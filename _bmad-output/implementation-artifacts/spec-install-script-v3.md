---
title: 'Bootstrap Portainer CE Installation Script (v3 — Optional Let''s Encrypt TLS, fed directly to Portainer)'
type: 'feature'
created: '2026-05-06'
status: 'done'
context: []
baseline_commit: '13b086926e29e445c505e06af5c947f9baf7a88e'
supersedes: 'spec-install-script-v2.md'
---

> **Renegotiated revision (approved 2026-05-06).** This spec extends the v2 contract with optional Let's Encrypt TLS for Portainer's own HTTPS endpoint. Portainer always serves HTTPS itself; v3 lets the operator replace its self-signed cert with a real LE cert, fed directly to Portainer via `--sslcert` / `--sslkey` and a bind-mounted `/etc/letsencrypt`. No host reverse proxy is introduced — that is a deliberate departure from the sibling `bootstrap-supabase` / `bootstrap-n8n` / `bootstrap-infisical` pattern, justified by Portainer being a single-port HTTPS service that natively supports operator-supplied certs.

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Portainer always serves HTTPS on its UI port using a self-signed cert generated at first boot. Browsers and remote clients reject this cert. The v2 contract had no story for replacing it, so operators either accepted the cert manually per-browser or bolted a reverse proxy on top.

**Approach:** Add an optional TLS bootstrap step to `install.sh` that obtains a Let's Encrypt cert via `certbot` on the host, bind-mounts `/etc/letsencrypt` read-only into the Portainer container, and passes `--sslcert` / `--sslkey` flags to Portainer pointing at the live cert paths. Renewal is delegated to Debian's bundled `certbot.timer`; a deploy hook restarts the Portainer container after each renewal so it picks up the new cert.

## Boundaries & Constraints

**Always (carry from v2):**
- Follow bootstrap-supabase patterns (idempotent, re-runnable, pinned versions)
- Use Docker Compose (not docker run) for deployment
- Support Ubuntu 22.04 / 24.04
- Detect OS via `/etc/os-release` (works on minimal cloud images without `lsb_release`)
- When Docker Engine or the Compose v2 plugin is missing, install both from Docker's official Ubuntu apt repository
- When Docker is present but the daemon is not responding, attempt `systemctl start docker` once before failing
- After Docker is usable, when invoked via sudo from a normal login, add `SUDO_USER` to group `docker`
- Use `portainer/portainer-ce:sts` image (pinned version)
- Mount Docker socket and persistent volume
- Save configuration to `.install.conf` for re-runs
- Use shared logging library

**Always (new in v3):**
- Provide a `TLS_MODE` knob with three values: `off` (default — Portainer's self-signed cert), `letsencrypt-http` (Let's Encrypt via HTTP-01 over port 80), `dns-cloudflare` (Let's Encrypt via DNS-01 against Cloudflare's API)
- When `TLS_MODE` is not `off`, prompt for `DOMAIN` and `CERTBOT_EMAIL`; when `dns-cloudflare`, additionally prompt for `CF_API_TOKEN`
- Install `certbot` from the Ubuntu archive when `TLS_MODE` is not `off`; for `dns-cloudflare`, also install `python3-certbot-dns-cloudflare`
- Obtain certs via `certbot certonly --standalone` (HTTP-01) or `certbot certonly --dns-cloudflare` (DNS-01) — never via the `--nginx` plugin, since v3 does not introduce a host nginx
- Bind-mount `/etc/letsencrypt:/certs:ro` into the Portainer container (the entire tree, because `live/` contains relative symlinks into `archive/`)
- Pass `--sslcert /certs/live/${DOMAIN}/fullchain.pem --sslkey /certs/live/${DOMAIN}/privkey.pem` to Portainer when `TLS_MODE` is not `off`
- Write `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh` that runs `docker restart portainer`, idempotently, so renewals propagate
- Leave Debian's bundled `certbot.timer` to drive renewal — do not write a custom cron or systemd unit
- Persist `TLS_MODE`, `DOMAIN`, and `CERTBOT_EMAIL` in `.install.conf`; persist `CF_API_TOKEN` only at `/etc/letsencrypt/.cloudflare-credentials` (chmod 600), not in `.install.conf`

**Ask First:**
- Changes to default ports (9443, 8000)
- Adding TLS modes beyond `off` / `letsencrypt-http` / `dns-cloudflare` (e.g. `tailscale-cert`, `acme-dns`, user-supplied PEM)
- Adding SMTP or authentication settings
- Supporting additional Portainer Agent deployments

**Never (carry from v2 + extend):**
- Use `:latest` tags for images (reject at runtime regardless of source)
- Break idempotency (must be safe to re-run; second run must not re-acquire the cert if a valid one is already on disk)
- Support non-Ubuntu distributions
- Add Portainer Business Edition features
- Manage systemd units on hosts that are not running systemd as init
- **Run a host reverse proxy** (no nginx / Traefik / Caddy): Portainer is a single-port HTTPS service that accepts operator-supplied certs natively, so a reverse proxy would only add a redundant TLS hop with no security or routing benefit
- **Disable Portainer's HTTPS** — Portainer always serves HTTPS; the only choice is which cert it uses
- **Persist `CF_API_TOKEN` in `.install.conf`** — that file is sourced into a root shell on every re-run; the token belongs at `/etc/letsencrypt/.cloudflare-credentials` (chmod 600) instead

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh install, `TLS_MODE=off` | No saved config, defaults | Same as v2: deploy with Portainer's self-signed cert, no certbot | Same as v2 |
| Fresh install, `TLS_MODE=letsencrypt-http` | `DOMAIN` resolves to host's public IP, port 80 free, `CERTBOT_EMAIL` provided | apt-install `certbot`; `certbot certonly --standalone` obtains cert; write deploy hook; bind-mount `/etc/letsencrypt:/certs:ro`; deploy Portainer with `--sslcert` / `--sslkey` flags | Die when port 80 is in use, when `certbot` exits non-zero, when DNS does not resolve to this host (best-effort sanity check) |
| Fresh install, `TLS_MODE=dns-cloudflare` | `DOMAIN` provided, `CF_API_TOKEN` provided | apt-install `certbot python3-certbot-dns-cloudflare`; write `.cloudflare-credentials` (chmod 600); `certbot certonly --dns-cloudflare`; deploy as above | Die when CF token is rejected; never echo the token into logs |
| Re-run, valid cert on disk | Cert at `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` exists and is not near expiry | Skip cert acquisition; continue to compose / deploy phase | Warn and re-acquire if cert expires within 30 days but renewal does not run |
| Re-run, container already running | `portainer` running with the same `TLS_MODE` / `DOMAIN` | No-op (v2 idempotency carries) | n/a |
| TLS reconfiguration | Saved `TLS_MODE` differs from current | The script does **not** automatically recreate the running container; operator must `docker rm portainer` first and re-run | Log a warning when the saved config differs from the running container's state |
| Renewal | `certbot.timer` fires, `certbot renew` succeeds | Deploy hook `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh` runs `docker restart portainer`; new cert active within seconds | Renewal failures surface through journalctl / certbot's own log; the install script does not police them |
| `dns-cloudflare` without token | `TLS_MODE=dns-cloudflare` and `CF_API_TOKEN` empty | Die before installing certbot | Prompt or env-var; no silent fallback |

</frozen-after-approval>

## Code Map

- `install.sh` — main idempotent installer. New v3 sections: TLS prompts (`TLS_MODE`, `DOMAIN`, `CERTBOT_EMAIL`, `CF_API_TOKEN`), `install_certbot_for_tls_mode`, `obtain_letsencrypt_cert` (mode-dispatched), `write_portainer_renewal_hook`, port-80 collision check (only when `letsencrypt-http`).
- `lib/log.sh` — unchanged.
- `docker-compose.yaml` — generated. v3 conditionally adds:
  - `volumes: - /etc/letsencrypt:/certs:ro`
  - `command: --sslcert /certs/live/${DOMAIN}/fullchain.pem --sslkey /certs/live/${DOMAIN}/privkey.pem`
  - Only when `TLS_MODE != off`.
- `.install.conf` — adds `TLS_MODE`, `DOMAIN`, `CERTBOT_EMAIL`. **Does not** persist `CF_API_TOKEN` (lives at `/etc/letsencrypt/.cloudflare-credentials`).
- `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh` (new, generated) — `#!/bin/sh\nexec docker restart portainer`, chmod 0755.
- `/etc/letsencrypt/.cloudflare-credentials` (generated only when `TLS_MODE=dns-cloudflare`) — chmod 0600, owner root.
- `tests/install_script_contract.bats` — extend with v3 contract assertions.
- `tests/install_script_behavior.bats` — extend with v3 branch coverage (TLS_MODE off / letsencrypt-http / dns-cloudflare; cert-already-present skip path; renewal-hook content).

## Tasks & Acceptance

**Execution:**
- [x] `install.sh` — add `TLS_MODE` prompt and dispatch; add `install_certbot_for_tls_mode`, `obtain_letsencrypt_cert`, `write_portainer_renewal_hook`; gate the bind-mount and Portainer flags in the compose template on `TLS_MODE != off`
- [x] Compose generation — emit different YAML for `TLS_MODE=off` vs `TLS_MODE!=off`
- [x] Renewal hook — write `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh` (idempotent: skip when content matches)
- [x] Cloudflare credentials handling — write `/etc/letsencrypt/.cloudflare-credentials` chmod 0600, never echo, never persist in `.install.conf`
- [x] `tests/install_script_contract.bats` — string-grep contracts for the new surface (`TLS_MODE`, `--sslcert`, `--sslkey`, `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh`, no `nginx` package install, no Caddy / Traefik install)
- [x] `tests/install_script_behavior.bats` — branch coverage: TLS off (default v2 behavior), TLS letsencrypt-http (port-80 check + certbot --standalone called), TLS dns-cloudflare (cert-credentials file written + certbot --dns-cloudflare called), cert-already-present skip path, renewal hook script written and chmod'd, drift warning, no-reverse-proxy assertion
- [x] `README.md` — document `TLS_MODE`, `DOMAIN`, `CERTBOT_EMAIL`, `CF_API_TOKEN`, the renewal story, and the "change TLS_MODE → docker rm portainer first" caveat

**Acceptance Criteria (extends v2 ACs #1–#11):**

12. Given `TLS_MODE=off` (or unset, defaulting to `off`), when `install.sh` runs, then no `certbot` apt install happens, no `/etc/letsencrypt` bind-mount appears in the generated compose file, and Portainer is deployed with its self-signed cert as in v2.

13. Given `TLS_MODE=letsencrypt-http`, `DOMAIN` resolves to this host's public IP, `CERTBOT_EMAIL` is set, and port 80 is free, when `install.sh` runs, then `certbot` is installed via apt, `certbot certonly --standalone -d ${DOMAIN}` is invoked, the cert lands at `/etc/letsencrypt/live/${DOMAIN}/{fullchain,privkey}.pem`, the renewal-hook script exists and is executable, and the generated compose file bind-mounts `/etc/letsencrypt:/certs:ro` and passes `--sslcert /certs/live/${DOMAIN}/fullchain.pem --sslkey /certs/live/${DOMAIN}/privkey.pem` to Portainer.

14. Given `TLS_MODE=letsencrypt-http` and port 80 is already listening, when `install.sh` runs, then it dies before invoking `certbot` with a clear remediation hint about freeing port 80.

15. Given `TLS_MODE=dns-cloudflare` and a non-empty `CF_API_TOKEN`, when `install.sh` runs, then `certbot` and `python3-certbot-dns-cloudflare` are installed, `/etc/letsencrypt/.cloudflare-credentials` is written with mode `0600` and owner `root`, `certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/.cloudflare-credentials -d ${DOMAIN}` is invoked, and the cert lands as in AC #13. The token is never echoed to stdout / stderr / `.install.conf`.

16. Given a valid cert is already present at `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` and is not within 30 days of expiry, when `install.sh` re-runs, then it skips the `certbot` invocation and proceeds to the compose / deploy phase.

17. Given `certbot.timer` runs `certbot renew` and the cert is renewed, then the deploy hook at `/etc/letsencrypt/renewal-hooks/deploy/portainer.sh` runs `docker restart portainer` so the new cert is loaded.

18. Given the saved `TLS_MODE` differs from the value in the prompt or env, and the `portainer` container is running, when `install.sh` re-runs, then it logs a warning that the running container does not match the new config and instructs the operator to `docker rm portainer` and re-run.

19. Given the `portainer` container is running, when `curl -k https://${DOMAIN}:${PORTAINER_HTTP_PORT}` is run from outside the host, then for `TLS_MODE!=off` the served cert chain validates against the LE intermediate (no `-k` needed in practice; `-k` is only for the local self-signed test).

20. Given `TLS_MODE` is not `off`, when `install.sh` runs, then it does **not** install nginx, Caddy, Traefik, or any other reverse-proxy package, and does not write any `/etc/nginx/sites-*` or `/etc/caddy/*` files.

## Spec Change Log

1. **v3 baseline (2026-05-06)** — Add optional Let's Encrypt TLS via certbot, fed directly to Portainer (no host reverse proxy):
   - New `TLS_MODE` knob: `off | letsencrypt-http | dns-cloudflare`. Default is `off` for v2 backwards compatibility on existing installs.
   - New prompts: `DOMAIN`, `CERTBOT_EMAIL`, `CF_API_TOKEN` (only when `dns-cloudflare`).
   - Cert acquisition via `certbot certonly --standalone` or `--dns-cloudflare`. The `--nginx` plugin is intentionally **not** used because v3 does not introduce a host reverse proxy.
   - Cert is fed directly to Portainer via `--sslcert` / `--sslkey` flags and a `/etc/letsencrypt:/certs:ro` bind-mount, exploiting Portainer's native operator-cert support.
   - Renewal is left to Debian's `certbot.timer`; a deploy hook restarts the `portainer` container so the new cert is loaded.
   - New `Never` rules: no host reverse proxy, no disabling Portainer's HTTPS, no `CF_API_TOKEN` persistence in `.install.conf`.

## Design Notes

**Compose template (TLS_MODE != off):**
```yaml
services:
  portainer:
    container_name: portainer
    image: ${PORTAINER_IMAGE}
    restart: always
    command: --sslcert /certs/live/${DOMAIN}/fullchain.pem --sslkey /certs/live/${DOMAIN}/privkey.pem
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - /etc/letsencrypt:/certs:ro
    ports:
      - ${PORTAINER_HTTP_PORT}:9443
      - ${PORTAINER_EDGE_PORT}:8000
volumes:
  portainer_data:
    name: portainer_data
networks:
  default:
    name: portainer_network
```

**Compose template (TLS_MODE == off):** unchanged from v2.

**Why the entire `/etc/letsencrypt` is bind-mounted, not just `live/${DOMAIN}/`:** the files in `live/${DOMAIN}/` are relative symlinks pointing into `../../archive/${DOMAIN}/`. Mounting only `live/${DOMAIN}/` would surface broken symlinks to the container.

**Why `--standalone` instead of `--nginx`:** the sibling repos use `--nginx` because they install nginx for reverse proxying. v3 does not install nginx, so `--standalone` is the right plugin for HTTP-01. It binds port 80 transiently during cert acquisition and renewal.

**Why the deploy hook is needed:** Portainer reads `--sslcert` / `--sslkey` once at startup and does not watch the files. After each renewal, the cert on disk changes but the running container still serves the old cert until restarted. The deploy hook in `/etc/letsencrypt/renewal-hooks/deploy/` is invoked by `certbot` after every successful renewal exactly to handle this.

**Default port choice:** `PORTAINER_HTTP_PORT_DEFAULT` stays at `9443`. When `TLS_MODE != off`, the operator typically wants `443`, but defaulting to `443` would conflict with the `--standalone` cert-acquisition step (which itself binds `80`, but operators frequently have `:443` consumed by something else). The prompt logic offers `443` as a *suggestion* in the help text but keeps the default at `9443`.

## Verification

**Commands** (operator on the target host):
- `sudo ./install.sh -y` (first run with `TLS_MODE=off`) — same v2 behavior; Portainer with self-signed cert
- `sudo TLS_MODE=letsencrypt-http DOMAIN=portainer.example.com CERTBOT_EMAIL=ops@example.com ./install.sh -y` — first run with HTTP-01 LE
- `sudo TLS_MODE=dns-cloudflare DOMAIN=portainer.example.com CERTBOT_EMAIL=ops@example.com CF_API_TOKEN=xxxxx ./install.sh -y` — first run with DNS-01 LE
- `curl -I https://${DOMAIN}:${PORTAINER_HTTP_PORT}` — expected: HTTP/1.1 or 2 200/302; cert chain validates without `-k` for `TLS_MODE != off`
- `sudo certbot renew --dry-run` — expected: success; deploy hook fires; container restarts (verify with `docker ps --format '{{.Names}} {{.Status}}'`)
- `make check` (DevRail dev-toolchain container) — expected: composite pass including new Bats coverage
- `sudo cat /etc/letsencrypt/.cloudflare-credentials` — expected: file mode `0600`, owner `root`. **Never** included in `.install.conf`.

## Suggested Review Order

Read [`install.sh`](../../install.sh) top-to-bottom in these sections (line numbers drift; headings are authoritative):

**Entry point and core logic** — Banner comment, `set -euo pipefail`, constants, `# Load Shared Library`, `# Argument Parsing` (USAGE heredoc).

**OS detection & Docker bootstrap** — unchanged from v2.

**TLS bootstrap (new in v3)** — `install_certbot_for_tls_mode`, `obtain_letsencrypt_cert`, `write_portainer_renewal_hook`, port-80 guard.

**Pre-flight Checks** — root, OS, Docker daemon, sudo-user group add, registry probe; conditional port-80 check.

**Validation and configuration** — `valid_port`, `tcp_port_listening`, `ensure_publish_ports_free_for_compose_deploy`, `prompt`, `prompt_port`, `:latest` rejection, `prompt_tls_mode`, `prompt_domain`, etc.

**Deployment** — Idempotency check, mode-dispatched compose template, `docker compose up -d`, readiness polling.

**Shared library** — [`lib/log.sh`](../../lib/log.sh) unchanged.

**Tests** — extended `tests/install_script_contract.bats` and `tests/install_script_behavior.bats` for v3 coverage.
