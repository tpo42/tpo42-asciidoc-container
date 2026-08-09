# tpo42 mini QA fleet — the fast, non-build checks named in lefthook.yml.
#
# Adapted from tpo42-templates/container/mini.Containerfile. The two repositories carry
# different artefacts, so the fleets differ; this is adaptation, not duplication. There
# is no shared third image, and there will not be one until both requirement sets are
# known well enough to say what it would have to satisfy.
#
# What this repository adds over the templates fleet: shellcheck, shfmt and zsh. Shell
# is the primary artefact here — bin/adcw, bin/adcbw, lib/*.bash and the command scripts
# installed into the delivered container are all shell, and they run on the *host*, not
# inside a container.
#
# Where each tool comes from:
#   gates — pinned upstream releases, whatever the channel: a release binary, pip, a gem.
#           A linter earns its place through the checks it has *newly* learned, and a
#           distribution that optimises for long-term compatibility optimises against
#           exactly that. Which version runs is a decision, and it belongs here.
#   base  — distribution packages: curl, git, jq, file, a shell, the language runtimes.
#           This is what a distribution's promise is actually worth having for.
#
# Fedora rather than Debian for the same reason: it carries current interpreters, which is
# what the gates run on. It buys nothing for the gates themselves — those are pinned above
# the distribution either way.
#
# 44 is the newest stable release; 45 is still pending. The tag pins the release line, not
# the package set — the base image is rebuilt within it, and `update` below takes what has
# landed since. Which is the point: a CVE fixed in the base should not wait for the next
# Fedora.
#
# Domain tools (asciidoctor, asciidoc-linter) are deliberately absent. They need version
# integrity with the documentation build and live in their own images — here that is the
# very image this repository delivers, dispatched through bin/adcw.
#
# The ARG pins below are what a dependency bot would move. Nothing bumps them
# automatically today. Release asset names drift; verify them when bumping. gitleaks
# uses `x64` where everyone else writes `amd64`, and dclint ships a glibc and a musl
# build.

FROM registry.fedoraproject.org/fedora-minimal:44

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- base: what the gates stand on -------------------------------------------
# zsh is here for `zsh -n` on lib/completions/_adcw, and only for that. There is no zsh
# linter to install: shellcheck refuses the dialect outright ("Unknown shell: zsh",
# upstream #809 open since forever), and z-shell/zsh-lint — a Go semantic analyzer,
# actively developed — has published no release binary to date, so wiring it would mean
# building from source. `zsh -n` is a syntax gate, not a linter, and that is the honest
# claim for it.
#
# jq (JSON), file/libmagic (type detection beyond extensions — lefthook matches MIME
# types, which is how the extensionless bin/adcw is caught), git-core (lefthook needs git;
# the -core split leaves out the Perl tooling nothing here calls), curl + ca-certificates
# (to fetch the gates), tar + gzip (to unpack them — fedora-minimal carries neither),
# python3-pip (the runtime the Python gates run on).
#
# --setopt=install_weak_deps=0 is Fedora's equivalent of --no-install-recommends.
RUN microdnf update -y \
    && microdnf install -y --setopt=install_weak_deps=0 \
        ca-certificates \
        curl \
        file \
        git-core \
        gzip \
        jq \
        python3-pip \
        tar \
        zsh \
    && microdnf clean all

# --- gates that are Python programs ------------------------------------------
# In mini.requirements.txt beside this file, so the pins sit where a reader looks for them
# and where a dependency bot can reach them — the same arrangement container/Gemfile has.
# Named for the image it belongs to, since this context builds two.
RUN --mount=type=bind,source=mini.requirements.txt,target=/tmp/requirements.txt,ro \
    pip install --disable-pip-version-check --no-cache-dir --break-system-packages \
        -r /tmp/requirements.txt

# --- gates that ship as release binaries --------------------------------------
ARG SHELLCHECK_VERSION="0.11.0"
ARG SHFMT_VERSION="3.13.1"
ARG EC_VERSION="3.11.1"
ARG ACTIONLINT_VERSION="1.7.12"
ARG GITLEAKS_VERSION="8.30.1"
ARG HADOLINT_VERSION="2.15.1"
ARG DCLINT_VERSION="3.1.0"

# `set -eu` only: pipefail already comes from the SHELL instruction above, and repeating
# it here makes shellcheck read the block as POSIX sh, where the option does not exist.
RUN set -eu; \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.gz" \
        | tar -xz -C /tmp \
    && install -m0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf "/tmp/shellcheck-v${SHELLCHECK_VERSION}"; \
    curl -fsSL -o /tmp/shfmt \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
    && install -m0755 /tmp/shfmt /usr/local/bin/shfmt \
    && rm -f /tmp/shfmt; \
    curl -fsSL "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v${EC_VERSION}/ec-linux-amd64.tar.gz" \
        | tar -xz -C /tmp \
    && install -m0755 /tmp/bin/ec-linux-amd64 /usr/local/bin/ec \
    && rm -rf /tmp/bin; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /tmp actionlint \
    && install -m0755 /tmp/actionlint /usr/local/bin/actionlint \
    && rm -f /tmp/actionlint; \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        | tar -xz -C /tmp gitleaks \
    && install -m0755 /tmp/gitleaks /usr/local/bin/gitleaks \
    && rm -f /tmp/gitleaks; \
    curl -fsSL -o /usr/local/bin/hadolint \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" \
    && chmod 0755 /usr/local/bin/hadolint; \
    curl -fsSL -o /usr/local/bin/dclint \
        "https://github.com/zavoloklom/docker-compose-linter/releases/download/v${DCLINT_VERSION}/dclint-bullseye-amd64" \
    && chmod 0755 /usr/local/bin/dclint

# Fail the build when an asset name drifted, rather than the next commit.
RUN ec --version \
    && actionlint --version \
    && gitleaks version \
    && hadolint --version \
    && dclint --version \
    && shellcheck --version \
    && shfmt --version \
    && zsh --version \
    && yamllint --version \
    && gitlint --version \
    && check-jsonschema --version \
    && mdformat --version \
    && jq --version

# git refuses to operate on a bind-mounted worktree owned by another uid unless it is
# marked safe. The fleet always works on /workspace.
RUN git config --system --add safe.directory /workspace

ARG USER_UID="1000"
ARG USER_GID="1000"
ARG USER_NAME="tpo42"
ARG USER_GROUP_NAME="tpo42"

# The caller's identity, so the formatters can rewrite files the workspace owns.
#
# Two constraints pull against each other here. The numeric ids have to match the host's
# or the bind mount is unwritable — that is the whole point. But everything below 100 is
# reserved for the distribution, and macOS hands every user gid 20, which every
# distribution has already given to something — `games` on Fedora, `dialout` on Debian.
# So: reuse an id that exists, never create one in the reserved range,
# and fall back to running as a bare number when no account can be made for it. Docker
# accepts a numeric USER without a passwd entry; the tools here are linters and read
# their git identity from GIT_CONFIG_* rather than from a home directory.
RUN set -eu; \
    if [ "${USER_GID}" -ge 100 ] && ! getent group "${USER_GID}" >/dev/null 2>&1; then \
        groupadd --gid "${USER_GID}" "${USER_GROUP_NAME}"; \
    fi; \
    if [ "${USER_UID}" -ge 100 ] \
        && ! getent passwd "${USER_UID}" >/dev/null 2>&1 \
        && getent group "${USER_GID}" >/dev/null 2>&1; then \
        useradd --uid "${USER_UID}" --gid "${USER_GID}" \
            --create-home --shell /bin/bash "${USER_NAME}"; \
    fi

# Tools cache under XDG_CACHE_HOME, falling back to $HOME. On the numeric path above
# there is no passwd entry, so HOME is `/` and rubocop dies trying to create /.cache.
# Naming a writable location costs nothing and is what makes that path usable; the image
# is built for one identity, so a shared directory is not a shared-tenant problem.
ENV XDG_CACHE_HOME=/tmp/cache
RUN mkdir -p /tmp/cache && chmod 0777 /tmp/cache

USER ${USER_UID}:${USER_GID}
WORKDIR /workspace
