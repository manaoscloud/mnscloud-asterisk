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

## Install

Install GitHub CLI if needed, then authenticate before cloning this private
repository: [cli/cli installation](https://github.com/cli/cli#installation).

```bash
gh auth login
gh auth status

sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-asterisk
cd /opt/mnscloud/mnscloud-asterisk
sudo bash scripts/install-asterisk.sh
```

See `asterisk.md` and `SECURITY.md` for details.
