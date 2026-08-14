# Properties of the delivered image itself.
#
# The only suite that talks to a container runtime directly instead of going through
# bin/adcw. That is deliberate and the exception proves the rule: what is under test here
# is the image, not the wrapper, and the wrapper's command list is closed — it dispatches
# flatten, validate, extract-diagrams, the asciidoctor family and `shell`, none of which
# can carry the shell invocation these cases need.
#
# Everything asserted here is a property nothing else notices when it disappears. A base
# image that sets PATH differently, a dropped sudoers file, an environment variable that
# outlives what it pointed at — the toolchain keeps working, and only somebody at an
# interactive prompt finds out.
#
# Needs the delivered image:
#   ADOC_VERSION=local ./bin/adcbw

load 'test_helper/adcw'

setup() {
    cd "${REPO_ROOT}" || return 1
    _adcw_detect_runner run >/dev/null 2>&1 || skip "no container runtime"
    IMAGE="$(resolve_image adoc)"
}

# Run a shell snippet in a throwaway container. ${1} is `-lc` or `-c`, so a case can ask
# the login and the non-login path apart — which is the whole point of two of them.
in_image() {
    "${_ADCW_CONTAINER_RUNNER_BIN}" run --rm "${IMAGE}" bash "$1" "$2"
}

@test "a login shell finds the delivered commands" {
    # /etc/profile builds PATH from scratch and drops what ENV PATH put there, so without
    # the profile.d snippet `bash -l` has no asciidoctor and no gem binary at all.
    run in_image -lc 'command -v asciidoctor && command -v extract-diagrams'
    assert_success
    assert_output --partial "asciidoctor"
    assert_output --partial "extract-diagrams"
}

@test "a non-login shell finds them too" {
    # The path every adcw command takes. Asserted beside the login case so a fix to one
    # cannot quietly break the other.
    run in_image -c 'command -v asciidoctor && command -v validate && command -v flatten'
    assert_success
}

@test "sudo needs no password" {
    # The account has no password, so membership in `sudo` without NOPASSWD leaves the
    # prompt unanswerable — installing a package for the length of a session then needs a
    # second terminal as root.
    run in_image -c 'sudo -n id -u'
    assert_success
    assert_output "0"
}

@test "no environment variable points at the dropped distribution PlantUML" {
    # PLANTUML_JAR named /usr/share/plantuml/plantuml.jar, which left with the Debian
    # package. asciidoctor-diagram reads DIAGRAM_PLANTUML_CLASSPATH, so nothing broke —
    # it just said something untrue to whoever read the environment.
    # SC2016: single quotes on purpose — the expansion belongs to the shell inside the
    # container, which is the one being asked.
    # shellcheck disable=SC2016
    run in_image -lc 'echo "[${PLANTUML_JAR:-unset}]"'
    assert_success
    assert_output "[unset]"
}

@test "the Mermaid variant carries the same shell environment" {
    # Stage two re-declares USER and could diverge without anyone noticing: the suites
    # that use the variant only ever ask it to render.
    local variant
    variant="$(resolve_image adoc-with-mermaid)"

    if ! "${_ADCW_CONTAINER_RUNNER_BIN}" image inspect "${variant}" >/dev/null 2>&1; then
        if [[ -n "${ADCW_TEST_REQUIRE_MERMAID:-}" ]]; then
            fail "${variant} unavailable while ADCW_TEST_REQUIRE_MERMAID is set — build it with: ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
        fi
        skip "${variant} not built — ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
    fi

    run "${_ADCW_CONTAINER_RUNNER_BIN}" run --rm "${variant}" bash -lc \
        'command -v asciidoctor >/dev/null && command -v mmdc >/dev/null && sudo -n id -u'
    assert_success
    assert_output "0"
}
