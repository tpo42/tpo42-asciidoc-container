#!/bin/bash
# ADCW Common — shared infrastructure for bin/adcw and bin/adcbw
#
# Environment variables (all optional):
#   ADC_PROJECT_HOME  — Path to tpo42-asciidoc-container checkout (contributor)
#   ADCW_LOCATION     — Directory containing installed adcw (e.g. ${HOMEBREW_PREFIX}/bin)
#   CONTAINER_TAG     — Explicit override for container tag

_ADCW_MISSING_RUNNER="Unable to locate a container runtime installation on this system.

Please install it preferably using your distribution's package
management system.

Example (Debian and derivatives, such as Ubuntu):

    # apt install podman

Example (Fedora, RHEL, etc.):

    # dnf install podman

Example (macOS 26+ with native container support):

    # Already included in macOS 26 \"Tahoe\"

Docker also provides pre-built binary packages in various formats at:
https://docs.docker.com/engine/install/#server.

Alternative container runtimes:
- nerdctl: containerd-native CLI
- podman: daemonless container engine
- container: Apple's native framework (macOS 26+)
"

_ADCW_MISSING_GIT="Unable to locate a Git installation on this system.

Please install it preferably using your distribution's package
management system.

Example (Debian and derivatives, such as Ubuntu):

    # apt install git

Example (Fedora, RHEL, etc.):

    # dnf install git
"

_adcw_exit_error() {
    echo "Error: $1" >&2
    return 1
}

# Detect container runtime → _ADCW_CONTAINER_RUNNER_BIN
_adcw_detect_runner() {
    [[ -n "${_ADCW_CONTAINER_RUNNER_BIN:-}" ]] && return 0
    _ADCW_CONTAINER_RUNNER_BIN="$(command -v container)" ||
    _ADCW_CONTAINER_RUNNER_BIN="$(command -v nerdctl)" ||
    _ADCW_CONTAINER_RUNNER_BIN="$(command -v finch)" ||
    _ADCW_CONTAINER_RUNNER_BIN="$(command -v podman)" ||
    _ADCW_CONTAINER_RUNNER_BIN="$(command -v docker)" ||
        _adcw_exit_error "${_ADCW_MISSING_RUNNER}"
}

# Resolve container tag: explicit env → git describe → "latest"
_adcw_detect_tag() {
    [[ -n "${CONTAINER_TAG:-}" ]] && return 0

    if [[ -n "${ADC_PROJECT_HOME:-}" ]] && [[ -d "${ADC_PROJECT_HOME}/.git" ]]; then
        local git_bin
        git_bin="$(command -v git)" || true
        if [[ -n "${git_bin}" ]]; then
            CONTAINER_TAG="$("${git_bin}" -C "${ADC_PROJECT_HOME}" \
                describe --all --always --dirty 2>/dev/null \
                | sed -e 's,^heads/,,g' -e 's,^main$,latest,g' | tr / -)" || true
        fi
    fi

    : "${CONTAINER_TAG:=latest}"
}
