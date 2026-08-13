# Fake container runtimes on a reduced PATH — the machinery behind ADR-009's unit cases.
#
# Every case that selects a runtime builds its own PATH out of these, so the set of
# installed runtimes is exactly what the case declares, not what the machine carries.
# That PATH holds nothing else: the code under test asks only bash builtins
# (`command -v`, `${bin##*/}`) plus the stubs themselves, so no external tool has to be
# reachable and none can smuggle in a real docker.
#
#   nocompose  refuses every invocation, which is what a runtime without compose support
#              looks like from the outside
#   compose    answers `<runtime> compose version`
#   recording  appends the argv it was handed to ${ADCW_TEST_LOG} and succeeds, for the
#              cases asking *what* ADCW tells the runtime to do rather than which one it
#              picks

# One set per bats run, not per file: on macOS the first exec of a newly created file
# pays a first-run policy evaluation of roughly 0.3 s, per inode. Two suites need these
# stubs, and writing them twice would pay that twice for nothing — a link to an inode
# that has already run costs nothing, which is what the warming execs below buy.
_runtime_stubs_root() { printf '%s' "${BATS_RUN_TMPDIR}/adcw-runtime-stubs"; }

# Call from setup_file. Idempotent across suites, and safe when bats runs files
# concurrently: mkdir is atomic, so exactly one caller populates the directory while any
# other waits for the marker rather than writing into it half-built.
runtime_stubs_init() {
    local root
    root="$(_runtime_stubs_root)"

    if mkdir "${root}" 2>/dev/null; then
        printf '#!/bin/bash\nexit 1\n' >"${root}/nocompose"
        # Single quotes on purpose throughout: the parameters belong to the stub when it
        # runs, not to this file when it writes it.
        # shellcheck disable=SC2016
        printf '#!/bin/bash\n%s\nexit 1\n' \
            '[ "${1:-}" = compose ] && [ "${2:-}" = version ] && exit 0' >"${root}/compose"
        # shellcheck disable=SC2016
        printf '#!/bin/bash\n%s\nexit 0\n' \
            'printf "%s\n" "$0 $*" >>"${ADCW_TEST_LOG}"' >"${root}/recording"
        chmod +x "${root}/nocompose" "${root}/compose" "${root}/recording"

        ADCW_TEST_LOG=/dev/null "${root}/nocompose" || true
        ADCW_TEST_LOG=/dev/null "${root}/compose" || true
        ADCW_TEST_LOG=/dev/null "${root}/recording" || true

        touch "${root}/.ready"
        return 0
    fi

    local waited=0
    while [[ ! -e "${root}/.ready" ]]; do
        sleep 0.05
        waited=$((waited + 1))
        if [[ ${waited} -gt 200 ]]; then
            echo "runtime stub directory never became ready: ${root}" >&2
            return 1
        fi
    done
}

# Install a fake runtime named ${2} into ${1}. ${3} selects the stub body. A link, so the
# name the code under test resolves is the link's own — `command -v` and `${bin##*/}`
# both read it.
stub_runtime() {
    ln -s "$(_runtime_stubs_root)/${3:-nocompose}" "$1/$2"
}

# Resolve a runtime for ${2} against the stubs in ${1} and print the binary chosen.
# ${3}, when given, pins _ADCW_CONTAINER_RUNNER_BIN. On failure the error message is
# printed instead, so one helper serves both the positive and the negative assertions.
#
# A subshell throughout: PATH and the resolved runtime stay out of the rest of the case,
# which asks for several resolutions in a row.
detect_runner_in() {
    local dir="$1" capability="$2" pinned="${3:-}"
    (
        PATH="${dir}"
        if [[ -n "${pinned}" ]]; then
            _ADCW_CONTAINER_RUNNER_BIN="${pinned}"
        else
            unset _ADCW_CONTAINER_RUNNER_BIN
        fi
        _adcw_detect_runner "${capability}" 2>&1 || exit 1
        printf '%s' "${_ADCW_CONTAINER_RUNNER_BIN}"
    )
}
