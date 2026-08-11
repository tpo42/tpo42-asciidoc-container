#!/usr/bin/env ruby
# frozen_string_literal: true

# ADCW - Extract diagram sources from AsciiDoc files
# Extract PlantUML, Graphviz, Mermaid, etc. for analysis and LLM context
#
# One Ruby program rather than a shell script writing a Ruby program to /tmp and calling
# it. The shell half was argument parsing and validation, which OptionParser does for
# free, and the temporary files it needed are what Dir.mktmpdir is for. Collapsing the
# two removes a fixed /tmp path that raced whenever the container was long-lived and
# shared -- which, per UC-002 and UC-003, is how the image is normally run.

require 'asciidoctor'
require 'fileutils'
require 'optparse'
require 'tmpdir'

FORMATS = %w[source rendered both].freeze

# Extraction works for every type in this list; rendering is a shorter list, and which
# one is shorter depends on the image (ADR-008).
SUPPORTED_TYPES = %w[
  plantuml graphviz mermaid ditaa blockdiag seqdiag actdiag nwdiag packetdiag rackdiag
  c4plantuml
].freeze

# Kernel#warn is a no-op whenever $VERBOSE is nil, which RUBYOPT=-W0 produces. The image
# no longer sets it; if it comes back, every message below goes silent while the exit
# codes stay correct.
def die(message)
  warn "❌ #{message}"
  exit 1
end

options = { format: 'source' }

parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    ADCW Extract-Diagrams - Extract diagram sources for analysis

    Usage:
      extract-diagrams -i <input.adoc> -o <output_dir> [options]

  BANNER

  opts.on('-i', '--input FILE', 'Input AsciiDoc file') { |v| options[:input] = v }
  opts.on('-o', '--output DIR', 'Output directory for extracted diagrams') { |v| options[:output] = v }
  opts.on('-f', '--format FORMAT', FORMATS, "Output format: #{FORMATS.join('|')} (default: source)") do |v|
    options[:format] = v
  end
  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    puts <<~TAIL

      Description:
        Extracts diagram source code from AsciiDoc files.

        Extraction works for every supported type; --format rendered depends on what
        the image carries. PlantUML and Graphviz render in every image; Mermaid needs
        ghcr.io/tpo42/adoc-with-mermaid, which ships the browser mmdc drives (ADR-008).

        A block that cannot be rendered under --format rendered is an error, not a
        note: a diagram nobody rendered is exactly the failure this toolchain exists
        to catch.

        Perfect for LLM context where diagram source code is more valuable than
        rendered images.

      Examples:
        extract-diagrams -i overview.adoc -o build/diagrams/
        extract-diagrams -i architecture.adoc -o diagrams/ --format both
    TAIL
    exit 0
  end
end

begin
  parser.parse!
rescue OptionParser::InvalidArgument => e
  die "#{e.message}. Use: #{FORMATS.join('|')}"
rescue OptionParser::ParseError => e
  die e.message
end

die 'Input file required (-i)' unless options[:input]
die 'Output directory required (-o)' unless options[:output]
die "Input file not found: #{options[:input]}" unless File.file?(options[:input])

input_file = options[:input]
output_dir = options[:output]
output_format = options[:format]
render = output_format != 'source'

# PlantUML comes from the asciidoctor-diagram-plantuml gem, not from a distribution
# package. The gem carries 1.2026.x with a 30+ library stdlib -- archimate and c4 among
# them -- while Debian ships 1.2020.02 with twelve. Having both meant that which PlantUML
# you got depended on which entry point you used.
plantuml_jar = nil
if render
  jar_glob = '/usr/gem/gems/asciidoctor-diagram-plantuml-*/lib/asciidoctor-diagram/' \
             'plantuml/plantuml-lgpl-*.jar'
  # Dir.glob sorts since Ruby 3.0, so the last entry is the highest version present.
  jars = Dir.glob(jar_glob)
  die 'No PlantUML jar found — is asciidoctor-diagram-plantuml installed?' if jars.empty?

  plantuml_jar = jars.last
end

FileUtils.mkdir_p(output_dir)

puts '📊 Extracting diagrams from AsciiDoc...'
puts "   Input:  #{input_file}"
puts "   Output: #{output_dir}"
puts "   Format: #{output_format}"

# Renderers keyed by diagram type. Each takes the source text and the target path, runs
# the tool without a shell, and returns true on success.
#
# Array form throughout, never a command string: an output directory containing a space
# used to split into two words, so a redirect landed on a truncated path. The command
# still succeeded and the caller was told "Rendered" while the file went somewhere else.
RENDERERS = {
  'plantuml' => lambda { |source, target, tmp, jar|
    intermediate = File.join(tmp, 'diagram.plantuml')
    File.write(intermediate, source)
    system('java', '-jar', jar.to_s, '-tsvg', '-pipe', in: intermediate, out: target)
  },
  'graphviz' => lambda { |source, target, tmp, _jar|
    intermediate = File.join(tmp, 'diagram.dot')
    File.write(intermediate, source)
    system('dot', '-Tsvg', intermediate, '-o', target)
  },
  # mmdc is the wrapper the image installs in front of npm's, which supplies the
  # Puppeteer configuration Chromium needs inside a container (ADR-008). It exists only
  # in the adoc-with-mermaid variant; the absence is reported below rather than here, so
  # that the message can name the image that does carry it.
  'mermaid' => lambda { |source, target, tmp, _jar|
    intermediate = File.join(tmp, 'diagram.mmd')
    File.write(intermediate, source)
    system('mmdc', '-i', intermediate, '-o', target)
  }
}.freeze

# What a missing renderer means, in the caller's terms. Everything not named here simply
# has no renderer in any image.
UNRENDERABLE_HINT = {
  'mermaid' => 'needs ghcr.io/tpo42/adoc-with-mermaid, which ships the browser (ADR-008)'
}.freeze

def renderer_available?(type)
  return false unless RENDERERS.key?(type)
  return true unless type == 'mermaid'

  ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
    File.executable?(File.join(dir, 'mmdc'))
  end
end

# The stem of every file this writes, taken from the block's own id where it has one — so
# the output is named after the diagram rather than after its position in the document.
#
# An id is text somebody wrote, and `arch/overview` is one they wrote without meaning a
# directory. `File.join` would take it as one, name a subdirectory that does not exist, and
# the extraction would yield nothing for a document with nothing wrong with it. Only the
# last component survives, and anything outside a conservative set becomes an underscore:
# the id names a file, never a path.
def output_stem(candidate, fallback)
  stem = File.basename(candidate.to_s).gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A[.]+/, '')
  stem.empty? ? fallback : stem
end

doc = Asciidoctor.load_file(input_file, safe: :unsafe)

diagram_count = 0
render_failures = 0

# Both delimiters count. `....` gives a literal block, `----` a listing block, and
# asciidoctor-diagram accepts either -- its own documentation uses `----` throughout, so
# matching only :literal missed the form most documents are written in and reported
# "No diagrams found" for them.
blocks = doc.find_by do |block|
  %i[literal listing].include?(block.context) &&
    block.style &&
    SUPPORTED_TYPES.include?(block.style.downcase)
end

Dir.mktmpdir('extract-diagrams') do |tmp|
  blocks.each do |diagram_block|
    diagram_count += 1
    diagram_type = diagram_block.style.downcase

    fallback = "diagram_#{diagram_count}"
    base_name = if diagram_block.id
                  output_stem(diagram_block.id, fallback)
                elsif diagram_block.parent&.id
                  output_stem("#{diagram_block.parent.id}_diagram_#{diagram_count}", fallback)
                else
                  fallback
                end

    source_content = diagram_block.source

    if %w[source both].include?(output_format)
      source_file = File.join(output_dir, "#{base_name}.#{diagram_type}")
      File.write(source_file, source_content)
      puts "   📄 Extracted source: #{base_name}.#{diagram_type}"
    end

    next unless render

    target = File.join(output_dir, "#{base_name}.svg")

    unless renderer_available?(diagram_type)
      hint = UNRENDERABLE_HINT[diagram_type]
      detail = hint ? " — #{hint}" : ''
      warn "   ❌ Cannot render #{diagram_type}: #{base_name}#{detail}"
      render_failures += 1
      next
    end

    if RENDERERS[diagram_type].call(source_content, target, tmp, plantuml_jar)
      puts "   🖼️  Rendered: #{base_name}.svg"
    else
      # PlantUML writes an image *containing* the words "Syntax Error" and exits 200, so
      # a failed render leaves a plausible-looking 8 KB SVG behind. Leaving it is how a
      # broken diagram reaches a document: the file exists, the build is green, and the
      # picture says the error out loud where nobody reads it.
      FileUtils.rm_f(target)
      warn "   ❌ Failed to render: #{base_name} (#{diagram_type})"
      render_failures += 1
    end
  end
end

puts ''
puts '📊 Extraction complete!'
puts "   Diagrams found: #{diagram_count}"
puts "   Output directory: #{output_dir}"

if diagram_count.zero?
  puts ''
  puts "💡 No diagrams found in #{input_file}"
  puts "   Supported types: #{SUPPORTED_TYPES.join(', ')}"
end

written = Dir.glob(File.join(output_dir, '*'))
unless written.empty?
  puts ''
  puts 'Extracted files:'
  written.each do |path|
    puts format('  %<size>9d  %<name>s', size: File.size(path), name: File.basename(path))
  end
end

if render_failures.positive?
  warn ''
  warn "❌ #{render_failures} diagram(s) could not be rendered"
  exit 1
end

puts ''
puts '✅ Diagram extraction complete! 📊'
