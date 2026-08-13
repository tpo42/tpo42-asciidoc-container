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
