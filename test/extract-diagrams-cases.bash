#!/bin/bash
# Regression suite for container/resources/extract-diagrams.sh.
#
# Runs through bin/adcw rather than calling the script directly, because that is the
# interface consumers use: the wrapper, the image, the script inside it.
#
# Written after a bug that survived three releases unnoticed: the block finder matched
# only `....` literal blocks, so diagrams written with `----` — the form
# asciidoctor-diagram uses throughout its own documentation — were silently skipped and
# the tool reported "No diagrams found". Nothing was broken; nothing was found either.
# Both delimiters are the first two cases here for that reason.
#
# Needs the delivered image. Build it with:
#   CONTAINER_TAG=local ./bin/adcbw

set -e
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="test/fixtures/extract-diagrams"

: "${CONTAINER_TAG:=local}"
export CONTAINER_TAG

cd "${REPO_ROOT}"

# Output goes into the workspace because the container only sees that; build/ is where
# adcw already puts generated things, and the trap takes it away again.
mkdir -p build
OUT="$(mktemp -d build/.extract-cases.XXXXXX)"
trap 'rm -rf "${OUT}"' EXIT

failures=0

indent() { echo "      | ${1//$'\n'/$'\n'      | }"; }

# case <label> <fixture> <format> <expected diagnostic regex>
check() {
    local label="$1" fixture="$2" format="$3" want_pattern="$4"
    local output rc=0

    printf '%-28s ' "${label}"
    output="$(./bin/adcw extract-diagrams -i "${FIXTURES}/${fixture}.adoc" \
        -o "${OUT}/${label}" --format "${format}" 2>&1)" || rc=$?

    if [[ "${rc}" -ne 0 ]]; then
        echo "FAIL: exited ${rc}"
        indent "${output}"
        failures=$((failures + 1))
        return 0
    fi

    if ! echo "${output}" | grep -qE "${want_pattern}"; then
        echo "FAIL: no match for /${want_pattern}/"
        indent "${output}"
        failures=$((failures + 1))
        return 0
    fi

    echo "PASS"
}

echo "=== extract-diagrams regression suite (image tpo42/adoc:${CONTAINER_TAG}) ==="

# The two delimiters, which is what this suite exists for.
check listing-block listing-block source 'Diagrams found: 1'
check literal-block literal-block source 'Diagrams found: 1'

# Mixed in one document, so a finder that handles one form by dropping the other cannot
# pass both cases above by accident.
check both-delimiters both-blocks source 'Diagrams found: 2'

# Not every absence is a failure: a document without diagrams is a valid document.
# `[source,ruby]` is a listing block too, and must not be mistaken for one.
check no-diagrams no-diagrams source 'No diagrams found'

# Rendering goes through the PlantUML jar the asciidoctor-diagram-plantuml gem carries,
# not through a distribution package. If that resolution breaks, this is where it shows.
check plantuml-render listing-block rendered 'Rendered: .*\.svg'

# extract-diagrams renders PlantUML and Graphviz and says so for everything else — its
# own case list, independent of what asciidoctor-diagram could do. A Mermaid block must
# report that rather than fail or pass in silence.
check mermaid-unsupported mermaid rendered 'Rendering not supported for: mermaid'

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "=== ${failures} case(s) failed ==="
    exit 1
fi
echo "=== All cases passed ==="
