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

test_compose_detection() {
    echo "Testing: Compose file detection and service parsing..."
    local compose_file="${SCRIPT_DIR}/fixtures/compose-valid.yml"
    local output
    # Without a command, compose mode shows usage error
    output="$(adcw -f "${compose_file}" 2>&1)" || true # Expected to fail
    echo "${output}" | grep -q "Usage:"
    echo "  PASS"
}

test_compose_service_detection() {
    echo "Testing: Service auto-detection from compose file..."
    local compose_file="${SCRIPT_DIR}/fixtures/compose-valid.yml"
    local service
    service="$(_adcw_find_adoc_service "${compose_file}")"
    [[ "${service}" == "adoc" ]] || {
        echo "  FAIL: expected 'adoc', got '${service}'"
        exit 1
    }
    echo "  PASS"
}

# Run all tests
echo "=== ADCW Tests ==="
test_help
test_no_context_error
test_compose_detection
test_compose_service_detection
echo "=== All tests passed ==="
