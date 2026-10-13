<#
.SYNOPSIS
    Permission-prompt triage for OpenCode implementers. Dot-sourced by watcher.ps1.
.DESCRIPTION
    OpenCode holds a turn on a "Permission required" dialog. These functions read that
    dialog from pane lines and decide whether the watcher may approve it or must leave
    it for a person. The policy and its limits are in references/permissions.md.

    Approve: the dialog text is not destructive, and every path it names is inside the
    job's allowed roots. Report: anything else.
#>

# The home folder's name, used to resolve "~" in dialog text.
$script:HomeName = Split-Path -Leaf $env:USERPROFILE

# Commands that delete, stop, reset, or publish. Matched case-insensitively.
$script:DestructivePattern = '(?i)(\brm\b|\brmdir\b|\bdel\b|\bunlink\b|\bdelete\b|Remove-Item|\bkill\b|taskkill|Stop-Process|\bshutdown\b|\bformat\b|git\s+(push|reset|clean|rebase|checkout\s+--|branch\s+-D|tag\s+-d|worktree\s+remove|stash\s+(drop|clear))|curl\b.*-X\s*(POST|PUT|PATCH|DELETE))'

<#
.SYNOPSIS
    Parses the newest live "Permission required" dialog from pane lines, or returns $null.
.DESCRIPTION
    Pane lines carry a box border and, on some rows, a right-hand sidebar. The border is
    stripped here; the sidebar is cut where the action path ends, at two or more spaces.
    A dialog counts as live only when its option bar ("Allow once") is present.
#>
function ConvertFrom-PermissionTail {
    param([string[]]$Lines)

    $clean = @($Lines | ForEach-Object { ($_ -replace '^[\s\u2503]+', '').TrimEnd() })

    $start = -1
    for ($i = 0; $i -lt $clean.Count; $i++) {
        if ($clean[$i] -match 'Permission required') { $start = $i }
    }
    if ($start -lt 0) { return $null }

    $dialog = @($clean[$start..($clean.Count - 1)])
    if (@($dialog | Where-Object { $_ -match 'Allow once' }).Count -eq 0) { return $null }

    $actionLine = @($dialog | Where-Object { $_ -match '\u2190' }) | Select-Object -First 1
    if (-not $actionLine) { return $null }
    $action = if ($actionLine -match '\u2190\s*(\S.*?)(\s{2,}|$)') { $Matches[1] } else { $actionLine }

    $patterns = @($dialog | Where-Object { $_ -match '^-\s+\S' } | ForEach-Object {
        if ($_ -match '^-\s+(\S+)') { $Matches[1] }
    })

    [pscustomobject]@{
        Action   = $action
        Patterns = $patterns
        Kind     = if ($action -match 'external directory') { 'external_directory' } else { 'other' }
        Key      = "$action|$($patterns -join ',')"
    }
}

<#
.SYNOPSIS
    Normalizes a path so the /Users/<name> form and the C:\Users\<name> form compare equal.
.DESCRIPTION
    Lowercases, uses forward slashes, drops a trailing glob or slash, expands "~" to the
    current user's home, and reduces the result to users/<name>/... for any home path.
#>
function ConvertTo-PermissionPath {
    param([Parameter(Mandatory)][string]$Path)

    $p = $Path.Trim().Trim('"').Replace('\', '/').TrimEnd('*').TrimEnd('/').ToLowerInvariant()
    if ($p.StartsWith('~/')) { $p = "/users/$($script:HomeName.ToLowerInvariant())" + $p.Substring(1) }
    if ($p -match '^(?:[a-z]:)?/?(users/[^/]+(?:/.*)?)$') { return $Matches[1] }
    return $p
}

<#
.SYNOPSIS
    Returns $true when a path is one of the roots or lies beneath one.
.DESCRIPTION
    A ".." segment is refused outright: it can climb out of a root after the prefix
    check has passed. An empty root is skipped, because it would match every path.
#>
function Test-PathInsideRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Roots)

    $p = ConvertTo-PermissionPath -Path $Path
    if ($p -match '(^|/)\.\.(/|$)') { return $false }
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $r = ConvertTo-PermissionPath -Path $root
        if ($p -eq $r -or $p.StartsWith("$r/")) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Returns 'approve' for a routine dialog and 'report' for one a person must decide.
#>
function Get-PermissionDecision {
    param([Parameter(Mandatory)]$Prompt, [Parameter(Mandatory)][AllowEmptyString()][string[]]$AllowedRoots)

    $text = "$($Prompt.Action) $($Prompt.Patterns -join ' ')"
    if ($text -match $script:DestructivePattern) { return 'report' }

    $paths = @($Prompt.Patterns)
    $paths += @([regex]::Matches($Prompt.Action, '(?:/Users/|~\\|[A-Za-z]:\\)\S+') | ForEach-Object { $_.Value })
    if ($Prompt.Kind -eq 'external_directory') {
        $paths += ($Prompt.Action -replace '^Access external directory\s*', '')
    }

    foreach ($path in $paths) {
        if (-not (Test-PathInsideRoot -Path $path -Roots $AllowedRoots)) { return 'report' }
    }
    return 'approve'
}
