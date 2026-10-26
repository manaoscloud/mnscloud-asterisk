# MNSCloud Asterisk Connector Skill

Use this contract when changing the `asterisk/` module or publishing `manaoscloud/mnscloud-asterisk`.

## Public Repository Boundary

This module is a public edge connector. It may run on MNSCloud, customer, or partner servers and
consume the MNSCloud API contract. It must be fully standalone and must not depend on the private
monorepo at runtime.

## Security Rules

- Do not commit secrets, tokens, private keys, provider credentials, customer data, production IPs, or
  tenant-specific values.
- Do not copy API-side authorization, billing, tenant scoping, routing ownership, or private business
  rules into this module.
- Do not add hidden API bypasses, static master tokens, default production credentials, or privileged
  shortcuts.
- Use placeholders in examples: `<api_base>`, `<node_uuid>`, `<token>`, `<tenant_domain>`.
- Node UUIDs generated, persisted, displayed, or sent by installers must be normalized to lowercase.
- Local secrets must be generated on the target host and stored with restrictive permissions.
- Permanent provider credentials stay in the API/control plane.
- UI-generated PABX install commands may expose the server runtime token only once. The API must
  store only its hash, and regenerating the command must replace the previous token.

## Contract

- Product repository: `manaoscloud/mnscloud-asterisk`
- Local installer: `scripts/install-asterisk.sh`
- Update latest: `scripts/update-latest-asterisk.sh`
- Explicit update: `scripts/update-asterisk.sh --ref <release-tag>`
- Validator: `scripts/validate-asterisk.sh`
- Rollback: `scripts/rollback-asterisk.sh --ref <known-good-release-tag>`
- Runtime API consumer: MNSCloud PABX Asterisk endpoints under `/api/v1/pabx/asterisk/*`
- Local state prefix: `/etc/mnscloud/pabx`
- Install flags: `--api-base`, `--node-uuid`, `--runtime-token`/`--install-token`, and optional
  `--db-host`, `--db-port`, `--db-name`, `--db-user`, `--db-pass`.
  Secrets on the command line (`--runtime-token`, `--install-token`, `--db-pass`) end up in shell
  history and process listings: they are a bootstrap/legacy path only. The normal path is the
  API/Agent-delivered principal and token files; never put these flags in generated or documented
  commands with real values.

## Checklist

- Validate `scripts/*.sh` with `bash -n`.
- Search the module for sensitive values before publishing.
- Keep all required installer helpers inside this repository.
- Keep the module consuming API contracts only.

## Contribution Governance

- External contributions must be submitted through Pull Requests.
- Follow `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, and this `SKILL.md` before proposing changes.
- Do not add secrets, customer data, private infrastructure details, production domains/IPs, or hidden bypass logic.
- MNSCloud may choose to pay, sponsor, contract, or hire contributors when work demonstrates strong value, but paid work requires explicit written agreement and is never implied by opening a Pull Request.
- Keep security-sensitive decisions, tenant scope, billing, authorization, routing ownership, and secret resolution in the MNSCloud API/control plane.

## PhoneWeb contact-center agents

The installer enables `mnscloud-asterisk-phone-agent.service`. It consumes local AMI AgentConnect/AgentComplete events and reconciles only `agent-<UUID>` queue members from the authenticated control-plane `/pabx/runtime/agents` endpoint. Only AVAILABLE routes calls; PAUSED, ON_CALL and WRAP_UP do not. LOGGED_OUT removes memberships. The API owns session, tenant, queue and commercial authorization.

The bridge reads existing host-local node credentials without logging them, rejects HTTP redirects, and persists pending events with mode 0600 under its systemd StateDirectory. Duplicate events are idempotent in the control plane. A control-plane outage pauses managed members until recovery; retired memberships discard refused replay events. Legacy extension members remain outside the bridge.

Install/update/validate/rollback use the normal Agent module lifecycle. Validation requires the bridge service; rollback to a release predating it disables its service and removes the generated executable/unit. Tests: `python3 tests/phone-agent-runtime.py`. No direct host changes are required.

The event reader runs independently from HTTP synchronization: a local contact event immediately pauses the member and fences stale AVAILABLE responses until the durable event is acknowledged. Service shutdown retires only its managed memberships; the spool survives for replay. Runtime validation requires both an active service and a successful control-plane synchronization within 60 seconds.
