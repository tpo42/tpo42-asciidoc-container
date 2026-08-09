#!/bin/bash
# Regression suite for container/resources/validate.sh — one fixture per defect class.
#
# Runs through bin/adcw rather than calling validate directly, because that is the
# interface consumers actually use: the wrapper, the image, the script inside it. A test
# that bypassed the wrapper would pass while the delivered path was broken.
#
# Each case asserts an exit code *and* a diagnostic, because the exit code alone cannot
# tell "found the defect" from "fell over for an unrelated reason". The patterns quote
# asciidoctor's own wording; when an upgrade rephrases one, this suite is where that
# surfaces, which is the point.
#
# Needs the delivered image. Build it with:
#   CONTAINER_TAG=local ./bin/adcbw

set -e
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="test/fixtures/validate"

: "${CONTAINER_TAG:=local}"
export CONTAINER_TAG

failures=0

# Prefix every line of a captured block, without piping a variable through sed.
indent() { echo "      | ${1//$'\n'/$'\n'      | }"; }

# case <fixture> <expected exit> <expected diagnostic regex>
check() {
    local fixture="$1" want_rc="$2" want_pattern="$3"
    local output rc=0

    printf '%-22s ' "${fixture}"
    output="$(cd "${REPO_ROOT}" && ./bin/adcw validate -i "${FIXTURES}/${fixture}.adoc" -l INFO 2>&1)" || rc=$?

    if [[ "${rc}" -ne "${want_rc}" ]]; then
        echo "FAIL: expected exit ${want_rc}, got ${rc}"
        indent "${output}"
        failures=$((failures + 1))
        return 0
    fi

    if ! echo "${output}" | grep -qE "${want_pattern}"; then
        echo "FAIL: exit ${rc} as expected, but no match for /${want_pattern}/"
        indent "${output}"
        failures=$((failures + 1))
        return 0
    fi

    echo "PASS"
}

echo "=== validate regression suite (image tpo42/adoc:${CONTAINER_TAG}) ==="

# The control. Without it a validator that fails on everything would look perfect.
check clean 0 'All files validated successfully'

check missing-include 1 'ERROR:.*include file not found'
check optional-include 1 'INFO:.*optional include dropped'
check unresolved-xref 1 'INFO:.*possible invalid reference'
check skipped-heading 1 'WARNING:.*section title out of sequence'

# The gap this suite was written for: without the diagram extension asciidoctor only
# parses the block, so a broken diagram reaches DEBUG ("unknown style for listing block")
# and validation passes. Rendering is what turns it into a finding.
check broken-plantuml 1 'ERROR:.*Failed to generate image'

# The escape hatch has to actually escape, or --no-diagrams is a comfortable lie.
#
# Three assertions, because exit 0 alone is satisfied by a validator that skipped the
# document entirely — which is the same shape of lie in the other direction. The run has
# to succeed, the renderer must not have run, and the file must be reported as validated.
printf '%-22s ' "broken-plantuml/off"
off_rc=0
off_output="$(cd "${REPO_ROOT}" && ./bin/adcw validate -i "${FIXTURES}/broken-plantuml.adoc" \
    -l INFO --no-diagrams 2>&1)" || off_rc=$?
if [[ "${off_rc}" -ne 0 ]]; then
    echo "FAIL: --no-diagrams still failed the document"
    indent "${off_output}"
    failures=$((failures + 1))
elif echo "${off_output}" | grep -qE 'Failed to generate image'; then
    echo "FAIL: the renderer ran despite --no-diagrams"
    indent "${off_output}"
    failures=$((failures + 1))
elif ! echo "${off_output}" | grep -qE 'Valid files:[[:space:]]+1'; then
    echo "FAIL: exit 0, but the document was never reported as validated"
    indent "${off_output}"
    failures=$((failures + 1))
else
    echo "PASS"
fi

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "=== ${failures} case(s) failed ==="
    exit 1
fi
echo "=== All cases passed ==="
