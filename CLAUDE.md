# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

ADCW — AsciiDoc Container Wrapper for the tpo42 Framework. See [README.md](README.md) for full documentation, commands, and project structure.

## Build & Run

```bash
./bin/adcbw          # build the container
./bin/adcw <command> # run a command (flatten, validate, extract-diagrams, asciidoctor, asciidoctor-pdf, shell, ...)
```

Local gates — lefthook owns them, and CI runs the same jobs:

```bash
lefthook run pre-commit --all-files  # formatters, linters, shellcheck, the unit suite
lefthook run pre-push --all-files    # the two container regression suites
```

The suites on their own, when one of them is what you are working on:

```bash
/bin/bash test/shell-function.bash          # sources bin/adcw, tests internals — no container
/bin/bash test/validate-cases.bash          # validate regression suite (needs the image)
/bin/bash test/extract-diagrams-cases.bash  # extract-diagrams regression suite (needs the image)
```

`/bin/bash` on purpose: on macOS that is bash 3.2, the oldest interpreter the wrappers
have to survive, and a bash 4 construct parses cleanly under `bash -n` there.

There is no Makefile. `.github/workflows/quality-gates.yml` runs the same lefthook jobs
on Linux and macOS; `container-publish.yml` builds both variants per architecture, runs the container
suites against them and publishes what passed; the unit suite needs no container and
runs everywhere.

## Key Conventions

- **Shell scripts** use `set -e -u -o pipefail`. Preserve this in all scripts.
- **Multi-runtime support**: `bin/adcw` and `bin/adcbw` detect 5 container runtimes (container, nerdctl, finch, podman, docker). Changes must not break any of them.
- **Container tag** is derived from `git describe` in the wrappers — `main`→`latest`, branches→slug, dirty→`-dirty` suffix.
- **Command scripts** in `container/resources/` are installed to `/usr/local/bin/` inside the container. `extract-diagrams.rb` uses the Asciidoctor API directly.
- **Tests** live in `test/`. `shell-function.bash` is the fast unit suite — it sources `bin/adcw` and runs every case in its own subshell, discovered by name, no container. `validate-cases.bash` and `extract-diagrams-cases.bash` drive `bin/adcw` against the built image and share `test/lib/harness.bash`. Fixtures are named after the defect they carry, not after the suite that reads them.
- **User mapping**: The Containerfile accepts `USER_UID`/`USER_GID`/`USER_NAME`/`USER_GROUP_NAME` build args for host permission alignment.
- **ADRs** in `adr/*.adoc` document all significant decisions. New decisions should follow the same AsciiDoc ADR format.
- **Commits** use conventional commit style (`feat:`, `fix:`, `docs:`). Always `--signoff`.
- **Gemfile** pins major versions (`~>`) — do not lock to exact versions or commit a `Gemfile.lock`. It belongs to the delivered image and to `bundle`. A gate that happens to be a gem is a gate: pinned as an `ARG` beside the other gate versions in `container/mini.Containerfile` and installed with `gem install <name> -v <version>`. That holds while there are two or three of them.
