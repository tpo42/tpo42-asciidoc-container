#!/bin/bash
# ADCW - Validate AsciiDoc syntax
# Best-effort syntax checking and validation

set -e
set -u
set -o pipefail

show_usage() {
    cat <<'EOF'
ADCW Validate - AsciiDoc syntax validation

Usage:
  validate -i <input> ... [options]
  validate -i 'adr/*.adoc'                   # Quoted glob (expanded by find)
  validate -i adr/adr-001.adoc adr/adr-002.adoc  # Shell-expanded file list

Options:
  -i, --input           Input AsciiDoc file(s) or glob pattern (repeatable)
  -l, --failure-level   Minimum log level that fails validation: INFO, WARN, ERROR, FATAL
                        (default: WARN; INFO implies --verbose)
  -s, --strict          Abort on missing files instead of skipping them
  -v, --verbose         Show asciidoctor DEBUG/INFO messages and additional checks
      --no-diagrams     Skip diagram rendering (faster; stops finding broken diagrams)
  -w, --work-dir        Scratch parent for rendering output (default: build,
                        or $ADOC_WORK_DIR). Must be inside the workspace.
  -h, --help            Show this help message
  --                    Everything after this is passed to asciidoctor

Description:
  Validates AsciiDoc compile units by running them through asciidoctor.
  Any warning or error produced during document processing constitutes
  a validation failure (non-zero exit code).

Examples:
  validate -i requirements.adoc
  validate -i architecture.adoc -l INFO          # strict: fail on INFO (implies -v)
  validate -i 'arc42-chapters/*.adoc' --verbose
  validate -i doc.adoc -- -a my-attribute        # pass extra flags to asciidoctor
EOF
}

# Parse command line arguments
INPUT_ARGS=()
ASCIIDOCTOR_EXTRA=()
FAILURE_LEVEL="WARN"
STRICT=false
VERBOSE=false
DIAGRAMS=true
WORK_DIR="${ADOC_WORK_DIR:-build}"

while [[ $# -gt 0 ]]; do
    case $1 in
    --)
        shift
        ASCIIDOCTOR_EXTRA=("$@")
        break
        ;;
    -i | --input)
        INPUT_ARGS+=("$2")
        shift 2
        ;;
    --no-diagrams)
        DIAGRAMS=false
        shift
        ;;
    -w | --work-dir)
        WORK_DIR="$2"
        shift 2
        ;;
    -l | --failure-level)
        FAILURE_LEVEL="$2"
        shift 2
        ;;
    -s | --strict)
        STRICT=true
        shift
        ;;
    -v | --verbose)
        VERBOSE=true
        shift
        ;;
    -h | --help)
        show_usage
        exit 0
        ;;
    *)
        # Treat positional arguments as additional input files
        # (handles shell-expanded globs: validate -i adr/a.adoc adr/b.adoc)
        INPUT_ARGS+=("$1")
        shift
        ;;
    esac
done

# --failure-level INFO requires asciidoctor --verbose to take effect
if [[ "${FAILURE_LEVEL}" == "INFO" ]]; then
    VERBOSE=true
fi

# Validate arguments
if [[ ${#INPUT_ARGS[@]} -eq 0 ]]; then
    echo "❌ Input file(s) or pattern required (-i)"
    show_usage
    exit 1
fi

# Scratch for everything asciidoctor writes: the HTML it has to produce for reference
# checking, the rendered diagrams, the diagram cache, the captured diagnostics. Only the
# diagnosis is of interest here, so nothing is retrieved and the directory goes away on
# exit — working directory, not result directory.
#
# Inside the workspace on purpose. --safe-mode server bends absolute attribute paths back
# into the document's base directory, so a scratch under /tmp reappears as
# <basedir>/tmp/… with real diagrams in it. The default parent is build/, which bin/adcw
# already creates and mounts and which consumers already ignore.
if ! mkdir -p "${WORK_DIR}" 2>/dev/null || ! SCRATCH="$(mktemp -d "${WORK_DIR}/.validate.XXXXXX" 2>/dev/null)"; then
    echo "❌ Cannot write to the work directory: ${WORK_DIR}"
    echo ""
    echo "   Validation renders into the workspace because --safe-mode server refuses"
    echo "   any output outside the document's base directory. This user ($(id -u):$(id -g))"
    echo "   cannot write here — the workspace belongs to someone else, or is mounted"
    echo "   read-only."
    echo ""
    echo "   Run the container as the workspace owner, or point --work-dir at a"
    echo "   writable directory inside it. --no-diagrams skips rendering entirely."
    exit 1
fi
trap 'rm -rf "${SCRATCH}"' EXIT

echo "🔍 Validating AsciiDoc files..."

# Resolve inputs: expand glob patterns via find, pass plain files through
FILES=()
for input in "${INPUT_ARGS[@]}"; do
    if [[ "${input}" == *"*"* ]] || [[ "${input}" == *"?"* ]]; then
        # Glob pattern — use -path for patterns with directory components,
        # -name for simple filename globs
        find_flag="-name"
        if [[ "${input}" == *"/"* ]]; then
            find_flag="-path"
            [[ "${input}" != ./* ]] && input="./${input}"
        fi
        matched=0
        while IFS= read -r -d '' file; do
            FILES+=("$file")
            matched=$((matched + 1))
        done < <(find . ${find_flag} "${input}" -type f -print0 2>/dev/null || true)

        # A pattern that matches nothing is the same kind of accident as a file that
        # is not there, and --strict has to treat it the same way. It did not: only
        # the plain-file branch below consulted STRICT, so a gate calling
        # `validate --strict -i 'adr/*.adoc' -i 'req/*.adoc'` kept passing after one
        # of those directories was renamed away, quietly checking half of what it
        # claimed to check.
        if [[ "${matched}" -eq 0 ]]; then
            if [[ "${STRICT}" == true ]]; then
                echo "❌ Pattern matched no files: ${input}"
                exit 1
            fi
            echo "⚠️  Skipping (no match): ${input}"
        fi
    elif [[ -f "${input}" ]]; then
        FILES+=("${input}")
    else
        if [[ "${STRICT}" == true ]]; then
            echo "❌ File not found: ${input}"
            exit 1
        fi
        echo "⚠️  Skipping (not found): ${input}"
    fi
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "❌ No files found matching: ${INPUT_ARGS[*]}"
    exit 1
fi

echo "   Files found: ${#FILES[@]}"
echo ""

# Validation counters
TOTAL_FILES=0
VALID_FILES=0
ERROR_FILES=0

# Validate each file
for file in "${FILES[@]}"; do
    TOTAL_FILES=$((TOTAL_FILES + 1))

    echo "📝 Validating: ${file}"

    # Validate via asciidoctor (resolves includes, conditionals, cross-references)
    # Rendering into the scratch rather than --out-file /dev/null: the latter skips
    # conversion and therefore misses invalid reference checks. A real target keeps that
    # property without writing into the document's directory.
    # --base-dir anchors the jail at the workspace instead of at each document's own
    # directory. Without it a document in a subdirectory renders into a scratch that
    # lies outside its jail, and asciidoctor answers with "path is outside of jail;
    # recovering automatically" — a warning, which at the default failure level fails
    # the very document it was asked to check.
    asciidoctor_args=(
        --trace
        --safe-mode server
        --base-dir "${PWD}"
        --failure-level "${FAILURE_LEVEL}"
        --no-header-footer
        -o "${SCRATCH}/render.html"
    )
    if [[ "${VERBOSE}" == true ]]; then
        asciidoctor_args+=(--verbose)
    fi
    # Without the extension asciidoctor only parses a diagram block — a syntactically
    # broken diagram reaches DEBUG ("unknown style for listing block") and validation
    # passes. Rendering is what turns it into a finding. imagesoutdir and diagram-cachedir
    # keep the rendered output out of the workspace; PlantUML's own `!include` still
    # resolves against the document, so diagram sources are unaffected.
    #
    # PlantUML (including the C4 and ArchiMate libraries), Graphviz and Ditaa render in
    # this image. Mermaid does not: it needs a headless browser, which would add 1.68 GB
    # to a 1.66 GB image, so it lives in ghcr.io/tpo42/adoc-with-mermaid instead
    # (ADR-008). A mermaid block validated here reports a missing mmdc — a tooling gap,
    # not a document defect. Use the variant image for such documents.
    if [[ "${DIAGRAMS}" == true ]]; then
        asciidoctor_args+=(
            -r asciidoctor-diagram
            -a imagesoutdir="${SCRATCH}/images"
            -a diagram-cachedir="${SCRATCH}/cache"
        )
    fi
    if asciidoctor \
        "${asciidoctor_args[@]}" \
        ${ASCIIDOCTOR_EXTRA[@]+"${ASCIIDOCTOR_EXTRA[@]}"} \
        "${file}" >/dev/null 2>"${SCRATCH}/diagnostics"; then

        VALID_FILES=$((VALID_FILES + 1))
        echo "   ✅ Valid"

        if [[ "${VERBOSE}" == true ]]; then
            # Show warnings if any
            if [[ -s "${SCRATCH}/diagnostics" ]]; then
                echo "   ⚠️  Warnings:"
                sed 's/^/      /' "${SCRATCH}/diagnostics"
            fi
        fi
    else
        ERROR_FILES=$((ERROR_FILES + 1))
        echo "   ❌ Errors found"
        echo "   🔍 Details:"
        sed 's/^/      /' "${SCRATCH}/diagnostics"
    fi

    # Additional checks for common issues
    if [[ "${VERBOSE}" == true ]]; then
        echo "   🔍 Additional checks:"

        # Check for missing include files
        while IFS= read -r include_line; do
            if [[ -n "${include_line}" ]]; then
                include_file=$(echo "${include_line}" | sed -n 's/^include::\([^[]*\).*/\1/p')
                if [[ -n "${include_file}" ]]; then
                    if [[ ! -f "${include_file}" ]] && [[ ! -f "$(dirname "${file}")/${include_file}" ]]; then
                        echo "      ⚠️  Missing include: ${include_file}"
                    fi
                fi
            fi
        done < <(grep -n "^include::" "${file}" 2>/dev/null || true)

        # Check for diagram blocks. Counting only — the real check is the rendering
        # above; this line predates it and is kept as a hint about document shape.
        if diagram_blocks=$(grep -cE "^\[(plantuml|graphviz|mermaid)" "${file}" 2>/dev/null); then
            echo "      📊 Diagram blocks found: ${diagram_blocks}"
        fi

        # Mermaid is counted above but cannot render here — see ADR-008.
        if grep -qE "^\[mermaid" "${file}" 2>/dev/null && [[ "${DIAGRAMS}" == true ]] &&
            ! command -v mmdc >/dev/null 2>&1; then
            echo "      ℹ️  Mermaid blocks need ghcr.io/tpo42/adoc-with-mermaid to render"
        fi

        # Check for cross-references
        if xrefs=$(grep -cE "<<[^>]+>>" "${file}" 2>/dev/null); then
            echo "      🔗 Cross-references found: ${xrefs}"
        fi
    fi

    echo ""
done

# Summary
echo "📊 Validation Summary:"
echo "   Total files:   ${TOTAL_FILES}"
echo "   Valid files:   ${VALID_FILES}"
echo "   Files with errors: ${ERROR_FILES}"
echo ""

if [[ "${ERROR_FILES}" -eq 0 ]]; then
    echo "✅ All files validated successfully! 🎉"
    exit 0
else
    echo "❌ ${ERROR_FILES} file(s) have validation errors"
    echo ""
    echo "Tip: Use --verbose for detailed analysis"
    exit 1
fi
