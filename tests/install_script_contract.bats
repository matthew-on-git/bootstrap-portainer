#!/usr/bin/env bats
# Contract smoke tests for Portainer bootstrap scripts (no live Docker / systemd).
# Run via: bats tests/install_script_contract.bats — also picked up by `make test`.

setup() {
  ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  INSTALL="${ROOT}/install.sh"
  LOG_LIB="${ROOT}/lib/log.sh"
}

@test "install.sh pins default Portainer image to sts (not latest)" {
  grep -Fq 'PORTAINER_IMAGE_DEFAULT="portainer/portainer-ce:sts"' "$INSTALL"
}

@test "install.sh does not assign PORTAINER_IMAGE_DEFAULT to a latest tag" {
  run grep -E '^PORTAINER_IMAGE_DEFAULT=.*:latest' "$INSTALL"
  [ "$status" -ne 0 ]
}

@test "install.sh rejects :latest at runtime regardless of source" {
  grep -Fq 'PORTAINER_IMAGE must not use the :latest tag' "$INSTALL"
}

@test "Docker registry HTTPS probe failures are warnings only" {
  grep -Fq 'log_warn "Cannot reach https://registry-1.docker.io/v2/' "$INSTALL"
}

@test "install.sh defines sudo-user docker group membership" {
  grep -Fq 'add_sudo_invoker_to_docker_group()' "$INSTALL"
  grep -Fq 'usermod -aG docker' "$INSTALL"
}

@test "install.sh installs Compose v2 plugin from Docker apt repo" {
  grep -Fq 'docker-compose-plugin' "$INSTALL"
}

@test "install.sh asserts Docker Compose major version >= 2" {
  grep -Fq 'assert_docker_compose_v2' "$INSTALL"
}

@test "install.sh requires systemd as init before managing docker.service" {
  grep -Fq '/run/systemd/system' "$INSTALL"
}

@test "install.sh validates SUDO_USER against a safe username pattern" {
  grep -Fq 'SUDO_USER value rejected as unsafe username' "$INSTALL"
}

@test "fresh deploy path invokes publish-port check before compose generation" {
  # Order: running-exit → existing-stopped block (with `docker start portainer`)
  # → ensure_publish_ports invocation → COMPOSE_FILE assignment.
  # Match line numbers using indent-tolerant patterns so trivial reformat
  # (shfmt etc.) does not break this contract test.
  run awk '
    /^if[[:space:]]+docker[[:space:]]+ps[[:space:]]+--format/  { r = NR }
    /^if[[:space:]]+docker[[:space:]]+ps[[:space:]]+-a[[:space:]]+--format/ { s = NR }
    /^[[:space:]]*docker[[:space:]]+start[[:space:]]+portainer[[:space:]]*$/ { ds = NR }
    /^[[:space:]]*ensure_publish_ports_free_for_compose_deploy[[:space:]]+"\$PORTAINER_HTTP_PORT"/ { call = NR }
    /^[[:space:]]*COMPOSE_FILE=/ { compose = NR }
    END { exit !((r > 0) && (s > 0) && (ds > s) && (call > ds) && (compose > call)) }
  ' "$INSTALL"
  [ "$status" -eq 0 ]
}

@test "lib/log.sh provides the full logging surface" {
  grep -Eq '^[[:space:]]*log_info[[:space:]]*\(\)'  "$LOG_LIB"
  grep -Eq '^[[:space:]]*log_warn[[:space:]]*\(\)'  "$LOG_LIB"
  grep -Eq '^[[:space:]]*log_error[[:space:]]*\(\)' "$LOG_LIB"
  grep -Eq '^[[:space:]]*die[[:space:]]*\(\)'       "$LOG_LIB"
  grep -Eq '^[[:space:]]*banner[[:space:]]*\(\)'    "$LOG_LIB"
}
