# Image resolution: ADOC_VERSION, ADOC_REGISTRY and ADOC_IMAGE, and how they compose.
#
# Run through test/run-suite.bash, never `bats` directly — the wrapper pins the
# interpreter to /bin/bash (ADR-010).

load '../test_helper/adcw'

# Resolve in a *freshly sourced* library, because the registry default is applied once at
# source time (`: "${ADOC_REGISTRY=…}"`). Re-using the copy this suite already loaded
# would test the environment it happened to start in, not the resolution.
#
# ${1} is the image name; everything after it is VAR=value for the child's environment.
resolve_image_fresh() {
    local name="$1"
    shift
    # Single quotes on purpose: $1, $2 and ADOC_IMAGE belong to the child bash, which is
    # the process that sources the library under the controlled environment.
    # shellcheck disable=SC2016
    env -u ADOC_IMAGE -u ADOC_VERSION -u ADOC_REGISTRY -u ADOC_PROJECT_HOME "$@" \
        bash -c 'set -u; . "$1"; _adcw_resolve_image "$2"; printf "%s" "${ADOC_IMAGE}"' \
        bash "${REPO_ROOT}/lib/adcw-common.bash" "${name}"
}

@test "version and registry compose into the image reference" {
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3)" \
        "ghcr.io/tpo42/adoc:1.2.3"

    assert_equal "$(resolve_image_fresh adoc-with-mermaid ADOC_VERSION=1.2.3)" \
        "ghcr.io/tpo42/adoc-with-mermaid:1.2.3"

    # A mirror, or a house image beside the upstream one — the reason ADOC_REGISTRY exists
    # at all (UC-004).
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.registry.internal/team)" \
        "my.registry.internal/team/adoc:1.2.3"
}

@test "an explicitly empty registry yields a bare local name" {
    # It has to survive: the default was once assigned with `:=`, which fires on empty as
    # well as unset, so this could not be expressed at all. CI names its test images this
    # way.
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=ci-abc123 ADOC_REGISTRY=)" \
        "adoc:ci-abc123"
}

@test "ADOC_IMAGE overrides version and registry together" {
    assert_equal "$(resolve_image_fresh adoc ADOC_VERSION=1.2.3 ADOC_REGISTRY=my.reg ADOC_IMAGE=example.org/other/thing:9)" \
        "example.org/other/thing:9"
}

@test "nothing set anywhere falls back to latest" {
    # No version, and no checkout to derive one from.
    assert_equal "$(resolve_image_fresh adoc)" "ghcr.io/tpo42/adoc:latest"
}
