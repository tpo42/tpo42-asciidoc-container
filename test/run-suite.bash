#!/bin/bash
# Run a BATS suite against the system bash, whatever else is on PATH.
#
# The shim is the whole reason this wrapper exists. `bats` and every one of its helpers
# carry `#!/usr/bin/env bash`, so they run under the *first* bash on PATH — a brewed 5.x
# on a good many macOS boxes, and on the GitHub macOS runner. The unit suite sources
# bin/adcw, and sourcing bypasses its `#!/bin/bash` shebang: whichever shell sources the
# file is the shell that parses it. Without the shim a bash 4 construct would pass here
# and break for every macOS user, which is precisely the failure these suites exist to
# catch. With it, `env bash` resolves to /bin/bash throughout the bats process tree.
#
# One spelling for local and CI, so the two cannot drift.
#
# Deliberately not `--jobs`: the suites are written to run concurrently — each case owns
# its output directory and shares nothing writable — but turning it on costs a GNU
# parallel dependency nobody has asked for yet. It is a flag away, not a rewrite away.

set -e -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# All three, not just the runner: test_helper/adcw.bash loads bats-support and
# bats-assert, and a missing one of those surfaces much later as an opaque `load`
# failure in the middle of a run rather than as a missing checkout here.
if [[ ! -x "${SCRIPT_DIR}/bats/bin/bats" ]] ||
    [[ ! -f "${SCRIPT_DIR}/test_helper/bats-support/load.bash" ]] ||
    [[ ! -f "${SCRIPT_DIR}/test_helper/bats-assert/load.bash" ]]; then
    echo "the test submodules are not checked out." >&2
    echo >&2
    echo "  git submodule update --init --recursive" >&2
    exit 1
fi

# Refused rather than worked around: /bin/bash is what bin/adcw runs under in the field,
# so a box without it would be testing a different interpreter than it ships to.
if [[ ! -x /bin/bash ]]; then
    echo "/bin/bash is missing — cannot pin the suites to the system bash." >&2
    exit 1
fi

shim="$(mktemp -d)"
trap 'rm -rf "${shim}"' EXIT
ln -s /bin/bash "${shim}/bash"

cd "${REPO_ROOT}"
PATH="${shim}:${PATH}" "${SCRIPT_DIR}/bats/bin/bats" "$@"
