#!/usr/bin/env ruby
# frozen_string_literal: true

# ADCW - Extract diagram sources from AsciiDoc files
# Extract PlantUML, Graphviz, Mermaid, etc. for analysis and LLM context
#
# One Ruby program rather than a shell script writing a Ruby program to /tmp and calling
# it. The shell half was argument parsing and validation, which OptionParser does for
# free. Collapsing the two removed a fixed /tmp path that raced whenever the container
# was long-lived and shared -- which, per UC-002 and UC-003, is how the image is normally
# run. Nothing here writes a temporary file any more: rendering goes through
# asciidoctor-diagram, which manages its own.

require 'asciidoctor'
require 'asciidoctor-diagram'
require 'fileutils'
require 'optparse'
require 'tmpdir'

FORMATS = %w[source rendered both].freeze

# Two lists, because extraction and rendering are two different questions and were never
# the same answer. The original comment here already said so — "extraction works for every
# type in this list; rendering is a shorter list" — but only one list existed, so the
# shorter one was expressed by leaving renderers out, and nothing said which types those
# were. That is how it came to name six types this image cannot render plus one that is
# not a block type in any image.

# Recognised as a diagram, and therefore extractable — asked of asciidoctor-diagram rather
# than transcribed from its documentation, because a transcription is a copy and copies
# drift. This one is right for the gem *installed here*, which is a stronger claim than
# matching the docs of whatever version is current upstream.
#
# The two do not even have the same shape: the docs list `barcode` once where the
# extension registers each symbology (code128, qrcode, ean13, …) as a block of its own,
# `meme` is a block macro and never a block, and `vhs` registers under the name `tape`.
# What matters here is what a block style can match, and that is only knowable at runtime.
DIAGRAM_GROUPS = Asciidoctor::Extensions.groups.dup.freeze
EXTRACTABLE_TYPES = Asciidoctor::Document.new([], safe: :safe).extensions
                                         .instance_variable_get(:@block_extensions)
                                         .keys.map(&:to_s).sort.freeze

# ...and then put the extension away again. asciidoctor-diagram renders at *parse* time,
# so leaving it registered would render every diagram in the input document as a side
# effect of reading it — into the working directory, before anything has decided whether
# rendering was even asked for. Verified: with the extension registered, the block is
# already an image by the time find_by sees it, and a stray PNG is left behind.
Asciidoctor::Extensions.unregister_all

# What this image renders out of the box. This one cannot be asked of anything — a
# registered extension is not a working one, as `structurizr` shows: the jar ships with
# the gem, the block registers, and rendering still fails for want of
# DIAGRAM_STRUCTURIZR_CLASSPATH. So it is stated here and proven in
# test/extract-diagrams-cases.bats, one rendered fixture per entry.
#
# Absent on purpose, measured 2026-08-14: `structurizr` (above), `syntrax` (wants the
# Python program, the jar alone is not enough), and the blockdiag family (not installed).
# Each has an issue of its own.
#
# `c4plantuml` is on neither list: it is not a diagram type in any image. C4 and ArchiMate
# are `[plantuml]` blocks with `!include <C4/C4_Container>` or
# `!include <archimate/Archimate>` — the stdlib comes with the gem's jar.
RENDERABLE_TYPES = %w[plantuml ditaa graphviz mermaid].freeze

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

        Extraction and rendering are two different lists. Every recognised type can be
        extracted -- source is what this tool is for, and a diagram nobody here can draw
        is still worth handing to a reader. Rendering is the shorter list: PlantUML,
        Ditaa and Graphviz render in every image, Mermaid needs
        ghcr.io/tpo42/adoc-with-mermaid, which ships the browser mmdc drives (ADR-008).
        Run without arguments on a document that has none to see both lists.

        C4 and ArchiMate are not diagram types of their own. Write them as [plantuml]
        blocks with !include <C4/C4_Container> or !include <archimate/Archimate>; the
        stdlib ships with the gem's jar.

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

FileUtils.mkdir_p(output_dir)

puts '📊 Extracting diagrams from AsciiDoc...'
puts "   Input:  #{input_file}"
puts "   Output: #{output_dir}"
puts "   Format: #{output_format}"

# What a missing renderer means, in the caller's terms. Everything not named here simply
# has no renderer in any image.
UNRENDERABLE_HINT = {
  'mermaid' => 'needs ghcr.io/tpo42/adoc-with-mermaid, which ships the browser (ADR-008)'
}.freeze

# Mermaid is the one type whose absence is a property of the *image* rather than of the
# toolchain: PlantUML, Ditaa and Graphviz come with the gems and the base packages, so
# their absence would be a broken image rather than a variant. mmdc is the wrapper the
# image installs in front of npm's, supplying the Puppeteer configuration Chromium needs
# inside a container (ADR-008).
def renderer_available?(type)
  return false unless RENDERABLE_TYPES.include?(type)
  return true unless type == 'mermaid'

  ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
    File.executable?(File.join(dir, 'mmdc'))
  end
end

# The stem of every file this writes, taken from the block's own id where it has one — so
# the output is named after the diagram rather than after its position in the document.
#
# An id is text somebody wrote, and `arch/overview` is one they wrote without meaning a
# directory. In AsciiDoc an id is an anchor -- `<<arch/overview>>` is how it is referenced
# -- so the slash is a namespace someone chose, not a path. `File.join` would take it as
# one, name a subdirectory that does not exist, and the extraction would yield nothing for
# a document with nothing wrong with it.
#
# So every component is kept and the separator is what changes: anything outside a
# conservative set becomes an underscore. `arch/overview` and `ui/overview` stay two names
# because they were two ids. Dropping to the last component instead would have merged
# them, and the second would have overwritten the first without a word.
def output_stem(candidate, fallback)
  stem = candidate.to_s.gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A[.]+/, '')
  stem.empty? ? fallback : stem
end

# A delimiter longer than any run of dots the source itself contains, so a diagram that
# happens to hold a `....` line cannot close the block it is wrapped in.
def literal_fence(source)
  longest = source.lines.map(&:chomp).grep(/\A\.{4,}\z/).map(&:length).max
  '.' * [4, longest.to_i + 1].max
end

# Errors the converter logged for the block just rendered, one line each.
def render_problems
  Asciidoctor::LoggerManager.logger.messages
                            .select { |m| %i[ERROR FATAL].include?(m[:severity]) }
                            .map { |m| m[:message].to_s.lines.first.to_s.strip }
end

# Render one block through asciidoctor-diagram, the same converter that renders it during
# an ordinary document build.
#
# This used to be a table of hand-written renderers — a second implementation of what the
# gem already does, which is how the list of supported types drifted away from the image
# without anyone noticing. Delegating means a diagram renders here exactly as it renders
# in the document, including the error handling: asciidoctor-diagram detects PlantUML's
# habit of emitting a plausible-looking "Syntax Error" image and writes no file at all,
# which the previous version had to undo with an rm_f.
#
# The block is wrapped in a document of its own so that `target` fixes the output name.
# Without it the gem names files by a hash of their content, and the caller could not
# predict what it just produced.
def diagram_registry
  Asciidoctor::Extensions.create { DIAGRAM_GROUPS.each_value { |group| instance_exec(&group) } }
end

def render_diagram(type, source, base_name, output_dir, cache_dir)
  Asciidoctor::LoggerManager.logger = Asciidoctor::MemoryLogger.new
  fence = literal_fence(source)

  Asciidoctor.load(
    "[#{type},target=#{base_name},format=svg]\n#{fence}\n#{source}\n#{fence}\n",
    safe: :unsafe,
    extension_registry: diagram_registry,
    # diagram-cachedir, or the extension writes .asciidoctor/diagram next to the document
    # — and this document has no path, so "next to" is the caller's working directory.
    # validate.sh redirects it for the same reason.
    attributes: { 'imagesoutdir' => output_dir, 'imagesdir' => '',
                  'diagram-cachedir' => cache_dir }
  ).convert

  problems = render_problems
  svg = File.join(output_dir, "#{base_name}.svg")

  # Both halves matter. A logged error with a file present means the gem wrote something
  # it is not happy with; a missing file without an error means it declined silently.
  # Either way nothing downstream should treat the result as a rendered diagram.
  rendered = problems.empty? && File.file?(svg)

  # And a file it is not happy with must not survive the run. The exit code says the
  # rendering failed, but a later step that reads the output directory sees only files --
  # so leaving one behind hands it a diagram nobody vouched for.
  FileUtils.rm_f(svg) unless rendered

  [rendered, problems]
end

doc = Asciidoctor.load_file(input_file, safe: :unsafe)

diagram_count = 0
render_failures = 0
cache_dir = render ? Dir.mktmpdir('adcw-diagram-cache') : nil

# Both delimiters count. `....` gives a literal block, `----` a listing block, and
# asciidoctor-diagram accepts either -- its own documentation uses `----` throughout, so
# matching only :literal missed the form most documents are written in and reported
# "No diagrams found" for them.
blocks = doc.find_by do |block|
  %i[literal listing].include?(block.context) &&
    block.style &&
    EXTRACTABLE_TYPES.include?(block.style.downcase)
end

# Names first, files second. Normalisation maps a set of ids onto a set of filenames, and
# no rule makes that mapping injective for every input a document may carry: keeping every
# component means `arch/overview` and `ui/overview` stay apart, but `arch/overview` and
# `arch_overview` still meet. Where two blocks land on one name the second would overwrite
# the first while the run reports both as processed -- silent loss, the one outcome this
# tool exists to prevent.
#
# Deciding this before anything is written is what makes the failure clean. Detecting it
# inside the writing loop would abort with the first diagram already on disk, and a later
# step reading the directory would find a partial result next to a non-zero exit.
planned = blocks.each_with_index.map do |diagram_block, index|
  fallback = "diagram_#{index + 1}"
  base_name = if diagram_block.id
                output_stem(diagram_block.id, fallback)
              elsif diagram_block.parent&.id
                output_stem("#{diagram_block.parent.id}_diagram_#{index + 1}", fallback)
              else
                fallback
              end
  { block: diagram_block, name: base_name,
    id: diagram_block.id || diagram_block.parent&.id || "(diagram #{index + 1}, no id)" }
end

planned.group_by { |entry| entry[:name] }.each_value do |entries|
  next if entries.length < 2

  warn "❌ #{entries.length} diagrams would be written as '#{entries.first[:name]}':"
  entries.each { |entry| warn "      #{entry[:id]}" }
  warn '   Give them ids that differ in more than a separator.'
  FileUtils.rm_rf(cache_dir) if cache_dir
  exit 1
end

planned.each do |entry|
  diagram_block = entry[:block]
  base_name = entry[:name]
  diagram_count += 1
  diagram_type = diagram_block.style.downcase

  source_content = diagram_block.source

  if %w[source both].include?(output_format)
    source_file = File.join(output_dir, "#{base_name}.#{diagram_type}")
    File.write(source_file, source_content)
    puts "   📄 Extracted source: #{base_name}.#{diagram_type}"
  end

  next unless render

  unless renderer_available?(diagram_type)
    hint = UNRENDERABLE_HINT[diagram_type]
    detail = hint ? " — #{hint}" : ''
    warn "   ❌ Cannot render #{diagram_type}: #{base_name}#{detail}"
    render_failures += 1
    next
  end

  rendered, problems = render_diagram(diagram_type, source_content, base_name,
                                      output_dir, cache_dir)

  if rendered
    puts "   🖼️  Rendered: #{base_name}.svg"
  else
    # The detail comes from the converter and names the offending line — worth passing
    # through rather than swallowing, because "Failed to render" alone sends the reader
    # back to the document with nothing to look for.
    warn "   ❌ Failed to render: #{base_name} (#{diagram_type})"
    problems.each { |problem| warn "      #{problem}" }
    render_failures += 1
  end
end

FileUtils.rm_rf(cache_dir) if cache_dir

puts ''
puts '📊 Extraction complete!'
puts "   Diagrams found: #{diagram_count}"
puts "   Output directory: #{output_dir}"

if diagram_count.zero?
  puts ''
  puts "💡 No diagrams found in #{input_file}"
  puts "   Extractable types: #{EXTRACTABLE_TYPES.join(', ')}"
  puts "   Of those, rendered here: #{RENDERABLE_TYPES.join(', ')}"
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
