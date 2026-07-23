# MNSCloud Asterisk

Public standalone Asterisk edge connector for MNSCloud.

This repository installs and configures local Asterisk runtime assets that consume the MNSCloud API
contract. It can run on MNSCloud, customer, or partner infrastructure.

## Boundary

- This repository is public and auditable by design.
- It must remain standalone and must not depend on the private MNSCloud monorepo at runtime.
- The MNSCloud API is the source of truth for authorization, tenant scope, routing ownership, billing,
  policy, and secret resolution.
- Do not commit secrets, customer data, production infrastructure values, provider credentials, or
  private business rules.

## Contract

- Product/runtime: `mnscloud-asterisk`
- Project directory: `/opt/mnscloud/mnscloud-asterisk`
- Installer: `scripts/install-asterisk.sh`
- Shared package installer: `mnscloud-runtime-kit`
- Service: `asterisk.service`
- Runtime user: `asterisk`
- Local state prefix: `/etc/mnscloud/pabx`
- Node UUID: `/etc/mnscloud/pabx/node.uuid`
- API token: `/etc/mnscloud/pabx/api.token`
- API base URL: `/etc/mnscloud/pabx/api.base`
- Database config: `/etc/mnscloud/pabx/db.conf`
- AMI secret: `/etc/mnscloud/pabx/asterisk-ami.secret`
- Asterisk config directory: `/etc/asterisk`
- Asterisk state directory: `/var/lib/asterisk`
- Asterisk log directory: `/var/log/asterisk`
- Recording spool: `/var/spool/asterisk/monitor/mnscloud`

### Ordered dial plan fallbacks

PABX dial plan rules store their primary trunk and ordered fallback trunks in the MNSCloud control
plane. During an outbound attempt, Asterisk dials each resolved trunk in that order and stops on
the first answered call. No trunk routing or fallback list is configured locally on the server.

## Install

Install GitHub CLI if needed:
[cli/cli installation](https://github.com/cli/cli#installation).

Authenticate GitHub CLI:

```bash
gh auth login
```

Clone the private repository and install:

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-asterisk
cd /opt/mnscloud/mnscloud-asterisk
sudo bash scripts/install-asterisk.sh
```

The recommended production flow is to create the Asterisk PABX server in MNSCloud and use
**Generate Install Command**. The platform returns a visible-once runtime token, stores only its hash,
and generates a command that clones/updates this repository and runs:

```bash
sudo bash scripts/install-asterisk.sh \
  --api-base <api_base> \
  --node-uuid <node_uuid> \
  --runtime-token <visible_once_runtime_token>
```

Asterisk realtime database credentials remain local server configuration. Provide them
interactively, through `/etc/mnscloud/pabx/db.conf`, or through the optional `--db-host`, `--db-port`,
`--db-name`, `--db-user`, and `--db-pass` installer flags.

Before installing Asterisk PABX, enroll `mnscloud-agent` on the host. The installer validates the
shared Agent prerequisite contract with
`/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh --require-active --require-enrolled`.
After Asterisk is installed, the Agent derives and reports `voip.asterisk.manage`.

See `asterisk.md` and `SECURITY.md` for details.
