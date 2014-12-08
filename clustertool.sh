#!/bin/sh

# clustertool.sh (clustertool version 0.2.0)

#  clustertool: a tool for automating/abstracting cluster operations
#  Copyright © 2013-2014 Greek Research and Technology Network (GRNET S.A.)
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
    setopt shwordsplit
    NULLCMD=':'
    export NULLCMD
fi

for _path_elem in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    ! printf '%s' "$PATH" | grep -q "\\(^\\|:\\)$_path_elem\\(\$\\|:\\)" || \
        PATH="${PATH}:$_path_elem"
done
export PATH

script_path="$(readlink -e "$0")"
script="$(printf '%s' "$script_path" | sed -e 's:^.*/\([^/]\+\)$:\1:')"
script_id=''

## source functions (default values, which are changed below in getopts, are set
##                   in clustertool-funcs.sh)
libdir="$(printf '%s' "$script_path" | sed -e 's:/[^/]*$::')"
test -n "$libdir" || libdir='/'
. "${libdir}/clustertool-funcs.sh"

trap '_die_s 129 "" "caught HUP interrupt\\n"' HUP
trap '_die_s 143 "" "caught TERM interrupt\\n"' TERM
trap '_die_s 131 "" "caught QUIT interrupt\\n"' QUIT
trap '_die_s 130 "" "caught INT interrupt\\n"' INT

invocation_cmdline=$(_array_wrap "$script_path" "$@")

## overrides

_usage() {
    cat <<EOF
Usage: $script COMMAND OPTIONS "master-node" ["master-node" ...]

 COMMAND

  roll                       : reboot nodes/nodegroups/clusters in groups of
                               nodes which can tolerate rebooting together
                               (worst-case = one node-at-a-time)
  kill                       : kill all instances, then shutdown all nodes, wait
                               for them to all return to operational then run
                               watchers to restore clusters
  test [string-to-eval]      : eval the string-argument directly following the
                               "test" command in the context of the script in
                               dryrun mode after option-parsing, and then exit
                               - this is useful for testing internal functions,
                               but BE CAREFUL (it blindly evals the arg) - when
                               in doubt use the dryrun flag too

 OPTIONS

 ==> basic options

  -h,--help                  : this message
  -q,--quiet                 : the opposite of --verbose (default)
  -S,--source                : show source code with all sourced libs and reader
                               macros expanded and code generation done inline
  -V,--version               : output clustertool version information

 ==> required options (for now until bugs are fixed)

  -s,--serial-nodes          : roll nodes serially regardless of other settings
                               implied by the arguments

 ==> recommended options (for now until the tool stabilises)

  -b,--no-batch              : have an interactive prompt before every invasive
                               action (for testing/monitoring clustertool
                               behaviour safely), rather than just using
                               defaults based on other flags (implies --verbose)
  -v,--verbose               : increase output

 ==> well-tested options

  -a,--alerts                : send alerts to logged in users,update /etc/motd
  -B,--skip-recent XX        : skip rolling-reboot of nodes that clustertool has
                               rolling-rebooted in the last XX days
  -c,--custom-cmds-string XX : string containing custom commands to run on each
                               node just before rebooting
  -C,--custom-cmds-file XX   : local file containing custom commands to run on
                               each node just before rebooting (if -c and -C are
                               both specified -C will always be run first)
  -d,--log-dir XX            : set the log-dir (defaults to the system temp-dir)
  -E,--no-test-version       : don't get Ganeti version or investigate the need
                               for workarounds (presume lowest common
                               denominator)
  -g,--no-reboot-groups      : when cycling by cluster or nodegroup calculate
                               nodes for rolling by iterating serially rather
                               than using tools like hroller (implies
                               --serial-nodes)
  -K,--skip-non-vm-capable   : skip processing non-vm-capable nodes even if they
                               are implied by the arguments
  -l,--dont-lock-cluster     : don't drain the queue and wait for it to empty
                               before running (NB: this is risky!)
  -L,--dont-lock-node        : don't migrate the node atomically, migrate
                               instance at a time without preventing other
                               actions on the node (NB: this is really risky!)
  -m,--mailto XX             : email log to recipient on errors/completion
  -M,--skip-master           : skip processing the master node even if it is
  -n,--dryrun                : only output invasive commands - don't execute
  -o,--no-log                : don't use a log file (not recommended except for
                               testing)
  -p,--pause-watcher         : pause the watcher during actions (probably only
                               useful for debugging)
  -r,--resume XX             : don't tag nodes before running (useful when
                               continuing a previously interrupted run), arg can
                               be "last" which appends to the last updated log
                               file (or a new one if missing), or can be the pid
                               of the previous run (see the logfile names for
                               the pid)
  -R,--no-rebalance          : don't do any rebalancing on completion
  -t,--dryrun-no-tag         : also don't execute (un)tag commands in --dryrun
  -T,--no-timestamps         : don't include timestamp entries in the logs

 ==> not well-tested options (pay extra attention when using these)

  -e,--evacuate              : also clear secondaries from nodes before reboot
  -G,--nodegroups XX         : space-separated list of nodegroups to match for
                               tagging nodes for reboot
  -I,--instances XX          : *TODO*: space-separated list of instances to tag
                               the containing nodes for reboot (matches primary
                               and with --evacuate also matches secondary)
  -N,--nodes XX              : space-separated list of nodes to tag for reboot
                               (this also implies --serial-nodes)
  -O|--monitor-trigger XX    : template for warning an external monitor (e.g.
                               icinga) that a node is about to go down
  -u|--monitor-check-up XX   : template for checking with external monitor if a
                               node is up, also used instead of ping-sleep-loop
                               for checking node-state at various points
  -x,--maintenance           : rather than rebooting each node shut it down and
                               wait for manual boot before continuing

 ==> very experimental options (not tested yet, YMMV)

  -A,--also-offline-drained  : also process nodes which are already manually
                               offlined or drained (not recommended)
  -i,--non-redundant-action X: what to do with non-redundant instances:
                               + skip (default) - skip containing-nodes entirely
                               + ignore - presume non-redundant instances can
                                 tolerate unexpected reboots, and roll nodes
                                 without moving those instances
                               + move - move the instances to other nodes (and
                                 then back)
                               *NB* "-i" presently inherits the apparent
                               ganeti/htools presumption that "non-redundant"
                               means "not drbd, blockdev or diskless" (which
                               makes life difficult for users of ext and rbd).
                               Until that is resolved upstream those people
                               should just use the -g and -R flags to avoid use
                               of hroller and hbal and rebalance the cluster
                               manually after rolling it.

 ==> broken options (don't use until bugs are fixed)

  -P,--parallel              : when tools like hroller are used nodes within
                               reboot-groups roll in parallel by default - this
                               option causes spawning of subshells to process as
                               many other parts of the script as possible in
                               parallel too (EXPERIMENTAL)

 DESCRIPTION

  This is a tool for automating/abstracting many operations on Ganeti (and other
  frameworks in future). At present it is primarily focused on automating
  rolling reboots or instances-and-nodes kills, and requires Ganeti to be at
  least version 2.9

  It is really just a thin wrapper for functions in clustertool-funcs-public.sh
  - which can also be sourced and used from your own scripts.

 EXAMPLES

  When using --monitor-trigger and --monitor-check-up templates the {} is
  replaced with the (quote-escaped) node name in the template, for example:

    --monitor-trigger '\\
        _ssh_sudo 1 normal icinga.domain.com \\
            "/usr/local/bin/sched_downtime {} 36000"'

     => ... "/usr/local/bin/sched_downtime 'node-name' 36000"

  ...the monitor-trigger should return zero unless something is wrong enough to
  stop clustertool, and the return value of the monitor-check-up is how the
  state of the node is indicated. Unlike --custom-cmds-file and
  --custom-cmds-string (which are run on the node inside _ssh_sudo), the monitor
  commands are eval-ed as-is, as they often need to be run on a different server
  entirely (e.g. a downtime command on an Icinga server). This means:
   * the necessary ssh commands (or wrapper functions from clustertool) need to
     be included (see above example)
   * if not using clustertool wrapper-ssh commands, there is no "dryrun"
     handling so you must either omit the flag during dryruns, or add your own
     handling of the \$dryrun variable

EOF
}

## get command arg
command="$1"
test 0 -eq $# || shift
case "$command" in
    -h|--help)
        _usage
        _exit
        ;;
    -V|--version)
        cat <<EOV
clustertool $clustertool_version
Copyright © 2013-2014 Greek Research and Technology Network (GRNET S.A.)
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
EOV
        _exit
        ;;
    -S|--source)
        sed -e 's:^\. "\${libdir}/clustertool-funcs\.sh"$:#### BEGIN SOURCED PRIVATE LIB ####:; t END; b; : END; q' "$script_path" && \
            sed -e 's%^eval "\$(cat "\${libdir}/clustertool-funcs-public\.sh" | "\${libdir}/clustertool-source-transform\.sh")"$%#### BEGIN PROCESSED AND SOURCED PUBLIC LIB ####%; t END; b; : END; q' "${libdir}/clustertool-funcs.sh" && \
            cat "${libdir}/clustertool-funcs-public.sh" | "${libdir}/clustertool-source-transform.sh" && printf '\n' && \
            printf '#### END PROCESSED AND SOURCED PUBLIC LIB ####\n' && \
            sed -e '1,/^eval "\$(cat "\${libdir}\/clustertool-funcs-public\.sh" | "\${libdir}\/clustertool-source-transform\.sh")\"\$/ d' "${libdir}/clustertool-funcs.sh" && \
            printf '#### END SOURCED PRIVATE LIB ####\n' && \
            sed -e '1,/^\. "\${libdir}\/clustertool-funcs\.sh"$/ d' "$script_path"
        _exit
        ;;
    test)
        test_string="$1"
        shift || _die_u 'no string argument provided for testing.\n'
        ;;
    roll)
        true
        ;;
    *)
        _die_u 'command "%s" not implemented (yet?).\n' "$command"
        ;;
esac

## getopts
while test $# -ne 0; do
    case "$1" in
        -h|--help|-V--version|-S|--source)
            _cleanup
            exec "$script_path" "$1"
            ;;
        -v|--verbose)
            verbose=1
            shift
            continue
            ;;
        -q|--quiet)
            verbose=0
            shift
            continue
            ;;
        -n|--dryrun)
            dryrun=1
            shift
            continue
            ;;
        -t|--dryrun-no-tag)
            dryrun_no_tag=1
            shift
            continue
            ;;
        -b|--no-batch)
            batch=0
            shift
            continue
            ;;
        -r|--resume)
            resume=1
            _resume_id="$2"
            shift 2
            continue
            ;;
        -e|--evacuate)
            evacuate=1
            shift
            continue
            ;;
        -G|--nodegroups)
            nodegroups="$2"
            shift 2
            continue
            ;;
        -N|--nodes)
            nodes="$2"
            shift 2
            continue
            ;;
        -I|--instances)
            instances="$2"
            shift 2
            continue
            ;;
        -R|--no-rebalance)
            rebalance=0
            shift
            continue
            ;;
        -l|--dont-lock-cluster)
            lock_cluster=0
            shift
            continue
            ;;
        -L|--dont-lock-node)
            lock_node=0
            shift
            continue
            ;;
        -i|--non-redundant-action)
            case "$2" in
                #skip|ignore|move)
                skip|ignore)
                    non_redundant_action="$2"
                    ;;
                *)
                    #_die 'unusable value "%s" for --non-redundant-action (should be skip|ignore|move).\n' "$2"
                    _die 'unusable value "%s" for --non-redundant-action (should be skip|ignore).\n' "$2"
                    ;;
            esac
            shift 2
            continue
            ;;
        -p|--pause-watcher)
            pause_watcher=1
            shift
            continue
            ;;
        -c|--custom-cmds-string)
            custom_commands_string="$2"
            shift 2
            continue
            ;;
        -C|--custom-cmds-file)
            custom_commands_file="$2"
            shift 2
            continue
            ;;
        -m|--mailto)
            mailto="$2"
            shift 2
            continue
            ;;
        -g|--no-reboot-groups)
            reboot_groups=0
            shift
            continue
            ;;
        -s|--serial-nodes)
            serial_nodes=1
            shift
            continue
            ;;
        -P|--parallel)
            parallel=1
            shift
            continue
            ;;
        -a|--alerts)
            alerts=1
            shift
            continue
            ;;
        -T|--no-timestamps)
            timestamps=0
            shift
            continue
            ;;
        -x|--maintenance)
            _in 'needsmaintenance' $tags || tags="$tags needsmaintenance"
            shift
            continue
            ;;
        -M|--skip-master)
            skip_master=1
            shift
            continue
            ;;
        -B|--skip-recent)
            skip_recent="$2"
            shift 2
            continue
            ;;
        -K|--skip-non-vm-capable)
            skip_non_vm_capable=1
            shift
            continue
            ;;
        -A|--also-offline-drained)
            nodetypes_to_process=''
            shift
            continue
            ;;
        -o|--no-log)
            use_log=0
            shift
            continue
            ;;
        -d|--log-dir)
            log_dir="$(readlink -m "$2")"
            mkdir -p "$log_dir" || _die_u 'unable to create log directory "%s".\n' "$log_dir"
            shift 2
            continue
            ;;
        -E|--no-test-version)
            test_version=0
            shift
            continue
            ;;
        -O|--monitor-trigger)
            monitor_trigger_template="$2"
            shift 2
            continue
            ;;
        -u|--monitor-check-up)
            monitor_check_up_template="$2"
            shift 2
            continue
            ;;
        --)
            shift
            break
            ;;
        -*)
            _die_u 'unknown option "%s".\n' "$1"
            ;;
        *)
            break
            ;;
    esac
done
test 1 -eq $batch || verbose=1
if test 1 -eq $resume; then
    test -n "$log_dir" || \
        _die_u 'you must specify --log-dir when using --resume.\n'
    case "$_resume_id" in
        last)
            script_id="$(
                find "$log_dir" -mindepth 1 -maxdepth 1 -type f -name "clustertool-${command}-*.log" -printf '%T@ %p\n' | \
                    sort -r | head -n 1 | cut -d' ' -f2- | \
                    sed -e "s:${log_dir}${log_dir:+/}clustertool-roll-::; s/\\.log\$//")"
            ;;
        *)
            test -n "$_resume_id" && \
                ! printf '%s' "$_resume_id" | grep -q '[^0-9]' && \
                test 1 -lt "$_resume_id" || \
                _die_u 'unusable value "%s" for $script_id (either grokked from logfile or given with -r option).\n' "$_resume_id"
            script_id="$_resume_id"
            ;;
    esac
    eval "_log_mark resume $invocation_cmdline"
else
    script_id=$$
    eval "_log_mark start $invocation_cmdline"
fi

## get version and workarounds
gnt_version_maj=''
gnt_version_min=''
gnt_version_sub=''
jobwait_arg='watch'
if test 1 -eq $test_version && test -n "$1"; then
    if _ganeti_lib_dirs="$(
        _ssh_sudo 0 'normal' "$1" 'find /usr/share/ganeti/*/ganeti /usr/share/ganeti/*/ganeti/client /usr/share/ganeti/ganeti /usr/share/ganeti/ganeti/client -mindepth 0 -maxdepth 0 -type d 2>/dev/null' | _newline_to_space_pipe)" && \
        _ssh_sudo 0 'normal' "$1" "_dirs=\$(for _dir in $_ganeti_lib_dirs; do ! test -f \"\$_dir/gnt_job.py\" || printf '%s/gnt_job.py ' \"\$_dir\"; done); grep -q -- '^def WaitJob(.*):\$' \$_dirs"; then
        jobwait_arg='wait'
    else
        jobwait_arg='watch'
    fi
    if gnt_version="$(
        _ssh_sudo 0 'normal' "$1" "gnt-cluster version" | sed -ne 's/^Software version: //; t PRINT; b; : PRINT; p' | _trim_eol_pipe)"; then
        gnt_version_maj=$(printf '%s' "$gnt_version" | cut -d. -f1)
        gnt_version_min=$(printf '%s' "$gnt_version" | cut -d. -f2)
        gnt_version_sub=$(printf '%s' "$gnt_version" | cut -d. -f3-)
    fi
    if test -z "$gnt_version_maj" || test -z "$gnt_version_min" || test -z "$gnt_version_sub"; then
        _warn 'Unable to grok the ganeti version you are using.\n'
        gnt_version_maj=''
        gnt_version_min=''
        gnt_version_sub=''
    fi
fi

## main
masters="$*"
set --
case "$command" in
    test)
        read -r top_pid _temp </proc/self/stat
        eval "$test_string"
        _retval=${?:-$status}
        eval "_log_mark 'finish' $(_singlequote_wrap "$invocation_cmdline")"
        ;;
    roll)
        roll $masters
        _retval=${?:-$status}
        eval "_log_mark 'finish' $(_singlequote_wrap "$invocation_cmdline")"
        _sendmail "${script}: Completed with exit value $_retval"
        ;;
    kill)
	kill $masters
	_retval=${?:-$status}
	eval "_log_mark 'finish' $(_singlequote_wrap "$invocation_cmdline")"
	_sendmail "${script}: Completed with exit value $_retval"
	;;
esac
_exit $_retval
