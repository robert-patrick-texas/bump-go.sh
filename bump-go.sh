#!/usr/bin/env bash
set -euo pipefail

# bump-go.sh

# Written by Rob Patrick
# Last updated September 12, 2026
# This script is released to the public domain

# ============================================================
# Go toolchain bootstrap/update script
#
# Purpose:
#   - Ensure Go is installed under /usr/local/go
#   - If Go already exists, update it to the latest stable release
#   - Verify the downloaded archive against Go's published SHA-256
#     checksum before anything is installed
#
# Usage:
#   sudo ./bump-go.sh [OPTIONS]
#
#   Root privileges are required because installation targets
#   /usr/local/go. If not run as root, the script re-invokes the
#   privileged install/remove steps individually via sudo.
#
# Options:
#   --dry-run
#       Show what would be done without making changes.
#
#   --force-reinstall
#       Remove and reinstall the latest Go release even if the
#       currently installed version is already up to date.
#
#   -h, --help
#       Show usage information.
#
# Notes:
#   - Official Go install layout: https://go.dev/doc/install
#   - Upstream guidance is to remove any previous /usr/local/go
#     tree before extracting a new one, which is what this script
#     does for both the update and force-reinstall flows:
#       sudo rm -rf /usr/local/go
#       sudo tar -C /usr/local -xzf go<version>.<os>-<arch>.tar.gz
#   - Latest version is discovered via https://go.dev/VERSION?m=text
#   - Checksums are fetched from https://dl.google.com/go/<archive>.sha256
#   - PATH is exposed to all users via /etc/profile.d/go.sh so that
#     /usr/local/go/bin is available after a fresh login shell.
# ============================================================

# ------------------------------------------------------------
# Static configuration
# ------------------------------------------------------------
readonly GO_INSTALL_DIR="/usr/local/go"
readonly GO_VERSION_URL="https://go.dev/VERSION?m=text"
readonly GO_DOWNLOAD_BASE="https://dl.google.com/go"
readonly PROFILE_SNIPPET="/etc/profile.d/go.sh"

# ------------------------------------------------------------
# Runtime option flags
# ------------------------------------------------------------
DRY_RUN=false
FORCE_REINSTALL=false

# ------------------------------------------------------------
# Status tracking for summary output
# ------------------------------------------------------------
GO_STATUS=""
GO_OLD_VERSION=""
GO_NEW_VERSION=""

# ------------------------------------------------------------
# Working directory used for downloads; cleaned up on exit
# ------------------------------------------------------------
WORK_DIR=""

# ============================================================
# Logging functions
# ============================================================
# These functions provide consistent output formatting.
log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

# ============================================================
# Usage/help output
# ============================================================
# Prints supported command-line options.
usage() {
    cat <<'EOF'
Usage:
  sudo ./bump-go.sh [OPTIONS]

Options:
  --dry-run           Show actions without making changes
  --force-reinstall   Reinstall the latest Go release even if already current
  -h, --help          Show this help message
EOF
}

# ============================================================
# Command-line argument parsing
# ============================================================
# Parses script options before doing any work.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force-reinstall)
                FORCE_REINSTALL=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ============================================================
# Helper: command existence check
# ============================================================
# Returns success if a command exists on PATH.
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# Helper: command execution wrapper
# ============================================================
# In normal mode, execute the command.
# In dry-run mode, print the command and do not execute it.
run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

# ============================================================
# Helper: privileged command execution wrapper
# ============================================================
# Wraps run_cmd with sudo for steps that touch /usr/local/go or
# /etc/profile.d. Skips sudo entirely when already root, since
# re-sudoing as root is unnecessary and can fail in minimal
# containers without sudo installed.
run_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        run_cmd "$@"
    else
        run_cmd sudo "$@"
    fi
}

# ============================================================
# Cleanup handler
# ============================================================
# Removes the temporary download directory on any exit path.
cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# ============================================================
# Platform detection
# ============================================================
# Maps `uname` output to the os/arch naming Go uses for its
# release archives (e.g. linux-amd64, linux-arm64, darwin-arm64).
detect_platform() {
    local kernel machine

    kernel="$(uname -s)"
    machine="$(uname -m)"

    case "${kernel}" in
        Linux)  GO_OS="linux" ;;
        Darwin) GO_OS="darwin" ;;
        *)
            error "Unsupported operating system: ${kernel}"
            exit 1
            ;;
    esac

    case "${machine}" in
        x86_64|amd64)   GO_ARCH="amd64" ;;
        aarch64|arm64)  GO_ARCH="arm64" ;;
        armv6l)         GO_ARCH="armv6l" ;;
        i386|i686)      GO_ARCH="386" ;;
        *)
            error "Unsupported architecture: ${machine}"
            exit 1
            ;;
    esac

    log "Detected platform: ${GO_OS}/${GO_ARCH}"
}

# ============================================================
# Helper: fetch a URL to stdout
# ============================================================
# Prefers curl, falls back to wget. Used for both the version
# lookup and the checksum lookup, neither of which touch disk.
fetch_url() {
    local url="$1"

    if have_cmd curl; then
        curl -fsSL "${url}"
    elif have_cmd wget; then
        wget -qO- "${url}"
    else
        error "Neither curl nor wget is installed. Cannot reach ${url}."
        exit 1
    fi
}

# ============================================================
# Current version detection
# ============================================================
# Parses `go version` output (e.g. "go version go1.23.4 linux/amd64")
# down to a bare version string like "1.23.4". Empty if Go is not
# currently installed.
get_current_version() {
    if ! have_cmd go; then
        printf ''
        return 0
    fi

    go version | awk '{print $3}' | sed 's/^go//'
}

# ============================================================
# Latest version lookup
# ============================================================
# go.dev/VERSION?m=text returns the latest stable release as its
# first line, e.g. "go1.23.4", followed by a build timestamp line.
get_latest_version() {
    local raw

    raw="$(fetch_url "${GO_VERSION_URL}" | head -n1)"

    if [[ -z "${raw}" ]]; then
        error "Could not determine the latest Go version from ${GO_VERSION_URL}."
        exit 1
    fi

    printf '%s' "${raw#go}"
}

# ============================================================
# Version comparison
# ============================================================
# Returns success (0) if $1 and $2 are the same version.
# Relies on `sort -V` (version sort), available in GNU and BSD
# coreutils, to avoid hand-rolling numeric version parsing.
versions_equal() {
    [[ "$1" == "$2" ]]
}

# ============================================================
# Download and verify the release archive
# ============================================================
# Downloads the tarball for the given version/platform into
# WORK_DIR and checks it against the published SHA-256 sum before
# returning. Exits non-zero on any mismatch rather than risking
# an install from a corrupt or tampered archive.
download_and_verify() {
    local version="$1"
    local archive="go${version}.${GO_OS}-${GO_ARCH}.tar.gz"
    local archive_url="${GO_DOWNLOAD_BASE}/${archive}"
    local checksum_url="${archive_url}.sha256"
    local archive_path="${WORK_DIR}/${archive}"
    local expected_sha actual_sha

    # NOTE: this function's stdout is captured via command substitution
    # by its caller (archive_path="$(download_and_verify ...)"), so every
    # progress message below is redirected to stderr with `>&2`. Only the
    # final printf of archive_path may go to stdout.

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would download ${archive_url}" >&2
        log "[DRY-RUN] Would verify SHA-256 against ${checksum_url}" >&2
        printf '%s' "${archive_path}"
        return 0
    fi

    log "Downloading ${archive_url}..." >&2
    if have_cmd curl; then
        curl -fsSL -o "${archive_path}" "${archive_url}"
    else
        wget -qO "${archive_path}" "${archive_url}"
    fi

    log "Verifying checksum..." >&2
    expected_sha="$(fetch_url "${checksum_url}" | tr -d '[:space:]')"
    actual_sha="$(sha256sum "${archive_path}" | awk '{print $1}')"

    if [[ "${expected_sha}" != "${actual_sha}" ]]; then
        error "Checksum mismatch for ${archive}."
        error "  expected: ${expected_sha}"
        error "  actual:   ${actual_sha}"
        exit 1
    fi

    log "Checksum verified." >&2
    printf '%s' "${archive_path}"
}

# ============================================================
# Install (or reinstall) Go from a verified archive
# ============================================================
# Follows the upstream-documented update procedure: remove any
# existing /usr/local/go before extracting the new tree, so no
# files from an older release are left behind.
install_go() {
    local archive_path="$1"

    if [[ -d "${GO_INSTALL_DIR}" ]]; then
        log "Removing existing installation at ${GO_INSTALL_DIR}..."
        run_sudo rm -rf "${GO_INSTALL_DIR}"
    fi

    log "Extracting ${archive_path} to /usr/local..."
    run_sudo tar -C /usr/local -xzf "${archive_path}"
}

# ============================================================
# System-wide PATH setup
# ============================================================
# Drops a profile.d snippet so /usr/local/go/bin is on PATH for
# every login shell on the system, without editing any single
# user's dotfiles. Idempotent: skipped if already present.
ensure_path_snippet() {
    if [[ -f "${PROFILE_SNIPPET}" ]]; then
        log "PATH snippet already present at ${PROFILE_SNIPPET}."
        return 0
    fi

    log "Adding ${GO_INSTALL_DIR}/bin to PATH via ${PROFILE_SNIPPET}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would write ${PROFILE_SNIPPET}"
        return 0
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        printf 'export PATH=$PATH:%s/bin\n' "${GO_INSTALL_DIR}" > "${PROFILE_SNIPPET}"
    else
        printf 'export PATH=$PATH:%s/bin\n' "${GO_INSTALL_DIR}" | sudo tee "${PROFILE_SNIPPET}" >/dev/null
    fi
    run_sudo chmod 644 "${PROFILE_SNIPPET}"
}

# ============================================================
# Verification section
# ============================================================
# Confirms `go` is callable and reports its version after
# install/update. In dry-run mode this is informational only.
verify_go() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Dry-run mode: skipping post-install verification."
        return 0
    fi

    local go_bin="${GO_INSTALL_DIR}/bin/go"

    if [[ ! -x "${go_bin}" ]]; then
        error "Verification failed: ${go_bin} not found or not executable."
        exit 1
    fi

    local version_output
    version_output="$("${go_bin}" version)"
    log "Go verification OK: ${version_output}"
}

# ============================================================
# Go orchestration section
# ============================================================
# Decides whether to install, update, force-reinstall, or leave
# Go untouched, then drives the download/verify/install flow.
ensure_go() {
    local current_version latest_version archive_path

    current_version="$(get_current_version)"
    latest_version="$(get_latest_version)"

    GO_OLD_VERSION="${current_version:-none}"
    GO_NEW_VERSION="${latest_version}"

    log "Installed Go version: ${GO_OLD_VERSION}"
    log "Latest Go version:    ${latest_version}"

    if [[ -z "${current_version}" ]]; then
        log "Go not found. Installing Go ${latest_version}..."
        GO_STATUS="installed"
    elif [[ "${FORCE_REINSTALL}" == "true" ]]; then
        log "Force reinstall requested. Reinstalling Go ${latest_version}..."
        GO_STATUS="reinstalled"
    elif ! versions_equal "${current_version}" "${latest_version}"; then
        log "Newer Go release available. Updating ${current_version} -> ${latest_version}..."
        GO_STATUS="updated"
    else
        log "Go ${current_version} is already up to date."
        GO_STATUS="already-current"
        ensure_path_snippet
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        GO_STATUS="would-${GO_STATUS}"
    fi

    archive_path="$(download_and_verify "${latest_version}")"
    install_go "${archive_path}"
    ensure_path_snippet
}

# ============================================================
# Summary section
# ============================================================
# Prints a concise final status report.
print_summary() {
    printf '\n'
    printf '========== Summary ==========\n'
    printf 'Mode:      dry-run=%s, force-reinstall=%s\n' "${DRY_RUN}" "${FORCE_REINSTALL}"
    printf 'Go before: %s\n' "${GO_OLD_VERSION}"
    printf 'Go after:  %s\n' "${GO_NEW_VERSION}"
    printf 'Status:    %s\n' "${GO_STATUS:-unknown}"
    if [[ "${GO_STATUS}" != "already-current" ]]; then
        printf '\n'
        printf 'Start a new shell (or "source %s") to pick up PATH changes.\n' "${PROFILE_SNIPPET}"
    fi
    printf '=============================\n'
}

# ============================================================
# Main program flow
# ============================================================
# Execution order:
#   1. Parse options
#   2. Detect platform (os/arch)
#   3. Ensure Go is installed and current
#   4. Verify the installed binary
#   5. Print summary
main() {
    parse_args "$@"

    WORK_DIR="$(mktemp -d)"

    detect_platform
    ensure_go

    log "Verifying installed Go..."
    verify_go

    print_summary
}

main "$@"
