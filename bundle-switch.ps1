# Switch the provider Claude Code talks to. PowerShell port of bundle-switch.sh.
#
#   powershell -File bundle-switch.ps1            list bundles + report the active one
#   powershell -File bundle-switch.ps1 status     same
#   powershell -File bundle-switch.ps1 --help     this text
#   powershell -File bundle-switch.ps1 --new      the add-a-provider flow, not a switch
#   powershell -File bundle-switch.ps1 <name>     switch to that bundle
#
# Invoked from inside the /bundle skill. This port replaces bash+jq with the
# native Windows toolchain: System.Web.Script.Serialization for JSON, curl.exe
# for HTTP, and [Environment]::SetEnvironmentVariable for the registry (it
# broadcasts WM_SETTINGCHANGE, so a newly opened terminal picks the values up).
#
# Why HKCU\Environment and not settings.json: the API token cannot live in the
# tracked settings.json, and settings.local.json is not read for env. Both the
# non-secret and the secret part therefore live in the registry. One token file
# per provider lives in ~/.claude/bundles/<name>.local.json, gitignored by the
# `*.local.*` rule; never add those to git.
#
# After every switch, OPEN A NEW TERMINAL. The registry only affects newly
# created processes, and Claude Code inherits its environment from the shell
# that launched it. Restarting claude in the same terminal is not enough.
#
# To go back to a plain Anthropic account, delete the variables from
# HKCU\Environment (ANTHROPIC_* / CLAUDE_CODE_*), then open a new terminal.
#
# This script ALWAYS exits 0. It runs as inline output inside the /bundle skill,
# where a non-zero exit aborts the invocation and Claude never sees the output,
# which is how a failed switch could get narrated as a successful one. Failure
# is reported on stdout as `NOT SWITCHED - <reason>` instead.

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

# read one variable from HKCU\Environment. Returns $null when absent.
function Get-RegValue([string]$Name) {
    try {
        $item = Get-ItemProperty -Path $script:EnvKey -Name $Name -ErrorAction Stop
        return [string]$item.$Name
    } catch {
        return $null
    }
}

# write one variable and broadcast. Empty value deletes it (the previous
# provider's value must not linger, and SetEnvironmentVariable(null) removes
# the registry entry while still broadcasting WM_SETTINGCHANGE).
function Set-RegValue([string]$Name, [string]$Value) {
    try {
        if ([string]::IsNullOrEmpty($Value)) {
            [System.Environment]::SetEnvironmentVariable($Name, $null, 'User')
        } else {
            [System.Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        }
        return $true
    } catch {
        return $false
    }
}

# safe property access on a Dictionary or PSCustomObject that may be $null or
# lack the field
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

# report the active provider. Prints names and URLs only, never a token value.
function Write-Report {
    $base  = Get-RegValue 'ANTHROPIC_BASE_URL'
    $model = Get-RegValue 'ANTHROPIC_MODEL'
    $tok   = Get-RegValue 'ANTHROPIC_AUTH_TOKEN'
    if ([string]::IsNullOrEmpty($base))  { $base = '<unset>' }
    if ([string]::IsNullOrEmpty($model)) { $model = '<unset>' }
    Write-Output ('active    base  ' + $base)
    Write-Output ('          model ' + $model)
    if (-not [string]::IsNullOrEmpty($tok)) {
        Write-Output ('          token present (' + $tok.Length + ' chars)')
    } else {
        Write-Output '          token MISSING'
    }
}

# natural (version) sort key: numeric runs zero-padded so lexical order matches
# numeric order. Replaces the bash `sort -Vr` the .sh version relied on.
function Get-NaturalKey([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in [regex]::Matches($s, '(\d+)|(\D+)')) {
        if ($m.Groups[1].Success) {
            $n = $m.Groups[1].Value.TrimStart('0')
            if ($n -eq '') { $n = '0' }
            [void]$sb.Append(('{0:D12}' -f [long]$n))
        } else {
            [void]$sb.Append($m.Groups[2].Value)
        }
    }
    return $sb.ToString()
}

function Get-ClaudeCliVersion {
    try {
        $out = & claude --version 2>$null
        if ($out) {
            $first = ($out | Select-Object -First 1)
            $v = (($first -split '\s+')[0])
            if ($v -match '^\d') { return $v }
        }
    } catch { }
    return '0.0.0'
}

# The probe must carry a Claude Code User-Agent: agentrouter fingerprints
# clients and answers 401 "unauthorized client detected" to anything that does
# not look like one. It matches the SHAPE claude-cli/<anything> (external, cli).
$script:ProbeUA = 'claude-cli/' + (Get-ClaudeCliVersion) + ' (external, cli)'

# One-token probe. The token is passed in, never taken from the environment:
# this script runs inside Claude Code, whose own ANTHROPIC_AUTH_TOKEN still
# belongs to the session's provider and would 401 against the new one.
function Test-ModelWorks([string]$Base, [string]$Model, [string]$Token) {
    # The JSON body goes through a temp file, not a -d argument. PowerShell 5.1's
    # native-argument quoting mangles a string containing embedded double quotes,
    # so curl received invalid JSON and answered 400 for every candidate.
    $body = '{"model":"' + $Model + '","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
    $tmp = [System.IO.Path]::GetTempFileName()
    $code = ''
    try {
        Set-Content -LiteralPath $tmp -Value $body -Encoding Ascii -NoNewline
        $code = & curl.exe -sS --max-time 25 -o NUL -w '%{http_code}' `
            -X POST "$Base/v1/messages" `
            -H "Authorization: Bearer $Token" `
            -H 'content-type: application/json' `
            -H 'anthropic-version: 2023-06-01' `
            -A $script:ProbeUA `
            --data-binary "@$tmp" 2>$null
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    return (("$code").Trim() -eq '200')
}

# Model resolution, driven entirely by the bundle's resolveModels block. No
# provider's model names are hardcoded; every candidate gets a one-token probe
# and only what answers 200 is used (both endpoints list models they cannot
# actually serve). Returns a hashtable: @{ rc = 0|1|2; lines = @('KEY=VALUE') }.
function Resolve-Models([string]$ProfPath, $Prof, [string]$Base, [string]$Token) {
    $rm = Get-Prop $Prof 'resolveModels'
    if ($null -eq $rm) { return @{ rc = 1; lines = @() } }
    $url = [string](Get-Prop $rm 'from')
    if ([string]::IsNullOrEmpty($url)) { return @{ rc = 1; lines = @() } }

    $idf    = [string](Get-Prop $rm 'idField');    if ([string]::IsNullOrEmpty($idf)) { $idf = 'model_name' }
    $ratiof = [string](Get-Prop $rm 'ratioField')
    $cwf    = [string](Get-Prop $rm 'contextWindowField')
    $ep     = [string](Get-Prop $rm 'requiresEndpointType')
    $assign = [string](Get-Prop $rm 'assignment'); if ([string]::IsNullOrEmpty($assign)) { $assign = 'family' }
    $prefer = [string](Get-Prop $rm 'prefer')

    $cacheDir = Join-Path $env:TEMP 'claude-bundle-state'
    $cache = Join-Path $cacheDir (([System.IO.Path]::GetFileNameWithoutExtension($ProfPath)) + '-models.cache.json')

    $json = ''
    try {
        $out = & curl.exe -sS --max-time 12 -A $script:ProbeUA -H "Authorization: Bearer $Token" $url 2>$null
        if ($out) { $json = ($out -join "`n") }
    } catch { $json = '' }

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
            if (-not (Test-Path -LiteralPath $cacheDir)) {
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            }
            Set-Content -LiteralPath $cache -Value $json -Encoding UTF8
        } catch { }
    } else {
        $json = ''
        if (Test-Path -LiteralPath $cache) {
            try { $json = Get-Content -LiteralPath $cache -Raw } catch { $json = '' }
        }
        if ([string]::IsNullOrEmpty($json)) { return @{ rc = 1; lines = @() } }
        try { $parsed = $script:Json.DeserializeObject($json) } catch { return @{ rc = 1; lines = @() } }
    }

    $data = Get-Prop $parsed 'data'
    if ($null -eq $data) { return @{ rc = 1; lines = @() } }
    if ($data -isnot [System.Array]) { $data = @($data) }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($m in $data) {
        if ($ep -ne '') {
            $eps = Get-Prop $m 'supported_endpoint_types'
            if ($null -eq $eps) { continue }
            if (-not ($eps -contains $ep)) { continue }
        }
        $name = [string](Get-Prop $m $idf)
        if ([string]::IsNullOrEmpty($name)) { continue }
        $ratio = 999.0
        if ($ratiof -ne '') {
            $r = Get-Prop $m $ratiof
            if ($null -ne $r) {
                $tmp = 0.0
                if ([double]::TryParse([string]$r, [ref]$tmp)) { $ratio = $tmp }
            }
        }
        $cw = [long]0
        if ($cwf -ne '') {
            $c = Get-Prop $m $cwf
            if ($null -ne $c) {
                $tmpL = [long]0
                if ([long]::TryParse([string]$c, [ref]$tmpL)) { $cw = $tmpL }
            }
        }
        $rows.Add([pscustomobject]@{ name = $name; ratio = $ratio; cw = $cw })
    }
    if ($rows.Count -eq 0) { return @{ rc = 1; lines = @() } }

    # Probe order. "family": claude models first (newest version first), then
    # everything else cheapest first. "single": plain cost order, with an
    # optional preferred name hoisted to the front.
    $ordered = New-Object System.Collections.Generic.List[string]
    if ($assign -eq 'single') {
        $sorted = $rows |
            Sort-Object -Property @{Expression = { $_.ratio }; Ascending = $true },
                                   @{Expression = { $_.name };  Ascending = $true } |
            ForEach-Object { $_.name }
        if ($prefer -ne '') {
            $prefNames = $rows | Where-Object { $_.name -match $prefer } | ForEach-Object { $_.name }
            $seen = @{}
            foreach ($n in (@($prefNames) + @($sorted))) {
                if (-not $seen.ContainsKey($n)) { $seen[$n] = $true; $ordered.Add($n) }
            }
        } else {
            foreach ($n in $sorted) { $ordered.Add($n) }
        }
    } else {
        $group = @()
        $group += $rows | Where-Object { $_.name -match '^claude-opus-' } |
            Sort-Object -Property @{Expression = { Get-NaturalKey $_.name }; Descending = $true } |
            ForEach-Object { $_.name }
        $group += $rows | Where-Object { $_.name -match '^claude-' -and $_.name -notmatch '^claude-opus-' } |
            Sort-Object -Property @{Expression = { Get-NaturalKey $_.name }; Descending = $true } |
            ForEach-Object { $_.name }
        $group += $rows | Where-Object { $_.name -notmatch '^claude-' } |
            Sort-Object -Property @{Expression = { $_.ratio }; Ascending = $true },
                                   @{Expression = { $_.name };  Ascending = $true } |
            ForEach-Object { $_.name }
        foreach ($n in $group) { $ordered.Add($n) }
    }

    $usable = New-Object System.Collections.Generic.List[string]
    foreach ($m in $ordered) {
        if ([string]::IsNullOrEmpty($m)) { continue }
        if (Test-ModelWorks $Base $m $Token) { $usable.Add($m) }
    }
    if ($usable.Count -eq 0) { return @{ rc = 2; lines = @() } }

    $primary = $usable[0]
    $sfxMap = Get-Prop $Prof 'contextSuffixes'

    # Per-model client-side context marker, from contextSuffixes or from a
    # context window of at least 1M. It must NOT go on the wire: Claude Code
    # strips it before the request and uses it only to size its own window.
    $lines = New-Object System.Collections.Generic.List[string]
    $emit = {
        param($key, $val)
        $suffix = ''
        if ($null -ne $sfxMap) {
            $s = Get-Prop $sfxMap $val
            if (-not [string]::IsNullOrEmpty([string]$s)) { $suffix = [string]$s }
        }
        if ($suffix -eq '' -and $cwf -ne '') {
            $row = $rows | Where-Object { $_.name -eq $val } | Select-Object -First 1
            if ($null -ne $row -and $row.cw -ge 1048576) { $suffix = '[1m]' }
        }
        $lines.Add($key + '=' + $val + $suffix)
    }

    if ($assign -eq 'single') {
        foreach ($slot in @('ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL_NAME',
                            'ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL',
                            'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME','CLAUDE_CODE_SUBAGENT_MODEL')) {
            & $emit $slot $primary
        }
    } else {
        $opus = $usable | Where-Object { $_ -match '^claude-opus-' } |
            Sort-Object -Property @{Expression = { Get-NaturalKey $_ }; Descending = $true } |
            Select-Object -First 1
        $sonnet = $usable | Where-Object { $_ -match '^claude-' -and $_ -ne $opus } |
            Sort-Object -Property @{Expression = { Get-NaturalKey $_ }; Descending = $true } |
            Select-Object -First 1
        $mini = $usable | Where-Object { $_ -notmatch '^claude-' } | Select-Object -First 1
        if ([string]::IsNullOrEmpty($mini)) { $mini = $sonnet }
        if ([string]::IsNullOrEmpty($mini)) { $mini = $primary }

        & $emit 'ANTHROPIC_MODEL' $primary
        if (-not [string]::IsNullOrEmpty($opus))   { & $emit 'ANTHROPIC_DEFAULT_OPUS_MODEL'   $opus }
        if (-not [string]::IsNullOrEmpty($sonnet)) { & $emit 'ANTHROPIC_DEFAULT_SONNET_MODEL' $sonnet }
        & $emit 'ANTHROPIC_DEFAULT_HAIKU_MODEL' $mini
        & $emit 'CLAUDE_CODE_SUBAGENT_MODEL' $mini
    }

    return @{ rc = 0; lines = $lines }
}

# ---------------------------------------------------------------------------
# main

try {
    $arg = ''
    if ($args.Count -ge 1) { $arg = [string]$args[0] }

    if ($arg -eq '--help' -or $arg -eq '-h') {
@'
bundle-switch.ps1 - switch the provider Claude Code talks to.

  powershell -File bundle-switch.ps1            list bundles + report the active one
  powershell -File bundle-switch.ps1 status     same
  powershell -File bundle-switch.ps1 --help     this text
  powershell -File bundle-switch.ps1 --new      the add-a-provider flow, not a switch
  powershell -File bundle-switch.ps1 <name>     switch to that bundle

After every switch, OPEN A NEW terminal before using it: the registry only
affects newly created processes, so restarting claude in the same terminal is
not enough.
'@
        exit 0
    }

    if ([string]::IsNullOrEmpty($arg) -or $arg -eq 'status') {
        Write-Output ('bundles: ' + (Get-BundleNames))
        Write-Report
        exit 0
    }

    if ($arg -eq '--new') {
        Write-Output ('NEW BUNDLE ' + $script:EMDash + ' no switch was attempted.')
        exit 0
    }

    $name = $arg

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

    $secPath = Join-Path $script:Bundles ($name + '.local.json')
    if (-not (Test-Path -LiteralPath $secPath -PathType Leaf)) {
        Write-NotSwitched ('missing ' + $secPath + "`n" +
            'Create it as {"env":{"ANTHROPIC_AUTH_TOKEN":"<key>"}} and re-run.' + "`n" +
            'Refusing without it: the previous provider''s token is still in the registry and would be sent to the new provider.')
    }

    $prof = $null
    try { $prof = $script:Json.DeserializeObject((Get-Content -LiteralPath $profPath -Raw)) }
    catch { Write-NotSwitched ('invalid JSON in ' + $profPath) }
    if ($null -eq $prof) { Write-NotSwitched ('invalid JSON in ' + $profPath) }

    $sec = $null
    try { $sec = $script:Json.DeserializeObject((Get-Content -LiteralPath $secPath -Raw)) }
    catch { Write-NotSwitched ('invalid JSON in ' + $secPath) }
    if ($null -eq $sec) { Write-NotSwitched ('invalid JSON in ' + $secPath) }

    $token = [string](Get-Prop (Get-Prop $sec 'env') 'ANTHROPIC_AUTH_TOKEN')
    if ([string]::IsNullOrEmpty($token)) {
        Write-NotSwitched ($secPath + ' has no env.ANTHROPIC_AUTH_TOKEN')
    }

    # build the final KEY=VALUE set: bundle env, plus resolved models, plus token
    $plan = [ordered]@{}
    $profEnv = Get-Prop $prof 'env'
    if ($null -ne $profEnv) {
        foreach ($k in Get-PropNames $profEnv) { $plan[$k] = [string](Get-Prop $profEnv $k) }
    }

    $rmFrom = [string](Get-Prop (Get-Prop $prof 'resolveModels') 'from')
    if (-not [string]::IsNullOrEmpty($rmFrom)) {
        $baseUrl = [string](Get-Prop $profEnv 'ANTHROPIC_BASE_URL')
        $res = Resolve-Models $profPath $prof $baseUrl $token
        if ($res.rc -eq 0) {
            foreach ($line in $res.lines) {
                $idx = $line.IndexOf('=')
                if ($idx -gt 0) {
                    $plan[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
                }
            }
        } elseif ($res.rc -eq 2) {
            Write-NotSwitched ('no model behind ' + $baseUrl + ' answered a probe just now.' + "`n" +
                "The provider's list endpoint names models it cannot currently serve: agentrouter" + "`n" +
                "rations the claude models and answers 402 'Budget pool quota has been exhausted'" + "`n" +
                'while still listing them. Refusing to switch onto a model that cannot serve a' + "`n" +
                'request ' + $script:EMDash + ' retry once the pool refills.')
        } else {
            Write-NotSwitched ('could not fetch the model list from ' + $rmFrom + ' (no network, no cache).')
        }
    }
    $plan['ANTHROPIC_AUTH_TOKEN'] = $token

    # Every key any bundle has ever set must be written this time, otherwise a
    # key from the previous provider lingers in the registry. Model names are
    # resolved at switch time, so also read back the namespace this script owns.
    $allKeys = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -Path $script:Bundles -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name | ForEach-Object {
            if ($_.Name -like '*.local.json') { return }
            if ($_.Name.StartsWith('.')) { return }
            try {
                $o = $script:Json.DeserializeObject((Get-Content -LiteralPath $_.FullName -Raw))
                $e = Get-Prop $o 'env'
                if ($null -ne $e) { foreach ($k in Get-PropNames $e) { $allKeys.Add($k) } }
            } catch { }
        }
    try {
        $props = Get-ItemProperty -Path $script:EnvKey -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^(ANTHROPIC_|CLAUDE_CODE_)[A-Za-z0-9_]*$') { $allKeys.Add($p.Name) }
        }
    } catch { }
    $allKeys.Add('ANTHROPIC_AUTH_TOKEN')
    # Resolved model keys are computed at switch time, so enumerate them from
    # the plan too: on a fresh registry the env blocks and the read-back cannot
    # name them, and without this they would never be written.
    foreach ($k in @($plan.Keys)) { $allKeys.Add([string]$k) }
    $allKeys = @($allKeys | Sort-Object -Unique)

    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($key in $allKeys) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        $val = ''
        if ($plan.Contains($key)) { $val = [string]$plan[$key] }
        if (-not (Set-RegValue $key $val)) { $failed.Add($key) }
    }
    if ($failed.Count -gt 0) {
        Write-NotSwitched ('registry write failed for:' + ($failed -join ' '))
    }

    Write-Output ('/bundle ' + $name)
    Write-Output ('  model ' + (Get-RegValue 'ANTHROPIC_MODEL'))
    Write-Output ('  base  ' + (Get-RegValue 'ANTHROPIC_BASE_URL'))
    Write-Output ('  token present (' + $token.Length + ' chars)')
    Write-Output ''
    Write-Output 'Open a NEW terminal before using it: the registry only affects newly'
    Write-Output 'created processes, so restarting claude in this terminal is not enough.'
    Write-Output ''
    exit 0
} catch {
    Write-Output ''
    Write-Output ('NOT SWITCHED ' + $script:EMDash + ' unexpected error: ' + $_.Exception.Message)
    Write-Output ''
    exit 0
}
