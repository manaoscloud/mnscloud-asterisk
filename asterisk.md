# Asterisk PABX

## Objetivo

O instalador `scripts/install-asterisk.sh` provisiona um PABX Asterisk multi-tenant usando
PJSIP Realtime com MariaDB/ODBC. Ele segue o mesmo padrão operacional dos instaladores
FreeSWITCH, Kamailio e OpenSIPS:

- cria/carrega o node UUID em `/etc/mnscloud/pabx/node.uuid`;
- em instalação interativa, imprime o node UUID no início e aguarda o cadastro no
  `VoipPabxServer` com `VpsEngine = 'asterisk'`;
- valida o cadastro via heartbeat API antes de continuar, quando o operador confirma;
- tenta vincular o node UUID ao `VoipPabxServer` cadastrado com `VpsEngine = 'asterisk'`
  quando houver credenciais DB disponíveis como compatibilidade operacional;
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

## NAT e IP Público

O instalador segue o mesmo conceito do FreeSWITCH para evitar depender de IP público no `.env`:

1. gera/carrega o node UUID logo no início;
2. pausa em instalação interativa para o operador cadastrar esse UUID no servidor Asterisk;
3. valida o cadastro via `POST /api/v1/pabx/asterisk/heartbeat`;
4. se a API retornar `VoipPabxServer.VpsPublicIP`, esse IP é usado;
5. se a validação não ocorrer, o heartbeat usa descoberta HTTPS de IPv4 público;
6. se a descoberta falhar, a configuração NAT do Asterisk permanece sem endereço externo explícito.

O prompt de confirmação usa `/dev/tty`, então continua funcionando quando o instalador é chamado
por um wrapper que usa a entrada padrão internamente. Apenas sessões realmente sem terminal de
controle pulam essa espera.

Quando há IP público validado ou detectado, a API materializa o NAT no Realtime PJSIP em
`AsteriskTransport`:

- `external_media_address = <ip_publico>`;
- `external_signaling_address = <ip_publico>`;
- `external_signaling_port = 5060`;
- `local_net = <ip_privado>/<prefixo>` quando o instalador consegue detectar a interface local;
- `symmetric_transport = yes`.

Os endpoints gerados para ramais/trunks já devem manter os campos compatíveis com NAT:
`force_rport = yes`, `rewrite_contact = yes`, `rtp_symmetric = yes` e `direct_media = no`.

## Multi-Tenant, Domínios e Realtime

O Asterisk deve ser tratado como runtime realtime multi-tenant. O instalador entrega apenas a
base PJSIP/ODBC/Sorcery; a separação de tenants deve ser materializada nas tabelas `Asterisk*`
pela camada de provisionamento a partir das entidades canônicas (`VoipPabxAccount`,
`VoipPabxExtension`, `VoipPabxTrunk` e rotas).

Regras obrigatórias:

- Não usar dialplan global compartilhado do tipo `_X. => Dial(PJSIP/${EXTEN})`.
- Não depender do contexto `default` para chamadas entre ramais. O `default` gerado pelo
  instalador é contexto de rejeição/fallback.
- Todos os ramais autenticados usam o contexto estático `authenticated`. A separação
  multi-tenant não depende de criar contextos por PABX; ela é resolvida no banco usando o
  endpoint chamador (`ramal@dominio`) e o ramal discado.
- O identificador técnico do endpoint deve ser globalmente único quando houver possibilidade de
  dois tenants usarem o mesmo número de ramal. O ramal visível ao cliente continua em
  `VoipPabxExtension.VpeUsername`, mas o `AsteriskEndpoint.id`, `AsteriskAuth.id` e
  `AsteriskAor.id` devem evitar colisão entre tenants/domínios.
- Para ramais SIP de tenant com domínio, o identificador técnico padrão é
  `LOWER(CONCAT(VpeUsername, '@', VoipDomain.VdmName))`, por exemplo
  `5009@pabx-dev3.publichost.cloud`. O `AsteriskAuth.username` permanece apenas o ramal
  (`5009`) para que o cliente continue autenticando com usuário curto dentro do domínio SIP.
- O `AsteriskAuth.realm` dos ramais deve ser o domínio SIP (`VoipDomain.VdmName`), evitando que
  clientes recebam desafio digest com o realm global `asterisk` e deixem de completar o REGISTER.
- O `extensions.conf` gerado pelo instalador deve conter `default` como fallback de rejeição e
  `authenticated` como contexto fixo de chamadas internas. Chamadas para `_X.` resolvem o destino
  via `ODBC_AST_RESOLVE_INTERNAL(${CHANNEL(name)},${EXTEN})`; a consulta identifica o endpoint
  chamador pelo prefixo `PJSIP/<endpoint>-` do canal e só retorna destino quando chamador e chamado
  pertencem ao mesmo `VoipPabxAccount`/tenant.
- Hints/BLF devem ser tenant-aware. Quando forem provisionados no realtime, devem usar o endpoint
  técnico completo como extensão (`1100@pabx-dev1.publichost.cloud`) apontando para
  `PJSIP/1100@pabx-dev1.publichost.cloud`, nunca apenas o ramal curto (`1100`) em contexto comum.
- Para BLF em telefones/softphones, o valor monitorado deve ser o endpoint técnico completo
  (`ramal@dominio`). A chamada interna continua discando o ramal curto (`1100`), mas a assinatura
  BLF precisa ser única no contexto compartilhado `authenticated`.
- Endpoints Asterisk provisionados pelo app devem manter `allow_subscribe = yes`,
  `subscribe_context = authenticated` e `device_state_busy_at = 1`, permitindo que
  `res_pjsip_exten_state` publique estado ocupado/tocando a partir do hint realtime.
- Eventos `presence`/`presence.winfo` enviados espontaneamente por alguns softphones não são o BLF
  principal deste modelo. BLF de ramal usa hints + `dialog-info`/extension-state; presença rica pode
  ser tratada depois como recurso separado.

O modelo de laboratório com `id = 5009` e `context = default` é aceito apenas para validação
local de registro SIP. Em produção, o provisionamento Asterisk deve usar endpoint técnico
`ramal@dominio` e contexto `authenticated`.

## Trunks Asterisk

Trunks criados no app com `engine = asterisk` são materializados automaticamente nas tabelas
realtime do Asterisk quando o recurso é criado, alterado ou removido:

- `AsteriskEndpoint`: endpoint técnico `trunk-<VptID>`.
- `AsteriskAor`: contato estático `sip:<host>:<port>`.
- `AsteriskAuth`: criado quando `authMode` exige digest e há usuário/senha.
- `AsteriskEndpointIdentify`: criado para trunks inbound/both usando `allowedCidrs` ou `host`.
- `AsteriskRegistration`: criado quando `authMode = register`, `registerEnabled = true` e há
  usuário/senha.

O contrato de trunk é engine-aware, mas a engine não é escolhida no trunk. A entidade canônica é
`VoipPabxTrunk`, e a engine é derivada do `VoipPabxServer` vinculado ao PABX. Cada engine materializa
apenas seus artefatos runtime. Para Asterisk, o renderer da API grava as tabelas `Asterisk*`; para
FreeSWITCH, os mesmos campos canônicos são renderizados como gateways no `sofia.conf` via XML Curl.

O Asterisk suporta três formas principais nesta modelagem:

- `ip_acl`: identifica chamadas recebidas por IP/CIDR em `AsteriskEndpointIdentify`.
- `digest`: cria auth no endpoint para autenticação SIP digest.
- `register`: cria auth e registro outbound periódico em `AsteriskRegistration`.

O contexto de entrada dos trunks Asterisk é `trunk-inbound`. Esse contexto deve resolver rotas de
entrada por trunk/DID para ramal, fila, grupo, URA ou destino externo sem depender de contexto por
PABX.

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
/etc/asterisk/func_odbc.conf
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
as tabelas `Asterisk*` deve respeitar o contrato multi-tenant acima e acontecer pelas procedures
do banco, não por scripts operacionais manuais.
