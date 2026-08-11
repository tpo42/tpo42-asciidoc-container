#!/bin/bash
# Test suite for adcw (sourced for unit testing)
set -e -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source adcw for access to internal functions
source "${REPO_ROOT}/bin/adcw"

test_help() {
    echo "Testing: --help shows usage..."
    adcw --help | grep -q "AsciiDoc Container Wrapper"
    echo "  PASS"
}

test_no_context_error() {
    echo "Testing: No context produces an actionable error..."
    unset ADC_PROJECT_HOME CONTAINER_TAG 2>/dev/null || true
    # A name no registry will ever carry, instead of relying on the ambient image being
    # absent: once bin/adcbw has run — which the adoc gate requires — the tag derived
    # from git *does* exist locally, and the assertion below would flip.
    local output
    output="$(CONTAINER_IMAGE=tpo42/adoc:test-nonexistent adcw validate 2>&1)" || true

    # Which error is correct depends on the machine, and both are. A developer box and
    # the Linux runner have a runtime but not that image; a GitHub macOS runner has no
    # runtime at all. Asserting only the first would make this suite unrunnable exactly
    # where it matters most — macOS is where /bin/bash is 3.2, and bash 4 constructs
    # survive `bash -n` there and only fail when the code actually runs.
    local expected="Container.*not found"
    if ! _adcw_detect_runner 2>/dev/null; then
        expected="Unable to locate a container runtime"
    fi
    echo "${output}" | grep -qE "${expected}"
    echo "  PASS"
}

test_compose_flag_takes_a_path() {
    echo "Testing: -f names a compose file, and says so when it cannot..."
    local output

    # The assertion this replaced was `grep -q "Usage:"` on an invocation without a
    # command — which the argument check answers before any compose code runs, so it
    # held even with every line of compose support deleted. These two reach the -f
    # branch itself.
    output="$(adcw -f /nowhere/compose.yml validate 2>&1)" || true
    [[ "${output}" == *"Compose file not found: /nowhere/compose.yml"* ]] || {
        echo "  FAIL: missing file not reported by name — got '${output}'"
        exit 1
    }

    output="$(adcw -f 2>&1)" || true
    [[ "${output}" == *"-f requires a path argument"* ]] || {
        echo "  FAIL: bare -f not reported — got '${output}'"
        exit 1
    }
    echo "  PASS"
}

test_compose_service_detection() {
    echo "Testing: Service auto-detection survives ordinary compose shapes..."
    local tmp
    tmp="$(mktemp -d)"

    # The shape that broke it: matching every bare `key:` line let the *last* one win,
    # so a service declaring volumes before its image answered "volumes". Nothing exotic
    # — key order inside a service is free, and half the compose files in the wild put
    # volumes first.
    printf 'name: t\nservices:\n  adoc:\n    volumes:\n      - .:/workspace\n    image: ghcr.io/tpo42/adoc:0\n' >"${tmp}/nested.yml"
    assert_equals "adoc" "$(_adcw_find_adoc_service "${tmp}/nested.yml")" "volumes before image"

    # Other top-level sections must not leak into the answer either, and a nested key
    # inside the service must not be mistaken for one.
    printf 'name: t\nvolumes:\n  cache:\nnetworks:\n  default:\nservices:\n  my-adoc:\n    networks:\n      - default\n    image: tpo42/adoc:latest\n' >"${tmp}/sections.yml"
    assert_equals "my-adoc" "$(_adcw_find_adoc_service "${tmp}/sections.yml")" "other sections first"

    # The service that matches is not necessarily the first one declared.
    printf 'name: t\nservices:\n  other:\n    image: nginx\n  adoc:\n    image: ghcr.io/tpo42/adoc:0\n' >"${tmp}/second.yml"
    assert_equals "adoc" "$(_adcw_find_adoc_service "${tmp}/second.yml")" "second service matches"

    # Compose allows the value to be quoted.
    printf 'name: t\nservices:\n  adoc:\n    image: "ghcr.io/tpo42/adoc:0"\n' >"${tmp}/quoted.yml"
    assert_equals "adoc" "$(_adcw_find_adoc_service "${tmp}/quoted.yml")" "quoted image"

    # And the fixture the rest of the suite uses, so the two cannot drift apart.
    assert_equals "adoc" "$(_adcw_find_adoc_service "${SCRIPT_DIR}/fixtures/compose-valid.yml")" "suite fixture"

    rm -rf "${tmp}"
    echo "  PASS"
}

assert_equals() {
    local expected="$1" actual="$2" what="$3"
    [[ "${expected}" == "${actual}" ]] && return 0
    echo "  FAIL: ${what} — expected '${expected}', got '${actual}'"
    exit 1
}

# Write a compose file naming this toolchain, one per requested filename.
_write_compose_fixtures() {
    local dir="$1" name
    shift
    for name in "$@"; do
        printf 'name: t\nservices:\n  adoc:\n    image: ghcr.io/tpo42/adoc:0\n' >"${dir}/${name}"
    done
}

test_compose_discovery_order() {
    echo "Testing: Compose discovery follows docker compose's own precedence..."
    local tmp
    tmp="$(mktemp -d)"
    _write_compose_fixtures "${tmp}" compose.yaml compose.yml docker-compose.yml docker-compose.yaml

    # Not symmetric, and that asymmetry is the point: compose.yaml beats compose.yml,
    # but docker-compose.yml beats docker-compose.yaml. Picking differently from what
    # `docker compose` picks, and then forcing it with -f, would only bite in a
    # repository carrying more than one of them.
    assert_equals "compose.yaml" "$(cd "${tmp}" && _adcw_detect_compose_path)" "all four present"
    rm -f "${tmp}/compose.yaml"
    assert_equals "compose.yml" "$(cd "${tmp}" && _adcw_detect_compose_path)" "spec .yml"
    rm -f "${tmp}/compose.yml"
    assert_equals "docker-compose.yml" "$(cd "${tmp}" && _adcw_detect_compose_path)" "legacy pair"
    rm -f "${tmp}/docker-compose.yml"
    assert_equals "docker-compose.yaml" "$(cd "${tmp}" && _adcw_detect_compose_path)" "legacy .yaml"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_discovery_ignores_foreign_file() {
    echo "Testing: A compose file without this toolchain is not ours..."
    local tmp
    tmp="$(mktemp -d)"
    printf 'name: t\nservices:\n  web:\n    image: nginx\n' >"${tmp}/compose.yaml"

    # Falling through to the dedicated container serves such a project better than
    # failing over a service that was never meant to be there.
    assert_equals "" "$(cd "${tmp}" && _adcw_detect_compose_path)" "foreign compose file"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_discovery_honours_service_override() {
    echo "Testing: ADOC_SERVICE turns the content check off..."
    local tmp found
    tmp="$(mktemp -d)"
    printf 'name: t\nservices:\n  mine:\n    image: example.org/custom-adoc:1\n' >"${tmp}/compose.yaml"

    # Naming a service is a statement that the caller knows what is in the file, so a
    # differently named image must not cost them compose mode.
    found="$(cd "${tmp}" && ADOC_SERVICE=mine _adcw_detect_compose_path)"
    assert_equals "compose.yaml" "${found}" "with ADOC_SERVICE set"

    rm -rf "${tmp}"
    echo "  PASS"
}

# --- Runtime selection by capability (ADR-009) ---
#
# Every case below builds its own PATH out of stub binaries, so the set of installed
# runtimes is exactly what the case declares — not what the machine happens to carry.
# That PATH holds *nothing else*: the code under test asks only bash builtins
# (`command -v`, `${bin##*/}`) plus the stubs themselves, so no external tool has to be
# reachable, and none can smuggle in a real docker.

# Create a fake runtime. ${3} == "compose" makes `<runtime> compose version` succeed;
# anything else makes the stub refuse every invocation, which is what a runtime without
# compose support looks like from the outside.
_write_runner_stub() {
    local dir="$1" name="$2" mode="${3:-nocompose}"
    {
        echo '#!/bin/bash'
        if [[ "${mode}" == "compose" ]]; then
            # Single quotes on purpose: $1 and $2 are the *stub's* arguments when it
            # runs, not this function's when it writes the file.
            # shellcheck disable=SC2016
            echo '[ "${1:-}" = compose ] && [ "${2:-}" = version ] && exit 0'
        fi
        echo 'exit 1'
    } >"${dir}/${name}"
    chmod +x "${dir}/${name}"
}

# Resolve a runtime for ${2} against the stubs in ${1} and print the binary chosen.
# ${3}, when given, pins _ADCW_CONTAINER_RUNNER_BIN. On failure the error message is
# printed instead, so one helper serves both the positive and the negative assertions.
#
# A subshell throughout: it keeps PATH and the resolved runtime out of the other tests,
# which the suite has been bitten by before.
_detect_runner_in() {
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

# Resolve a compose implementation against the stubs in ${1} and print it as one line.
#
# Selecting for `compose` is what fills _adcw_compose_cmd — the probe that decides
# whether a runtime can compose is the same code that knows how it is spelled, so there
# is no second call to make. Printing "${_adcw_compose_cmd[*]}" flattens the array for
# comparison; the array-ness itself is what test_compose_cmd_survives_a_spaced_path
# asserts, since that is the property a string round trip used to destroy.
_find_compose_cmd_in() {
    local dir="$1"
    (
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        _adcw_detect_runner compose 2>&1 || exit 1
        printf '%s' "${_adcw_compose_cmd[*]}"
    )
}

test_runner_run_takes_the_first_installed() {
    echo "Testing: 'run' is satisfied by the first installed runtime..."
    local tmp
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # Unchanged behaviour, and the counterpart to the compose case below: `container`
    # cannot compose but runs containers perfectly well, so for `run` it still wins.
    assert_equals "${tmp}/container" "$(_detect_runner_in "${tmp}" run)" "run picks first"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_runner_compose_skips_the_incapable() {
    echo "Testing: 'compose' skips a runtime that has none..."
    local tmp
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # The defect this replaced: compose mode landed on Apple's `container`, first in the
    # list and without compose in any form, while docker sat two entries further down.
    assert_equals "${tmp}/docker" "$(_detect_runner_in "${tmp}" compose)" "compose skips container"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_cmd_is_the_runtime_subcommand() {
    echo "Testing: A runtime carrying compose as a subcommand is used as such..."
    local tmp
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" nerdctl compose

    # `nerdctl compose` exists and is documented, so nerdctl and finch need no special
    # case — only the two standalone binaries below do.
    assert_equals "${tmp}/nerdctl compose" "$(_find_compose_cmd_in "${tmp}")" "subcommand form"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_cmd_apple_standalone_is_found() {
    echo "Testing: Apple's container gets container-compose, never docker..."
    local tmp
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" container-compose nocompose
    _write_runner_stub "${tmp}" docker compose

    # The route that matters on macOS 26 (CON-001): all three Apple compose routes keep
    # the image in Apple's own store, which is where a local `container build` put it.
    # Answering with `docker compose` here would step out of that store as well as out of
    # that engine. The plugin route needs nothing — it answers `container compose version`
    # and the generic probe already takes it — and socktainer presents as docker; the
    # standalone binary is the one that has to be named.
    assert_equals "container-compose" "$(_find_compose_cmd_in "${tmp}")" "apple standalone"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_cmd_stays_with_its_own_runtime() {
    echo "Testing: podman without 'podman compose' gets podman-compose, never docker..."
    local tmp
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" podman nocompose
    _write_runner_stub "${tmp}" podman-compose nocompose
    _write_runner_stub "${tmp}" docker compose

    # podman precedes docker, and podman *can* compose — through the standalone
    # implementation that belongs to it. Answering with `docker compose` here would talk
    # to a different engine holding different containers, so the service started under
    # podman would simply not be there.
    assert_equals "podman-compose" "$(_find_compose_cmd_in "${tmp}")" "standalone pairing"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_compose_cmd_survives_a_spaced_path() {
    echo "Testing: A runtime under a path with a space stays one argv word..."
    local tmp dir out count first
    tmp="$(mktemp -d)"
    dir="${tmp}/Docker Desktop/bin"
    mkdir -p "${dir}"
    _write_runner_stub "${dir}" docker compose

    # The regression the array replaced: the compose command was printed as a string and
    # split back with `read -a`, which splits on IFS and knows nothing about quoting. A
    # "Docker Desktop" directory — the realistic case, and the likely one on Windows —
    # became two argv words, so the invocation pointed at a path that does not exist.
    out="$(
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        _adcw_detect_runner compose >/dev/null 2>&1 || exit 1
        printf '%s\n%s\n' "${#_adcw_compose_cmd[@]}" "${_adcw_compose_cmd[0]}"
    )" || {
        echo "  FAIL: no compose implementation resolved"
        exit 1
    }

    count="$(echo "${out}" | sed -n 1p)"
    first="$(echo "${out}" | sed -n 2p)"

    assert_equals "2" "${count}" "argv is <runtime> compose, two words"
    assert_equals "${dir}/docker" "${first}" "the spaced path stays one word"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_runner_pinned_is_held_to_the_requirement() {
    echo "Testing: A pinned runtime must satisfy the requirement, no silent switch..."
    local tmp output
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # Naming a runtime is a statement about which engine holds the containers. When it
    # cannot do what the mode needs, that is an error to report -- quietly using docker
    # instead would answer a question nobody asked.
    output="$(_detect_runner_in "${tmp}" compose "${tmp}/container")" || true
    echo "${output}" | grep -q "_ADCW_CONTAINER_RUNNER_BIN" || {
        echo "  FAIL: error does not name the variable — got '${output}'"
        exit 1
    }
    if echo "${output}" | grep -q "docker"; then
        echo "  FAIL: switched to another runtime — got '${output}'"
        exit 1
    fi

    rm -rf "${tmp}"
    echo "  PASS"
}

test_runner_none_installed() {
    echo "Testing: No runtime at all is reported as such..."
    local tmp output
    tmp="$(mktemp -d)"

    output="$(_detect_runner_in "${tmp}" run)" || true
    echo "${output}" | grep -q "Unable to locate a container runtime" || {
        echo "  FAIL: unexpected error — got '${output}'"
        exit 1
    }

    # A runtime that runs but cannot compose is a different situation from having none,
    # and saying "no container runtime" there would send the reader hunting for an
    # installation they already have.
    _write_runner_stub "${tmp}" container nocompose
    output="$(_detect_runner_in "${tmp}" compose)" || true
    echo "${output}" | grep -q "No container runtime with compose support" || {
        echo "  FAIL: unexpected compose error — got '${output}'"
        exit 1
    }

    rm -rf "${tmp}"
    echo "  PASS"
}

test_runner_pinned_must_exist() {
    echo "Testing: A pinned runtime that is not installed is reported, not used..."
    local tmp output
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" docker compose

    # `run` is satisfied by being installed, and every candidate the loop sees came out of
    # `command -v`. A pinned runtime skips that walk, so nothing else establishes that the
    # name resolves — a typo would otherwise reach the runtime invocation itself, after
    # adcbw already announced which store it was filling.
    output="$(_detect_runner_in "${tmp}" run "${tmp}/not-installed")" || true
    echo "${output}" | grep -q "not executable" || {
        echo "  FAIL: a non-existent pinned runtime was accepted — got '${output}'"
        exit 1
    }
    echo "${output}" | grep -q "_ADCW_CONTAINER_RUNNER_BIN" || {
        echo "  FAIL: error does not name the variable — got '${output}'"
        exit 1
    }

    rm -rf "${tmp}"
    echo "  PASS"
}

test_runner_unknown_capability_is_the_callers_error() {
    echo "Testing: An unknown capability is reported once, not once per runtime..."
    local tmp output occurrences
    tmp="$(mktemp -d)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" podman nocompose
    _write_runner_stub "${tmp}" docker compose

    # Asking for something that does not exist is not a shortcoming of any runtime, so
    # trying the next one repeats the same wrong answer. The guard matters beyond tidiness:
    # ADR-009 rests the absence of a `build` capability on it failing loudly and correctly.
    output="$(_detect_runner_in "${tmp}" build)" || true
    occurrences="$(echo "${output}" | grep -c "Unknown runtime capability" || true)"
    if [[ "${occurrences}" != "1" ]]; then
        echo "  FAIL: expected the capability error once, got ${occurrences} — '${output}'"
        exit 1
    fi
    # The fallthrough would end in "no runtime found" on a machine carrying three.
    if echo "${output}" | grep -q "Unable to locate a container runtime"; then
        echo "  FAIL: reported as a missing runtime — got '${output}'"
        exit 1
    fi

    rm -rf "${tmp}"
    echo "  PASS"
}

# --- The build invocation (ADR-009, CON-001) ---

# A runtime stub that records the argv it was handed and then succeeds. Used where the
# question is *what* ADCW asks the runtime to do, rather than which runtime it picks.
_write_recording_stub() {
    local dir="$1" name="$2" log="$3"
    # Unquoted heredoc so the log path is substituted now; the stub's own $0 and $* are
    # escaped so they survive until it runs.
    cat >"${dir}/${name}" <<EOF
#!/bin/bash
printf '%s\n' "\$0 \$*" >>$(printf '%q' "${log}")
exit 0
EOF
    chmod +x "${dir}/${name}"
}

# Run bin/adcbw against the stubs in ${1}, logging to ${2}, and print the invocation it
# produced. ${3} pins _ADCW_CONTAINER_RUNNER_BIN when non-empty; anything after it is
# passed on to adcbw. All three are mandatory, so the caller reads as a sentence.
#
# CONTAINER_TAG short-circuits the git probe and ADC_PROJECT_HOME the realpath/dirname
# one, so the stub PATH really only has to carry the runtimes plus `id`.
_adcbw_invocation() {
    local dir="$1" log="$2" pinned="$3"
    shift 3
    : >"${log}"
    (
        PATH="${dir}"
        export ADC_PROJECT_HOME="${REPO_ROOT}" CONTAINER_TAG=stub
        # A prefix assignment rather than an export: adcbw is a separate process and this
        # is the only channel there is between it and adcw, which is the point being
        # tested. The unset matters too — an earlier case leaves the variable resolved in
        # this shell, and inheriting it would pin every run to the machine's real runtime.
        if [[ -n "${pinned}" ]]; then
            _ADCW_CONTAINER_RUNNER_BIN="${pinned}" "${REPO_ROOT}/bin/adcbw" "$@"
        else
            unset _ADCW_CONTAINER_RUNNER_BIN
            "${REPO_ROOT}/bin/adcbw" "$@"
        fi
    ) >/dev/null 2>&1
    cat "${log}"
}

_fail() {
    echo "  FAIL: $1"
    exit 1
}

# Run bin/adcbw against the stubs in ${1} and print "<exit code>|<combined output>".
# The invocation log is irrelevant here — these cases assert that the build never starts.
_adcbw_rejects() {
    local dir="$1"
    shift
    local out rc=0
    out="$(
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        # Prefix assignment rather than export, for the same reason _adcbw_invocation
        # uses one: adcbw is a separate process, and exporting inside this subshell is
        # what SC2030 warns about.
        ADOC_PROJECT_HOME="${REPO_ROOT}" ADOC_VERSION=stub \
            "${REPO_ROOT}/bin/adcbw" "$@" 2>&1
    )" || rc=$?
    printf '%s|%s' "${rc}" "${out}"
}

test_build_refuses_surplus_arguments() {
    echo "Testing: adcbw refuses what it cannot use rather than dropping it..."
    local tmp log result
    tmp="$(mktemp -d)"
    log="${tmp}/calls"
    _write_recording_stub "${tmp}" container "${log}"
    ln -s "$(command -v id)" "${tmp}/id"

    # Silently discarded before: the flag was consumed, the rest fell off the end, and
    # the build ran as if nobody had asked for anything else. `--no-cache` is the
    # realistic case — a docker flag someone expects to be passed through.
    : >"${log}"
    result="$(_adcbw_rejects "${tmp}" --with-mermaid --no-cache)"
    [[ "${result%%|*}" == "1" ]] || _fail "surplus after a flag exited ${result%%|*}, expected 1"
    [[ "${result#*|}" == *"Unexpected argument: --no-cache"* ]] ||
        _fail "message does not name the argument — got '${result#*|}'"
    [[ ! -s "${log}" ]] || _fail "the build ran anyway — $(cat "${log}")"

    # The pre-existing half of the guard, asserted rather than assumed: a mistyped flag
    # must not fall through to the default target.
    result="$(_adcbw_rejects "${tmp}" --with-mermade)"
    [[ "${result%%|*}" == "1" ]] || _fail "typo exited ${result%%|*}, expected 1"
    [[ "${result#*|}" == *"Unknown option: --with-mermade"* ]] ||
        _fail "typo message unexpected — got '${result#*|}'"
    [[ ! -s "${log}" ]] || _fail "the build ran on a typo — $(cat "${log}")"

    # And the two forms that must still work.
    result="$(_adcbw_rejects "${tmp}" --help)"
    [[ "${result%%|*}" == "0" ]] || _fail "--help exited ${result%%|*}, expected 0"
    : >"${log}"
    result="$(_adcbw_rejects "${tmp}")"
    [[ "${result%%|*}" == "0" ]] || _fail "no arguments exited ${result%%|*}, expected 0"
    [[ -s "${log}" ]] || _fail "the plain build did not run"

    rm -rf "${tmp}"
    echo "  PASS"
}

test_build_uses_the_portable_verb() {
    echo "Testing: adcbw builds with the portable verb, on the runtime 'run' resolves..."
    local tmp log invocation
    tmp="$(mktemp -d)"
    log="${tmp}/calls"

    _write_recording_stub "${tmp}" container "${log}"
    _write_recording_stub "${tmp}" docker "${log}"
    # The one thing adcbw needs off PATH besides a runtime: it asks who is building.
    ln -s "$(command -v id)" "${tmp}/id"

    invocation="$(_adcbw_invocation "${tmp}" "${log}" "")"

    # `buildx` is docker's own spelling; four of the five runtimes have never heard of it,
    # so the bare verb is the whole of the portable surface (CON-001, "Build").
    case "${invocation}" in
    "${tmp}/container build "*) ;;
    *) _fail "expected '<runtime> build …' — got '${invocation}'" ;;
    esac
    if [[ "${invocation}" == *buildx* ]]; then
        _fail "buildx survived — got '${invocation}'"
    fi

    # The build has to land in the same engine's store the run reads out of, so adcbw must
    # resolve exactly what `run` resolves — docker is installed here and must stay unused.
    assert_equals "${tmp}/container" "$(_detect_runner_in "${tmp}" run)" "run resolves container"
    if [[ "${invocation}" == *"${tmp}/docker"* ]]; then
        _fail "build crossed to another engine — got '${invocation}'"
    fi

    # --target is load-bearing: the Containerfile has two stages and the default is the
    # last one, so losing the flag silently builds the browser-carrying variant.
    if [[ "${invocation}" != *"--target=adoc "* ]]; then
        _fail "--target=adoc missing — got '${invocation}'"
    fi

    invocation="$(_adcbw_invocation "${tmp}" "${log}" "" --with-mermaid)"
    if [[ "${invocation}" != *"--target=adoc-with-mermaid "* ]]; then
        _fail "--with-mermaid did not reach --target — got '${invocation}'"
    fi

    rm -rf "${tmp}"
    echo "  PASS"
}

test_build_honours_the_pinned_engine() {
    echo "Testing: A pinned runtime decides which store the build lands in..."
    local tmp log invocation
    tmp="$(mktemp -d)"
    log="${tmp}/calls"

    _write_recording_stub "${tmp}" container "${log}"
    _write_recording_stub "${tmp}" docker "${log}"
    ln -s "$(command -v id)" "${tmp}/id"

    # Nothing carries the resolved runtime from adcbw to adcw — they are two processes.
    # Exporting the variable is what pins both to one engine, and it only works if adcbw
    # honours it, which is the whole of this assertion.
    invocation="$(_adcbw_invocation "${tmp}" "${log}" "${tmp}/docker")"
    case "${invocation}" in
    "${tmp}/docker build "*) ;;
    *) _fail "pinned runtime ignored — got '${invocation}'" ;;
    esac

    rm -rf "${tmp}"
    echo "  PASS"
}

# Run all tests
echo "=== ADCW Tests ==="
test_help
test_no_context_error
test_compose_flag_takes_a_path
test_compose_service_detection
test_compose_discovery_order
test_compose_discovery_ignores_foreign_file
test_compose_discovery_honours_service_override
test_runner_run_takes_the_first_installed
test_runner_compose_skips_the_incapable
test_compose_cmd_is_the_runtime_subcommand
test_compose_cmd_apple_standalone_is_found
test_compose_cmd_stays_with_its_own_runtime
test_compose_cmd_survives_a_spaced_path
test_runner_pinned_is_held_to_the_requirement
test_runner_none_installed
test_runner_pinned_must_exist
test_runner_unknown_capability_is_the_callers_error
test_build_refuses_surplus_arguments
test_build_uses_the_portable_verb
test_build_honours_the_pinned_engine
echo "=== All tests passed ==="
