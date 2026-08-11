#!/bin/bash
# Regression suite for container/resources/extract-diagrams.rb.
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
# Two things this suite learned the hard way and now asserts:
#   - the exit code, not only the diagnostic. A failed render used to print a warning
#     and exit 0, so a pipeline gating on this tool was green while diagrams were
#     missing — the very failure mode the toolchain exists to prevent.
#   - the output directory, not only stdout. "Rendered: x.svg" while the file lands
#     somewhere else passed every earlier version of this suite.
#
# Needs the delivered image:
#   ADOC_VERSION=local ./bin/adcbw
# The mermaid render case additionally needs the variant image:
#   ADOC_VERSION=local ./bin/adcbw --with-mermaid
# Without it that one case is skipped locally. Set ADCW_TEST_REQUIRE_MERMAID=1 to turn
# the skip into a failure — CI does, because a case that only ever skips is not a case.

set -e
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="test/fixtures/extract-diagrams"

: "${ADOC_VERSION:=local}"
export ADOC_VERSION
: "${ADCW_TEST_REQUIRE_MERMAID:=}"

# Asked of the library rather than rebuilt from the same parts. Reassembling
# "${ADOC_REGISTRY:+…/}${name}:${ADOC_VERSION}" here would be a second place holding the
# same rule, and the copy that drifts is always the one nobody runs — the suite would
# then report against an image the wrapper never pulls.
# shellcheck source=../lib/adcw-common.bash
. "${REPO_ROOT}/lib/adcw-common.bash"
export ADOC_REGISTRY

resolve_image() {
    local ADOC_IMAGE=""
    _adcw_resolve_image "$1" || return 1
    printf '%s' "${ADOC_IMAGE}"
}

ADOC_BASE_IMAGE="$(resolve_image adoc)"
MERMAID_IMAGE="$(resolve_image adoc-with-mermaid)"

cd "${REPO_ROOT}"

# Output goes into the workspace because the container only sees that; build/ is where
# adcw already puts generated things, and the trap takes it away again.
mkdir -p build
OUT="$(mktemp -d build/.extract-cases.XXXXXX)"
trap 'rm -rf "${OUT}"' EXIT

failures=0

indent() { echo "      | ${1//$'\n'/$'\n'      | }"; }

fail() {
    echo "FAIL: $1"
    shift
    [[ $# -gt 0 ]] && indent "$1"
    failures=$((failures + 1))
}

# case <label> <fixture> <format> <want_rc> <diagnostic regex> [want_glob] [image]
#
# want_glob is checked against the case's own output directory, in three shapes:
#   '*.svg'    at least one match
#   '2:*.svg'  exactly two — "it produced something" is not the claim being made
#   '!*.svg'   none, which is how "the renderer refused" is told apart from
#              "the renderer wrote a broken file and said nothing"
check() {
    local label="$1" fixture="$2" format="$3" want_rc="$4" want_pattern="$5"
    local want_glob="${6:-}" image="${7:-}"
    local output rc=0

    printf '%-28s ' "${label}"

    output="$(
        [[ -n "${image}" ]] && export ADOC_IMAGE="${image}"
        ./bin/adcw extract-diagrams -i "${FIXTURES}/${fixture}.adoc" \
            -o "${OUT}/${label}" --format "${format}" 2>&1
    )" || rc=$?

    if [[ "${rc}" -ne "${want_rc}" ]]; then
        fail "exited ${rc}, expected ${want_rc}" "${output}"
        return 0
    fi

    if ! echo "${output}" | grep -qE "${want_pattern}"; then
        fail "no match for /${want_pattern}/" "${output}"
        return 0
    fi

    if [[ -n "${want_glob}" ]]; then
        local pattern="${want_glob}" want_count=""
        case "${want_glob}" in
        !*) # nothing may match
            pattern="${want_glob#!}"
            want_count=0
            ;;
        [0-9]*:*) # exactly this many
            want_count="${want_glob%%:*}"
            pattern="${want_glob#*:}"
            ;;
        esac

        local -a produced=()
        shopt -s nullglob
        # SC2206: the missing quotes are the point — ${pattern} is a glob and has to
        # expand. nullglob makes an empty result an empty array rather than the literal.
        # shellcheck disable=SC2206
        produced=("${OUT}/${label}/"${pattern})
        shopt -u nullglob

        if [[ -n "${want_count}" ]]; then
            if [[ ${#produced[@]} -ne "${want_count}" ]]; then
                fail "expected exactly ${want_count} ${pattern}, found ${#produced[@]}" "${output}"
                return 0
            fi
        elif [[ ${#produced[@]} -eq 0 ]]; then
            fail "no file matching ${pattern} in the output directory" "${output}"
            return 0
        fi
    fi

    echo "PASS"
}

echo "=== extract-diagrams regression suite (image ${ADOC_BASE_IMAGE}) ==="

# The two delimiters, which is what this suite exists for.
check listing-block listing-block source 0 'Diagrams found: 1' '1:*.plantuml'
check literal-block literal-block source 0 'Diagrams found: 1' '1:*.plantuml'

# Mixed in one document, so a finder that handles one form by dropping the other cannot
# pass both cases above by accident. Two files, not two *.plantuml: the fixture pairs a
# plantuml block with a graphviz one, and the count is what proves neither was dropped.
check both-delimiters both-blocks source 0 'Diagrams found: 2' '2:*'

# Not every absence is a failure: a document without diagrams is a valid document.
# `[source,ruby]` is a listing block too, and must not be mistaken for one.
check no-diagrams no-diagrams source 0 'No diagrams found'

# Rendering goes through the PlantUML jar the asciidoctor-diagram-plantuml gem carries,
# not through a distribution package. If that resolution breaks, this is where it shows.
check plantuml-render listing-block rendered 0 'Rendered: .*\.svg' '1:*.svg'

# The silent pass this suite was extended for: a renderer that fails must fail the run.
# Exit code first, message second — a warning on stdout is what the old version did.
check plantuml-broken broken-plantuml rendered 1 'Failed to render' '!*.svg'

# A renderer that is not in *this* image is the same class of failure, and must not be
# reported as a note. The message has to name the image that does carry it, because
# "cannot render mermaid" without a remedy sends the reader nowhere.
check mermaid-unsupported mermaid rendered 1 'Cannot render mermaid.*adoc-with-mermaid' '!*.svg'

# The mermaid renderer itself, in the image that has it. Skipped when that image is
# absent — unless ADCW_TEST_REQUIRE_MERMAID says the skip is a failure, which is how CI
# runs it.
# Asking the wrapper rather than a runtime directly: `--help` reaches the image the same
# way a real case does, so a missing image, a wrong tag and an unusable runtime all
# answer here rather than halfway through the case below.
if ADOC_IMAGE="${MERMAID_IMAGE}" ./bin/adcw extract-diagrams --help >/dev/null 2>&1; then
    check mermaid-render mermaid rendered 0 'Rendered: .*\.svg' '1:*.svg' "${MERMAID_IMAGE}"
elif [[ -n "${ADCW_TEST_REQUIRE_MERMAID}" ]]; then
    printf '%-28s ' "mermaid-render"
    fail "${MERMAID_IMAGE} unavailable while ADCW_TEST_REQUIRE_MERMAID is set" \
        "build it with: ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
else
    printf '%-28s ' "mermaid-render"
    echo "SKIP: ${MERMAID_IMAGE} not built"
    indent "ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
fi

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "=== ${failures} case(s) failed ==="
    exit 1
fi
echo "=== All cases passed ==="
