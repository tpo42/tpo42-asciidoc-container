# Bash completion for adcw
# Source this file in .bashrc (adcw must be in PATH)

_adcw_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local commands="flatten validate extract-diagrams shell asciidoctor asciidoctor-pdf asciidoctor-reducer help"

    # After -i: show .adoc files and directories
    if [[ "${prev}" == "-i" ]]; then
        COMPREPLY=($(compgen -f -X '!*.adoc' -- "${cur}") $(compgen -d -- "${cur}"))
        return
    fi

    # After -o or -f: show all files and directories
    if [[ "${prev}" == "-o" || "${prev}" == "-f" ]]; then
        COMPREPLY=($(compgen -f -- "${cur}"))
        return
    fi

    # First argument: commands or -f
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "${commands} -f" -- "${cur}"))
        return
    fi

    # After -f <file>: commands
    if [[ "${COMP_WORDS[1]}" == "-f" && ${COMP_CWORD} -eq 3 ]]; then
        COMPREPLY=($(compgen -W "${commands}" -- "${cur}"))
        return
    fi

    # After command: options or files based on command
    local cmd="${COMP_WORDS[1]}"
    [[ "${COMP_WORDS[1]}" == "-f" ]] && cmd="${COMP_WORDS[3]}"

    case "${cmd}" in
        flatten|validate|extract-diagrams)
            if [[ "${cur}" == -* ]]; then
                COMPREPLY=($(compgen -W "-i -o" -- "${cur}"))
            else
                COMPREPLY=($(compgen -f -X '!*.adoc' -- "${cur}") $(compgen -d -- "${cur}"))
            fi
            ;;
        asciidoctor|asciidoctor-pdf|asciidoctor-reducer)
            COMPREPLY=($(compgen -f -X '!*.adoc' -- "${cur}") $(compgen -d -- "${cur}"))
            ;;
    esac
}

complete -o filenames -F _adcw_completions adcw
