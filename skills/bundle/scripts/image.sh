#!/usr/bin/env bash
# Generate one image through the traxnode-image key and save it locally.
# Shared by opencode and Claude Code: the commands only call this script.
#
#   bash image.sh [-d <dir>] [-m <model>] <prompt...>
#   bash image.sh --list
#
# -d <dir> saves there instead of ~/Pictures/opencode-images. The directory is
# created when missing. -m <model> picks the model, default gpt-image-2.5-sunburst.
# Options and values must not contain spaces, because the words after each option
# are taken one by one: a quoted "-d <dir> -m <model> <prompt>" string parses too.
#
# Before generating, the model is checked against the key's /models list (free).
# A model missing there fails at once. A listed model can still fail upstream
# (for example 503 "No available channel"); that error is reported as is.
#
# The key is read from opencode's auth.json under "traxnode-image", the base URL
# from bundles/traxnode-image.json.
#
# This script ALWAYS exits 0, so a failure reaches the caller as
# `IMAGE FAILED — <reason>` on stdout instead of an aborted command.

set -uo pipefail

AUTH="$HOME/.local/share/opencode/auth.json"
PROFILE="$HOME/.claude/bundles/traxnode-image.json"
OUT_DIR="$HOME/Pictures/opencode-images"
MODEL="gpt-image-2.5-sunburst"
list_only=0

failed() { printf '\nIMAGE FAILED — %s\n\n' "$1"; exit 0; }

# Every jq output goes through this: jq on Windows ends lines with CRLF.
jqr() { jq -r "$@" | tr -d '\r'; }

# Consume leading options one word at a time; what remains is the prompt.
input="$*"
while :; do
    read -r first rest <<< "$input"
    case "$first" in
        -d)
            read -r dir rest <<< "$rest"
            [ -n "$dir" ] || failed "-d needs a directory"
            OUT_DIR="${dir/#\~/$HOME}"
            input="$rest" ;;
        -m)
            read -r model rest <<< "$rest"
            [ -n "$model" ] || failed "-m needs a model id"
            MODEL="$model"
            input="$rest" ;;
        --list)
            list_only=1
            input="$rest" ;;
        *) break ;;
    esac
done
prompt="$input"
[ "$list_only" = 1 ] || [ -n "$prompt" ] || failed "usage: image.sh [-d <dir>] [-m <model>] <prompt>"
[ -f "$PROFILE" ] || failed "no bundle file: $PROFILE"
base=$(jqr '.opencode.baseURL // empty' "$PROFILE")
[ -n "$base" ] || failed "$PROFILE has no opencode.baseURL"
key=$(jqr '."traxnode-image".key // empty' "$AUTH" 2>/dev/null) || key=""
[ -n "$key" ] || failed "$AUTH has no key under \"traxnode-image\""

# The image models this key can see. Listing is free; generating is not.
models=$(mktemp) || failed "could not create a temp file"
trap 'rm -f "$models" "$resp"' EXIT
resp=""
code=$(curl -sS --max-time 60 -o "$models" -w '%{http_code}' "${base}/models" \
    -H "Authorization: Bearer $key") || code="000"
[ "$code" = "200" ] || failed "could not read ${base}/models: HTTP $code"
ids=$(jqr '.data[].id' "$models" | grep -i 'image' || true)

if [ "$list_only" = 1 ]; then
    printf '%s\n' "$ids"
    exit 0
fi
printf '%s\n' "$ids" | grep -Fxq -- "$MODEL" ||
    failed "model $MODEL is not listed for this key. Image models: $(printf '%s' "$ids" | tr '\n' ' ')"

body=$(jq -nc --arg m "$MODEL" --arg p "$prompt" \
    '{model: $m, prompt: $p, size: "1024x1024", quality: "medium", n: 1}')
resp=$(mktemp) || failed "could not create a temp file"

code=$(curl -sS --max-time 300 -o "$resp" -w '%{http_code}' -X POST "${base}/images/generations" \
    -H "Authorization: Bearer $key" -H "content-type: application/json" -d "$body") || code="000"
if [ "$code" != "200" ]; then
    failed "HTTP $code from $MODEL: $(tr -s '[:space:]' ' ' < "$resp" | cut -c1-300). Try another -m; see --list"
fi

url=$(jqr '.data[0].url // empty' "$resp")
b64=$(jqr '.data[0].b64_json // empty' "$resp")
mkdir -p "$OUT_DIR" || failed "could not create $OUT_DIR"
dest="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$RANDOM.png"
if [ -n "$b64" ]; then
    printf '%s' "$b64" | base64 -d > "$dest" || failed "could not decode the image"
elif [ -n "$url" ]; then
    curl -sS --max-time 120 -o "$dest" "$url" || failed "could not download the image"
else
    failed "response had neither url nor b64_json"
fi

printf '\nimage saved: %s\n\n' "$dest"
exit 0
