# deploy

Ansible for one Hetzner box: provision, ship, look, and prove it comes back.

| | |
|---|---|
| `site.yml` | provision and deploy. Tags: `provision`, `deploy`, `reload` |
| `status.yml` | read-only — services, health, disk, snapshot, node memory |
| `reboot.yml` | the recovery drill |
| `templates/` | the systemd unit, the Caddyfile, unattended-upgrades |
| `inventory.example.ini` | copy to `inventory.ini` (gitignored) and fill in |

**[docs/OPERATIONS.md](../docs/OPERATIONS.md) is the walkthrough** — first run,
deploying, environment variables, observer, and what failure looks like.

The one thing to know before touching any of it: the release bundles ERTS and
is linked against its build host's glibc, so it **must be built on Ubuntu
24.04**. The playbook asserts the target matches.
