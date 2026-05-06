#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────
# bootstrap-portainer — Idempotent installer for Portainer CE
#
# Deploys Portainer CE via Docker Compose:
#   Portainer CE with Docker socket access
#
# Supports:  Ubuntu 22.04 / 24.04
# Re-run safe: configuration and data volumes are preserved
# ───────────────────────────────────────────────────────────────────
set -euo pipefail

######################################################################
# Constants & Defaults
######################################################################

INSTALL_DIR_DEFAULT="/opt/portainer"
PORTAINER_HTTP_PORT_DEFAULT=9443
PORTAINER_EDGE_PORT_DEFAULT=8000
PORTAINER_IMAGE_DEFAULT="portainer/portainer-ce:sts"

CONF_FILE=".install.conf"

######################################################################
# Load Shared Library
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  printf '%s\n' "bootstrap-portainer: failed to resolve script directory" >&2
  exit 1
}
[[ -n "$SCRIPT_DIR" ]] || {
  printf '%s\n' "bootstrap-portainer: SCRIPT_DIR is empty — failed to resolve script directory" >&2
  exit 1
}
if [[ ! -f "${SCRIPT_DIR}/lib/log.sh" ]]; then
  printf '%s\n' "bootstrap-portainer: missing logging library ${SCRIPT_DIR}/lib/log.sh" >&2
  exit 1
fi
# shellcheck source=lib/log.sh
if ! source "${SCRIPT_DIR}/lib/log.sh"; then
  printf '%s\n' "bootstrap-portainer: failed to load logging library ${SCRIPT_DIR}/lib/log.sh" >&2
  exit 1
fi

######################################################################
# Argument Parsing
######################################################################

AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes)
    AUTO_YES=true
    shift
    ;;
  -h | --help)
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

Idempotent installer for Portainer CE via Docker Compose.

Options:
  -y, --yes    Non-interactive mode (accept all defaults / saved config)
  -h, --help   Show this help message

Requirements:
  Requires root on Ubuntu 22.04 / 24.04.
  If Docker is missing, it is installed from Docker's official apt repository (Engine + Compose v2 plugin).
  Safe to re-run — configuration and data volumes are preserved.

Side effects:
  When invoked via sudo from a normal login (SUDO_USER set, not root), that user is
  added to the docker group. Log out / back in (or run: newgrp docker) to take effect.

Default Ports:
  HTTPS UI: 9443
  Edge Tunnel: 8000
USAGE
    exit 0
    ;;
  *) die "Unknown option: $1" ;;
  esac
done

######################################################################
# OS detection & Docker bootstrap
######################################################################

# Read a single key from /etc/os-release without sourcing the file (avoids
# leaking variables into the global shell and avoids executing arbitrary
# shell metacharacters in os-release values).
read_os_release_field() {
  local key="$1"
  awk -F= -v k="$key" '
    $1 == k {
      v = $2
      sub(/^"/, "", v)
      sub(/"$/, "", v)
      print v
      exit
    }
  ' /etc/os-release
}

ensure_ubuntu_supported() {
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release — cannot verify OS"
  local id version_id
  id="$(read_os_release_field ID)"
  version_id="$(read_os_release_field VERSION_ID)"
  [[ "$id" == "ubuntu" ]] || die "This script requires Ubuntu (detected ID=${id:-unknown})"
  case "$version_id" in
  22.04 | 24.04) ;;
  *) die "This script supports Ubuntu 22.04 / 24.04 only (detected ${version_id:-unknown})" ;;
  esac
}

# Verify systemd is the running init — `systemctl` against another init
# (containers without systemd, WSL with default shim) returns confusing
# errors that we'd rather diagnose up-front.
ensure_systemd_init() {
  [[ -d /run/systemd/system ]] || die "systemd is required (/run/systemd/system not found). \
This installer manages docker.service via systemctl and does not support non-systemd hosts."
}

# Map the running architecture to the Docker apt channel and reject any
# arch Docker does not publish for.
docker_supported_arch() {
  local arch
  arch="$(dpkg --print-architecture)"
  case "$arch" in
  amd64 | arm64 | armhf | s390x | ppc64el) printf '%s\n' "$arch" ;;
  *) die "Unsupported architecture for Docker upstream apt: $arch (supported: amd64, arm64, armhf, s390x, ppc64el)" ;;
  esac
}

install_docker_engine_ubuntu() {
  banner "Installing Docker Engine"

  ensure_systemd_init

  log_info "Removing conflicting distro Docker packages if present (safe if none are installed)"
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc \
    >/dev/null 2>&1 || true

  log_info "Installing apt prerequisites..."
  apt-get update || die "apt-get update failed"
  apt-get install -y ca-certificates curl >/dev/null || die "Failed to install ca-certificates and curl"

  install -m 0755 -d /etc/apt/keyrings
  local arch gpg=/etc/apt/keyrings/docker.asc
  arch="$(docker_supported_arch)"

  # Atomic, hardened key download: write to a temporary file with strict
  # perms and ownership via `install`, then move into place. Avoids a
  # TOCTOU between `curl -o` and a separate `chmod`.
  if [[ ! -s "$gpg" ]]; then
    local gpg_tmp="${gpg}.tmp.$$"
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://download.docker.com/linux/ubuntu/gpg" -o "$gpg_tmp" \
      || die "Failed to download Docker apt signing key"
    install -m 0644 -o root -g root "$gpg_tmp" "$gpg" \
      || { rm -f "$gpg_tmp"; die "Failed to install Docker apt signing key at $gpg"; }
    rm -f "$gpg_tmp"
  else
    log_info "Docker apt signing key already present at $gpg — skipping download"
  fi

  local codename
  codename="$(read_os_release_field VERSION_CODENAME)"
  [[ -n "$codename" ]] || die "VERSION_CODENAME unset in /etc/os-release"

  local sources=/etc/apt/sources.list.d/docker.list
  local desired_line
  desired_line="$(printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable' \
    "$arch" "$gpg" "$codename")"

  # Idempotent sources write: only rewrite when content differs (or file
  # is missing), so re-runs do not churn apt state.
  if [[ ! -f "$sources" ]] || ! grep -Fxq "$desired_line" "$sources"; then
    rm -f "$sources"
    printf '%s\n' "$desired_line" >"$sources" \
      || die "Failed to write $sources"
  else
    log_info "$sources already configured — skipping rewrite"
  fi

  apt-get update || die "apt-get update failed after adding Docker repository"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    || die "Failed to install Docker Engine packages"

  systemctl enable --now docker || die "Failed to enable/start docker.service"
  log_info "Docker Engine and Compose plugin are installed"
}

# Capture the major version reported by `docker compose version` and require >= 2.
assert_docker_compose_v2() {
  local raw major
  raw="$(docker compose version --short 2>/dev/null)" \
    || die "Failed to query 'docker compose version'"
  # raw looks like "2.27.1" or "v2.27.1" — strip optional leading 'v'
  raw="${raw#v}"
  major="${raw%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || die "Cannot parse Docker Compose version: $raw"
  (( major >= 2 )) || die "Docker Compose v2 required (detected: $raw)"
}

ensure_docker_daemon_and_compose() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    assert_docker_compose_v2
    if docker info &>/dev/null; then
      return 0
    fi
    log_info "Docker is installed but the daemon is not responding — attempting to start docker.service"
    ensure_systemd_init
    systemctl start docker || die "Docker is installed but the daemon failed to start (systemctl start docker)."
    docker info &>/dev/null || die "Docker daemon is still unreachable after start — check logs: journalctl -u docker.service"
    return 0
  fi

  log_warn "Docker Engine or Compose v2 plugin is missing — installing from Docker upstream (official apt repo)"
  install_docker_engine_ubuntu
  command -v docker &>/dev/null || die "Docker CLI missing after installation"
  docker compose version &>/dev/null || die "Compose v2 plugin missing after installation"
  assert_docker_compose_v2
  docker info &>/dev/null || die "Docker daemon unreachable after installation — check: journalctl -u docker.service"
}

# Non-root docker CLI access: add the account that invoked sudo to group `docker`.
add_sudo_invoker_to_docker_group() {
  local u="${SUDO_USER:-}"
  if [[ -z "$u" ]]; then
    log_warn "Cannot add anyone to the docker group (SUDO_USER is unset). Run via sudo from a normal login (e.g. sudo ./install.sh), or run: sudo usermod -aG docker \$USER"
    return 0
  fi
  if [[ "$u" == "root" ]]; then
    log_info "Invoking user is root; skipping docker group membership for that account."
    return 0
  fi
  # POSIX-portable username pattern (per useradd(8) NAME_REGEX). Reject anything
  # that could carry shell metacharacters into usermod or id below.
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] \
    || die "SUDO_USER value rejected as unsafe username: ${u}"
  if ! id "$u" &>/dev/null; then
    log_warn "SUDO_USER=${u} is not a local user ID; skipping docker group membership."
    return 0
  fi
  local groups
  groups="$(id -nG "$u" 2>/dev/null)" || die "Cannot read groups for ${u}"
  case " ${groups} " in
  *' docker '*)
    log_info "User ${u} is already in the docker group."
    ;;
  *)
    usermod -aG docker "$u" || die "Failed to add user ${u} to the docker group"
    log_info "Added user ${u} to the docker group."
    log_warn "Log out and back in (or: newgrp docker) before running docker without sudo as ${u}."
    ;;
  esac
}

######################################################################
# Pre-flight Checks
######################################################################

banner "Pre-flight Checks"

[[ $EUID -eq 0 ]] || die "This script must be run as root"

ensure_ubuntu_supported
ensure_docker_daemon_and_compose
add_sudo_invoker_to_docker_group

log_info "Checking registry HTTPS reachability (optional)..."
# Probe the registry endpoint actually used by `docker pull`, not the website at
# hub.docker.com — the website can be reachable while registry-1 is firewalled
# (and vice versa). v2/ returns 401 to anonymous clients; we only care that
# TLS terminates and the endpoint answers.
if ! curl --proto '=https' --tlsv1.2 -s -o /dev/null --max-time 10 \
     -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null \
     | grep -qE '^(200|401|403)$'; then
  log_warn "Cannot reach https://registry-1.docker.io/v2/ — image pull may still succeed via proxy or mirror; continuing"
fi

log_info "Pre-flight checks passed"

######################################################################
# Load Saved Config
######################################################################

INSTALL_DIR="$INSTALL_DIR_DEFAULT"
PORTAINER_HTTP_PORT="$PORTAINER_HTTP_PORT_DEFAULT"
PORTAINER_EDGE_PORT="$PORTAINER_EDGE_PORT_DEFAULT"
PORTAINER_IMAGE="$PORTAINER_IMAGE_DEFAULT"

for candidate in "${INSTALL_DIR}/${CONF_FILE}" "${INSTALL_DIR_DEFAULT}/${CONF_FILE}"; do
  if [[ -f "$candidate" ]]; then
    log_info "Loading saved configuration from ${candidate}"
    # shellcheck source=/dev/null
    if ! source "$candidate" 2>/dev/null; then
      log_warn "Failed to load config from ${candidate} — using defaults"
    fi
    break
  fi
done

######################################################################
# Interactive Configuration
######################################################################

banner "Configuration"

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && return 0
  return 1
}

# Returns 0 when something is listening on TCP {port} on the host; 1 when idle or unknown.
tcp_port_listening() {
  local port="$1"
  if ! command -v ss &>/dev/null; then
    log_warn "ss not found — cannot verify whether port ${port} is listening; continuing"
    return 1
  fi
  # Parse only the local-address column ($4) of `ss -ltnH` and compare the
  # trailing port. A naive grep would also match port numbers occurring as
  # an octet of an IP (e.g. 192.168.0.80 false-positives port 80).
  ss -ltnH 2>/dev/null | awk -v p="$port" '
    {
      n = split($4, a, ":")
      if (n > 0 && a[n] == p) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  '
}

ensure_publish_ports_free_for_compose_deploy() {
  local http="$1" edge="$2"
  [[ "$http" != "$edge" ]] || die "HTTPS port and Edge port must differ (both are ${http})"

  local p
  for p in "$http" "$edge"; do
    tcp_port_listening "$p" && die "TCP port ${p} is already in use — choose another value or stop the conflicting service"
  done
}

prompt() {
  local var="$1" msg="$2" default="$3"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  read -rp "$(printf "${BLUE}>>>${NC} %s [%s]: " "$msg" "$default")" input
  printf -v "$var" '%s' "${input:-$default}"
}

prompt_port() {
  local var="$1" msg="$2" default="$3"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  while true; do
    read -rp "$(printf "${BLUE}>>>${NC} %s [%s]: " "$msg" "$default")" input
    input="${input:-$default}"
    if valid_port "$input"; then
      printf -v "$var" '%s' "$input"
      return
    fi
    log_error "Invalid port: $input. Must be a number between 1 and 65535."
  done
}

prompt INSTALL_DIR "Install directory" "$INSTALL_DIR"
prompt_port PORTAINER_HTTP_PORT "Portainer HTTPS port (UI)" "$PORTAINER_HTTP_PORT"
prompt_port PORTAINER_EDGE_PORT "Portainer Edge tunnel port" "$PORTAINER_EDGE_PORT"
prompt PORTAINER_IMAGE "Portainer image" "$PORTAINER_IMAGE"

# Spec contract: never use unpinned tags. Reject `:latest` (or no tag at all)
# whether sourced from a saved .install.conf, an interactive prompt, or the
# default — single point of enforcement.
[[ "$PORTAINER_IMAGE" == *:* ]] \
  || die "PORTAINER_IMAGE must include an explicit tag (e.g. portainer/portainer-ce:sts) — got '${PORTAINER_IMAGE}'"
[[ "${PORTAINER_IMAGE##*:}" != "latest" ]] \
  || die "PORTAINER_IMAGE must not use the :latest tag — pin a stable tag (e.g. portainer/portainer-ce:sts)"

######################################################################
# Save Configuration
######################################################################

mkdir -p "$INSTALL_DIR" || die "Failed to create install directory: $INSTALL_DIR"

cat >"${INSTALL_DIR}/${CONF_FILE}" <<CONF
# bootstrap-portainer saved configuration — $(date -Iseconds)
INSTALL_DIR="${INSTALL_DIR}"
PORTAINER_HTTP_PORT="${PORTAINER_HTTP_PORT}"
PORTAINER_EDGE_PORT="${PORTAINER_EDGE_PORT}"
PORTAINER_IMAGE="${PORTAINER_IMAGE}"
CONF
chmod 600 "${INSTALL_DIR}/${CONF_FILE}" || die "Failed to set permissions on config file"
log_info "Configuration saved"

######################################################################
# Idempotency Check
######################################################################

banner "Deployment"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
  log_info "Portainer container is already running — nothing to do"
  exit 0
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
  log_info "Portainer container exists but is stopped — starting..."
  docker start portainer
  log_info "Portainer started successfully"
  exit 0
fi

ensure_publish_ports_free_for_compose_deploy "$PORTAINER_HTTP_PORT" "$PORTAINER_EDGE_PORT"

######################################################################
# Generate Docker Compose File
######################################################################

COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yaml"

log_info "Generating Docker Compose file: ${COMPOSE_FILE}"

cat >"$COMPOSE_FILE" <<COMPOSE || die "Failed to write compose file: $COMPOSE_FILE"
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
COMPOSE

log_info "Docker Compose file created"

######################################################################
# Deploy Portainer
######################################################################

log_info "Deploying Portainer CE..."

if ! docker compose -f "$COMPOSE_FILE" up -d; then
  die "Failed to deploy Portainer — check logs with: docker compose -f ${COMPOSE_FILE} logs"
fi

# Wait for container to be ready (up to 10 seconds)
for i in 1 2 3 4 5; do
  sleep 2
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^portainer$"; then
    log_info "Portainer CE deployed successfully"
    log_info "Access Portainer at: https://localhost:${PORTAINER_HTTP_PORT}"
    exit 0
  fi
done

die "Portainer container is not running — check logs with: docker logs portainer"
