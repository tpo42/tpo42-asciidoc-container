# The wrapper's own argument surface, and how it finds a compose file to work with.
#
# No container and no stub runtimes here: everything below is answered by bin/adcw's own
# parsing and by files on disk.
#
# Run through test/run-suite.bash, never `bats` directly — the wrapper pins the
# interpreter to /bin/bash (ADR-010).

load '../test_helper/adcw'

setup() {
    # shellcheck source=../../bin/adcw
    source "${REPO_ROOT}/bin/adcw"
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
    # The status as well as the wording: a wrapper that printed this and exited 0 would
    # leave every caller believing the document validated.
    assert_failure

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
    assert_failure
    assert_output --partial "Compose file not found: /nowhere/compose.yml"

    run adcw -f
    assert_failure
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
    assert_equal "$(_adcw_find_adoc_service "${REPO_ROOT}/test/fixtures/compose-valid.yml")" "adoc"
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
