# Shared harness for the container-backed regression suites.
#
# The suites differ in what they assert, not in how they report it — same image
# resolution, same indented failure blocks, same tally. Holding that once keeps the next
# suite from forking whichever copy it happened to read first, which is how these two
# already ended up with only one of them owning `fail`.
#
# Sourced, never run. The caller sets its own FIXTURES and its own `check`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${ADOC_VERSION:=local}"
export ADOC_VERSION

# Asked of the library rather than rebuilt from the same parts. Reassembling
# "${ADOC_REGISTRY:+…/}${name}:${ADOC_VERSION}" here would be a second place holding the
# same rule, and the copy that drifts is always the one nobody runs — the suites would
# then report against an image the wrapper never pulls.
# shellcheck source=../../lib/adcw-common.bash
. "${REPO_ROOT}/lib/adcw-common.bash"
# The registry default is applied at source time (`: "${ADOC_REGISTRY=…}"`) and bin/adcw
# is a child process, so without the export the suite and the wrapper can disagree about
# which registry the name they each resolved belongs to.
export ADOC_REGISTRY

# Resolve <name> the way the wrapper does, without letting ADOC_IMAGE escape into the
# caller — every case that pins an image wants to pin it itself.
resolve_image() {
    local ADOC_IMAGE=""
    _adcw_resolve_image "$1" || return 1
    printf '%s' "${ADOC_IMAGE}"
}

failures=0

# Prefix every line of a captured block, without piping a variable through sed.
indent() { echo "      | ${1//$'\n'/$'\n'      | }"; }

# fail <reason> [captured block] — report a case and keep going, so one broken case does
# not hide the ones after it.
fail() {
    echo "FAIL: $1"
    shift
    [[ $# -gt 0 ]] && indent "$1"
    failures=$((failures + 1))
    return 0
}

# The tally every suite ends with.
summarize() {
    echo
    if [[ "${failures}" -gt 0 ]]; then
        echo "=== ${failures} case(s) failed ==="
        exit 1
    fi
    echo "=== All cases passed ==="
}
