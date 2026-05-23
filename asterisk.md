# Asterisk PABX

## Objetivo

O instalador `scripts/install-asterisk.sh` provisiona um PABX Asterisk multi-tenant usando
PJSIP Realtime com MariaDB/ODBC. Ele segue o mesmo padrão operacional dos instaladores
FreeSWITCH:

- cria/carrega o node UUID em `/etc/mnscloud/pabx/node.uuid`;
- em instalação interativa, imprime o node UUID e aguarda cadastro manual no `VoipPabxServer`
  correto com `VpsEngine = 'asterisk'`;
- valida o cadastro via heartbeat API antes de continuar, quando o operador confirma;
- não executa SQL direto para vincular o node UUID;
- preserva arquivos originais com `.bkp`;
- gera configuração limpa controlada pelo mnscloud;
- valida serviço e módulos básicos após a instalação.

## Versão

O Asterisk não mantém um repositório oficial de pacotes Linux alinhado ao modelo operacional que
precisamos para esta engine PABX. Por isso o instalador usa o source oficial:

```text
https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
```

O valor pode ser sobrescrito via `ASTERISK_VERSION` ou `ASTERISK_SOURCE_URL`.

## Codecs

O padrão de mídia do mnscloud é:

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
2. pausa em instalação interativa para o operador cadastrar esse UUID no servidor Asterisk correto;
3. exige que o operador digite `validate`; ENTER vazio não confirma o cadastro;
4. valida o cadastro via `POST /api/v1/pabx/asterisk/heartbeat`;
5. se a API retornar `VoipPabxServer.VpsPublicIPv4`, esse IP é usado;
6. se `AST_PUBLIC_IP`/`ASTERISK_PUBLIC_IP` estiver definido com um IPv4 público válido, esse IP é usado;
7. se a validação não ocorrer e o operador digitar `skip`, o heartbeat usa descoberta HTTPS de IPv4 público;
8. a descoberta HTTPS pode ser desativada com `AST_AUTO_DISCOVER_PUBLIC_IP=0` ou
   `ASTERISK_AUTO_DISCOVER_PUBLIC_IP=0`;
9. o IPv4 local é detectado pela interface global, mas pode ser sobrescrito com
   `AST_LOCAL_IP`/`ASTERISK_LOCAL_IP`;
10. se o host tiver IPv6 global, o heartbeat também envia `publicIPv6`, `privateIPv6`
   e `localNetIPv6`;
11. se a descoberta falhar, a configuração NAT do Asterisk permanece sem endereço externo explícito.

O cadastro usa a API de heartbeat para validação. O instalador gera um token por servidor em
`/etc/mnscloud/pabx/api.token`, envia esse token no heartbeat e a API armazena apenas o hash em
`VoipPabxServer.VpsApiTokenHash`. O instalador não executa SQL direto para vincular `VpsNodeUUID`.

O prompt de confirmação usa `/dev/tty`, então continua funcionando quando o instalador é chamado
por um wrapper que usa a entrada padrão internamente. Apenas sessões realmente sem terminal de
controle pulam essa espera.

Quando o host é validado, a API materializa os defaults de transporte no Realtime PJSIP em
`AsteriskTransport`:

- `external_media_address = <ip_publico>` quando o heartbeat informa ou confirma o IPv4 público;
- `external_signaling_address = <ip_publico>` quando o heartbeat informa ou confirma o IPv4 público;
- `external_signaling_port = 5060`;
- `local_net = <ip_privado>/<prefixo>` quando o instalador consegue detectar a interface local;
- `allow_reload = no`;
- `symmetric_transport = yes`.

Se o host tiver IPv6 global, a API também cria os transportes `transport-udp6` e `transport-tcp6`
com `bind = [::]:5060`, endereço externo IPv6 e `local_net` IPv6. Assim clientes IPv6-only podem
registrar diretamente por IPv6, enquanto clientes dual-stack continuam livres para escolher o
caminho que funcionar melhor via DNS/rede.

Em ambientes com NAT, o transporte deve anunciar o IPv4 público para evitar respostas SIP com
`Contact` privado/quebrado, enquanto `local_net` mantém a rede interna fora da reescrita externa.
Depois de alterar esses campos, reinicie o Asterisk e recrie as contas nos softphones para limpar
estado de registro antigo.

Os endpoints gerados para ramais/trunks já devem manter os campos compatíveis com NAT:
`force_rport = yes`, `rewrite_contact = yes`, `rtp_symmetric = yes`, `direct_media = no`,
`identify_by = auth_username,username` e `from_domain = <dominio>`. Ramais não devem fixar
`transport`, para que o PJSIP use o transporte real do contato registrado (`transport-udp` ou
`transport-udp6`).

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
- Todo `Dial()` gerado pelo instalador deve passar pelo subcontexto `mnscloud-dial-result` antes do
  desligamento final. Esse subcontexto traduz `DIALSTATUS` para causas determinísticas:
  `CHANUNAVAIL` vira `Hangup(20)`, `NOANSWER` vira `Hangup(19)`, `BUSY` vira `Hangup(17)` e
  `CONGESTION` vira `Hangup(34)`. Assim, um ramal sem contato PJSIP registrado não fica em ringback
  vazio quando não há voicemail, encaminhamento ou outro fallback configurado.
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

O `trunk-inbound` não deve materializar uma extensão estática para cada rota. As rotas inbound do
modelo canônico usam regex em `VoipPabxInboundRoute.VriPattern`, então o Asterisk resolve a chamada
em tempo real via `ODBC_AST_RESOLVE_INBOUND(${CHANNEL(name)},${EXTEN})`. A função identifica o trunk
pelo endpoint PJSIP do canal, filtra a rota pelo PABX/tenant/trunk opcional e retorna o destino de
`Dial()`. Destinos `extension` retornam `PJSIP/<endpoint-do-ramal>`, `external` retorna
`PJSIP/<numero>@<endpoint-do-trunk>` quando o destino é número livre ou destino externo cadastrado,
e `group`, `queue` e `ivr` retornam canais `Local/...` para os contextos `mnscloud-group`,
`mnscloud-queue` e `mnscloud-ivr`. Se um destino externo livre já vier como canal Asterisk
explícito, por exemplo `PJSIP/...`, ele é usado como informado. Isso evita reload pesado e mantém
alterações de rota inbound dinâmicas.

O contexto `mnscloud-group` resolve membros pelo banco e disca os endpoints PJSIP materializados no
realtime. O contexto `mnscloud-queue` usa o `app_queue` nativo com filas realtime
`AsteriskQueue`/`AsteriskQueueMember`; quando um ramal membro tem `VoipPabxQueueAgent`, o status
`LOGGED_OUT`, `AVAILABLE` ou `PAUSED` controla se o membro entra na fila e se entra pausado. Ramais
sem agente continuam como membros fixos para compatibilidade. O `mnscloud-ivr` resolve o áudio
inicial e as opções por ODBC, mantendo opções de URA também dinâmicas. Para opções de URA com
destino externo, o canal de entrada original é preservado em `MNSCLOUD_INBOUND_CHANNEL`, permitindo
que a opção disque o número externo pelo mesmo endpoint de trunk recebido.

The Asterisk IVR implementation must follow Asterisk dialplan sequencing, not the FreeSWITCH XML
dialplan model. The installer uses the official `Read()` application as the IVR primitive because it
can play an optional prompt and store collected digits in a channel variable before the next
priority resolves the option through ODBC. Do not split prompt playback into `Background()` followed
by unrelated option logic unless there is a specific feature reason; the standard path is:

```text
Answer()
Set(IVR_AUDIO=<ODBC_AST_IVR_AUDIO>)
Set(IVR_TIMEOUT=<ODBC_AST_IVR_TIMEOUT or 10>)
Read(IVR_DIGIT,<optional prompt>,1,,1,<timeout>)
Set(TARGET_DIAL=<ODBC_AST_IVR_OPTION_TARGET>)
Dial(<TARGET_DIAL>,30)
Gosub(mnscloud-dial-result,s,1(${DIALSTATUS}))
```

This keeps Asterisk behavior deterministic: digit capture is completed before the selected target is
resolved, and every IVR option that reaches `Dial()` is normalized through `mnscloud-dial-result`.
FreeSWITCH needs a different generated XML shape because its XML conditions are evaluated before
actions execute; do not copy the FreeSWITCH `execute_extension` workaround into Asterisk.

IVR prompt delivery must respect the same media contract used by the platform:

1. media file delivery mode;
2. PABX media delivery mode;
3. tenant `SystemParameter`;
4. master `SystemParameter`;
5. default `offline`.

When the effective mode is `offline`, `ODBC_AST_IVR_AUDIO` returns the synchronized local
`VoipPabxMediaFileSync.VmsDialPath` for the current PABX server. When the effective mode is
`online`, it returns a stable MNSCloud API media URL:

```text
<api-base>/api/v1/pabx/media/<node-uuid>/<media-uuid>/content/<filename>?token=<url-encoded-pabx-token>
```

The API validates the node UUID and PABX API token, checks tenant ownership from the registered PABX
server, then streams either the API-local file or the configured storage object. This avoids putting
cloud-storage signed URLs directly into the Asterisk dialplan and keeps URLs free of extra query
parameters that could confuse prompt playback. The installer loads `res_curl.so` and
`res_http_media_cache.so` so Asterisk can use HTTP media with the official media cache path behind
`Read()`. The filename suffix must preserve a real audio extension because PBX media caches and
format detection rely on a playable file name. Keep generated Asterisk configuration files readable
only by root/asterisk because they contain the node playback token needed by the engine.

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

O `logger.conf` gerado pelo instalador preserva o arquivo original com `.bkp` e recria uma
configuração limpa com `console`, `messages` e `full` ativos. O arquivo
`/var/log/asterisk/full` recebe `notice`, `warning`, `error`, `debug` e `verbose`, para facilitar
diagnóstico de PJSIP/realtime sem depender somente do journal.

O serviço é controlado por um unit systemd nativo gerado pelo instalador. O runtime/socket fica
em `/run/asterisk`, evitando dependência do script SysV criado por `make config`.

## AMI Control

O instalador cria `/etc/asterisk/manager.conf` para o worker `pabx-control`. A senha forte de
32 caracteres fica em `/etc/mnscloud/pabx/asterisk-ami.secret` e é enviada no heartbeat para a API
gravar nos campos de controle do `VoipPabxServer`.

O instalador configura AMI na porta `5038`, cria o usuário `mnscloud`, descobre automaticamente os
IPs autorizados para o worker/API e gera senha forte local em
`/etc/mnscloud/pabx/asterisk-ami.secret`. Esses dados são enviados no heartbeat e persistidos no
cadastro `VoipPabxServer`, sem depender de overrides no `.env`.

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
que a API publicada em `/etc/mnscloud/pabx/api.base` ainda não tem a rota
`/api/v1/pabx/asterisk/heartbeat` implantada/reiniciada, ou que o backend ativo não está na mesma
versão do repositório.

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
