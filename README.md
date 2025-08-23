# ADCW - AsciiDoc Container Wrapper

**AsciiDoc Container Wrapper** for fast, clean AsciiDoc operations with containerized toolchain.

## Overview

ADCW follows the proven docToolchain pattern (`dtcw`) and provides a containerized AsciiDoc environment for:

- **Self-contained Documents:** Include resolution for LLM context
- **Diagram Handling:** PlantUML/Graphviz source code extraction
- **Syntax Validation:** Best-effort checking of AsciiDoc sources
- **Quick Operations:** CLI tools for development workflow

## Project Structure

```
├── bin
│   ├── adcbw
│   └── adcw
├── container
│   ├── bashrc.bsp
│   ├── Containerfile
│   ├── extra-packages
│   ├── extra-packages.pre-commit
│   ├── Gemfile
│   ├── requirements.pre-commit.txt
│   └── resources
│       ├── extract-diagrams.sh
│       ├── flatten.sh
│       └── validate.sh
├── LICENSE.txt
└── README.md
```

## Requirements & Constraints

### Core Requirements

1. **Self-contained Documents**
   - Resolve all `include::` directives to single `.adoc` file
   - **Goal:** LLM context preparation - 1-2 files instead of 20+
   - **Diagrams:** Preserve source code for LLM understanding

2. **Diagram Handling**
   - Make PlantUML, Graphviz, etc. available in build/ directory
   - **Source preservation:** Diagram code more important for LLM than rendered images
   - **CLI-focused:** No complex build pipeline needed

3. **Syntax Validation**
   - Best-effort AsciiDoc syntax checking
   - **Scope:** Project-internal content (no web link validation)
   - **Tools:** What AsciiDoc provides out-of-the-box

### Design Constraints

- **Container:** Only tools (Ruby + AsciiDoc + diagram tools)
- **Host:** Wrapper scripts + command logic
- **Pattern:** docToolchain-inspired (`dtcw` → `adcw`)
- **Base Image:** `ruby:3-bookworm` (consistent with Jekyll container)
- **User Mapping:** Proper UID/GID handling for file permissions

## Usage

### Container Management

```bash
# Build container
./bin/adcbw

# Interactive shell
./bin/adcw shell
```

### AsciiDoc Operations

```bash
# Include resolution (self-contained for LLM)
./bin/adcw flatten -i requirements.adoc -o build/requirements-flat.adoc

# Syntax validation
./bin/adcw validate -i architecture.adoc

# Diagram extraction
./bin/adcw extract-diagrams -i overview.adoc -o build/diagrams/

# Direct asciidoctor commands
./bin/adcw asciidoctor mydoc.adoc
./bin/adcw asciidoctor-pdf mydoc.adoc
```

### Development Workflow

```bash
# Quick validation during development
./bin/adcw validate -i $(find . -name "*.adoc")

# LLM context preparation
./bin/adcw flatten -i arc42-architecture.adoc -o llm-context/architecture.adoc
./bin/adcw flatten -i req42-requirements.adoc -o llm-context/requirements.adoc

# Interactive debugging
./bin/adcw shell
# → asciidoctor --trace mydoc.adoc
```

## Technical Architecture

### Container Components

**Base:** `ruby:3-bookworm`
- Modern Ruby environment
- Debian-based for package availability
- Consistent with Jekyll container

**AsciiDoc Toolchain:**
- `asciidoctor` - Core processor
- `asciidoctor-pdf` - PDF generation
- `asciidoctor-diagram` - PlantUML/Graphviz support
- `rouge` - Syntax highlighting

**System Tools:**
- Git for repository operations
- PlantUML for diagram processing
- Graphviz for graph rendering
- Basic Unix tools (bash, curl, etc.)

**Optional Components:**
```dockerfile
# embedding pre-commit into container
# (can be activated if needed)
```

### Volume Mapping

```bash
# Workspace
--volume "${PWD}:/workspace"

# Build output
--volume "${PWD}/build:/build" 

# Cache (optional)
--volume "${PWD}/.adoc-cache:/cache"
```

### User Mapping

Container respects host user for clean file permissions:

```bash
--build-arg=USER_UID="$(id -u)"
--build-arg=USER_GID="$(id -g)" 
--build-arg=USER_NAME="$(id -un)"
--build-arg=USER_GROUP_NAME="$(id -gn)"
```

## Command Architecture

### Plugin System

Commands implemented as shell scripts in `resources/`:

- `flatten.sh` - Include resolution logic
- `validate.sh` - Syntax checking logic
- `extract-diagrams.sh` - Diagram extraction logic

### Wrapper Logic

`adcw` recognizes commands and maps them to container operations:

```bash
adcw <command> <args> → docker run ... tpo42/adoc:tag resources/<command>.sh <args>
```

## Container Versioning

Git-based container tags (like docToolchain):

```bash
# Git describe → Container tag
heads/main → latest
heads/feature/xyz → feature-xyz
v1.0.0 → v1.0.0
dirty → latest-dirty
```

## Integration

### tpo42 Framework

ADCW is optimized for tpo42 templates:
- req42/arc42 chapter structure
- Cross-reference resolution  
- Template-specific validation

### Development Workflow

```bash
# tpo42 template development
adcw flatten -i tpo42-template.adoc -o build/
adcw validate -i req42-chapters/*.adoc
adcw extract-diagrams -i arc42-views.adoc -o build/diagrams/
```

### LLM Integration

Self-contained documents for AI sparring:

```bash
# Prepare context for LLM discussion
adcw flatten -i architecture.adoc -o llm-context/complete-architecture.adoc

# → Single file with all includes + diagram source
# → Perfect for LLM technical discussions
```

## Roadmap

### Phase 1: MVP (Current)
- ✅ Container with AsciiDoc toolchain
- ✅ Basic wrapper (build/run)
- ✅ flatten, validate, extract-diagrams commands

### Phase 2: Enhancement
- [ ] Template-specific validation rules
- [ ] Performance optimization (caching)
- [ ] Extended diagram support (mermaid, etc.)

### Phase 3: Community
- [ ] tpo42 community sharing
- [ ] Blog post about container strategy
- [ ] Docker-library ruby template contribution

## Contributing

ADCW follows established patterns:
- **Code Style:** Consistent with docToolchain approach
- **Container Design:** User mapping, proper volumes, clean separation
- **Command Pattern:** Extensible plugin architecture

## License

CC-BY-SA-4.0 License - Part of the tpo42 Framework Initiative

---

**Next:** `./bin/adcbw && ./bin/adcw flatten -i mydoc.adoc -o build/mydoc-flat.adoc` 🚀
