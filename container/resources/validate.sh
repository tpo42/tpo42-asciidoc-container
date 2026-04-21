#!/bin/bash
# ADCW - Validate AsciiDoc syntax
# Best-effort syntax checking and validation

set -e
set -u
set -o pipefail

show_usage() {
    cat << 'EOF'
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

while [[ $# -gt 0 ]]; do
    case $1 in
        --)
            shift
            ASCIIDOCTOR_EXTRA=("$@")
            break
            ;;
        -i|--input)
            INPUT_ARGS+=("$2")
            shift 2
            ;;
        -l|--failure-level)
            FAILURE_LEVEL="$2"
            shift 2
            ;;
        -s|--strict)
            STRICT=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
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
        while IFS= read -r -d '' file; do
            FILES+=("$file")
        done < <(find . ${find_flag} "${input}" -type f -print0 2>/dev/null || true)
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
    # Use -o - (stdout) instead of --out-file /dev/null: the latter skips rendering
    # and therefore misses invalid reference checks.
    asciidoctor_args=(
        --trace
        --safe-mode server
        --failure-level "${FAILURE_LEVEL}"
        --no-header-footer
        -o -
    )
    if [[ "${VERBOSE}" == true ]]; then
        asciidoctor_args+=(--verbose)
    fi
    if asciidoctor \
        "${asciidoctor_args[@]}" \
        ${ASCIIDOCTOR_EXTRA[@]+"${ASCIIDOCTOR_EXTRA[@]}"} \
        "${file}" > /dev/null 2>/tmp/validation_output; then
        
        VALID_FILES=$((VALID_FILES + 1))
        echo "   ✅ Valid"
        
        if [[ "${VERBOSE}" == true ]]; then
            # Show warnings if any
            if [[ -s /tmp/validation_output ]]; then
                echo "   ⚠️  Warnings:"
                sed 's/^/      /' /tmp/validation_output
            fi
        fi
    else
        ERROR_FILES=$((ERROR_FILES + 1))
        echo "   ❌ Errors found"
        echo "   🔍 Details:"
        sed 's/^/      /' /tmp/validation_output
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
        
        # Check for diagram blocks
        if diagram_blocks=$(grep -cE "^\[(plantuml|graphviz|mermaid)" "${file}" 2>/dev/null); then
            echo "      📊 Diagram blocks found: ${diagram_blocks}"
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
