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
#   ADOC_VERSION=local ./bin/adcbw

set -e -u -o pipefail

# Image resolution, reporting and the tally live in the harness, shared with the
# extract-diagrams suite.
# shellcheck source=lib/harness.bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.bash"

FIXTURES="test/fixtures/validate"

cd "${REPO_ROOT}"

ADOC_BASE_IMAGE="$(resolve_image adoc)"

# check <fixture> <expected exit> <pattern>... [-- <extra adcw arguments>]
#
# A pattern prefixed with '!' must *not* appear. That is what tells "the renderer was
# skipped" apart from "the renderer ran and stayed quiet", and it is why the escape-hatch
# case below is a case rather than a hand-written block beside the harness.
check() {
    local fixture="$1" want_rc="$2"
    shift 2

    local -a patterns=() extra=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift
            extra=("$@")
            break
        fi
        patterns+=("$1")
        shift
    done

    local output rc=0 pattern
    printf '%-38s ' "${fixture}${extra[0]:+ ${extra[*]}}"

    # bash 3.2 treats "${extra[@]}" on an empty array as unbound under `set -u`, hence
    # the guard rather than a plain expansion.
    output="$(./bin/adcw validate -i "${FIXTURES}/${fixture}.adoc" -l INFO \
        ${extra[@]+"${extra[@]}"} 2>&1)" || rc=$?

    if [[ "${rc}" -ne "${want_rc}" ]]; then
        fail "expected exit ${want_rc}, got ${rc}" "${output}"
        return 0
    fi

    for pattern in "${patterns[@]}"; do
        if [[ "${pattern}" == '!'* ]]; then
            if echo "${output}" | grep -qE "${pattern#!}"; then
                fail "exit ${rc} as expected, but /${pattern#!}/ must not appear" "${output}"
                return 0
            fi
        elif ! echo "${output}" | grep -qE "${pattern}"; then
            fail "exit ${rc} as expected, but no match for /${pattern}/" "${output}"
            return 0
        fi
    done

    echo "PASS"
}

echo "=== validate regression suite (image ${ADOC_BASE_IMAGE}) ==="

# The control. Without it a validator that fails on everything would look perfect.
check clean 0 'All files validated successfully'

check missing-include 1 'ERROR:.*include file not found'
check optional-include 1 'INFO:.*optional include dropped'
check unresolved-xref 1 'INFO:.*possible invalid reference'
check skipped-heading 1 'WARNING:.*section title out of sequence'

# The gap this suite was written for: without the diagram extension asciidoctor only
# parses the block, so a broken diagram reaches DEBUG ("unknown style for listing block")
# and validation passes. Rendering is what turns it into a finding.
check plantuml-syntax-error 1 'ERROR:.*Failed to generate image'

# The escape hatch has to actually escape, or --no-diagrams is a comfortable lie.
#
# Three assertions, because exit 0 alone is satisfied by a validator that skipped the
# document entirely — which is the same shape of lie in the other direction. The run has
# to succeed, the renderer must not have run, and the file must be reported as validated.
check plantuml-syntax-error 0 \
    'Valid files:[[:space:]]+1' \
    '!Failed to generate image' \
    -- --no-diagrams

summarize
