# What BATS cannot know: containers, images, and this repository.
#
# Everything generic — assertions, per-test isolation, temp directories, reporting —
# comes from bats-assert and bats-core. What is left here is domain knowledge, and that
# is the only thing this file is allowed to grow.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

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

# A scratch directory inside the workspace, because the container only sees that; build/
# is where adcw already puts generated things. One per case rather than one per file,
# which is what lets the suites run concurrently.
#
# The path is returned *relative to the repository root*, and that is not cosmetic: it is
# handed to a command running inside the container, where the workspace sits at a
# different absolute location. An absolute host path reaches the container as a directory
# it may not create, and the failure arrives as a Ruby EACCES backtrace rather than as
# anything about paths.
workspace_tmpdir() {
    mkdir -p "${REPO_ROOT}/build"
    (cd "${REPO_ROOT}" && mktemp -d "build/.bats.XXXXXX")
}

# assert_file_count <expected> <directory> <glob>
#
# "It produced something" is rarely the claim being made: a renderer that writes one file
# where two were asked for, and one that writes a broken file where none was right, both
# pass a bare existence check. Zero is a first-class expectation here.
assert_file_count() {
    local want="$1" dir="$2" pattern="$3"

    local -a produced
    shopt -s nullglob
    # SC2206: the missing quotes are the point — ${pattern} is a glob and has to expand.
    # nullglob makes an empty result an empty array rather than the literal.
    # shellcheck disable=SC2206
    produced=("${dir}/"${pattern})
    shopt -u nullglob

    if [[ ${#produced[@]} -ne "${want}" ]]; then
        batslib_print_kv_single_or_multi 8 \
            'pattern' "${pattern}" \
            'expected' "${want}" \
            'found' "${#produced[@]}" |
            batslib_decorate 'file count differs' |
            fail
    fi
}
