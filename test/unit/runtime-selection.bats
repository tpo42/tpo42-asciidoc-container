# Runtime selection by capability (ADR-009): which engine ADCW picks, and how it spells
# compose for that engine.
#
# Run through test/run-suite.bash, never `bats` directly — the wrapper pins the
# interpreter to /bin/bash (ADR-010).

load '../test_helper/adcw'
load '../test_helper/runtime_stubs'

setup_file() {
    runtime_stubs_init
}

setup() {
    # shellcheck source=../../bin/adcw
    source "${REPO_ROOT}/bin/adcw"
}

# Resolve a compose implementation against the stubs in ${1} and print it as one line.
#
# Selecting for `compose` is what fills _adcw_compose_cmd — the probe that decides whether
# a runtime can compose is the same code that knows how it is spelled, so there is no
# second call to make. Printing "${_adcw_compose_cmd[*]}" flattens the array for
# comparison; the array-ness itself is what the spaced-path case asserts, since that is
# the property a string round trip used to destroy.
find_compose_cmd_in() {
    local dir="$1"
    (
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        _adcw_detect_runner compose 2>&1 || exit 1
        # SC2154: _adcw_compose_cmd is filled by the library sourced in setup().
        # shellcheck disable=SC2154
        printf '%s' "${_adcw_compose_cmd[*]}"
    )
}

# The same resolution, reported as element count and first element rather than flattened.
# Only the spaced-path case needs this, and it needs it because flattening is the very
# round trip that case exists to catch.
compose_argv_in() {
    local dir="$1"
    (
        PATH="${dir}"
        unset _ADCW_CONTAINER_RUNNER_BIN
        _adcw_detect_runner compose >/dev/null 2>&1 || exit 1
        printf '%s\n%s\n' "${#_adcw_compose_cmd[@]}" "${_adcw_compose_cmd[0]}"
    )
}

# --- Which runtime the capability selects ------------------------------------

@test "'run' is satisfied by the first installed runtime" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # Unchanged behaviour, and the counterpart to the compose case below: `container`
    # cannot compose but runs containers perfectly well, so for `run` it still wins.
    assert_equal "$(detect_runner_in "${BATS_TEST_TMPDIR}" run)" "${BATS_TEST_TMPDIR}/container"
}

@test "'compose' skips a runtime that has none" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # The defect this replaced: compose mode landed on Apple's `container`, first in the
    # list and without compose in any form, while docker sat two entries further down.
    assert_equal "$(detect_runner_in "${BATS_TEST_TMPDIR}" compose)" "${BATS_TEST_TMPDIR}/docker"
}

# --- How compose is spelled for that runtime ---------------------------------

@test "a runtime carrying compose as a subcommand is used as such" {
    stub_runtime "${BATS_TEST_TMPDIR}" nerdctl compose

    # `nerdctl compose` exists and is documented, so nerdctl and finch need no special
    # case — only the two standalone binaries below do.
    assert_equal "$(find_compose_cmd_in "${BATS_TEST_TMPDIR}")" "${BATS_TEST_TMPDIR}/nerdctl compose"
}

@test "Apple's container gets container-compose, never docker" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" container-compose nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # The route that matters on macOS 26 (CON-001): all three Apple compose routes keep
    # the image in Apple's own store, which is where a local `container build` put it.
    # Answering with `docker compose` here would step out of that store as well as out of
    # that engine. The plugin route needs nothing — it answers `container compose version`
    # and the generic probe already takes it — and socktainer presents as docker; the
    # standalone binary is the one that has to be named.
    assert_equal "$(find_compose_cmd_in "${BATS_TEST_TMPDIR}")" "container-compose"
}

@test "podman without 'podman compose' gets podman-compose, never docker" {
    stub_runtime "${BATS_TEST_TMPDIR}" podman nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" podman-compose nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # podman precedes docker, and podman *can* compose — through the standalone
    # implementation that belongs to it. Answering with `docker compose` here would talk
    # to a different engine holding different containers, so the service started under
    # podman would simply not be there.
    assert_equal "$(find_compose_cmd_in "${BATS_TEST_TMPDIR}")" "podman-compose"
}

@test "a runtime under a path with a space stays one argv word" {
    local dir="${BATS_TEST_TMPDIR}/Docker Desktop/bin"
    mkdir -p "${dir}"
    stub_runtime "${dir}" docker compose

    # The regression the array replaced: the compose command was printed as a string and
    # split back with `read -a`, which splits on IFS and knows nothing about quoting. A
    # "Docker Desktop" directory — the realistic case, and the likely one on Windows —
    # became two argv words, so the invocation pointed at a path that does not exist.
    #
    # The count and the first word, not the flattened string find_compose_cmd_in prints:
    # flattening is exactly the round trip under test, so a string comparison would hold
    # for both the fixed and the broken form.
    run compose_argv_in "${dir}"
    assert_success

    assert_equal "${lines[0]}" "2"
    assert_equal "${lines[1]}" "${dir}/docker"
}

# --- What is reported when nothing satisfies the requirement -----------------

@test "a pinned runtime must satisfy the requirement, no silent switch" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # Naming a runtime is a statement about which engine holds the containers. When it
    # cannot do what the mode needs, that is an error to report — quietly using docker
    # instead would answer a question nobody asked.
    run detect_runner_in "${BATS_TEST_TMPDIR}" compose "${BATS_TEST_TMPDIR}/container"
    assert_failure
    assert_output --partial "_ADCW_CONTAINER_RUNNER_BIN"
    refute_output --partial "docker"
}

@test "no runtime at all is reported as such" {
    run detect_runner_in "${BATS_TEST_TMPDIR}" run
    assert_failure
    assert_output --partial "Unable to locate a container runtime"
}

@test "a runtime that cannot compose is not reported as a missing runtime" {
    # A different situation from having none, and saying "no container runtime" there
    # would send the reader hunting for an installation they already have.
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    run detect_runner_in "${BATS_TEST_TMPDIR}" compose
    assert_failure
    assert_output --partial "No container runtime with compose support"
}

@test "a pinned runtime that is not installed is reported, not used" {
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # `run` is satisfied by being installed, and every candidate the loop sees came out of
    # `command -v`. A pinned runtime skips that walk, so nothing else establishes that the
    # name resolves — a typo would otherwise reach the runtime invocation itself, after
    # adcbw already announced which store it was filling.
    run detect_runner_in "${BATS_TEST_TMPDIR}" run "${BATS_TEST_TMPDIR}/not-installed"
    assert_failure
    assert_output --partial "not executable"
    assert_output --partial "_ADCW_CONTAINER_RUNNER_BIN"
}

@test "an unknown capability is reported once, not once per runtime" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" podman nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # Asking for something that does not exist is not a shortcoming of any runtime, so
    # trying the next one repeats the same wrong answer. The guard matters beyond
    # tidiness: ADR-009 rests the absence of a `build` capability on it failing loudly and
    # correctly.
    run detect_runner_in "${BATS_TEST_TMPDIR}" build
    assert_failure
    assert_equal "$(echo "${output}" | grep -c "Unknown runtime capability")" "1"
    # The fallthrough would end in "no runtime found" on a machine carrying three.
    refute_output --partial "Unable to locate a container runtime"
}
