---
title: 'Bootstrap Portainer CE Installation Script (v2 — Docker bootstrap on bare Ubuntu)'
type: 'feature'
created: '2026-05-06'
status: 'done'
context: []
baseline_commit: '636987e700cfa99801e0dfb93929dea4f5ba6187'
supersedes: 'spec-install-script.md'
---

> **Renegotiated revision.** This spec formally renegotiates the [v1 frozen contract](./spec-install-script.md) to allow `install.sh` to install Docker Engine + Compose v2 on bare Ubuntu cloud images, detect the OS without `lsb_release`, and grant the invoking sudo user access to the `docker` group. v1 is preserved for traceability and is marked `superseded`.

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Operators provisioning Portainer CE on freshly-imaged Ubuntu 22.04 / 24.04 cloud templates frequently start without Docker Engine present, and minimal images often lack `lsb_release`. The v1 contract assumed Docker was pre-installed, which created a manual prerequisite step before `install.sh` could run.

**Approach:** Extend `install.sh` to bootstrap Docker Engine and the Compose v2 plugin from Docker's official Ubuntu apt repository (`download.docker.com`) when missing, detect the OS via `/etc/os-release`, and — when invoked through sudo from a normal login — add `SUDO_USER` to the `docker` group so the operator can use the Docker CLI without sudo afterwards.

## Boundaries & Constraints

**Always:**
- Follow bootstrap-supabase patterns (idempotent, re-runnable, pinned versions)
- Use Docker Compose (not docker run) for deployment
- Support Ubuntu 22.04 / 24.04
- Detect OS via `/etc/os-release` (works on minimal cloud images without `lsb_release`)
- When Docker Engine or the Compose v2 plugin is missing, install both from Docker's official Ubuntu apt repository (`download.docker.com`)
- When Docker is present but the daemon is not responding, attempt `systemctl start docker` once before declaring failure
- After Docker is usable, when the script was invoked via sudo from a normal login (`SUDO_USER` is set and is not `root`), add `SUDO_USER` to group `docker` so the user can run `docker` without sudo (a new login or `newgrp docker` is required for the group to take effect)
- Use `portainer/portainer-ce:sts` image (pinned version)
- Expose ports 9443 (HTTPS UI) and 8000 (Edge tunnel)
- Mount Docker socket and persistent volume
- Save configuration to `.install.conf` for re-runs
- Use shared logging library (`log_info`, `log_warn`, `log_error`, `die` from `lib/log.sh`)

**Ask First:**
- Changes to default ports (9443, 8000)
- Adding TLS/HTTPS configuration
- Adding SMTP or authentication settings
- Supporting additional Portainer Agent deployments

**Never:**
- Use `:latest` tags for images (reject `:latest` at runtime regardless of source — defaults, saved config, or interactive input)
- Break idempotency (must be safe to re-run; re-running on a fully-installed host must not churn apt state or re-download keys)
- Support non-Ubuntu distributions
- Add Portainer Business Edition features
- Manage systemd units on hosts that are not running systemd as init (containers without systemd, WSL with default shim) — refuse explicitly

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh install (Docker present) | First run, Docker + Compose v2 + daemon all up | Creates `.install.conf`, generates compose file, deploys Portainer via `docker compose up -d`, container running | Die with remediation hint if compose deploy fails |
| Fresh install (bare Ubuntu) | First run, Docker Engine and/or Compose v2 plugin missing | Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` from Docker's upstream apt; enables `docker.service`; adds `SUDO_USER` to `docker` group; then deploys Portainer | Die with apt / systemd / network remediation hints (journalctl, network, apt update) |
| Daemon down | Docker installed, `docker info` fails | `systemctl start docker` (once); re-check; proceed if recovered | Die with `journalctl -u docker.service` hint if still unreachable |
| Re-run existing | Config exists, container running | No-op (already running), reports status | Warn if `.install.conf` is corrupted; fall back to defaults |
| Unattended mode | `-y` flag passed | Uses all defaults / saved values without prompts | Die on missing required values |
| Custom port | User specifies non-default port | Uses specified port; validates 1–65535; verifies port is not already listening on host (via `ss -ltnH`) before fresh deploy | Die when HTTP and Edge ports collide; die when port is already in use |
| Non-systemd host | `/run/systemd/system` absent (LXC without systemd, WSL default shim, etc.) | Refuse to manage `docker.service`; halt with explanatory message | Die before any apt or systemctl side effects |
| Unsupported architecture | `dpkg --print-architecture` is not in `{amd64, arm64, armhf, s390x, ppc64el}` | Halt before adding apt sources | Die with the supported architecture list |

</frozen-after-approval>

## Code Map

- `install.sh` — main idempotent installer. Sections: OS detection (`ensure_ubuntu_supported`, `read_os_release_field`), Docker bootstrap (`ensure_systemd_init`, `docker_supported_arch`, `install_docker_engine_ubuntu`), runtime checks (`ensure_docker_daemon_and_compose`, `assert_docker_compose_v2`), group membership (`add_sudo_invoker_to_docker_group`), registry probe, port collision (`tcp_port_listening`, `ensure_publish_ports_free_for_compose_deploy`), config load/prompt/save, idempotency check, compose generation, deploy, readiness loop.
- `lib/log.sh` — shared logging library (`log_info`, `log_warn`, `log_error`, `die`, `banner`).
- `docker-compose.yaml` — generated by `install.sh`.
- `.install.conf` — created on first run, sourced on re-runs (with corrupt-file fallback to defaults).
- `tests/install_script_contract.bats` — string-grep contract suite over `install.sh` and `lib/log.sh`. Picked up by `make test`.

## Tasks & Acceptance

**Execution:**
- [x] `install.sh` — extend with Docker apt bootstrap, `/etc/os-release` detection, daemon recovery via `systemctl start docker`, and `SUDO_USER → docker` group step
- [x] `lib/log.sh` — unchanged from v1 (still authoritative shared logging)
- [x] `docker-compose.yaml` (generated) — unchanged from v1; `${PORTAINER_HTTP_PORT}:9443` and `${PORTAINER_EDGE_PORT}:8000` mapping
- [x] `tests/install_script_contract.bats` — string-grep contracts for the v2 surface (image pin, registry probe, sudo-user group helper, Compose v2 plugin install, systemd init guard, `:latest` runtime rejection, SUDO_USER pattern reject, port-check ordering, full `lib/log.sh` surface)

**Acceptance Criteria:**
1. Given a bare Ubuntu 22.04 / 24.04 cloud template with outbound network to `download.docker.com` and a working OCI registry path, when `sudo bash install.sh` is run, then `install.sh` installs Docker CE + Compose v2 from Docker's upstream apt repo, generates `${INSTALL_DIR}/docker-compose.yaml` pinned to `${PORTAINER_IMAGE}` (default `portainer/portainer-ce:sts`), runs `docker compose up -d`, and Portainer becomes reachable on host port `${PORTAINER_HTTP_PORT}` (default 9443) mapped to container `9443`.
2. Given `install.sh` is invoked via sudo from a normal login (`SUDO_USER` is set and is not `root`) and `SUDO_USER` matches the safe-username pattern, when the script runs to completion, then `SUDO_USER` is in group `docker` (or the script logs that they were already a member), and the script logs the "log out / `newgrp docker`" reminder.
3. Given Docker binaries are present but `docker info` fails, when `install.sh` runs, then it calls `systemctl start docker` once, re-checks, and either proceeds (if the daemon recovers) or dies with a `journalctl -u docker.service` hint.
4. Given the `portainer` container is already running, when `install.sh` re-runs, then it exits 0 reporting "already running" with no compose rewrite and no group/usermod side-effect that contradicts the operator's prior state.
5. Given the `portainer` container exists but is stopped, when `install.sh` re-runs, then `docker start portainer` is invoked and the script exits 0. Reconciling changed `.install.conf` ports against an existing stopped container is **out of scope for v2** (deferred behavioral nuance).
6. Given `install.sh -y` is passed, when the script runs, then all interactive prompts use saved values or defaults without `read`.
7. Given the fresh-deploy path (no running and no stopped `portainer` container), when the script reaches the deploy step, then `${PORTAINER_HTTP_PORT}` ≠ `${PORTAINER_EDGE_PORT}` and neither is listening on the host (per `ss -ltnH` local-address parse). Missing `ss` → warn and skip the collision check.
8. Given a corrupted `.install.conf`, when the script sources it and `source` fails, then the script `log_warn`s the failure and falls back to in-script defaults rather than dying.
9. Given the host is not running systemd as init (`/run/systemd/system` absent), when the script reaches Docker bootstrap or daemon recovery, then it halts with an explanatory message before invoking `systemctl`.
10. Given a saved `.install.conf` overrides `PORTAINER_IMAGE` (or the operator types a new value at the prompt) to use the `:latest` tag or no explicit tag at all, then the script dies before writing the compose file.
11. Given `make check` is run inside the DevRail dev-toolchain container, then all gates (lint, format, test including the Bats contract suite, security, scan, docs) pass.

## Spec Change Log

1. **v2 baseline (2026-05-06)** — Renegotiate the v1 frozen contract to bootstrap Docker on bare Ubuntu templates:
   - Removed "Never install Docker"; the script now installs Docker CE + Compose v2 from Docker's upstream apt when missing.
   - OS detection uses `/etc/os-release` (`ID`, `VERSION_ID`, `VERSION_CODENAME`) instead of `lsb_release`, so minimal cloud images work.
   - If Docker is installed but the daemon is down, the script attempts `systemctl start docker` once before failing.
   - When run with sudo from a normal login, the invoking user (`SUDO_USER`) is added to the `docker` group; the script never alters group membership for `root` or for users that fail the safe-username pattern.
   - New `Never` rule: refuse to manage `docker.service` when systemd is not the init.
   - New `Never` rule: reject `:latest` at runtime regardless of source (defaults, saved config, or interactive input).
   - New `I/O Matrix` rows for the daemon-down recovery path, the non-systemd host case, and the unsupported-architecture case.

## Design Notes

**Compose File Template** (unchanged from v1):
```yaml
services:
  portainer:
    container_name: portainer
    image: ${PORTAINER_IMAGE}
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
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

**Key v2 implementation choices:**
- `read_os_release_field` parses `/etc/os-release` via `awk` instead of `source`-ing it — avoids leaking variables into the global shell and avoids executing arbitrary content from a hostile or malformed os-release.
- GPG key install uses `curl --proto '=https' --tlsv1.2` to a temp file, then `install -m 0644 -o root -g root` for an atomic, non-TOCTOU placement.
- `apt` sources file is rewritten only when its content does not already match the desired line (idempotent re-runs).
- Registry reachability probe targets `https://registry-1.docker.io/v2/` (the actual pull endpoint) accepting HTTP 200 / 401 / 403 — `hub.docker.com` website probes were unreliable theatre.
- `tcp_port_listening` parses only the local-address column of `ss -ltnH` via `awk`, so an IP octet that happens to equal the port number does not produce a false positive.
- `assert_docker_compose_v2` captures `docker compose version --short` and requires major ≥ 2.

## Verification

**Commands** (run by an operator on the target host):
- `sudo ./install.sh -y` (first run) — expected: Docker installed if missing, compose file generated, container running
- `sudo ./install.sh -y && sudo ./install.sh -y` — expected: second run reports "already running" and exits 0 (idempotent)
- `docker ps` — expected: `portainer` container running with ports `${PORTAINER_HTTP_PORT}` and `${PORTAINER_EDGE_PORT}` exposed. **Precondition for non-sudo `docker ps` after first install**: log out / log back in (or `newgrp docker`) so the new `docker` group membership for `SUDO_USER` takes effect.
- `curl -k https://localhost:${PORTAINER_HTTP_PORT}` — expected: Portainer login page response
- `make check` (DevRail dev-toolchain container) — expected: composite pass including the Bats contract suite

## Suggested Review Order

Read [`install.sh`](../../install.sh) top-to-bottom in these sections (line numbers drift; headings are authoritative):

**Entry point and core logic** — Banner comment, `set -euo pipefail`, constants, `# Load Shared Library` (bootstrap `SCRIPT_DIR` + `source lib/log.sh` via printf/exit-safe path), `# Argument Parsing` (USAGE heredoc including the `Side effects` block).

**OS detection & Docker bootstrap** — `read_os_release_field`, `ensure_ubuntu_supported`, `ensure_systemd_init`, `docker_supported_arch`, `install_docker_engine_ubuntu` (idempotent key + sources writes), `assert_docker_compose_v2`, `ensure_docker_daemon_and_compose`, `add_sudo_invoker_to_docker_group` (with safe-username regex).

**Pre-flight Checks** — root-only, OS support, Docker daemon recovery, sudo-user group add, registry probe (`registry-1.docker.io/v2/` warn-only).

**Validation and configuration** — `valid_port`, `tcp_port_listening` (awk local-column parse), `ensure_publish_ports_free_for_compose_deploy`, `prompt`, `prompt_port`, `:latest` rejection guard, save `.install.conf`.

**Deployment** — Idempotency check (running / stopped / fresh), `COMPOSE_FILE` HEREDOC, `docker compose up -d`, readiness polling.

**Shared library** — [`lib/log.sh`](../../lib/log.sh) (`log_info`, `log_warn`, `log_error`, `die`, `banner`).

**Tests** — [`tests/install_script_contract.bats`](../../tests/install_script_contract.bats) string-grep contracts; behavioral DinD integration suite tracked separately.
