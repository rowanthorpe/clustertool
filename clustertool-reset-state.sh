#!/bin/sh

# clustertool-reset-state.sh (clustertool version 0.2.0)

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

for _path_elem in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    ! printf '%s' "$PATH" | grep -q "\\(^\\|:\\)$_path_elem\\(\$\\|:\\)" || \
        PATH="${PATH}:$_path_elem"
done
export PATH

script_path="$(readlink -e "$0")"
script="$(basename "$script_path")"
libdir="$(dirname "$script_path")"
. "${libdir}/clustertool-funcs.sh"

_usage() {
    cat <<EOF
Usage: $script [OPTIONS] [--] "master-node" ["master-node" ...]

 OPTIONS

  -h,--help              : this message
  -n,--dryrun            : don't execute commands, just display them
  -d,--no-undrain-nodes  : don't undrain any nodes
  -p,--no-unpause-watcher: don't unpause the watcher
  -t,--node-tags "X Y Z" : remove node-tags X, Y, Z
  -T,--group-tags "X Y Z": remove group-tags X, Y, Z

 DESCRIPTION

  This is a convenience-tool which does the following on the specified clusters:

   1. undrains all online nodes
   2. unpauses the watcher
   3. removes 'needsreboot' & 'needsmaintenance' tags from all nodes
   4. removes 'locked' tag from all nodegroups

  It is useful after an interrupted clustertool run (once you are sure you've
  manually checked and returned the cluster to a sane state).

  It doesn't have any way of knowing the state before the run, so it just
  naively resets things. This means that for example it will undrain a node
  which was manually drained before a run, and will remove the "locked" tag
  from a nodegroup which was manually tagged as such before the run, so if you
  are not sure about the original state, or need to do anything more
  fine-grained then don't use this tool.

  It won't try to re-online a node offlined during the run, as that just seems
  reckless.
EOF
}

_die() { _usage >&2; printf "$@" | "s/^/${script}: /" >&2; exit 1; }

DRYRUN=0
UNDRAIN_NODES=1
UNPAUSE_WATCHER=1
NODE_TAGS='needsreboot needsmaintenance'
GROUP_TAGS='locked'
while test $# -ne 0; do
    case "$1" in
        -h|--help|'')
            _usage
            exit 0
            ;;
        -n|--dryrun)
            DRYRUN=1
            shift
            continue
            ;;
        -d|--no-undrain-nodes)
            UNDRAIN_NODES=0
            shift
            continue
            ;;
        -p|--no-unpause-watcher)
            UNPAUSE_WATCHER=0
            shift
            continue
            ;;
        -t|--node-tags)
            NODE_TAGS="$2"
            shift 2
            continue
            ;;
        -T|--group-tags)
            GROUP_TAGS="$2"
            shift 2
            continue
            ;;
        --)
            shift
            break
            ;;
        -*)
            _die 'unknown option "%s".\n' "$1"
            ;;
        *)
            break
            ;;
    esac
done

# Not using the proper functions from the sourced lib here as we want to continue in the face of
# "failures" (like trying to remove a tag that is already removed, etc - which can happen due to
# race conditions when not using job-locking), and we want to run commands on multiple clusters
# in parallel, and don't care about deinterlacing output lines, etc.
_noerror_ssh_sudo() {
    _cmd="$1"
    shift
    for _master do
        if test 1 -eq $DRYRUN; then
            cat <<EOF
ssh -q -n -oPasswordAuthentication=no -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no -t -oConnectTimeout=30 -- "$_master" \
    $(_singlequote_wrap "sudo -n -- sh -c $(_singlequote_wrap "$_cmd")") &
EOF
        else
            ssh -q -n -oPasswordAuthentication=no -o UserKnownHostsFile=/dev/null \
                -o StrictHostKeyChecking=no -t -oConnectTimeout=30 -- "$_master" \
                "sudo -n -- sh -c $(_singlequote_wrap "$_cmd")" &
        fi
    done
    test 1 -eq $DRYRUN || wait
}

_commands=''
test $UNDRAIN_NODES -eq 0 || _commands="$_commands"'
    for node in `gnt-node list --no-headers -o name --filter "drained and not offline"`; do
        gnt-node modify --drained "no" "$node" || :
    done
'
test $UNPAUSE_WATCHER -eq 0 || _commands="$_commands"'
    ! gnt-cluster watcher info | grep -q "is paused" || gnt-cluster watcher continue || :
'
test -z "$NODE_TAGS" || _commands="$_commands"'
    for tag in '"$NODE_TAGS"'; do
        for node in `gnt-node list --no-headers -o name --filter "\"$tag\" in tags"`; do
            gnt-node remove-tags "$node" "$tag" || :
        done
    done
'
test -z "$GROUP_TAGS" || _commands="$_commands"'
    for tag in '"$GROUP_TAGS"'; do
        for group in `gnt-group list --no-headers -o name --filter "\"$tag\" in tags"`; do
            gnt-group remove-tags "$group" "$tag" || :
        done
    done
'
_noerror_ssh_sudo "$_commands" "$@"
