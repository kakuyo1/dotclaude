#!/usr/bin/env bash
# Switch the provider Claude Code talks to.
#
#   bash bundle-switch.sh                 list bundles + report the active one
#   bash bundle-switch.sh status          same
#   bash bundle-switch.sh --help          this text
#   bash bundle-switch.sh <name>          switch to that bundle
#
# Invoked from inside Claude Code as the `/bundle` skill.
#
# ---------------------------------------------------------------------------
# Why the registry, and not settings.json
#
# The provider environment has to live somewhere Claude Code actually reads.
# Measured on this machine:
#   - ~/.claude/settings.json        read   (tracked -> a secret must never go here)
#   - ~/.claude/settings.local.json  NOT read by env (a probe stayed unset while a
#                                    control probe in settings.json took effect)
# and there is no other user-scope file. So the non-secret part could go in the
# tracked settings.json, but the API token could not. Both therefore live in
# HKCU\Environment, which also keeps the public repo from churning on every
# switch.
#
# `setx` is used rather than `reg add` because only setx broadcasts
# WM_SETTINGCHANGE; without that broadcast a newly opened terminal can still
# inherit the old environment block.
#
# ---------------------------------------------------------------------------
# One-time setup (there is no README section for this by request)
#
#   1. Create one token file per provider, gitignored by the `*.local.*` rule:
#
#        ~/.claude/bundles/deepseek.local.json
#        ~/.claude/bundles/agentrouter.local.json
#
#      each containing exactly:
#
#        { "env": { "ANTHROPIC_AUTH_TOKEN": "<that provider's key>" } }
#
#      Never write a token anywhere else, and never add these files to git.
#      The pre-commit gate refuses a force-added ignored path, but do not rely
#      on it as the only barrier.
#
#   2. Remove the provider env from the tracked ~/.claude/settings.json so the
#      registry is not overridden. Settings `env` replaces the value inherited
#      from the shell, so anything left there wins over this script.
#
#   3. After every switch, OPEN A NEW TERMINAL. The registry only affects newly
#      created processes, and Claude Code inherits its environment from the
#      shell that launched it. Restarting claude in the same terminal is not
#      enough.
#
#   4. To go back to a plain Anthropic account, delete the variables:
#        reg delete "HKCU\Environment" /v ANTHROPIC_BASE_URL /f
#      (and the ANTHROPIC_*MODEL* / NO_PROXY ones), then open a new terminal.
#
# ---------------------------------------------------------------------------
# This script ALWAYS exits 0. It runs as inline bash inside the /bundle skill,
# where a non-zero exit aborts the whole invocation and Claude never sees this
# output — which is how a failed switch would get narrated as a successful one.
# Failure is reported on stdout as `NOT SWITCHED — <reason>` instead.

set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
BUNDLES="$CLAUDE_DIR/bundles"
MODEL_CACHE="/tmp/claude-${UID}-state/agentrouter-models.cache.json"
ENV_KEY='HKCU\Environment'

not_switched() { printf '\nNOT SWITCHED — %s\n\n' "$1"; exit 0; }

# Every jq output goes through this. jq on Windows terminates its stdout with
# CRLF, and only the *final* one is stripped by command substitution — interior
# ones survive. Unwrapped, that turns a key list into names ending in \r, which
# grep then fails to match (silently yielding an empty value) and which creates
# registry entries whose names are literally "ANTHROPIC_MODEL\r".
jqr() { jq -r "$@" | tr -d '\r'; }

# ---------------------------------------------------------------------------
# helper: list bundle names (never touches a .local.json)
list_bundles() {
    local f names=()
    for f in "$BUNDLES"/*.json; do
        [ -e "$f" ] || continue
        case "$f" in *.local.json|.*) continue ;; esac
        names+=("$(basename "$f" .json)")
    done
    printf '%s' "${names[*]:-none}"
}

# helper: read one variable from HKCU\Environment. Prints nothing when absent.
reg_get() {
    reg query "$ENV_KEY" //v "$1" 2>/dev/null | awk '
        NR == 3 { $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); print }'
}

# helper: write one variable and broadcast. Empty value clears it (setx cannot
# delete, and `reg delete` would not broadcast, leaving a stale value in any
# environment block Windows already handed out).
reg_set() {
    setx "$1" "$2" >/dev/null 2>&1 || return 1
}

# ---------------------------------------------------------------------------
# report the active provider. Prints names and URLs only — never a token value.
report() {
    local base model tok
    base=$(reg_get ANTHROPIC_BASE_URL)
    model=$(reg_get ANTHROPIC_MODEL)
    tok=$(reg_get ANTHROPIC_AUTH_TOKEN)
    printf 'active    base  %s\n' "${base:-<unset>}"
    printf '          model %s\n' "${model:-<unset>}"
    if [ -n "$tok" ]; then
        printf '          token present (%s chars)\n' "${#tok}"
    else
        printf '          token MISSING\n'
    fi
}

# ---------------------------------------------------------------------------
# agentrouter: resolve model names from the relay, then verify each one.
#
# The pricing endpoint lists a model as offered even while its budget pool is
# exhausted, and this relay rations the claude models. An exhausted pool answers
# HTTP 402 to every call and Claude Code retries it. Measured live: a session
# whose ANTHROPIC_MODEL had been resolved to claude-opus-5 failed six times
# before its first reply, while deepseek-v4-flash answered 200 straight away.
# Listing is therefore not enough — every candidate gets a one-token probe and
# only what actually answers is used.
#
# The probe must carry a Claude Code User-Agent: the relay fingerprints clients
# and answers 401 "unauthorized client detected" to anything that does not look
# like one. Without it every probe would look broken.
#
# Emits KEY=VALUE lines. A slot with no working candidate is omitted rather than
# guessed. Returns 1 when the list cannot be obtained at all, 2 when nothing in
# it works.
PROBE_UA="claude-cli/2.1.293 (external, cli)"

# The token is passed in, never taken from the environment: this script runs
# inside Claude Code, whose own ANTHROPIC_AUTH_TOKEN still belongs to whatever
# provider the session started on. Using that one probes the new provider with
# the old provider's key, every probe 401s, and the switch is refused for a
# reason that has nothing to do with the models.
model_works() {
    local base="$1" model="$2" tok="$3" code
    code=$(curl -sS --max-time 25 -o /dev/null -w '%{http_code}' \
        -X POST "${base}/v1/messages" \
        -H "Authorization: Bearer $tok" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -A "$PROBE_UA" \
        -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        2>/dev/null) || code=""
    [ "$code" = "200" ]
}

resolve_models() {
    local url="$1" want="$2" base="$3" tok="$4" prof="$5" json

    json=$(curl -sS --max-time 10 "$url" 2>/dev/null) || json=""
    if [ -n "$json" ] && printf '%s' "$json" | jq -e '.data' >/dev/null 2>&1; then
        mkdir -p "$(dirname "$MODEL_CACHE")" 2>/dev/null
        printf '%s' "$json" > "$MODEL_CACHE.tmp.$$" 2>/dev/null &&
            mv "$MODEL_CACHE.tmp.$$" "$MODEL_CACHE" 2>/dev/null
    else
        json=$(cat "$MODEL_CACHE" 2>/dev/null) || json=""
        [ -n "$json" ] || return 1
    fi

    local all
    all=$(printf '%s' "$json" | jqr --arg t "$want" \
        '.data[]
         | select((.supported_endpoint_types // []) | index($t))
         | [.model_name, ((.model_ratio // 999) | tostring)] | @tsv' 2>/dev/null) || return 1
    [ -n "$all" ] || return 1

    # Preference order: claude models first (better quality), newest version
    # first, then everything else cheapest first. Probing follows this order, so
    # the first usable entry is also the preferred one.
    local order m usable=""
    order=$(
        printf '%s\n' "$all" | awk -F'\t' '$1 ~ /^claude-/ {print $1}' | sort -Vr
        printf '%s\n' "$all" | awk -F'\t' '$1 !~ /^claude-/ {print $2"\t"$1}' \
            | sort -k1,1n -k2,2 | cut -f2
    )
    for m in $order; do
        [ -n "$m" ] || continue
        model_works "$base" "$m" "$tok" && usable="$usable $m"
    done
    # shellcheck disable=SC2086  # word splitting is the point here
    usable=$(printf '%s\n' $usable)
    [ -n "$usable" ] || return 2

    local primary opus sonnet mini
    primary=$(printf '%s\n' $usable | head -1)
    opus=$(printf '%s\n' $usable | awk '/^claude-opus-/' | sort -Vr | head -1)
    sonnet=$(printf '%s\n' $usable | awk -v s="${opus:-__none__}" \
        '/^claude-/ && $0 != s' | sort -Vr | head -1)
    # non-claude entries are already cost-ordered inside $usable
    mini=$(printf '%s\n' $usable | awk '!/^claude-/' | head -1)
    [ -n "${mini:-}" ]   || mini="${sonnet:-}"
    [ -n "${mini:-}" ]   || mini="$primary"

    # Per-model client-side context marker, from the bundle's contextSuffixes.
    # It must NOT go on the wire: the relay answers 503 "无可用渠道" for the
    # literal "deepseek-v4-flash[1m]" (measured). Claude Code strips it before
    # the request — verified on this version, where ANTHROPIC_MODEL was
    # deepseek-flash[1m] and every recorded message.model was deepseek-flash —
    # and uses it only to size its own context window. So the probes above used
    # the bare name and only the emitted value carries the suffix.
    sfx() { jqr --arg m "$1" '.contextSuffixes[$m] // ""' "$prof"; }

    printf 'ANTHROPIC_MODEL=%s%s\n' "$primary" "$(sfx "$primary")"
    [ -n "${opus:-}" ]   && printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s%s\n' "$opus" "$(sfx "$opus")"
    [ -n "${sonnet:-}" ] && printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s%s\n' "$sonnet" "$(sfx "$sonnet")"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s%s\n' "$mini" "$(sfx "$mini")"
    printf 'CLAUDE_CODE_SUBAGENT_MODEL=%s%s\n' "$mini" "$(sfx "$mini")"
    return 0
}

# ---------------------------------------------------------------------------
# argument handling
case "${1:-}" in
    --help|-h)
        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    ""|status)
        printf 'bundles: %s\n' "$(list_bundles)"
        report
        exit 0 ;;
esac

name="$1"

# the name becomes a path, so keep the charset strict
if [ -n "$(printf '%s' "$name" | tr -d 'a-z0-9-')" ]; then
    printf 'invalid bundle name: %s\n' "$name"
    printf 'bundles: %s\n' "$(list_bundles)"
    exit 0
fi

prof="$BUNDLES/$name.json"
[ -f "$prof" ] || not_switched "no such bundle: $name (available: $(list_bundles))"

sec="$BUNDLES/$name.local.json"
[ -f "$sec" ] || not_switched "missing $sec
Create it as {\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"<key>\"}} and re-run.
Refusing without it: the previous provider's token is still in the registry and
would be sent to the new provider."

# token must be present and non-empty in the secret file
token=$(jqr '.env.ANTHROPIC_AUTH_TOKEN // empty' "$sec" 2>/dev/null) || token=""
[ -n "$token" ] || not_switched "$sec has no env.ANTHROPIC_AUTH_TOKEN"

# ---------------------------------------------------------------------------
# build the final KEY=VALUE set: bundle env, plus resolved models, plus token
plan=$(mktemp) || not_switched "could not create a temp file"
trap 'rm -f "$plan"' EXIT

jqr '.env | to_entries[] | "\(.key)=\(.value)"' "$prof" > "$plan" 2>/dev/null ||
    not_switched "invalid JSON in $prof"

resolve_url=$(jqr '.resolveModels.from // empty' "$prof" 2>/dev/null)
if [ -n "$resolve_url" ]; then
    want=$(jqr '.resolveModels.requiresEndpointType // "anthropic"' "$prof" 2>/dev/null)
    base=$(jqr '.env.ANTHROPIC_BASE_URL // empty' "$prof" 2>/dev/null)
    resolved=$(resolve_models "$resolve_url" "$want" "$base" "$token" "$prof")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$resolved" >> "$plan"
    elif [ "$rc" -eq 2 ]; then
        not_switched "no model behind $base answered a probe just now.
This relay rations the claude models and answers 402 'Budget pool quota has been
exhausted' while its pricing page still lists them, so listing is not proof of
availability. Refusing to switch onto a model that cannot serve a request."
    else
        not_switched "could not fetch the model list from $resolve_url (no network, no cache)."
    fi
fi
printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$token" >> "$plan"

# ---------------------------------------------------------------------------
# every key any bundle has ever set must be written this time, otherwise a key
# from the previous provider lingers in the registry.
all_keys=$(for f in "$BUNDLES"/*.json; do
        [ -e "$f" ] || continue
        case "$f" in *.local.json|.*) continue ;; esac
        jqr '.env | keys[]' "$f" 2>/dev/null
    done | sort -u)
all_keys=$(printf '%s\nANTHROPIC_AUTH_TOKEN' "$all_keys" | sort -u)

failed=""
while IFS= read -r key; do
    [ -n "$key" ] || continue
    val=$(grep -m1 "^${key}=" "$plan" | cut -d= -f2-)
    reg_set "$key" "$val" || failed="$failed $key"
done <<< "$all_keys"

[ -n "$failed" ] && not_switched "setx failed for:$failed"

# ---------------------------------------------------------------------------
printf '/bundle %s\n' "$name"
# Read back from the registry, not from the profile: a bundle may define no
# models at all and have them resolved at switch time instead.
printf '  model %s\n' "$(reg_get ANTHROPIC_MODEL)"
printf '  base  %s\n' "$(reg_get ANTHROPIC_BASE_URL)"
printf '  token present (%s chars)\n' "${#token}"
printf '\nOpen a NEW terminal before using it: the registry only affects newly\n'
printf 'created processes, so restarting claude in this terminal is not enough.\n\n'
