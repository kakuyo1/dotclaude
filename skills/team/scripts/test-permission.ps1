<#
.SYNOPSIS
    Self-check for permission.ps1. Run it after any change to the permission policy.
.DESCRIPTION
    Builds dialogs in the shape OpenCode shows and checks the parse and the decision.
    Paths assume the machine this skill was written on (user folder fw1sg2); change
    the roots and the sample paths if the user folder differs.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'permission.ps1')

$script:failures = 0
function Assert-Equal {
    param($Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL ${Name}: expected '$Expected', got '$Actual'"
        $script:failures++
    }
}

# Symbols the dialog draws, built from code points so this file stays ASCII.
$bar   = [char]0x2503
$arrow = [char]0x2190
$tri   = [char]0x25B3

function New-Dialog {
    param([string]$Action, [string[]]$Patterns = @(), [switch]$NoOptionBar)

    $lines = @('  Build - Space Bunny Free', '', "  $tri Permission required", "  $arrow $Action", '', 'Patterns')
    $lines += @($Patterns | ForEach-Object { "  - $_" })
    if (-not $NoOptionBar) { $lines += '   Allow once   Allow always   Reject   enter confirm' }
    return @($lines | ForEach-Object { "  $bar  $_" })
}

$roots = @(
    'C:/Users/admin/AppData/Local/Temp',
    'C:/Users/admin/.config/opencode',
    'C:/Users/admin/orca/workspaces/team-html-demo/hn-newest-50'
)

# 1. Routine read of the job's own handover folder: approve.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory ~\AppData\Local\Temp\team-html-demo\.orca\team\hn-newest-50' -Patterns 'C:/Users/admin/AppData/Local/Temp/team-html-demo/.orca/team/hn-newest-50/*')
Assert-Equal 'routine read: kind' 'external_directory' $p.Kind
Assert-Equal 'routine read: decision' 'approve' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 2. Sidebar text on the action row is cut off the action.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory ~\AppData\Local\Temp\a          /~\orca\workspaces\b')
Assert-Equal 'sidebar cut: action' 'Access external directory ~\AppData\Local\Temp\a' $p.Action

# 3. Read outside every root: report.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory ~\Documents\notes' -Patterns 'C:/Users/admin/Documents/notes/*')
Assert-Equal 'outside root: decision' 'report' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 4. Destructive command inside the worktree: report.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Run command: rm -rf dist' -Patterns 'C:/Users/admin/orca/workspaces/team-html-demo/hn-newest-50/*')
Assert-Equal 'rm -rf: decision' 'report' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 5. git push: report, even inside the worktree.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Run command: git push origin hn-newest-50' -Patterns 'C:/Users/admin/orca/workspaces/team-html-demo/hn-newest-50/*')
Assert-Equal 'git push: decision' 'report' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 6. Path climbing out with "..": report.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory ~\AppData\Local\Temp\x\..\..\..\Documents' -Patterns 'C:/Users/admin/AppData/Local/Temp/x/../../../Documents/*')
Assert-Equal 'dot-dot climb: decision' 'report' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 7. A Windows drive path to a folder under a /Users root: approve.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory C:/Users/admin/AppData/Local/Temp/team-html-demo/a' -Patterns 'C:\Users\admin\AppData\Local\Temp\team-html-demo\a\*')
Assert-Equal 'drive path under users root: decision' 'approve' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 8. An edit aimed outside the roots, named only in the action: report.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Edit C:/Users/admin/Documents/x.txt')
Assert-Equal 'edit outside root: decision' 'report' (Get-PermissionDecision -Prompt $p -AllowedRoots $roots)

# 9. No dialog on screen: null.
$p = ConvertFrom-PermissionTail -Lines @('  Build - Space Bunny Free', '  writing the report')
Assert-Equal 'no dialog: null' $true ($null -eq $p)

# 10. A "Permission required" line without the option bar is not a live dialog: null.
$p = ConvertFrom-PermissionTail -Lines (New-Dialog -Action 'Access external directory ~\AppData\Local\Temp\a' -NoOptionBar)
Assert-Equal 'no option bar: null' $true ($null -eq $p)

# 11. An empty root must not match every path.
Assert-Equal 'empty root ignored' $false (Test-PathInsideRoot -Path 'C:/Users/admin/Documents/x' -Roots @(''))

# 12. A root written with a drive letter matches a /Users path beneath it: approve.
Assert-Equal 'drive root matches users path' $true (Test-PathInsideRoot -Path 'C:/Users/admin/AppData/Local/Temp/a' -Roots @('C:\Users\admin\AppData\Local\Temp'))

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed."
    exit 1
}
Write-Host 'All permission checks passed.'
exit 0
