# Switch the provider Claude Code talks to. PowerShell port of bundle-switch.sh.
#
#   powershell -File bundle-switch.ps1            list bundles + report the active one
#   powershell -File bundle-switch.ps1 status     same
#   powershell -File bundle-switch.ps1 --help     this text
#   powershell -File bundle-switch.ps1 --new      the add-a-provider flow, not a switch
#   powershell -File bundle-switch.ps1 --diag <name>
#                                                 probe every candidate of one
#                                                 bundle and print each result,
#                                                 without writing the registry
#   powershell -File bundle-switch.ps1 <name>     switch to that bundle
#
# Invoked from inside the /bundle skill. The opencode side is
# ..\opencode\bundle-switch.ps1, which shares no code with this file. This port replaces bash+jq with the
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

# The only evidence the script has about a candidate. The request carries a
# tools array and an unambiguous instruction to call the tool, so a 200 can be
# told apart from a model that merely answers: measured on chengmo, 15 of 73
# listed models answered 200, but llama3.1-8B answered with plain text
# (stop_reason end_turn) and never called the tool, and nemotron-3.5-content-safety
# is a classifier rather than a chat model. Which of those counts as usable is
# the bundle's call, via requiresToolUse.
#
# A 400 or 5xx is retried once: a relay routing through a shared pool refuses
# transiently, measured as `分组 auto 下模型 X 的可用渠道不存在（retry）` minutes
# after the same model had answered 200.
#
# The token is passed in, never taken from the environment: this script runs
# inside Claude Code, whose own ANTHROPIC_AUTH_TOKEN still belongs to the
# session's provider and would 401 against the new one.
#
# Returns @{ code = '<http code>' ; toolUse = $bool ; snippet = '<body head>' }.
function Invoke-ModelProbe([string]$Base, [string]$Model, [string]$Token) {
    # The JSON body goes through a temp file, not a -d argument. PowerShell 5.1's
    # native-argument quoting mangles a string containing embedded double quotes,
    # so curl received invalid JSON and answered 400 for every candidate.
    $body = '{"model":"' + $Model + '","max_tokens":256,' +
            '"tools":[{"name":"get_weather","description":"Get the current weather for a city.",' +
            '"input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],' +
            '"messages":[{"role":"user","content":"What is the weather in Paris? Call the get_weather tool."}]}'
    $tmp = [System.IO.Path]::GetTempFileName()
    $out = [System.IO.Path]::GetTempFileName()
    $code = ''
    $resp = ''
    try {
        Set-Content -LiteralPath $tmp -Value $body -Encoding Ascii -NoNewline
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $code = & curl.exe -sS --max-time 30 -o $out -w '%{http_code}' `
                -X POST "$Base/v1/messages" `
                -H "Authorization: Bearer $Token" `
                -H 'content-type: application/json' `
                -H 'anthropic-version: 2023-06-01' `
                -A $script:ProbeUA `
                --data-binary "@$tmp" 2>$null
            $code = ("$code").Trim()
            if ($code -notmatch '^(400|5\d\d)$') { break }
        }
        if (Test-Path -LiteralPath $out) {
            $resp = Get-Content -LiteralPath $out -Raw -Encoding UTF8
        }
    } catch {
        $code = ''
    } finally {
        Remove-Item -LiteralPath $tmp, $out -ErrorAction SilentlyContinue
    }
    if ($null -eq $resp) { $resp = '' }

    $toolUse = $false
    if ($code -eq '200') {
        try {
            $blocks = Get-Prop ($script:Json.DeserializeObject($resp)) 'content'
            if ($null -ne $blocks) {
                foreach ($blk in @($blocks)) {
                    if ([string](Get-Prop $blk 'type') -eq 'tool_use') { $toolUse = $true; break }
                }
            }
        } catch { }
    }
    $snip = ($resp -replace '\s+', ' ')
    if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 160) }
    return @{ code = $code; toolUse = $toolUse; snippet = $snip }
}

# Model resolution, driven entirely by the bundle's resolveModels block. No
# provider's model names are hardcoded; every candidate gets one probe and only
# what answers it is used (both endpoints list models they cannot actually
# serve). Field semantics live in the header of bundle-switch.sh.
# Returns a hashtable: @{ rc = 0|1|2|3; lines = @('KEY=VALUE'); probed = <n>;
# detail = '<why>' }. rc 3 is "the list arrived and the filter emptied it",
# distinct from rc 1, "the list could not be obtained".
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
    # Opt-in: require a tool_use answer rather than merely a 200. Off by default
    # so an existing bundle keeps resolving exactly as it did.
    $requireToolUse = ([string](Get-Prop $rm 'requiresToolUse') -eq 'true')

    $cacheDir = Join-Path $env:TEMP 'claude-bundle-state'
    $cache = Join-Path $cacheDir (([System.IO.Path]::GetFileNameWithoutExtension($ProfPath)) + '-models.cache.json')

    # curl writes to a file instead of being captured through the pipeline:
    # PowerShell 5.1 decodes a native command's stdout with the console code
    # page, so a UTF-8 pricing payload came back with the closing quote of a
    # mangled multi-byte run swallowed (…"NVIDIA英伟达"],… arrived as
    # …"NVIDIA英伟?],…), and the serializer then rejected the whole body — which
    # the caller reports as "could not fetch the model list (no network, no
    # cache)". Reading the bytes back with -Encoding UTF8 keeps them out of the
    # console's hands.
    $json = ''
    $fetchNote = ''
    $bodyPath = Join-Path $env:TEMP ('bundle-models-' + [guid]::NewGuid().ToString('n') + '.json')
    try {
        # curl's own stderr is left in place rather than discarded, and its exit
        # code is kept: "could not fetch" otherwise reads the same for an
        # unresolvable host, a reset connection and a TLS failure, and curl
        # distinguishes them (6 / 7 / 35) without any mapping table.
        & curl.exe -sS --max-time 12 -A $script:ProbeUA -H "Authorization: Bearer $Token" -o $bodyPath $url
        if ($LASTEXITCODE -ne 0) { $fetchNote = 'curl exit ' + $LASTEXITCODE }
        if (Test-Path -LiteralPath $bodyPath) {
            $json = Get-Content -LiteralPath $bodyPath -Raw -Encoding UTF8
        }
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
        if ([string]::IsNullOrEmpty($json)) { return @{ rc = 1; lines = @(); probed = 0; detail = $fetchNote } }
        try { $parsed = $script:Json.DeserializeObject($json) } catch { return @{ rc = 1; lines = @(); probed = 0; detail = 'cached list unparseable' } }
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
    if ($rows.Count -eq 0) {
        # The list arrived; the filter emptied it. This is NOT the same as a
        # fetch failure, and the two used to share rc=1 and one message: on
        # chengmo all 73 rows declared only the openai endpoint type, so
        # requiresEndpointType "anthropic" discarded every one and the switch
        # blamed the network.
        return @{ rc = 3; lines = @(); probed = 0; detail = '' }
    }

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
            # -cmatch, not -match: -match is case-INsensitive here while the
            # bash port's `awk '$1 ~ p'` is case-sensitive, so one bundle
            # resolved differently per port. It also let `^deepseek` hoist
            # DeepSeek-* along with the intended lowercase names.
            $prefNames = $rows | Where-Object { $_.name -cmatch $prefer } | ForEach-Object { $_.name }
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
    $probed = 0
    $firstFailure = ''
    foreach ($m in $ordered) {
        if ([string]::IsNullOrEmpty($m)) { continue }
        $probed++
        $p = Invoke-ModelProbe $Base $m $Token
        if ($script:Diag) {
            # The refusal body goes to stderr with the code: the code alone
            # cannot separate a 402 quota from a 403 group, and that is the
            # whole reason to run a diagnostic.
            $note = ''
            if ($p.code -ne '200' -and -not [string]::IsNullOrEmpty($p.snippet)) { $note = '  ' + $p.snippet }
            [Console]::Error.WriteLine(('{0,-6} tool={1,-5} {2}{3}' -f $p.code, $p.toolUse, $m, $note))
        }
        $ok = ($p.code -eq '200') -and ((-not $requireToolUse) -or $p.toolUse)
        if ($ok) {
            $usable.Add($m)
        } elseif ($firstFailure -eq '') {
            # One refusal kept verbatim. It is the only thing that separates a
            # rejected key from a dry pool from a wrong field name, and this
            # message used to read only "nothing answered a probe".
            $firstFailure = $m + ' -> HTTP ' + $p.code + ' ' + $p.snippet
        }
    }
    if ($usable.Count -eq 0) {
        return @{ rc = 2; lines = @(); probed = $probed;
                  detail = ($probed.ToString() + ' candidates probed; first refusal: ' + $firstFailure) }
    }

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
    $argList = @($args)
    $arg = ''
    if ($argList.Count -ge 1) { $arg = [string]$argList[0] }

    # --diag <name>: probe every candidate and print each result, writing
    # nothing. The probe needs the token, and only this script reads that file,
    # so this is the only way to see why a resolution picked what it picked.
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
bundle-switch.ps1 - switch the provider Claude Code talks to.

  powershell -File bundle-switch.ps1            list bundles + report the active one
  powershell -File bundle-switch.ps1 status     same
  powershell -File bundle-switch.ps1 --help     this text
  powershell -File bundle-switch.ps1 --new      the add-a-provider flow, not a switch
  powershell -File bundle-switch.ps1 --diag <name>
                                                probe every candidate of one
                                                bundle and print each result,
                                                without writing the registry
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
            $why = 'no model behind ' + $baseUrl + ' answered the probe.'
            if (-not [string]::IsNullOrEmpty($res.detail)) { $why += "`n" + $res.detail }
            Write-NotSwitched ($why + "`n" +
                'The list endpoint names models the provider cannot currently serve, and a relay' + "`n" +
                'routing through a shared pool also refuses transiently: a 5xx "no available' + "`n" +
                'channel for this model" was measured minutes after the same model had answered' + "`n" +
                '200. Retrying later can succeed against the same list.')
        } elseif ($res.rc -eq 3) {
            $epFilter = [string](Get-Prop (Get-Prop $prof 'resolveModels') 'requiresEndpointType')
            Write-NotSwitched ('the list from ' + $rmFrom + ' arrived, but no row survived the' + "`n" +
                'resolveModels filter (requiresEndpointType "' + $epFilter + '"). Every candidate' + "`n" +
                'was discarded before any probe ran ' + $script:EMDash + ' compare that value against' + "`n" +
                'what the endpoint actually publishes for supported_endpoint_types.')
        } else {
            $why = 'could not fetch the model list from ' + $rmFrom + '.'
            if (-not [string]::IsNullOrEmpty($res.detail)) { $why += ' ' + $res.detail + '.' }
            Write-NotSwitched $why
        }
    }

    # --diag stops here. $plan holds no token yet and the registry is untouched,
    # so the probe log printed while resolving is the whole output.
    if ($diag) {
        Write-Output ('--- diag ' + $name + ' (registry untouched) ---')
        foreach ($k in @($plan.Keys)) { Write-Output ('  ' + $k + '=' + [string]$plan[$k]) }
        exit 0
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
