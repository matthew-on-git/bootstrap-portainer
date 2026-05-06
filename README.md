# bootstrap-portainer

> Idempotent installer that deploys [Portainer CE](https://www.portainer.io/) via Docker Compose on Ubuntu 22.04 / 24.04 hosts — bootstrapping Docker Engine and the Compose v2 plugin from Docker's upstream apt repository when missing. Built with [DevRail](https://devrail.dev) `v1` standards. See [STABILITY.md](STABILITY.md) for component status.

<!-- badges-start -->
<!-- TODO: Add CI status badge: ![Lint](https://github.com/OWNER/REPO/actions/workflows/lint.yml/badge.svg) -->
[![DevRail compliant](https://devrail.dev/images/badge.svg)](https://devrail.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
<!-- badges-end -->

## Quick Start

1. Click **"Use this template"** on [github.com/devrail-dev/github-repo-template](https://github.com/devrail-dev/github-repo-template) to create a new repository.
2. Edit `.devrail.yml` and uncomment the languages used in your project.
3. Run `make install-hooks` to set up pre-commit hooks.

## Usage

The Makefile is the universal execution interface. Every target produces consistent behavior whether invoked by a developer, CI pipeline, or AI agent.

| Target | Purpose |
|---|---|
| `make help` | Show available targets (default) |
| `make lint` | Run all linters for declared languages |
| `make format` | Run all formatters for declared languages |
| `make fix` | Auto-fix formatting issues in-place |
| `make test` | Run project test suite |
| `make security` | Run language-specific security scanners |
| `make scan` | Run universal scanning (trivy, gitleaks) |
| `make docs` | Generate documentation |
| `make check` | Run all of the above; report composite summary |
| `make install-hooks` | Install pre-commit and pre-push hooks |

All targets except `help` and `install-hooks` delegate to the dev-toolchain Docker container (`ghcr.io/devrail-dev/dev-toolchain:v1`).

## Bootstrapping Portainer CE

The authoritative spec is [`spec-install-script-v2.md`](_bmad-output/implementation-artifacts/spec-install-script-v2.md).

### Requirements

- **OS:** Ubuntu **22.04** or **24.04** (detected via `/etc/os-release`)
- **Init:** systemd — the script refuses to manage `docker.service` if `/run/systemd/system` is absent (containers without systemd, WSL with the default shim, etc.)
- **Architecture:** `amd64`, `arm64`, `armhf`, `s390x`, or `ppc64el` (the apt channels Docker publishes for)
- **Privilege:** the script must run as root — typically via `sudo`
- **Network:** outbound HTTPS to `download.docker.com` (apt repo) and `registry-1.docker.io` (image pull). The reachability probe is warn-only; real failures surface during `docker compose up -d`.

### Quick install

```bash
sudo ./install.sh           # interactive — accept defaults or override at the prompts
sudo ./install.sh -y        # unattended — accept defaults / saved config without prompting
./install.sh --help         # synopsis
```

If Docker Engine or the Compose v2 plugin is missing, the script configures Docker's official apt repository and installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`, then `systemctl enable --now docker`.

### Configuration

The first run writes `${INSTALL_DIR}/.install.conf` with the values you accepted; re-runs source it for defaults. A corrupt `.install.conf` is logged as a warning and ignored — the script falls back to in-script defaults rather than dying.

| Setting | Default | Notes |
|---|---|---|
| `INSTALL_DIR` | `/opt/portainer` | Holds `.install.conf` and the generated `docker-compose.yaml` |
| `PORTAINER_HTTP_PORT` | `9443` | Host port for Portainer's HTTPS UI; mapped to container `9443` |
| `PORTAINER_EDGE_PORT` | `8000` | Host port for Portainer's Edge tunnel; mapped to container `8000` |
| `PORTAINER_IMAGE` | `portainer/portainer-ce:sts` | Pinned tag — `:latest` and unpinned tags are rejected at runtime regardless of source (defaults, saved config, interactive input) |

### Docker group access

When you invoke the script via `sudo` from a normal login (i.e. `SUDO_USER` is set, is not `root`, and matches a safe POSIX-portable username pattern), that user is added to the **`docker`** group so they can run `docker` without `sudo`. **Log out and back in (or run `newgrp docker`)** for the new group to take effect.

If you ran the script directly as `root` (no `SUDO_USER`), or via a non-sudo elevation tool (`doas`, `pkexec`, `su -i`), the group step is skipped with a warning; grant access manually with `sudo usermod -aG docker <user>`.

### Idempotency

Re-runs are safe and cheap:

- If the `portainer` container is **running** — report "already running" and exit `0` without touching the compose file or container state.
- If the `portainer` container exists but is **stopped** — run `docker start portainer` and exit `0`.
- Otherwise — verify the configured host ports are not already listening, generate `docker-compose.yaml`, and run `docker compose up -d`.

Reconciling a changed `.install.conf` against an **existing stopped** container is intentionally out of scope — recreate the container (`docker rm portainer`) before re-running if you have changed ports.

### Verification

```bash
docker ps                                       # portainer container running on the configured host ports
curl -k https://localhost:${PORTAINER_HTTP_PORT}  # Portainer login page response
sudo ./install.sh -y && sudo ./install.sh -y    # second run reports "already running"
```

The first plain `docker ps` (no `sudo`) only succeeds after you have logged out / back in or run `newgrp docker` so the `docker` group membership takes effect.

### Troubleshooting

- **`HTTPS port and Edge port must differ`** — `PORTAINER_HTTP_PORT` and `PORTAINER_EDGE_PORT` resolve to the same value. Edit `.install.conf` (or delete it and re-run) to set distinct ports.
- **`TCP port N is already in use`** — another service is bound to one of the configured host ports. Stop it, or pick a different port at the prompt.
- **`Docker daemon is still unreachable after start`** — the script ran `systemctl start docker` once and `docker info` still fails. Investigate with `journalctl -u docker.service`.
- **`systemd is required (/run/systemd/system not found)`** — the host is not running systemd as init. The script does not support these environments; run Portainer manually via `docker compose` instead.
- **`Unsupported architecture for Docker upstream apt`** — the host architecture is outside Docker's published apt channels. Install Docker manually via your distribution's packages, then re-run `install.sh`.
- **`PORTAINER_IMAGE must not use the :latest tag`** — pin a stable tag like `portainer/portainer-ce:sts`. The contract rejects `:latest` so re-runs are reproducible.

## Configuration

### `.devrail.yml`

Every DevRail-managed repository includes a `.devrail.yml` file at the repo root. This file declares the project's languages and settings, and is read by the Makefile, CI pipelines, and AI agents.

```yaml
languages:
  - python
  - bash

fail_fast: false
log_format: json
```

Uncomment the languages used in your project and configure settings as needed.

### Branch Protection

To enforce CI checks before merging pull requests:

1. Go to **Settings > Branches > Branch protection rules**
2. Add a rule for the `main` branch
3. Enable **"Require status checks to pass before merging"**
4. Select all five status checks: `lint`, `format`, `security`, `test`, `docs`

### GitHub Template Repository

This repo is configured as a GitHub template. To enable this on your fork:

1. Go to **Settings > General**
2. Check **"Template repository"** under the repository name section
3. Users will then see a **"Use this template"** button on the repo page

## Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for development standards, coding conventions, and contribution guidelines.

To add a new language ecosystem to DevRail, see the [Contributing to DevRail](https://github.com/devrail-dev/devrail-standards/blob/main/standards/contributing.md) guide.

This project follows [Conventional Commits](https://www.conventionalcommits.org/). All commits use the `type(scope): description` format.

## Retrofit Existing Project

To add DevRail standards to an existing GitHub repository:

### Step 1: Core Configuration

- [ ] Copy `.devrail.yml` and uncomment your project's languages
- [ ] Copy `.editorconfig`
- [ ] Merge `.gitignore` patterns into your existing .gitignore
- [ ] Copy `Makefile` (or merge targets if you have an existing Makefile)

### Step 2: Pre-Commit Hooks

- [ ] Copy `.pre-commit-config.yaml` and uncomment hooks for your languages
- [ ] Run `make install-hooks`

### Step 3: Agent Instruction Files

- [ ] Copy `DEVELOPMENT.md`, `CLAUDE.md`, `AGENTS.md`, `.cursorrules`
- [ ] Copy `.opencode/agents.yaml`

### Step 4: CI Workflows

- [ ] Copy `.github/workflows/` directory (lint.yml, format.yml, security.yml, test.yml, docs.yml)
- [ ] Configure branch protection: Settings > Branches > Require status checks

### Step 5: Project Documentation

- [ ] Copy `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] Copy `.github/CODEOWNERS` and configure for your team
- [ ] Copy `CHANGELOG.md` if not already present

### Step 6: Verify

- [ ] Run `make check` and fix any issues
- [ ] Create a test commit to verify pre-commit hooks fire
- [ ] Create a test PR to verify CI workflows run

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
