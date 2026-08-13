# The build invocation (ADR-009, CON-001): what bin/adcbw asks the runtime to do, and
# which engine's store it lands in.
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

# The PATH these cases run against: both candidate runtimes recording, plus the one thing
# adcbw needs off PATH besides a runtime — it asks who is building.
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
    # env rather than a prefix assignment: adcbw is a separate process and the environment
    # is the only channel there is between it and adcw, which is the point being tested.
    # Unsetting matters too — inheriting a resolved runtime would pin the run to whatever
    # this machine really has installed.
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
}

@test "the forms adcbw must still accept keep working" {
    local dir
    dir="$(adcbw_stub_dir)"

    adcbw_run "${dir}" "" --help
    assert_success

    adcbw_run "${dir}" ""
    assert_success
    refute [ -z "${adcbw_calls}" ]
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
}

@test "--target reaches the build and follows --with-mermaid" {
    local dir
    dir="$(adcbw_stub_dir)"

    # --target is load-bearing: the Containerfile has two stages and the default is the
    # last one, so losing the flag silently builds the browser-carrying variant.
    adcbw_run "${dir}" ""
    assert_success
    [[ "${adcbw_calls}" == *"--target=adoc "* ]] ||
        fail "--target=adoc missing — got '${adcbw_calls}'"

    adcbw_run "${dir}" "" --with-mermaid
    assert_success
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
