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
    echo "Testing: No context produces container-not-found error..."
    unset ADCW_LOCATION ADC_PROJECT_HOME CONTAINER_TAG CONTAINER_IMAGE 2>/dev/null || true
    local output
    output="$(adcw validate 2>&1)" || true  # Expected to fail
    echo "${output}" | grep -q "Container.*not found"
    echo "  PASS"
}

test_compose_detection() {
    echo "Testing: Compose file detection and service parsing..."
    local compose_file="${SCRIPT_DIR}/fixtures/compose-valid.yml"
    local output
    # Without a command, compose mode shows usage error
    output="$(adcw -f "${compose_file}" 2>&1)" || true  # Expected to fail
    echo "${output}" | grep -q "Usage:"
    echo "  PASS"
}

test_compose_service_detection() {
    echo "Testing: Service auto-detection from compose file..."
    local compose_file="${SCRIPT_DIR}/fixtures/compose-valid.yml"
    local service
    service="$(_adcw_find_adoc_service "${compose_file}")"
    [[ "${service}" == "adoc" ]] || { echo "  FAIL: expected 'adoc', got '${service}'"; exit 1; }
    echo "  PASS"
}

# Run all tests
echo "=== ADCW Tests ==="
test_help
test_no_context_error
test_compose_detection
test_compose_service_detection
echo "=== All tests passed ==="
