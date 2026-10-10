# opencode target

Read this from the opencode section of `SKILL.md`. Claude Code does not use it.

## The `opencode` block

A bundle gets an opencode target by adding an `opencode` block to
`bundles/<name>.json`. The block is ignored by Claude Code.

    "opencode": { "baseURL": "<base>/v1", "requiresEndpointType": "openai" }

- `baseURL` is explicit and includes `/v1`. Never derive it from
  `ANTHROPIC_BASE_URL`: the two often differ (DeepSeek's Anthropic base is
  `.../anthropic`, its OpenAI base is `.../v1`).
- `from`, `idField` and `ratioField` inherit from `resolveModels` when the block
  omits them. Give `from` only when the OpenAI-side list lives elsewhere (traxnode
  does). Then give `idField` too: the default `model_name` is wrong for
  `/v1/models`, which uses `id`.
- `requiresEndpointType` defaults to empty. Set it to `openai` only when the
  priced list marks rows with `supported_endpoint_types` (agentrouter does). A
  plain `/v1/models` list has none, and a default filter would empty it.
- Probes send `max_tokens`. Some endpoints reject it and want
  `max_completion_tokens`. If every candidate answers 400 with a parameter
  message, that is the cause; the script does not yet switch the field name.
- A 400 on this wire is usually final ("tools not supported", a model
  restriction). Only 5xx and connection failures are retried.
- The probe checks for `tool_calls`. A model that answers 200 without one is
  listed with `tool_call: false`, not dropped, unless `requiresToolUse` is set.

## What a sync writes

`~/.claude/skills/bundle/scripts/opencode/bundle-switch.ps1 <name>` merges one provider entry into `~/.config/opencode/opencode.jsonc`:

- `provider.<name>`: `npm`, `name`, `options.baseURL`, and `models` with each id's
  `tool_call` flag from the probe.

It does not write the default `model`, any other provider, or `auth.json`. Before
each sync the previous `opencode.jsonc` is kept as `opencode.jsonc.bak`. If that
file contains comments, the sync refuses and writes nothing, because the rewrite
would drop them.

The key is read from `~/.local/share/opencode/auth.json` under the bundle name. The
sync never writes that file, and it never prints a key.

## Adding a provider for opencode

Run this after the Claude Code steps in `claudecode.md` have named the bundle, or on its own
for a provider that only opencode uses.

1. Run recon (`claudecode.md` step 3). Its `openai route` line decides whether this target
   applies: 401 means the route exists, 404 means it does not. Stop if it is 404.
2. Ask the user to add the key to `auth.json` under the bundle name, as
   `{"type": "api", "key": "<key>"}`. The name must match the bundle name exactly.
   Never open the file to read the key, and never ask for it in the chat.
3. Add the `opencode` block to `bundles/<name>.json`.
4. Run `~/.claude/skills/bundle/scripts/opencode/bundle-switch.ps1 --diag <name>` and read the candidate list. It writes nothing.
5. Run `~/.claude/skills/bundle/scripts/opencode/bundle-switch.ps1 <name>` to sync. Report the models it lists. They are the real
   content, so get the user's confirmation before calling it done.
6. Tell the user to restart opencode. It reads its config only at startup.

A relay whose OpenAI route serves only Claude models cannot be used here. The probe
is refused and the script reports `NOT SWITCHED` with the first refusal verbatim.
traxnode, with its Claude-only key, is an example.
