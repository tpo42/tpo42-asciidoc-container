#!/bin/bash
# mmdc with a working default, installed in front of the one npm provides.
#
# Chromium refuses to start inside a container without its sandbox, and the sandbox
# needs privileges a container should not be given (ADR-008). --no-sandbox is the
# ordinary trade here: the container is the isolation boundary. Rather than expecting
# every consumer to discover a Puppeteer configuration file, the image ships one and
# passes it.
#
# Our -p comes first, so an explicit -p from the caller — asciidoctor-diagram passes one
# when :mermaid-puppeteer-config: is set — lands later on the command line and wins.

set -e
set -u
set -o pipefail

# Chromium writes a profile, a cache and a crash database while starting. adcw runs the
# container as the invoking uid, which has no passwd entry in the image, so HOME points
# somewhere unwritable and the crashpad handler is spawned without its --database — the
# browser then never comes up. Visible on a GitHub runner, masked by Docker Desktop.
#
# Per uid rather than a fixed path: in compose and devcontainer mode the container is
# long-lived and shared, and a directory owned by someone else fails the same way.
_adcw_chromium_home="${TMPDIR:-/tmp}/chromium-$(id -u)"
mkdir -p "${_adcw_chromium_home}"
export XDG_CONFIG_HOME="${_adcw_chromium_home}"
export XDG_CACHE_HOME="${_adcw_chromium_home}"

exec /usr/local/bin/mmdc-real -p /etc/tpo42/puppeteer.json "$@"
