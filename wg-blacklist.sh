#!/bin/bash

CONFIG_FILE="wg-blacklists.conf"
BLACKLIST_DIR="./blacklists"
PROCESS_DIR="./processamento"
FINAL_OUTPUT="wg-blacklist.txt"
MIKROTIK_SCRIPT="webgenium-blacklist.rsc"
ADDRESS_LIST_NAME="webgenium-blacklist"
NO_DOWNLOAD=0

# Verifica opção -n (no download)
if [[ "$1" == "-n" ]]; then
    NO_DOWNLOAD=1
    echo "➤ Modo sem download ativado (-n): processando apenas arquivos existentes."
fi

mkdir -p "$BLACKLIST_DIR" "$PROCESS_DIR"

# Regex para IPs com ou sem CIDR
IP_REGEX='([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'

while IFS=";" read -r LIST_NAME URL; do
    [[ -z "$LIST_NAME" || -z "$URL" || "$LIST_NAME" =~ ^# ]] && continue

    RAW_FILE="${BLACKLIST_DIR}/${LIST_NAME}.txt"
    OUT_FILE="${PROCESS_DIR}/${LIST_NAME}.txt"

    if [[ "$NO_DOWNLOAD" -eq 0 ]]; then
        echo "Baixando lista: $LIST_NAME"
        TEMP_FILE=$(mktemp)

        if curl -fsSL "$URL" -o "$TEMP_FILE"; then
            echo "  ➤ Download realizado. Substituindo arquivo."
            mv "$TEMP_FILE" "$RAW_FILE"
        else
            echo "  ⚠️  Falha ao baixar $URL. Mantendo arquivo atual."
            rm -f "$TEMP_FILE"
        fi
    fi

    if [[ -f "$RAW_FILE" ]]; then
        echo "  ➤ Processando $RAW_FILE..."

        grep -Eo "$IP_REGEX" "$RAW_FILE" \
            | grep -Ev '^0\.' \
            | sort -u \
            | awk '
                BEGIN { FS="/" }
                {
                    if (NF == 1) {
                        print $1 "/32"
                    } else {
                        print $1 "/" $2
                    }
                }
            ' > "$OUT_FILE"

        echo "  ➤ IPs normalizados salvos em: $OUT_FILE"
    else
        echo "  ⚠️  Arquivo não encontrado: $RAW_FILE. Pulei."
    fi

done < "$CONFIG_FILE"

# 🔄 Agregando todos os IPs em um único arquivo
echo "➤ Agregando todas as listas em $FINAL_OUTPUT..."

cat "$PROCESS_DIR"/*.txt \
    | sort -u \
    | aggregate -q > "$FINAL_OUTPUT"

echo "✅ Arquivo final agregado: $FINAL_OUTPUT"

# 🛠️ Gerar script MikroTik
echo "➤ Gerando script MikroTik em $MIKROTIK_SCRIPT..."

{
    echo "/ip firewall address-list"
    echo ":foreach i in=[find list=$ADDRESS_LIST_NAME] do={ remove \$i }"
    echo ""
    while read -r CIDR; do
        [[ -z "$CIDR" ]] && continue
        echo "add list=$ADDRESS_LIST_NAME address=$CIDR"
    done < "$FINAL_OUTPUT"
} > "$MIKROTIK_SCRIPT"

echo "✅ Script MikroTik gerado: $MIKROTIK_SCRIPT"

git commit -a --author="Fernando Hallberg <fernando@webgenium.com.br>" --message="Blacklist Update"
git push
