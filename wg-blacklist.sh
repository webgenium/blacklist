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

# 🔄 Concatenar todas as listas normalizadas
echo "➤ Concatenando listas normalizadas..."

cat "$PROCESS_DIR"/*.txt \
    | sort -u > "$FINAL_OUTPUT"

# ❌ Lista de bogons a excluir
BOGONS=(
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
    "255.255.255.255/32"
)

echo "➤ Removendo bogons da lista..."

BOGON_TEMP=$(mktemp)
printf "%s\n" "${BOGONS[@]}" > "$BOGON_TEMP"

grep -v -f "$BOGON_TEMP" "$FINAL_OUTPUT" > "${FINAL_OUTPUT}.filtered"
mv "${FINAL_OUTPUT}.filtered" "$FINAL_OUTPUT"
rm "$BOGON_TEMP"

echo "✅ Bogons removidos."

# ✅ Agregando com aggregate após remoção de bogons
echo "➤ Agregando com aggregate..."

cat "$FINAL_OUTPUT" | aggregate -q > "${FINAL_OUTPUT}.tmp"
mv "${FINAL_OUTPUT}.tmp" "$FINAL_OUTPUT"

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

# 📝 Commit e push automático no Git
echo "➤ Enviando mudanças para o Git..."

git commit -a --author="Fernando Hallberg <fernando@webgenium.com.br>" --message="Blacklist Update"
git push

echo "✅ Atualização enviada para o repositório Git."

