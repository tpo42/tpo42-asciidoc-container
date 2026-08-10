#!/bin/bash
# Delete one tag from a GHCR package — the image of a branch that no longer exists.
#
# Usage: ghcr-delete-tag.sh <owner> <package> <tag>
#
# Deleting a *version* removes every tag it carries, so a version that also carries a
# release tag is left alone even when the branch tag matches. A cleanup job that can
# take down a release is a liability, not housekeeping.

set -e
set -u
set -o pipefail

# shellcheck source=./ghcr-common.sh
. "$(dirname "$0")/ghcr-common.sh"

OWNER="$1"
PACKAGE="$2"
TAG="$3"

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

gh api --paginate "${base}/versions" |
    jq -r --arg tag "${TAG}" \
        '.[] | select(.metadata.container.tags | index($tag)) | "\(.id) \(.metadata.container.tags | join(","))"' |
    ghcr_delete_unprotected "${base}"
