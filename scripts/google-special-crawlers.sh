#!/bin/bash

DEST="/home/blacklist/whitelists/google_special_crawlers_ipv4.txt"
TMP_FILE=$(mktemp)

# Baixar e filtrar os prefixos IPv4
if curl -sS 'https://developers.google.com/search/apis/ipranges/special-crawlers.json' \
  | jq -r '.prefixes[]?.ipv4Prefix? // empty' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
  | sort -u > "$TMP_FILE"; then

    # Verifica se o arquivo baixado realmente tem conteúdo
    if [[ -s "$TMP_FILE" ]]; then
        mv "$TMP_FILE" "$DEST"
        echo "✅ Lista atualizada com sucesso em $DEST"
    else
        echo "⚠️ Download vazio. Mantendo arquivo anterior."
        rm -f "$TMP_FILE"
    fi
else
    echo "❌ Falha no download. Mantendo arquivo anterior."
    rm -f "$TMP_FILE"
fi

