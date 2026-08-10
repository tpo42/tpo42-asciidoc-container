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

# Pass one — collect what the survivors of this run point at. A version survives if it is
# young enough or carries a protected tag; the children of one being deleted today turn
# into orphans and are swept next week, which is what the schedule is for.
referenced=""
while read -r id digest updated tags; do
    [[ -n "${id}" ]] || continue
    if [[ "${updated}" < "${cutoff}" ]] && ! is_tag_list_protected "${tags}"; then
        continue
    fi
    children="$(ghcr_child_digests "${OWNER}" "${PACKAGE}" "${token}" "${digest}")" || {
        echo "error: cannot read the manifest of ${digest} — deleting nothing" >&2
        exit 1
    }
    referenced+="${children}"$'\n'
done <<<"${versions}"

# Pass two — delete what is old, unprotected and unreferenced.
while read -r id digest updated tags; do
    [[ -n "${id}" ]] || continue
    [[ "${updated}" < "${cutoff}" ]] || continue

    if is_tag_list_protected "${tags}"; then
        echo "keeping version ${id} (${tags}) — carries a protected tag"
        continue
    fi
    if grep -qxF "${digest}" <<<"${referenced}"; then
        echo "keeping version ${id} (${digest}) — a surviving index points at it"
        continue
    fi

    echo "deleting version ${id} (${tags:-untagged})"
    gh api --method DELETE "${base}/versions/${id}"
done <<<"${versions}"
