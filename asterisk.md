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

## Codecs

O padrão de mídia do Manaos é:

```text
OPUS,PCMU,PCMA,G729,G722,H264
```

G.729 usa a biblioteca gratuita `bcg729` dos repositórios Debian (`libbcg729-0` e
`libbcg729-dev`). O instalador não instala codecs comerciais Sangoma/Digium e desabilita nomes
comerciais conhecidos no `modules.conf`. Se um pacote oficial `asterisk-codec-bcg729` estiver
disponível no repositório configurado, ele é instalado; caso contrário o instalador compila
`codec_g729.so` localmente usando o fonte versionado em `asterisk/codecs/asterisk-g72x` e a
biblioteca `libbcg729` do Debian.

O fonte local é baseado no projeto `asterisk-g72x`, que suporta Asterisk 1.4 até 22.x. O instalador
prefere esse diretório local para evitar download online em reinstalações futuras. Se o diretório
local não existir, o fallback é baixar `ASTERISK_G72X_SOURCE_URL` e fixar
`ASTERISK_G72X_SOURCE_REF`; o padrão é o commit
`55a7b8246c8ad3f32e50a033529e5a52c11a5592`.

H.264 é tratado como codec de vídeo/pass-through. O módulo `format_h264` é habilitado no build
quando disponível. A seleção efetiva vem dos campos do Provider, Extension e Trunk; no Realtime
Asterisk a engine deve materializar `PCMU` como `ulaw`, `PCMA` como `alaw`, e `H264` como `h264`.

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
/etc/systemd/system/asterisk.service
```

O serviço é controlado por um unit systemd nativo gerado pelo instalador. O runtime/socket fica
em `/run/asterisk`, evitando dependência do script SysV criado por `make config`.

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

Se o heartbeat retornar `404`, a instalação local ainda pode estar correta. Esse status indica
que a API publicada em `APP_BASE` ainda não tem a rota `/api/v1/pabx/asterisk/heartbeat`
implantada/reiniciada, ou que o backend ativo não está na mesma versão do repositório.

## Diagnóstico

```bash
systemctl status asterisk --no-pager
asterisk -V
asterisk -rx "core show uptime"
asterisk -rx "odbc show"
asterisk -rx "module show like res_odbc"
asterisk -rx "module show like res_config_odbc"
asterisk -rx "module show like res_sorcery_realtime"
asterisk -rx "module show like res_pjsip"
asterisk -rx "module show like g729"
asterisk -rx "module show like h264"
asterisk -rx "core show codecs audio" | grep -i g729
asterisk -rx "core show translation" | grep -i g729
asterisk -rx "core show codecs video" | grep -i h264
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
