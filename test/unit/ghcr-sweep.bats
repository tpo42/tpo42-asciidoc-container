# The registry sweep, classification only — no network, no gh, no registry.
#
# Run through test/run-suite.bash, never `bats` directly — the wrapper pins the
# interpreter to /bin/bash (ADR-010).
#
# What is being defended here: the sweep deletes published images for a living. Its two
# passes used to sit inline in the script, where nothing could reach them, and the defect
# they carried — untagged per-architecture children of a live multi-arch tag read as
# disposable — survived review twice because "untagged" and "orphaned" look identical in
# the packages API. Since ADR-011 every branch push pushes by digest without a tag, so
# both kinds are permanently present and telling them apart is the whole job.

load '../test_helper/adcw'

setup() {
    # shellcheck source=../../.github/scripts/ghcr-common.sh
    . "${REPO_ROOT}/.github/scripts/ghcr-common.sh"
    CUTOFF="2026-08-07T00:00:00Z"
}

OLD="2026-08-01T00:00:00Z"
NEW="2026-08-13T00:00:00Z"

# `<id> <digest> <updated_at> <tags>`, the shape both passes read.
versions() { printf '%s\n' "$@"; }

# The registry answer, stated per case rather than fetched. Only an index has children;
# anything else prints nothing, which is what a single-architecture manifest looks like.
#
# Values through variables rather than into an `eval`d body: `${var@Q}` would be the tidy
# way to quote them and is bash 4.4, while /bin/bash on macOS is 3.2 — the very reason
# ADR-010 pins the interpreter instead of letting `env bash` find a brewed 5.x.
stub_children() {
    _STUB_INDEX="$1"
    shift
    _STUB_CHILDREN="$*"

    ghcr_child_digests() {
        [[ "$4" == "${_STUB_INDEX}" ]] || return 0
        printf '%s\n' "${_STUB_CHILDREN}"
    }
}

# A registry that cannot be asked — a network error, an expired token, a 5xx. Beside
# stub_children rather than inline in the case, so both fakes live in one place.
#
# Never invoked from this file, and invoked at run time by the code under test — the case
# both checks name as their own exception. Two codes because 0.11 split them: SC2317 for
# the unreachable body, SC2329 for the function nobody calls. The stub above escapes both
# only because its first command is a condition.
stub_children_unreadable() {
    # shellcheck disable=SC2317,SC2329
    ghcr_child_digests() { return 1; }
}

@test "a child of a live release tag is not an orphan" {
    stub_children "sha256:index" "sha256:amd64
sha256:arm64"

    local list referenced
    list="$(versions \
        "1 sha256:index ${OLD} 1.2.3" \
        "2 sha256:amd64 ${OLD} " \
        "3 sha256:arm64 ${OLD} ")"

    referenced="$(ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}")"
    run ghcr_sweep_plan "${CUTOFF}" "${referenced}" <<<"${list}"

    # All three are older than the cutoff and two carry no tag at all. Deleting either
    # leaves 1.2.3 pointing at nothing: the tag stays visible while `docker pull` fails
    # with "manifest unknown", and the job reports success.
    refute_output --partial "delete"
    assert_line --partial "keep 1 carries a protected tag"
    assert_line --partial "keep 2 a surviving index points at"
    assert_line --partial "keep 3 a surviving index points at"
}

@test "an untagged version nothing points at is swept" {
    stub_children "sha256:index" "sha256:amd64"

    local list referenced
    list="$(versions \
        "1 sha256:index ${OLD} 1.2.3" \
        "2 sha256:amd64 ${OLD} " \
        "9 sha256:orphan ${OLD} ")"

    referenced="$(ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}")"
    run ghcr_sweep_plan "${CUTOFF}" "${referenced}" <<<"${list}"

    # The case the sweep exists for since ADR-011: a matrix cell pushed by digest, its
    # sibling failed, so the merge job never tagged anything and the digest is real
    # garbage.
    assert_line "delete 9 untagged"
    assert_line --partial "keep 2"
}

@test "a protected tag outlives the cutoff, a branch tag does not" {
    stub_children "sha256:none"

    local list referenced
    list="$(versions \
        "1 sha256:a ${OLD} latest" \
        "2 sha256:b ${OLD} 0.4" \
        "3 sha256:c ${OLD} v1.2.3" \
        "4 sha256:d ${OLD} feature-something" \
        "5 sha256:e ${OLD} sha-abc123")"

    referenced="$(ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}")"
    run ghcr_sweep_plan "${CUTOFF}" "${referenced}" <<<"${list}"

    assert_line --partial "keep 1 carries a protected tag"
    assert_line --partial "keep 2 carries a protected tag"
    assert_line --partial "keep 3 carries a protected tag"
    assert_line "delete 4 feature-something"
    assert_line "delete 5 sha-abc123"
}

@test "anything younger than the cutoff is left alone" {
    stub_children "sha256:none"

    local list referenced
    list="$(versions \
        "1 sha256:fresh ${NEW} feature-wip" \
        "2 sha256:fresh2 ${NEW} ")"

    referenced="$(ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}")"
    run ghcr_sweep_plan "${CUTOFF}" "${referenced}" <<<"${list}"

    # An untagged digest pushed minutes ago is the normal state between a matrix cell and
    # the merge job that tags it. The age window is what keeps that from being a race.
    assert_output ""
}

@test "an unreadable manifest decides nothing at all" {
    stub_children_unreadable

    local list
    list="$(versions \
        "1 sha256:index ${OLD} 1.2.3" \
        "2 sha256:amd64 ${OLD} ")"

    run ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}"

    # Fail closed. "No children" and "could not ask" are the same bytes on stdout, and the
    # caller deletes on that answer — so the failure has to arrive as an exit code and the
    # script has to stop, rather than proceeding with a reference set that is merely
    # incomplete.
    assert_failure
    assert_output --partial "deciding nothing"
}

@test "a tagged version is protected by any one of its tags" {
    stub_children "sha256:none"

    local list referenced
    list="$(versions \
        "1 sha256:a ${OLD} feature-x,1.2.3" \
        "2 sha256:b ${OLD} feature-y,sha-deadbee")"

    referenced="$(ghcr_referenced_digests o p tok "${CUTOFF}" <<<"${list}")"
    run ghcr_sweep_plan "${CUTOFF}" "${referenced}" <<<"${list}"

    # Deleting a version removes every tag it carries, so one release tag on it makes the
    # whole version untouchable — the branch tag riding along is not a reason to drop it.
    assert_line --partial "keep 1 carries a protected tag"
    assert_line "delete 2 feature-y,sha-deadbee"
}
