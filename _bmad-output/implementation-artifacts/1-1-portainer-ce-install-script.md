# Story 1.1: Portainer CE bootstrap installer

Status: in-progress (review items resolved; pending `make check` verification of new tests)

_Source document_: [`spec-install-script.md`](./spec-install-script.md) (authoritative product intent). There is **no** `planning-artifacts` PRD/epics/architecture folder in-repo yet; everything below is distilled from that spec plus the actual tree.

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As an **Ubuntu server operator**,  
I want **`install.sh` to bootstrap Docker (when missing) and deploy Portainer CE via Docker Compose** idempotently,  
So that **I can stand up container management from a bare 22.04/24.04 template with predictable behavior and sane defaults.**

## Acceptance Criteria

_Map directly to [_bmad-output/implementation-artifacts/spec-install-script.md § Tasks & Acceptance_](./spec-install-script.md); verify **code parity**, not just intent._

1. **Fresh host + sudo** — On Ubuntu **22.04** or **24.04**, with outbound network to Canonical/Docker APT and Docker Registry, **`sudo bash install.sh`** (or `./install.sh` as root via sudo) installs missing **Docker CE + Compose v2 plugin** from **`download.docker.com`**, persists **`.install.conf`** under chosen install dir, generates **`docker-compose.yaml`**, runs **`docker compose up -d`**, and exposes Portainer HTTPS on **`PORTAINER_HTTP_PORT`** mapped to container **9443**.  
   - Compose must pin **`${PORTAINER_IMAGE}`** default **`portainer/portainer-ce:sts`** (never **`:latest`**).  
   - Named volume **`portainer_data`**, network **`portainer_network`**, **`restart: always`**, **`/var/run/docker.sock`** mounted. [Source: spec § Design Notes, Code Map]

2. **Docker group for sudo caller** — When **`SUDO_USER`** is set and not **`root`**, that user ends up in group **`docker`** (or script logs they are already member); **`log_warn`** mentions **logout / `newgrp docker`**. [Source: spec § Always bullets + change log §2]

3. **Daemon edge cases** — If Docker binaries exist but **`docker info`** fails, script **`systemctl start docker`** once and re-check before declaring failure; after install path, **`systemctl enable --now docker`**. [Source: spec § I/O Docker unavailable]

4. **Idempotent re-run — running** — If container **`portainer`** is running, script exits **`0`** with **“already running”** semantics (no teardown, no needless compose rewrite).  

5. **Idempotent re-run — stopped** — If container **`portainer`** exists but stopped, **`docker start portainer`** and exit **`0`** (no regeneration path on that branch). **[Gap risk]** Changing **`.install.conf` ports while a stopped legacy container exists may not remap ports—that is **pre-existing behavioral nuance**; do not refactor unless explicitly scoped; record in Dev Agent Record if observed.

6. **Unattended** — **`install.sh -y`** accepts defaults / saved values without **`read`** prompts except where impossible. [Source: spec § I/O Unattended]

7. **Host ports before first deploy** — Before **first compose deploy path only**, **`HTTP`≠`EDGE` ports** and neither may be **listening** on host per **`ss -ltnH`** heuristic; missing **`ss`** → warn and skip collision check **per current code**.

8. **Corrupt `.install.conf`** — **`source` failure** warns and continues from in-script defaults (`log_warn`). [Source: spec change log Loop 1]

9. **`make check`** — Repository gate passes after any change (**DevRail toolchain container only**).

10. **Project standards** — No raw **`echo`** for user-facing progress in **`install.sh`** (use **`lib/log.sh`**); **`set -euo pipefail`**; bootstrap errors before **`log.sh`** load stay **`printf … >&2; exit 1`** (already pattern). **Conventional commits** if committing. Do **not** install host-only linters ([Source: AGENTS.md / README DevRail hooks]).

## Tasks / Subtasks

- [x] **AC parity audit** (#1–#8) Walk `install.sh` and `lib/log.sh` line-by-line against `spec-install-script.md` *Boundaries*, *I/O matrix*, *Design Notes*.
  - [x] Confirm Docker install path (`install_docker_engine_ubuntu`, `ensure_docker_daemon_and_compose`, `add_sudo_invoker_to_docker_group`).
  - [x] Confirm compose template matches spec (service name, volumes, ports mapping **host:${PORTAINER_HTTP_PORT}:9443**, **host:${PORTAINER_EDGE_PORT}:8000**).
  - [x] Confirm **hub.docker.com** check is **warn-only** post-review.
  - [x] Confirm **`ensure_publish_ports_free_for_compose_deploy`** only on **fresh deploy** branch (after early exits).

- [x] **Doc hygiene** (#1, spec UX)
  - [x] Align **Suggested Review Order** anchor line numbers in `spec-install-script.md` with **current** `install.sh` or switch links to stable section headings.
  - [x] Ensure **README.md** § *Portainer on Ubuntu* remains accurate versus script help text (`--help`) and sudo/Docker/group behavior.

- [x] **`make check` / CI** (#9)
  - [x] Run **`make check`** locally (Docker daemon required). Fix any regressions uncovered.

- [x] **Dev Agent Record**
  - [x] Capture file list touched, model used, and any parity gaps or deliberate deferrals (**spec frozen** subsection: do **not** expand scope without human renegotiation per `<frozen-after-approval>`).

### Review Findings

_From `bmad-code-review` 2026-05-05 — three layers (Blind / Edge-Case / Acceptance Auditor) over `git diff main` + new `tests/install_script_contract.bats`._

**Decision needed**

- [x] [Review][Patch] **Revert frozen-block edits and redo as a versioned spec revision (`spec-install-script-v2.md`)** — done 2026-05-06: v1 frozen block restored to its original Always / Never / I/O Matrix; v1 frontmatter marked `status: superseded` with `superseded_by: spec-install-script-v2.md` and a deprecation banner above the freeze; new `spec-install-script-v2.md` carries the renegotiated frozen contract (Docker bootstrap, `/etc/os-release` detection, sudo-user docker group, non-systemd refuse, `:latest` runtime reject), 11 numbered ACs, an updated I/O Matrix with daemon-down / non-systemd / unsupported-arch rows, and `baseline_commit: 636987e`. [`spec-install-script.md`, `spec-install-script-v2.md`]
- [x] [Review][Patch] **Add a behavioral test suite for `install.sh`** — done 2026-05-06 as a mock-based suite (option 1 of three considered): full Docker-in-Docker via the existing `make test` was infeasible because `DOCKER_RUN` mounts no docker socket and runs the toolchain unprivileged. Instead, [`tests/install_script_behavior.bats`](../../tests/install_script_behavior.bats) (~22 tests) runs the script end-to-end inside a per-test sandbox: stub `apt-get`, `systemctl`, `docker`, `usermod`, `ss`, `curl`, `dpkg`, `id`, `sleep` are placed on `PATH`; hardcoded paths (`/etc/os-release`, `/etc/apt/keyrings`, `/etc/apt/sources.list.d/docker.list`, `/run/systemd/system`, `/opt/portainer`) are sed-redirected to a writable sandbox; assertions are made against process exit, stdout, generated compose file, and a per-test calls log. Covers AC #2 / #3 / #4 / #5 / #6 / #7 / #8 / #9 / #10 by branch behavior; AC #1 (real reachability) and AC #11 (`make check` itself) are explicitly out of scope. Auto-discovered by `make test` via the existing `find . -name '*.bats'` pattern (no Makefile change needed). **Not yet executed** — needs `make check` inside the dev-toolchain to confirm green on this host. [`tests/install_script_behavior.bats`]

**Patch (unambiguous fixes)**

- [x] [Review][Patch] `tcp_port_listening` regex matches non-local-address columns and substring ports (e.g. 80 vs 8080) [`install.sh:tcp_port_listening`] — fixed via awk parse of local-address column 2026-05-06
- [x] [Review][Patch] `tests/install_script_contract.bats` lacks final newline (.editorconfig) [`tests/install_script_contract.bats:49`] — fixed 2026-05-06
- [x] [Review][Patch] Bats `awk` order test relies on exact leading whitespace; trivial reformat breaks it [`tests/install_script_contract.bats:34-44`] — fixed via indent-tolerant patterns 2026-05-06
- [x] [Review][Patch] `source /etc/os-release` pollutes globals, executes any code in os-release, and is unsafe under `set -u` if `ID`/`VERSION_CODENAME` missing — parse safely instead [`install.sh:ensure_ubuntu_supported`, `install.sh:install_docker_engine_ubuntu`] — fixed via `read_os_release_field` (awk parse, no source) 2026-05-06
- [x] [Review][Patch] GPG-key download is non-atomic and lacks TLS pin (TOCTOU between `curl -o` and `chmod a+r`) [`install.sh:install_docker_engine_ubuntu`] — fixed: `curl --proto '=https' --tlsv1.2` to tmp file, atomic `install -m 0644 -o root -g root` 2026-05-06
- [x] [Review][Patch] Reachability probe targets `hub.docker.com` (the website) instead of the actual registry endpoint `registry-1.docker.io/v2/` — probe is theatre [`install.sh:Pre-flight Checks`] — fixed: probe `https://registry-1.docker.io/v2/` accepting 200/401/403 2026-05-06
- [x] [Review][Patch] `SUDO_USER` is not validated against a shell-safe username pattern before being passed to `usermod` [`install.sh:add_sudo_invoker_to_docker_group`] — fixed: regex `^[a-z_][a-z0-9_-]*\$?$` 2026-05-06
- [x] [Review][Patch] `docker compose version &>/dev/null` does not assert v2.x — capture and compare major version [`install.sh:ensure_docker_daemon_and_compose`] — fixed via `assert_docker_compose_v2` 2026-05-06
- [x] [Review][Patch] `install_docker_engine_ubuntu` re-downloads the GPG key and re-writes `docker.list` on every entry — guard with existence/fingerprint checks [`install.sh:install_docker_engine_ubuntu`] — fixed: skip-if-present for key, content-equality guard for sources.list 2026-05-06
- [x] [Review][Patch] `docker.list` write does not pre-clear an existing/conflicting suite line [`install.sh:install_docker_engine_ubuntu`] — fixed: `rm -f` before write, gated by content-equality 2026-05-06
- [x] [Review][Patch] `systemctl enable --now docker` runs without confirming systemd is the init (containers/WSL pretend to be Ubuntu) [`install.sh:install_docker_engine_ubuntu`] — fixed via `ensure_systemd_init` 2026-05-06
- [x] [Review][Patch] `dpkg --print-architecture` is used unguarded — Docker only ships `amd64|arm64|armhf|s390x|ppc64el` [`install.sh:install_docker_engine_ubuntu`] — fixed via `docker_supported_arch` case 2026-05-06
- [x] [Review][Patch] Saved `.install.conf` may set `PORTAINER_IMAGE=…:latest` at runtime, defeating the no-`:latest` contract — guard after load [`install.sh:Load Saved Config`] — fixed: explicit-tag and not-`:latest` checks after prompts 2026-05-06
- [x] [Review][Patch] Spec Change Log entries are out of order ("2." precedes "1.") [`spec-install-script.md:Spec Change Log`] — subsumed by D1 (frozen-block revert moves the "2. Product change" entry into v2 spec)
- [x] [Review][Patch] Bats `lib/log.sh provides die and banner` test misses `log_info`/`log_warn`/`log_error` and is brittle string-match [`tests/install_script_contract.bats:46-49`] — fixed: assertions for the full log_* surface 2026-05-06
- [x] [Review][Patch] README "Portainer on Ubuntu" claims account is "added to the `docker` group" unconditionally; script may skip when `SUDO_USER` is unset / root / non-local [`README.md:Portainer on Ubuntu`] — fixed: split into the sudo-from-login case and the explicit caveat for root / non-sudo elevations 2026-05-06
- [x] [Review][Patch] `install.sh --help` USAGE heredoc omits the docker-group / `newgrp docker` side-effect [`install.sh:USAGE`] — fixed: added "Side effects" block 2026-05-06
- [x] [Review][Patch] Spec § Verification omits `newgrp docker` precondition for `docker ps` after first install [`spec-install-script.md:Verification`] — subsumed by D1 (newgrp note belongs in v2 spec where the docker-group behavior is documented)

**Deferred (pre-existing or out of scope)**

- [x] [Review][Defer] Stopped-container path does not reconcile changed `.install.conf` ports against the existing container [`install.sh:Idempotency Check`] — deferred, story AC #5 explicitly tags this as pre-existing nuance not to refactor in scope
- [x] [Review][Defer] Saved-config and `INSTALL_DIR` input validation gaps (relative paths, symlinks, `$`/`"` in image, world-writable conf privesc) [`install.sh:Load Saved Config`, `install.sh:Save Configuration`] — deferred, pre-existing config-loader behavior
- [x] [Review][Defer] Compose-file generation does not escape YAML-special characters in interpolated values [`install.sh:Generate Docker Compose File`] — deferred, pre-existing; inputs are validated upstream and root-only
- [x] [Review][Defer] `docker start portainer` failure on the stopped path exits silently under `set -e` [`install.sh:Idempotency Check`] — deferred, pre-existing path
- [x] [Review][Defer] Readiness loop matches container name not state — could report success during a crash-loop [`install.sh:Deploy`] — deferred, pre-existing readiness check
- [x] [Review][Defer] No `gpg --dearmor` fallback if upstream switches key serving format [`install.sh:install_docker_engine_ubuntu`] — deferred, upstream snippet is canonical; hypothetical
- [x] [Review][Defer] `systemctl start docker` does not unmask a masked unit [`install.sh:ensure_docker_daemon_and_compose`] — deferred, uncommon corner case
- [x] [Review][Defer] No verification of partial apt install state (containerd OK, docker-ce fail) [`install.sh:install_docker_engine_ubuntu`] — deferred, apt's exit code covers the common cases
- [x] [Review][Defer] No `trap ERR` cleanup of stale `/etc/apt/sources.list.d/docker.list` on failed install [`install.sh:install_docker_engine_ubuntu`] — deferred, hardening; not correctness
- [x] [Review][Defer] `doas` / `pkexec` / `su -i` elevation paths produce no `SUDO_USER` and skip group add [`install.sh:add_sudo_invoker_to_docker_group`] — deferred, contract is documented as `sudo`
- [x] [Review][Defer] No `apt` lock-contention wait/retry [`install.sh:install_docker_engine_ubuntu`] — deferred, one-shot installer; user can re-run
- [x] [Review][Defer] No graceful behavior if Docker upstream has not yet published packages for a new Ubuntu release [`install.sh:install_docker_engine_ubuntu`] — deferred, spec scopes to 22.04 / 24.04

## Dev Notes

### Canonical source & frozen intent

> **2026-05-06 update.** The authoritative spec is now **[`spec-install-script-v2.md`](./spec-install-script-v2.md)** — a formal renegotiation of the v1 freeze that allows the script to install Docker on bare Ubuntu templates, detect OS via `/etc/os-release`, and add `SUDO_USER` to the `docker` group. v1 (`spec-install-script.md`) is preserved at `status: superseded` for traceability. Treat v2 as the contract for any future change.

Original (v1) note, retained for context:

Primary product contract: **`_bmad-output/implementation-artifacts/spec-install-script.md`** (YAML frontmatter + frozen HTML block through *I/O & Edge-Case Matrix*).

Treat **frozen** prose as immutable **unless human explicitly renegotiates** in writing; backlog items that contradict it belong in a **new** spec revision, not stealth edits inside the freeze.

Implementation map:

| Artifact | Role |
|----------|------|
| `install.sh` | Entry point, systemd/apt/Docker bootstrap, prompts, compose write, deploy, idempotency |
| `lib/log.sh` | `log_*`, **`die`**, **`banner`** — sourced after safe `SCRIPT_DIR` resolution |

Generated at runtime (**not necessarily committed**): **`${INSTALL_DIR}/docker-compose.yaml`**, **`.install.conf`**.

### Project structure notes

Repo is **DevRail** bash-flavored (**`.devrail.yml` declares bash**).

- Prefer **small surgical diffs**; match existing indentation and **`banner`/section banners** layout in `install.sh`.
- Scripts must stay **idempotent** and **`bash`**-oriented (**`/usr/bin/env bash`**).

### Architecture / stack compliance (brownfield extraction)

_No formal architecture doc._ Inferred MUST-haves:

- **Ubuntu-only** (**`/etc/os-release`**, **`VERSION_ID`∈22.04|24.04**).
- **Docker Compose CLI** (**`docker compose` plugin**, not obsolete `docker-compose` standalone python).
- **Networking**: APT + **`download.docker.com`** + registry for **first pull**; optional hub HTTPS probe is non-fatal warning.

### Library & tooling requirements

- **Shell diagnostics**: Prefer **`shellcheck`** clean (**Makefile / dev-toolchain** runs it indirectly via `make check`).
- Docker packages (when scripted): **`docker-ce`**, **`docker-ce-cli`**, **`containerd.io`**, **`docker-buildx-plugin`**, **`docker-compose-plugin`**.

### File structure MUST NOT violate

Keep scripts at repo root / `lib/`:

```
install.sh
lib/log.sh
```

Do **not** splinter logging into ad-hoc `echo` callers.

### Testing requirements

- Mandatory: **`make check`** (gates lint/format/test/security/scan/docs per DevRail Makefile).
- There is **no** dedicated **`install.sh`** Bats/integration suite in-repo today — if adding one, integrate via Makefile `_test`/`make check` delegation (coordinate with toolchain image capabilities first).

### Project context reference

_No `**/project-context.md` found._

DevRail norms: **`AGENTS.md`**, **`DEVELOPMENT.md`**, **`README.md`**.

### References

| Topic | Pointer |
|------|---------|
| Spec — authoritative (v2) | [`_bmad-output/implementation-artifacts/spec-install-script-v2.md`](./spec-install-script-v2.md) |
| Spec — superseded (v1, archival) | [`_bmad-output/implementation-artifacts/spec-install-script.md`](./spec-install-script.md) |
| Installer implementation | [`install.sh`](../../install.sh) |
| Logging | [`lib/log.sh`](../../lib/log.sh) |
| Tests (contract suite) | [`tests/install_script_contract.bats`](../../tests/install_script_contract.bats) |
| Repo standards | [`AGENTS.md`](../../AGENTS.md), [`DEVELOPMENT.md`](../../DEVELOPMENT.md) |

---

## Git intelligence (recent work pattern)

Commits touching installer:

```text
636987e fix(install): harden bootstrap, host port checks, soften registry probe
afc4850 feat: add bootstrap-portainer installation script
```

Expect **continuation** of **`fix(install): …` / `feat(install): …`** conventional prefixes for follow-ups.

---

## Latest technical anchors (minimal)

| Area | Guidance |
|------|----------|
| Docker Engine on Ubuntu | Official repo pattern: keyed **`/etc/apt/sources.list.d/docker.list`**, **`docker.asc`**, install **`docker-compose-plugin`** for Compose V2 **`docker compose`**. |

---

### Story completion status

**Ultimate context engine analysis completed** — authoritative spec ingested + **observed codebase** summarized for dev agent execution.

_Reminder_: `sprint-status.yaml` absent — backlog → ready-for-dev **not synced** centrally; create via sprint-planning if team tracking desired.

---

## Change Log

- **2026-05-05** — Parity/documentation pass: **`tests/install_script_contract.bats`** (Bats glue for install script contracts), **`spec-install-script.md`** review-order + verified review findings anchored by section (`README.md` **`--help`** note, verification **`sudo`** for idempotent example). **`make check`** green.

---

## Dev Agent Record

### Agent Model Used

Composer / Cursor Agent (conversation session implementing `bmad-dev-story`).

### Debug Log References

- `make check` (Docker `ghcr.io/devrail-dev/dev-toolchain:v1`) — composite pass incl. new Bats suite.

### Completion Notes List

- **AC parity:** Walked **`install.sh` / `lib/log.sh`** vs **spec Boundaries / I/O / Design Notes**. Docker upstream apt bootstrap, systemd start/enable, **`SUDO_USER` → docker group**, compose template (named volume, **`portainer_network`**, **`restart: always`**, socket mount, **`:sts`** default image, host-port publish mapping), **`ss`** collision guard on fresh path only after running/stopped early exits, corrupt config **`log_warn`**, hub probe **`log_warn`** — all aligned.
- **Deferred (no refactor per AC #5 text):** Stopped container branch does not reconcile changed `.install.conf` ports with an existing **`portainer`** container; documented as pre-existing nuance in story AC.
- **Tests:** Introduced **`tests/install_script_contract.bats`** exercised by **`make test`** (`find … *.bats`) so regressions surface in **`make check`**.

### File List

- `tests/install_script_contract.bats` (new)
- `_bmad-output/implementation-artifacts/spec-install-script.md` (Suggested Review Order, Verification idempotency line, Review Findings resolution pointers)
- `README.md` (Portainer section — `./install.sh --help`)
