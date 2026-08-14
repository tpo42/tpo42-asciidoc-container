---
name: adcw
description: "AsciiDoc Container Wrapper — flatten, validate, extract diagrams, generate PDF/HTML from AsciiDoc files via containerized toolchain."
user-invocable: true
---

# adcw — AsciiDoc Container Wrapper

Use the `adcw` command to process AsciiDoc files via the tpo42/adoc container toolchain.

## Prerequisites

The `adcw` command must be in PATH (e.g. via Homebrew or `ADOC_PROJECT_HOME/bin`). It auto-detects the execution context:

1. **Docker Compose**: If `docker-compose.yml` with adoc service exists
2. **Devcontainer**: If `.devcontainer/devcontainer.json` references tpo42/adoc
3. **Dedicated container**: Direct container runtime execution (requires built image)

## Commands

### flatten — Resolve includes into single document

```bash
adcw flatten -i <input.adoc> -o <output.adoc>
```

### validate — Check AsciiDoc syntax

```bash
adcw validate -i <file.adoc>
adcw validate --strict -i requirements.adoc
```

### extract-diagrams — Extract diagram sources

```bash
adcw extract-diagrams -i <input.adoc> -o <output-dir>/
```

### asciidoctor / asciidoctor-pdf — Generate HTML or PDF

```bash
adcw asciidoctor -a toc=left mydoc.adoc
adcw asciidoctor-pdf mydoc.adoc
```

### asciidoctor-reducer — Flatten with options

```bash
adcw asciidoctor-reducer --output flat.adoc input.adoc
```

## Usage Patterns

```bash
# Validate first, then flatten for full context
adcw validate -i <file.adoc>
adcw flatten -i <file.adoc> -o /tmp/flat.adoc

# Generate output
adcw asciidoctor <file.adoc>       # HTML
adcw asciidoctor-pdf <file.adoc>   # PDF

# Extract diagrams for inspection
adcw extract-diagrams -i <file.adoc> -o build/diagrams/
```

`/tmp/flat.adoc` is deliberate, and it is not an output path anybody is meant to read.
`/tmp` is container-local and gone with `--rm`, which is the point: the flattening has to
*happen* for the includes to be resolved and the result checked, and then the result is
of no further interest.

**Do not "optimise" this to `-o /dev/null`.** A null target lets the transformation be
skipped, and then nothing is checked at all — the command succeeds without having done
the work it was called for. The same applies to `validate`, which renders into a scratch
directory for the same reason: rendering is what turns a broken diagram into a finding.

Write to a real path when the flattened document is the point — as LLM context, for
instance — and pick one inside the workspace, since that and `./build` are the only paths
the container can see.

## Error Handling

- If `adcw` is not found, it needs to be added to PATH
- If the container image is not found, suggest running `adcbw` to build it
- Validation errors indicate AsciiDoc syntax problems in the source files

## Notes

- All paths are relative to the workspace root
- Output goes to `build/` by default (created automatically)
- The container mounts the current directory as `/workspace`
