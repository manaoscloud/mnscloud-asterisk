# Asterisk PABX

## Objetivo

O instalador `scripts/install-asterisk.sh` provisiona um PABX Asterisk multi-tenant usando
PJSIP Realtime com MariaDB/ODBC. Ele segue o mesmo padrão operacional dos instaladores
FreeSWITCH, Kamailio e OpenSIPS:

- cria/carrega o node UUID em `/etc/mnscloud/pabx/node.uuid`;
- tenta vincular o node UUID ao `VoipPabxServer` cadastrado com `VpsEngine = 'asterisk'`;
- preserva arquivos originais com `.bkp`;
- gera configuração limpa controlada pelo Manaos Cloud;
- valida serviço e módulos básicos após a instalação.

## Versão

O Asterisk não mantém repositório oficial de pacotes Linux equivalente ao Kamailio/OpenSIPS.
Por isso o instalador usa o source oficial:

```text
https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
```

O valor pode ser sobrescrito via `ASTERISK_VERSION` ou `ASTERISK_SOURCE_URL`.

## Realtime MariaDB

As tabelas físicas seguem o padrão do projeto com `Asterisk` + CamelCase:

```text
AsteriskTransport
AsteriskGlobal
AsteriskEndpoint
AsteriskAuth
AsteriskAor
AsteriskContact
AsteriskDomainAlias
AsteriskEndpointIdentify
AsteriskExtension
AsteriskCdr
AsteriskCel
```

Os nomes das colunas dessas tabelas preservam os campos esperados pelo Asterisk Realtime
(`id`, `aors`, `auth`, `context`, `match`, etc.). O nome físico da tabela é nosso, mas o
mapeamento é feito em `/etc/asterisk/extconfig.conf`.

## Arquivos Gerados

O instalador escreve:

```text
/etc/odbc.ini
/etc/asterisk/asterisk.conf
/etc/asterisk/modules.conf
/etc/asterisk/pjsip.conf
/etc/asterisk/extconfig.conf
/etc/asterisk/sorcery.conf
/etc/asterisk/res_odbc.conf
/etc/asterisk/extensions.conf
/etc/asterisk/logger.conf
/etc/asterisk/cdr_adaptive_odbc.conf
/etc/asterisk/cel_odbc.conf
```

## Heartbeat

O instalador valida o cadastro com:

```bash
NODE_UUID="$(tr -d '[:space:]' < /etc/mnscloud/pabx/node.uuid)"

curl -i -X POST "https://dev1.publichost.cloud/api/v1/pabx/asterisk/heartbeat?node_uuid=${NODE_UUID}" \
  -H "Content-Type: application/json" \
  --data "{\"hostname\":\"$(hostname -f 2>/dev/null || hostname)\",\"engine\":\"asterisk\"}"
```

Resposta esperada:

```json
{
  "status": "success",
  "data": {
    "serverUUID": "...",
    "engine": "asterisk"
  }
}
```

## Diagnóstico

```bash
systemctl status asterisk --no-pager
asterisk -V
asterisk -rx "core show uptime"
asterisk -rx "odbc show"
asterisk -rx "module show like res_odbc"
asterisk -rx "module show like res_pjsip"
asterisk -rx "pjsip show endpoints"
asterisk -rx "pjsip show contacts"
ss -lntup | grep 5060
journalctl -u asterisk -n 100 --no-pager
```

Para SIP:

```bash
sngrep
tcpdump -ni any port 5060
ngrep -d any -W byline port 5060
```

## Próximos Passos

O instalador entrega a base Asterisk Realtime. A sincronização de entidades canônicas
(`VoipPabxExtension`, `VoipPabxTrunk`, `VoipPabxInboundRoute`, `VoipPabxOutboundRoute`) para
as tabelas `Asterisk*` deve ser feita pelo worker PABX Asterisk.
