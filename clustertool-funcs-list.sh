## Don't set the shebang line, use $SHELL, or let the user specify on the
## commandline (colourisation is better from more powerful shells)

# clustertool-funcs-list.sh (clustertool version 0.2.0)

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

def_filelist='clustertool-funcs.sh clustertool-funcs-public.sh'
search_filelist='clustertool-funcs.sh clustertool-funcs-public.sh clustertool.sh clustertool-source-transform.sh'

# A: sed command
#    ...piped to...
# B: processing loop
#
# A1. skip to blank line
# A2. append next line
# A3. try replace function-definition line with just function-name
# A4. if successful replacement (matched a function-definition line) then print
#
# B1. read function-name
# B2. print divider line
# B3. grep all occurrences (with highlighting)

sed -n -e \
    '/^$/! b; N; s/^\n\([a-zA-Z_][a-zA-Z0-9_]*\) *() *{.*$/\1/; t PRINT; b; : PRINT; p' \
    $def_filelist | \
    while read funcname; do
        printf -- "%s================%s\n\n" "$BYELLOW" "$RESET"
        printf -- '%s%s%s\n' "$BPURPLE" "$funcname" "$RESET"
        for filename in $search_filelist; do
            if grep -q "\\<$funcname\\>" "$filename"; then
                printf -- "%s--------%s\n" "$BBLUE" "$RESET"
                printf -- '%s%s%s\n' "$BRED" "$filename" "$RESET"
                grep --color=always --line-number "\\<$funcname\\>" "$filename"
            fi
        done
        printf '\n'
    done
