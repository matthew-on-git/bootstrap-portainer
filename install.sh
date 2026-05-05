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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "Failed to resolve script directory"
[[ -n "$SCRIPT_DIR" ]] || die "SCRIPT_DIR is empty — failed to resolve script directory"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh" || die "Failed to load logging library from ${SCRIPT_DIR}/lib/log.sh"

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
  Docker must be installed and running.
  Safe to re-run — configuration and data volumes are preserved.

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
# Pre-flight Checks
######################################################################

banner "Pre-flight Checks"

[[ $EUID -eq 0 ]] || die "This script must be run as root"

if command -v lsb_release &>/dev/null; then
  [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]] ||
    die "This script requires Ubuntu (detected: $(lsb_release -is))"
else
  die "lsb_release not found — is this Ubuntu?"
fi

command -v docker &>/dev/null || die "Docker is not installed. Please install Docker first."
docker info &>/dev/null || die "Docker daemon is not running. Please start Docker."
docker compose version &>/dev/null || die "Docker Compose plugin is not installed. Please install docker compose plugin."

log_info "Checking internet connectivity..."
curl -sf --max-time 10 https://hub.docker.com >/dev/null 2>&1 ||
  die "Cannot reach Docker Hub — check internet connectivity"

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
