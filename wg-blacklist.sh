#!/bin/bash

BASEDIR=/home/blacklist
CONFIG_FILE="${BASEDIR}/wg-blacklist.conf"
BLACKLIST_DIR="${BASEDIR}/blacklists"
PROCESS_DIR="${BASEDIR}/processamento"
FINAL_OUTPUT="${BASEDIR}/wg-blacklist.txt"
MIKROTIK_SCRIPT="${BASEDIR}/webgenium-blacklist.rsc"
ADDRESS_LIST_NAME="webgenium-blacklist"
WHITELIST_DIR="${BASEDIR}/whitelists"
AGGREGATE=/usr/local/bin/aggregate
NO_DOWNLOAD=0

# Verifica opção -n (no download)
if [[ "$1" == "-n" ]]; then
    NO_DOWNLOAD=1
    echo "➤ Modo sem download ativado (-n): processando apenas arquivos existentes."
fi

mkdir -p "$BLACKLIST_DIR" "$PROCESS_DIR" "$WHITELIST_DIR"

echo "➤ Limpando a pasta de processamento dos arquivos."

rm -f "${PROCESS_DIR}/*"

# ✅ Executar scripts auxiliares (whitelists, atualizações externas, etc)
SCRIPTS_DIR="${BASEDIR}/scripts"

if [[ -d "$SCRIPTS_DIR" ]]; then
    echo "➤ Executando scripts auxiliares em ${SCRIPTS_DIR}..."
    for script in "$SCRIPTS_DIR"/*; do
        if [[ -x "$script" && -f "$script" ]]; then
            echo "   ▶ Executando: $script"
            "$script"
        else
            echo "   ⚠️ Ignorando $script (não é executável)"
        fi
    done
else
    echo "ℹ️ Nenhuma pasta de scripts encontrada em ${SCRIPTS_DIR}. Pulando etapa."
fi


# Regex para IPs com ou sem CIDR
IP_REGEX='([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'

while IFS=";" read -r LIST_NAME URL; do
    [[ -z "$LIST_NAME" || -z "$URL" || "$LIST_NAME" =~ ^# ]] && continue

    RAW_FILE="${BLACKLIST_DIR}/${LIST_NAME}.txt"
    OUT_FILE="${PROCESS_DIR}/${LIST_NAME}.txt"

    if [[ "$NO_DOWNLOAD" -eq 0 ]]; then
        DOWNLOAD=1
        if [[ -f "$RAW_FILE" ]]; then
            # Verifica se o arquivo tem menos de 12h
	    file_age_hours=$(( ( $(date +%s) - $(stat -c %Y "$RAW_FILE") ) / 3600 ))
	    if (( file_age_hours < 12 )); then
	        DOWNLOAD=0
	        echo "⏩ Pulando download de $LIST_NAME (arquivo atualizado há ${file_age_hours}h)."
	    else
                echo "📥 Arquivo antigo (${file_age_hours}h). Download será feito novamente."
            fi
        fi

        if [[ "$DOWNLOAD" -eq 1 ]]; then
            echo "Baixando lista: $LIST_NAME"
            if [[ "$URL" == rsync://* ]]; then
                URLDOWNLOAD=$(echo $URL | cut -d '/' -f3-)
                echo "  rsync -z ${URLDOWNLOAD} ${RAW_FILE}"
                if rsync -z "$URLDOWNLOAD" "$RAW_FILE"; then
                    echo "  ➤ Download via rsync concluído."
                else
                    echo "  ⚠️  Falha ao baixar via rsync: $URL"
                fi
            else
                TEMP_FILE=$(mktemp)
                if curl -fsSL "$URL" -o "$TEMP_FILE"; then
                    echo "  ➤ Download via HTTP concluído."
                    mv "$TEMP_FILE" "$RAW_FILE"
                else
                    echo "  ⚠️  Falha ao baixar $URL. Mantendo arquivo atual."
                    rm -f "$TEMP_FILE"
                fi
            fi
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
cat "$PROCESS_DIR"/*.txt | sort -u > "$FINAL_OUTPUT"

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

# ✅ Carregar whitelists (se existirem) e filtrar do resultado final (CIDR-aware)
WHITELIST_TEMP=$(mktemp)
if compgen -G "${WHITELIST_DIR}/*.txt" > /dev/null; then
    echo "➤ Carregando whitelists de ${WHITELIST_DIR}..."
    # Extrai e normaliza (IP -> /32)
    grep -Eho "$IP_REGEX" "${WHITELIST_DIR}"/*.txt 2>/dev/null \
        | sort -u \
        | awk 'BEGIN{FS="/"}{ if(NF==1){print $1"/32"} else {print $1"/"$2} }' \
        > "$WHITELIST_TEMP"

    if [[ -s "$WHITELIST_TEMP" ]]; then
        echo "➤ Subtraindo whitelists do conjunto final (tratando sobreposições corretamente)..."
        python3 - "$FINAL_OUTPUT" "$WHITELIST_TEMP" > "${FINAL_OUTPUT}.nowhite" <<'PYCODE'
import sys, ipaddress

def read_networks(path):
    nets=[]
    with open(path, 'r') as f:
        for line in f:
            s=line.strip()
            if not s: continue
            try:
                nets.append(ipaddress.ip_network(s, strict=False))
            except ValueError:
                pass
    return nets

def subtract_network(net, wl):
    res=[net]
    for w in wl:
        new=[]
        for n in res:
            if n.version != w.version or not n.overlaps(w):
                new.append(n); continue

            # w cobre n por inteiro -> elimina
            if w.network_address <= n.network_address and w.broadcast_address >= n.broadcast_address:
                continue

            start=int(n.network_address); end=int(n.broadcast_address)
            wstart=int(w.network_address); wend=int(w.broadcast_address)

            ranges=[]
            if start < wstart:
                ranges.append((start, min(end, wstart-1)))
            if wend < end:
                ranges.append((max(start, wend+1), end))

            for a,b in ranges:
                cur=a
                while cur<=b:
                    # maior bloco alinhado ao cur, sem ultrapassar b
                    max_size = cur & -cur
                    max_len = (max_size.bit_length()-1)
                    remaining = b - cur + 1
                    while (1<<max_len) > remaining:
                        max_len -= 1
                    prefix = 32 if n.version==4 else 128
                    plen = prefix - max_len
                    new.append(ipaddress.ip_network((cur, plen)))
                    cur += (1<<max_len)
        res=new
    return res

black = read_networks(sys.argv[1])
white = read_networks(sys.argv[2])

result=[]
for n in black:
    result.extend(subtract_network(n, white))

# Minimiza o resultado
collapsed = ipaddress.collapse_addresses(result)
for n in collapsed:
    print(str(n))
PYCODE
        mv "${FINAL_OUTPUT}.nowhite" "$FINAL_OUTPUT"
        echo "✅ Whitelist aplicada."
    else
        echo "ℹ️  Nenhum IP/rede válido encontrado nas whitelists. Prosseguindo sem alterações."
    fi
else
    echo "ℹ️  Nenhum arquivo de whitelist encontrado em ${WHITELIST_DIR}. Prosseguindo."
fi
rm -f "$WHITELIST_TEMP" 2>/dev/null

# ➕ Agregar com aggregate para minimizar ainda mais
echo "➤ Agregando com aggregate..."
cat "$FINAL_OUTPUT" | ${AGGREGATE} -q > "${FINAL_OUTPUT}.tmp"
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
pushd "${BASEDIR}" >/dev/null
git commit -a --author="Fernando Hallberg <fernando@webgenium.com.br>" --message="Blacklist Update"
git push
popd >/dev/null
echo "✅ Atualização enviada para o repositório Git."

