# Regression suite for container/resources/flatten.sh.
#
# Runs through bin/adcw rather than calling flatten directly, because that is the interface
# consumers use: the wrapper, the image, the script inside it.
#
# flatten had no suite at all until now, which is why an option missing its value could die
# with bash's own "unbound variable" for as long as it did.
#
# Needs the delivered image:
#   ADOC_VERSION=local ./bin/adcbw
#
# Every case owns its output directory and shares nothing writable, so the cases may run
# concurrently (`--jobs`).

load 'test_helper/adcw'

FIXTURES="test/fixtures/flatten"

setup() {
    cd "${REPO_ROOT}" || return 1
    OUT="$(workspace_tmpdir)"
    OUT_ABS="${REPO_ROOT}/${OUT}"
}

teardown() {
    [[ -n "${OUT_ABS:-}" ]] && rm -rf "${OUT_ABS}"
    return 0
}

# The control: an include is resolved rather than carried over.
@test "an include is resolved into the output" {
    run ./bin/adcw flatten -i "${FIXTURES}/with-include.adoc" -o "${OUT}/flat.adoc"
    assert_success

    [[ -f "${OUT_ABS}/flat.adoc" ]] || fail "no output written"
    run cat "${OUT_ABS}/flat.adoc"
    assert_output --partial "only in the included part"
    refute_output --partial "include::"
}

@test "a missing input file is reported" {
    run ./bin/adcw flatten -i "${FIXTURES}/nope.adoc" -o "${OUT}/flat.adoc"
    assert_failure
    assert_output --partial "Input file not found"
}

# Both options take a value, and both dereference $2 to get it. As the last argument that
# is an unset parameter under `set -u`, so the script died with bash's words about its own
# implementation instead of its own about the invocation.
@test "-i without its value is reported, not crashed on" {
    run ./bin/adcw flatten -i
    assert_failure
    refute_output --partial "unbound variable"
    assert_output --partial "-i requires"
}

@test "-o without its value is reported, not crashed on" {
    run ./bin/adcw flatten -i "${FIXTURES}/with-include.adoc" -o
    assert_failure
    refute_output --partial "unbound variable"
    assert_output --partial "-o requires"
}
