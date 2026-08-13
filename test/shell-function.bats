# Unit suite for bin/adcw — sources the wrapper and exercises its internals.
#
# No container is started anywhere in this file. Everything is answered by bash builtins
# and by stub binaries on a reduced PATH, which is what keeps it in pre-commit while the
# two container suites sit in pre-push.
#
# Run it through test/run-suite.bash, never through `bats` directly: the wrapper pins the
# interpreter to /bin/bash, and on macOS that is bash 3.2 — the oldest interpreter the
# wrappers have to survive. Sourcing bypasses the `#!/bin/bash` shebang, so whichever
# shell bats runs under is the shell that parses bin/adcw. A bash 4 construct passes
# `bash -n` on 3.2 and only fails when the code actually runs, which is the class of
# defect this suite exists to catch.

load 'test_helper/adcw'

setup_file() {
    # Each distinct stub body is written once per file and every case links to it under
    # whatever runtime name it needs — the code under test asks `command -v` and
    # `${bin##*/}`, both of which read the link's own name.
    #
    # Once rather than per case because on macOS the *first* exec of a newly created file
    # pays a first-run policy evaluation of roughly 0.3 s, per inode. Writing a fresh stub
    # in every case cost this suite more wall clock than everything it asserts put
    # together; a link to an inode that has already run costs nothing. The warming execs
    # below are what buy that.
    #
    #   nocompose  refuses every invocation, which is what a runtime without compose
    #              support looks like from the outside
    #   compose    answers `<runtime> compose version`
    #   recording  appends the argv it was handed to ${ADCW_TEST_LOG} and succeeds, for
    #              the cases asking *what* ADCW tells the runtime to do rather than which
    #              one it picks
    local stubs="${BATS_FILE_TMPDIR}/stubs"
    mkdir -p "${stubs}"

    printf '#!/bin/bash\nexit 1\n' >"${stubs}/nocompose"
    # Single quotes on purpose throughout: the parameters belong to the stub when it
    # runs, not to this file when it writes it.
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n%s\nexit 1\n' \
        '[ "${1:-}" = compose ] && [ "${2:-}" = version ] && exit 0' >"${stubs}/compose"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n%s\nexit 0\n' \
        'printf "%s\n" "$0 $*" >>"${ADCW_TEST_LOG}"' >"${stubs}/recording"
    chmod +x "${stubs}"/nocompose "${stubs}"/compose "${stubs}"/recording

    ADCW_TEST_LOG=/dev/null "${stubs}/nocompose" || true
    ADCW_TEST_LOG=/dev/null "${stubs}/compose" || true
    ADCW_TEST_LOG=/dev/null "${stubs}/recording" || true
}

setup() {
    # shellcheck source=../bin/adcw
    source "${REPO_ROOT}/bin/adcw"
}

# --- Helpers -----------------------------------------------------------------

# Install a fake runtime named ${2} into ${1}. ${3} selects the stub body.
stub_runtime() {
    ln -s "${BATS_FILE_TMPDIR}/stubs/${3:-nocompose}" "$1/$2"
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

# The PATH the adcbw cases run against: both candidate runtimes recording, plus the one
# thing adcbw needs off PATH besides a runtime — it asks who is building.
adcbw_stub_dir() {
    local dir="${BATS_TEST_TMPDIR}/adcbw"
    mkdir -p "${dir}"
    stub_runtime "${dir}" container recording
    stub_runtime "${dir}" docker recording
    ln -s "$(command -v id)" "${dir}/id"
    printf '%s' "${dir}"
}

# Run bin/adcbw against the stubs in ${1} and report through `run`'s $status/$output plus
# ${adcbw_calls} — the argv the runtime was handed, empty when the build never started.
# ${2} pins _ADCW_CONTAINER_RUNNER_BIN when non-empty; anything after it goes to adcbw.
#
# ADOC_VERSION short-circuits the git probe and ADOC_PROJECT_HOME the realpath/dirname
# one, so the stub PATH really only has to carry the runtimes plus `id`.
adcbw_run() {
    local dir="$1" pinned="$2" log="$1/calls"
    shift 2
    : >"${log}"
    # env rather than a prefix assignment: adcbw is a separate process and the
    # environment is the only channel there is between it and adcw, which is the point
    # being tested. Unsetting matters too — inheriting a resolved runtime would pin the
    # run to whatever this machine really has installed.
    if [[ -n "${pinned}" ]]; then
        run env PATH="${dir}" ADCW_TEST_LOG="${log}" \
            ADOC_PROJECT_HOME="${REPO_ROOT}" ADOC_VERSION=stub \
            _ADCW_CONTAINER_RUNNER_BIN="${pinned}" \
            "${REPO_ROOT}/bin/adcbw" "$@"
    else
        # -u before the assignments: BSD env stops looking for options at the first
        # NAME=VALUE and would take a later -u for the command name.
        run env -u _ADCW_CONTAINER_RUNNER_BIN \
            PATH="${dir}" ADCW_TEST_LOG="${log}" \
            ADOC_PROJECT_HOME="${REPO_ROOT}" ADOC_VERSION=stub \
            "${REPO_ROOT}/bin/adcbw" "$@"
    fi
    adcbw_calls="$(cat "${log}")"
}

# --- The wrapper's own surface -----------------------------------------------

@test "--help shows usage" {
    run adcw --help
    assert_success
    assert_output --partial "AsciiDoc Container Wrapper"
}

@test "no context produces an actionable error" {
    unset ADOC_PROJECT_HOME ADOC_VERSION
    # A name no registry will ever carry, instead of relying on the ambient image being
    # absent: once bin/adcbw has run — which the adoc gate requires — the tag derived
    # from git *does* exist locally, and the assertion below would flip.
    export ADOC_IMAGE=tpo42/adoc:test-nonexistent
    run adcw validate

    # Which error is correct depends on the machine, and both are. A developer box and
    # the Linux runner have a runtime but not that image; a GitHub macOS runner has no
    # runtime at all. Asserting only the first would make this suite unrunnable exactly
    # where it matters most — macOS is where /bin/bash is 3.2.
    if _adcw_detect_runner 2>/dev/null; then
        assert_output --regexp "Container.*not found"
    else
        assert_output --partial "Unable to locate a container runtime"
    fi
}

@test "-f names a compose file, and says so when it cannot" {
    # The assertion this replaced was `grep -q "Usage:"` on an invocation without a
    # command — which the argument check answers before any compose code runs, so it held
    # even with every line of compose support deleted. These two reach the -f branch
    # itself.
    run adcw -f /nowhere/compose.yml validate
    assert_output --partial "Compose file not found: /nowhere/compose.yml"

    run adcw -f
    assert_output --partial "-f requires a path argument"
}

# --- Compose discovery -------------------------------------------------------

@test "service auto-detection survives ordinary compose shapes" {
    local tmp="${BATS_TEST_TMPDIR}"

    # The shape that broke it: matching every bare `key:` line let the *last* one win, so
    # a service declaring volumes before its image answered "volumes". Nothing exotic —
    # key order inside a service is free, and half the compose files in the wild put
    # volumes first.
    printf 'name: t\nservices:\n  adoc:\n    volumes:\n      - .:/workspace\n    image: ghcr.io/tpo42/adoc:0\n' >"${tmp}/nested.yml"
    assert_equal "$(_adcw_find_adoc_service "${tmp}/nested.yml")" "adoc"

    # Other top-level sections must not leak into the answer either, and a nested key
    # inside the service must not be mistaken for one.
    printf 'name: t\nvolumes:\n  cache:\nnetworks:\n  default:\nservices:\n  my-adoc:\n    networks:\n      - default\n    image: tpo42/adoc:latest\n' >"${tmp}/sections.yml"
    assert_equal "$(_adcw_find_adoc_service "${tmp}/sections.yml")" "my-adoc"

    # The service that matches is not necessarily the first one declared.
    printf 'name: t\nservices:\n  other:\n    image: nginx\n  adoc:\n    image: ghcr.io/tpo42/adoc:0\n' >"${tmp}/second.yml"
    assert_equal "$(_adcw_find_adoc_service "${tmp}/second.yml")" "adoc"

    # Compose allows the value to be quoted.
    printf 'name: t\nservices:\n  adoc:\n    image: "ghcr.io/tpo42/adoc:0"\n' >"${tmp}/quoted.yml"
    assert_equal "$(_adcw_find_adoc_service "${tmp}/quoted.yml")" "adoc"

    # And the fixture the rest of the repository uses, so the two cannot drift apart.
    assert_equal "$(_adcw_find_adoc_service "${BATS_TEST_DIRNAME}/fixtures/compose-valid.yml")" "adoc"
}

@test "compose discovery follows docker compose's own precedence" {
    local tmp="${BATS_TEST_TMPDIR}" name
    for name in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        printf 'name: t\nservices:\n  adoc:\n    image: ghcr.io/tpo42/adoc:0\n' >"${tmp}/${name}"
    done

    # Not symmetric, and that asymmetry is the point: compose.yaml beats compose.yml, but
    # docker-compose.yml beats docker-compose.yaml. Picking differently from what
    # `docker compose` picks, and then forcing it with -f, would only bite in a repository
    # carrying more than one of them.
    assert_equal "$(cd "${tmp}" && _adcw_detect_compose_path)" "compose.yaml"
    rm -f "${tmp}/compose.yaml"
    assert_equal "$(cd "${tmp}" && _adcw_detect_compose_path)" "compose.yml"
    rm -f "${tmp}/compose.yml"
    assert_equal "$(cd "${tmp}" && _adcw_detect_compose_path)" "docker-compose.yml"
    rm -f "${tmp}/docker-compose.yml"
    assert_equal "$(cd "${tmp}" && _adcw_detect_compose_path)" "docker-compose.yaml"
}

@test "a compose file without this toolchain is not ours" {
    printf 'name: t\nservices:\n  web:\n    image: nginx\n' >"${BATS_TEST_TMPDIR}/compose.yaml"

    # Falling through to the dedicated container serves such a project better than failing
    # over a service that was never meant to be there.
    assert_equal "$(cd "${BATS_TEST_TMPDIR}" && _adcw_detect_compose_path)" ""
}

@test "ADOC_SERVICE turns the content check off" {
    printf 'name: t\nservices:\n  mine:\n    image: example.org/custom-adoc:1\n' >"${BATS_TEST_TMPDIR}/compose.yaml"

    # Naming a service is a statement that the caller knows what is in the file, so a
    # differently named image must not cost them compose mode.
    assert_equal "$(cd "${BATS_TEST_TMPDIR}" && ADOC_SERVICE=mine _adcw_detect_compose_path)" "compose.yaml"
}

# --- Image resolution (ADOC_VERSION / ADOC_REGISTRY / ADOC_IMAGE) ------------

# Resolve in a *freshly sourced* library, because the registry default is applied once at
# source time (`: "${ADOC_REGISTRY=…}"`). Re-using this suite's already-sourced copy would
# test the environment it happened to start in, not the resolution.
#
# ${1} is the image name; everything after it is VAR=value for the child's environment.
resolve_image_fresh() {
    local name="$1"
    shift
    # Single quotes on purpose: $1, $2 and ADOC_IMAGE belong to the child bash, which is
    # the process that sources the library under the controlled environment.
    # shellcheck disable=SC2016
    env -u ADOC_IMAGE -u ADOC_VERSION -u ADOC_REGISTRY -u ADOC_PROJECT_HOME "$@" \
        bash -c 'set -u; . "$1"; _adcw_resolve_image "$2"; printf "%s" "${ADOC_IMAGE}"' \
        bash "${REPO_ROOT}/lib/adcw-common.bash" "${name}"
}

@test "version, registry and image reference resolve as documented" {
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3)" \
        "ghcr.io/tpo42/adoc:1.2.3"

    assert_equal "$(resolve_image_fresh adoc-with-mermaid ADOC_VERSION=1.2.3)" \
        "ghcr.io/tpo42/adoc-with-mermaid:1.2.3"

    # A mirror, or a house image beside the upstream one — the reason ADOC_REGISTRY exists
    # at all (UC-004).
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.registry.internal/team)" \
        "my.registry.internal/team/adoc:1.2.3"

    # Explicitly empty means a bare local name, and it has to survive: the default was
    # once assigned with `:=`, which fires on empty as well as unset, so this could not be
    # expressed at all. CI names its test images this way.
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=ci-abc123 ADOC_REGISTRY=)" \
        "adoc:ci-abc123"

    # The full override wins over both of the above.
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.reg ADOC_IMAGE=example.org/other/thing:9)" \
        "example.org/other/thing:9"

    # No version anywhere, and no checkout to derive one from.
    assert_equal "$(resolve_image_fresh adoc)" "ghcr.io/tpo42/adoc:latest"
}

# --- Runtime selection by capability (ADR-009) -------------------------------
#
# Every case below builds its own PATH out of stub binaries, so the set of installed
# runtimes is exactly what the case declares — not what the machine happens to carry.
# That PATH holds *nothing else*: the code under test asks only bash builtins
# (`command -v`, `${bin##*/}`) plus the stubs themselves, so no external tool has to be
# reachable, and none can smuggle in a real docker.

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

@test "a pinned runtime must satisfy the requirement, no silent switch" {
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # Naming a runtime is a statement about which engine holds the containers. When it
    # cannot do what the mode needs, that is an error to report — quietly using docker
    # instead would answer a question nobody asked.
    run detect_runner_in "${BATS_TEST_TMPDIR}" compose "${BATS_TEST_TMPDIR}/container"
    assert_output --partial "_ADCW_CONTAINER_RUNNER_BIN"
    refute_output --partial "docker"
}

@test "no runtime at all is reported as such" {
    run detect_runner_in "${BATS_TEST_TMPDIR}" run
    assert_output --partial "Unable to locate a container runtime"

    # A runtime that runs but cannot compose is a different situation from having none,
    # and saying "no container runtime" there would send the reader hunting for an
    # installation they already have.
    stub_runtime "${BATS_TEST_TMPDIR}" container nocompose
    run detect_runner_in "${BATS_TEST_TMPDIR}" compose
    assert_output --partial "No container runtime with compose support"
}

@test "a pinned runtime that is not installed is reported, not used" {
    stub_runtime "${BATS_TEST_TMPDIR}" docker compose

    # `run` is satisfied by being installed, and every candidate the loop sees came out of
    # `command -v`. A pinned runtime skips that walk, so nothing else establishes that the
    # name resolves — a typo would otherwise reach the runtime invocation itself, after
    # adcbw already announced which store it was filling.
    run detect_runner_in "${BATS_TEST_TMPDIR}" run "${BATS_TEST_TMPDIR}/not-installed"
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
    assert_equal "$(echo "${output}" | grep -c "Unknown runtime capability")" "1"
    # The fallthrough would end in "no runtime found" on a machine carrying three.
    refute_output --partial "Unable to locate a container runtime"
}

# --- The build invocation (ADR-009, CON-001) ---------------------------------

@test "adcbw refuses what it cannot use rather than dropping it" {
    local dir
    dir="$(adcbw_stub_dir)"

    # Silently discarded before: the flag was consumed, the rest fell off the end, and the
    # build ran as if nobody had asked for anything else. `--no-cache` is the realistic
    # case — a docker flag someone expects to be passed through.
    adcbw_run "${dir}" "" --with-mermaid --no-cache
    assert_failure 1
    assert_output --partial "Unexpected argument: --no-cache"
    assert_equal "${adcbw_calls}" ""

    # The pre-existing half of the guard, asserted rather than assumed: a mistyped flag
    # must not fall through to the default target.
    adcbw_run "${dir}" "" --with-mermade
    assert_failure 1
    assert_output --partial "Unknown option: --with-mermade"
    assert_equal "${adcbw_calls}" ""

    # And the two forms that must still work.
    adcbw_run "${dir}" "" --help
    assert_success
    adcbw_run "${dir}" ""
    assert_success
    refute [ -z "${adcbw_calls}" ]
    # ^ the plain build must actually have run
}

@test "adcbw builds with the portable verb, on the runtime 'run' resolves" {
    local dir
    dir="$(adcbw_stub_dir)"

    adcbw_run "${dir}" ""
    assert_success

    # `buildx` is docker's own spelling; four of the five runtimes have never heard of it,
    # so the bare verb is the whole of the portable surface (CON-001, "Build").
    [[ "${adcbw_calls}" == "${dir}/container build "* ]] ||
        fail "expected '<runtime> build …' — got '${adcbw_calls}'"
    [[ "${adcbw_calls}" != *buildx* ]] || fail "buildx survived — got '${adcbw_calls}'"

    # The build has to land in the same engine's store the run reads out of, so adcbw must
    # resolve exactly what `run` resolves — docker is installed here and must stay unused.
    assert_equal "$(detect_runner_in "${dir}" run)" "${dir}/container"
    [[ "${adcbw_calls}" != *"${dir}/docker"* ]] ||
        fail "build crossed to another engine — got '${adcbw_calls}'"

    # --target is load-bearing: the Containerfile has two stages and the default is the
    # last one, so losing the flag silently builds the browser-carrying variant.
    [[ "${adcbw_calls}" == *"--target=adoc "* ]] ||
        fail "--target=adoc missing — got '${adcbw_calls}'"

    adcbw_run "${dir}" "" --with-mermaid
    [[ "${adcbw_calls}" == *"--target=adoc-with-mermaid "* ]] ||
        fail "--with-mermaid did not reach --target — got '${adcbw_calls}'"
}

@test "a pinned runtime decides which store the build lands in" {
    local dir
    dir="$(adcbw_stub_dir)"

    # Nothing carries the resolved runtime from adcbw to adcw — they are two processes.
    # Exporting the variable is what pins both to one engine, and it only works if adcbw
    # honours it, which is the whole of this assertion.
    adcbw_run "${dir}" "${dir}/docker"
    [[ "${adcbw_calls}" == "${dir}/docker build "* ]] ||
        fail "pinned runtime ignored — got '${adcbw_calls}'"
}
