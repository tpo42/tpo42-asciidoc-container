#!/bin/bash
# Test suite for adcw (sourced for unit testing)
set -e -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source adcw for access to internal functions
source "${REPO_ROOT}/bin/adcw"

# One scratch root for the whole run, taken away by a trap. The per-test `rm -rf` this
# replaced was dead on the one path where it mattered — the assertions exit on failure,
# so every failing run leaked its directory.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
_scratch() { mktemp -d "${TMPROOT}/XXXXXX"; }

_fail() {
    echo "  FAIL: $1"
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2" what="$3"
    [[ "${expected}" == "${actual}" ]] ||
        _fail "${what} — expected '${expected}', got '${actual}'"
}

# The two shapes the cases below kept hand-rolling: a captured block that must, or must
# not, carry something. Named so every failure in this suite reads alike — the inline
# copies each invented their own wording and printed the subject differently.
assert_matches() {
    local subject="$1" pattern="$2" what="$3"
    echo "${subject}" | grep -qE "${pattern}" || _fail "${what} — got '${subject}'"
}

refute_matches() {
    local subject="$1" pattern="$2" what="$3"
    echo "${subject}" | grep -qE "${pattern}" && _fail "${what} — got '${subject}'"
    return 0
}

assert_contains() {
    local subject="$1" needle="$2" what="$3"
    [[ "${subject}" == *"${needle}"* ]] || _fail "${what} — got '${subject}'"
}

refute_contains() {
    local subject="$1" needle="$2" what="$3"
    [[ "${subject}" != *"${needle}"* ]] || _fail "${what} — got '${subject}'"
}

test_help() {
    echo "Testing: --help shows usage..."
    adcw --help | grep -q "AsciiDoc Container Wrapper"
    echo "  PASS"
}

test_no_context_error() {
    echo "Testing: No context produces an actionable error..."
    unset ADOC_PROJECT_HOME ADOC_VERSION
    # A name no registry will ever carry, instead of relying on the ambient image being
    # absent: once bin/adcbw has run — which the adoc gate requires — the tag derived
    # from git *does* exist locally, and the assertion below would flip.
    local output
    output="$(ADOC_IMAGE=tpo42/adoc:test-nonexistent adcw validate 2>&1)" || true

    # Which error is correct depends on the machine, and both are. A developer box and
    # the Linux runner have a runtime but not that image; a GitHub macOS runner has no
    # runtime at all. Asserting only the first would make this suite unrunnable exactly
    # where it matters most — macOS is where /bin/bash is 3.2, and bash 4 constructs
    # survive `bash -n` there and only fail when the code actually runs.
    local expected="Container.*not found"
    if ! _adcw_detect_runner 2>/dev/null; then
        expected="Unable to locate a container runtime"
    fi
    assert_matches "${output}" "${expected}" "no actionable error"
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
    assert_contains "${output}" "Compose file not found: /nowhere/compose.yml" \
        "missing file not reported by name"

    output="$(adcw -f 2>&1)" || true
    assert_contains "${output}" "-f requires a path argument" "bare -f not reported"
    echo "  PASS"
}

test_compose_service_detection() {
    echo "Testing: Service auto-detection survives ordinary compose shapes..."
    local tmp
    tmp="$(_scratch)"

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

    echo "  PASS"
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
    tmp="$(_scratch)"
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

    echo "  PASS"
}

test_compose_discovery_ignores_foreign_file() {
    echo "Testing: A compose file without this toolchain is not ours..."
    local tmp
    tmp="$(_scratch)"
    printf 'name: t\nservices:\n  web:\n    image: nginx\n' >"${tmp}/compose.yaml"

    # Falling through to the dedicated container serves such a project better than
    # failing over a service that was never meant to be there.
    assert_equals "" "$(cd "${tmp}" && _adcw_detect_compose_path)" "foreign compose file"

    echo "  PASS"
}

test_compose_discovery_honours_service_override() {
    echo "Testing: ADOC_SERVICE turns the content check off..."
    local tmp found
    tmp="$(_scratch)"
    printf 'name: t\nservices:\n  mine:\n    image: example.org/custom-adoc:1\n' >"${tmp}/compose.yaml"

    # Naming a service is a statement that the caller knows what is in the file, so a
    # differently named image must not cost them compose mode.
    found="$(cd "${tmp}" && ADOC_SERVICE=mine _adcw_detect_compose_path)"
    assert_equals "compose.yaml" "${found}" "with ADOC_SERVICE set"

    echo "  PASS"
}

# --- Image resolution (ADOC_VERSION / ADOC_REGISTRY / ADOC_IMAGE) ---

# Resolve in a *freshly sourced* library, because the registry default is applied once
# at source time (`: "${ADOC_REGISTRY=…}"`). Re-using this suite's already-sourced copy
# would test the environment it happened to start in, not the resolution.
#
# ${1} is the image name; everything after it is VAR=value for the child's environment.
_resolve_image_fresh() {
    local name="$1"
    shift
    # Single quotes on purpose: $1, $2 and ADOC_IMAGE belong to the child bash, which
    # is the process that sources the library under the controlled environment.
    # shellcheck disable=SC2016
    env -u ADOC_IMAGE -u ADOC_VERSION -u ADOC_REGISTRY -u ADOC_PROJECT_HOME "$@" \
        bash -c 'set -u; . "$1"; _adcw_resolve_image "$2"; printf "%s" "${ADOC_IMAGE}"' \
        bash "${REPO_ROOT}/lib/adcw-common.bash" "${name}"
}

test_image_resolution() {
    echo "Testing: version, registry and image reference resolve as documented..."

    assert_equals "ghcr.io/tpo42/adoc:1.2.3" \
        "$(_resolve_image_fresh adoc ADOC_VERSION=1.2.3)" "default registry"

    assert_equals "ghcr.io/tpo42/adoc-with-mermaid:1.2.3" \
        "$(_resolve_image_fresh adoc-with-mermaid ADOC_VERSION=1.2.3)" "variant name"

    # A mirror, or a house image beside the upstream one — the reason ADOC_REGISTRY
    # exists at all (UC-004).
    assert_equals "my.registry.internal/team/adoc:1.2.3" \
        "$(_resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.registry.internal/team)" \
        "own registry"

    # Explicitly empty means a bare local name, and it has to survive: the default was
    # once assigned with `:=`, which fires on empty as well as unset, so this could not
    # be expressed at all. CI names its test images this way.
    assert_equals "adoc:ci-abc123" \
        "$(_resolve_image_fresh adoc ADOC_VERSION=ci-abc123 ADOC_REGISTRY=)" \
        "empty registry yields a bare name"

    # The full override wins over both of the above.
    assert_equals "example.org/other/thing:9" \
        "$(_resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.reg ADOC_IMAGE=example.org/other/thing:9)" \
        "ADOC_IMAGE overrides"

    # No version anywhere, and no checkout to derive one from.
    assert_equals "ghcr.io/tpo42/adoc:latest" \
        "$(_resolve_image_fresh adoc)" "fallback when nothing is set"

    echo "  PASS"
}

# --- Runtime selection by capability (ADR-009) ---
#
# Every case below builds its own PATH out of stub binaries, so the set of installed
# runtimes is exactly what the case declares — not what the machine happens to carry.
# That PATH holds *nothing else*: the code under test asks only bash builtins
# (`command -v`, `${bin##*/}`) plus the stubs themselves, so no external tool has to be
# reachable, and none can smuggle in a real docker.

# Each distinct stub body is written once, here, and every case links to it under
# whatever runtime name it needs — the code under test asks `command -v` and
# `${bin##*/}`, both of which read the link's own name.
#
# Written once rather than per case because on macOS the *first* exec of a newly created
# file pays a first-run policy evaluation of roughly 0.3 s, per inode. Writing a fresh
# stub in every case cost this suite — the pre-commit gate — more wall clock than
# everything it asserts put together; a link to an inode that has already run costs
# nothing.
#
#   nocompose  refuses every invocation, which is what a runtime without compose
#              support looks like from the outside
#   compose    answers `<runtime> compose version`
#   recording  appends the argv it was handed to ${ADCW_TEST_LOG} and succeeds, for the
#              cases asking *what* ADCW tells the runtime to do rather than which one it
#              picks
_STUBS="$(_scratch)"
{
    printf '#!/bin/bash\nexit 1\n' >"${_STUBS}/nocompose"
    # Single quotes on purpose throughout: the parameters belong to the stub when it
    # runs, not to this file when it writes it.
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n%s\nexit 1\n' \
        '[ "${1:-}" = compose ] && [ "${2:-}" = version ] && exit 0' >"${_STUBS}/compose"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n%s\nexit 0\n' \
        'printf "%s\n" "$0 $*" >>"${ADCW_TEST_LOG}"' >"${_STUBS}/recording"
}
chmod +x "${_STUBS}"/*

# Install a fake runtime named ${2} into ${1}. ${3} selects the stub body.
_write_runner_stub() {
    ln -s "${_STUBS}/${3:-nocompose}" "$1/$2"
}

# Resolve a runtime for ${2} against the stubs in ${1} and print the binary chosen.
# ${3}, when given, pins _ADCW_CONTAINER_RUNNER_BIN. On failure the error message is
# printed instead, so one helper serves both the positive and the negative assertions.
#
# A subshell throughout: PATH and the resolved runtime stay out of the rest of the case,
# which asks for several resolutions in a row.
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
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # Unchanged behaviour, and the counterpart to the compose case below: `container`
    # cannot compose but runs containers perfectly well, so for `run` it still wins.
    assert_equals "${tmp}/container" "$(_detect_runner_in "${tmp}" run)" "run picks first"

    echo "  PASS"
}

test_runner_compose_skips_the_incapable() {
    echo "Testing: 'compose' skips a runtime that has none..."
    local tmp
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # The defect this replaced: compose mode landed on Apple's `container`, first in the
    # list and without compose in any form, while docker sat two entries further down.
    assert_equals "${tmp}/docker" "$(_detect_runner_in "${tmp}" compose)" "compose skips container"

    echo "  PASS"
}

test_compose_cmd_is_the_runtime_subcommand() {
    echo "Testing: A runtime carrying compose as a subcommand is used as such..."
    local tmp
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" nerdctl compose

    # `nerdctl compose` exists and is documented, so nerdctl and finch need no special
    # case — only the two standalone binaries below do.
    assert_equals "${tmp}/nerdctl compose" "$(_find_compose_cmd_in "${tmp}")" "subcommand form"

    echo "  PASS"
}

test_compose_cmd_apple_standalone_is_found() {
    echo "Testing: Apple's container gets container-compose, never docker..."
    local tmp
    tmp="$(_scratch)"
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

    echo "  PASS"
}

test_compose_cmd_stays_with_its_own_runtime() {
    echo "Testing: podman without 'podman compose' gets podman-compose, never docker..."
    local tmp
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" podman nocompose
    _write_runner_stub "${tmp}" podman-compose nocompose
    _write_runner_stub "${tmp}" docker compose

    # podman precedes docker, and podman *can* compose — through the standalone
    # implementation that belongs to it. Answering with `docker compose` here would talk
    # to a different engine holding different containers, so the service started under
    # podman would simply not be there.
    assert_equals "podman-compose" "$(_find_compose_cmd_in "${tmp}")" "standalone pairing"

    echo "  PASS"
}

test_compose_cmd_survives_a_spaced_path() {
    echo "Testing: A runtime under a path with a space stays one argv word..."
    local tmp dir out count first
    tmp="$(_scratch)"
    dir="${tmp}/Docker Desktop/bin"
    mkdir -p "${dir}"
    _write_runner_stub "${dir}" docker compose

    # The regression the array replaced: the compose command was printed as a string and
    # split back with `read -a`, which splits on IFS and knows nothing about quoting. A
    # "Docker Desktop" directory — the realistic case, and the likely one on Windows —
    # became two argv words, so the invocation pointed at a path that does not exist.
    #
    # The count and the first word, not the flattened string _find_compose_cmd_in
    # prints: flattening is exactly the round trip under test, so a string comparison
    # would hold for both the fixed and the broken form.
    out="$(
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        _adcw_detect_runner compose >/dev/null 2>&1 || exit 1
        printf '%s\n%s\n' "${#_adcw_compose_cmd[@]}" "${_adcw_compose_cmd[0]}"
    )" || _fail "no compose implementation resolved"
    {
        read -r count
        read -r first
    } <<<"${out}"

    assert_equals "2" "${count}" "argv is <runtime> compose, two words"
    assert_equals "${dir}/docker" "${first}" "the spaced path stays one word"

    echo "  PASS"
}

test_runner_pinned_is_held_to_the_requirement() {
    echo "Testing: A pinned runtime must satisfy the requirement, no silent switch..."
    local tmp output
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" docker compose

    # Naming a runtime is a statement about which engine holds the containers. When it
    # cannot do what the mode needs, that is an error to report -- quietly using docker
    # instead would answer a question nobody asked.
    output="$(_detect_runner_in "${tmp}" compose "${tmp}/container")" || true
    assert_matches "${output}" "_ADCW_CONTAINER_RUNNER_BIN" "error does not name the variable"
    refute_matches "${output}" "docker" "switched to another runtime"

    echo "  PASS"
}

test_runner_none_installed() {
    echo "Testing: No runtime at all is reported as such..."
    local tmp output
    tmp="$(_scratch)"

    output="$(_detect_runner_in "${tmp}" run)" || true
    assert_matches "${output}" "Unable to locate a container runtime" "unexpected error"

    # A runtime that runs but cannot compose is a different situation from having none,
    # and saying "no container runtime" there would send the reader hunting for an
    # installation they already have.
    _write_runner_stub "${tmp}" container nocompose
    output="$(_detect_runner_in "${tmp}" compose)" || true
    assert_matches "${output}" "No container runtime with compose support" \
        "unexpected compose error"

    echo "  PASS"
}

test_runner_pinned_must_exist() {
    echo "Testing: A pinned runtime that is not installed is reported, not used..."
    local tmp output
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" docker compose

    # `run` is satisfied by being installed, and every candidate the loop sees came out of
    # `command -v`. A pinned runtime skips that walk, so nothing else establishes that the
    # name resolves — a typo would otherwise reach the runtime invocation itself, after
    # adcbw already announced which store it was filling.
    output="$(_detect_runner_in "${tmp}" run "${tmp}/not-installed")" || true
    assert_matches "${output}" "not executable" "a non-existent pinned runtime was accepted"
    assert_matches "${output}" "_ADCW_CONTAINER_RUNNER_BIN" "error does not name the variable"

    echo "  PASS"
}

test_runner_unknown_capability_is_the_callers_error() {
    echo "Testing: An unknown capability is reported once, not once per runtime..."
    local tmp output occurrences
    tmp="$(_scratch)"
    _write_runner_stub "${tmp}" container nocompose
    _write_runner_stub "${tmp}" podman nocompose
    _write_runner_stub "${tmp}" docker compose

    # Asking for something that does not exist is not a shortcoming of any runtime, so
    # trying the next one repeats the same wrong answer. The guard matters beyond tidiness:
    # ADR-009 rests the absence of a `build` capability on it failing loudly and correctly.
    output="$(_detect_runner_in "${tmp}" build)" || true
    occurrences="$(echo "${output}" | grep -c "Unknown runtime capability" || true)"
    assert_equals "1" "${occurrences}" "the capability error, reported once — '${output}'"
    # The fallthrough would end in "no runtime found" on a machine carrying three.
    refute_matches "${output}" "Unable to locate a container runtime" \
        "reported as a missing runtime"

    echo "  PASS"
}

# --- The build invocation (ADR-009, CON-001) ---

# The PATH every adcbw case runs against: both candidate runtimes recording, plus the
# one thing adcbw needs off PATH besides a runtime — it asks who is building.
_adcbw_stub_dir() {
    local dir
    dir="$(_scratch)"
    _write_runner_stub "${dir}" container recording
    _write_runner_stub "${dir}" docker recording
    ln -s "$(command -v id)" "${dir}/id"
    printf '%s' "${dir}"
}

# Run bin/adcbw against the stubs in ${1}, and report through three variables:
# adcbw_rc, adcbw_out (stdout and stderr together) and adcbw_calls (the argv the runtime
# was handed, empty when the build never started). ${2} pins _ADCW_CONTAINER_RUNNER_BIN
# when non-empty; anything after it is passed on to adcbw. Both are mandatory, so the
# caller reads as a sentence.
#
# The log is truncated here rather than by the caller: which of the two it was is a
# question the assertions kept having to answer for themselves.
#
# ADOC_VERSION short-circuits the git probe and ADOC_PROJECT_HOME the realpath/dirname
# one, so the stub PATH really only has to carry the runtimes plus `id`.
_adcbw_run() {
    local dir="$1" pinned="$2" log="$1/calls"
    shift 2
    : >"${log}"
    adcbw_rc=0
    adcbw_out="$(
        PATH="${dir}"
        export ADCW_TEST_LOG="${log}"
        # A prefix assignment rather than an export: adcbw is a separate process and this
        # is the only channel there is between it and adcw, which is the point being
        # tested. The unset matters too — inheriting a resolved runtime would pin the run
        # to whatever this machine really has installed.
        if [[ -n "${pinned}" ]]; then
            _ADCW_CONTAINER_RUNNER_BIN="${pinned}" \
                ADOC_PROJECT_HOME="${REPO_ROOT}" ADOC_VERSION=stub \
                "${REPO_ROOT}/bin/adcbw" "$@" 2>&1
        else
            unset _ADCW_CONTAINER_RUNNER_BIN
            ADOC_PROJECT_HOME="${REPO_ROOT}" ADOC_VERSION=stub \
                "${REPO_ROOT}/bin/adcbw" "$@" 2>&1
        fi
    )" || adcbw_rc=$?
    adcbw_calls="$(cat "${log}")"
}

test_build_refuses_surplus_arguments() {
    echo "Testing: adcbw refuses what it cannot use rather than dropping it..."
    local dir
    dir="$(_adcbw_stub_dir)"

    # Silently discarded before: the flag was consumed, the rest fell off the end, and
    # the build ran as if nobody had asked for anything else. `--no-cache` is the
    # realistic case — a docker flag someone expects to be passed through.
    _adcbw_run "${dir}" "" --with-mermaid --no-cache
    assert_equals "1" "${adcbw_rc}" "surplus after a flag"
    assert_contains "${adcbw_out}" "Unexpected argument: --no-cache" \
        "message does not name the argument"
    assert_equals "" "${adcbw_calls}" "the build ran anyway"

    # The pre-existing half of the guard, asserted rather than assumed: a mistyped flag
    # must not fall through to the default target.
    _adcbw_run "${dir}" "" --with-mermade
    assert_equals "1" "${adcbw_rc}" "a typo"
    assert_contains "${adcbw_out}" "Unknown option: --with-mermade" "typo message unexpected"
    assert_equals "" "${adcbw_calls}" "the build ran on a typo"

    # And the two forms that must still work.
    _adcbw_run "${dir}" "" --help
    assert_equals "0" "${adcbw_rc}" "--help"
    _adcbw_run "${dir}" ""
    assert_equals "0" "${adcbw_rc}" "no arguments"
    [[ -n "${adcbw_calls}" ]] || _fail "the plain build did not run"

    echo "  PASS"
}

test_build_uses_the_portable_verb() {
    echo "Testing: adcbw builds with the portable verb, on the runtime 'run' resolves..."
    local dir
    dir="$(_adcbw_stub_dir)"

    _adcbw_run "${dir}" ""

    # `buildx` is docker's own spelling; four of the five runtimes have never heard of it,
    # so the bare verb is the whole of the portable surface (CON-001, "Build").
    [[ "${adcbw_calls}" == "${dir}/container build "* ]] ||
        _fail "expected '<runtime> build …' — got '${adcbw_calls}'"
    refute_contains "${adcbw_calls}" "buildx" "buildx survived"

    # The build has to land in the same engine's store the run reads out of, so adcbw must
    # resolve exactly what `run` resolves — docker is installed here and must stay unused.
    assert_equals "${dir}/container" "$(_detect_runner_in "${dir}" run)" "run resolves container"
    refute_contains "${adcbw_calls}" "${dir}/docker" "build crossed to another engine"

    # --target is load-bearing: the Containerfile has two stages and the default is the
    # last one, so losing the flag silently builds the browser-carrying variant.
    assert_contains "${adcbw_calls}" "--target=adoc " "--target=adoc missing"

    _adcbw_run "${dir}" "" --with-mermaid
    assert_contains "${adcbw_calls}" "--target=adoc-with-mermaid " \
        "--with-mermaid did not reach --target"

    echo "  PASS"
}

test_build_honours_the_pinned_engine() {
    echo "Testing: A pinned runtime decides which store the build lands in..."
    local dir
    dir="$(_adcbw_stub_dir)"

    # Nothing carries the resolved runtime from adcbw to adcw — they are two processes.
    # Exporting the variable is what pins both to one engine, and it only works if adcbw
    # honours it, which is the whole of this assertion.
    _adcbw_run "${dir}" "${dir}/docker"
    [[ "${adcbw_calls}" == "${dir}/docker build "* ]] ||
        _fail "pinned runtime ignored — got '${adcbw_calls}'"

    echo "  PASS"
}

# Every case is discovered rather than listed, and runs in its own subshell.
#
# Discovered, because the hand-written list this replaced had to be edited twice per new
# case and the second edit failed silently — an unregistered test simply never ran while
# the suite still reported everything passed.
#
# In a subshell, because isolation is the harness's job: PATH, ADOC_*,
# _ADCW_CONTAINER_RUNNER_BIN and _adcw_compose_cmd all live in this shell, and a case
# leaking into the next is what the helpers used to defend against one at a time. It
# also means the discovered order does not matter. Fail-fast is kept — the first case to
# fail ends the run, which is what a unit suite this fast should do.
echo "=== ADCW Tests ==="
for _test in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    ("${_test}") || exit 1
done
echo "=== All tests passed ==="
