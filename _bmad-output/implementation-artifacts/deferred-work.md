# Deferred Work

Action items raised during reviews that were intentionally not addressed in the originating change. Each entry records the source review and the reason for deferral so future work can pick them up with context.

## Deferred from: code review of 1-1-portainer-ce-install-script (2026-05-06)

- Stopped-container path does not reconcile changed `.install.conf` ports against the existing container — story AC #5 explicitly tags this as pre-existing nuance not to refactor in scope. [`install.sh:Idempotency Check`]
- Saved-config and `INSTALL_DIR` input validation gaps: relative paths, symlinked install dirs, `$`/`"` in `PORTAINER_IMAGE`, world-writable `.install.conf` privesc via `source`. Pre-existing config-loader behavior. [`install.sh:Load Saved Config`, `install.sh:Save Configuration`]
- Compose-file HEREDOC does not escape YAML-special characters in interpolated values. Pre-existing; inputs are validated upstream and the script is root-only. [`install.sh:Generate Docker Compose File`]
- `docker start portainer` failure on the stopped-container path exits silently under `set -e` with no remediation message. Pre-existing path. [`install.sh:Idempotency Check`]
- Readiness loop matches container name, not state — could report success while Portainer is in a crash-loop. Pre-existing readiness check. [`install.sh:Deploy`]
- No `gpg --dearmor` fallback if Docker upstream switches key serving format. Upstream snippet is canonical; concern is hypothetical. [`install.sh:install_docker_engine_ubuntu`]
- `systemctl start docker` does not detect or unmask a masked unit. Uncommon corner case. [`install.sh:ensure_docker_daemon_and_compose`]
- No verification of partial apt install state (e.g. containerd OK, docker-ce fail). apt's exit code covers the common cases. [`install.sh:install_docker_engine_ubuntu`]
- No `trap ERR` cleanup of stale `/etc/apt/sources.list.d/docker.list` on failed install. Hardening only; not correctness. [`install.sh:install_docker_engine_ubuntu`]
- `doas` / `pkexec` / `su -i` elevation paths produce no `SUDO_USER` and skip docker-group add. Contract documents `sudo` only. [`install.sh:add_sudo_invoker_to_docker_group`]
- No `apt` lock-contention wait/retry. One-shot installer; operator can re-run. [`install.sh:install_docker_engine_ubuntu`]
- No graceful behavior if Docker upstream has not yet published packages for a new Ubuntu release. Spec scopes to 22.04 / 24.04. [`install.sh:install_docker_engine_ubuntu`]
