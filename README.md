# ADCW - AsciiDoc Container Wrapper

A Ruby-native AsciiDoc toolchain in a container -- inspired by the [docToolchain](https://doctoolchain.org/) wrapper pattern (`dtcw`).

## Motivation

[docToolchain](https://doctoolchain.org/) is the reference toolchain for [arc42](https://arc42.org/) and [req42](https://req42.de/), covering a wide range of use cases (HTML, PDF, Confluence, Jira, jBake microsites, ...).

ADCW explores what a lean, Ruby-native container approach looks like for common AsciiDoc operations. It serves as a playground to experiment with different answers to the same use cases -- and to learn which approaches work well, which might feed back into docToolchain, and where docToolchain's existing solutions are already the right ones.

The container is designed to be **extensible via two paths**: `adcw` for fast, single-shot operations and [Dev Containers](https://containers.dev/) for extended setups with custom fonts, Jekyll, or additional gems (see [ADR-005](adr/adr-005.adoc)).

## Quick Start

```bash
# Build the container (uses your host UID/GID for clean file permissions)
./bin/adcbw

# Generate a PDF
./bin/adcw asciidoctor-pdf mydoc.adoc

# Flatten includes for LLM context
./bin/adcw flatten -i architecture.adoc -o build/architecture-flat.adoc

# Validate AsciiDoc syntax
./bin/adcw validate -i '*.adoc'

# Interactive shell
./bin/adcw shell
```

## Commands

| Command | Description |
|---------|-------------|
| `flatten` | Resolve all `include::` directives into a single self-contained document |
| `validate` | Best-effort AsciiDoc syntax checking |
| `extract-diagrams` | Extract PlantUML/Graphviz/Mermaid sources for analysis |
| `asciidoctor` | Run asciidoctor directly (HTML output) |
| `asciidoctor-pdf` | Generate PDF documents |
| `asciidoctor-reducer` | Run asciidoctor-reducer directly |
| `shell` | Interactive container shell for debugging |

## Extending the Container

Projects that need nothing beyond the base toolchain use `adcw` directly -- no extra setup needed.

For projects that need more (custom fonts, Jekyll, additional gems), the recommended path is a [Dev Container](https://containers.dev/) configuration:

```json
// .devcontainer/devcontainer.json
{
  "image": "tpo42/adoc:latest",
  "postCreateCommand": "bundle install",
  "forwardPorts": [4000]
}
```

For custom fonts or system packages, use a derived Dockerfile:

```json
// .devcontainer/devcontainer.json
{
  "build": { "dockerfile": "Dockerfile" },
  "forwardPorts": [4000]
}
```

```dockerfile
# .devcontainer/Dockerfile
FROM tpo42/adoc:latest
COPY fonts/ /usr/share/fonts/custom/
RUN fc-cache -f
```

The [devcontainer CLI](https://github.com/devcontainers/cli) runs these setups outside of VS Code:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . asciidoctor-pdf mydoc.adoc
devcontainer exec --workspace-folder . flatten -i arch.adoc -o build/arch-flat.adoc
```

Developer workstations and CI pipelines use the same `devcontainer.json` -- there is no separate setup path. See [ADR-005](adr/adr-005.adoc) for the full rationale.

## Container Stack

```
ruby:3-trixie                    Debian 13, Ruby 3.x (ADR-001)
  └─ tpo42/adoc                  AsciiDoc toolchain + Bundler 4.x (ADR-003)
      └─ .devcontainer/          Fonts, Jekyll, extra gems (ADR-005)
```

### Pre-installed AsciiDoc Toolchain

| Gem | Purpose |
|-----|---------|
| `asciidoctor` ~> 2.0 | Core AsciiDoc processor |
| `asciidoctor-pdf` ~> 2.3 | PDF generation |
| `asciidoctor-reducer` ~> 1.0 | Include resolution / flattening |
| `asciidoctor-diagram` ~> 3.0 | PlantUML, Graphviz, Mermaid, Ditaa integration |
| `asciidoctor-revealjs` ~> 5.2 | Presentation slides |
| `asciidoctor-epub3` ~> 2.2 | EPUB3 generation (experimental, ADR-004) |
| `asciidoctor-bibtex` ~> 0.8 | Bibliography support |
| `asciidoctor-kroki` ~> 0.10 | Extended diagram rendering via Kroki |
| `rouge` ~> 4.6 | Syntax highlighting |

### System Tools

- **PlantUML + Graphviz** -- diagram rendering
- **Java Runtime** -- required by PlantUML
- **Git + Git-LFS** -- repository operations
- **Standard Unix tools** -- bash, curl, wget, make, ssh, etc.

## How It Relates to docToolchain

ADCW explores Ruby-native alternatives for common docToolchain use cases. Some may turn out better, some may confirm that docToolchain's existing approach is already the right one:

| docToolchain task | ADCW equivalent |
|-------------------|-----------------|
| `generateHTML` | `adcw asciidoctor` |
| `generatePDF` | `adcw asciidoctor-pdf` |
| `generateDeck` | `adcw asciidoctor -r asciidoctor-revealjs` |
| `collectIncludes` / flatten | `adcw flatten` |
| `generateSite` (jBake) | Jekyll via devcontainer (see ADR-005) |
| `publishToConfluence` | open |
| Jira integration | open |
| `htmlSanityCheck` | `adcw validate` (different scope) |

## Project Structure

```
tpo42-asciidoc-container/
├── adr/                          Architecture Decision Records
│   ├── adr-001.adoc             Base image: ruby:3-trixie
│   ├── adr-002.adoc             Remove pre-commit from container
│   ├── adr-003.adoc             Upgrade Bundler to 4.x
│   ├── adr-004.adoc             Include EPUB3 capability
│   └── adr-005.adoc             Extensibility: adcw + devcontainer
├── bin/
│   ├── adcbw                     Build wrapper
│   └── adcw                      CLI wrapper (command dispatcher)
├── container/
│   ├── Containerfile            Container build definition
│   ├── Gemfile                  Base gem dependencies
│   ├── bashrc.bsp               Shell environment for container user
│   ├── extra-packages           System package list
│   └── resources/               Command scripts (plugin system)
│       ├── extract-diagrams.sh
│       ├── flatten.sh
│       └── validate.sh
├── LICENSE.txt                  CC-BY-SA-4.0
└── README.md
```

## Volume Mapping

| Host | Container | Purpose |
|------|-----------|---------|
| `${PWD}` | `/workspace` | Project source files |
| `${PWD}/build` | `/build` | Generated output |

## Container Versioning

Tags are derived from `git describe`:

| Git state | Container tag |
|-----------|---------------|
| `heads/main` | `latest` |
| `heads/feature/xyz` | `feature-xyz` |
| `v1.0.0` | `v1.0.0` |
| dirty working tree | `*-dirty` |

## Container Runtime

The wrapper auto-detects available container runtimes (in priority order):

1. `container` -- Apple macOS 26+ native
2. `nerdctl` -- containerd native CLI
3. `finch` -- AWS alternative
4. `podman` -- daemonless container engine
5. `docker` -- traditional fallback

## Architecture Decisions

All significant decisions are documented as ADRs in `adr/`:

- **ADR-001**: Base image `ruby:3-trixie` over bookworm
- **ADR-002**: Remove pre-commit and Python dependencies from container
- **ADR-003**: Upgrade Bundler pin from ~> 2.0 to ~> 4.0
- **ADR-004**: Include experimental EPUB3 generation capability
- **ADR-005**: Extensibility strategy -- adcw for speed, devcontainer for comfort

## tpo42 Framework

ADCW is part of the [tpo42 Framework](https://www.tpo42.de/) initiative, combining [arc42](https://arc42.org/) (architecture documentation) and [req42](https://req42.de/) (requirements engineering) with lean, modern tooling.

## License

CC-BY-SA-4.0 -- see [LICENSE.txt](LICENSE.txt)
