# Regression suite for container/resources/validate.sh â one fixture per defect class.
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
#
# Nothing here is shared or writable, so the cases may run concurrently (`--jobs`).

# Run through test/run-suite.bash, never through `bats` directly — the wrapper pins
# the interpreter to /bin/bash. Deliberately carries no shebang and is not executable:
# `#!/usr/bin/env bats` would need bats on PATH, which this repository does not install.

load 'test_helper/adcw'

FIXTURES="test/fixtures/validate"

setup() {
    cd "${REPO_ROOT}" || return 1
}

# The control. Without it a validator that fails on everything would look perfect.
@test "a clean document validates" {
    run ./bin/adcw validate -i "${FIXTURES}/clean.adoc" -l INFO
    assert_success
    assert_output --partial "All files validated successfully"
}

@test "a missing include is an error" {
    run ./bin/adcw validate -i "${FIXTURES}/missing-include.adoc" -l INFO
    assert_failure 1
    assert_output --regexp 'ERROR:.*include file not found'
}

@test "a dropped optional include is reported" {
    run ./bin/adcw validate -i "${FIXTURES}/optional-include.adoc" -l INFO
    assert_failure 1
    assert_output --regexp 'INFO:.*optional include dropped'
}

@test "an unresolved xref is reported" {
    run ./bin/adcw validate -i "${FIXTURES}/unresolved-xref.adoc" -l INFO
    assert_failure 1
    assert_output --regexp 'INFO:.*possible invalid reference'
}

@test "a skipped heading level is reported" {
    run ./bin/adcw validate -i "${FIXTURES}/skipped-heading.adoc" -l INFO
    assert_failure 1
    assert_output --regexp 'WARNING:.*section title out of sequence'
}

# The gap this suite was written for: without the diagram extension asciidoctor only
# parses the block, so a broken diagram reaches DEBUG ("unknown style for listing block")
# and validation passes. Rendering is what turns it into a finding.
@test "a plantuml syntax error fails validation" {
    run ./bin/adcw validate -i "${FIXTURES}/plantuml-syntax-error.adoc" -l INFO
    assert_failure 1
    assert_output --regexp 'ERROR:.*Failed to generate image'
}

# The escape hatch has to actually escape, or --no-diagrams is a comfortable lie.
#
# Three assertions, because exit 0 alone is satisfied by a validator that skipped the
# document entirely â which is the same shape of lie in the other direction. The run has
# to succeed, the renderer must not have run, and the file must be reported as validated.
@test "--no-diagrams skips the renderer without skipping the document" {
    run ./bin/adcw validate -i "${FIXTURES}/plantuml-syntax-error.adoc" -l INFO --no-diagrams
    assert_success
    refute_output --partial "Failed to generate image"
    assert_output --regexp 'Valid files:[[:space:]]+1'
}
