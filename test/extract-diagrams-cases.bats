# Regression suite for container/resources/extract-diagrams.rb.
#
# Runs through bin/adcw rather than calling the script directly, because that is the
# interface consumers use: the wrapper, the image, the script inside it.
#
# Written after a bug that survived three releases unnoticed: the block finder matched
# only `....` literal blocks, so diagrams written with `----` â the form
# asciidoctor-diagram uses throughout its own documentation â were silently skipped and
# the tool reported "No diagrams found". Nothing was broken; nothing was found either.
# Both delimiters are the first two cases here for that reason.
#
# Two things this suite learned the hard way and now asserts:
#   - the exit code, not only the diagnostic. A failed render used to print a warning and
#     exit 0, so a pipeline gating on this tool was green while diagrams were missing â
#     the very failure mode the toolchain exists to prevent.
#   - the output directory, not only stdout. "Rendered: x.svg" while the file lands
#     somewhere else passed every earlier version of this suite.
#
# Needs the delivered image:
#   ADOC_VERSION=local ./bin/adcbw
# The mermaid render case additionally needs the variant image:
#   ADOC_VERSION=local ./bin/adcbw --with-mermaid
# Without it that one case is skipped. Set ADCW_TEST_REQUIRE_MERMAID=1 to turn the skip
# into a failure â CI does, because a case that only ever skips is not a case.
#
# Every case owns its output directory and shares nothing writable, so the cases may run
# concurrently (`--jobs`). The directory lives under build/ rather than in BATS_TEST_TMPDIR
# because the container only mounts the workspace.

# Run through test/run-suite.bash, never through `bats` directly — the wrapper pins
# the interpreter to /bin/bash. Deliberately carries no shebang and is not executable:
# `#!/usr/bin/env bats` would need bats on PATH, which this repository does not install.

load 'test_helper/adcw'

FIXTURES="test/fixtures/extract-diagrams"

setup() {
    cd "${REPO_ROOT}" || return 1
    # Relative for the container, absolute for the assertions on this side of the mount.
    OUT="$(workspace_tmpdir)"
    OUT_ABS="${REPO_ROOT}/${OUT}"
}

teardown() {
    [[ -n "${OUT_ABS:-}" ]] && rm -rf "${OUT_ABS}"
    return 0
}

# --- The two delimiters, which is what this suite exists for ----------------

@test "a ---- listing block is found" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/listing-block.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "Diagrams found: 1"
    assert_file_count 1 "${OUT_ABS}" '*.plantuml'
}

@test "a .... literal block is found" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/literal-block.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "Diagrams found: 1"
    assert_file_count 1 "${OUT_ABS}" '*.plantuml'
}

# Mixed in one document, so a finder that handles one form by dropping the other cannot
# pass both cases above by accident. Two files, not two *.plantuml: the fixture pairs a
# plantuml block with a graphviz one, and the count is what proves neither was dropped.
@test "both delimiters in one document are found" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/both-blocks.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "Diagrams found: 2"
    assert_file_count 2 "${OUT_ABS}" '*'
}

# Not every absence is a failure: a document without diagrams is a valid document.
# `[source,ruby]` is a listing block too, and must not be mistaken for one.
@test "a document without diagrams is not a failure" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/no-diagrams.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "No diagrams found"
    # Not only stdout: a finder that reported nothing while still writing a file would
    # pass on the message alone, and this suite exists because of a silent mismatch
    # between what was reported and what landed.
    assert_file_count 0 "${OUT_ABS}" '*'
}

# --- Rendering ---------------------------------------------------------------

# Rendering goes through the PlantUML jar the asciidoctor-diagram-plantuml gem carries,
# not through a distribution package. If that resolution breaks, this is where it shows.
@test "plantuml renders through the gem's own jar" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/listing-block.adoc" -o "${OUT}" --format rendered
    assert_success
    assert_output --regexp 'Rendered: .*\.svg'
    assert_file_count 1 "${OUT_ABS}" '*.svg'
}

# One rendered case per entry in SUPPORTED_TYPES, and that is the whole point of them.
# That list is documentation — it answers "which diagrams does this image render out of
# the box?" — and it was assembled from what looked plausible rather than from what the
# image does. It named six types this image cannot render and one that is not a block
# type in any image. A list nobody executes drifts; these two cases plus the plantuml and
# mermaid ones above are what keep it from drifting again.

@test "ditaa renders" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/ditaa.adoc" -o "${OUT}" --format rendered
    assert_success
    assert_output --regexp 'Rendered: .*\.svg'
    assert_file_count 1 "${OUT_ABS}" '*.svg'
}

@test "graphviz renders" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/graphviz.adoc" -o "${OUT}" --format rendered
    assert_success
    assert_output --regexp 'Rendered: .*\.svg'
    assert_file_count 1 "${OUT_ABS}" '*.svg'
}

# C4 is a PlantUML standard library, not a diagram type — which is why `c4plantuml` left
# SUPPORTED_TYPES instead of gaining a renderer. The help text says to write it this way;
# this case is what stops that sentence from being an unchecked claim.
@test "C4 renders as a plantuml block with an include" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/plantuml-c4.adoc" -o "${OUT}" --format rendered
    assert_success
    assert_output --regexp 'Rendered: .*\.svg'
    assert_file_count 1 "${OUT_ABS}" '*.svg'
}

# The extractable list is read out of asciidoctor-diagram at startup, not transcribed
# from its documentation. Both names below are things a hand-written list would not
# contain: `qrcode` because the docs mention `barcode` once while the extension registers
# every symbology separately, and `tape` because that is the block name vhs registers
# under. If either disappears, the list has been replaced by a copy — which is how it
# drifted the first time.
@test "the extractable list comes from the extension, not from a copy" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/no-diagrams.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "qrcode"
    assert_output --partial "tape"
}

# A block id becomes the stem of the files extracted from it, and `arch/overview` is an id
# somebody writes without a second thought. Joined onto the output directory it names a
# subdirectory that does not exist, and the extraction yields nothing — for a document
# nothing is wrong with.
#
# Every component survives; only the separator changes. Keeping the last component alone
# would be shorter and wrong: it merges ids that differ, which the next case is about.
@test "a slash in a block id is a filename, not a path" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/slash-in-id.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "Diagrams found: 1"

    # Directly in the output directory, under a name that still says which id it came from.
    assert_file_count 1 "${OUT_ABS}" '*.plantuml'
    [[ -e "${OUT_ABS}/arch_overview.plantuml" ]] || fail "not written under the flattened name"
}

# Keeping every component separates the ids a document actually carries. What it cannot
# separate is a slash meeting the underscore it becomes — the residual case. It has to
# fail loudly rather than quietly drop one of the two, which is what overwriting did.
@test "two ids that normalise to one name stop the run" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/colliding-ids.adoc" -o "${OUT}" --format source
    assert_failure

    # Both ids named, so the document author knows which two to change.
    assert_output --partial "arch/overview"
    assert_output --partial "would be written as 'arch_overview'"

    # Nothing written at all: the names are decided before the first file, so a later step
    # reading the directory cannot find a partial result beside a non-zero exit.
    assert_file_count 0 "${OUT_ABS}" '*.plantuml'
}

# The two lists, and why they are two. Extraction needs no renderer, so a type this image
# cannot draw is still worth pulling out — that is what the tool is for. Collapsing the
# lists into one would take the source with the picture.

@test "a type this image cannot render is still extracted" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/structurizr.adoc" -o "${OUT}" --format source
    assert_success
    assert_output --partial "Diagrams found: 1"
    assert_file_count 1 "${OUT_ABS}" '*.structurizr'
}

@test "a type this image cannot render says so under --format rendered" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/structurizr.adoc" -o "${OUT}" --format rendered
    assert_failure 1
    assert_output --partial "Cannot render structurizr"
    assert_file_count 0 "${OUT_ABS}" '*.svg'
}

# The silent pass this suite was extended for: a renderer that fails must fail the run.
# Exit code first, message second â a warning on stdout is what the old version did. And
# no file, which is how "the renderer refused" is told apart from "the renderer wrote a
# broken file and said nothing".
@test "a failed render fails the run and writes nothing" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/plantuml-syntax-error.adoc" -o "${OUT}" --format rendered
    assert_failure 1
    assert_output --partial "Failed to render"
    assert_file_count 0 "${OUT_ABS}" '*.svg'
}

# A renderer that is not in *this* image is the same class of failure, and must not be
# reported as a note. The message has to name the image that does carry it, because
# "cannot render mermaid" without a remedy sends the reader nowhere.
@test "mermaid in the base image names the image that can render it" {
    run ./bin/adcw extract-diagrams -i "${FIXTURES}/mermaid.adoc" -o "${OUT}" --format rendered
    assert_failure 1
    assert_output --regexp 'Cannot render mermaid.*adoc-with-mermaid'
    assert_file_count 0 "${OUT_ABS}" '*.svg'
}

# The mermaid renderer itself, in the image that has it.
#
# Asking the wrapper rather than a runtime directly: `--help` reaches the image the same
# way a real case does, so a missing image, a wrong tag and an unusable runtime all answer
# here rather than halfway through the case.
@test "mermaid renders in the variant image" {
    local mermaid_image
    mermaid_image="$(resolve_image adoc-with-mermaid)"

    if ! ADOC_IMAGE="${mermaid_image}" ./bin/adcw extract-diagrams --help >/dev/null 2>&1; then
        if [[ -n "${ADCW_TEST_REQUIRE_MERMAID:-}" ]]; then
            fail "${mermaid_image} unavailable while ADCW_TEST_REQUIRE_MERMAID is set â build it with: ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
        fi
        skip "${mermaid_image} not built â ADOC_VERSION=${ADOC_VERSION} ./bin/adcbw --with-mermaid"
    fi

    ADOC_IMAGE="${mermaid_image}" run ./bin/adcw extract-diagrams \
        -i "${FIXTURES}/mermaid.adoc" -o "${OUT}" --format rendered
    assert_success
    assert_output --regexp 'Rendered: .*\.svg'
    assert_file_count 1 "${OUT_ABS}" '*.svg'
}
