<#
.SYNOPSIS
    Bridges Orca-managed agents for up to five jobs: one OpenCode implementer per
    job, and optionally one Claude Code reviewer pane. Polls Orca's agent state once
    per tick, advances every job, approves routine OpenCode permission dialogs, and
    reports the destructive ones.

.DESCRIPTION
    The watcher owns no intelligence. It only:
      1. detects implementer turn boundaries and reviewer availability from `orca worktree ps`,
      2. reads the handover documents on disk,
      3. types the next instruction into the receiving terminal.

    All judgment (plan quality, review verdicts) lives in the handover documents,
    so the watcher stays a dumb, restartable transport. If it dies mid-run, rerun
    it with the same jobs file and every job resumes from its state.json.

    One process runs every job, with no threads. Each tick reads Orca's state once,
    then advances each job in turn. A job waits only on its own files and on Orca's
    state, never on another job.

    Reviewer. The orchestrator reviews by default: a job that needs review or help is
    logged as ACTION and waits, in phase reviewing or helping, until its file changes.
    When a reviewer pane is pinned with -ReviewerTerminal, requests are typed into it
    one at a time, help requests first.

    Permissions. While an implementer reports 'waiting', the watcher reads its pane. A
    "Permission required" dialog is approved with Enter (Allow once) unless its text is
    destructive or names a path outside the job's allowed roots. Those are logged as
    NEEDS YOU and left for a person. See references/permissions.md.

    Delivery is verified for implementers: every prompt to an implementer is followed
    by a check that its turn started. The reviewer is not verified this way; a stuck
    reviewer shows up as a stall warning on the job waiting for it.

    Handover layout, per job, under <team-root>\<slug>\ (team-root is the folder
    holding the jobs file, normally <main-repo>\.orca\team):
      PLAN.md            planner writes. First line must be the team-skill directive.
      IMPLEMENTATION.md  implementer writes when its turn completes.
      REVIEW.md          reviewer writes. First line is the verdict token.
      HELP.md            implementer writes requests; reviewer (as helper) writes answers.
      state.json         watcher-owned. Resume point after a restart.
    Run-level, in team-root: jobs.json (input) and watcher.log (every job's lines are tagged with its slug).

    State machine (per job):
      planned        -> PLAN.md well-formed                 -> send plan                 -> implementing
      implementing   -> implementer done, HELP.md request   -> help-queued
      implementing   -> implementer done, report is newer   -> review-queued
      help-queued    -> pinned pane sent, or logged for the orchestrator -> helping
      helping        -> HELP.md solution is last            -> send solution             -> implementing
      review-queued  -> pinned pane sent, or logged for the orchestrator -> reviewing
      reviewing      -> REVIEW.md verdict                   -> approved, or send changes -> implementing
      approved, exhausted, stopped: terminal

    Exit codes: 0 every job approved. 1 bad jobs file. 2 a terminal could not be
    resolved. 3 at least one job reached MaxRounds or MaxHelp. 4 at least one job hit
    an unknown phase. The watcher exits once every job is terminal. Never merges,
    pushes, or touches git.

.PARAMETER JobsFile
    Path to jobs.json: an array of { "slug": "...", "implementerWorktree": "..." }.
    At most five entries. The folder holding this file is the team root.

.PARAMETER ReviewerWorktreePath
    The checkout the Claude Code reviewer works in: the repo under review.
    Defaults to the current directory; pin it when the watcher is started from elsewhere.

.PARAMETER ReviewerTerminal
    Optional. Orca terminal handle of a reviewer pane. Not resolved automatically: the
    orchestrator's own Claude session sits in the same worktree, so a lookup could pick
    it. Omit it, and reviews and help requests wait for the orchestrator.

.PARAMETER PollSeconds
    Seconds between ticks. Orca's state is pushed, so polling is cheap.

.PARAMETER MaxRounds
    Per job. Stops a job in an approve/reject loop.

.PARAMETER MaxHelp
    Per job. Stops a job that keeps asking for help.

.PARAMETER StallMinutes
    Warn (do not exit) when a job's phase makes no progress for this long.

.PARAMETER Once
    Run a single read, log the observed state, and exit. Use it to check wiring before a live run.

.EXAMPLE
    .\watcher.ps1 -JobsFile C:\repo\.orca\team\jobs.json -ReviewerWorktreePath C:\repo -ReviewerTerminal <handle> -Once
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobsFile,

    [string]$ReviewerWorktreePath = '',
    [string]$ReviewerTerminal = '',

    [int]$PollSeconds = 5,
    [int]$MaxRounds = 5,
    [int]$MaxHelp = 5,
    [int]$StallMinutes = 45,

    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:MaxJobs = 5
$script:TerminalPhases = @('approved', 'exhausted', 'stopped')
$script:LogPath = Join-Path (Split-Path -Parent $JobsFile) 'watcher.log'

# The planner must open each plan with a directive that makes the implementer
# load the team skill before touching anything. Verifying it here rather than
# trusting the prose keeps a malformed plan from reaching the implementer.
$script:RequiredPlanDirective = 'Read and follow the "team" skill'

# Permission-dialog policy: pure functions, checked by test-permission.ps1.
. (Join-Path $PSScriptRoot 'permission.ps1')

# --- logging ---------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'STATE')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        $Job = $null
    )

    $tag = if ($null -ne $Job) { "[$($Job.Slug)] " } else { '' }
    $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $tag, $Message
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
    `orca worktree ps` is the only state source that distinguishes an agent that
    finished from one blocked on a permission prompt: each agent carries `state`
    (working/done) and `lastAssistantMessage`. One call serves every job in a tick.
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

<#
.SYNOPSIS
    Returns one agent's state within a worktree, or $null when Orca cannot see it.
#>
function Get-AgentState {
    param(
        $Agents,
        [Parameter(Mandatory)][string]$AgentType,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $wanted = ConvertTo-ComparablePath $WorktreePath
    $match = @($Agents | Where-Object {
        $_.AgentType -eq $AgentType -and (ConvertTo-ComparablePath $_.WorktreePath) -ieq $wanted
    })
    if ($match.Count -eq 0) { return $null }
    return $match[0].State
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
    would pick whichever the CLI happens to list first. So the lookup is scoped
    to a worktree: each implementer to its job's worktree, the reviewer to the
    repo under review.
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
        # Falling back to an unscoped match would silently route work to a
        # different checkout, so an empty scoped set is an error here.
        if ($scoped.Count -eq 0) {
            throw ("No connected '$AgentIdentity' terminal in '$WorktreePath'. " +
                "Start the $AgentIdentity agent in that worktree and let it register with Orca, then rerun.")
        }
        if ($scoped.Count -gt 1) {
            Write-Log -Level WARN -Message (
                "{0} '{1}' terminals in '{2}'; using {3}. Pin it with -ReviewerTerminal if that is the wrong one." -f
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
            "{0} '{1}' terminals visible and no worktree scope given; using {2}." -f
            $matches.Count, $AgentIdentity, $matches[0].handle
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
    # `ok` means the keystrokes were accepted, not that they were submitted:
    # Orca answers `input was accepted, but this provider cannot report delivery`
    # for a message that never leaves the input box. Delivery to an implementer is
    # therefore proven by its turn starting -- see Test-TurnPending.
    Write-Log -Level INFO -Message "Sent to ${Label} (acceptance only; delivery unconfirmed by Orca)."
}

# --- handover documents ----------------------------------------------------

function Get-Verdict {
    param($Job)

    if (-not (Test-Path -LiteralPath $Job.ReviewPath)) { return $null }

    $firstLine = (Get-Content -LiteralPath $Job.ReviewPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if (-not $firstLine) { return $null }
    return $firstLine.Trim().TrimStart('#').Trim().ToUpperInvariant()
}

function Test-PlanIsWellFormed {
    param($Job)

    if (-not (Test-Path -LiteralPath $Job.PlanPath)) { return $false }

    $firstLine = (Get-Content -LiteralPath $Job.PlanPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if (-not $firstLine) { return $false }

    if ($firstLine -notlike "*$($script:RequiredPlanDirective)*") {
        Write-Log -Level ERROR -Job $Job -Message (
            "PLAN.md does not open with the required directive. First line was: '$firstLine'. " +
            'The implementer would skip the team skill, so the plan is held back.'
        )
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Reads a job's help dialogue as a list of entries, in file order.
.DESCRIPTION
    Only headings in the fixed format are entries; prose under them is ignored.
    Routing uses order, kind and role. The numbers the agents write are for the
    humans reading the file.
#>
function Get-HelpEntries {
    param($Job)

    if (-not (Test-Path -LiteralPath $Job.HelpPath)) { return @() }

    $entries = @()
    foreach ($line in Get-Content -LiteralPath $Job.HelpPath -Encoding utf8) {
        if ($line -match '^##\s+\d+\s*\|\s*(request|solution)\s*\|\s*(implementer|helper)\s*\|') {
            $entries += [pscustomobject]@{ Kind = $Matches[1]; Role = $Matches[2] }
        }
    }
    return $entries
}

function Get-LastHelpEntry {
    param($Job)

    $entries = @(Get-HelpEntries -Job $Job)
    if ($entries.Count -eq 0) { return $null }
    return $entries[-1]
}

# --- job state -------------------------------------------------------------

function New-InitialState {
    [pscustomobject]@{
        phase           = 'planned'
        round           = 0
        lastVerdict     = ''
        reviewRequested = $false
        phaseEnteredAt  = (Get-Date).ToString('o')
    }
}

function Read-JobState {
    param($Job)

    if (-not (Test-Path -LiteralPath $Job.StatePath)) { return New-InitialState }

    try {
        return Get-Content -LiteralPath $Job.StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log -Level WARN -Job $Job -Message "state.json is unreadable; restarting this job's state machine. $($_.Exception.Message)"
        return New-InitialState
    }
}

function Write-JobState {
    param($Job, [Parameter(Mandatory)][string]$Phase)

    $Job.State.phase = $Phase
    $Job.State.phaseEnteredAt = (Get-Date).ToString('o')
    $Job.ResendCount = 0
    $Job.State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Job.StatePath -Encoding utf8
    Write-Log -Level STATE -Job $Job -Message "phase -> $Phase (round $($Job.State.round))"
}

function Get-PhaseEnteredAt {
    param($State)

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$State.phaseEnteredAt, [ref]$parsed)) { return $parsed }
    return Get-Date
}

# --- jobs ------------------------------------------------------------------

function Test-JobEntry {
    param($Entry)

    $names = @($Entry.PSObject.Properties.Name)
    return ($names -contains 'slug') -and ($names -contains 'implementerWorktree') -and
        [bool]$Entry.slug -and [bool]$Entry.implementerWorktree
}

function New-Job {
    param($Entry, [string]$TeamRoot)

    $handover = Join-Path $TeamRoot ([string]$Entry.slug)
    New-Item -ItemType Directory -Path $handover -Force | Out-Null

    [pscustomobject]@{
        Slug                    = [string]$Entry.slug
        ImplementerWorktreePath = [string]$Entry.implementerWorktree
        HandoverDir             = $handover
        StatePath               = Join-Path $handover 'state.json'
        PlanPath                = Join-Path $handover 'PLAN.md'
        ImplementationPath      = Join-Path $handover 'IMPLEMENTATION.md'
        ReviewPath              = Join-Path $handover 'REVIEW.md'
        HelpPath                = Join-Path $handover 'HELP.md'
        ImplementerTerminal     = ''
        AllowedRoots            = @($env:TEMP, (Join-Path $env:USERPROFILE '.config\opencode'), (Join-Path $env:USERPROFILE '.claude\skills'), [string]$Entry.implementerWorktree, $handover)
        Permission              = [pscustomobject]@{ Key = ''; Tries = 0; SentAt = [datetime]::MinValue; ReportedKey = ''; ReportedAt = [datetime]::MinValue }
        State                   = $null
        StartPending            = $null
        ResendCount             = 0
        LastStallWarn           = [datetime]::MinValue
        VerdictWarnedAt         = [datetime]::MinValue
        UndeliveredWarnedAt     = [datetime]::MinValue
    }
}

function Write-PromptNotDeliveredWarning {
    param($Job, [Parameter(Mandatory)][string]$Reason)

    # The condition persists until a human clears the box, so the report is
    # throttled rather than logged on every tick.
    if (((Get-Date) - $Job.UndeliveredWarnedAt).TotalSeconds -lt 60) { return }
    $Job.UndeliveredWarnedAt = Get-Date

    Write-Log -Level ERROR -Job $Job -Message (
        "$Reason Inspect its pane with 'orca terminal read --terminal <handle> --json'. " +
        'A prompt that did not submit is sitting in the input box: clear that box by hand, ' +
        'then the watcher can send again.'
    )
}

function Start-ImplementerTurn {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Phase,
        [ValidateSet('none', 'first', 'next')][string]$RoundMode = 'none',
        [string]$Verdict = ''
    )

    Send-ToTerminal -Handle $Job.ImplementerTerminal -Text $Text -Label "implementer $($Job.Slug)"
    $Job.StartPending = [pscustomobject]@{ Phase = $Phase; RoundMode = $RoundMode; Verdict = $Verdict; SentAt = Get-Date }
}

<#
.SYNOPSIS
    Returns $true while a prompt sent to the implementer has not started its turn.
.DESCRIPTION
    The only proof a prompt reached the implementer is its turn starting: a send
    can leave the text sitting in the input box and still report success. A null
    state means Orca cannot see the agent, which is not evidence either way, so it
    counts as started; Orca's own warning reports that case.
#>
function Test-TurnPending {
    param($Job, $ImplState)

    $pending = $Job.StartPending
    if ($null -eq $pending) { return $false }

    if ($null -eq $ImplState -or $ImplState -ne 'done') {
        $Job.StartPending = $null
        switch ($pending.RoundMode) {
            'first' { $Job.State.round = 1 }
            'next'  { $Job.State.round = [int]$Job.State.round + 1; $Job.State.lastVerdict = $pending.Verdict }
        }
        # A resend keeps its phase, so the resend counter is not reset by it.
        if ($Job.State.phase -ne $pending.Phase) { Write-JobState -Job $Job -Phase $pending.Phase }
        return $false
    }

    if (((Get-Date) - $pending.SentAt).TotalSeconds -lt 45) { return $true }

    # Not started within the window. Clear it; the next tick sends again.
    $Job.StartPending = $null
    Write-PromptNotDeliveredWarning -Job $Job -Reason 'The implementer stayed idle after a prompt was sent.'
    return $true
}

<#
.SYNOPSIS
    Approves routine OpenCode permission dialogs and reports the rest.
.DESCRIPTION
    Runs only while the implementer's state is 'waiting', the state a dialog holds the
    turn in. Enter selects the dialog's default, Allow once. A dialog the policy rejects
    is left alone: the watcher never sends Enter to it.
#>
function Invoke-PermissionMonitor {
    param($Job)

    $read = Invoke-OrcaJson -OrcaArgs @('terminal', 'read', '--terminal', $Job.ImplementerTerminal, '--screen', '--json')
    $prompt = ConvertFrom-PermissionTail -Lines @($read.result.terminal.tail)
    $perm = $Job.Permission
    if ($null -eq $prompt) {
        $perm.Key = ''
        $perm.Tries = 0
        return
    }

    if ((Get-PermissionDecision -Prompt $prompt -AllowedRoots $Job.AllowedRoots) -eq 'report') {
        # Once per dialog, and again only after ten minutes, so an open dialog does not fill the log.
        if ($perm.ReportedKey -ne $prompt.Key -or ((Get-Date) - $perm.ReportedAt).TotalMinutes -gt 10) {
            $perm.ReportedKey = $prompt.Key
            $perm.ReportedAt = Get-Date
            Write-Log -Level WARN -Job $Job -Message (
                "NEEDS YOU: permission not auto-approved: $($prompt.Action). " +
                'Decide it in that pane: Allow once or Reject.'
            )
        }
        return
    }

    # A new dialog starts its own count. The same dialog gets a second Enter only after
    # 15 seconds; after three tries the watcher reports and stops pressing Enter.
    if ($perm.Key -ne $prompt.Key) {
        $perm.Key = $prompt.Key
        $perm.Tries = 0
    }
    if ($perm.Tries -ge 3) {
        if ($perm.ReportedKey -ne $prompt.Key) {
            $perm.ReportedKey = $prompt.Key
            Write-Log -Level ERROR -Job $Job -Message "NEEDS YOU: approval did not clear the prompt: $($prompt.Action). Inspect that pane."
        }
        return
    }
    if ($perm.Tries -gt 0 -and ((Get-Date) - $perm.SentAt).TotalSeconds -lt 15) { return }

    Invoke-OrcaJson -OrcaArgs @('terminal', 'send', '--terminal', $Job.ImplementerTerminal, '--enter', '--json') | Out-Null
    $perm.Tries++
    $perm.SentAt = Get-Date
    Write-Log -Level INFO -Job $Job -Message "Approved once: $($prompt.Action)"
}

# --- per-job tick ----------------------------------------------------------

function Invoke-JobTick {
    param($Job, $Agents)

    if ($Job.State.phase -in $script:TerminalPhases) { return }

    $implState = Get-AgentState -Agents $Agents -AgentType 'opencode' -WorktreePath $Job.ImplementerWorktreePath
    # A dialog holds the turn in 'waiting'. Only then is the pane read.
    if ($implState -eq 'waiting') { Invoke-PermissionMonitor -Job $Job }
    if (Test-TurnPending -Job $Job -ImplState $implState) { return }

    $phaseEntered = Get-PhaseEnteredAt -State $Job.State
    $idleMinutes = ((Get-Date) - $phaseEntered).TotalMinutes
    if ($idleMinutes -gt $StallMinutes -and ((Get-Date) - $Job.LastStallWarn).TotalMinutes -gt $StallMinutes) {
        # Deliberately a warning, not an exit: the usual cause is a permission prompt
        # waiting for a human, and stopping here would strand the work.
        $Job.LastStallWarn = Get-Date
        Write-Log -Level WARN -Job $Job -Message (
            "No progress in phase '$($Job.State.phase)' for $([int]$idleMinutes) min. " +
            'If the implementer is blocked on a dialog reported as NEEDS YOU, answer it in that pane. ' +
            'If the job waits for review, the orchestrator has not written REVIEW.md or HELP.md yet.'
        )
    }

    # Queued jobs wait for the reviewer; Invoke-ReviewerQueue sends them.
    if ($Job.State.phase -in 'help-queued', 'review-queued') { return }

    switch ($Job.State.phase) {
        'planned' {
            if (-not (Test-PlanIsWellFormed -Job $Job)) { return }
            Start-ImplementerTurn -Job $Job -Text (New-PlanPrompt -Job $Job) -Phase 'implementing' -RoundMode 'first'
        }

        'implementing' {
            # Only 'done' ends a turn. OpenCode reports 'waiting' while a tool call is
            # still in flight, and treating that as finished re-sends the plan into a busy pane.
            if ($implState -ne 'done') { return }

            # A request is the implementer stopping to ask, not finishing. It is
            # checked before the report, because a request arrives with no report.
            $last = Get-LastHelpEntry -Job $Job
            if ($null -ne $last -and $last.Kind -eq 'request' -and $last.Role -eq 'implementer') {
                $asked = @(Get-HelpEntries -Job $Job | Where-Object { $_.Kind -eq 'request' }).Count
                if ($asked -gt $MaxHelp) {
                    Write-Log -Level ERROR -Job $Job -Message (
                        "Reached MaxHelp ($MaxHelp) help requests. Stopping this job so a human can read " +
                        'HELP.md instead of another request.'
                    )
                    Write-JobState -Job $Job -Phase 'exhausted'
                    return
                }
                Write-JobState -Job $Job -Phase 'help-queued'
                return
            }

            # The report must be newer than the review that asked for it. Testing only for
            # the file's existence let a change request that never reached the implementer
            # hand the reviewer the previous round's report.
            $report = Get-Item -LiteralPath $Job.ImplementationPath -ErrorAction SilentlyContinue
            $review = Get-Item -LiteralPath $Job.ReviewPath -ErrorAction SilentlyContinue
            $reportAnswersThisRound =
                ($null -ne $report) -and
                (($null -eq $review) -or ($report.LastWriteTime -ge $review.LastWriteTime))

            if (-not $reportAnswersThisRound) {
                Write-PromptNotDeliveredWarning -Job $Job -Reason (
                    "Round $($Job.State.round): the implementer is idle and its report is older than the review."
                )
                if ($Job.ResendCount -lt 2) {
                    $Job.ResendCount++
                    $text = if ($null -ne $review) { New-ChangesPrompt -Job $Job } else { New-PlanPrompt -Job $Job }
                    Start-ImplementerTurn -Job $Job -Text $text -Phase 'implementing'
                }
                return
            }

            Write-JobState -Job $Job -Phase 'review-queued'
        }

        'helping' {
            # The answer is the last entry. The request stays last until the helper writes.
            $last = Get-LastHelpEntry -Job $Job
            if ($null -eq $last -or $last.Kind -ne 'solution' -or $last.Role -ne 'helper') { return }
            Start-ImplementerTurn -Job $Job -Text (New-HelpAnswerPrompt -Job $Job) -Phase 'implementing'
        }

        'reviewing' {
            $verdict = Get-Verdict -Job $Job
            if (-not $verdict) { return }

            # The guard is REVIEW.md's write time against the phase entry, not the verdict
            # text. A verdict older than this review request is a stale copy.
            $reviewFile = Get-Item -LiteralPath $Job.ReviewPath -ErrorAction SilentlyContinue
            if ($null -eq $reviewFile -or $reviewFile.LastWriteTime -le $phaseEntered) { return }

            if ($verdict -like 'APPROVED*') {
                $Job.State.lastVerdict = $verdict
                Write-Log -Level INFO -Job $Job -Message "Reviewer approved after $($Job.State.round) round(s)."
                Write-JobState -Job $Job -Phase 'approved'
                return
            }

            if ($verdict -like 'CHANGES REQUESTED*') {
                if ([int]$Job.State.round -ge $MaxRounds) {
                    Write-Log -Level ERROR -Job $Job -Message (
                        "Reached MaxRounds ($MaxRounds) with changes still requested. " +
                        'Stopping this job so a human can look at the pattern.'
                    )
                    Write-JobState -Job $Job -Phase 'exhausted'
                    return
                }
                Start-ImplementerTurn -Job $Job -Text (New-ChangesPrompt -Job $Job) -Phase 'implementing' -RoundMode 'next' -Verdict $verdict
                return
            }

            # A typo in the first line is a real error, but the file stays put until the
            # reviewer fixes it, so the repeat is throttled rather than logged every tick.
            if (((Get-Date) - $Job.VerdictWarnedAt).TotalSeconds -gt 60) {
                $Job.VerdictWarnedAt = Get-Date
                Write-Log -Level WARN -Job $Job -Message (
                    "Unrecognized verdict '$verdict'; expected APPROVED or CHANGES REQUESTED. Still waiting."
                )
            }
        }

        default {
            Write-Log -Level ERROR -Job $Job -Message "Unknown phase '$($Job.State.phase)'; stopping this job."
            Write-JobState -Job $Job -Phase 'stopped'
        }
    }
}

# --- reviewer queue --------------------------------------------------------

<#
.SYNOPSIS
    Sends the next queued request to the reviewer, if the reviewer is free.
.DESCRIPTION
    A job holds the reviewer from dispatch until its turn ends in a phase change.
    Orca's own state is checked too, so a reviewer already working on something else
    is left alone. Help requests sort ahead of reviews, then by how long they waited.
#>
function Invoke-ReviewerQueue {
    param($Jobs, $Agents)

    $queued = @($Jobs | Where-Object { $_.State.phase -in 'help-queued', 'review-queued' })
    if ($queued.Count -eq 0) { return }

    # Without a pinned pane the orchestrator reviews. Nothing is typed, so there is no
    # queue: each request is logged as ACTION, and the job waits on the file it needs.
    if (-not $script:ReviewerTerminal) {
        foreach ($job in $queued) {
            if ($job.State.phase -eq 'help-queued') {
                Write-Log -Level WARN -Job $job -Message "ACTION: Help requested. Append a solution entry to $($job.HelpPath)."
                Write-JobState -Job $job -Phase 'helping'
            }
            else {
                Write-Log -Level WARN -Job $job -Message "ACTION: Review requested. Read $($job.ImplementationPath), then write $($job.ReviewPath)."
                $job.State.reviewRequested = $true
                Write-JobState -Job $job -Phase 'reviewing'
            }
        }
        return
    }

    if (@($Jobs | Where-Object { $_.State.phase -in 'helping', 'reviewing' }).Count -gt 0) { return }

    $reviewerState = Get-AgentState -Agents $Agents -AgentType 'claude' -WorktreePath $script:ReviewerWorktreePath
    if ($reviewerState -eq 'working') { return }

    $queue = @($Jobs | Where-Object { $_.State.phase -in 'help-queued', 'review-queued' } |
        Sort-Object -Property @{ Expression = { if ($_.State.phase -eq 'help-queued') { 0 } else { 1 } } },
                              @{ Expression = { Get-PhaseEnteredAt -State $_.State } })
    if ($queue.Count -eq 0) { return }

    $job = $queue[0]
    try {
        if ($job.State.phase -eq 'help-queued') {
            Send-ToTerminal -Handle $script:ReviewerTerminal -Text (New-HelpRequestPrompt -Job $job) -Label "reviewer $($job.Slug)"
            Write-JobState -Job $job -Phase 'helping'
        }
        else {
            Send-ToTerminal -Handle $script:ReviewerTerminal -Text (New-ReviewPrompt -Job $job) -Label "reviewer $($job.Slug)"
            $job.State.reviewRequested = $true
            Write-JobState -Job $job -Phase 'reviewing'
        }
    }
    catch {
        Write-Log -Level ERROR -Job $job -Message "Could not send to the reviewer; will retry on the next tick. $($_.Exception.Message)"
    }
}

# --- prompts ---------------------------------------------------------------
# Every prompt names its document by path. The body is never pasted: a path is one
# ASCII line the receiving agent resolves itself, in whatever encoding the file uses.

function New-PlanPrompt {
    param($Job)
    @"
The plan for job '$($Job.Slug)' is ready at:
  $($Job.PlanPath)

$($script:RequiredPlanDirective) before you change anything.

Work only inside your own worktree ($($Job.ImplementerWorktreePath)). Do not touch the
reviewer's checkout. Follow the plan's constraints and forbidden items exactly;
where the plan and your own judgement disagree, say so in your report rather
than silently deviating.

Reading the team skill, this handover directory, and your own OpenCode config is
part of the job: go ahead and read them, without stopping to ask for permission
first.

When the implementation is complete, write your report to:
  $($Job.ImplementationPath)

The report must state which files you changed, which acceptance criteria from
the plan you verified, the exact commands you ran with their results, and
anything you could not finish. An honest partial report is far more useful to
the reviewer than a confident one that hides a gap.

Do not merge, push, or open a pull request. The reviewer decides the next step.
"@
}

function New-ReviewPrompt {
    param($Job)
    @"
The implementer for job '$($Job.Slug)' reports its work is complete.

  Implementation report: $($Job.ImplementationPath)
  Job worktree:          $($Job.ImplementerWorktreePath)

Review this job only, from your own checkout ($($script:ReviewerWorktreePath)). The
implementer commits only when the plan says so, so the subject is the worktree's own diff:

  git -C "$($Job.ImplementerWorktreePath)" status --short
  git -C "$($Job.ImplementerWorktreePath)" diff -M

When a commit is on the branch Orca created for this job, the three-dot form
against main compares it; it compares commits, so it is empty until one exists.
Run /code-review once there is a commit: it reads your own checkout, so it sees
nothing while the work is uncommitted. Automated findings are input, not the
verdict -- apply your own judgement on top of them.

Write your review to:
  $($Job.ReviewPath)

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
    param($Job)
    @"
The reviewer requested changes on job '$($Job.Slug)'.

  Review: $($Job.ReviewPath)

Read that file and address every finding. Where you disagree with a finding,
implement the rest and explain your objection in the updated report at:
  $($Job.ImplementationPath)

Then stop and wait. The watcher will route your next report to the reviewer.
"@
}

function New-HelpRequestPrompt {
    param($Job)
    @"
The implementer for job '$($Job.Slug)' is stuck and asked for help.

  Help dialogue: $($Job.HelpPath)

Read the last entry, which is the request, and the entries before it. Then read the
files it cites, in the implementer's worktree ($($Job.ImplementerWorktreePath)). Read only:
the implementer applies the fix, so do not edit anything there.

Follow the "Answering" section of the team skill's references/help.md. Append your
answer to the same file as one solution entry, in English and plain ASCII, with the
same keyword as the request.

Then stop. The watcher routes your answer to the implementer.
"@
}

function New-HelpAnswerPrompt {
    param($Job)
    @"
The helper answered your help request for job '$($Job.Slug)'.

  Help dialogue: $($Job.HelpPath)

Read the solution entry at the end of that file and apply it, within the plan's
constraints. Where it conflicts with the plan, follow the plan and say so in your
report, as the team skill describes.

Then continue your work. When the implementation is complete, write your report to:
  $($Job.ImplementationPath)
"@
}

# --- startup ---------------------------------------------------------------

if (-not (Test-Path -LiteralPath $JobsFile)) {
    Write-Host "Jobs file not found: $JobsFile" -ForegroundColor Red
    exit 1
}
$teamRoot = Split-Path -Parent $JobsFile

try {
    # Assign, do not pipe: Windows PowerShell 5.1 emits a JSON array as one object[],
    # and @() around the pipeline would wrap that as a single entry.
    $entries = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $JobsFile -Raw)
    $entries = @($entries)
}
catch {
    Write-Log -Level ERROR -Message "Cannot read the jobs file: $($_.Exception.Message)"
    exit 1
}

if ($entries.Count -eq 0) {
    Write-Log -Level ERROR -Message 'The jobs file lists no jobs.'
    exit 1
}
if ($entries.Count -gt $script:MaxJobs) {
    Write-Log -Level ERROR -Message "$($entries.Count) jobs listed; the limit is $($script:MaxJobs). Split the list into separate runs."
    exit 1
}
if (@($entries | Where-Object { -not (Test-JobEntry -Entry $_) }).Count -gt 0) {
    Write-Log -Level ERROR -Message 'Each job needs a slug and an implementerWorktree.'
    exit 1
}
$slugs = @($entries | ForEach-Object { [string]$_.slug })
if (@($slugs | Sort-Object -Unique).Count -ne $slugs.Count) {
    Write-Log -Level ERROR -Message 'Job slugs must be unique.'
    exit 1
}

if (-not $ReviewerWorktreePath) {
    $ReviewerWorktreePath = (Get-Location).ProviderPath
}
$script:ReviewerWorktreePath = $ReviewerWorktreePath

$jobs = @($entries | ForEach-Object { New-Job -Entry $_ -TeamRoot $teamRoot })

Write-Log -Level INFO -Message ("watcher start: {0} job(s): {1}" -f $jobs.Count, (($jobs | ForEach-Object { $_.Slug }) -join ', '))

# The reviewer pane is optional and never resolved automatically: the orchestrator's own
# session is a Claude pane in the same repo, and a lookup could pick it.
$script:ReviewerTerminal = $ReviewerTerminal
if ($script:ReviewerTerminal) {
    Write-Log -Level INFO -Message "Reviewer pane pinned: $($script:ReviewerTerminal)"
}
else {
    Write-Log -Level INFO -Message 'No reviewer pane pinned: reviews and help requests are logged for the orchestrator.'
}

$unresolved = @()
foreach ($job in $jobs) {
    try {
        $job.ImplementerTerminal = Resolve-TerminalHandle -AgentIdentity 'opencode' -WorktreePath $job.ImplementerWorktreePath
        Write-Log -Level INFO -Job $job -Message "Resolved implementer terminal: $($job.ImplementerTerminal)"
    }
    catch {
        Write-Log -Level ERROR -Job $job -Message "Cannot resolve implementer terminal: $($_.Exception.Message)"
        $unresolved += $job.Slug
    }
}
if ($unresolved.Count -gt 0) {
    Write-Log -Level ERROR -Message "No terminal for: $($unresolved -join ', '). Start those implementers in their worktrees, then rerun."
    exit 2
}

foreach ($job in $jobs) { $job.State = Read-JobState -Job $job }

if ($Once) {
    $agents = @(Get-ObservedAgents)
    Write-Log -Level INFO -Message "Observed $($agents.Count) agent(s):"
    foreach ($a in $agents) {
        Write-Log -Level INFO -Message ("  {0,-8} {1,-8} {2}" -f $a.AgentType, $a.State, $a.WorktreePath)
    }
    if ($script:ReviewerTerminal) {
        $reviewerState = Get-AgentState -Agents $agents -AgentType 'claude' -WorktreePath $script:ReviewerWorktreePath
        $reviewerShown = if ($null -eq $reviewerState) { 'not visible yet' } else { $reviewerState }
        Write-Log -Level INFO -Message "reviewer state: $reviewerShown"
    }
    foreach ($job in $jobs) {
        Write-Log -Level INFO -Job $job -Message "phase=$($job.State.phase) round=$($job.State.round)"
    }
    exit 0
}

# --- main loop -------------------------------------------------------------

while ($true) {
    try {
        $agents = @(Get-ObservedAgents)
    }
    catch {
        Write-Log -Level ERROR -Message "Poll failed: $($_.Exception.Message)"
        Start-Sleep -Seconds ($PollSeconds * 2)
        continue
    }

    # A failure in one job is logged against that job; the others keep moving.
    foreach ($job in $jobs) {
        try {
            Invoke-JobTick -Job $job -Agents $agents
        }
        catch {
            Write-Log -Level ERROR -Job $job -Message "Tick failed: $($_.Exception.Message)"
        }
    }

    try {
        Invoke-ReviewerQueue -Jobs $jobs -Agents $agents
    }
    catch {
        Write-Log -Level ERROR -Message "Reviewer queue failed: $($_.Exception.Message)"
    }

    if (@($jobs | Where-Object { $_.State.phase -notin $script:TerminalPhases }).Count -eq 0) { break }

    Start-Sleep -Seconds $PollSeconds
}

$approved = @($jobs | Where-Object { $_.State.phase -eq 'approved' })
$exhausted = @($jobs | Where-Object { $_.State.phase -eq 'exhausted' })
$stopped = @($jobs | Where-Object { $_.State.phase -eq 'stopped' })
Write-Log -Level INFO -Message (
    "Finished: $($approved.Count) approved, $($exhausted.Count) exhausted, $($stopped.Count) stopped. " +
    "Merging is the human's call; nothing was merged or pushed."
)

if ($stopped.Count -gt 0) { exit 4 }
if ($exhausted.Count -gt 0) { exit 3 }
exit 0
