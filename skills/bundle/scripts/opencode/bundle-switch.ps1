# Sync a bundle into opencode's config. opencode side only: this script never
# touches the Claude Code registry. The Claude Code side is
# ..\claudecode\bundle-switch.ps1, and the two do not share code.
#
#   powershell -File bundle-switch.ps1            list bundles
#   powershell -File bundle-switch.ps1 status     same
#   powershell -File bundle-switch.ps1 --help     this text
#   powershell -File bundle-switch.ps1 --diag <name>
#                                                 print each candidate's probe result
#                                                 without writing anything
#   powershell -File bundle-switch.ps1 <name>     sync that bundle into opencode.jsonc
#
# Invoked from the opencode `bundle` command (assets/bundle.command.md).
#
# The sync merges one provider entry into ~\.config\opencode\opencode.jsonc and
# keeps every other key. The key is read from ~\.local\share\opencode\auth.json.
# Restart opencode afterwards: it reads its config once at startup.
#
# This script ALWAYS exits 0, so a failure reaches the caller as
# `NOT SWITCHED - <reason>` on stdout instead of an aborted command.

$ErrorActionPreference = 'Stop'

$script:ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$script:Bundles   = Join-Path $script:ClaudeDir 'bundles'
$script:EnvKey    = 'HKCU:\Environment'
$script:EMDash    = [char]0x2014

# JavaScriptSerializer, not ConvertFrom-Json: the agentrouter pricing payload
# contains an empty-string key (usable_group."" ), which PS 5.1's ConvertFrom-Json
# rejects outright. The serializer yields nested Dictionary/object[] instead of
# PSCustomObject, so property access below handles both shapes.
Add-Type -AssemblyName System.Web.Extensions
$script:Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
# ---------------------------------------------------------------------------
# helpers

function Write-NotSwitched([string]$Reason) {
    Write-Output ''
    Write-Output ('NOT SWITCHED ' + $script:EMDash + ' ' + $Reason)
    Write-Output ''
    exit 0
}
function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    if ($Obj -is [System.Collections.Generic.IDictionary[string, object]]) {
        if ($Obj.ContainsKey($Name)) { return $Obj[$Name] }
        return $null
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

# keys of a Dictionary or PSCustomObject, in order
function Get-PropNames($Obj) {
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.Generic.IDictionary[string, object]]) { return @($Obj.Keys) }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys) }
    return @($Obj.PSObject.Properties.Name)
}

# list bundle names (never touches a .local.json)
function Get-BundleNames {
    $names = New-Object System.Collections.Generic.List[string]
    $files = Get-ChildItem -Path $script:Bundles -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name
    foreach ($f in $files) {
        if ($f.Name -like '*.local.json') { continue }
        if ($f.Name.StartsWith('.')) { continue }
        $names.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
    }
    if ($names.Count -eq 0) { return 'none' }
    return ($names -join ' ')
}
# ---------------------------------------------------------------------------
# --opencode: the same bundle aimed at opencode. Mirrors bundle-switch.sh: no
# registry sweep (it would blank the Anthropic keys), OpenAI-wire probes, and no
# registry write: it syncs only its own provider entry into opencode.jsonc.

$script:OcAuth   = Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'
$script:OcCmd    = Join-Path $env:USERPROFILE '.config\opencode\command\bundle.md'
$script:OcCfg    = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
$script:OcCmdSrc = Join-Path $script:ClaudeDir 'skills\bundle\assets\bundle.command.md'

function Get-OpenCodeVersion {
    try {
        $out = & opencode --version 2>$null
        if ($out) {
            $v = (($out | Select-Object -First 1) -split '\s+')[0]
            if ($v -match '^\d') { return $v }
        }
    } catch { }
    return '0.0.0'
}

# One OpenAI-wire probe. 200 with tool_calls is the only evidence that a model
# can call tools, which is what the generated tool_call flag asserts. Only 5xx
# and connection failures are retried: a 400 here is a final answer.
# Returns @{ code; toolCall; snippet }.
function Invoke-OcProbe([string]$Base, [string]$Model, [string]$Token) {
    $body = @{
        model = $Model; max_tokens = 256
        messages = @(@{ role = 'user'; content = 'What is the weather in Paris? Call the get_weather tool.' })
        tools = @(@{ type = 'function'; function = @{
            name = 'get_weather'; description = 'Get the current weather for a city.'
            parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') } } })
    }
    $tmp = [System.IO.Path]::GetTempFileName()
    $out = [System.IO.Path]::GetTempFileName()
    $code = ''
    $resp = ''
    try {
        [System.IO.File]::WriteAllText($tmp, $script:Json.Serialize($body), (New-Object System.Text.UTF8Encoding $false))
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $code = & curl.exe -sS --max-time 30 -o $out -w '%{http_code}' `
                -X POST "$Base/chat/completions" `
                -H "Authorization: Bearer $Token" `
                -H 'content-type: application/json' `
                -A $script:OcUA `
                --data-binary "@$tmp" 2>$null
            $code = ("$code").Trim()
            if ($code -ne '' -and $code -notmatch '^5\d\d$') { break }
        }
        if (Test-Path -LiteralPath $out) { $resp = Get-Content -LiteralPath $out -Raw -Encoding UTF8 }
    } catch {
        $code = ''
    } finally {
        Remove-Item -LiteralPath $tmp, $out -ErrorAction SilentlyContinue
    }
    if ($null -eq $resp) { $resp = '' }

    $toolCall = $false
    if ($code -eq '200') {
        try {
            $choices = @(Get-Prop ($script:Json.DeserializeObject($resp)) 'choices')
            if ($choices.Count -gt 0) {
                $calls = @(Get-Prop (Get-Prop $choices[0] 'message') 'tool_calls')
                if ($calls.Count -gt 0) { $toolCall = $true }
            }
        } catch { }
    }
    $snip = ($resp -replace '\s+', ' ')
    if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 160) }
    return @{ code = $code; toolCall = $toolCall; snippet = $snip }
}

# The opencode model list and its probes. Field names inherit from resolveModels
# only when the opencode block does not give its own `from`; prefer and
# requiresToolUse always come from resolveModels.
# Returns @{ rc = 0|1|2|3; rows = @(@{ name; tool }); detail }. rc as in
# Resolve-Models: 1 list unobtainable, 2 nothing answered, 3 filter emptied it.
function Resolve-OcModels($Prof, [string]$Base, [string]$Token) {
    $oc = Get-Prop $Prof 'opencode'
    $rm = Get-Prop $Prof 'resolveModels'
    $ownFrom = -not [string]::IsNullOrEmpty([string](Get-Prop $oc 'from'))
    function Pick($key, $default) {
        $v = [string](Get-Prop $oc $key)
        if ($v -eq '' -and -not $ownFrom) { $v = [string](Get-Prop $rm $key) }
        if ($v -eq '') { $v = $default }
        return $v
    }
    $url    = Pick 'from' ''
    $idf    = Pick 'idField' 'model_name'
    $ratiof = Pick 'ratioField' ''
    $ep     = [string](Get-Prop $oc 'requiresEndpointType')
    $prefer = [string](Get-Prop $rm 'prefer')
    $requireToolUse = ([string](Get-Prop $rm 'requiresToolUse') -eq 'true')
    if ([string]::IsNullOrEmpty($url)) { return @{ rc = 1; rows = @(); detail = 'no list endpoint' } }

    $cache = Join-Path $env:TEMP ('claude-bundle-state\' + $script:Name + '-opencode-models.cache.json')
    $json = ''
    $fetchNote = ''
    $bodyPath = Join-Path $env:TEMP ('bundle-oc-models-' + [guid]::NewGuid().ToString('n') + '.json')
    try {
        & curl.exe -sS --max-time 12 -A $script:OcUA -H "Authorization: Bearer $Token" -o $bodyPath $url
        if ($LASTEXITCODE -ne 0) { $fetchNote = 'curl exit ' + $LASTEXITCODE }
        if (Test-Path -LiteralPath $bodyPath) { $json = Get-Content -LiteralPath $bodyPath -Raw -Encoding UTF8 }
    } catch { $json = '' } finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }

    $parsed = $null
    $hadData = $false
    if (-not [string]::IsNullOrEmpty($json)) {
        try {
            $parsed = $script:Json.DeserializeObject($json)
            if ($null -ne (Get-Prop $parsed 'data')) { $hadData = $true }
        } catch { $hadData = $false }
    }
    if ($hadData) {
        try {
            New-Item -ItemType Directory -Path (Split-Path $cache) -Force | Out-Null
            Set-Content -LiteralPath $cache -Value $json -Encoding UTF8
        } catch { }
    } else {
        $json = ''
        if (Test-Path -LiteralPath $cache) { $json = Get-Content -LiteralPath $cache -Raw }
        if ([string]::IsNullOrEmpty($json)) { return @{ rc = 1; rows = @(); detail = $fetchNote } }
        $parsed = $script:Json.DeserializeObject($json)
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($m in @(Get-Prop $parsed 'data')) {
        if ($ep -ne '') {
            $eps = @(Get-Prop $m 'supported_endpoint_types')
            if ($eps -notcontains $ep) { continue }
        }
        $name = [string](Get-Prop $m $idf)
        if ([string]::IsNullOrEmpty($name)) { continue }
        $ratio = 999.0
        if ($ratiof -ne '') {
            $tmp = 0.0
            if ([double]::TryParse([string](Get-Prop $m $ratiof), [ref]$tmp)) { $ratio = $tmp }
        }
        $rows.Add([pscustomobject]@{ name = $name; ratio = $ratio })
    }
    if ($rows.Count -eq 0) { return @{ rc = 3; rows = @(); detail = '' } }

    $sorted = $rows | Sort-Object -Property @{Expression = { $_.ratio }; Ascending = $true },
                                          @{Expression = { $_.name };  Ascending = $true } |
        ForEach-Object { $_.name }
    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $head = @()
    if ($prefer -ne '') { $head = @($rows | Where-Object { $_.name -cmatch $prefer } | ForEach-Object { $_.name }) }
    foreach ($n in (@($head) + @($sorted))) {
        if (-not $seen.ContainsKey($n)) { $seen[$n] = $true; $ordered.Add($n) }
    }

    $usable = New-Object System.Collections.Generic.List[object]
    $probed = 0
    $firstFailure = ''
    foreach ($m in $ordered) {
        $probed++
        $p = Invoke-OcProbe $Base $m $Token
        if ($script:Diag) {
            $note = ''
            if ($p.code -ne '200' -and -not [string]::IsNullOrEmpty($p.snippet)) { $note = '  ' + $p.snippet }
            [Console]::Error.WriteLine(('{0,-6} tool={1,-5} {2}{3}' -f $p.code, $p.toolCall, $m, $note))
        }
        if ($p.code -eq '200' -and ((-not $requireToolUse) -or $p.toolCall)) {
            $usable.Add([pscustomobject]@{ name = $m; tool = $p.toolCall })
        } elseif ($firstFailure -eq '') {
            $firstFailure = $m + ' -> HTTP ' + $p.code + ' ' + $p.snippet
        }
    }
    if ($usable.Count -eq 0) {
        return @{ rc = 2; rows = @(); detail = ($probed.ToString() + ' candidates probed; first refusal: ' + $firstFailure) }
    }
    return @{ rc = 0; rows = $usable; detail = '' }
}

# Writes one file through a temp copy that must parse before it replaces the
# target. A .bak of the previous file is kept beside it.
function Set-ValidatedFile([string]$Target, [string]$Text, [bool]$IsJson) {
    New-Item -ItemType Directory -Path (Split-Path $Target) -Force | Out-Null
    $tmp = $Target + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding $false))
    if ($IsJson) { [void]$script:Json.DeserializeObject((Get-Content -LiteralPath $tmp -Raw -Encoding UTF8)) }
    if (Test-Path -LiteralPath $Target) { Copy-Item -LiteralPath $Target -Destination ($Target + '.bak') -Force }
    Move-Item -LiteralPath $tmp -Destination $Target -Force
}

function Invoke-OpenCodeSwitch($Prof, [string]$Token) {
    $oc = Get-Prop $Prof 'opencode'
    $base = [string](Get-Prop $oc 'baseURL')
    if ([string]::IsNullOrEmpty($base)) { Write-NotSwitched 'the bundle has no opencode block: set opencode.baseURL' }
    $script:OcUA = 'opencode/' + (Get-OpenCodeVersion)

    $res = Resolve-OcModels $Prof $base $Token
    $detail = [string]$res.detail
    if ($res.rc -eq 1) { Write-NotSwitched ('could not fetch the opencode model list' + $(if ($detail) { ' (' + $detail + ')' } else { '' }) + '.') }
    if ($res.rc -eq 2) { Write-NotSwitched ('no model behind ' + $base + ' answered the opencode probe. ' + $detail) }
    if ($res.rc -eq 3) {
        Write-NotSwitched ('the opencode list arrived, but no row survived requiresEndpointType "' +
            [string](Get-Prop $oc 'requiresEndpointType') + '".')
    }

    if ($script:Diag) {
        Write-Output ('--- diag ' + $script:Name + ' opencode (registry untouched) ---')
        foreach ($r in $res.rows) {
            Write-Output ('  ' + $r.name + ' tool_call=' + $(if ($r.tool) { 'true' } else { 'false' }))
        }
        exit 0
    }

    $models = @{}
    foreach ($r in $res.rows) { $models[$r.name] = @{ name = $r.name; tool_call = $r.tool } }
    # Merge, not replace: only this bundle's provider entry is rewritten. Other
    # providers and the user's default model stay as they are.
    $cur = @{}
    if (Test-Path -LiteralPath $script:OcCfg) {
        try { $cur = $script:Json.DeserializeObject((Get-Content -LiteralPath $script:OcCfg -Raw -Encoding UTF8)) }
        catch { Write-NotSwitched ($script:OcCfg + ' is not plain JSON, so it was not rewritten. Remove its comments, then re-run') }
    }
    if (-not $cur.ContainsKey('$schema')) { $cur['$schema'] = 'https://opencode.ai/config.json' }
    if (-not $cur.ContainsKey('provider') -or $null -eq $cur['provider']) { $cur['provider'] = @{} }
    $cur['provider'][$script:Name] = @{
        npm = '@ai-sdk/openai-compatible'; name = $script:Name
        options = @{ baseURL = $base }; models = $models }
    $cfgJson = $script:Json.Serialize($cur)

    $cmdText = [System.IO.File]::ReadAllText($script:OcCmdSrc)
    try {
        Set-ValidatedFile $script:OcCfg $cfgJson $true
        Set-ValidatedFile $script:OcCmd $cmdText $false
    } catch {
        Write-NotSwitched ('could not write the opencode files: ' + $_.Exception.Message)
    }

    Write-Output ('/bundle ' + $script:Name + ' (opencode)')
    Write-Output ('  models ' + (($res.rows | ForEach-Object { $_.name }) -join ' '))
    Write-Output ''
    Write-Output 'Restart opencode to pick this up: it reads its config once at startup.'
    Write-Output ''
    exit 0
}


# ---------------------------------------------------------------------------
# main

try {
    $argList = @($args)
    $arg = ''
    if ($argList.Count -ge 1) { $arg = [string]$argList[0] }

    # --diag <name>: probe every candidate and print each result, writing
    # nothing. The probe needs the token, and only this script reads that file.
    $diag = $false
    if ($arg -eq '--diag') {
        if ($argList.Count -lt 2) {
            Write-Output 'usage: bundle-switch.ps1 --diag <name>'
            exit 0
        }
        $diag = $true
        $arg = [string]$argList[1]
    }
    $script:Diag = $diag

    if ($arg -eq '--help' -or $arg -eq '-h') {
@'
bundle-switch.ps1 - sync a bundle into opencode's config.

  powershell -File bundle-switch.ps1            list bundles
  powershell -File bundle-switch.ps1 status     same
  powershell -File bundle-switch.ps1 --help     this text
  powershell -File bundle-switch.ps1 --diag <name>
                                                print each candidate's probe result
                                                without writing anything
  powershell -File bundle-switch.ps1 <name>     sync that bundle into opencode.jsonc

Restart opencode afterwards: it reads its config once at startup.
'@
        exit 0
    }

    if ([string]::IsNullOrEmpty($arg) -or $arg -eq 'status') {
        Write-Output ('bundles: ' + (Get-BundleNames))
        exit 0
    }

    $name = $arg
    $script:Name = $name

    # the name becomes a path, so keep the charset strict
    if ($name -notmatch '^[a-z0-9-]+$') {
        Write-Output ('invalid bundle name: ' + $name)
        Write-Output ('bundles: ' + (Get-BundleNames))
        exit 0
    }

    $profPath = Join-Path $script:Bundles ($name + '.json')
    if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
        Write-NotSwitched ('no such bundle: ' + $name + ' (available: ' + (Get-BundleNames) + ')')
    }

    $prof = $null
    try { $prof = $script:Json.DeserializeObject((Get-Content -LiteralPath $profPath -Raw)) }
    catch { Write-NotSwitched ('invalid JSON in ' + $profPath) }
    if ($null -eq $prof) { Write-NotSwitched ('invalid JSON in ' + $profPath) }

    # opencode reads its key from its own auth.json, never from the Claude token file
    $authAll = $null
    try { $authAll = $script:Json.DeserializeObject((Get-Content -LiteralPath $script:OcAuth -Raw -Encoding UTF8)) } catch { $authAll = $null }
    $ocToken = [string](Get-Prop (Get-Prop $authAll $name) 'key')
    if ([string]::IsNullOrEmpty($ocToken)) {
        Write-NotSwitched ($script:OcAuth + ' has no key under "' + $name + '": add it there, then re-run')
    }

    Invoke-OpenCodeSwitch $prof $ocToken
    exit 0
} catch {
    Write-Output ''
    Write-Output ('NOT SWITCHED ' + $script:EMDash + ' unexpected error: ' + $_.Exception.Message)
    Write-Output ''
    exit 0
}
