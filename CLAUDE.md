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
lefthook run pre-push --all-files    # the container regression suites
```

The suites on their own, when one of them is what you are working on:

```bash
test/run-suite.bash test/unit                         # sources bin/adcw — no container
test/run-suite.bash test/validate-cases.bats          # needs the image
test/run-suite.bash test/flatten-cases.bats           # needs the image
test/run-suite.bash test/extract-diagrams-cases.bats  # needs the image
test/run-suite.bash test/image-cases.bats             # needs the image, both variants
test/run-suite.bash --filter 'compose' test/unit      # one case
```

Always through `test/run-suite.bash`, never `bats` directly: the wrapper pins the
interpreter to `/bin/bash` — bash 3.2 on macOS, the oldest one the wrappers have to survive,
where a bash 4 construct parses cleanly under `bash -n` and fails only when it runs.
bats' own `#!/usr/bin/env bash` would pick a brewed 5.x instead (ADR-010).

Runs are sequential locally. CI sets `ADCW_TEST_JOBS=4`, which the wrapper turns into
bats' `--jobs`; it needs GNU parallel, which is why it is not the local default. Pass
`--jobs N` explicitly to override.

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
- **Tests** are BATS (ADR-010), vendored as submodules under `test/bats` and `test/test_helper/`. `test/unit/*.bats` is the fast unit suite — it sources `bin/adcw`, no container, and is run as a directory so a new file needs no gate change. `validate-cases.bats`, `flatten-cases.bats` and `extract-diagrams-cases.bats` drive `bin/adcw` against the built image — one per delivered command. `image-cases.bats` is the one suite that reaches for the container runtime directly, because its subject is the image rather than the wrapper — the login shell's PATH, passwordless sudo, no variable outliving what it named. Domain helpers that BATS cannot supply live in `test/test_helper/adcw.bash`; keep it to image resolution, workspace paths and `assert_file_count`. Suites carry no shebang and are not executable — that is deliberate, see ADR-010. Cases are written to be reentrant (each owns its output directory) because CI runs them with `--jobs`; do not introduce shared writable state. Fixtures are named after the defect they carry, not after the suite that reads them.
- **Trust boundary**: the delivered commands do not defend against the author of the document they process. Running one already grants it everything mounted under `/workspace` — `safe: :unsafe` resolves includes across all of it — so a path that leaves `-o` is a robustness question ("`-o` names where output goes"), not a security one. A command cannot tell a deliberate `arch/overview` from a hostile `../../build/foo`: both are a path somebody wrote, and a tool that guesses intent ends up annoying and ineffective at once. Whoever processes foreign documents mounts the document and nothing else, the rest read-only — the caller's arrangement, not the image's decision.
- **User mapping**: The Containerfile accepts `USER_UID`/`USER_GID`/`USER_NAME`/`USER_GROUP_NAME` build args for host permission alignment.
- **ADRs** in `adr/*.adoc` document all significant decisions, **req42 artefacts** in `req/*.adoc` the problem side they answer — use cases (`uc-*`), functional requirements (`fr-*`), constraints (`con-*`). New ones follow the same AsciiDoc format as their neighbours; both directories are validated by the `adoc-validate` gate.
- **README.md tracks the artefacts.** Adding an ADR or a req42 artefact means adding its line to the "Architecture Decisions" or "Requirements" section — that list is the single point of truth for the titles, which is why the project tree names the directories and stops there. Anything else that appears at a level the tree shows (a workflow, a Containerfile, a config at the root) gets its line in the tree. A README that lists eight of eleven ADRs is worse than one that lists none: it reads as complete.
- **Commits** use conventional commit style (`feat:`, `fix:`, `docs:`). Always `--signoff`.
- **Gemfile** pins major versions (`~>`) — do not lock to exact versions or commit a `Gemfile.lock`. It belongs to the delivered image and to `bundle`. A gate that happens to be a gem is a gate: pinned as an `ARG` beside the other gate versions in `container/mini.Containerfile` and installed with `gem install <name> -v <version>`. That holds while there are two or three of them. Touching `asciidoctor-diagram` means checking `EXTRACTABLE_TYPES` in `container/resources/extract-diagrams.rb`, which is read out of the extension, and `RENDERABLE_TYPES` beside it, which is stated and proven by one fixture per entry. rubygems answers which version exists; only the project's release notes (`gh api repos/<org>/<repo>/releases`) answer whether it has to be taken.
