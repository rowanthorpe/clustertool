## Don't set the shebang line, use $SHELL, or let the user specify on the
## commandline (colourisation is better from more powerful shells)

# clustertool-highlight-words.sh (clustertool version 0.2.0)

#  clustertool: a tool for automating/abstracting cluster operations
#  Copyright © 2013-2015 Greek Research and Technology Network (GRNET S.A.)
#
#  Developed by Rowan Thorpe (rowan-at-noc-dot-grnet-dot-gr) with
#  additional contributions noted in the AUTHORS file in this distribution.
#
#  This file is part of clustertool.
#
#  clustertool is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  clustertool is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with clustertool. If not, see <http://www.gnu.org/licenses/>.

## Usage: ./clustertool-highlight-words.sh "logfilename" "word1" "word2" ...
#
#   Up to 12 distinct colours are cycled through in a loop.
#   Due to the way the colourising is done (and lack of terminal
#   flexibility) you will run into problems if you try to highlight
#   single capital letters or the underscore character. This shouldn't
#   usually be a problem as this is a *word* highlighter, not a *letter*
#   highlighter :-P
#
# EXAMPLE
#
#   ./clustertool-highlight-words.sh /tmp/tmp.fxddFxG2r6/clustertool-roll-2817.log \
#       CMD_i CMD_n CMD_t CMD_s INFO MARK WARN ERROR begin_func end_func start finish resume | \
#       less -R -S

if test -n "$ZSH_VERSION"; then
    setopt shglob
    setopt bsdecho
    setopt shwordsplit
    NULLCMD=':'
    export NULLCMD
    emulate sh
    autoload colors && colors
    eval RESET='$reset_color'
    for COLOR in RED GREEN YELLOW BLUE MAGENTA CYAN BLACK WHITE; do
        eval $COLOR='$fg_no_bold[${(L)COLOR}]'
        eval B$COLOR='$fg_bold[${(L)COLOR}]'
    done
elif test -n "$BASH_VERSION"; then
    set -o posix
    RESET=$'\e[0m'
    RED=$'\e[0;31m'
    GREEN=$'\e[0;32m'
    YELLOW=$'\e[0;33m'
    BLUE=$'\e[0;34m'
    PURPLE=$'\e[0;35m'
    CYAN=$'\e[0;36m'
    WHITE=$'\e[0;37m'
    BRED=$'\e[1;31m'
    BGREEN=$'\e[1;32m'
    BYELLOW=$'\e[1;33m'
    BBLUE=$'\e[1;34m'
    BPURPLE=$'\e[1;35m'
    BCYAN=$'\e[1;36m'
    BWHITE=$'\e[1;37m'
else
    # Otherwise try this if tput is present (may not be)
    BOLD="$(tput bold 2>/dev/null)"
    RESET="$(tput sgr0 2>/dev/null)"
    RED="$(tput setaf 1 2>/dev/null)"
    GREEN="$(tput setaf 2 2>/dev/null)"
    YELLOW="$(tput setaf 3 2>/dev/null)"
    BLUE="$(tput setaf 4 2>/dev/null)"
    PURPLE="$(tput setaf 5 2>/dev/null)"
    CYAN="$(tput setaf 6 2>/dev/null)"
    WHITE="$(tput setaf 7 2>/dev/null)"
    BRED="$BOLD$RED"
    BGREEN="$BOLD$GREEN"
    BYELLOW="$BOLD$YELLOW"
    BBLUE="$BOLD$BLUE"
    BPURPLE="$BOLD$PURPLE"
    BCYAN="$BOLD$CYAN"
    BWHITE="$BOLD$WHITE"
fi

_file="$1"
shift || exit 1

eval "$(
    printf "sed -e \""
    for _counter in $(seq 0 $(expr $# - 1) ); do
        printf "s/\\\\\\\\($(eval "printf '%s' \"\$$(expr 1 + $_counter)\" | sed -e 's/\\\\/\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/g; s/\\[/\\\\\\\\\\\\\\\\[/g; s/\\\$/\\\\\\\\\\\\\\\\\\\\\\\\\$/g; s/\\*/\\\\*/g; s/\`/\\\\\`/g; s/\"/\\\\\"/g'")\\\\\\\\)/{{{{{$(
            case "$(expr 1 + \( $_counter % 12 \) )" in
                1)
                    printf 'RED'
                    ;;
                2)
                    printf 'GREEN'
                    ;;
                3)
                    printf 'YELLOW'
                    ;;
                4)
                    printf 'BLUE'
                    ;;
                5)
                    printf 'PURPLE'
                    ;;
                6)
                    printf 'CYAN'
                    ;;
                7)
                    printf 'BRED'
                    ;;
                8)
                    printf 'BGREEN'
                    ;;
                9)
                    printf 'BYELLOW'
                    ;;
                10)
                    printf 'BBLUE'
                    ;;
                11)
                    printf 'BPURPLE'
                    ;;
                12)
                    printf 'BCYAN'
                    ;;
            esac | sed -e 's/\(.\)/\1_/g'
            )}}}}}\\\\\\\\1{{{{{R_E_S_E_T_}}}}}/g; "
    done | sed -e '$ s/; $//'
    printf '" "%s" | sed -e "' "$_file"
    for _col in RED GREEN YELLOW BLUE PURPLE CYAN BRED BGREEN BYELLOW BBLUE BPURPLE BCYAN RESET; do
        printf "s/{{{{{$(printf '%s' "$_col" | sed -e 's/\(.\)/\1_/g')}}}}}/\$${_col}/g; "
    done | sed -e '$ s/; $//'
    printf '"'
)"
