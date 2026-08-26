# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que é este repositório

Pipeline em Bash que agrega várias blocklists públicas de IPs, subtrai whitelists,
minimiza os prefixos e publica dois artefatos no próprio repositório Git:

- `wg-blacklist.txt` — lista final de CIDRs IPv4, uma por linha
- `webgenium-blacklist.rsc` — script RouterOS que recria a address-list `webgenium-blacklist`

Os roteadores MikroTik dos clientes baixam o `.rsc` direto do GitHub
(ver `webgenium-install.rst` para os `/system script` + `/system scheduler` instalados no roteador).
Ou seja: **o repositório é o canal de distribuição** — um commit/push errado vai para produção.

## Comandos

```bash
./wg-blacklist.sh          # pipeline completo: baixa, processa, agrega, gera .rsc, COMMITA E DÁ PUSH
./wg-blacklist.sh -n       # sem download: reprocessa só o que já está em blacklists/
```

Não há build, testes nem lint. Para validar uma mudança sem publicar, comente o bloco final
de `git commit`/`git push` em `wg-blacklist.sh` (últimas linhas) ou rode em uma cópia do diretório —
o script sempre termina fazendo push em `main`.

Execução automática: cron do usuário `fernando`, diariamente às 02:00,
com saída acumulada em `log/cron.log` (o log é a única fonte de diagnóstico de falhas).

Dependências externas: `aggregate` (/usr/bin/aggregate), `python3`, `jq`, `curl`, `rsync`.

## Arquitetura do pipeline

`wg-blacklist.sh` é o único orquestrador. Começa limpando `processamento/*.txt`, de modo que uma
fonte comentada em `wg-blacklist.conf` some do resultado já na execução seguinte. Depois roda:

1. **Scripts auxiliares** — executa todo arquivo executável em `scripts/`. Cada um desses scripts
   é um gerador de *whitelist*: baixa um JSON de provedor (GitHub `api.github.com/meta`,
   Microsoft 365 endpoints, ranges do Googlebot/crawlers), extrai só CIDRs IPv4 com `jq` e grava
   em `whitelists/*.txt`. Todos seguem o mesmo contrato: baixa para tmp, valida que o resultado
   não está vazio, e **em caso de falha sai com 0 mantendo o arquivo antigo** — nunca deixa a
   whitelist vazia, porque whitelist vazia significa bloquear Google/GitHub/Microsoft.
   Ao adicionar um provedor novo, copie `scripts/microsoft.sh` e mantenha esse contrato.
2. **Download das blocklists** — lê `wg-blacklist.conf` (formato `NOME;URL`, `#` comenta a linha),
   grava cru em `blacklists/NOME.txt`. Cache de 12h por mtime; URLs `rsync://` usam `rsync -z`,
   o resto usa `curl`. Falha de download preserva o arquivo anterior.
3. **Normalização** — extrai IPs com regex, joga fora `0.*`, e força todo IP solto para `/32`,
   gravando em `processamento/NOME.txt`.
4. **Concatenação + remoção de bogons** — `sort -u` de tudo em `processamento/`, menos a lista
   de bogons hardcoded no script (RFC1918, loopback, TEST-NET, etc).
5. **Subtração das whitelists** — heredoc Python inline dentro do `.sh`. É a única parte não trivial:
   faz subtração CIDR-aware (um /24 blacklistado com um /32 whitelistado vira os blocos alinhados
   restantes) e depois `ipaddress.collapse_addresses`. Não substitua por `grep -v`: as sobreposições
   parciais são o ponto.
6. **Agregação** — `aggregate -q` para minimizar os prefixos.
7. **Geração do `.rsc`** — cabeçalho que remove a address-list inteira, seguido de um
   `add list=webgenium-blacklist address=<cidr>` por linha.
8. **`git commit -a` + `git push`** com autor fixo e mensagem "Blacklist Update".

## Fontes

- Blocklists: entradas em `wg-blacklist.conf`. Para desativar uma fonte, comente a linha.
- Whitelists: qualquer `.txt` em `whitelists/` entra na subtração — tanto os gerados por `scripts/`
  quanto os mantidos à mão (`cloudflare.txt`, `brevo.txt`, `wordfence.txt`). Para liberar um IP
  ou range, basta acrescentá-lo a um `.txt` ali; o parser aceita IP solto ou CIDR.

## Segredos (.env)

URLs em `wg-blacklist.conf` podem conter placeholders `${VAR}` (hoje só `ABUSEIPDB_KEY`).
O `wg-blacklist.sh` carrega `.env` (não versionado, `chmod 600`) e expande esses placeholders por
substituição de string — sem `eval`. Se a variável não estiver definida, **apenas aquela lista é
pulada com aviso** e o resto do pipeline segue. `.env.example` documenta as chaves esperadas.

## Pegadinhas conhecidas

- `BASEDIR` está **hardcoded** como `/home/fernando/dev/blacklist` no `wg-blacklist.sh` e o caminho
  absoluto de destino se repete em cada script de `scripts/`. Mover o repositório exige editar todos.
- `.gitignore` ignora `blacklists/`, `whitelists/`, `processamento/`, `tmp/`, `backup/`, `log/` e `.env`.
  Nada dessas pastas é versionado — inclusive as whitelists mantidas à mão
  (`cloudflare.txt`, `wordfence.txt`, `brevo.txt`), que existem apenas no disco desta máquina.
- A chave do AbuseIPDB que ficava em claro no `wg-blacklist.conf` continua no **histórico do Git**
  de um repositório público. Só rotacionar a chave resolve.
- O pipeline é **IPv4-only** de ponta a ponta (regex, normalização para `/32`, filtros dos scripts).
