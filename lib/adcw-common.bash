#!/bin/bash
# ADCW Common — shared infrastructure for bin/adcw and bin/adcbw
#
# Environment variables (all optional):
#   ADC_PROJECT_HOME  — Path to tpo42-asciidoc-container checkout (contributor)
#   CONTAINER_TAG     — Explicit override for container tag

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

# Print the compose command belonging to exactly this runtime, or fail.
#
# Compose follows the runtime, it does not pick its own. `docker compose` against a
# podman setup is not a different spelling of the same thing — it is a different engine
# holding different containers. Modern runtimes carry compose as a subcommand; the
# standalone binaries each belong to one runtime and must not be crossed over.
#
# ${bin##*/} rather than basename: this runs inside the capability probe of every
# candidate runtime, and a builtin expansion asks nothing of PATH.
_adcw_runner_compose_cmd() {
    local bin="$1"

    if "${bin}" compose version >/dev/null 2>&1; then
        printf '%s compose' "${bin}"
        return 0
    fi

    case "${bin##*/}" in
    container)
        # Apple's `container` carries no compose of its own. Of the three third-party
        # routes (CON-001) two need nothing here: the plugin answers
        # `container compose version` above, and socktainer presents as `docker` with a
        # context. Only the standalone binary needs naming — exactly parallel to the two
        # below, and the reason it is worth naming is that all three keep the image in
        # Apple's store, which is where a local build put it.
        if command -v container-compose >/dev/null 2>&1; then
            printf 'container-compose'
            return 0
        fi
        ;;
    docker)
        if command -v docker-compose >/dev/null 2>&1; then
            printf 'docker-compose'
            return 0
        fi
        ;;
    podman)
        if command -v podman-compose >/dev/null 2>&1; then
            printf 'podman-compose'
            return 0
        fi
        ;;
    esac

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

# Resolve container tag: explicit env → git describe → "latest"
_adcw_detect_tag() {
    [[ -n "${CONTAINER_TAG:-}" ]] && return 0

    if [[ -n "${ADC_PROJECT_HOME:-}" ]] && [[ -d "${ADC_PROJECT_HOME}/.git" ]]; then
        local git_bin
        git_bin="$(command -v git)" || true
        if [[ -n "${git_bin}" ]]; then
            CONTAINER_TAG="$("${git_bin}" -C "${ADC_PROJECT_HOME}" \
                describe --all --always --dirty 2>/dev/null |
                sed -e 's,^heads/,,g' -e 's,^main$,latest,g' | tr / -)" || true
        fi
    fi

    : "${CONTAINER_TAG:=latest}"
}
