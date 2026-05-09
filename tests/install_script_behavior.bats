#!/usr/bin/env bats
# Behavioral tests for install.sh — runs the script end-to-end against a
# per-test sandbox of mocked system commands and redirected filesystem paths.
# No live Docker, no live apt, no live systemd. Designed to run inside the
# DevRail dev-toolchain container (root, no privileged caps) under `make test`.
#
# Coverage by AC (per spec-install-script-v2.md):
#   AC #2  — sudo-user → docker group flow (already-member, not-member, root, unset, unsafe)
#   AC #3  — daemon down → systemctl start docker → recovery
#   AC #4  — container running → exit 0 "already running"
#   AC #5  — container stopped → docker start portainer → exit 0
#   AC #6  — `-y` flag → no prompts
#   AC #7  — port equality / port already listening → die
#   AC #8  — corrupt .install.conf → log_warn + continue
#   AC #9  — non-systemd host → die before systemctl/apt
#   AC #10 — :latest at runtime → die
#
# AC #1 (real reachability) and AC #11 (`make check` itself) are not in scope:
# they require a real Docker daemon and the toolchain itself, respectively.

setup() {
  ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
  MOCK_DIR="${BATS_TEST_TMPDIR}/mock"
  CALLS_LOG="${MOCK_DIR}/calls.log"

  mkdir -p \
    "${SANDBOX}/lib" \
    "${SANDBOX}/etc/apt/sources.list.d" \
    "${SANDBOX}/etc/apt/keyrings" \
    "${SANDBOX}/etc/letsencrypt/live" \
    "${SANDBOX}/etc/letsencrypt/renewal-hooks/deploy" \
    "${SANDBOX}/run/systemd/system" \
    "${SANDBOX}/opt/portainer" \
    "${MOCK_DIR}/bin" \
    "${MOCK_DIR}/state"

  # Default: Ubuntu 22.04 jammy on amd64 with systemd init.
  cat > "${SANDBOX}/etc/os-release" <<'EOF'
ID=ubuntu
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 22.04 LTS"
EOF

  # Copy lib/log.sh as-is.
  cp "${ROOT}/lib/log.sh" "${SANDBOX}/lib/log.sh"

  # Copy install.sh, redirecting hardcoded system paths to the sandbox so
  # the script can run without root-on-host privilege beyond what a normal
  # container provides.
  sed \
    -e "s|/etc/os-release|${SANDBOX}/etc/os-release|g" \
    -e "s|/etc/apt/keyrings|${SANDBOX}/etc/apt/keyrings|g" \
    -e "s|/etc/apt/sources.list.d/docker.list|${SANDBOX}/etc/apt/sources.list.d/docker.list|g" \
    -e "s|/run/systemd/system|${SANDBOX}/run/systemd/system|g" \
    -e "s|LETSENCRYPT_DIR=\"/etc/letsencrypt\"|LETSENCRYPT_DIR=\"${SANDBOX}/etc/letsencrypt\"|g" \
    -e "s|INSTALL_DIR_DEFAULT=\"/opt/portainer\"|INSTALL_DIR_DEFAULT=\"${SANDBOX}/opt/portainer\"|g" \
    "${ROOT}/install.sh" > "${SANDBOX}/install.sh"
  chmod +x "${SANDBOX}/install.sh"

  # The TLS bootstrap shells out to `certbot` and `openssl`. Tests need to see
  # call traces and control behavior (cert valid / not valid).
  export SANDBOX_LETSENCRYPT_DIR="${SANDBOX}/etc/letsencrypt"

  _install_stubs

  # Each invocation of `bash install.sh` will pick up these env exports.
  export MOCK_DIR
  export PATH="${MOCK_DIR}/bin:${PATH}"
}

# -- mock state helpers --------------------------------------------------------

_state()       { echo "${MOCK_DIR}/state/$1"; }
_set_state()   { : > "$(_state "$1")"; }
_clear_state() { rm -f "$(_state "$1")"; }

# -- stub generators -----------------------------------------------------------

_install_stubs() {
  local b="${MOCK_DIR}/bin"

  # Generic logger snippet inlined into each stub via printf.
  cat > "$b/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${MOCK_DIR}/calls.log"
state() { echo "${MOCK_DIR}/state/$1"; }
case "$1" in
  info)
    [[ -f "$(state daemon_down)" ]] && exit 1
    exit 0
    ;;
  compose)
    shift
    sub=""; while [[ $# -gt 0 ]]; do
      case "$1" in
        -f) shift 2 ;;
        version|up|down|pull|ps) sub="$1"; shift; break ;;
        *) shift ;;
      esac
    done
    case "$sub" in
      version)
        if [[ "${1:-}" == "--short" ]]; then
          cat "$(state compose_version_short)" 2>/dev/null || echo "2.27.1"
        else
          echo "Docker Compose version v2.27.1"
        fi
        ;;
      up)
        # Successful deploy → next `docker ps` should see portainer running.
        : > "${MOCK_DIR}/state/portainer_running"
        ;;
      *) : ;;
    esac
    exit 0
    ;;
  ps)
    # Distinguish `docker ps` (running only) from `docker ps -a` (incl. stopped).
    if [[ "$*" == *' -a '* || "$*" == *' -a' ]]; then
      [[ -f "$(state portainer_running)" || -f "$(state portainer_stopped)" ]] && echo "portainer"
    else
      [[ -f "$(state portainer_running)" ]] && echo "portainer"
    fi
    exit 0
    ;;
  start)
    # Mark the container as running after a successful start.
    _set_state() { : > "${MOCK_DIR}/state/$1"; }
    [[ "$2" == "portainer" ]] && _set_state portainer_running
    exit 0
    ;;
esac
exit 0
STUB

  cat > "$b/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${MOCK_DIR}/calls.log"
case "$1" in
  start)
    # If the scenario says the daemon recovers, clear the daemon_down marker.
    [[ -f "${MOCK_DIR}/state/daemon_recovers" ]] && rm -f "${MOCK_DIR}/state/daemon_down"
    exit 0
    ;;
  enable) exit 0 ;;
esac
exit 0
STUB

  cat > "$b/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
STUB

  cat > "$b/dpkg" <<'STUB'
#!/usr/bin/env bash
printf 'dpkg %s\n' "$*" >> "${MOCK_DIR}/calls.log"
case "$*" in
  *--print-architecture*)
    cat "${MOCK_DIR}/state/dpkg_arch" 2>/dev/null || echo amd64
    ;;
esac
exit 0
STUB

  cat > "$b/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${MOCK_DIR}/calls.log"
out=""; want_code=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) want_code="$2"; shift 2 ;;
    --proto|--tlsv1.2|-s|-f|-S|--max-time|--silent) shift ;;
    -fsSL|-sf) shift ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] && printf 'mock-gpg-key\n' > "$out"
[[ "$want_code" == '%{http_code}' ]] && printf '200'
exit 0
STUB

  cat > "$b/ss" <<'STUB'
#!/usr/bin/env bash
printf 'ss %s\n' "$*" >> "${MOCK_DIR}/calls.log"
# Each line in mock_ss_listeners is one "Local-Address:Port".
if [[ -f "${MOCK_DIR}/state/mock_ss_listeners" ]]; then
  while read -r addr; do
    [[ -z "$addr" ]] && continue
    # Mimic `ss -ltnH` columns: State Recv-Q Send-Q LocalAddr:Port Peer:Port
    printf 'LISTEN 0 4096 %s *:*\n' "$addr"
  done < "${MOCK_DIR}/state/mock_ss_listeners"
fi
exit 0
STUB

  cat > "$b/usermod" <<'STUB'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
STUB

  cat > "$b/id" <<'STUB'
#!/usr/bin/env bash
printf 'id %s\n' "$*" >> "${MOCK_DIR}/calls.log"
state="${MOCK_DIR}/state"
if [[ "${1:-}" == "-nG" ]]; then
  user="${2:-}"
  if [[ -f "${state}/user_${user}_in_docker_group" ]]; then
    echo "${user} sudo docker"
  elif [[ -f "${state}/user_${user}_exists" ]]; then
    echo "${user} sudo"
  else
    exit 1
  fi
  exit 0
fi
user="${1:-}"
[[ -f "${state}/user_${user}_exists" || -f "${state}/user_${user}_in_docker_group" ]] && exit 0
exit 1
STUB

  cat > "$b/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  cat > "$b/certbot" <<'STUB'
#!/usr/bin/env bash
printf 'certbot %s\n' "$*" >> "${MOCK_DIR}/calls.log"
domain=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) domain="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# Test scenario hook: optionally make certbot fail.
[[ -f "${MOCK_DIR}/state/certbot_fail" ]] && exit 1
# Drop a fake cert at the expected sandbox path so subsequent install.sh
# checks (cert presence, compose generation) succeed.
if [[ -n "$domain" && -n "${SANDBOX_LETSENCRYPT_DIR:-}" ]]; then
  mkdir -p "${SANDBOX_LETSENCRYPT_DIR}/live/${domain}"
  printf 'mock-fullchain\n' > "${SANDBOX_LETSENCRYPT_DIR}/live/${domain}/fullchain.pem"
  printf 'mock-privkey\n'   > "${SANDBOX_LETSENCRYPT_DIR}/live/${domain}/privkey.pem"
fi
exit 0
STUB

  cat > "$b/openssl" <<'STUB'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "${MOCK_DIR}/calls.log"
# Used by cert_is_valid_for_at_least: openssl x509 -in <cert> -noout -checkend N
# Default: pretend the cert is NOT valid (return 1) so install.sh proceeds to
# call certbot. Tests opt in to the "skip certbot" path by touching
# state/openssl_cert_valid.
case "$1" in
  x509)
    [[ -f "${MOCK_DIR}/state/openssl_cert_valid" ]] && exit 0
    exit 1
    ;;
esac
exit 0
STUB

  chmod +x "$b"/*
}

# -- AC #4: container already running -----------------------------------------

@test "AC#4: container running → exit 0 with 'already running'" {
  _set_state portainer_running

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  # No compose file should have been generated on the running path.
  [ ! -f "${SANDBOX}/opt/portainer/docker-compose.yaml" ]
  # Deploy must NOT have been invoked.
  ! grep -q 'compose .*up -d' "${CALLS_LOG}"
}

# -- AC #5: container stopped -------------------------------------------------

@test "AC#5: container stopped → docker start portainer → exit 0" {
  _set_state portainer_stopped

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  grep -Eq '^docker start portainer$' "${CALLS_LOG}"
  # Compose deploy must NOT happen on the stopped-restart path.
  ! grep -q 'compose .*up -d' "${CALLS_LOG}"
}

# -- AC #3: daemon down → systemctl start docker → recovery -------------------

@test "AC#3: daemon down recoverable → systemctl start docker → proceeds" {
  _set_state daemon_down
  _set_state daemon_recovers
  _set_state portainer_running   # short-circuit deploy after recovery

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  grep -Eq '^systemctl start docker$' "${CALLS_LOG}"
}

@test "AC#3: daemon down and stays down → die with journalctl hint" {
  _set_state daemon_down

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"journalctl -u docker.service"* ]]
}

# -- AC #9: non-systemd host --------------------------------------------------

@test "AC#9: /run/systemd/system absent + daemon down → die before systemctl start" {
  _set_state daemon_down
  rm -rf "${SANDBOX}/run/systemd/system"

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd is required"* ]]
  ! grep -Eq '^systemctl start docker$' "${CALLS_LOG}"
}

# -- AC #2: SUDO_USER → docker group ------------------------------------------

@test "AC#2: SUDO_USER unset → warn and skip group add" {
  _set_state portainer_running
  unset SUDO_USER

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"SUDO_USER is unset"* ]]
  ! grep -q '^usermod ' "${CALLS_LOG}"
}

@test "AC#2: SUDO_USER=root → skip group add (info, not warn)" {
  _set_state portainer_running

  run env SUDO_USER=root bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"Invoking user is root"* ]]
  ! grep -q '^usermod ' "${CALLS_LOG}"
}

@test "AC#2: SUDO_USER unsafe (shell metachar) → die" {
  _set_state portainer_running

  run env "SUDO_USER=bad;rm" bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected as unsafe username"* ]]
  ! grep -q '^usermod ' "${CALLS_LOG}"
}

@test "AC#2: SUDO_USER nonexistent → warn and skip" {
  _set_state portainer_running

  run env SUDO_USER=alice bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a local user ID"* ]]
  ! grep -q '^usermod ' "${CALLS_LOG}"
}

@test "AC#2: SUDO_USER already in docker group → no usermod call" {
  _set_state portainer_running
  _set_state user_alice_in_docker_group

  run env SUDO_USER=alice bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the docker group"* ]]
  ! grep -q '^usermod ' "${CALLS_LOG}"
}

@test "AC#2: SUDO_USER not in docker group → usermod -aG docker invoked" {
  _set_state portainer_running
  _set_state user_alice_exists

  run env SUDO_USER=alice bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  grep -Eq '^usermod -aG docker alice$' "${CALLS_LOG}"
  [[ "$output" == *"Added user alice to the docker group"* ]]
  [[ "$output" == *"newgrp docker"* ]]
}

# -- AC #7: port collision and equality ---------------------------------------

@test "AC#7: HTTP port equals EDGE port → die before deploy" {
  cat > "${SANDBOX}/opt/portainer/.install.conf" <<EOF
INSTALL_DIR="${SANDBOX}/opt/portainer"
PORTAINER_HTTP_PORT="9443"
PORTAINER_EDGE_PORT="9443"
PORTAINER_IMAGE="portainer/portainer-ce:sts"
EOF

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTPS port and Edge port must differ"* ]]
  ! grep -q 'compose .*up -d' "${CALLS_LOG}"
}

@test "AC#7: HTTP port already listening → die before deploy" {
  printf '*:9443\n' > "$(_state mock_ss_listeners)"

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"already in use"* ]]
  ! grep -q 'compose .*up -d' "${CALLS_LOG}"
}

@test "AC#7: ss reports unrelated port (8000-suffixed IP octet) → no false positive on 80" {
  # Force ports to 80/8000 to simulate a tricky overlap.
  cat > "${SANDBOX}/opt/portainer/.install.conf" <<EOF
INSTALL_DIR="${SANDBOX}/opt/portainer"
PORTAINER_HTTP_PORT="80"
PORTAINER_EDGE_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce:sts"
EOF
  # An IP whose last octet is 80, but the listener is actually on port 9443:
  printf '192.168.0.80:9443\n' > "$(_state mock_ss_listeners)"

  run bash "${SANDBOX}/install.sh" -y

  # Should NOT die for "port 80 in use" — the listener is on 9443.
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "TCP port 80 is already in use" ]]
}

# -- AC #10: :latest rejection ------------------------------------------------

@test "AC#10: PORTAINER_IMAGE=:latest from saved config → die" {
  cat > "${SANDBOX}/opt/portainer/.install.conf" <<EOF
INSTALL_DIR="${SANDBOX}/opt/portainer"
PORTAINER_HTTP_PORT="9443"
PORTAINER_EDGE_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce:latest"
EOF

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"must not use the :latest tag"* ]]
  [ ! -f "${SANDBOX}/opt/portainer/docker-compose.yaml" ]
}

@test "AC#10: PORTAINER_IMAGE without explicit tag → die" {
  cat > "${SANDBOX}/opt/portainer/.install.conf" <<EOF
INSTALL_DIR="${SANDBOX}/opt/portainer"
PORTAINER_HTTP_PORT="9443"
PORTAINER_EDGE_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce"
EOF

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"must include an explicit tag"* ]]
  [ ! -f "${SANDBOX}/opt/portainer/docker-compose.yaml" ]
}

# -- AC #8: corrupt .install.conf ---------------------------------------------

@test "AC#8: corrupt .install.conf → log_warn and continue with defaults" {
  # Source-failing config: unmatched quote.
  printf '%s\n' 'PORTAINER_HTTP_PORT="9443' > "${SANDBOX}/opt/portainer/.install.conf"
  _set_state portainer_running   # short-circuit deploy

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"Failed to load config"* ]]
}

# -- AC #6: -y flag never reads stdin -----------------------------------------

@test "AC#6: -y flag → no read on stdin" {
  _set_state portainer_running

  # Closing stdin (</dev/null) ensures no `read` call would succeed silently.
  run bash -c "bash '${SANDBOX}/install.sh' -y </dev/null"

  [ "$status" -eq 0 ]
}

# -- Compose v2 assertion -----------------------------------------------------

@test "Compose v1 only → assert_docker_compose_v2 dies" {
  echo "1.29.2" > "$(_state compose_version_short)"
  _set_state portainer_running

  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker Compose v2 required"* ]]
}

# -- Fresh deploy path (smoke) ------------------------------------------------

@test "fresh deploy: no container → ports checked, compose written, up -d invoked" {
  # No portainer_running, no portainer_stopped → fresh deploy path.
  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  # Port-collision check ran on the fresh path.
  grep -Eq '^ss ' "${CALLS_LOG}"
  # Compose file generated.
  [ -f "${SANDBOX}/opt/portainer/docker-compose.yaml" ]
  grep -Fq 'image: portainer/portainer-ce:sts' "${SANDBOX}/opt/portainer/docker-compose.yaml"
  # Compose up -d invoked.
  grep -q 'compose .*up -d' "${CALLS_LOG}"
}

# -- v3: TLS_MODE branches ----------------------------------------------------

@test "AC#12: TLS_MODE=off (default) → no certbot, no bind-mount, no --sslcert" {
  run bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  ! grep -q '^certbot ' "${CALLS_LOG}"
  ! grep -Fq -- '--sslcert' "${SANDBOX}/opt/portainer/docker-compose.yaml"
  ! grep -Fq '/certs:ro' "${SANDBOX}/opt/portainer/docker-compose.yaml"
}

@test "AC#13: TLS_MODE=letsencrypt-http → certbot --standalone called, compose has --sslcert/--sslkey" {
  run env TLS_MODE=letsencrypt-http \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  grep -Fq 'certbot certonly --standalone' "${CALLS_LOG}"
  grep -Fq -- '-d portainer.example.com' "${CALLS_LOG}"
  grep -Fq -- '-m ops@example.com'       "${CALLS_LOG}"

  local compose="${SANDBOX}/opt/portainer/docker-compose.yaml"
  grep -Fq -- '--sslcert /certs/live/portainer.example.com/fullchain.pem' "$compose"
  grep -Fq -- '--sslkey /certs/live/portainer.example.com/privkey.pem'    "$compose"
  grep -Fq "${SANDBOX}/etc/letsencrypt:/certs:ro" "$compose"

  # Renewal hook deployed and executable.
  local hook="${SANDBOX}/etc/letsencrypt/renewal-hooks/deploy/portainer.sh"
  [ -f "$hook" ]
  [ -x "$hook" ]
  grep -Fq 'docker restart portainer' "$hook"
}

@test "AC#14: TLS_MODE=letsencrypt-http with port 80 in use → die before certbot" {
  printf '*:80\n' > "$(_state mock_ss_listeners)"

  run env TLS_MODE=letsencrypt-http \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"port 80 free"* ]]
  ! grep -Fq 'certbot certonly --standalone' "${CALLS_LOG}"
}

@test "AC#15: TLS_MODE=dns-cloudflare → CF creds written 0600, certbot --dns-cloudflare called" {
  run env TLS_MODE=dns-cloudflare \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          CF_API_TOKEN=secret-token-xyz \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  grep -Fq 'certbot certonly --dns-cloudflare' "${CALLS_LOG}"
  grep -Fq -- '--dns-cloudflare-credentials' "${CALLS_LOG}"

  local creds="${SANDBOX}/etc/letsencrypt/.cloudflare-credentials"
  [ -f "$creds" ]
  [ "$(stat -c '%a' "$creds")" = "600" ]
  grep -Fq 'dns_cloudflare_api_token = secret-token-xyz' "$creds"

  # Token must NOT leak into stdout/stderr or .install.conf.
  ! [[ "$output" == *"secret-token-xyz"* ]]
  ! grep -Fq 'secret-token-xyz' "${SANDBOX}/opt/portainer/.install.conf"
  ! grep -Eq '^CF_API_TOKEN' "${SANDBOX}/opt/portainer/.install.conf"
}

@test "AC#16: cert already valid for >= 30 days → skip certbot" {
  # Pre-stage a fake cert and tell the openssl stub to report it valid.
  mkdir -p "${SANDBOX}/etc/letsencrypt/live/portainer.example.com"
  printf 'pre-existing-fullchain\n' > "${SANDBOX}/etc/letsencrypt/live/portainer.example.com/fullchain.pem"
  printf 'pre-existing-privkey\n'   > "${SANDBOX}/etc/letsencrypt/live/portainer.example.com/privkey.pem"
  _set_state openssl_cert_valid

  run env TLS_MODE=letsencrypt-http \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  # certbot apt install still happens (cheap, idempotent), but the cert
  # acquisition itself is skipped.
  ! grep -Fq 'certbot certonly --standalone' "${CALLS_LOG}"
  [[ "$output" == *"valid for at least 30 days"* ]]
}

@test "AC#18: TLS drift while container running → warn + exit 0" {
  # Pre-existing config saved as TLS off; container running.
  cat > "${SANDBOX}/opt/portainer/.install.conf" <<EOF
INSTALL_DIR="${SANDBOX}/opt/portainer"
PORTAINER_HTTP_PORT="9443"
PORTAINER_EDGE_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce:sts"
TLS_MODE="off"
DOMAIN=""
CERTBOT_EMAIL=""
EOF
  _set_state portainer_running

  # Operator now requests dns-cloudflare via env.
  run env TLS_MODE=dns-cloudflare \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          CF_API_TOKEN=token \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuration drift detected"* ]]
  [[ "$output" == *"docker rm -f portainer"* ]]
  # No cert work: the drift bail happens before TLS bootstrap.
  ! grep -Fq 'certbot ' "${CALLS_LOG}"
}

@test "AC#20: TLS_MODE=letsencrypt-http does NOT install nginx/Caddy/Traefik" {
  run env TLS_MODE=letsencrypt-http \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  ! grep -Eq 'apt-get install .* nginx'   "${CALLS_LOG}"
  ! grep -Eq 'apt-get install .* caddy'   "${CALLS_LOG}"
  ! grep -Eq 'apt-get install .* traefik' "${CALLS_LOG}"
}

@test "v3: dns-cloudflare without token AND no creds file → die" {
  run env TLS_MODE=dns-cloudflare \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -ne 0 ]
  [[ "$output" == *"CF_API_TOKEN is required"* ]]
  ! grep -Fq 'certbot ' "${CALLS_LOG}"
}

@test "v3: dns-cloudflare with pre-existing creds file → reuse (no token prompt)" {
  install -m 0600 -D /dev/stdin "${SANDBOX}/etc/letsencrypt/.cloudflare-credentials" <<<'dns_cloudflare_api_token = pre-existing-token'

  run env TLS_MODE=dns-cloudflare \
          DOMAIN=portainer.example.com \
          CERTBOT_EMAIL=ops@example.com \
          bash "${SANDBOX}/install.sh" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"Reusing Cloudflare API token"* ]]
  grep -Fq 'certbot certonly --dns-cloudflare' "${CALLS_LOG}"
}
