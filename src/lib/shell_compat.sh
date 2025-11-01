#!/usr/bin/env bash

# shellcheck shell=bash

# Compatibility helpers so dline works under legacy Bash and Zsh.
if [[ -n ${ZSH_VERSION:-} ]]; then
    emulate -L bash
    setopt KSH_ARRAYS
    setopt BASH_REMATCH
    setopt SH_WORD_SPLIT

    if ! typeset -f shopt >/dev/null 2>&1; then
        shopt() {
            local action="$1"
            local option="$2"
            case "$option" in
                nocasematch)
                    case "$action" in
                        -s) setopt NO_CASE_MATCH ;;
                        -u) unsetopt NO_CASE_MATCH ;;
                        *) printf 'shopt: unsupported action %s\n' "$action" >&2; return 1 ;;
                    esac
                    ;;
                *)
                    printf 'shopt: unsupported option %s\n' "$option" >&2
                    return 1
                    ;;
            esac
        }
    fi
fi

to_upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

if ! type mapfile >/dev/null 2>&1; then
    mapfile() {
            local strip_newline=0
            while [[ $# -gt 0 && $1 == -* ]]; do
                case "$1" in
                    -t)
                        strip_newline=1
                        ;;
                    --)
                        shift
                        break
                        ;;
                    *)
                        printf 'mapfile: unsupported option %s\n' "$1" >&2
                        return 1
                        ;;
                esac
                shift
            done
            if [[ $# -lt 1 ]]; then
                printf 'mapfile: missing array name\n' >&2
                return 1
            fi
            local array_name=$1
            shift
            local IFS=$'\n'
            local line
            local -a data=()
            while IFS=$'\n' read -r line; do
                data+=("$line")
            done
            if (( ! strip_newline )); then
                local i
                for ((i=0; i<${#data[@]}; i++)); do
                    data[$i]+=$'\n'
                done
            fi
            eval "$array_name=(\"\${data[@]}\")"
    }
fi
