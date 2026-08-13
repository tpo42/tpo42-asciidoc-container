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
test/run-suite.bash test/shell-function.bats          # sources bin/adcw — no container
test/run-suite.bash test/validate-cases.bats          # needs the image
test/run-suite.bash test/extract-diagrams-cases.bats  # needs the image
test/run-suite.bash --filter 'compose' test/shell-function.bats   # one case
```

Always through `test/run-suite.bash`, never `bats` directly: the wrapper pins the
interpreter to `/bin/bash` — on macOS 3.2, the oldest one the wrappers have to survive,
where a bash 4 construct parses cleanly under `bash -n` and fails only when it runs.
bats' own `#!/usr/bin/env bash` would pick a brewed 5.x instead (ADR-010).

The suites live behind git submodules. A fresh clone needs:

```bash
git submodule update --init --recursive
```

There is no Makefile. `.github/workflows/quality-gates.yml` runs the same lefthook jobs
on Linux and macOS; `container-publish.yml` builds both variants per architecture, runs the container
suites against them and publishes what passed; the unit suite needs no container and
runs everywhere.

## Key Conventions

- **Executable shell scripts** use `set -e -u -o pipefail`. Preserve this in all of them. *Sourced* files must not: shell options set there mutate the calling shell, and under BATS that changes the semantics of every test that loads them. `lib/adcw-common.bash`, `lib/completions/adcw.bash` and everything under `test/test_helper/` therefore carry none.
- **Multi-runtime support**: `bin/adcw` and `bin/adcbw` detect 5 container runtimes (container, nerdctl, finch, podman, docker). Changes must not break any of them.
- **Container tag** is derived from `git describe` in the wrappers — `main`→`latest`, branches→slug, dirty→`-dirty` suffix.
- **Command scripts** in `container/resources/` are installed to `/usr/local/bin/` inside the container. `extract-diagrams.rb` uses the Asciidoctor API directly.
- **Tests** are BATS (ADR-010), vendored as submodules under `test/bats` and `test/test_helper/`. `shell-function.bats` is the fast unit suite — it sources `bin/adcw`, no container. `validate-cases.bats` and `extract-diagrams-cases.bats` drive `bin/adcw` against the built image. Domain helpers that BATS cannot supply live in `test/test_helper/adcw.bash`; keep it to image resolution, workspace paths and `assert_file_count`. Suites carry no shebang and are not executable — that is deliberate, see ADR-010. Cases are written to be reentrant (each owns its output directory) so `--jobs` stays one flag away; do not introduce shared writable state. Fixtures are named after the defect they carry, not after the suite that reads them.
- **User mapping**: The Containerfile accepts `USER_UID`/`USER_GID`/`USER_NAME`/`USER_GROUP_NAME` build args for host permission alignment.
- **ADRs** in `adr/*.adoc` document all significant decisions. New decisions should follow the same AsciiDoc ADR format.
- **Commits** use conventional commit style (`feat:`, `fix:`, `docs:`). Always `--signoff`.
- **Gemfile** pins major versions (`~>`) — do not lock to exact versions or commit a `Gemfile.lock`. It belongs to the delivered image and to `bundle`. A gate that happens to be a gem is a gate: pinned as an `ARG` beside the other gate versions in `container/mini.Containerfile` and installed with `gem install <name> -v <version>`. That holds while there are two or three of them.
