#!/usr/bin/env bash
# Install what web-search needs: uv, the jina CLI, and a JINA_API_KEY.
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
    python -m pip install --user uv
fi

if ! command -v jina >/dev/null 2>&1; then
    uv tool install jina-cli --with 'httpx[socks]'
fi

if ! command -v jina >/dev/null 2>&1; then
    printf 'jina: installed but not on PATH yet; open a new shell or run: uv tool update-shell\n' >&2
fi

if [[ -z ${JINA_API_KEY:-} ]]; then
    printf 'jina: JINA_API_KEY is not set\n  get a free key: https://jina.ai/?sui=apikey\n  persist it:     setx JINA_API_KEY <key>\n' >&2
    exit 1
fi

printf 'web-search deps ok: %s, %s\n' "$(uv --version)" "$(jina --version)"
