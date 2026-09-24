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
- Update latest: `scripts/update-latest-asterisk.sh`
- Explicit update: `scripts/update-asterisk.sh --ref <release-tag>`
- Validate: `scripts/validate-asterisk.sh`
- Rollback: `scripts/rollback-asterisk.sh --ref <known-good-release-tag>`
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
When `scripts/update-asterisk.sh` is present, the Agent also reports
`mnscloud.asterisk.update`, includes this runtime in heartbeat inventory, and can execute approved
`mnscloud-asterisk` release rollouts from the MNSCloud control plane.

### Install log and build diagnostics

Every installer run appends its full session to `/var/log/mnscloud-install.log` (mode `0640`):
a `START` line with the module version, argument names (never values), host context (OS, kernel,
CPUs, RAM, swap, disk), every command with its complete stdout/stderr, and an `END OK` or
`END FAILED` line with elapsed time. Nothing is filtered or sent to `/dev/null`.

- Asterisk is compiled with `NOISY_BUILD=yes`, so the bundled pjproject/jansson compiler output
  that Asterisk normally hides is written to the log.
- Before downloading sources, a build preflight checks free disk (`ASTERISK_BUILD_MIN_DISK_MB`,
  default `3072`) and memory. Parallel jobs are derived from RAM+swap
  (`ASTERISK_BUILD_MB_PER_JOB`, default `1024`, capped at the CPU count) and can be forced with
  `ASTERISK_BUILD_JOBS`.
- A failed parallel build is retried once with `-j1` so the real compiler error is not
  interleaved with other jobs.
- On any failure the log records the failing command plus diagnostics: Asterisk and pjproject
  `config.log` tails from this run, `free`, `df`, kernel OOM/kill events since the install
  started, and failed systemd units.
- The install ends by running `scripts/validate-asterisk.sh`.

To review a failed install: `grep -nE 'ERROR|END ' /var/log/mnscloud-install.log | tail`.

Right after boot, `unattended-upgrades`/apt-daily often hold the dpkg or apt lists lock. The
installer waits for those locks before any apt/dpkg command (up to 600s, override with
`MNSCLOUD_APT_LOCK_TIMEOUT`) and logs progress every 30s, instead of failing with exit 100.
Packages installed through `mnscloud-runtime-kit` use the same wait.

Runtime secrets (API token, AMI secret, database password) are registered with the installer log
and masked as `***` in every `RUN:`/failure line.

The generated ODBC DSN pins `CHARSET=utf8mb4` and
`INITSTMT=SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci`: MariaDB 11.2+ otherwise gives utf8mb4
clients `utf8mb4_uca1400_ai_ci`, and realtime `LIKE` lookups against the `utf8mb4_unicode_ci`
views fail with "Illegal mix of collations". The installer fails if the DSN collation differs.
ARI is explicitly disabled (`ari.conf`) and the unused `res_pjsip_config_wizard` and
`res_stun_monitor` modules are not loaded.

For a PABX trunk removed by the control plane, the assigned Agent sends
`pjsip send unregister <registration>` before `pjsip reload` removes the realtime
registration object. This prevents a provider from retaining an outbound SIP
registration until its normal expiry interval. The Agent reports teardown failure
when the local registration is already missing, rather than falsely confirming
carrier-side removal.

See `asterisk.md` and `SECURITY.md` for details.
