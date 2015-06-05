#!/bin/sh

# clustertool-source-transform.sh (clustertool version 0.2.0)

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

# xx_FUNC: generates logging of markers for entry and exit points of all
#          public functions, and injects boilerplate code for _getargs()
# xx_LOOP: expands macros for parallelising for-loops over "$@"
# xx_BLOCK: expands macros for parallelising sequential blocks

# NB: this is used on clustertool-funcs-public.sh only, so for example
# it doesn't add boilerplate for _getargs usage in
# clustertool-funcs.sh (it is safer to always keep private function
# code explicit anyway)

# Try to get as much consistency between shells as possible
# TODO: adding $KSH_VERSION to this test works for pdksh but kills ksh
#       (how to distinguish between those two shells?)
test -z "$BASH_VERSION" || set -o posix

# Make zshell behave similarly to other shells
if test -n "$ZSH_VERSION"; then
    setopt shglob
    setopt bsdecho
    setopt shwordsplit
    NULLCMD=':'
    export NULLCMD
    emulate sh
fi

_exit() { _retval="$1"; rm -f "$_tempfile1" "$_tempfile2" "$_tempfile3" >/dev/null 2>&1; exit $_retval; }

_tempfile1="$(mktemp)" && _tempfile2="$(mktemp)" && _tempfile3="$(mktemp)" && \
    sed -n -e '/^#### BEGIN_FUNC ####$/,/^#### END_FUNC ####$/ {s/^# //; p}' "$0" >"$_tempfile1" && \
    sed -n -e '/^#### BEGIN_LOOP ####$/,/^#### END_LOOP ####$/ {s/^# //; p}' "$0" >"$_tempfile2" && \
    sed -n -e '/^#### BEGIN_BLOCK ####$/,/^#### END_BLOCK ####$/ {s/^# //; p}' "$0" >"$_tempfile3" && \
    sed -f "$_tempfile1" | \
    sed -f "$_tempfile2" | \
    sed -f "$_tempfile3"
_exit ${?:-$status}

#### BEGIN_FUNC ####
# : BEGIN_FIND
# x
# /^$/ b BEGIN_FOUND1
# n
# b BEGIN_FIND
# : BEGIN_FOUND1
# x
# /^[[:alpha:]][_[:alnum:]]*[[:space:]]*()[[:space:]]*{/ b BEGIN_FOUND2
# x
# n
# b BEGIN_FIND
# : BEGIN_FOUND2
# s/^\(\([[:alpha:]][_[:alnum:]]*\)[[:space:]]*()[[:space:]]*{.*\)$/\1\n    funcnames="$funcnames\n\2"\n    _log_mark begin_func "$(printf '%s' "$funcnames" | tail -n 1)" "$@"\n/
# s/{ \{1,\}\(_getargs '[^']\{1,\}'\)\(.*\n\)\(.*\n.*\n.*\)\n$/{\n\3\n    \1 "$@"; shift $_to_shift\2/
# x
# n
# : END_FIND
# x
# /^}$/ b END_FOUND1
# n
# b END_FIND
# : END_FOUND1
# x
# /^$/ b END_FOUND2
# x
# n
# b END_FIND
# : END_FOUND2
# x
# s/^/\n    _log_mark end_func "$(printf '%s' "$funcnames" | tail -n 1)"\n    funcnames="$(printf '%s' "$funcnames" | head -n -1)"\n/
# n
# b BEGIN_FIND
#### END_FUNC ####

#### BEGIN_LOOP ####
# : BEGIN_FIND
# /^[[:space:]]*for[[:space:]]\{1,\}[_[:alpha:]][_[:alnum:]]*[[:space:]]\{1,\}do[[:space:]]*#\{1,\}[[:space:]]*@PAR_LOOP_BEGIN@/ b BEGIN_FOUND
# n
# b BEGIN_FIND
# : BEGIN_FOUND
# s/^\([[:space:]]*\)\(for[[:space:]]\{1,\}[_[:alpha:]][_[:alnum:]]*[[:space:]]\{1,\}do[[:space:]]*\)#\{1,\}[[:space:]]*@PAR_LOOP_BEGIN@.*$/\1proc_id=\$\$\n\1\2\n\1    {\n\1        {/
# n
# : END_FIND
# /^[[:space:]]*done[[:space:]]*#\{1,\}[[:space:]]*@PAR_LOOP_END@/ b END_FOUND
# n
# b END_FIND
# : END_FOUND
# s/^\([[:space:]]*\)\(done\)[[:space:]]*#\{1,\}[[:space:]]*@PAR_LOOP_END@.*$/\1        } | _stdout_write \$proc_id\n\1    } \&\n\1    test 1 -eq \$parallel || wait \$!\n\1\2\n\1wait/
# n
# b BEGIN_FIND
#### END_LOOP ####

#### BEGIN_BLOCK ####
# : BEGIN_FIND
# /^[[:space:]]*#\{1,\}[[:space:]]*@PAR_BLOCK_BEGIN@/ b BEGIN_FOUND
# n
# b BEGIN_FIND
# : BEGIN_FOUND
# s/^\([[:space:]]*\)#\{1,\}[[:space:]]*@PAR_BLOCK_BEGIN@.*$/\1{/
# n
# : OTHER_FIND
# /^[[:space:]]*#\{1,\}[[:space:]]*@PAR_BLOCK_BARRIER@/ b BARRIER_FOUND
# /^[[:space:]]*#\{1,\}[[:space:]]*@PAR_BLOCK_END@/ b END_FOUND
# n
# b OTHER_FIND
# : BARRIER_FOUND
# s/^\([[:space:]]*\)#\{1,\}[[:space:]]*@PAR_BLOCK_BARRIER@.*$/\1} \&\n\1test 1 -eq \$parallel || wait\n\1{/
# n
# b OTHER_FIND
# : END_FOUND
# s/^\([[:space:]]*\)#\{1,\}[[:space:]]*@PAR_BLOCK_END@.*$/\1}/
# n
# b BEGIN_FIND
#### END_BLOCK ####
