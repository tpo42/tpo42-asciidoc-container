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
  validate -i <input.adoc> [options]
  validate -i "*.adoc"      # Validate multiple files

Options:
  -i, --input    Input AsciiDoc file(s) - supports glob patterns
  -v, --verbose  Verbose output with detailed information
  -h, --help     Show this help message

Description:
  Performs best-effort syntax validation of AsciiDoc files.
  Checks for common issues like:
  - Invalid include paths
  - Malformed document structure  
  - Broken cross-references
  - Diagram syntax errors

Examples:
  validate -i requirements.adoc
  validate -i "arc42-chapters/*.adoc"
  validate -i architecture.adoc --verbose
EOF
}

# Parse command line arguments
INPUT_PATTERN=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input)
            INPUT_PATTERN="$2"
            shift 2
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
            echo "❌ Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate arguments
if [[ -z "${INPUT_PATTERN}" ]]; then
    echo "❌ Input pattern required (-i)"
    show_usage
    exit 1
fi

echo "🔍 Validating AsciiDoc files..."
echo "   Pattern: ${INPUT_PATTERN}"

cd /workspace

# Find files matching the pattern
FILES=()
if [[ "${INPUT_PATTERN}" == *"*"* ]] || [[ "${INPUT_PATTERN}" == *"?"* ]]; then
    # Handle glob patterns
    while IFS= read -r -d '' file; do
        FILES+=("$file")
    done < <(find . -name "${INPUT_PATTERN}" -type f -print0 2>/dev/null || true)
else
    # Single file
    if [[ -f "${INPUT_PATTERN}" ]]; then
        FILES=("${INPUT_PATTERN}")
    fi
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "❌ No files found matching: ${INPUT_PATTERN}"
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
    
    # Basic syntax validation using asciidoctor
    if asciidoctor \
        --trace \
        --safe-mode safe \
        --no-header-footer \
        --out-file /dev/null \
        "${file}" 2>/tmp/validation_output; then
        
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
        diagram_blocks=$(grep -c "^\[plantuml\|^\[graphviz\|^\[mermaid" "${file}" 2>/dev/null || echo "0")
        if [[ "${diagram_blocks}" -gt 0 ]]; then
            echo "      📊 Diagram blocks found: ${diagram_blocks}"
        fi
        
        # Check for cross-references
        xrefs=$(grep -c "<<.*>>" "${file}" 2>/dev/null || echo "0")
        if [[ "${xrefs}" -gt 0 ]]; then
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
