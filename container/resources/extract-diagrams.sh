#!/bin/bash
# ADCW - Extract diagram sources from AsciiDoc files
# Extract PlantUML, Graphviz, etc. for analysis and LLM context

set -e
set -u
set -o pipefail

show_usage() {
    cat << 'EOF'
ADCW Extract-Diagrams - Extract diagram sources for analysis

Usage:
  extract-diagrams -i <input.adoc> -o <output_dir> [options]

Options:
  -i, --input    Input AsciiDoc file
  -o, --output   Output directory for extracted diagrams
  -f, --format   Output format: source|rendered|both (default: source)
  -h, --help     Show this help message

Description:
  Extracts diagram source code from AsciiDoc files.
  Supports PlantUML, Graphviz, Mermaid diagrams.
  
  Perfect for LLM context where diagram source code
  is more valuable than rendered images.

Examples:
  extract-diagrams -i overview.adoc -o build/diagrams/
  extract-diagrams -i architecture.adoc -o diagrams/ --format both
EOF
}

# Parse command line arguments
INPUT_FILE=""
OUTPUT_DIR=""
FORMAT="source"

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input)
            INPUT_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -f|--format)
            FORMAT="$2"
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

if [[ -z "${OUTPUT_DIR}" ]]; then
    echo "❌ Output directory required (-o)"
    show_usage
    exit 1
fi

if [[ ! -f "${INPUT_FILE}" ]]; then
    echo "❌ Input file not found: ${INPUT_FILE}"
    exit 1
fi

if [[ "${FORMAT}" != "source" && "${FORMAT}" != "rendered" && "${FORMAT}" != "both" ]]; then
    echo "❌ Invalid format: ${FORMAT}. Use: source|rendered|both"
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

echo "📊 Extracting diagrams from AsciiDoc..."
echo "   Input:  ${INPUT_FILE}"
echo "   Output: ${OUTPUT_DIR}"
echo "   Format: ${FORMAT}"

# Ruby script to extract diagram blocks
cat > /tmp/extract_diagrams.rb << 'RUBY'
require 'asciidoctor'

input_file = ARGV[0]
output_dir = ARGV[1]
format = ARGV[2] || 'source'

# Load document
doc = Asciidoctor.load_file(input_file, safe: :unsafe)

diagram_count = 0
supported_types = %w[plantuml graphviz mermaid ditaa blockdiag seqdiag actdiag nwdiag packetdiag rackdiag c4plantuml]

# Find all diagram blocks
doc.find_by do |block|
  block.context == :literal && 
  block.style && 
  supported_types.include?(block.style.downcase)
end.each do |diagram_block|
  
  diagram_count += 1
  diagram_type = diagram_block.style.downcase
  
  # Generate filename
  if diagram_block.id
    base_name = diagram_block.id
  elsif diagram_block.parent && diagram_block.parent.id
    base_name = "#{diagram_block.parent.id}_diagram_#{diagram_count}"
  else
    base_name = "diagram_#{diagram_count}"
  end
  
  # Extract source content
  source_content = diagram_block.source
  
  # Write source file
  if format == 'source' || format == 'both'
    source_file = File.join(output_dir, "#{base_name}.#{diagram_type}")
    File.write(source_file, source_content)
    puts "   📄 Extracted source: #{base_name}.#{diagram_type}"
  end
  
  # Generate rendered version if requested
  if format == 'rendered' || format == 'both'
    case diagram_type
    when 'plantuml'
      rendered_file = File.join(output_dir, "#{base_name}.svg")
      temp_file = "/tmp/#{base_name}.plantuml"
      File.write(temp_file, source_content)
      
      if system("plantuml -tsvg -pipe < #{temp_file} > #{rendered_file}")
        puts "   🖼️  Rendered: #{base_name}.svg"
      else
        puts "   ⚠️  Failed to render: #{base_name}.plantuml"
      end
      
    when 'graphviz'
      rendered_file = File.join(output_dir, "#{base_name}.svg")
      temp_file = "/tmp/#{base_name}.dot"
      File.write(temp_file, source_content)
      
      if system("dot -Tsvg #{temp_file} -o #{rendered_file}")
        puts "   🖼️  Rendered: #{base_name}.svg"
      else
        puts "   ⚠️  Failed to render: #{base_name}.dot"
      end
      
    else
      puts "   ⚠️  Rendering not supported for: #{diagram_type}"
    end
  end
end

puts ""
puts "📊 Extraction complete!"
puts "   Diagrams found: #{diagram_count}"
puts "   Output directory: #{output_dir}"

if diagram_count == 0
  puts ""
  puts "💡 No diagrams found in #{input_file}"
  puts "   Supported types: #{supported_types.join(', ')}"
end
RUBY

# Execute extraction
ruby /tmp/extract_diagrams.rb \
    "${INPUT_FILE}" \
    "${OUTPUT_DIR}" \
    "${FORMAT}"

echo ""
echo "✅ Diagram extraction complete! 📊"
echo ""
echo "Output location:"
echo "  ${OUTPUT_DIR}"
echo ""

# List extracted files
if ls "${OUTPUT_DIR}"/* >/dev/null 2>&1; then
    echo "Extracted files:"
    ls -la "${OUTPUT_DIR}" | sed 's/^/  /'
else
    echo "💡 No diagrams were extracted"
    echo ""
    echo "Supported diagram types:"
    echo "  - PlantUML: [plantuml]"
    echo "  - Graphviz: [graphviz]"
    echo "  - Mermaid: [mermaid]"
    echo "  - And more..."
fi
