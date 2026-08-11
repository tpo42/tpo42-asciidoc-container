#!/bin/bash
# ADCW Common — shared infrastructure for bin/adcw and bin/adcbw
#
# Environment variables (all optional):
#   ADOC_VERSION      — Toolchain version to use (default: the released version)
#   ADOC_REGISTRY     — Registry and namespace to pull from (default: ghcr.io/tpo42)
#   ADOC_IMAGE        — Full image reference, overriding registry/name/version together
#   ADOC_PROJECT_HOME — Path to tpo42-asciidoc-container checkout (contributor)

_ADCW_MISSING_RUNNER="Unable to locate a container runtime installation on this system.

Please install it preferably using your distribution's package
management system.

Example (Debian and derivatives, such as Ubuntu):

    # apt install podman

Example (Fedora, RHEL, etc.):

    # dnf install podman

Example (macOS 26 on Apple silicon):

    # Apple's \`container\` is not preinstalled — macOS ships the
    # frameworks it builds on, not the tool. Install it from
    # https://github.com/apple/container/releases, then run:
    #     container system start

Docker also provides pre-built binary packages in various formats at:
https://docs.docker.com/engine/install/#server.

Alternative container runtimes (compose support differs — see CON-001):
- podman:    daemonless container engine; compose needs podman-compose
             or docker-compose installed alongside it
- nerdctl:   containerd-native CLI; compose built in
- finch:     containerd, nerdctl and BuildKit bundled; compose built in
- container: Apple's native framework (macOS 26, Apple silicon);
             carries no compose of its own
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

# Container runtimes in order of preference: lightweight and daemonless first, docker
# last. Data rather than a chain of fallbacks — a list can be walked while asking each
# entry a question, an `||` chain can only take the first thing that exists. See ADR-009.
_ADCW_CONTAINER_RUNNERS=(container nerdctl finch podman docker)

# The standalone compose implementation belonging to each runtime, for the runtimes that
# have one. Apple's `container` is in here for the store reason (CON-001): of its three
# third-party routes only this one needs naming, since the plugin answers
# `<runtime> compose version` and socktainer presents as `docker` with a context.
_ADCW_STANDALONE_COMPOSE=(
    "container:container-compose"
    "docker:docker-compose"
    "podman:podman-compose"
)

# Set _adcw_compose_cmd to the compose invocation belonging to exactly this runtime,
# or fail leaving it empty.
#
# Compose follows the runtime, it does not pick its own. `docker compose` against a
# podman setup is not a different spelling of the same thing — it is a different engine
# holding different containers. Modern runtimes carry compose as a subcommand; the
# standalone binaries each belong to one runtime and must not be crossed over.
#
# An array rather than a printed string. The caller needs argv, and a string has to be
# split to get there — `read -a` splits on IFS, which knows nothing about quoting, so a
# runtime under a path containing a space (a "Docker Desktop" directory is the realistic
# case, and Windows makes it likely) became two argv words. Setting the array here means
# the two words of `<runtime> compose` never become text in the first place.
#
# ${bin##*/} rather than basename: this runs inside the capability probe of every
# candidate runtime, and a builtin expansion asks nothing of PATH.
_adcw_compose_cmd=()
_adcw_runner_compose_cmd() {
    local bin="$1"
    _adcw_compose_cmd=()

    if "${bin}" compose version >/dev/null 2>&1; then
        _adcw_compose_cmd=("${bin}" compose)
        return 0
    fi

    local entry
    for entry in "${_ADCW_STANDALONE_COMPOSE[@]}"; do
        [[ "${bin##*/}" == "${entry%%:*}" ]] || continue
        if command -v "${entry#*:}" >/dev/null 2>&1; then
            _adcw_compose_cmd=("${entry#*:}")
            return 0
        fi
    done

    return 1
}

# True when the runtime ${1} can do what ${2} asks of it.
#
# There is no `build` capability, and its absence is a decision rather than an omission.
# A build lands in the engine's *local* image store and the later run reads out of it, so
# the two are one transaction against one engine (CON-001, "Image stores and transport").
# Letting a build-specific criterion pick a different runtime than `run` picks would
# produce exactly the failure that criterion was meant to avoid — an image nobody can
# find, or a stale one from the other store. `bin/adcbw` therefore asks for `run`.
# See ADR-009.
#
# Three outcomes, not two: 0 can, 1 cannot, 2 the capability itself is unknown. The third
# is not a property of the runtime and must not be answered by trying the next one — a
# caller asking for something that does not exist gets the same wrong answer from every
# entry in the list. Keeping the distinction here rather than validating the name in the
# caller keeps the set of known capabilities in exactly one place.
_adcw_runner_has_capability() {
    local bin="$1" capability="$2"

    case "${capability}" in
    run)
        # Every runtime in the list runs containers; being installed is the whole test.
        return 0
        ;;
    compose)
        _adcw_runner_compose_cmd "${bin}" >/dev/null 2>&1
        ;;
    *)
        _adcw_exit_error "Unknown runtime capability: ${capability}"
        return 2
        ;;
    esac
}

# Detect a container runtime → _ADCW_CONTAINER_RUNNER_BIN
#
# The capability the caller needs drives the search: `run` (the default) is satisfied by
# any installed runtime, `compose` only by one that carries a compose implementation of
# its own. Selecting before asking is what let compose mode land on Apple's `container`,
# which has no compose at all, while docker sat two entries further down the list.
#
# A pre-set _ADCW_CONTAINER_RUNNER_BIN turns the capability from a criterion into a
# requirement: naming a runtime is a statement about which engine holds the containers
# and the images, so a shortfall is reported rather than silently answered with a
# different engine. Exported, it is also how `bin/adcbw` and `bin/adcw` are pinned to one
# engine across the two processes when the ambient selection cannot be trusted to be
# reproducible.
#
# Nothing here is remembered between processes, and it does not need to be: the same list
# walked with the same criterion against the same PATH yields the same runtime, which is
# what keeps a build and the run that follows it in one image store.
_adcw_detect_runner() {
    local capability="${1:-run}" rc=0

    if [[ -n "${_ADCW_CONTAINER_RUNNER_BIN:-}" ]]; then
        # Existence is checked here and nowhere else. Walking the list, every candidate
        # came out of `command -v` and is installed by construction — which is why `run`
        # can treat being installed as the whole test. A pinned runtime skips that walk,
        # so on this path nothing has established that the name resolves to anything. A
        # typo would otherwise reach the first real invocation and surface as the
        # runtime's own "No such file or directory", after adcbw has already announced
        # which store it was going to fill.
        if ! command -v "${_ADCW_CONTAINER_RUNNER_BIN}" >/dev/null 2>&1; then
            _adcw_exit_error "_ADCW_CONTAINER_RUNNER_BIN is set to '${_ADCW_CONTAINER_RUNNER_BIN}', which is not executable.
Unset it to select a runtime automatically, or point it at an installed one."
            return 1
        fi

        _adcw_runner_has_capability "${_ADCW_CONTAINER_RUNNER_BIN}" "${capability}" || rc=$?
        if ((rc == 0)); then
            return 0
        fi
        if ((rc == 2)); then
            return 1
        fi
        _adcw_exit_error "${_ADCW_CONTAINER_RUNNER_BIN##*/} has no ${capability} support installed.
Unset or change _ADCW_CONTAINER_RUNNER_BIN to use a different runtime."
        return 1
    fi

    local candidate bin
    for candidate in "${_ADCW_CONTAINER_RUNNERS[@]}"; do
        bin="$(command -v "${candidate}")" || continue
        rc=0
        _adcw_runner_has_capability "${bin}" "${capability}" || rc=$?
        if ((rc == 0)); then
            _ADCW_CONTAINER_RUNNER_BIN="${bin}"
            return 0
        fi
        # An unknown capability is the caller's error, not this candidate's shortcoming.
        # Reported once by the probe; asking the remaining runtimes would repeat it and
        # then end in "no runtime found" on a machine that has several.
        if ((rc == 2)); then
            return 1
        fi
    done

    case "${capability}" in
    compose)
        _adcw_exit_error "No container runtime with compose support found.
Tried ${_ADCW_CONTAINER_RUNNERS[*]} as '<runtime> compose', plus the
standalone container-compose, docker-compose and podman-compose."
        ;;
    *)
        _adcw_exit_error "${_ADCW_MISSING_RUNNER}"
        ;;
    esac
    return 1
}

# The toolchain version this wrapper asks for. The release workflow replaces the value
# below when it builds the distributed script, so an installed adcw names the version it
# was shipped with instead of deriving one.
_ADCW_RELEASE_VERSION=""

# Where images are pulled from. Overridable so that a consumer can mirror the image into
# their own registry, or publish a derived one beside it, without editing the wrapper.
: "${ADOC_REGISTRY:=ghcr.io/tpo42}"

# Resolve ADOC_VERSION: explicit env → release constant → git describe → "latest"
#
# git describe is the contributor's answer, not the consumer's: it produces the branch
# slug of whatever checkout ADOC_PROJECT_HOME points at, which is meaningful only while
# building from that checkout.
_adcw_detect_version() {
    [[ -n "${ADOC_VERSION:-}" ]] && return 0

    if [[ -n "${_ADCW_RELEASE_VERSION}" ]]; then
        ADOC_VERSION="${_ADCW_RELEASE_VERSION}"
        return 0
    fi

    if [[ -n "${ADOC_PROJECT_HOME:-}" ]] && [[ -d "${ADOC_PROJECT_HOME}/.git" ]]; then
        local git_bin
        git_bin="$(command -v git)" || true
        if [[ -n "${git_bin}" ]]; then
            ADOC_VERSION="$("${git_bin}" -C "${ADOC_PROJECT_HOME}" \
                describe --all --always --dirty 2>/dev/null |
                sed -e 's,^heads/,,g' -e 's,^tags/,,g' -e 's,^main$,latest,g' | tr / -)" || true
        fi
    fi

    : "${ADOC_VERSION:=latest}"
}

# Resolve ADOC_IMAGE from registry, name and version, unless the caller named one.
#
# ${1} is the image name without registry ("adoc", "adoc-with-mermaid"). An empty
# ADOC_REGISTRY yields a bare local name, which is what a purely local build wants.
_adcw_resolve_image() {
    local name="$1"
    [[ -n "${ADOC_IMAGE:-}" ]] && return 0

    _adcw_detect_version || return 1
    ADOC_IMAGE="${ADOC_REGISTRY:+${ADOC_REGISTRY}/}${name}:${ADOC_VERSION}"
}
