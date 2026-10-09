<#
.SYNOPSIS
    Bridges two Orca-managed agents: a Claude Code planner/reviewer and an
    OpenCode implementer. Polls Orca's own agent state to detect when the
    implementer finishes a turn, then routes the next instruction.

.DESCRIPTION
    The watcher owns no intelligence. It only:
      1. detects implementer turn boundaries from `orca worktree ps`,
      2. reads the handover documents on disk,
      3. types the next instruction into the receiving terminal.

    All judgment (plan quality, review verdicts) lives in the handover
    documents, so the watcher stays a dumb, restartable transport. That split
    matters: if the watcher dies mid-run it can be restarted and will resume
    from the files without losing the conversation.

    Handover directory layout (all files are the agents' own writing):
      PLAN.md            planner writes. First line must be the team-skill directive.
      IMPLEMENTATION.md  implementer writes when its turn completes.
      REVIEW.md          reviewer writes. First line is the verdict token.
      state.json         watcher-owned. Resume point after a restart.

    State machine:
      planned      -> PLAN.md exists, nothing sent yet      -> send plan to implementer
      implementing-> implementer is working                -> wait
      delivered   -> implementer done + IMPLEMENTATION.md  -> ask reviewer to review
      reviewing   -> REVIEW.md exists, verdict changes-... -> send review to implementer
      approved    -> exit 0

    Termination: the watcher exits on an APPROVED verdict, on exceeding
    MaxRounds, or on Ctrl+C. It never merges, pushes, or touches git.

.PARAMETER Feature
    Short feature slug. Used for the handover directory name and log lines.

.PARAMETER HandoverDir
    Absolute path to the handover directory. Created if absent.

.PARAMETER ImplementerWorktreePath
    Absolute path of the worktree the OpenCode agent works in. Used to discover
    its terminal handle when -ImplementerTerminal is not given.

.PARAMETER ImplementerTerminal
    Orca terminal handle of the OpenCode agent. Discovered when omitted.

.PARAMETER ReviewerTerminal
    Orca terminal handle of the Claude Code agent. Discovered when omitted.

.PARAMETER ReviewerWorktreePath
    Worktree the reviewer works in, i.e. the checkout under review. The watcher
    infers it from its own working directory when omitted. Pin it explicitly when
    the watcher is launched from outside the repo, or the review prompt would
    carry a relative `git -C` path that resolves against the wrong directory.

.PARAMETER PollSeconds
    Seconds between state polls. Keep this modest; Orca's state is pushed, not
    queried, so polling is cheap.

.PARAMETER MaxRounds
    Safety stop. Prevents an approve/reject loop from burning tokens forever.

.PARAMETER StallMinutes
    Warn (do not exit) when a phase makes no progress for this long. A silent
    implementer is usually a permission prompt waiting for a human, and killing
    the watcher there would strand the work.

.PARAMETER Once
    Run a single poll, log the observed state, and exit. Use this to verify the
    watcher can read Orca state before trusting it with a live run.

.EXAMPLE
    .\watcher.ps1 -Feature update-check -HandoverDir C:\repo\.orca\team\update-check -Once

.EXAMPLE
    .\watcher.ps1 -Feature update-check -HandoverDir C:\repo\.orca\team\update-check -ImplementerWorktreePath C:\repo-wt\update-check
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Feature,
    [Parameter(Mandatory = $true)][string]$HandoverDir,

    [string]$ImplementerWorktreePath = '',
    [string]$ImplementerTerminal = '',
    [string]$ReviewerTerminal = '',
    [string]$ReviewerWorktreePath = '',

    [int]$PollSeconds = 5,
    [int]$MaxRounds = 5,
    [int]$StallMinutes = 45,

    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:LogPath   = Join-Path $HandoverDir 'watcher.log'
$script:StatePath = Join-Path $HandoverDir 'state.json'

# --- paths -----------------------------------------------------------------

$script:PlanPath           = Join-Path $HandoverDir 'PLAN.md'
$script:ImplementationPath = Join-Path $HandoverDir 'IMPLEMENTATION.md'
$script:ReviewPath         = Join-Path $HandoverDir 'REVIEW.md'

# The planner must open the plan with a directive that makes the implementer
# load the team skill before touching anything. Verifying it here rather than
# trusting the prose keeps a malformed plan from reaching the implementer.
$script:RequiredPlanDirective = 'Read and follow the "team" skill'

# --- logging ---------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'STATE')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STATE' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

# --- orca plumbing ---------------------------------------------------------

function Invoke-OrcaJson {
    param([Parameter(Mandatory)][string[]]$OrcaArgs)

    # Do not read orca's stdout through the PowerShell pipeline. The console
    # codepage here is not UTF-8, so the pipeline misreads the box-drawing and
    # emoji characters that agent previews contain, corrupts them into
    # replacement bytes, and truncates JSON string literals mid-escape.
    # Redirecting to a file and decoding as UTF-8 keeps the payload intact.
    $orcaExe = (Get-Command orca -ErrorAction Stop).Source

    # Start-Process joins ArgumentList with spaces and does not quote for us.
    $quoted = @($OrcaArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $orcaExe -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $raw = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)

        if ($proc.ExitCode -ne 0) {
            $errText = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
            throw "orca $($OrcaArgs -join ' ') exited $($proc.ExitCode): $errText"
        }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "orca $($OrcaArgs -join ' ') returned no output"
        }

        return $raw | ConvertFrom-Json
    }
    catch {
        if ($_.Exception.Message -notmatch 'ConvertFromJson|JSON') {
            throw "orca $($OrcaArgs -join ' ') failed: $($_.Exception.Message)"
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Reads every agent Orca currently tracks, flattened across worktrees.
.DESCRIPTION
    `orca worktree ps` is the only state source that distinguishes an
    implementer that finished from one that is blocked on a permission prompt:
    each agent carries `state` (working/done) and `lastAssistantMessage`.
#>
function Get-ObservedAgents {
    $response = Invoke-OrcaJson -OrcaArgs @('worktree', 'ps', '--limit', '20', '--json')
    if (-not $response.ok) {
        throw "orca worktree ps reported failure: $($response | ConvertTo-Json -Depth 5 -Compress)"
    }

    $observed = @()
    foreach ($wt in $response.result.worktrees) {
        foreach ($agent in @($wt.agents)) {
            if ($null -eq $agent) { continue }

            # mainAgent.state is the root session's state; the flat state can
            # reflect a finished child while the root is still going. Prefer the
            # root, fall back for runtimes that omit it.
            $state = $agent.state
            if ($agent.PSObject.Properties.Name -contains 'mainAgent' -and
                $null -ne $agent.mainAgent -and
                $agent.mainAgent.PSObject.Properties.Name -contains 'state' -and
                $agent.mainAgent.state) {
                $state = $agent.mainAgent.state
            }

            $observed += [pscustomobject]@{
                AgentType             = [string]$agent.agentType
                State                 = [string]$state
                LastAssistantMessage  = [string]$agent.lastAssistantMessage
                WorktreePath          = [string]$wt.path
                WorktreeDisplayName   = [string]$wt.displayName
            }
        }
    }
    return $observed
}

function Get-ImplementerState {
    $agents = @(Get-ObservedAgents | Where-Object { $_.AgentType -eq 'opencode' })

    if ($ImplementerWorktreePath) {
        $wanted = ConvertTo-ComparablePath $ImplementerWorktreePath
        $scoped = @($agents | Where-Object {
            (ConvertTo-ComparablePath $_.WorktreePath) -ieq $wanted
        })
        if ($scoped.Count -gt 0) { $agents = $scoped }
    }

    if ($agents.Count -eq 0) {
        Write-Log -Level WARN -Message 'No opencode agent is visible to Orca yet.'
        return $null
    }
    if ($agents.Count -gt 1) {
        Write-Log -Level WARN -Message (
            "{0} opencode agents visible; using the first. Narrow with -ImplementerWorktreePath." -f $agents.Count
        )
    }
    return $agents[0]
}

<#
.SYNOPSIS
    Normalizes a path for comparison against Orca-reported paths.
.DESCRIPTION
    Orca reports worktree paths with forward slashes on Windows, while a path
    typed by a user or taken from Get-Location uses backslashes. Comparing the
    raw strings silently fails to match, so both sides go through here first.
#>
function ConvertTo-ComparablePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
    }
    catch {
        return $Path.TrimEnd('\', '/')
    }
}

<#
.SYNOPSIS
    Resolves an Orca terminal handle by agent identity.
.DESCRIPTION
    When several terminals report the same agentIdentity, an unscoped lookup
    would pick whichever the CLI happens to list first. That is wrong for the
    reviewer: it must be the Claude Code agent in the repo under review, not one
    in an unrelated checkout. So the reviewer is scoped to the watcher's own
    worktree by default.
#>
function Resolve-TerminalHandle {
    param(
        [Parameter(Mandatory)][string]$AgentIdentity,
        [string]$WorktreePath = ''
    )

    $response = Invoke-OrcaJson -OrcaArgs @('terminal', 'list', '--limit', '50', '--json')
    if (-not $response.ok) { throw 'orca terminal list reported failure' }

    # A plain shell terminal reports no agentIdentity, and Set-StrictMode makes reading the
    # absent property an error rather than $null -- which would kill every lookup, not just
    # that one terminal's. So presence is tested before the value is read.
    $matches = @($response.result.terminals | Where-Object {
        ($_.PSObject.Properties.Name -contains 'agentIdentity') -and
        $_.agentIdentity -eq $AgentIdentity -and -not $_.orphaned -and $_.connected
    })

    if ($WorktreePath) {
        $wanted = ConvertTo-ComparablePath $WorktreePath
        $scoped = @($matches | Where-Object {
            (ConvertTo-ComparablePath $_.worktreePath) -ieq $wanted
        })
        # Falling back to an unscoped match would silently route the review to a
        # different checkout, so an empty scoped set is an error here, not a cue
        # to relax the filter.
        if ($scoped.Count -eq 0) {
            throw ("No connected '$AgentIdentity' terminal in '$WorktreePath'. " +
                "Start the $AgentIdentity agent in that worktree and let it register with Orca, then rerun.")
        }
        if ($scoped.Count -gt 1) {
            Write-Log -Level WARN -Message (
                "{0} '{1}' terminals in '{2}'; using {3}." -f
                $scoped.Count, $AgentIdentity, $WorktreePath, $scoped[0].handle
            )
        }
        return [string]$scoped[0].handle
    }

    if ($matches.Count -eq 0) {
        throw "No connected terminal reports agentIdentity '$AgentIdentity'"
    }
    if ($matches.Count -gt 1) {
        Write-Log -Level WARN -Message (
            "{0} '{1}' terminals visible and no worktree scope given; using {2}. " +
            'Pass -ReviewerWorktreePath to pin it.' -f $matches.Count, $AgentIdentity, $matches[0].handle
        )
    }
    return [string]$matches[0].handle
}

function Send-ToTerminal {
    param(
        [Parameter(Mandatory)][string]$Handle,
        [Parameter(Mandatory)][string]$Text,
        [string]$Label = 'agent'
    )

    Write-Log -Level INFO -Message "Sending to ${Label} (${Handle}): $($Text -replace '\s+', ' ')"

    $response = Invoke-OrcaJson -OrcaArgs @(
        'terminal', 'send',
        '--terminal', $Handle,
        '--text', $Text,
        '--enter',
        '--wait-submit', '20',
        '--json'
    )

    if (-not $response.ok) {
        throw "terminal send to ${Label} failed: $($response | ConvertTo-Json -Depth 5 -Compress)"
    }
    Write-Log -Level INFO -Message "Delivered to ${Label}."
}

# --- handover documents ----------------------------------------------------

function Get-Verdict {
    if (-not (Test-Path -LiteralPath $script:ReviewPath)) { return $null }

    $firstLine = (Get-Content -LiteralPath $script:ReviewPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if (-not $firstLine) { return $null }
    return $firstLine.Trim().TrimStart('#').Trim().ToUpperInvariant()
}

function Test-PlanIsWellFormed {
    if (-not (Test-Path -LiteralPath $script:PlanPath)) { return $false }

    $firstLine = (Get-Content -LiteralPath $script:PlanPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if (-not $firstLine) { return $false }

    if ($firstLine -notlike "*$($script:RequiredPlanDirective)*") {
        Write-Log -Level ERROR -Message (
            "PLAN.md does not open with the required directive. First line was: '$firstLine'. " +
            "The implementer would skip the team skill, so the plan is held back."
        )
        return $false
    }
    return $true
}

# --- watcher state ---------------------------------------------------------

function Read-WatcherState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{
            phase              = 'planned'
            round              = 0
            lastVerdict        = ''
            planSent           = $false
            reviewRequested    = $false
            phaseEnteredAt     = (Get-Date).ToString('o')
        }
    }

    try {
        return Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log -Level WARN -Message "state.json is unreadable; restarting the state machine. $($_.Exception.Message)"
        return [pscustomobject]@{
            phase = 'planned'; round = 0; lastVerdict = ''
            planSent = $false; reviewRequested = $false
            phaseEnteredAt = (Get-Date).ToString('o')
        }
    }
}

function Write-WatcherState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Phase)

    $State.phase          = $Phase
    $State.phaseEnteredAt = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StatePath -Encoding utf8
    Write-Log -Level STATE -Message "phase -> $Phase (round $($State.round))"
}

# --- prompts ---------------------------------------------------------------

function New-PlanPrompt {
    @"
The plan for feature '$Feature' is ready at:
  $script:PlanPath

$($script:RequiredPlanDirective) before you change anything.

Work only inside your own worktree ($ImplementerWorktreePath). Do not touch the
reviewer's checkout. Follow the plan's constraints and forbidden items exactly;
where the plan and your own judgement disagree, say so in your report rather
than silently deviating.

When the implementation is complete, write your report to:
  $script:ImplementationPath

The report must state which files you changed, which acceptance criteria from
the plan you verified, the exact commands you ran with their results, and
anything you could not finish. An honest partial report is far more useful to
the reviewer than a confident one that hides a gap.

Do not merge, push, or open a pull request. The reviewer decides the next step.
"@
}

function New-ReviewPrompt {
    @"
The implementer for feature '$Feature' reports its work is complete.

  Implementation report: $script:ImplementationPath
  Feature worktree:     $ImplementerWorktreePath

Review it from your own checkout ($ReviewerWorktreePath). Read the diff with:

  git -C "$ReviewerWorktreePath" diff main...$Feature

Run /code-review for the automated pass, then apply your own judgement on top of
it — the automated findings are input, not the verdict.

Write your review to:
  $script:ReviewPath

The first line of that file must be exactly one of:
  APPROVED
  CHANGES REQUESTED

Then list the findings. For each one, name the file and line, say what is wrong,
and state the change required. If you request changes, be specific enough that
the implementer can act without guessing what you meant.

If you approve, say so plainly and note anything a human should still check
before this ships. Do not merge anything yourself.
"@
}

function New-ChangesPrompt {
    $verdict = (Get-Content -LiteralPath $script:ReviewPath -Raw)
    @"
The reviewer requested changes on feature '$Feature'.

  Review: $script:ReviewPath

$verdict

Address every finding. Where you disagree with a finding, implement the rest and
explain your objection in the updated report at:
  $script:ImplementationPath

Then stop and wait. The watcher will route your next report to the reviewer.
"@
}

# --- main loop -------------------------------------------------------------

New-Item -ItemType Directory -Path $HandoverDir -Force | Out-Null
Write-Log -Level INFO -Message "watcher start: feature='$Feature' handover='$HandoverDir'"

if (-not $ReviewerWorktreePath) {
    # Default to the checkout the watcher was started from: that is the repo
    # under review, and it keeps the review prompt's `git -C` path correct.
    $ReviewerWorktreePath = (Get-Location).ProviderPath
    Write-Log -Level INFO -Message "Reviewer worktree defaults to current directory: $ReviewerWorktreePath"
}

try {
    if (-not $ImplementerTerminal) {
        $ImplementerTerminal = Resolve-TerminalHandle -AgentIdentity 'opencode' -WorktreePath $ImplementerWorktreePath
        Write-Log -Level INFO -Message "Resolved implementer terminal: $ImplementerTerminal"
    }
    if (-not $ReviewerTerminal) {
        $ReviewerTerminal = Resolve-TerminalHandle -AgentIdentity 'claude' -WorktreePath $ReviewerWorktreePath
        Write-Log -Level INFO -Message "Resolved reviewer terminal: $ReviewerTerminal"
    }
}
catch {
    Write-Log -Level ERROR -Message "Cannot resolve terminals: $($_.Exception.Message)"
    exit 2
}

$state = Read-WatcherState

if ($Once) {
    $agents = @(Get-ObservedAgents)
    Write-Log -Level INFO -Message "Observed $($agents.Count) agent(s):"
    foreach ($a in $agents) {
        Write-Log -Level INFO -Message ("  {0,-8} {1,-8} {2}" -f $a.AgentType, $a.State, $a.WorktreePath)
    }
    Write-Log -Level INFO -Message "phase=$($state.phase) round=$($state.round)"
    exit 0
}

Write-Log -Level INFO -Message "resuming at phase=$($state.phase) round=$($state.round)"

while ($true) {
    try {
        $implementer = Get-ImplementerState
    }
    catch {
        Write-Log -Level ERROR -Message "Poll failed: $($_.Exception.Message)"
        Start-Sleep -Seconds ($PollSeconds * 2)
        continue
    }

    $phaseEntered = [datetime]::MinValue
    [void][datetime]::TryParse($state.phaseEnteredAt, [ref]$phaseEntered)
    if ($phaseEntered -eq [datetime]::MinValue) { $phaseEntered = Get-Date }
    $idleMinutes = ((Get-Date) - $phaseEntered).TotalMinutes

    if ($idleMinutes -gt $StallMinutes) {
        # Deliberately a warning, not an exit: the usual cause is a permission
        # prompt waiting for a human, and stopping here would strand the work.
        Write-Log -Level WARN -Message (
            "No progress in phase '$($state.phase)' for $([int]$idleMinutes) min. " +
            'If an agent is blocked on a permission prompt, answer it in that pane; the watcher will resume.'
        )
        Write-WatcherState -State $state -Phase $state.phase | Out-Null
    }

    switch ($state.phase) {

        'planned' {
            if (-not (Test-Path -LiteralPath $script:PlanPath)) {
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if (-not (Test-PlanIsWellFormed)) {
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            Send-ToTerminal -Handle $ImplementerTerminal -Text (New-PlanPrompt) -Label 'implementer'
            $state.round = 1
            Write-WatcherState -State $state -Phase 'implementing'
        }

        'implementing' {
            # Wait for the turn to actually end. Only 'done' counts: OpenCode
            # reports 'waiting' while a tool call is still in flight, and an
            # earlier guard that treated every non-'working' state as finished
            # re-sent the whole plan into a busy pane about fifteen seconds after
            # delivering it. Seen live; do not relax this without new evidence
            # about the state vocabulary.
            if ($null -eq $implementer -or $implementer.State -ne 'done') {
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if (-not (Test-Path -LiteralPath $script:ImplementationPath)) {
                Write-Log -Level WARN -Message (
                    'Implementer went idle without an implementation report; ' +
                    'the turn may have been interrupted. Re-sending the plan.'
                )
                $state.round = 0
                Write-WatcherState -State $state -Phase 'planned'
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            Send-ToTerminal -Handle $ReviewerTerminal -Text (New-ReviewPrompt) -Label 'reviewer'
            $state.reviewRequested = $true
            Write-WatcherState -State $state -Phase 'reviewing'
        }

        'reviewing' {
            $verdict = Get-Verdict
            if (-not $verdict) {
                # Guard against acting on a stale verdict from a previous round.
                if ($state.lastVerdict) {
                    Start-Sleep -Seconds $PollSeconds
                    continue
                }
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if ($verdict -eq $state.lastVerdict) {
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            $state.lastVerdict = $verdict

            if ($verdict -like 'APPROVED*') {
                Write-Log -Level INFO -Message "Reviewer approved feature '$Feature' after $($state.round) round(s)."
                Write-WatcherState -State $state -Phase 'approved'
                Write-Log -Level INFO -Message 'Watcher exiting. Merging is the human''s call; nothing was merged or pushed.'
                exit 0
            }

            if ($verdict -like 'CHANGES REQUESTED*') {
                if ($state.round -ge $MaxRounds) {
                    Write-Log -Level ERROR -Message (
                        "Reached MaxRounds ($MaxRounds) with changes still requested. " +
                        'Stopping so a human can look at the pattern instead of another round.'
                    )
                    Write-WatcherState -State $state -Phase 'exhausted'
                    exit 3
                }
                Send-ToTerminal -Handle $ImplementerTerminal -Text (New-ChangesPrompt) -Label 'implementer'
                $state.round++
                Write-WatcherState -State $state -Phase 'implementing'
                continue
            }

            Write-Log -Level WARN -Message "Unrecognized verdict '$verdict'; expected APPROVED or CHANGES REQUESTED."
            Start-Sleep -Seconds $PollSeconds
        }

        default {
            Write-Log -Level ERROR -Message "Unknown phase '$($state.phase)'; stopping."
            exit 4
        }
    }

    Start-Sleep -Seconds $PollSeconds
}