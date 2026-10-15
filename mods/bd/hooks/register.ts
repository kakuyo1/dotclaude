import type { Register } from 'claude-code'

// Resolved by PowerShell itself: $.process.run passes an argv, no shell, so
// $HOME never reaches the child.
const SCRIPT = '& "$env:USERPROFILE\\.claude\\skills\\bundle\\scripts\\claudecode\\bundle-switch.ps1"'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'bd',
      description: 'Switch the provider Claude Code talks to (runs bundle-switch.ps1)',
      argumentHint: '[<name>|status|--diag <name>]',
    })

    return next(e)
  })

  on('command.run', { command: 'bd' }, async ($, e) => {
    const args = e.args.trim() === '' ? [] : e.args.trim().split(/\s+/)

    // The args are spliced into one -Command string, so only bundle names and
    // flags get through.
    if (!args.every(arg => /^[A-Za-z0-9_.-]+$/.test(arg))) {
      return { text: 'bd: arguments may only be letters, digits, . _ and -' }
    }

    const ran = await $.process.run(
      ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', [SCRIPT, ...args].join(' ')],
      { timeoutMs: 300000 },
    )

    if (ran.exitCode !== 0) {
      return { text: `bd: powershell exited ${ran.exitCode}\n${ran.stderr.trimEnd()}` }
    }

    return { text: ran.stdout.trimEnd() || 'bd: no output' }
  })
}
