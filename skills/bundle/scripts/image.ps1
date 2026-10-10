# Generate one image through the traxnode-image key and save it locally.
# Windows port of image.sh, for runtimes with no bash. Same options, same output.
# Needs only PowerShell and curl.exe.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File image.ps1 [-k <claude|opencode>] [-d <dir>] [-m <model>] <prompt...>
#   powershell -NoProfile -ExecutionPolicy Bypass -File image.ps1 --list
#
# -k picks where the key comes from. claude (default) reads
# bundles\traxnode-image.local.json; opencode reads opencode's auth.json under
# "traxnode-image". The two stores are independent. -d <dir> saves there instead
# of ~\Pictures\opencode-images. -m <model> picks the model, default
# gpt-image-2.5-sunburst. Options and values must not contain spaces: the words
# after each option are taken one by one, so a single quoted
# "-k <src> -d <dir> -m <model> <prompt>" argument parses too.
#
# Before generating, the model is checked against the key's /models list (free).
# A model missing there fails at once. A listed model can still fail upstream;
# that error is reported as is.
#
# The base URL comes from bundles\traxnode-image.json.
#
# This script ALWAYS exits 0, so a failure reaches the caller as
# `IMAGE FAILED - <reason>` on stdout instead of an aborted command.

Add-Type -AssemblyName System.Web.Extensions
$Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Json.MaxJsonLength = [int]::MaxValue

$Auth = Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'
$KeyFile = Join-Path $env:USERPROFILE '.claude\bundles\traxnode-image.local.json'
$Profile = Join-Path $env:USERPROFILE '.claude\bundles\traxnode-image.json'
$OutDir = Join-Path $env:USERPROFILE 'Pictures\opencode-images'
$Model = 'gpt-image-2.5-sunburst'
$KeySource = 'claude'
$ListOnly = $false
$Tmp = Join-Path $env:TEMP ('image-' + [guid]::NewGuid().ToString('N'))

function Read-Json([string]$Path) {
    return $Json.DeserializeObject((Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop))
}

function Fail([string]$Reason) {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output ''
    Write-Output "IMAGE FAILED - $Reason"
    Write-Output ''
    exit 0
}

# Consume leading options one word at a time; what remains is the prompt.
$rest = ($args -join ' ').Trim()
while ($true) {
    if ($rest -match '^-d\s+(\S+)\s*(.*)$') {
        $dir = $matches[1]
        if ($dir.StartsWith('~')) { $dir = $env:USERPROFILE + $dir.Substring(1) }
        $OutDir = $dir
        $rest = $matches[2]
    } elseif ($rest -match '^-d\s*$') {
        Fail '-d needs a directory'
    } elseif ($rest -match '^-m\s+(\S+)\s*(.*)$') {
        $Model = $matches[1]
        $rest = $matches[2]
    } elseif ($rest -match '^-m\s*$') {
        Fail '-m needs a model id'
    } elseif ($rest -match '^-k\s+(\S+)\s*(.*)$') {
        $KeySource = $matches[1]
        $rest = $matches[2]
    } elseif ($rest -match '^-k\s*$') {
        Fail '-k needs claude or opencode'
    } elseif ($rest -match '^--list\s*(.*)$') {
        $ListOnly = $true
        $rest = $matches[1]
    } else {
        break
    }
}
if ($KeySource -notin @('claude', 'opencode')) { Fail "-k must be claude or opencode, not $KeySource" }
$Prompt = $rest
if (-not $ListOnly -and -not $Prompt) { Fail 'usage: image.ps1 [-k <claude|opencode>] [-d <dir>] [-m <model>] <prompt>' }

if (-not (Test-Path -LiteralPath $Profile)) { Fail "no bundle file: $Profile" }
try { $Base = [string]((Read-Json $Profile)['opencode']['baseURL']) } catch { $Base = '' }
if (-not $Base) { Fail "$Profile has no opencode.baseURL" }
if ($KeySource -eq 'opencode') {
    try { $Key = [string]((Read-Json $Auth)['traxnode-image']['key']) } catch { $Key = '' }
    if (-not $Key) { Fail "$Auth has no key under `"traxnode-image`"" }
} else {
    try { $Key = [string]((Read-Json $KeyFile)['key']) } catch { $Key = '' }
    if (-not $Key) { Fail "$KeyFile is missing or has no `"key`" field. Create it as {`"key`": `"<key>`"}" }
}

New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

# The image models this key can see. Listing is free; generating is not.
$ModelsFile = Join-Path $Tmp 'models.json'
$Code = & curl.exe -s --max-time 60 -o $ModelsFile -w '%{http_code}' "$Base/models" -H "Authorization: Bearer $Key"
if ($Code -ne '200') { Fail "could not read $Base/models: HTTP $Code" }
$Ids = @((Read-Json $ModelsFile)['data'] | ForEach-Object { [string]$_['id'] } | Where-Object { $_ -match 'image' })

if ($ListOnly) {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    $Ids | ForEach-Object { Write-Output $_ }
    exit 0
}
if ($Ids -notcontains $Model) {
    Fail "model $Model is not listed for this key. Image models: $($Ids -join ' ')"
}

$BodyFile = Join-Path $Tmp 'body.json'
$Body = @{ model = $Model; prompt = $Prompt; size = '1024x1024'; quality = 'medium'; n = 1 }
[System.IO.File]::WriteAllText($BodyFile, $Json.Serialize($Body), (New-Object System.Text.UTF8Encoding $false))

$RespFile = Join-Path $Tmp 'resp.json'
$Code = & curl.exe -s --max-time 300 -o $RespFile -w '%{http_code}' -X POST "$Base/images/generations" `
    -H "Authorization: Bearer $Key" -H 'content-type: application/json' --data-binary "@$BodyFile"
if ($Code -ne '200') {
    $Text = (Get-Content -LiteralPath $RespFile -Raw -Encoding UTF8) -replace '\s+', ' '
    if ($Text.Length -gt 300) { $Text = $Text.Substring(0, 300) }
    Fail "HTTP $Code from ${Model}: $Text. Try another -m; see --list"
}

$Item = (Read-Json $RespFile)['data'][0]
$Url = [string]$Item['url']
$B64 = [string]$Item['b64_json']
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Dest = Join-Path $OutDir ('{0}-{1}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 100000))
if ($B64) {
    [System.IO.File]::WriteAllBytes($Dest, [Convert]::FromBase64String($B64))
} elseif ($Url) {
    & curl.exe -s --max-time 120 -o $Dest $Url
    if ($LASTEXITCODE -ne 0) { Fail 'could not download the image' }
} else {
    Fail 'response had neither url nor b64_json'
}

Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "image saved: $Dest"
Write-Output ''
exit 0
