#!/bin/bash
# Shared helpers for the GHCR cleanup scripts. Sourced, not executed.

# Never delete a version carrying one of these: `latest`, or anything shaped like a
# version number. Everything else — branch names, sha- tags — is disposable.
is_protected() {
    local tag="$1"
    [[ "${tag}" == "latest" ]] && return 0
    [[ "${tag}" =~ ^v?[0-9]+(\.[0-9]+)*$ ]] && return 0
    return 1
}

# True when a comma-separated tag list carries at least one protected tag. An empty list
# is not protected — an untagged version makes no promise to anyone by itself. Whether it
# is nonetheless load-bearing is a question about references, answered further down.
is_tag_list_protected() {
    local tags="$1" t
    local -a tag_list
    [[ -z "${tags}" ]] && return 1
    IFS=',' read -r -a tag_list <<<"${tags}"
    for t in "${tag_list[@]}"; do
        is_protected "${t}" && return 0
    done
    return 1
}

# A short-lived pull token for the registry. The versions endpoint used everywhere else
# is the GitHub packages API; manifests live in the registry, which is a separate service
# with its own authentication.
# Registry paths are lowercase; an owner login is not necessarily. `tr` rather than
# ${var,,} because that is bash 4, and the bash shipping with macOS is 3.2 — these
# scripts only ever run on a Linux runner, but a maintainer debugging one should not
# discover that the hard way.
ghcr_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

ghcr_registry_token() {
    local owner package token
    owner="$(ghcr_lower "$1")"
    package="$(ghcr_lower "$2")"
    token="$(curl -fsSL -u "x-access-token:${GH_TOKEN}" \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:${owner}/${package}:pull" |
        jq -r '.token')" || return 1
    [[ -n "${token}" && "${token}" != "null" ]] || return 1
    printf '%s' "${token}"
}

# Print the digests a version references, one per line; nothing for a single-arch image.
#
# A multi-arch tag is an index whose per-architecture children carry no tags of their
# own. Through the packages API those children look exactly like the orphans a sweep
# exists to reap — deleting one leaves the index in place and pointing at nothing, so the
# tag stays visible in the registry while `docker pull` fails with "manifest unknown".
#
# Fails rather than printing nothing when the manifest cannot be read. "No children" and
# "could not ask" must not collapse into the same answer: the caller deletes on it.
ghcr_child_digests() {
    local owner package token="$3" ref="$4" body
    owner="$(ghcr_lower "$1")"
    package="$(ghcr_lower "$2")"
    body="$(curl -fsSL \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/${owner}/${package}/manifests/${ref}")" || return 1
    printf '%s\n' "${body}" | jq -r '.manifests[]?.digest // empty'
}

# The HTTP status of a GET, as three digits.
ghcr_status() {
    gh api --include "$1" 2>/dev/null | head -1 | awk '{print $2}'
}

# Print the API base for ${1}/${2}, or fail.
#
# Organisations and users have different endpoints, and a fork's package sits under a
# user, so both are tried. The status is read rather than just the exit code, because
# the two failures mean opposite things: 404 is a package that does not exist, which is
# the normal state of a fresh fork and a legitimate "nothing to do". Anything else — a
# token without `read:packages` being the likely one — is a problem, and a cleanup job
# that swallows it reports success forever while the registry fills up.
#
# Exit codes: 0 found, 1 absent everywhere, 2 something to report.
ghcr_versions_path() {
    local owner="$1" package="$2" scope status
    for scope in orgs users; do
        status="$(ghcr_status "/${scope}/${owner}/packages/container/${package}/versions")"
        case "${status}" in
        200)
            printf '/%s/%s/packages/container/%s' "${scope}" "${owner}" "${package}"
            return 0
            ;;
        404) ;;
        *)
            echo "error: /${scope}/… answered ${status:-<no status>} for ${owner}/${package}" >&2
            return 2
            ;;
        esac
    done
    return 1
}

# --- The sweep, in two passes -------------------------------------------------
#
# Both read the same version list on stdin, one line per version:
#
#     <id> <digest> <updated_at> <comma-separated tags or empty>
#
# They are functions rather than inline loops so a suite can drive them without a
# registry: the classification is where the damage happens, and it was the part that
# could not be reached from a test while it sat in the middle of the script.

# Pass one — every digest a survivor of this run points at, one per line.
#
# A version survives if it is young enough or carries a protected tag. The children of
# one being deleted today become orphans and are swept next time, which is what the
# schedule is for.
#
# Fails without printing a partial answer when a manifest cannot be read. The caller
# deletes on this output, so "no children" and "could not ask" must not look alike.
ghcr_referenced_digests() {
    local owner="$1" package="$2" token="$3" cutoff="$4"
    local id digest updated tags children

    while read -r id digest updated tags; do
        [[ -n "${id}" ]] || continue
        if [[ "${updated}" < "${cutoff}" ]] && ! is_tag_list_protected "${tags}"; then
            continue
        fi
        children="$(ghcr_child_digests "${owner}" "${package}" "${token}" "${digest}")" || {
            echo "error: cannot read the manifest of ${digest} — deciding nothing" >&2
            return 1
        }
        [[ -n "${children}" ]] && printf '%s\n' "${children}"
    done
    return 0
}

# Pass two — the plan, one line per version, as `keep <id> <why>` or `delete <id> <what>`.
#
# Deliberately data rather than action: nothing here talks to the registry, so the whole
# decision can be asserted in a test, and the caller stays a loop that executes a plan it
# can also just print.
ghcr_sweep_plan() {
    local cutoff="$1" referenced="$2"
    local id digest updated tags

    while read -r id digest updated tags; do
        [[ -n "${id}" ]] || continue
        [[ "${updated}" < "${cutoff}" ]] || continue

        if is_tag_list_protected "${tags}"; then
            echo "keep ${id} carries a protected tag (${tags})"
        elif grep -qxF "${digest}" <<<"${referenced}"; then
            echo "keep ${id} a surviving index points at ${digest}"
        else
            echo "delete ${id} ${tags:-untagged}"
        fi
    done
}

# Delete every version id read from stdin, unless it carries a protected tag.
# Input lines: "<id> <comma-separated tags>"
ghcr_delete_unprotected() {
    local base="$1" id tags
    while read -r id tags; do
        if is_tag_list_protected "${tags}"; then
            echo "keeping version ${id} (${tags}) — carries a protected tag"
            continue
        fi

        echo "deleting version ${id} (${tags})"
        gh api --method DELETE "${base}/versions/${id}"
    done
}
