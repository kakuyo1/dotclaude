#!/usr/bin/env bash
# Switch the provider Claude Code talks to.
#
#   bash bundle-switch.sh                 list bundles + report the active one
#   bash bundle-switch.sh status          same
#   bash bundle-switch.sh --help          this text
#   bash bundle-switch.sh --new           the add-a-provider flow, not a switch
#   bash bundle-switch.sh --diag <name>   print each candidate's probe result
#                                         without writing the registry
#   bash bundle-switch.sh <name>          switch to that bundle
#
# Invoked from inside Claude Code as the `/bundle` skill. The opencode side is
# ../opencode/bundle-switch.sh, which shares no code with this file.
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
# Model resolution, driven entirely by the bundle's resolveModels block.
#
# No provider's model names are hardcoded. Both expose a list endpoint, and both
# are known to list models that cannot actually serve a request, so a listed
# model is not proof of a usable one. Measured live on agentrouter: a session
# whose ANTHROPIC_MODEL had been resolved to claude-opus-5 failed six API calls
# before its first reply, because that relay rations the claude models and
# answers 402 "Budget pool quota has been exhausted" while /api/pricing still
# lists them. Every candidate therefore gets one probe — a messages request
# carrying a tools array — and only what answers it is used.
#
# resolveModels fields:
#   from                  list endpoint. The token is always sent: required by
#                         DeepSeek, which answers 401 without it, and ignored by
#                         the public agentrouter endpoint.
#   idField               "id" (DeepSeek) | "model_name" (agentrouter)
#   ratioField            optional cost multiplier, used to order candidates
#   contextWindowField    optional. A window of at least 1M earns the
#                         client-side [1m] marker, so the marker is derived from
#                         the provider's own data rather than asserted.
#   requiresEndpointType  optional. Keep only models offering that wire format.
#   requiresToolUse       optional "true". A candidate must then answer the
#                         probe with a tool_use block, not merely a 200.
#   assignment            "family" -> opus / sonnet / mini slots (agentrouter)
#                         "single" -> one model in every slot (DeepSeek)
#   prefer                optional regex, "single" only — "family" has a fixed
#                         order and ignores it. Matching models are probed
#                         first, and if none match the ordering still yields a
#                         candidate, so a rename degrades instead of breaking.
#                         Anchor it on a single name: a regex matching several
#                         resolves by the provider's list order, which the
#                         provider may reorder between requests.
#
# Emits KEY=VALUE lines. A slot with no working candidate is omitted rather than
# guessed. Returns 1 when the list cannot be obtained at all, 2 when nothing in
# it works.
#
# The probe must carry a Claude Code User-Agent: agentrouter fingerprints
# clients and answers 401 "unauthorized client detected" to anything that does
# not look like one, which would make every candidate look broken. What it
# matches is the SHAPE claude-cli/<anything> (external, cli) — measured,
# versions 1.0.0 and 9.9.9 both pass, while dropping the " (external, cli)"
# suffix or the "claude-cli/" prefix gives 401. The version is read from the
# installed CLI anyway so the header stays truthful across an upgrade, not
# because the relay validates it.
claude_cli_version() {
    local v
    # --version writes nothing: verified by comparing the mtimes of ~/.claude.json
    # and settings.json across a call.
    v=$(claude --version 2>/dev/null | awk 'NR==1 {print $1}')
    case "$v" in
        [0-9]*) printf '%s' "$v" ;;
        *)      printf '0.0.0' ;;  # undetectable; the relay checks shape, not value
    esac
}
PROBE_UA="claude-cli/$(claude_cli_version) (external, cli)"

# The only evidence the script has about a candidate. The request carries a tools
# array and an unambiguous instruction to call the tool, so a 200 can be told
# apart from a model that merely answers: measured on chengmo, 15 of 73 listed
# models answered 200, but llama3.1-8B answered with plain text (stop_reason
# end_turn) and never called the tool, and nemotron-3.5-content-safety is a
# classifier rather than a chat model. Which of those counts as usable is the
# bundle's call, via requiresToolUse.
#
# A 400 or 5xx is retried once: a relay routing through a shared pool refuses
# transiently, measured as `分组 auto 下模型 X 的可用渠道不存在（retry）` minutes
# after the same model had answered 200. A 402 (quota) or 403 (group) is final
# and is not retried.
#
# The token is passed in, never taken from the environment: this script runs
# inside Claude Code, whose own ANTHROPIC_AUTH_TOKEN still belongs to whatever
# provider the session started on. Using that one probes the new provider with
# the old provider's key, every probe 401s, and the switch is refused for a
# reason that has nothing to do with the models.
#
# Prints "<code>\t<1|0 has tool_use>\t<body head>" on stdout.
probe_model() {
    local base="$1" model="$2" tok="$3"
    local body resp code tu="0" attempt=0
    body=$(printf '{"model":"%s","max_tokens":256,"tools":[{"name":"get_weather","description":"Get the current weather for a city.","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],"messages":[{"role":"user","content":"What is the weather in Paris? Call the get_weather tool."}]}' "$model")
    resp=$(mktemp) || return 0
    while :; do
        attempt=$((attempt+1))
        code=$(curl -sS --max-time 30 -o "$resp" -w '%{http_code}' \
            -X POST "${base}/v1/messages" \
            -H "Authorization: Bearer $tok" \
            -H "content-type: application/json" \
            -H "anthropic-version: 2023-06-01" \
            -A "$PROBE_UA" \
            -d "$body" 2>/dev/null) || code=""
        case "$code" in
            400|5[0-9][0-9]) [ "$attempt" -lt 2 ] || break ;;
            *) break ;;
        esac
    done
    if [ "$code" = "200" ] &&
       jq -e '[(.content // [])[] | .type] | index("tool_use")' "$resp" >/dev/null 2>&1; then
        tu="1"
    fi
    printf '%s\t%s\t%s\n' "${code:-000}" "$tu" \
        "$(tr -s '[:space:]' ' ' < "$resp" | cut -c1-160)"
    rm -f "$resp"
}

resolve_models() {
    local prof="$1" base="$2" tok="$3" json
    local url idf ratiof cwf ep assign prefer rt

    # Cached per bundle. A single shared file served one provider's list to
    # another provider's probe whenever a fetch failed, and the failure it
    # produced — every candidate rejected — reads as a quota problem rather
    # than a cache mixup.
    local cache="/tmp/claude-${UID}-state/$(basename "$prof" .json)-models.cache.json"

    # Why the resolution gave up, carried out to the caller's message. A
    # variable cannot do it: the caller runs this function in a command
    # substitution, so anything set here dies with the subshell.
    local state="${cache%/*}"
    local notefile="$state/$(basename "$prof" .json)-lastfail.txt"
    mkdir -p "$state" 2>/dev/null
    : > "$notefile" 2>/dev/null

    url=$(jqr '.resolveModels.from // empty' "$prof")
    [ -n "$url" ] || return 1
    idf=$(jqr '.resolveModels.idField // "model_name"' "$prof")
    ratiof=$(jqr '.resolveModels.ratioField // ""' "$prof")
    cwf=$(jqr '.resolveModels.contextWindowField // ""' "$prof")
    ep=$(jqr '.resolveModels.requiresEndpointType // ""' "$prof")
    assign=$(jqr '.resolveModels.assignment // "family"' "$prof")
    prefer=$(jqr '.resolveModels.prefer // ""' "$prof")
    rt=$(jqr '.resolveModels.requiresToolUse // false' "$prof")

    # curl's stderr is left in place rather than discarded, and its exit code is
    # kept: "could not fetch" otherwise reads the same for an unresolvable host,
    # a reset connection and a TLS failure, and curl separates them (6 / 7 / 35).
    local curl_rc=0
    json=$(curl -sS --max-time 12 -A "$PROBE_UA" \
        -H "Authorization: Bearer $tok" "$url") || curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
        printf '%s' "curl exit $curl_rc" > "$notefile" 2>/dev/null
        json=""
    fi
    if [ -n "$json" ] && printf '%s' "$json" | jq -e '.data' >/dev/null 2>&1; then
        printf '%s' "$json" > "$cache.tmp.$$" 2>/dev/null &&
            mv "$cache.tmp.$$" "$cache" 2>/dev/null
    else
        json=$(cat "$cache" 2>/dev/null) || json=""
        if [ -z "$json" ]; then
            printf '%s' "no list and no cache" > "$notefile" 2>/dev/null
            return 1
        fi
    fi

    # one row per candidate: id <TAB> ratio <TAB> context_window
    local rows
    rows=$(printf '%s' "$json" | jqr \
        --arg id "$idf" --arg rf "$ratiof" --arg cw "$cwf" --arg ep "$ep" '
        .data[]
        | select($ep == "" or ((.supported_endpoint_types // []) | index($ep)))
        | . as $m
        | ($m[$id] // empty) as $name
        | select($name != "")
        | [$name, (($m[$rf] // 999) | tostring), (($m[$cw] // 0) | tostring)]
        | @tsv' 2>/dev/null) || rows=""
    if [ -z "$rows" ]; then
        # The list arrived; the filter emptied it. This is NOT a fetch failure,
        # and the two used to share return 1 and one message: on chengmo all 73
        # rows declared only the openai endpoint type, so requiresEndpointType
        # "anthropic" discarded every one and the switch blamed the network.
        return 3
    fi

    # Probe order. "family" puts claude models first (better quality), newest
    # version first, then everything else cheapest first. "single" is a plain
    # cost order with an optional preferred name hoisted to the front.
    local order m usable="" probed=0 firstfail="" line pcode ptu psnip tfl
    if [ "$assign" = "single" ]; then
        order=$(printf '%s\n' "$rows" | sort -t$'\t' -k2,2n -k1,1 | cut -f1)
        if [ -n "$prefer" ]; then
            order=$( { printf '%s\n' "$rows" | awk -F'\t' -v p="$prefer" '$1 ~ p {print $1}'
                       printf '%s\n' "$order"; } | awk '!seen[$0]++')
        fi
    else
        order=$(
            printf '%s\n' "$rows" | awk -F'\t' '$1 ~ /^claude-opus-/ {print $1}' | sort -Vr
            printf '%s\n' "$rows" | awk -F'\t' '$1 ~ /^claude-/ && $1 !~ /^claude-opus-/ {print $1}' | sort -Vr
            printf '%s\n' "$rows" | awk -F'\t' '$1 !~ /^claude-/ {print $2"\t"$1}' \
                | sort -k1,1n -k2,2 | cut -f2
        )
    fi
    for m in $order; do
        [ -n "$m" ] || continue
        probed=$((probed+1))
        line=$(probe_model "$base" "$m" "$tok")
        pcode=$(printf '%s' "$line" | cut -f1)
        ptu=$(printf '%s' "$line" | cut -f2)
        psnip=$(printf '%s' "$line" | cut -f3-)
        if [ "${DIAG:-0}" = "1" ]; then
            # The refusal body goes to stderr with the code: the code alone
            # cannot separate a 402 quota from a 403 group, and that is the
            # whole reason to run a diagnostic.
            tfl="False"; [ "$ptu" = "1" ] && tfl="True"
            if [ "$pcode" = "200" ]; then
                printf '%-6s tool=%-5s %s\n' "$pcode" "$tfl" "$m" >&2
            else
                printf '%-6s tool=%-5s %s  %s\n' "$pcode" "$tfl" "$m" "$psnip" >&2
            fi
        fi
        if [ "$pcode" = "200" ] && { [ "$rt" != "true" ] || [ "$ptu" = "1" ]; }; then
            usable="$usable $m"
        elif [ -z "$firstfail" ]; then
            # One refusal kept verbatim. It is the only thing that separates a
            # rejected key from a dry pool from a wrong field name, and this
            # message used to read only "nothing answered a probe".
            firstfail="$m -> HTTP $pcode $psnip"
        fi
    done
    # shellcheck disable=SC2086  # word splitting is the point here
    usable=$(printf '%s\n' $usable)
    if [ -z "$usable" ]; then
        printf '%s' "$probed candidates probed; first refusal: $firstfail" > "$notefile" 2>/dev/null
        return 2
    fi

    local primary
    primary=$(printf '%s\n' $usable | head -1)

    # Per-model client-side context marker, from the bundle's contextSuffixes.
    # It must NOT go on the wire: the relay answers 503 "无可用渠道" for the
    # literal "deepseek-v4-flash[1m]" (measured). Claude Code strips it before
    # the request — verified on this version, where ANTHROPIC_MODEL was
    # deepseek-flash[1m] and every recorded message.model was deepseek-flash —
    # and uses it only to size its own context window. So the probes above used
    # the bare name and only the emitted value carries the suffix.
    # An explicit contextSuffixes map wins; otherwise a window of at least 1M
    # earns the marker on its own, so it comes from the provider's own data.
    sfx() {
        local s cw
        s=$(jqr --arg m "$1" '.contextSuffixes[$m] // ""' "$prof")
        if [ -n "$s" ]; then printf '%s' "$s"; return 0; fi
        [ -n "$cwf" ] || return 0
        cw=$(printf '%s\n' "$rows" | awk -F'\t' -v m="$1" '$1 == m {print $3; exit}')
        case "$cw" in
            ''|*[!0-9]*) : ;;
            *) [ "$cw" -ge 1048576 ] && printf '[1m]' ;;
        esac
    }
    emit() { printf '%s=%s%s\n' "$1" "$2" "$(sfx "$2")"; }

    if [ "$assign" = "single" ]; then
        # one model in every slot, which is how this provider was hand-configured
        emit ANTHROPIC_MODEL                    "$primary"
        emit ANTHROPIC_DEFAULT_OPUS_MODEL       "$primary"
        emit ANTHROPIC_DEFAULT_OPUS_MODEL_NAME  "$primary"
        emit ANTHROPIC_DEFAULT_SONNET_MODEL     "$primary"
        emit ANTHROPIC_DEFAULT_HAIKU_MODEL      "$primary"
        emit ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME "$primary"
        emit CLAUDE_CODE_SUBAGENT_MODEL         "$primary"
    else
        local opus sonnet mini
        opus=$(printf '%s\n' $usable | awk '/^claude-opus-/' | sort -Vr | head -1)
        sonnet=$(printf '%s\n' $usable | awk -v s="${opus:-__none__}" \
            '/^claude-/ && $0 != s' | sort -Vr | head -1)
        # non-claude entries are already cost-ordered inside $usable
        mini=$(printf '%s\n' $usable | awk '!/^claude-/' | head -1)
        [ -n "${mini:-}" ]   || mini="${sonnet:-}"
        [ -n "${mini:-}" ]   || mini="$primary"
        emit ANTHROPIC_MODEL "$primary"
        [ -n "${opus:-}" ]   && emit ANTHROPIC_DEFAULT_OPUS_MODEL "$opus"
        [ -n "${sonnet:-}" ] && emit ANTHROPIC_DEFAULT_SONNET_MODEL "$sonnet"
        emit ANTHROPIC_DEFAULT_HAIKU_MODEL "$mini"
        emit CLAUDE_CODE_SUBAGENT_MODEL "$mini"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# argument handling
case "${1:-}" in
    --help|-h)
        # Bounded by the comment block itself, not by a line number: the range
        # silently truncated the help the first time the header grew.
        awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
        exit 0 ;;
    ""|status)
        printf 'bundles: %s\n' "$(list_bundles)"
        report
        exit 0 ;;
    --new)
        # Adding a provider is agent research, not a registry write (see the
        # /bundle skill). It is answered here rather than in the skill because
        # the skill's `!`-substitution runs unconditionally, so this script is
        # always called and would otherwise report a supported invocation as
        # "no such bundle".
        printf 'NEW BUNDLE — no switch was attempted.\n'
        exit 0 ;;
esac

# --diag <name>: probe every candidate and print each result, writing nothing.
# The probe needs the token, and only this script reads that file, so this is
# the only way to see why a resolution picked what it picked.
DIAG=0
if [ "${1:-}" = "--diag" ]; then
    if [ -z "${2:-}" ]; then
        printf 'usage: bundle-switch.sh --diag <name>\n'
        exit 0
    fi
    DIAG=1
    shift
fi

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
notefile="/tmp/claude-${UID}-state/$(basename "$prof" .json)-lastfail.txt"
if [ -n "$resolve_url" ]; then
    base=$(jqr '.env.ANTHROPIC_BASE_URL // empty' "$prof" 2>/dev/null)
    resolved=$(resolve_models "$prof" "$base" "$token")
    rc=$?
    detail=$(cat "$notefile" 2>/dev/null) || detail=""
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$resolved" >> "$plan"
    elif [ "$rc" -eq 2 ]; then
        msg="no model behind $base answered the probe."
        [ -n "$detail" ] && msg="$msg
$detail"
        not_switched "$msg
The list endpoint names models the provider cannot currently serve, and a relay
routing through a shared pool also refuses transiently: a 5xx "no available
channel for this model" was measured minutes after the same model had answered
200. Retrying later can succeed against the same list."
    elif [ "$rc" -eq 3 ]; then
        ep_filter=$(jqr '.resolveModels.requiresEndpointType // ""' "$prof" 2>/dev/null)
        not_switched "the list from $resolve_url arrived, but no row survived the
resolveModels filter (requiresEndpointType \"$ep_filter\"). Every candidate was
discarded before any probe ran — compare that value against what the endpoint
actually publishes for supported_endpoint_types."
    else
        msg="could not fetch the model list from $resolve_url."
        [ -n "$detail" ] && msg="$msg $detail."
        not_switched "$msg"
    fi
fi

# --diag stops here. $plan holds no token yet and the registry is untouched, so
# the probe log printed while resolving is the whole output.
if [ "$DIAG" = "1" ]; then
    printf -- '--- diag %s (registry untouched) ---\n' "$name"
    sed 's/^/  /' "$plan"
    exit 0
fi

printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$token" >> "$plan"

# ---------------------------------------------------------------------------
# every key any bundle has ever set must be written this time, otherwise a key
# from the previous provider lingers in the registry.
all_keys=$(
    { for f in "$BUNDLES"/*.json; do
          [ -e "$f" ] || continue
          case "$f" in *.local.json|.*) continue ;; esac
          jqr '.env | keys[]' "$f" 2>/dev/null
      done
      # Model names are resolved at switch time now rather than declared in a
      # bundle, so the env blocks alone can no longer enumerate them. Read back
      # the registry for the namespace this script owns instead.
      reg query "$ENV_KEY" 2>/dev/null |
          sed -n 's/^    \(\(ANTHROPIC_\|CLAUDE_CODE_\)[A-Za-z0-9_]*\).*/\1/p'
      printf 'ANTHROPIC_AUTH_TOKEN\n'
    } | grep -v '^$' | sort -u)

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
