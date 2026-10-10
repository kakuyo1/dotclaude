#!/usr/bin/env bash
# Sync a bundle into opencode's config. opencode side only: this script never
# touches the Claude Code registry. The Claude Code side is
# ../claudecode/bundle-switch.sh, and the two do not share code.
#
#   bash bundle-switch.sh                 list bundles
#   bash bundle-switch.sh status          same
#   bash bundle-switch.sh --help          this text
#   bash bundle-switch.sh --diag <name>   print each candidate's probe result
#                                         without writing anything
#   bash bundle-switch.sh <name>          sync that bundle into opencode.jsonc
#
# Invoked from the opencode `bundle` command (assets/bundle.command.md).
#
# The sync merges one provider entry into ~/.config/opencode/opencode.jsonc and
# keeps every other key. The key is read from ~/.local/share/opencode/auth.json.
# Restart opencode afterwards: it reads its config once at startup.
#
# This script ALWAYS exits 0, so a failure reaches the caller as
# `NOT SWITCHED — <reason>` on stdout instead of an aborted command.

set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
BUNDLES="$CLAUDE_DIR/bundles"

not_switched() { printf '\nNOT SWITCHED — %s\n\n' "$1"; exit 0; }

# Every jq output goes through this: jq on Windows ends lines with CRLF.
jqr() { jq -r "$@" | tr -d '\r'; }

# ---------------------------------------------------------------------------
# list bundle names (never touches a .local.json)
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
# ---------------------------------------------------------------------------
# --opencode: the same bundle, aimed at opencode instead of Claude Code.
#
# Nothing above is reused on this path. The registry sweep would blank every
# ANTHROPIC_* key this plan does not carry, and the probe speaks /v1/messages
# where opencode speaks /v1/chat/completions. opencode takes several providers
# at once, so this path only syncs its own provider entry into the user's
# opencode.jsonc and leaves everything else in that file alone. No registry write.
OC_AUTH="$HOME/.local/share/opencode/auth.json"
OC_CMD="$HOME/.config/opencode/command/bundle.md"
OC_CFG="$HOME/.config/opencode/opencode.jsonc"
OC_CMD_SRC="$CLAUDE_DIR/skills/bundle/assets/bundle.command.md"
OC_STATE="/tmp/claude-${UID}-state"

oc_version() {
    local v
    v=$(opencode --version 2>/dev/null | awk 'NR==1 {print $1}')
    case "$v" in
        [0-9]*) printf '%s' "$v" ;;
        *)      printf '0.0.0' ;;
    esac
}

# One OpenAI-wire probe. 200 with tool_calls is the only evidence that a model
# can call tools, which is what the generated tool_call flag asserts. Only 5xx
# and connection failures are retried: a 400 here is a final answer ("this model
# rejects tools"), and a retry only spends quota.
# Prints "<code>\t<1|0 called a tool>\t<body head>".
oc_probe() {
    local base="$1" model="$2" tok="$3"
    local body resp code="" tool="0" attempt=0
    body=$(jq -nc --arg m "$model" '{
        model: $m, max_tokens: 256,
        messages: [{role: "user", content: "What is the weather in Paris? Call the get_weather tool."}],
        tools: [{type: "function", function: {name: "get_weather", description: "Get the current weather for a city.",
            parameters: {type: "object", properties: {city: {type: "string"}}, required: ["city"]}}}]}')
    resp=$(mktemp) || return 0
    while :; do
        attempt=$((attempt+1))
        code=$(curl -sS --max-time 30 -o "$resp" -w '%{http_code}' \
            -X POST "${base}/chat/completions" \
            -H "Authorization: Bearer $tok" \
            -H "content-type: application/json" \
            -A "$OC_UA" \
            -d "$body" 2>/dev/null) || code=""
        case "$code" in
            ""|5[0-9][0-9]) [ "$attempt" -lt 2 ] || break ;;
            *) break ;;
        esac
    done
    if [ "$code" = "200" ] &&
       jq -e '(.choices[0].message.tool_calls // []) | length > 0' "$resp" >/dev/null 2>&1; then
        tool="1"
    fi
    printf '%s\t%s\t%s\n' "${code:-000}" "$tool" \
        "$(tr -s '[:space:]' ' ' < "$resp" | cut -c1-160)"
    rm -f "$resp"
}

# The opencode model list and its probes. Field names inherit from resolveModels
# (same endpoint, same row shape) unless the opencode block sets its own `from`.
# That is another endpoint, so the block must then give idField, and nothing is
# inherited. prefer and requiresToolUse always come from resolveModels.
# Stdout: "<id>\t<1|0 called a tool>", one line per usable model, probe order.
# Returns 1 when the list cannot be had, 2 when nothing answers, 3 when the
# endpoint-type filter empties a list that did arrive.
oc_models() {
    local prof="$1" base="$2" tok="$3"
    local name cache notefile ocj rmj url idf ratiof ep prefer rt json curl_rc=0
    local rows order m line pcode ptc psnip firstfail="" probed=0 out=""

    name=$(basename "$prof" .json)
    cache="$OC_STATE/$name-opencode-models.cache.json"
    notefile="$OC_STATE/$name-opencode-lastfail.txt"
    mkdir -p "$OC_STATE" 2>/dev/null
    : > "$notefile" 2>/dev/null

    ocj=$(jqr '.opencode // {}' "$prof")
    rmj=$(jqr '.resolveModels // {}' "$prof")
    prefer=$(printf '%s' "$rmj" | jqr '.prefer // ""')
    rt=$(printf '%s' "$rmj" | jqr '.requiresToolUse // false')
    [ -n "$(printf '%s' "$ocj" | jqr '.from // empty')" ] && rmj='{}'
    url=$(printf '%s' "$ocj" | jqr --argjson rm "$rmj" '.from // $rm.from // empty')
    [ -n "$url" ] || return 1
    idf=$(printf '%s' "$ocj" | jqr --argjson rm "$rmj" '.idField // $rm.idField // "model_name"')
    ratiof=$(printf '%s' "$ocj" | jqr --argjson rm "$rmj" '.ratioField // $rm.ratioField // ""')
    ep=$(printf '%s' "$ocj" | jqr '.requiresEndpointType // ""')

    # Same fallback rule as resolve_models: a fetch that fails serves the last
    # good list for this bundle, in this namespace only.
    json=$(curl -sS --max-time 12 -A "$OC_UA" \
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
            [ -s "$notefile" ] || printf '%s' "no list and no cache" > "$notefile" 2>/dev/null
            return 1
        fi
    fi

    rows=$(printf '%s' "$json" | jqr --arg id "$idf" --arg rf "$ratiof" --arg ep "$ep" '
        .data[]
        | select($ep == "" or ((.supported_endpoint_types // []) | index($ep)))
        | select((.[$id] // "") != "")
        | [.[$id], ((.[$rf] // 999) | tostring)]
        | @tsv' 2>/dev/null) || rows=""
    [ -n "$rows" ] || return 3

    # Cost order, then name, with the bundle's preferred name hoisted. There is
    # no family ordering: opencode gets the whole list, not three Claude slots.
    order=$(printf '%s\n' "$rows" | sort -t$'\t' -k2,2n -k1,1 | cut -f1)
    if [ -n "$prefer" ]; then
        order=$({ printf '%s\n' "$rows" | awk -F'\t' -v p="$prefer" '$1 ~ p {print $1}'
                  printf '%s\n' "$order"; } | awk '!seen[$0]++')
    fi

    for m in $order; do
        [ -n "$m" ] || continue
        probed=$((probed+1))
        line=$(oc_probe "$base" "$m" "$tok")
        pcode=$(printf '%s' "$line" | cut -f1)
        ptc=$(printf '%s' "$line" | cut -f2)
        psnip=$(printf '%s' "$line" | cut -f3-)
        if [ "${DIAG:-0}" = "1" ]; then
            printf '%-6s tool=%s %s  %s\n' "$pcode" "$ptc" "$m" "$psnip" >&2
        fi
        if [ "$pcode" = "200" ] && { [ "$rt" != "true" ] || [ "$ptc" = "1" ]; }; then
            out="$out$m"$'\t'"$ptc"$'\n'
        elif [ -z "$firstfail" ]; then
            firstfail="$m -> HTTP $pcode $psnip"
        fi
    done
    if [ -z "$out" ]; then
        printf '%s' "$probed candidates probed; first refusal: $firstfail" > "$notefile" 2>/dev/null
        return 2
    fi
    printf '%s' "$out"
}

opencode_switch() {
    local prof="$1" tok="$2" name="$3"
    local base rows rc detail models src tmp_cfg tmp_cmd note="$OC_STATE/$name-opencode-lastfail.txt"

    base=$(jqr '.opencode.baseURL // empty' "$prof" 2>/dev/null)
    [ -n "$base" ] || not_switched "$prof has no opencode block: set opencode.baseURL"

    OC_UA="opencode/$(oc_version)"
    rows=$(oc_models "$prof" "$base" "$tok"); rc=$?
    detail=$(cat "$note" 2>/dev/null) || detail=""
    case "$rc" in
        1) not_switched "could not fetch the opencode model list${detail:+ ($detail)}." ;;
        2) not_switched "no model behind $base answered the opencode probe. $detail" ;;
        3) not_switched "the opencode list arrived, but no row survived requiresEndpointType \"$(jqr '.opencode.requiresEndpointType // ""' "$prof")\"." ;;
    esac

    # --diag stops before any file is written.
    if [ "${DIAG:-0}" = "1" ]; then
        printf -- '--- diag %s opencode (registry untouched) ---\n' "$name"
        printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %s tool_call=%s\n", $1, ($2 == "1" ? "true" : "false") }'
        exit 0
    fi

    models=$(printf '%s\n' "$rows" | jq -Rsc '
        split("\n") | map(select(. != "") | split("\t")
        | {key: .[0], value: {name: .[0], tool_call: (.[1] == "1")}}) | from_entries')

    # Merge, not replace: only this bundle's provider entry is rewritten. Other
    # providers and the user's default model stay as they are. A file with
    # comments is refused rather than rewritten without them.
    if [ -f "$OC_CFG" ]; then src=$(cat "$OC_CFG"); else src="{}"; fi
    [ -n "$src" ] || src="{}"
    tmp_cfg=$(mktemp) && tmp_cmd=$(mktemp) || not_switched "could not create temp files"
    if ! printf '%s' "$src" | jq --arg n "$name" --arg b "$base" --argjson m "$models" '
        .["$schema"] //= "https://opencode.ai/config.json"
        | .provider[$n] = {npm: "@ai-sdk/openai-compatible", name: $n, options: {baseURL: $b}, models: $m}' > "$tmp_cfg"; then
        rm -f "$tmp_cfg" "$tmp_cmd"
        not_switched "$OC_CFG is not plain JSON, so it was not rewritten. Remove its comments, then re-run"
    fi

    # The merged file and the command are validated before the first rename, so
    # a bad file never reaches a path opencode reads.
    cp "$OC_CMD_SRC" "$tmp_cmd" || not_switched "could not stage the command file"
    jq -e 'type == "object"' "$tmp_cfg" >/dev/null || { rm -f "$tmp_cfg" "$tmp_cmd"; not_switched "the merged config is not an object; nothing was written"; }

    mkdir -p "$(dirname "$OC_CMD")" || not_switched "could not create the opencode command directory"
    [ -f "$OC_CFG" ] && cp "$OC_CFG" "$OC_CFG.bak"
    mv "$tmp_cfg" "$OC_CFG" && mv "$tmp_cmd" "$OC_CMD" ||
        not_switched "could not move the synced opencode files into place"

    printf '/bundle %s (opencode)\n' "$name"
    printf '  models %s\n' "$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')"
    printf '\nRestart opencode to pick this up: it reads its config once at startup.\n\n'
    exit 0
}


# ---------------------------------------------------------------------------
# argument handling
case "${1:-}" in
    --help|-h)
        # Bounded by the comment block itself, not by a line number.
        awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
        exit 0 ;;
    ""|status)
        printf 'bundles: %s\n' "$(list_bundles)"
        exit 0 ;;
esac

# --diag <name>: probe every candidate and print each result, writing nothing.
DIAG=0
if [ "${1:-}" = "--diag" ]; then
    if [ -z "${2:-}" ]; then
        printf 'usage: bash bundle-switch.sh --diag <name>\n'
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

# opencode reads its key from its own auth.json, never from the Claude token file
token=$(jqr --arg n "$name" '.[$n].key // empty' "$OC_AUTH" 2>/dev/null) || token=""
[ -n "$token" ] || not_switched "$OC_AUTH has no key under \"$name\": add it there, then re-run"

opencode_switch "$prof" "$token" "$name"
