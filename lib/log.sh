#!/usr/bin/env bash
# Shared logging library for bootstrap scripts
# Provides: log_info, log_warn, log_error, die, banner

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'

log_info() { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() {
  log_error "$*"
  exit 1
}
banner() { printf "\n${BOLD}═══ %s ═══${NC}\n\n" "$*"; }
