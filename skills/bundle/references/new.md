# Adding a provider

Reached by `/bundle --new`. A provider is two files under `~/.claude/bundles/`,
and only one of them is yours to write: `<name>.json` describes it, and
`<name>.local.json` holds the key and belongs to the user.

The field semantics you are about to write live in the header of
`~/.claude/bundle-switch.sh`. Read that first. This file says what to find out.

## 1. Ask which provider

Ask which provider to add and for a link to its docs or API page, unless the
user already named one in the command or in an earlier message. Nothing in this
repo can supply that identity, and the site alone is enough to start.

Then name the bundle after the provider's host: a short lowercase slug, because
`bundle-switch.sh` rejects any name outside `a-z0-9-`. State the name you picked
— it is the path the user is about to type.

## 2. Ask for the token file, never the token

Tell the user to create `~/.claude/bundles/<name>.local.json`, containing
exactly:

    { "env": { "ANTHROPIC_AUTH_TOKEN": "<the provider's key>" } }

Never create, open, `cat`, `jq`, `grep` or `source` that file, and never ask the
user to paste the key into the conversation. A key that reaches this transcript
has to be rotated. `bundle-switch.sh` reads the file itself, so no step below
needs the value.

Everything after this point can proceed while the user does that.

## 3. Find where the model list lives

Pick the family, and the `resolveModels` block follows.

- **A New API / One API relay** — agentrouter.org is one, and traxnode.com is
  another. `GET <base>/api/pricing` returns `data[]` rows carrying
  `model_name`, `model_ratio` and `supported_endpoint_types`, which map
  straight onto `idField`, `ratioField` and `requiresEndpointType` — use
  `"model_name"`, `"model_ratio"`, `"anthropic"`. The last one is not optional:
  these relays serve the same models over OpenAI-compatible routes too, and
  those answer 404 to `/v1/messages`. Some instances gate `/api/pricing` behind
  the key (traxnode answers 401 `AUTH_UNAUTHORIZED`) and some do not
  (agentrouter). The script sends the key either way, but a gated endpoint means
  you cannot read the field names yourself: take them from the docs, and fall
  back to `/v1/models` with `idField: "id"` if the pricing shape turns out not
  to match.
- **A first-party API** — DeepSeek is one: `GET <base>/models`, `idField: "id"`,
  plus `contextWindowField` when the response reports a window.

`ANTHROPIC_BASE_URL` is whatever the provider's docs call its Anthropic
endpoint. DeepSeek's carries a path (`https://api.deepseek.com/anthropic`);
a New API relay's is the bare origin. The script appends `/v1/messages` itself,
so never add `/v1` here.

Two properties of the script shape what you choose. The list fetch sends
`Authorization: Bearer`, so `from` must accept the key as a Bearer token. And
every candidate is probed one at a time, so a list of hundreds of models makes
the switch slow — the other reason `/api/pricing` beats `/v1/models` when the
instance does not gate it: its endpoint types filter the set before any probe
runs.

## 4. Set NO_PROXY by reachability

`env.NO_PROXY` names the hosts to reach directly, bypassing Clash. A domestic
host belongs there (`api.deepseek.com` is in DeepSeek's); a foreign one must not
be (`agentrouter.org` is absent from agentrouter's), or the provider is
unreachable in the terminal the user actually runs. Keep
`localhost,127.0.0.1,::1` in every bundle. One curl with and without
`-x "$HTTP_PROXY"` tells you which side a host is on.

## 5. Choose the models

`assignment`:

- `"family"` when the provider offers claude-* models. They fill the
  opus/sonnet/haiku slots and the cheapest non-claude model fills the subagent
  slot. A relay that rations its claude models degrades instead of breaking: a
  candidate whose probe fails is dropped, not guessed around.
- `"single"` when the provider is effectively one model (this is DeepSeek's):
  one name in every slot.

Prefer a name this repo already trusts, rather than the cheapest untried thing.
They are recorded in the existing bundles — list the tracked ones with
`git -C ~/.claude ls-files bundles` (never glob `bundles/*.json`, which would
match the token files), and read their `contextSuffixes` keys and `prefer`
regexes. If the new provider offers one of those names, say so and offer it. One
catch: `prefer` is honoured by `"single"` only, so a `prefer` written into a
`"family"` bundle is config that never runs.

`contextSuffixes` is an assertion about a window the provider does not publish —
agentrouter's `"deepseek-v4-flash": "[1m]"` is the existing one. The suffix never
reaches the wire; Claude Code strips it and uses it only to size its own context.
Add an entry only when you know the window and the list endpoint does not report
it. When `contextWindowField` is set and the endpoint reports a window of 1M or
more, the marker is derived and an entry would be redundant.

## 6. Write the bundle

`~/.claude/bundles/<name>.json`, shaped like an existing one: the `name` field
and two `env` keys, `ANTHROPIC_BASE_URL` and `NO_PROXY`. Models do not go in
`env` — they are resolved at switch time. Nothing secret goes here either: this
file is tracked in a public repo, which is the whole reason the key lives in the
`.local.json` beside it.

## 7. Activate it, and let the probes judge

Once the token file exists, run `bash ~/.claude/bundle-switch.sh <name>`. This is
a real switch, not a dry run, and it is also the only test that the config is
right: it fetches the list, probes one token against every candidate, and writes
the registry only when something answered 200. It refuses in two distinguishable
ways, and the message says which one you got:

- the list could not be fetched — `from` is wrong, or answers something other
  than `{data: [...]}` to a Bearer key;
- nothing answered a probe — the model set, the `idField`, or the
  endpoint-type filter is wrong.

Fix and repeat. Then relay the resolved model names to the user and get their
confirmation before calling it done: the resolved set is the bundle's real
content, not the draft in the JSON.

## 8. Give it a statusline badge

`statusline.sh` reads the provider from `ANTHROPIC_BASE_URL`, and while that
match is empty the entire cost segment disappears — a new provider shows no
badge at all until it is listed, not a bare name. So add one arm to the
`case "${ANTHROPIC_BASE_URL:-}"` matcher:

    *<host>*) provider=<name>; symbol='<¥|$>' ;;

A `fetch_balance` arm is optional and belongs there only when the provider
answers a balance request with the API key and hands back a real number. A wrong
number is worse than none: New API's `/v1/dashboard/billing/subscription`
returns `soft_limit_usd: 100000000`, its "no limit" sentinel, which once
rendered as a literal `$100000000`, and the real quota sits behind
`/api/user/self`, which wants a browser session token rather than an API key.
With no honest number, leave the arm out and let the badge name the provider.

## 9. Finish

Tell the user the token file is what is left to do if they have not made it, and
that the switch takes effect only in a new terminal — restarting `claude` in the
same one is not enough.
