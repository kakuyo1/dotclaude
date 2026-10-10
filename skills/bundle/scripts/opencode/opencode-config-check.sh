#!/usr/bin/env bash
# Assert the opencode config that the sync writes into is well-formed. Prints
# provider and key names only, never a key value.
#
#   bash opencode-config-check.sh
#
# Exits 1 on the first failed assertion, so it can gate a manual run.

set -uo pipefail

cfg="$HOME/.config/opencode/opencode.jsonc"
auth="$HOME/.local/share/opencode/auth.json"
fail=0
check() { local label="$1"; shift; if "$@"; then printf 'ok    %s\n' "$label"; else printf 'FAIL  %s\n' "$label"; fail=1; fi; }

check "config is an object" jq -e 'type == "object"' "$cfg"
check "auth is an object" jq -e 'type == "object"' "$auth"

# no context-suffix leaked into a model id, and no limit (output is unknown)
check "no [1m] suffix in ids" jq -e '[.provider // {} | .[].models // {} | keys[] | select(test("\\[1m\\]"))] | length == 0' "$cfg"
check "no limit key" jq -e '[.provider // {} | .[].models // {} | .[] | select(has("limit"))] | length == 0' "$cfg"

# every bundle-synced provider has a matching auth entry
for p in $(jq -r '.provider // {} | keys[]' "$cfg"); do
    if jq -e --arg p "$p" 'has($p)' "$auth" >/dev/null; then
        check "auth entry for $p" jq -e --arg p "$p" '.[$p].key | type == "string" and length > 0' "$auth"
    fi
done

printf 'providers in opencode.jsonc: %s\n' "$(jq -r '.provider // {} | keys | join(" ")' "$cfg")"
exit "$fail"
