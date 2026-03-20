#!/usr/bin/env bash

set -u

URL="https://api.github.com/meta"
DEST="/home/blacklist/whitelists/github.txt"
TMP_JSON="$(mktemp)"
TMP_OUT="$(mktemp)"

cleanup() {
    rm -f "$TMP_JSON" "$TMP_OUT"
}
trap cleanup EXIT

mkdir -p "$(dirname "$DEST")" || exit 1

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$URL" -o "$TMP_JSON"; then
    echo "Falha no download. Mantendo arquivo antigo." >&2
    exit 0
fi

if ! jq -r '
    .[]
    | select(type == "array")
    | .[]
    | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$"))
' "$TMP_JSON" | sort -u > "$TMP_OUT"; then
    echo "Falha ao processar JSON. Mantendo arquivo antigo." >&2
    exit 0
fi

if [[ ! -s "$TMP_OUT" ]]; then
    echo "Nenhum IPv4 CIDR encontrado. Mantendo arquivo antigo." >&2
    exit 0
fi

mv "$TMP_OUT" "$DEST"
echo "Arquivo atualizado com sucesso em: $DEST"
