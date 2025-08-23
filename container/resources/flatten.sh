#!/bin/bash
# ADCW - Flatten includes to self-contained document
# Resolve all include:: directives for LLM context preparation

set -e
set -u
set -o pipefail

show_usage() {
    cat << 'EOF'
ADCW Flatten - Resolve includes to self-contained document

Usage:
  flatten -i <input.adoc> -o <output.adoc> [options]

Options:
  -i, --input    Input AsciiDoc file
  -o, --output   Output file for flattened document
  -h, --help     Show this help message

Description:
  Resolves all include:: directives to create a self-contained
  document suitable for LLM context or analysis.
  
  Diagram sources (PlantUML, Graphviz) are preserved as-is
  for better LLM understanding.

Examples:
  flatten -i requirements.adoc -o build/requirements-flat.adoc
  flatten -i arc42-architecture.adoc -o llm-context/architecture.adoc
EOF
}

# Parse command line arguments
INPUT_FILE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input)
            INPUT_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2" 
            shift 2
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
if [[ -z "${INPUT_FILE}" ]]; then
    echo "❌ Input file required (-i)"
    show_usage
    exit 1
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
    echo "❌ Output file required (-o)"
    show_usage
    exit 1
fi

if [[ ! -f "/workspace/${INPUT_FILE}" ]]; then
    echo "❌ Input file not found: ${INPUT_FILE}"
    exit 1
fi

# Create output directory if needed
OUTPUT_DIR=$(dirname "${OUTPUT_FILE}")
mkdir -p "/build/${OUTPUT_DIR}"

echo "📄 Flattening AsciiDoc includes..."
echo "   Input:  ${INPUT_FILE}"
echo "   Output: ${OUTPUT_FILE}"

# Use asciidoctor-reducer to resolve includes and output flattened AsciiDoc
# This preserves diagram sources while resolving all includes - perfect for LLM context!
cd /workspace

echo "   Using asciidoctor-reducer for include resolution..."

# asciidoctor-reducer is the official tool for this exact use case
asciidoctor-reducer \
    --output "/build/${OUTPUT_FILE}" \
    --preserve-conditionals \
    "${INPUT_FILE}"

echo "✅ Flattening complete!"
echo ""
echo "Self-contained document created:"
echo "  /build/${OUTPUT_FILE}"
echo ""
echo "Ready for LLM context or analysis! 🤖"
