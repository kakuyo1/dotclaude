#!/usr/bin/env bash
# Characterize a provider before any bundle exists.
#
#   bash bundle-recon.sh <base-url>
#   bash bundle-recon.sh https://api.example.com
#
# The /bundle --new flow needs four facts before it can choose a list endpoint,
# and none of them is about the credential, so this sends no Authorization
# header and reads no .local.json. Run it first; it answers:
#
#   fingerprint     which relay software answers, from headers that ride on
#                   every response (a bare origin serves them too)
#   anthropic route whether POST <base>/v1/messages exists at all. A key-free
#                   call separates "route exists, key missing" from "no such
#                   route", and a relay with no Anthropic route cannot be
#                   configured by this flow however good its catalog looks.
#   catalog         what the instance publishes, grouped by endpoint type and by
#                   group, and whether any row offers an anthropic endpoint type
#                   at all. A count of zero there is normal, not fatal: measured,
#                   a relay whose every row said "openai" still answered
#                   /v1/messages with a tool_use block.
#   reachability    whether this host answers directly or only through the proxy,
#                   which is exactly what the bundle's NO_PROXY encodes.
#
# Read-only: it writes no bundle and no registry entry. Needs bash, curl and jq.
# Where bash is unavailable (some Windows machines), references/new.md step 3
# names the same requests to make by hand.

set -uo pipefail

base="${1:-}"
if [ -z "$base" ]; then
    printf 'usage: bundle-recon.sh <base-url>\n'
    printf 'example: bundle-recon.sh https://api.example.com\n'
    exit 0
fi
base="${base%/}"

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 ||
        { printf 'bundle-recon needs %s on PATH\n' "$tool"; exit 0; }
done

say() { printf '\n== %s\n' "$1"; }
# one JSON in, one jq program, one line out; empty on any failure so a wrong
# shape degrades to a blank rather than to a wrong number
j() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
# Truncate bytes without leaving half a multi-byte character behind: these
# strings are frequently Chinese, and a cut through a character renders as a
# replacement glyph in the very output being read.
trim() {
    if command -v iconv >/dev/null 2>&1; then
        # iconv reports the deliberate cut as an error on stderr; the -c flag
        # already drops it, so the report is noise about a truncation we asked
        # for. This is the one place discarding stderr is correct.
        head -c "$1" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null
    else
        head -c "$1"
    fi
}

# ---------------------------------------------------------------- fingerprint
say "fingerprint  $base"
hdr=$(curl -sS -m 15 -D - -o /dev/null "$base/" 2>&1) || hdr=""
if [ -z "$hdr" ]; then
    printf '  no response from %s/  (host down, wrong scheme, or blocked)\n' "$base"
else
    printf '%s\n' "$hdr" |
        grep -iE '^(server|x-new-api-version|x-oneapi-request-id|x-powered-by):' |
        sed 's/^/  /'
    if printf '%s' "$hdr" | grep -qi '^x-new-api-version'; then
        printf '  => New API (version header present)\n'
    elif printf '%s' "$hdr" | grep -qi '^x-oneapi-request-id'; then
        # one-api lineage only: New API is a fork of one-api and keeps this
        # header, so it alone does not name the software. It does mean the
        # /api/pricing and /api/status shapes below are likely to apply.
        printf '  => one-api lineage (New API is a fork and keeps this header)\n'
    else
        printf '  => no relay fingerprint header; confirm the family from the docs\n'
    fi
fi

# ------------------------------------------------------------ anthropic route
say "anthropic route  POST $base/v1/messages  (no key sent)"
code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    -X POST "$base/v1/messages" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"x","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    2>/dev/null) || code=""
case "$code" in
    401|403) printf '  %s  route exists; only the key or group was refused\n' "$code" ;;
    200)     printf '  %s  route answered with no key at all (open, or the proxy answered)\n' "$code" ;;
    404)     printf '  %s  no route at this path. Try the bare origin, or read the docs\n' "$code"
             printf '         (a relay with no Anthropic route cannot be configured here)\n' ;;
    "")      printf '  no response\n' ;;
    *)       printf '  %s  inspect the body by hand\n' "$code" ;;
esac

# ------------------------------------------------------------- instance status
say "instance status  GET $base/api/status"
st=$(curl -sS -m 15 "$base/api/status") || st=""
if [ -z "$st" ] || ! printf '%s' "$st" | jq -e . >/dev/null 2>&1; then
    printf '  not public JSON (gated, or not a New API instance)\n'
else
    groups=$(j "$st" '[.data.group_ratio // .data.usable_group // {} | keys[]] | join(", ")')
    printf '  groups       %s\n' "${groups:-<none published>}"
    printf '  currency     %s\n' "$(j "$st" '.data.custom_currency_symbol // "<none>"')"
    printf '  docs         %s\n' "$(j "$st" '.data.docs_link // "<none>"')"
    ann=$(j "$st" '(.data.announcements // [])
        | map(if type == "object" then (.content // "") else tostring end)
        | join(" | ")' | tr -s ' \n' ' ' | trim 220)
    printf '  announcements %s\n' "${ann:-<none>}"
fi

# --------------------------------------------------------------------- catalog
say "catalog  GET $base/api/pricing"
pr=$(curl -sS -m 20 "$base/api/pricing") || pr=""
if [ -z "$pr" ] || ! printf '%s' "$pr" | jq -e '.data' >/dev/null 2>&1; then
    printf '  not a public priced catalog (gated, or not New API)\n'
    printf '  fall back to GET %s/models with idField "id"\n' "$base"
else
    printf '  rows                                 %s\n' \
        "$(j "$pr" '.data | length')"
    printf '  endpoint types                       %s\n' \
        "$(j "$pr" '[.data[].supported_endpoint_types[]?] | group_by(.) | map("\(.[0]):\(length)") | join(" ")')"
    printf '  rows offering an anthropic endpoint  %s\n' \
        "$(j "$pr" '[.data[] | select((.supported_endpoint_types // []) | index("anthropic"))] | length')"
    printf '  models named claude-*                %s\n' \
        "$(j "$pr" '[.data[].model_name | select(test("claude"; "i"))] | length')"
    printf '  groups                               %s\n' \
        "$(j "$pr" '[.data[].enable_groups[]?] | group_by(.) | map("\(.[0]):\(length)") | join(" ")')"
fi

# ---------------------------------------------------------------- reachability
say "reachability  (this decides the bundle's NO_PROXY)"
host=$(printf '%s' "$base" | sed -E 's#^[a-z]+://##; s#/.*$##')
direct=$(curl -sS -m 12 --noproxy '*' -o /dev/null -w '%{http_code}' "$base/" 2>/dev/null) || direct=""
if [ -n "${HTTPS_PROXY:-}${HTTP_PROXY:-}" ]; then
    prox=$(curl -sS -m 12 -x "${HTTPS_PROXY:-$HTTP_PROXY}" -o /dev/null -w '%{http_code}' "$base/" 2>/dev/null) || prox=""
    printf '  direct  %s\n  proxy   %s\n' "${direct:-unreachable}" "${prox:-unreachable}"
else
    printf '  direct  %s\n  proxy   no HTTP(S)_PROXY set\n' "${direct:-unreachable}"
fi
printf '  host    %s\n' "$host"
if [ -n "$direct" ]; then
    printf '  => reachable directly: NO_PROXY "localhost,127.0.0.1,::1,%s"\n' "$host"
elif [ -n "${prox:-}" ]; then
    printf '  => reachable only through the proxy: keep it OUT of NO_PROXY\n'
else
    printf '  => not reachable either way: check the URL, the host, or the proxy itself\n'
fi
