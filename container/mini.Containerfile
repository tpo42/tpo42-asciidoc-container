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

# --- builder: what has to be compiled -----------------------------------------
#
# rubocop's dependency tree carries native extensions — json, racc and prism ship no
# prebuilt gem for this platform. The compiler that installs them is of no use afterwards,
# so it lives in a stage that is discarded. Same base image, therefore the same Ruby ABI,
# which is what makes copying built extensions legitimate rather than lucky.
#
# Staged the way a package build stages one, which for rubygems means constructing the
# path rather than setting a variable it reads: --install-dir and --bindir point at
# <staging><final path>, and --env-shebang keeps the builder's absolute ruby out of the
# binstub. This is the shape Yocto's ruby.bbclass uses.
#
# A prefix of its own, and --install-dir rather than GEM_HOME, so the compiled extensions
# stay beside the gem that owns them: Fedora's rubygems keeps those under lib64 for its
# *default* directories, and only for those.
FROM registry.fedoraproject.org/fedora-minimal:44 AS builder

ARG RUBOCOP_VERSION="1.89.0"

RUN microdnf update -y \
    && microdnf install -y --setopt=install_weak_deps=0 \
        gcc \
        make \
        redhat-rpm-config \
        ruby \
        ruby-devel \
        rubygems \
    && microdnf clean all

RUN mkdir -p /opt/staging \
    && gem install --no-document --env-shebang \
        --install-dir /opt/staging/opt/gems \
        --bindir /opt/staging/usr/local/bin \
        rubocop -v "${RUBOCOP_VERSION}"

# --- the fleet ----------------------------------------------------------------
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
# python3-pip and ruby (the runtimes the Python and Ruby gates run on — the runtimes, not
# the gates themselves).
#
# --setopt=install_weak_deps=0 is Fedora's equivalent of --no-install-recommends, and
# rubypick and rubygems are what it costs: Fedora's `ruby` package installs
# /usr/bin/ruby-mri and only *recommends* the stub that provides the plain /usr/bin/ruby,
# and it recommends rubygems rather than requiring it. Without the two, a gem's
# `#!/usr/bin/env ruby` finds nothing, and finding ruby then fails on `require "rubygems"`.
RUN microdnf update -y \
    && microdnf install -y --setopt=install_weak_deps=0 \
        ca-certificates \
        curl \
        file \
        git-core \
        gzip \
        jq \
        python3-pip \
        ruby \
        rubypick \
        rubygems \
        tar \
        zsh \
    && microdnf clean all

# --- gates that ship as gems --------------------------------------------------
# Built in the builder stage and copied in without the toolchain that built them. The
# executables land in /usr/local/bin, which is already on PATH; GEM_HOME is what ruby
# needs to find the library beside them.
ENV GEM_HOME=/opt/gems
COPY --from=builder /opt/staging/ /

# --- gates that are Python programs ------------------------------------------
# In mini.requirements.txt beside this file, so the pins sit where a reader looks for them
# and where a dependency bot can reach them — the same arrangement container/Gemfile has.
# Named for the image it belongs to, since this context builds two.
RUN --mount=type=bind,source=mini.requirements.txt,target=/tmp/requirements.txt,ro \
    pip install --disable-pip-version-check --no-cache-dir --break-system-packages \
        -r /tmp/requirements.txt

# --- gates that ship as release binaries --------------------------------------
#
# Version and digest belong to each other and move together. Where a project publishes a
# checksum file beside its release, the digest is read from there — not computed from the
# download, which would only assert that the bytes are the bytes that arrived. ec,
# actionlint, gitleaks and hadolint do.
#
# shellcheck, shfmt and dclint publish none. Theirs are self-computed and carry less: they
# pin the artefact against a later change without vouching for the first fetch. Written
# down anyway, because that is still the difference between a silent substitution and a
# failed build.
#
# The build stops on a mismatch. That covers a tampered download and, just as usefully, a
# release re-cut under the same tag: either way the image is not built rather than built
# from something nobody reviewed.
# A digest belongs to one artefact, and an artefact is per architecture — so every pin is
# a pair. The alternative, resolving a digest at build time, is what the pin exists to
# prevent.
#
# The asset names do not agree on what to call an architecture: Go projects use GOARCH
# (amd64/arm64) and are named from TARGETARCH directly, while shellcheck says
# x86_64/aarch64, gitleaks says x64, and hadolint says x86_64. Those three are mapped
# below rather than papered over.
ARG SHELLCHECK_VERSION="0.11.0"
ARG SHELLCHECK_SHA256_AMD64="b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"
ARG SHELLCHECK_SHA256_ARM64="68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc"
ARG SHFMT_VERSION="3.13.1"
ARG SHFMT_SHA256_AMD64="fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1"
ARG SHFMT_SHA256_ARM64="32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7"
ARG EC_VERSION="3.11.1"
ARG EC_SHA256_AMD64="5a37922963248451e88149251e49f6ae08f69717a3918202a51fe9945e19691e"
ARG EC_SHA256_ARM64="073d5263f0c5953f3e847df44a84403ecc284ab77419de56e280ab92bc082e8d"
ARG ACTIONLINT_VERSION="1.7.12"
ARG ACTIONLINT_SHA256_AMD64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ARG ACTIONLINT_SHA256_ARM64="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"
ARG GITLEAKS_VERSION="8.30.1"
ARG GITLEAKS_SHA256_AMD64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
ARG GITLEAKS_SHA256_ARM64="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
ARG HADOLINT_VERSION="2.15.1"
ARG HADOLINT_SHA256_AMD64="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"
ARG HADOLINT_SHA256_ARM64="f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d"
# docker-compose-linter publishes no checksum file, so this one is self-computed and
# carries less: it pins the artefact against a later change, but says nothing about
# whether the first download was genuine. The project also ships on npm, whose registry
# does publish integrity metadata — a second distribution channel, at the price of node
# in this image. Recorded rather than decided.
ARG DCLINT_VERSION="3.1.0"
ARG DCLINT_SHA256_AMD64="5834586af5d3a5d3721dbb781cd87b4193e498f53671562864ca15567d1d42ac"
ARG DCLINT_SHA256_ARM64="ea58b5392e8c47c849b93028455d6df1a711b361ef49a870defa6b77b178e8ff"

# Supplied by BuildKit; declaring it is what brings it into scope.
ARG TARGETARCH

# `set -eu` only: pipefail already comes from the SHELL instruction above, and repeating
# it here makes shellcheck read the block as POSIX sh, where the option does not exist.
#
# Downloaded to a file rather than piped into tar, because a pipe has consumed the bytes
# by the time there is anything to check them against.
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) sc_arch=x86_64;  gl_arch=x64;   hl_arch=x86_64; \
               sc_sha="${SHELLCHECK_SHA256_AMD64}"; sf_sha="${SHFMT_SHA256_AMD64}"; \
               ec_sha="${EC_SHA256_AMD64}";         al_sha="${ACTIONLINT_SHA256_AMD64}"; \
               gl_sha="${GITLEAKS_SHA256_AMD64}";   hl_sha="${HADOLINT_SHA256_AMD64}"; \
               dc_sha="${DCLINT_SHA256_AMD64}" ;; \
        arm64) sc_arch=aarch64; gl_arch=arm64; hl_arch=arm64; \
               sc_sha="${SHELLCHECK_SHA256_ARM64}"; sf_sha="${SHFMT_SHA256_ARM64}"; \
               ec_sha="${EC_SHA256_ARM64}";         al_sha="${ACTIONLINT_SHA256_ARM64}"; \
               gl_sha="${GITLEAKS_SHA256_ARM64}";   hl_sha="${HADOLINT_SHA256_ARM64}"; \
               dc_sha="${DCLINT_SHA256_ARM64}" ;; \
        *) echo "No gate binaries pinned for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    fetch() { \
        curl -fsSL -o "$2" "$1"; \
        echo "$3  $2" | sha256sum -c -; \
    }; \
    fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.gz" \
        /tmp/shellcheck.tar.gz "${sc_sha}"; \
    tar -xzf /tmp/shellcheck.tar.gz -C /tmp; \
    install -m0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf "/tmp/shellcheck-v${SHELLCHECK_VERSION}" /tmp/shellcheck.tar.gz; \
    fetch "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${TARGETARCH}" \
        /tmp/shfmt "${sf_sha}"; \
    install -m0755 /tmp/shfmt /usr/local/bin/shfmt; \
    fetch "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v${EC_VERSION}/ec-linux-${TARGETARCH}.tar.gz" \
        /tmp/ec.tar.gz "${ec_sha}"; \
    tar -xzf /tmp/ec.tar.gz -C /tmp; \
    install -m0755 "/tmp/bin/ec-linux-${TARGETARCH}" /usr/local/bin/ec; \
    fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${TARGETARCH}.tar.gz" \
        /tmp/actionlint.tar.gz "${al_sha}"; \
    tar -xzf /tmp/actionlint.tar.gz -C /tmp actionlint; \
    install -m0755 /tmp/actionlint /usr/local/bin/actionlint; \
    fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${gl_arch}.tar.gz" \
        /tmp/gitleaks.tar.gz "${gl_sha}"; \
    tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks; \
    install -m0755 /tmp/gitleaks /usr/local/bin/gitleaks; \
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-${hl_arch}" \
        /tmp/hadolint "${hl_sha}"; \
    install -m0755 /tmp/hadolint /usr/local/bin/hadolint; \
    fetch "https://github.com/zavoloklom/docker-compose-linter/releases/download/v${DCLINT_VERSION}/dclint-bullseye-${TARGETARCH}" \
        /tmp/dclint "${dc_sha}"; \
    install -m0755 /tmp/dclint /usr/local/bin/dclint; \
    rm -rf /tmp/bin /tmp/ec.tar.gz /tmp/actionlint /tmp/actionlint.tar.gz \
        /tmp/gitleaks /tmp/gitleaks.tar.gz /tmp/hadolint /tmp/dclint /tmp/shfmt

# Fail the build when an asset name drifted, rather than the next commit.
RUN ec --version \
    && actionlint --version \
    && gitleaks version \
    && hadolint --version \
    && dclint --version \
    && rubocop --version \
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
