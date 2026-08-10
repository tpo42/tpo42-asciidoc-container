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

# Run all tests
echo "=== ADCW Tests ==="
test_help
test_no_context_error
test_compose_flag_takes_a_path
test_compose_service_detection
test_compose_discovery_order
test_compose_discovery_ignores_foreign_file
test_compose_discovery_honours_service_override
echo "=== All tests passed ==="
