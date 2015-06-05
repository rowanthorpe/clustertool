# clustertool-funcs.sh (clustertool version 0.2.0)

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

clustertool_version='0.2.0'

## defaults
actions_started=0
test_string=''
dryrun=0
dryrun_no_tag=0
batch=1
verbose=0
resume=0
evacuate=0
nodegroups=''
nodes=''
instances=''
rebalance=1
# the cluster and nodes don't get fully locked for now anyway (by request)...
lock_cluster=1
lock_node=1
non_redundant_action='skip'
pause_watcher=0
custom_commands_string=''
custom_commands_file=''
mailto=''
reboot_groups=1
serial_nodes=0
parallel=0
alerts=0
timestamps=1
maintenance=0
change_priority='low'
skip_master=0
skip_non_vm_capable=0
tags='needsreboot'
use_log=1
monitor_trigger_template=''
monitor_check_up_template=''
in_die_func=0
test_version=1
libdir="${libdir:-.}"
funcnames=''
temp_dir="$(mktemp -d)" || { printf 'ERROR: unable to create temp working directory for clustertool.\n' >&2; exit 1; }
log_dir="$temp_dir"
skip_recent=0
nodetypes_to_process='not_offline not_drained'
clustertool_tty="${TTY:-$(tty)}"

_kill_pgid_tree() {
    # TODO: The rule here is:
    #  * When a kill is requested from this process, if running multiple clusters in parallel kill all
    #    processes in the per-cluster process-group that this process is a part of, in all other cases
    #    kill all processes in the entire clustertool process-group that this process is a part of
    # (for now there is no per-cluster process-group handling, even in parallel mode, so it kills the
    #  whole clustertool process-group either way)
    printf 'clustertool: spawning process to reap processes and clean up (might cause some subshell "killed" output to shell)\n' >&2
    ! test -d "$log_dir" || printf "clustertool: logfiles may be found in \"%s\" directory.\n" "$log_dir" >&2
    if test 1 -eq $parallel; then
        _pid="${top_pid_cluster:-${top_pid:-$$}}"
    else
        _pid="${top_pid:-$$}"
    fi
    _pgid="`ps --no-headers -p $_pid -o pgid=`"
    (setsid sh -c '
        # define _cleanup() and required vars inside the new shell session
        '"$_cleanup_funcstr"'
        temp_dir='"$temp_dir"'
        command='"$command"'
        script_id='"$script_id"'
        log_dir='"$log_dir"'
        _pid='"$_pid"'
        _pgid='"$_pgid"'
        for _sig; do
            /bin/kill -s $_sig -- -$_pgid || : # failure should just mean processes already disappeared
            /bin/sleep 0.05 || :            # try a microsleep, fallback to no sleep at all
            pgrep -g $_pgid || break        # processes have gone
        done
        _cleanup
    ' 'kill_pgid_tree' "$@" >/dev/null 2>&1 </dev/null &)
}

# Do this for easy function (re-)definition inside a new spawned session (e.g. setsid)
_cleanup_funcstr='
_cleanup() {
    rm -f $(find "${temp_dir:-.}" -mindepth 1 -maxdepth 1 \( \
        -name "clustertool-${command}-${script_id}.log.lock" -o \
        -name "clustertool-${command}-*.STDOUT.lock" -o \
        -name "clustertool-${command}.STDERR.lock" \) \
        -printf "%p ") 2>/dev/null
    rmdir "$log_dir" 2>/dev/null
    rmdir "$temp_dir" 2>/dev/null
}
'
eval "$_cleanup_funcstr"

_exit() {
    # Don't use _getargs() here - or any custom function other than _cleanup() or _kill_pgid_tree()
    _retval="${1:-${?:-$status}}"
    shift
    test $# -ne 0 || set -- 'TERM' 'INT' 'KILL'
    test 0 -eq $_retval || _kill_pgid_tree "$@"
    exit $_retval
}

# Add-then-remove trailing newline to avoid swallowing oneliners with no
# trailing newline (NB: use of "head" with negative index breaks streaming
# by slurping everything)
_slurp_sed() { sed -e '$ s/$/\n/' | sed -n -e "1! b NOTFIRST; h; \$ b LAST; b; : NOTFIRST; H; \$! b; : LAST; x; /\\n\$/ b TRAIL; $1; b PRINT; : TRAIL; s/\\n\$//; $1; s/\$/\\n/; : PRINT; p; q" | head -c -1; }

_timestamp_get() { test 1 -ne $timestamps || date --rfc-3339=s | _slurp_sed 's/ /_/g; s/\n//g'; }

_backslash_escape_pipe() { sed -e 's/\\/\\\\\\/g'; }

_backslash_escape() { printf '%s' "$1" | _backslash_escape_pipe; }

_string_escape_pipe() { sed -e 's/\$/\\$/g'; }

_string_escape() { printf '%s' "$1" | _string_escape_pipe; }

_backtick_escape_pipe() { sed -e 's/`/\\`/g'; }

_backtick_escape() { printf '%s' "$1" | _backtick_escape_pipe; }

_doublequote_escape_pipe() { sed -e 's/"/\\"/g'; }

_doublequote_escape() { printf '%s' "$1" | _doublequote_escape_pipe; }

_escape_for_doublequotes_pipe() { _backslash_escape_pipe | _doublequote_escape_pipe | _backtick_escape_pipe | _string_escape_pipe; }

_escape_for_doublequotes() { printf '%s' "$1" | _escape_for_doublequotes_pipe; }

_doublequote_wrap_pipe() { printf '"'; _escape_for_doublequotes_pipe; printf '"'; }

_doublequote_wrap() { printf '%s' "$1" | _doublequote_wrap_pipe; }

_singlequote_escape_pipe() { sed "s/'/'\\\\''/g"; }

_singlequote_escape() { printf '%s' "$1" | _singlequote_escape_pipe; }

_singlequote_wrap_pipe() { printf "'"; _singlequote_escape_pipe; printf "'"; }

_singlequote_wrap() { printf '%s' "$1" | _singlequote_wrap_pipe; }

_element_wrap_pipe() { sed -e '$ s/$/ \\\n/'; }

_element_wrap() { printf '%s' "$1" | _element_wrap_pipe; }

_list_escape() {
    for _elem do
        _singlequote_wrap "$_elem" | _element_wrap_pipe
    done
}

_list_wrap_pipe() { sed -e '$ s/$/\n /'; }

_list_wrap() { printf '%s' "$1" | _list_wrap_pipe; }

_array_wrap() { _list_escape "$@" | _list_wrap_pipe; }

_compact_space_pipe() { tr -s ' '; }

_compact_newline_pipe() { tr -s '\n'; }

_slurp_chomp_space_pipe() { _slurp_sed 's/^ \{1,\}//; s/ \{1,\}$//'; }

_slurp_chomp_newline_pipe() { _slurp_sed 's/^\n\{1,\}//; s/\n\{1,\}$//'; }

_newline_to_space_pipe() { tr '\n' ' ' | _compact_space_pipe | _slurp_chomp_space_pipe; }

_space_to_newline_pipe() { tr ' ' '\n' | _compact_newline_pipe | _slurp_chomp_newline_pipe; }

_trim_cr_pipe() { tr -d '\r'; }

_trim_eol_pipe() { tr -d '\r\n'; }

_uniq_list_pipe() { _space_to_newline_pipe | sort -u | _newline_to_space_pipe; }

_uniq_list() { printf '%s' "$1" | _uniq_list_pipe; }

_msg_pipe() { sed -e "s/^/$(_timestamp_get) ${script}:       :/"; }

_msg() { printf "$@" | _msg_pipe; }

# Shouldn't be needed any more (remove later if OK). See comment below
# in _ssh_sudo().
#_stdin_exitval() {
#    read _exitval
#    return $_exitval
#}

_getargs() {
    _args="$1"
    shift
    _to_shift=$#
    for _arg in $_args; do
        case "$_arg" in
            *:*)
                _default_val="$(printf '%s' "$_arg" | cut -d: -f2-)"
                _arg="$(printf '%s' "$_arg" | cut -d: -f1)"
                ;;
            *)
                _default_val=''
                test 0 -ne $# || _die_r ${?:-$status} 'not enough arguments provided, unable to set arg "%s".\n' "$_arg"
                ;;
        esac
        eval "$_arg=$(_singlequote_wrap "${1:-$_default_val}")"
        test 0 -eq $# || shift 1
    done
    _to_shift=$(expr $_to_shift - $#)
}

_in() { _getargs '_matcher' "$@"; shift $_to_shift
    for _arg do
        test "x$_matcher" != "x$_arg" || return 0
    done
    return 1
}

_lock() { _getargs '_locktype _lockfile _to_eval' "$@"; shift $_to_shift
    if test -x "$(which flock)"; then
        flock $_locktype "$_lockfile" -c "$_to_eval" || \
            _die_r ${?:-$status} 'failed evaluating %s with "flock %s" on %s.\n' "$(_singlequote_wrap "$_to_eval")" "$_locktype" "$(_singlequote_wrap "$_lockfile")"
    else
        eval "$_to_eval" || \
            _die_r ${?:-$status} 'failed evaluating %s.\n' "$(_singlequote_wrap "$_to_eval")"
    fi
}

_stdout_write() { _getargs '_proc_id' "$@"; shift $_to_shift
    #FIXME: the "tty -s" shouldn't be necessary, and means that some subshell output might
    #       still be interlaced...
    if test 1 -eq $parallel && tty -s; then
        _lockfile="${temp_dir}${temp_dir:+/}clustertool-${command}-${_proc_id}.STDOUT.lock"
        _lock -x "$_lockfile" cat
    else
        cat
    fi
}

_log_write() { # [quiet/silent/append]
    if test 1 -eq $use_log && test -n "$script_id"; then
        _logfile="${log_dir}${log_dir:+/}clustertool-${command}-${script_id}.log"
        _lockfile="${temp_dir}${temp_dir:+/}clustertool-${command}-${script_id}.log.lock"
    else
        _logfile=''
        _lockfile="${temp_dir}${temp_dir:+/}clustertool-${command}.STDERR.lock"
    fi
    if _in quiet "$@" && test 1 -ne $dryrun && test 1 -ne $verbose; then
        set -- "$@" silent
    fi
    if _in silent "$@"; then
        _visible_output='/dev/null'
    else
        _visible_output='&2'
    fi
    _eval_code="
        if test -n $(_singlequote_wrap "$_logfile"); then
            tee $(! _in append "$@" || printf -- -a) $(_singlequote_wrap "$_logfile") >$_visible_output
        else
            cat >$_visible_output
        fi
    "
    if test 1 -eq $parallel; then
        _lock -x "$_lockfile" "$_eval_code"
    else
        eval "$_eval_code"
    fi
}

_log_read() {
    if test 1 -eq $use_log && test -n "$script_id"; then
        _logfile="${log_dir}${log_dir:+/}clustertool-${command}-${script_id}.log"
        _lockfile="${temp_dir}${temp_dir:+/}clustertool-${command}-${script_id}.log.lock"
        if test -f "$_logfile"; then
            _eval_code="cat $(_singlequote_wrap "$_logfile")"
            if test 1 -eq $parallel; then
                _lock -s "$_lockfile" "$_eval_code"
            else
                eval "$_eval_code"
            fi
        fi
    fi
}

_log_mark_pipe() {
    # NB: *don't* use _getargs() in this function due to dynamic scope/namespace-stomping issues when using recursion
    _marker_type="$1"
    shift 1
    # _marker_type: begin_func, end_func, start, resume, finish
    _msg_pipe | sed -e 's/^\(\([^ ]\+\)\? [^:]\+\):       :/\1:MARK   :'"$(printf '%-10s' "$_marker_type")"':/' | \
        _log_write quiet $(test 'start' = "$_marker_type" || printf 'append')
}

_log_mark() {
    # NB: *don't* use _getargs() in this function due to dynamic scope/namespace-stomping issues when using recursion
    _marker_type="$1"
    shift 1
    # TODO: find easy way to retain func_args for output in end_func, then it
    #       can be array_wrapped too (NB: must handle recursion)
    case "$_marker_type" in
        end_func)
            _singlequote_wrap "$@"
            printf '\n'
            ;;
        *)
            _array_wrap '--------' "$@"
            ;;
    esac | _log_mark_pipe "$_marker_type"
}

_cmdlog_pipe() { _getargs '_invasive _cmd_type' "$@"; shift $_to_shift
    case "$_cmd_type" in
        normal)
            _suffix='_n'
            ;;
        invocation-specific)
            _suffix='_s'
            ;;
        tag)
            _suffix='_t'
            ;;
    esac
    if test 1 -eq $_invasive; then
        _suffix="${_suffix}_i"
    else
        _suffix="${_suffix}  "
    fi
    _msg_pipe | sed -e "s/:       :/:CMD${_suffix}:/" | _log_write quiet append
}

_cmdlog() { _getargs '_invasive _cmd_type' "$@"; shift $_to_shift
    printf "$@" | _cmdlog_pipe "$_invasive" "$_cmd_type"
}

_info_pipe() { _msg_pipe | sed -e 's/:       :/:INFO   :/' | _log_write quiet append; }

_info() { printf "$@" | _info_pipe; }

_warn_pipe() { _msg_pipe | sed -e 's/:       :/:WARN   :/' | _log_write append; }

_warn() { printf "$@" | _warn_pipe; }

_error_pipe() { _msg_pipe | sed -e 's/:       :/:ERROR  :/' | _log_write append; }

_error() { printf "$@" | _error_pipe; }

_sendmail() { _getargs '_subject' "$@"; shift $_to_shift
    if test -n "$mailto"; then
        {
            printf 'To: %s\nSubject: %s\n\n' "$mailto" "$_subject"
            if test -n "$script_id"; then
                printf 'logfile: %s%sclustertool-%s-%s.log\n\n' "$temp_dir" "${temp_dir:+/}" "$command" "$script_id"
                _log_read
            else
                printf 'No logfile content.\n'
            fi
        } | env MAILRC=/dev/null from=clustertool mailx -n -t >/dev/null 2>&1
    fi
}

_die_s() { test 1 -ne $in_die_func || return 1; in_die_func=1; _getargs '_retval _sigs' "$@"; shift $_to_shift
    # just in case...
    stty -raw >/dev/null 2>&1
    _error "$@"
    _error 'died with exitval %s.\n' "$_retval"
    if test 1 -eq $actions_started; then
        {
            printf '\nIMPORTANT:\n\nThe workflow was interrupted but for safety and debugging reasons I am not touching anything, so manually check the following:\n'
            test 1 -ne $lock_cluster || printf ' * if queue has been left drained\n    - gnt-cluster queue info\n'
            printf ' * if node(s) have been left '
            test 1 -ne $lock_node || printf 'drained or '
            printf 'offline'
            test -z "$nodetypes_to_process" || printf ' other than those that already were'
            printf '\n    - gnt-node list -o +role\n'
            test 1 -ne $alerts || printf ' * if any nodes'\'' /etc/motd file have remained in edited form\n    - gnt-cluster command -M '\''grep '\''\'\'''\''^\*\* THIS NODE WILL REBOOT'\''\'\'''\'' /etc/motd'\''\n'
            printf 'before re-running this tool.\n\n'
            test 1 -eq $skip_master || printf 'Also if you were working on the master node when this script died then it won'\''t know to "revert" to the previous master node when run again:\n * do it manually if you want\n    - gnt-cluster master-failover (on the node).\n\n'
        } | _warn_pipe
    fi
    _sendmail "Clustertool died with exitval $_retval"
    _exit "$_retval" "${_sigs:-TERM HUP INT KILL}"
}

_die_r() {
    _retval="$1"
    shift
    _die_s "$_retval" '' "$@"
}

_die() { _die_r 1 "$@"; }

_die_u() { _usage >&2; _die "$@"; }

_readchars() { _getargs '_numchars _timeout:0 _silent:1 _clearafter:0 _throwaway:0' "$@"; shift $_to_shift
    _have_timeout=0
    _have_stty=0
    _have_tput=0
    ! test -x $(which timeout) >/dev/null 2>&1 || _have_timeout=1
    ! test -x $(which stty) >/dev/null 2>&1 || _have_stty=1
    ! test -x $(which tput) >/dev/null 2>&1 || _have_tput=1
    # get initial terminal state and flush input
    if test 1 -eq $_have_stty; then
        _this_stty="$(stty -g)"
        _main_stty="$(stty -F "$clustertool_tty" -g)"
        stty -echo raw isig
        stty -F "$clustertool_tty" -echo raw isig
        if test 1 -eq $_have_timeout; then
            timeout --foreground 0.1 cat
        else
            cat & sleep 1; kill $!
        fi
        stty "$_this_stty"
        stty -F "$clustertool_tty" "$_main_stty"
    fi <"$clustertool_tty" >/dev/null 2>&1
    # prompt
    test 0 -eq $# || printf "$@" >&2
    # get characters
    if test 1 -eq $_have_stty; then
        if test 1 -eq $_silent; then
            stty -echo
            stty -F "$clustertool_tty" -echo
        fi
        stty raw min 1 isig
        stty -F "$clustertool_tty" raw min 1 isig
        _output="$(
            printf 'x'
            if test 0 -ne $_timeout && test 1 -eq $_have_timeout; then
                timeout --foreground $_timeout head -c $_numchars
            else
                head -c $_numchars
            fi
            printf 'x'
        )"
        stty "$_this_stty"
        stty -F "$clustertool_tty" "$_main_stty"
    else
        _output="$(
            printf 'x'
            if test 0 -ne $_timeout && test 1 -eq $_have_timeout; then
                timeout --foreground $_timeout sh -c 'IFS= read -r _input && printf "%s" "$_input"'
            else
                IFS= read -r _input && printf '%s' "$_input"
            fi | _slurp_sed 's/^\(.\{'$_numchars'\}\).*$/\1/'
            printf 'x'
        )"
    fi <"$clustertool_tty" >/dev/null 2>&1
    test 1 -eq $_throwaway || printf '%s' "$_output" | _slurp_sed 's/^x//; s/x$//'
    if test 0 -ne $#; then
        if test 1 -eq $_clearafter && test 1 -eq $_have_tput; then
            printf "\\r$(tput el 2>/dev/null)" >&2
        else
            printf '\n' >&2
        fi
    fi
}

_ssh_sudo() { _getargs '_invasive _cmd_type _server _commandline _timeout:0' "$@"; shift $_to_shift
    # _cmd_type: normal, invocation-specific, tag
    _to_eval="\
ssh -q -n -oPasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t \
$(test 0 -eq $_timeout || printf -- '-oConnectTimeout=%s ' $_timeout)\
-- $_server \
$(_singlequote_wrap "sudo -n -- sh -c $(_singlequote_wrap "$_commandline") || exit \${?:-\$status}")\
"
    _cmdlog "$_invasive" "$_cmd_type" '%s\n' "$_to_eval"
    _do_it=1
    if test 1 -eq $dryrun; then
        _do_it=0
        if test tag = "$_cmd_type"; then
            test 1 -eq $dryrun_no_tag || _do_it=1
        elif test 1 -ne $_invasive; then
            _do_it=1
        fi
    fi
    if test 1 -eq $_do_it; then
        # NB: This should all be unnecessary if using only -t, and I think I
        # no longer need "-t -t". Leaving commented for reference for now.
        #
        # OpenSSH with -t -t (to force a tty) outputs lines with \r\n EOLs instead
        # of just \n. Apparently when logging to stderr it adds the \r in case
        # interface is in raw mode, to avoid stairstepping. The "log.c" file seems
        # to be the culprit.
        #
        # FIXME: when displaying STDERR in a non-sub-shell it
        # still stairsteps...
        #(
        #    (
        #        (
        #            (
        #                eval "$_to_eval"
        #                printf '%s\n' ${?:-$status} >&3
        #            ) | _trim_cr_pipe >&4
        #        ) 3>&1
        #    ) | _stdin_exitval
        #) 4>&1
        #TODO (e.g. with -b -b vs. -b)
        # test 1 -ne $_invasive || \
        test 1 -eq $batch || _readchars 1 0 1 1 1 '[hit space]'
        eval "$_to_eval"
    else
        # To avoid _stdout_write() hanging forever waiting with "cat"
        printf ''
    fi
}

_alert_pause() {
    if test 1 -eq $alerts; then
        _cmdlog 0 'normal' 'sleep 60\n'
        test 1 -eq $dryrun || sleep 60
    fi
}

_filter() { _getargs '_comparison' "$@"; shift $_to_shift
    for _elem do
        ! eval "$(printf '%s' "$_comparison" | sed -e "s/{}/$(_singlequote_wrap "${_elem}")/g")" || printf '%s\n' "$_elem"
    done | _newline_to_space_pipe
}

_list_from_cluster() { _getargs '_cmd_type _master _object_type _filters: _filters_op:and' "$@"; shift $_to_shift
    # ARGS:
    #   _cmd_type: normal, invocation-specific, tag
    #   _master: [master node]
    #   _object_type: node, instance, group, job
    #   _filters: [$_match_type:$_action:$_matches ...]
    #     => _match_type: _flag, status, id, name, disk_template, tags, pnode, snodes, etc...
    #     => _action: trim, keep
    #     => _matches: [args to match against, separated by '|']
    #   _filters_op: and, or
    #   "$@" objects to match by name/id (otherwise all)

    case "$_object_type" in
        job)
            _field='id'
            ;;
        *)
            _field='name'
            ;;
    esac
    _filter_string="$(
        if test -n "$_filters"; then
            for _filter in $_filters; do
                printf '( '
                _match_type="$(printf '%s' "$_filter" | cut -d: -f1)"
                _action="$(printf '%s' "$_filter" | cut -d: -f2)"
                _matches="$(printf '%s' "$_filter" | cut -d: -f3- | sed -e 's/|/ /g')"
                _first=1
                for _match in $_matches; do
                    if test 1 -eq $_first; then
                        _first=0
                    else
                        if test 'trim' = "$_action"; then
                            printf ' and '
                        elif test 'keep' = "$_action"; then
                            printf ' or '
                        fi
                    fi
                    test 'keep' = "$_action" || printf 'not '
                    case "$_match_type" in
                        _flag)
                            printf '%s' "$_match"
                            ;;
                        id)
                            printf '%s == %s' "$_match_type" "$_match"
                            ;;
                        status|name|disk_template|group|pnode)
                            printf '%s == "%s"' "$_match_type" "$_match"
                            ;;
                        tags|snodes|node_list)
                            printf '"%s" in %s' "$_match" "$_match_type"
                            ;;
                    esac
                done
                printf ' ) '"$_filters_op "
            done | sed -e "\$ s/ $_filters_op \$//"
        fi
    )"
    _commandline="gnt-$_object_type list -o $_field --no-headers"
    test -z "$_filter_string" || _commandline="$_commandline --filter '$_filter_string'"
    # Don't use _array_wrap() here because it makes the log output unreadable
    test 0 -eq $# || _commandline="$_commandline $(
        for _arg do
            _singlequote_wrap "$_arg"
            printf ' '
        done | sed -e '$ s/ $//')"
    _die_message="$(
        printf 'failed listing %s objects' "$_object_type"
        test $# -eq 0 || printf ' "%s"' "$*"
        test -z "$_filter_string" || printf ' with --filter arg "%s"' "$_filters"
        printf ' on "%s".' "$_master"
    )"
    {
        _ssh_sudo 0 "$_cmd_type" "$_master" "$_commandline" || \
            _die_r ${?:-$status} '%s\n' "$_die_message"
    } | _newline_to_space_pipe
}

# Load the public functions here (transforming reader-macros for parallel-loops
# and parallel-blocks, and doing file-wide code-generation for function-logging)

eval "$(cat "${libdir}/clustertool-funcs-public.sh" | "${libdir}/clustertool-source-transform.sh")"
