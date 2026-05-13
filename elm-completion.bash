# elm bash completion for Click 7.x
#
# Installed to $XDG_DATA_HOME/bash-completion/completions/elm by 'make completion'.
# bash-completion 2.x sources this automatically — no manual sourcing needed.
#
# To regenerate after upgrading Click:
#   _ELM_COMPLETE=source_bash elm > elm-completion.bash
# Note: Click 7.1.2 generates '_elm_completionetup' (missing underscore before
# 'setup') due to a template bug. This file corrects that to '_elm_completion_setup'.

_elm_completion() {
    local IFS=$'\n'
    COMPREPLY=( $( env COMP_WORDS="${COMP_WORDS[*]}" \
                   COMP_CWORD=$COMP_CWORD \
                   _ELM_COMPLETE=complete $1 ) )
    return 0
}

_elm_completion_setup() {
    local COMPLETION_OPTIONS=""
    local BASH_VERSION_ARR=(${BASH_VERSION//./ })
    # Only BASH version 4.4 and later have the nosort option.
    if [ ${BASH_VERSION_ARR[0]} -gt 4 ] || ([ ${BASH_VERSION_ARR[0]} -eq 4 ] && [ ${BASH_VERSION_ARR[1]} -ge 4 ]); then
        COMPLETION_OPTIONS="-o nosort"
    fi

    complete $COMPLETION_OPTIONS -F _elm_completion elm
}

_elm_completion_setup
