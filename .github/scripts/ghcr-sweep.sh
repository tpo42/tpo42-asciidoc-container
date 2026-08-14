#!/bin/bash
# Remove disposable image versions older than a cutoff — the net under the
# branch-deletion cleanup.
#
# Usage: ghcr-sweep.sh <owner> <package> <days>
#
# Catches what the precise mechanism cannot: branches nobody deleted, and the sha- tags
# that belong to no branch at all. Deleting a version removes every tag it carries, so
# anything holding a release tag survives regardless of age.
#
# Two things are old and unprotected without being disposable, and both are untagged: the
# per-architecture children of a live multi-arch tag, and its attestations. Whether an
# untagged version is one of those or a genuine orphan is not visible in the packages
# API — it takes a look at the manifests of everything that survives.
#
# Since ADR-011 that distinction carries the whole job rather than an edge of it: every
# branch push publishes by digest without a tag, and only the merge job tags the list it
# assembles. Untagged is therefore the normal state of both a live architecture manifest
# and the leftovers of a matrix whose sibling cell failed.

set -e
set -u
set -o pipefail

# shellcheck source=./ghcr-common.sh
. "$(dirname "$0")/ghcr-common.sh"

OWNER="$1"
PACKAGE="$2"
DAYS="$3"

rc=0
base="$(ghcr_versions_path "${OWNER}" "${PACKAGE}")" || rc=$?
case "${rc}" in
0) ;;
1)
    echo "package ${OWNER}/${PACKAGE} does not exist — nothing to do"
    exit 0
    ;;
*) exit 1 ;;
esac

# GNU date; this only ever runs on a Linux runner.
cutoff="$(date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
echo "sweeping ${OWNER}/${PACKAGE}, cutoff ${cutoff}"

# One line per version: id, digest, timestamp, tags. The tag field stays *empty* for an
# untagged version. It used to say "<untagged>", which read as an ordinary tag name, was
# duly found unprotected, and made every per-architecture child of a live release tag a
# deletion candidate a week after the release.
versions="$(gh api --paginate "${base}/versions" |
    jq -r '.[] | "\(.id) \(.name) \(.updated_at) \((.metadata.container.tags // []) | join(","))"')"

token="$(ghcr_registry_token "${OWNER}" "${PACKAGE}")" || {
    echo "error: no registry pull token for ${OWNER}/${PACKAGE}" >&2
    exit 1
}

# The classification lives in ghcr-common.sh and is driven from here, so that a suite can
# reach it without a registry. A failure in pass one is fatal on purpose: an unreadable
# manifest means the reference set is incomplete, and an incomplete reference set deletes
# live architecture manifests.
referenced="$(ghcr_referenced_digests "${OWNER}" "${PACKAGE}" "${token}" "${cutoff}" <<<"${versions}")" || exit 1

# The plan is printed before it is executed. On a scheduled job nobody watches, the log is
# the only account of what was removed and why the rest was not.
plan="$(ghcr_sweep_plan "${cutoff}" "${referenced}" <<<"${versions}")"
[[ -n "${plan}" ]] || {
    echo "nothing older than the cutoff"
    exit 0
}
echo "${plan}"

while read -r action id rest; do
    [[ "${action}" == "delete" ]] || continue
    echo "deleting version ${id} (${rest})"
    gh api --method DELETE "${base}/versions/${id}"
done <<<"${plan}"
