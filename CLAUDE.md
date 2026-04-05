# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

ADCW — AsciiDoc Container Wrapper for the tpo42 Framework. See [README.md](README.md) for full documentation, commands, and project structure.

## Build & Run

```bash
./bin/adcbw          # build the container
./bin/adcw <command> # run a command (flatten, validate, extract-diagrams, asciidoctor, asciidoctor-pdf, shell, ...)
```

There is no test suite, Makefile, linter, or CI pipeline.

## Key Conventions

- **Shell scripts** use `set -e -u -o pipefail`. Preserve this in all scripts.
- **Multi-runtime support**: `bin/adcw` and `bin/adcbw` detect 5 container runtimes (container, nerdctl, finch, podman, docker). Changes must not break any of them.
- **Container tag** is derived from `git describe` in the wrappers — `main`→`latest`, branches→slug, dirty→`-dirty` suffix.
- **Command scripts** in `container/resources/*.sh` are installed to `/usr/local/bin/` inside the container. `extract-diagrams.sh` contains embedded Ruby using the Asciidoctor API.
- **User mapping**: The Containerfile accepts `USER_UID`/`USER_GID`/`USER_NAME`/`USER_GROUP_NAME` build args for host permission alignment.
- **ADRs** in `adr/*.adoc` document all significant decisions. New decisions should follow the same AsciiDoc ADR format.
- **Commits** use conventional commit style (`feat:`, `fix:`, `docs:`). Always `--signoff`.
- **Gemfile** pins major versions (`~>`) — do not lock to exact versions or commit a `Gemfile.lock`.
