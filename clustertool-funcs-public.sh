# clustertool-funcs-public.sh (clustertool version 0.2.0)

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

# Don't interfere with comments like @PAR_LOOP_BEGIN@, @PAR_BLOCK_BARRIER@, etc
# - they are reader macros for on-the-fly expansion. Also, to allow logging code
# to be generated for public function entry/exit points on-the-fly be sure the
# functions are always in the following exact multiline form (replace
# square-bracketed terms with appropriate content), and that there is a blank
# line after the last function:
#
#[BLANK LINE HERE]
#[FUNCTION_NAME]() { [OPTIONAL CONTENT]
#    [CONTENT]
#}
#[BLANK LINE HERE]
#[FUNCTION_NAME]() { [OPTIONAL CONTENT]
#    [CONTENT]
#}
# ...


#### jobs non-invasive

jobs_get() { _getargs '_status _master'
    _list_from_cluster 'invocation-specific' "$_master" 'job' "status:keep:$_status"
}

jobs_wait() { _getargs '_master'
    # in dryrun mode $# will sometimes be 0
    if test 0 -ne $#; then
        _failed="$(
            {
                for _job do
                    _ssh_sudo 0 'invocation-specific' "$_master" "gnt-job $jobwait_arg '$_job'" >/dev/null || \
                        printf '%s ' "$_job"
                done
                _list_from_cluster 'invocation-specific' "$_master" 'job' "status:trim:success id:keep:$(
                    printf '%s|' "$@" | sed -e 's/|$//')"
            } | _uniq_list_pipe)"
        test 1 -eq $dryrun || printf '%s' "$_failed"
    fi
}

#### instances non-invasive

instances_get() { _getargs '_instance_role _instance_types _filtered _master'
    # $_instance_role -> one/none of:
    #    {primary,secondary,both}
    # $_instance_types -> space-separated, one/many/none of:
    #    {,not_}{drbd,ext,rbd,file,...}
    _instances="$(
        _nodes_string="$(printf '%s|' "$@" | sed -e 's/|$//')"
        eval "
            _list_from_cluster 'normal' \"\$_master\" 'instance' \"$(
                case "$_instance_role" in
                    both)
                        case "$_instance_types" in
                            '')
                                test -z "$_nodes_string" || \
                                    printf "pnode:keep:%s snodes:keep:%s' 'or" "$_nodes_string" "$_nodes_string"
                                ;;
                            *)
                                # To do this in one call like the other types would require
                                # rewriting _list_from_cluster() in a less simple way, so just
                                # do two calls for now.
                                {
                                    instances_get 'primary' "$_instance_types" 0 "$_master" "$@"
                                    printf ' '
                                    instances_get 'secondary' "$_instance_types" 0 "$_master" "$@"
                                } | _slurp_chomp_space_pipe
                                ;;
                        esac
                        ;;
                    *)
                        if test -n "$_nodes_string"; then
                            case "$_instance_role" in
                                primary)
                                    printf 'pnode:keep:%s' "$_nodes_string"
                                    ;;
                                secondary)
                                    printf 'snodes:keep:%s' "$_nodes_string"
                                    ;;
                            esac
                        fi
                        _types_neg="$(_filter '! test {} = "$(printf "%s" {} | sed -e "s/^not_//")"' $_instance_types)"
                        _types_pos="$(_filter '! _in {} $_types_neg' $_instance_types)"
                        if test -n "$_types_neg"; then
                            printf ' disk_template:trim:'
                            for _type in $_types_neg; do
                                printf '%s|' "$(printf '%s' "$_type" | sed -e 's/^not_//')"
                            done | sed -e '$ s/|$//'
                        fi
                        if test -n "$_types_pos"; then
                            printf ' disk_template:keep:'
                            for _type in $_types_pos; do
                                printf '%s|' "$_type"
                            done | sed -e '$ s/|$//'
                        fi
                        ;;
                esac)\"")"
    if test 1 -eq $_filtered && test -n "$instances"; then
        _filter '_in {} $instances' $_instances
    else
        printf '%s' "$_instances"
    fi
}

#### instances invasive

instances_activate_disks() { _getargs '_master'
    for _instance do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_master" "gnt-instance activate-disks --wait-for-sync '$_instance'" || \
            _die_r ${?:-$status} 'failed running activate-disks for "%s" on "%s".\n' "$_instance" "$_master"
    done             # @PAR_LOOP_END@
}

instances_handler() { _getargs '_action _master'
    # _action: migrate, evacuate, cleanup, move
    _action_args=''
    _extra_args=''
    case "$_action" in
        migrate)
            _action_args='migrate -f'
            _extra_args='--allow-failover'
            ;;
        evacuate)
            _action_args='replace-disks'
            _extra_args='-I .'
            ;;
        move)
            _action_args='move -f'
            ;;
        move\ *)
            _action_args='move -f'
            _extra_args="-n $(_singlequote_wrap "$(printf '%s' "$_action" | cut -d' ' -f2-)")"
            ;;
        cleanup)
            _action_args='migrate -f'
            _extra_args='--cleanup'
            ;;
    esac
    _jobs="$(
        for _instance do
            # *Don't* match "move ..." here, only "move"...
            if test 'move' = "$_action"; then
                _extra_args="$_extra_args -n $(
                    _singlequote_wrap "$(
                        {
                            # No need to differentiate empty-set from real error here for hroller,
                            # both are errors for us this time
                            _ssh_sudo 0 'normal' "hroller -L -G $(
                                _singlequote_wrap "$(
                                    _ssh_sudo 0 'normal' "$_master" "gnt-instance list -o 'pnode.group' --filter 'name == '\''$_instance'\'''" || \
                                        _die_r ${?:-$status} 'failed to get group-name for instance "%s".\n' "$_instance"
                                )"
                            ) --print-moves --no-headers" || \
                                _die_r ${?:-$status} 'failed to find a destination node to move instance "%s" to.\n' "$_instance"
                        } | sed -n -e "s/^ \{1,\}$_instance //; t PRINT; b; : PRINT; p; q"
                    )"
                )"
            fi
            _ssh_sudo 1 'normal' "$_master" "gnt-instance $_action_args $_extra_args --submit --print-jobid '$_instance'" || \
                _die_r ${?:-$status} 'failed doing "%s" with extra args "%s" for instance "%s".\n' "$_action_args" "$_extra_args" "$_instance"
        done | _newline_to_space_pipe
    )"
    jobs_wait "$_master" $_jobs
}

instances_evacuate() { _getargs '_master _node'
    # Accept initial list as args (to allow passing in fake values for dryrun)
    if test 1 -eq $evacuate; then
        _failed_jobs="$(instances_handler 'evacuate' "$_master" "$@")"
        if test -n "$_failed_jobs"; then
            set -- $(instances_get 'secondary' 'not_plain not_file' 1 "$_master" "$_node")
            _die 'failed to evacuate instances "%s" with job numbers "%s".\n' "$*" "$_failed_jobs"
        fi
    fi
}

instances_migrate() { _getargs '_master _node'
    # Accept initial list as args (to allow passing in fake values for dryrun)
    _failed_jobs="$(instances_handler 'migrate' "$_master" "$@")"
    if test -n "$_failed_jobs"; then
        set -- $(instances_get 'primary' 'not_plain not_file' 1 "$_master" "$_node")
        _warn 'failed to migrate instances "%s" with job numbers "%s" - attempting again.\n' "$*" "$_failed_jobs"
        _failed_jobs="$(
            {
                # just cleanup and try migrating again
                instances_handler 'cleanup' "$_master" "$@"
                printf ' '
                _cmdlog 0 'normal' 'sleep 30\n'
                sleep 30
                instances_handler 'migrate' "$_master" "$@"
            } | _uniq_list_pipe)"
        if test -n "$_failed_jobs"; then
            set -- $(instances_get 'primary' 'not_plain not_file' 1 "$_master" "$_node")
            _warn 'failed second attempt to migrate instances "%s" with job numbers "%s" - attempting a last time.\n' "$*" "$_failed_jobs"
            _failed_jobs="$(
                {
                    # Cleanup, for drbd primaries on this node move their secondaries
                    # to other nodes than where they are, and try migrating again
                    # (requires temporarily overriding $evacuate)
                    instances_handler 'cleanup' "$_master" "$@"
                    printf ' '
                    _cmdlog 0 'normal' 'sleep 30\n'
                    sleep 30
                    _old_evacuate=$evacuate
                    evacuate=1
                    instances_handler 'evacuate' "$_master" $(instances_get 'primary' 'drbd' 1 "$_master" "$_node")
                    evacuate=$_old_evacuate
                    printf ' '
                    _cmdlog 0 'normal' 'sleep 30\n'
                    sleep 30
                    instances_handler 'migrate' "$_master" "$@"
                } | _uniq_list_pipe)"
            if test -n "$_failed_jobs" ; then
                set -- $(instances_get 'primary' 'not_plain not_file' 1 "$_master" "$_node")
                _die 'failed last attempt to migrate instances "%s" with job numbers "%s" - giving up.\n' "$*" "$_failed_jobs"
            fi
        fi
    fi
}

instances_move() { _getargs '_master _node _direction'
    # Accept initial list as args (to allow passing in fake values for dryrun)
    if 'move' = "$non_redundant_action"; then
        case "$_direction" in
            from)
                _arg='move'
                _filter_arg='keep'
                ;;
            to)
                _arg="move $(_singlequote_wrap "$_node")"
                _filter_arg='trim'
                ;;
        esac
        _failed_jobs="$(instances_handler "$_arg" "$_master" "$@")"
        test -z "$_failed_jobs" || \
            _die 'failed to move instances "%s" %s node "%s" with job numbers "%s".\n' "$(
                _list_from_cluster 'normal' 'instance' "pnode:${_filter_arg}:$_node" "$@")" "$_direction" "$_node" "$_failed_jobs"
    fi
}

instances_kill() { _getargs '_kill_mode _node'
    #TODO: have a more patient version of this if $_kill_mode is 1
    # Tolerate failures here - the point is to poweroff no matter what...
    _ssh_sudo 1 'normal' "$_node" '
        # Script based on kknd by Giorgos Kargiotakis
        for _monitor in /var/run/ganeti/kvm-hypervisor/ctrl/*.monitor; do
            printf "system_powerdown\\n" | \
                /usr/bin/socat STDIO UNIX-CONNECT:$monitor >/dev/null 2>&1
        done
        sleep 100
        #TODO: be more refined about this, dont just killall
        killall -9 socat >/dev/null 2>&1
        sleep 5
        for VM_PID in /var/run/ganeti/kvm-hypervisor/pid/*; do
            kill -9 `cat $VM_PID` >/dev/null 2>&1
        done
        sleep 10
        if test -s /proc/drbd; then
            cat /proc/drbd | \
                grep Connected | \
                awk -F":" "{print \$1}"  | \
                tr -d " " | \
                xargs -I {} -P 0 drbdsetup /dev/drbd{} down
        fi >/dev/null 2>&1
        sleep 10
    '
}

#### nodes non-invasive

nodes_get() { _getargs '_node_types _tag_types _filtered _master'
    # $_node_types -> space-separated, any/many/none of:
    #    {,not_}{offline,drained,master_candidate,master_capable,...}
    # $_tag_types -> space-separated, any/many/none of:
    #    {,not_}{needsreboot,needsmaintenance}
    _nodes="$(
        _nodegroups_string="$(printf '%s|' "$@" | sed -e 's/|$//')"
        eval "
            _list_from_cluster 'normal' \"\$_master\" 'node' \"$(
                test -z "$_nodegroups_string" || printf 'group:keep:%s ' "$_nodegroups_string"
                _nodetypes_neg="$(_filter '! test {} = "$(printf "%s" {} | sed -e "s/^not_//")"' $_node_types)"
                _nodetypes_pos="$(_filter '! _in {} $_nodetypes_neg' $_node_types)"
                if test -n "$_nodetypes_neg"; then
                    printf ' _flag:trim:'
                    for _type in $_nodetypes_neg; do
                        printf '%s|' "$(printf '%s' "$_type" | sed -e 's/^not_//')"
                    done | sed -e '$ s/|$//'
                fi
                if test -n "$_nodetypes_pos"; then
                    printf ' _flag:keep:'
                    for _type in $_nodetypes_pos; do
                        printf '%s|' "$_type"
                    done | sed -e '$ s/|$//'
                fi
                if test 1 -ne $dryrun || test 1 -ne $dryrun_no_tag; then
                    _tagtypes_neg="$(_filter '! test {} = "$(printf "%s" {} | sed -e "s/^not_//")"' $_tag_types)"
                    _tagtypes_pos="$(_filter '! _in {} $_tagtypes_neg' $_tag_types)"
                    if test -n "$_tagtypes_neg"; then
                        printf ' tags:trim:'
                        for _type in $_tagtypes_neg; do
                            printf '%s|' "$(printf '%s' "$_type" | sed -e 's/^not_//')"
                        done | sed -e '$ s/|$//'
                    fi
                    if test -n "$_tagtypes_pos"; then
                        printf ' tags:keep:'
                        for _type in $_tagtypes_pos; do
                            printf '%s|' "$_type"
                        done | sed -e '$ s/|$//'
                    fi
                fi)\"")"
    if test 1 -eq $_filtered && test -n "$nodes"; then
        _filter '_in {} $nodes' $_nodes
    else
        printf '%s' "$_nodes"
    fi
}

node_check_down() { _getargs '_node _ping_loops:36 _ping_sleep:5'
    if test -n "$monitor_check_up_template"; then
        test 1 -eq $dryrun || \
            ! eval "$(printf '%s' "$monitor_check_up_template" | sed -e "s/{}/$(_singlequote_wrap "$_node")/g")"
    else
        _counter=1
        while true; do
            _cmdlog 0 normal "! { ping -c 1 $(_singlequote_wrap "$_node") || ping6 -c 1 $(_singlequote_wrap "$_node"); }\n"
            if test 1 -eq $dryrun || ! { ping -c 1 "$_node" || ping6 -c 1 "$_node"; }; then
                break
            fi
            _cmdlog 0 normal 'sleep %d\n' "$_ping_sleep"
            # Won't get here in dryrun mode, so no need to test for it
            sleep $_ping_sleep
            test 0 -eq $_ping_loops || test $_ping_loops -gt $_counter || return 1
            _counter=$(expr $_counter + 1)
        done
    fi
}

node_check_up() { _getargs '_node _ping_loops:60 _ping_sleep:5 _ssh_timeout:120'
    if test -n "$monitor_check_up_template"; then
        test 1 -eq $dryrun || \
            eval "$(printf '%s' "$monitor_check_up_template" | sed -e "s/{}/$(_singlequote_wrap "$_node")/g")"
    else
        _counter=1
        while true; do
            _cmdlog 0 'normal' "{ ping -c 1 $(_singlequote_wrap "$_node") && ping6 -c 1 $(_singlequote_wrap "$_node"); }\n"
            if test 1 -eq $dryrun || { ping -c 1 "$_node" && ping6 -c 1 "$_node"; }; then
                break
            fi
            _cmdlog 0 'normal' 'sleep %d\n' "$_ping_sleep"
            # Won't get here in dryrun mode, so no need to test for it
            sleep $_ping_sleep
            test 0 -eq $_ping_loops || test $_ping_loops -gt $_counter || return 1
            _counter=$(expr $_counter + 1)
        done
    fi
    _cmdlog 0 'normal' 'sleep 30\n'
    test 1 -eq $dryrun || sleep 30
    _retval="$(
        _ssh_sudo 0 'normal' "$_node" "printf 'ok'" "$_ssh_timeout" || \
            _die_r ${?:-$status} 'failed to get ssh access to "%s".\n' "$_node")"
    _cmdlog 0 'normal' 'sleep 30\n'
    if test 1 -ne $dryrun; then
        test 'ok' = "$_retval" || return 1
        sleep 30
    fi
}

#### nodes invasive

master_update() { _getargs '_master _candidates'
    _failed_over=0
    for _candidate in $_candidates ; do # *don't* do this in parallel...
        if test 0 -eq $# || ! _in "$_candidate" "$@"; then
            _ssh_sudo 1 'normal' "$_candidate" 'gnt-cluster master-failover' || continue
            _failed_over=1
            break
        fi
    done
    if test 1 -eq $dryrun; then
        _info 'dryrun note: because we are being non-invasive we will not actually failover the master so the operations will still be calculated on the original master (and will appear as such) for the sake of having output at all.\n'
        printf '%s' "$_master"
    elif test 1 -eq $_failed_over; then
        printf '%s' "$_candidate"
    else
        _die 'failed to find a viable candidate for master failover from "%s".\n' "$_master"
    fi
}

master_revert() { _getargs '_master _orig_master'
    _ssh_sudo 1 'normal' "$_master" "gnt-node modify -C yes '$_orig_master' >/dev/null 2>&1" || \
        _die_r ${?:-$status} 'failed setting previous master node "%s" to master_candidate role.\n' "$_orig_master"
    _ssh_sudo 1 'normal' "$_orig_master" "gnt-cluster master-failover >/dev/null 2>&1" || \
        _die_r ${?:-$status} 'failed reverting master from "%s" to original node "%s".\n' "$_master" "$_orig_master"
    printf '%s' "$_orig_master"
}

candidate_add() { _getargs '_master _orig_candidates _allow_capable_limit_fail _force'
    # $@ are the nodes about to be rebooted, so to be *avoided*
    _node=''
    if test 1 -eq $_force || \
        test $(clusters_pool_size get "$_master") -ge "$(printf '%s' "$_orig_candidates" | wc -w)"; then
        _master_capable="$(nodes_get "$nodetypes_to_process master_capable" '' 0 "$_master")"
        # Find usable nodes which are "capable" and not yet "candidates" (except for
        # the ones about to reboot)
        _master_capable_available="$(
            # pre-expand $* otherwise _filter() evals its *own* $@
            _filter "! _in {} $* \$_orig_candidates" $_master_capable)"
        if test -n "$_master_capable_available"; then
            _new_candidate_set=0
            for _node in $_master_capable_available; do # *don't* parallelise this
                if _ssh_sudo 1 'normal' "$_master" "gnt-node modify -C yes '$_node' >/dev/null 2>&1"; then
                    _new_candidate_set=1
                    break
                fi
            done
            test 1 -eq $_new_candidate_set || \
                _die 'failed to add a node to the master candidate pool.\n'
        elif test 1 -ne $_allow_capable_limit_fail; then
            _die 'there are no more master_capable nodes to promote to candidates.\n'
        fi
    fi
    printf '%s' "$_node"
}

candidates_revert() { _getargs '_master'
    for _temp_candidate do
        _ssh_sudo 1 'normal' "$_master" "gnt-node modify -C no '$_temp_candidate'" || \
            _die_r ${?:-$status} 'failed removing master_candidate status from temporary candidate "%s".\n' "$_temp_candidate"
    done
}

nodes_drain() { _getargs '_master'
    if test 1 -eq $lock_node; then
        for _node do # @PAR_LOOP_BEGIN@
            _ssh_sudo 1 'normal' "$_master" "gnt-node modify -D yes '$_node'" || \
                _die_r ${?:-$status} 'failed while draining node "%s".\n' "$_node"
        done         # @PAR_LOOP_END@
    fi
}

nodes_undrain() { _getargs '_master'
    if test 1 -eq $lock_node; then
        for _node do # @PAR_LOOP_BEGIN@
            _ssh_sudo 1 'normal' "$_master" "gnt-node modify -D no '$_node'" || \
                _die_r ${?:-$status} 'failed while undraining node "%s".\n' "$_node"
        done         # @PAR_LOOP_END@
    fi
}

nodes_offline() { _getargs '_master'
    for _node do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_master" "gnt-node modify -O yes '$_node'" || \
            _die_r ${?:-$status} 'failed while offlining node "%s".\n' "$_node"
    done         # @PAR_LOOP_END@
}

nodes_online() { _getargs '_master'
    for _node do # @PAR_LOOP_BEGIN@
        # Revert to "add --readd" when the SSH StrictHostKeyChecking issue has
        # been solved (add --readd is useful even if re-draining straight away,
        # because it auto-reuses secondary IP from the cluster).
        ##_ssh_sudo 1 'normal' "$_master" "gnt-node add --readd '$_node'" || \
        ##    _die_r ${?:-$status} 'failed while onlining node "%s".\n' "$_node"
        _ssh_sudo 1 'normal' "$_master" "gnt-node modify -O no '$_node'" || \
            _die_r ${?:-$status} 'failed while onlining node "%s".\n' "$_node"
        nodes_drain "$_master" "$_node"
    done         # @PAR_LOOP_END@
}

nodes_custom_commands() {
    for _node do # @PAR_LOOP_BEGIN@
        if test -n "$custom_commands_file"; then
            _commands_string="$(cat "$custom_commands_file")" || \
                _die_r ${?:-$status} 'failed sourcing local custom commands file "%s".\n' "$custom_commands_file"
            _ssh_sudo 1 'normal' "$_node" "$_commands_string" || \
                _die_r ${?:-$status} 'failed running custom commands from file "%s" on node "%s".\n' "$custom_commands_file" "$_node"
        fi
        # *don't* split for parallelisation here...
        if test -n "$custom_commands_string"; then
            _ssh_sudo 1 'normal' "$_node" "$custom_commands_string" || \
                _die_r ${?:-$status} 'failed running commands from string "%s" on node "%s".\n' "$custom_commands_string" "$_node"
        fi
    done         # @PAR_LOOP_END@
}

nodes_get_tags() { _getargs '_master'
    {
        # Using one "list" with a filter instead of list-tags per-node is
        # more efficient.
        _ssh_sudo 0 'tag' "$_master" "gnt-node list -o tags --no-headers $(
            if test 0 -ne $#; then
                printf -- '--filter '
                _singlequote_wrap "$(
                    for _node do # no parallelisation
                        printf 'name == "%s" or ' "$_node"
                    done | sed -e '$ s/ or $//')"
            fi)" || \
            _die_r ${?:-$status} 'failed to get list of tags for nodes "%s".\n' "$*"
    } | sed -e 's/,/ /g' | _uniq_list_pipe
}

nodes_reboot() { _getargs '_kill_mode _master'
    for _node do # @PAR_LOOP_BEGIN@
        # Last sanity check for paranoia's sake, before rebooting
        # NB: this will all have to be changed when Ganeti team change disk_template
        #     semantics (in ~v2.13 ?), as per
        #     http://docs.ganeti.org/ganeti/master/html/design-storagetypes.html
        if test 1 -ne $dryrun && test 0 -eq $_kill_mode; then
            test -z "$(instances_get 'primary' 'not_plain not_file' 0 "$_master" "$_node")" || \
                _die 'not rebooting node "%s" because there are still primary redundant instances on it.\n' "$_node"
            test 'ignore' = "$non_redundant_action" || \
                test -z "$(instances_get 'primary' 'plain file' 0 "$_master" "$_node")" || \
                _die 'not rebooting node "%s" because there are still non-redundant instances on it.\n' "$_node"
        fi
        if test -n "$monitor_trigger_template"; then
            eval "$(printf '%s' "$monitor_trigger_template" | sed -e "s/{}/$(_singlequote_wrap "$_node")/g")" || \
                _die_r ${?:-$status} 'failed executing monitor trigger for node "%s" using template: "%s".\n' "$monitor_trigger_template" "$_node"
        fi
        test 0 -ne $_kill_mode || nodes_offline "$_master" "$_node"
        nodes_custom_commands "$_node"
        _check_nodes_up=1
        if test 0 -eq $_kill_mode; then
            _node_tags="$(nodes_get_tags "$_master" "$_node")"
            if _in 'needsmaintenance' $_node_tags; then
                _reboot_type='-h'
            else
                _reboot_type='-r'
            fi
        elif test 1 -eq $_kill_mode; then
            _reboot_type='-r'
        else
            _reboot_type='-h'
            _check_nodes_up=0
        fi
        # Hardcode the path to the real shutdown below to avoid molly-guard
        _ssh_sudo 1 'normal' "$_node" "/sbin/shutdown $_reboot_type now" || \
            _die_r ${?:-$status} 'failed to %s node "%s".\n' "$(
                if test x-r = x$_reboot_type; then printf 'reboot'; else printf 'shutdown'; fi
            )" "$_node"
        if test 1 -eq $_check_nodes_up; then
            node_check_down "$_node" || \
                _die_r ${?:-$status} 'node "%s" failed to power off before the timeout.\n' "$_node"
            # For maintenance mode set loop-till-pingable limit to "0" to wait indefinitely
            node_check_up "$_node" $(! _in 'needsmaintenance' $_node_tags || printf -- 0) || \
                _die_r ${?:-$status} 'node "%s" failed to return to responsive ssh level.\n' "$_node"
            test 1 -eq $_kill_mode || nodes_online "$_master" "$_node"
        fi
    done         # @PAR_LOOP_END@
}

nodes_migrate() { _getargs '_master'
    _orig_parallel=$parallel
    test 1 -ne $serial_nodes || parallel=0
    for _node do # @PAR_LOOP_BEGIN@
        _secondary_instances=''
        _non_redundant_instances=''
        if test 1 -eq $dryrun && test 1 -eq $dryrun_no_tag && test 1 -ne $serial_nodes; then
            _info 'dryrun note: seeing a fictional rebootgroup is used for dryrun no real instances will be found, so we populate the instance list with fictional values for the sake of syntax checking.\n'
            _primary_redundant_instances='_fake_primary_instance_1_ _fake_primary_instance_2_'
            test 1 -ne $evacuate || _secondary_instances='_fake_secondary_instance_1_ _fake_secondary_instance_2_'
            ! test 'move' = "$non_redundant_action" || \
                _non_redundant_instances='_fake_nonredundant_instance_1_ _fake_nonredundant_instance_2_'
        else
            _primary_redundant_instances="$(instances_get 'primary' 'not_plain not_file' 1 "$_master" "$_node")"
            test 1 -ne $evacuate || _secondary_instances="$(instances_get 'secondary' '' 1 "$_master" "$_node")"
            ! test 'move' = "$non_redundant_action" || \
                _non_redundant_instances="$(instances_get 'primary' 'plain file' 1 "$_master" "$_node")"
        fi
        instances_migrate "$_master" "$_node" $_primary_redundant_instances
        instances_evacuate "$_master" "$_node" $_secondary_instances
        instances_move "$_master" "$_node" 'from' $_non_redundant_instances
        # Output a list of moved non-redundant instances for moving back to the node
        # later
        printf '%s' "$_non_redundant_instances"
    done         # @PAR_LOOP_END@
    parallel=$_orig_parallel
}

nodes_alert() { _getargs '_type'
    if test 1 -eq $alerts; then
        case "$_type" in
            start)
                _string='A rolling reboot or kill has been scheduled for this cluster. This node will reboot/shutdown sometime during the next few minutes (or up to a few hours). You will get another warning just before it happens.'
                ;;
            final)
                _string='As part of a rolling reboot/kill this node will reboot/shutdown any moment...'
                ;;
        esac
        # $_motd_string must be a oneliner
        _motd_string='** THIS NODE WILL REBOOT/SHUTDOWN VERY SOON AS PART OF A ROLLING REBOOT/KILL **'
        for _node do # @PAR_LOOP_BEGIN@
            # @PAR_BLOCK_BEGIN@
            ! test final = "$_type" || \
                _ssh_sudo 1 'normal' "$_node" "if ! grep -q -x -F $(_singlequote_wrap "$_motd_string") /etc/motd; then cp -f /etc/motd /etc/motd.clustertool-backup && { sed -e '\$! b; /^\$/ b; s/\$/\\n/' /etc/motd.clustertool-backup | sed -e '\$! b; /^\$/ b; s/\$/\\n/' && printf '%s\\n' $(_singlequote_wrap "$_motd_string"); } >/etc/motd; fi" || \
                _die_r ${?:-$status} 'failed updating motd file with upcoming reboot/shutdown alert on node "%s".\n' "$_node"
            # @PAR_BLOCK_BARRIER@
            _ssh_sudo 1 'normal' "$_node" "printf '%s\\n' $(_singlequote_wrap "$_string") | wall -t 30" || \
                _die_r ${?:-$status} 'failed alerting logged in users about upcoming reboot/shutdown on node "%s".\n' "$_node"
            # @PAR_BLOCK_END@
        done         # @PAR_LOOP_END@
    fi
}

nodes_alert_remove() {
    if test 1 -eq $alerts; then
        for _node do # @PAR_LOOP_BEGIN@
            _ssh_sudo 1 'normal' "$_node" 'mv -f /etc/motd.clustertool-backup /etc/motd' || \
                _die_r ${?:-$status} 'failed reverting motd file on node "%s".\n' "$_node"
        done         # @PAR_LOOP_END@
    fi
}

nodes_tag() { _getargs '_tags _master'
    if test 1 -ne $resume; then
        for _node do # @PAR_LOOP_BEGIN@
            _ssh_sudo 1 'tag' "$_master" "gnt-node add-tags '$_node' $_tags" || \
                _die_r ${?:-$status} 'failed setting "%s" tags on node "%s".\n' "$_tags" "$_node"
        done         # @PAR_LOOP_END@
    fi
}

nodes_untag() { _getargs '_tags _master'
    for _node do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'tag' "$_master" "gnt-node remove-tags '$_node' $_tags" || \
            _die_r ${?:-$status} 'failed to remove "%s" tags from node "%s".\n' "$_tags" "$_node"
    done         # @PAR_LOOP_END@
}

nodes_set_marker() {
    _now="$(date '+%s')"
    for _node do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_node" "printf '%s' '$_now' >/.clustertool-reboot-marker" || \
            _die_r ${?:-$status} 'failed to leave reboot-marker file on node "%s".\n' "$_node"
    done         # @PAR_LOOP_END@
}

node_recent_marker() { _getargs '_node'
    test 0 -ne $skip_recent || return 1
    _now="$(date '+%s')"
    _marker_time="$(_ssh_sudo 0 'normal' "$_node" "cat /.clustertool-reboot-marker 2>/dev/null")"
    test -n "$_marker_time" && \
        test $(expr $_now - $_marker_time) -lt $(expr $skip_recent \* 86400)
    return ${?:-$status}
}

nodes_roll() { _getargs '_parallel _only_reboot _master'
    _orig_parallel=$parallel
    parallel=$_parallel
    test 1 -ne $skip_non_vm_capable || \
        set -- $(_filter '_in {} $(nodes_get "vm_capable" "" 0 "$_master")' "$@")
    if _in "$_master" "$@"; then
        if test 1 -eq $skip_master; then
            _warn 'skipping processing the master node "%s" by request, but not removing any tags, so you don'\''t forget about it - remove tags manually if necessary.\n' "$_master"
            set -- $(_filter '! in {} "$_master"' "$@")
            _master_processing=0
        else
            _master_processing=1
        fi
    else
        _master_processing=0
    fi
    _temp_candidates=''
    _orig_master=''
    if test 1 -eq $parallel; then
        _orig_candidates="$(nodes_get 'not_offline master_candidate' '' 0 "$_master")"
        for _node do
            # Master node is also always a master_candidate (no need to test for both)...
            #
            # Tolerate failure when trying to add a candidate because if it fails
            # it probably means there are no more master_capable nodes, in which
            # case ganeti will allow less candidates than pool-size, as it knows
            # it has no choice anyway (counter-intuitive, but it works...)
            ! _in "$_node" $_orig_candidates || \
                _temp_candidates="${_temp_candidates}${_temp_candidates:+ }$(candidate_add "$_master" "$_orig_candidates $_temp_candidates" 1 0 "$@")"
        done
        if _in "$_master" "$@"; then
            _orig_master="$_master"
            _master="$(master_update "$_master" "$_orig_candidates $_temp_candidates" "$@")"
        fi
    fi
    for _node do # @PAR_LOOP_BEGIN@
        ! test 'skip' = "$non_redundant_action" || \
            test -z "$(instances_get 'primary' 'file plain' 0 "$_master" "$_node")" || \
            continue
        if ! node_recent_marker "$_node"; then
            if test 1 -ne $parallel; then
                _orig_candidates="$(nodes_get 'not_offline master_candidate' '' 0 "$_master")"
                # Tolerate failure here (see comment above)
                ! _in "$_node" $_orig_candidates || \
                    _temp_candidates="$(candidate_add "$_master" "$_orig_candidates" 1 0 "$_node")"
                if _in "$_master" "$_node"; then
                    _orig_master="$_master"
                    _master="$(master_update "$_master" "$_orig_candidates $_temp_candidates" "$_node")"
                fi
            fi
            nodes_drain "$_master" "$_node"
            if test 1 -ne $_only_reboot; then
                # Although running the watcher after every node is expensive
                # it seems to be more successful than manually activating disks, so
                # comment this for now (maybe delete it later)
                #_drbd_instances="$(instances_get 'both' 'drbd' 0 "$_master" "$_node")"
                _moved_instances="$(nodes_migrate "$_master" "$_node")"
            fi
            nodes_alert final "$_node"
            _alert_pause
            nodes_reboot 0 "$_master" "$_node"
            instances_move "$_master" "$_node" 'to' $_moved_instances
            # Use watcher instead for now (see comment above)
            #instances_activate_disks "$_master" $_drbd_instances
            watchers_run "$_master"
            nodes_alert_remove "$_node"
            nodes_untag "needsreboot$(
                ! _in 'needsmaintenance' $(nodes_get_tags "$_master" "$_node") || \
                    printf ' needsmaintenance')" "$_master" "$_node"
            nodes_set_marker "$_node"
            nodes_undrain "$_master" "$_node"
            if test 1 -ne $parallel; then
                if test -n "$_orig_master"; then
                    _master="$(master_revert "$_master" "$_orig_master")"
                elif _in "$_node" $_orig_candidates; then
                    _ssh_sudo 1 'normal' "$_master" "gnt-node modify -C yes '$_node'"
                fi
                test -z "$_temp_candidates" || candidates_revert "$_master" $_temp_candidates
            fi
        fi
    done         # @PAR_LOOP_END@
    # See comments above (run per-node instead)..
    #watchers_run "$_master"
    if test 1 -eq $parallel; then
        test -z "$_orig_master" || _master="$(master_revert "$_master" "$_orig_master")"
        for _node do
            _in "$_master" "$_node" || ! _in "$_node" $_orig_candidates || \
                _ssh_sudo 1 'normal' "$_master" "gnt-node modify -C yes '$node'"
        done
        test -z "$_temp_candidates" || candidates_revert "$_master" $_temp_candidates
    fi
    parallel=$_orig_parallel
}

nodes_kill() { _getargs '_kill_mode _master'
    for _node do # @PAR_LOOP_BEGIN@
        instances_kill "$_kill_mode" "$_node"
        nodes_reboot "$_kill_mode" "$_master" "$_node"
    done         # @PAR_LOOP_END@
}

#### rebootgroups non-invasive

rebootgroup_get() { _getargs '_master _nodegroup'
    if test 1 -eq $dryrun && test 1 -eq $dryrun_no_tag; then
        _info 'dryrun note: seeing no nodes have actually been tagged we just populate the reboot-group with silly example values for the sake of syntax checking.\n'
        printf '_fake_node_1_ _fake_node_2_'
    # Need to check for tagged nodes first, hroller "fails" on empty set and on real errors
    elif test -n "$(nodes_get "$nodetypes_to_process" 'needsreboot' 1 "$_master" "$_nodegroup")"; then
        {
            _ssh_sudo 0 'normal' "$_master" "hroller $(test 1 -ne $evacuate || printf -- '--full-evacuation'; test 'move' = "$non_redundant_action" || printf -- ' --%s-non-redundant' "$non_redundant_action") -G '$_nodegroup' --node-tags 'needsreboot' --one-step-only --no-headers -L" || \
                _die_r ${?:-$status} 'failed to get a rebootgroup from hroller for group "%s" on "%s".\n' "$_nodegroup" "$_master"
        } | _newline_to_space_pipe
    fi
}

#### rebootgroups invasive

rebootgroups_roll() { _getargs '_master _nodegroup'
    _parallel=$(expr 1 - $serial_nodes)
    set -- $(rebootgroup_get "$_master" "$_nodegroup")
    while test 0 -ne $#; do
        nodes_roll $_parallel 0 "$_master" "$@"
        if test 1 -eq $dryrun; then
            _info 'dryrun note: hroller recalculates the operations based on previous operations, so in dryrun mode it would loop forever - therefore we just output one loop and forcibly break from the loop. Beware tags won'\''t have been removed. Do it manually.\n'
            break
        fi
        set -- $(rebootgroup_get "$_master" "$_nodegroup")
    done
    # Now reboot nodes which didn't need VMs migrated/moved (so didn't appear
    # in hroller results)
    test 1 -eq $dryrun || nodes_roll 0 1 "$_master" $(nodes_get "$nodetypes_to_process" 'needsreboot' 1 "$_master" "$_nodegroup")
}

#### nodegroups non-invasive

nodegroups_get() {
    {
        for _master do # @PAR_LOOP_BEGIN@
            _nodegroups="$(_list_from_cluster 'normal' "$_master" group)"
            if test -n "$nodegroups"; then
                _filter '_in {} "$nodegroups"' $_nodegroups
            else
                printf '%s' "$_nodegroups"
            fi
            printf ' '
        done           # @PAR_LOOP_END@
    } | _uniq_list_pipe
}

#### nodegroups invasive

nodegroups_rebalance() { _getargs '_master'
    if test 1 -eq $rebalance; then
        # Maybe not wise to parallelise this for future-proofing yet
        # (it will effectively run serially either way for now anyway)
        for _nodegroup do
            _ssh_sudo 1 'normal' "$_master" "hbal -L -X -G '$_nodegroup' $(test 1 -eq $evacuate || printf -- '--no-disk-moves')" || \
                _die_r ${?:-$status} 'failed rebalancing nodegroup "%s" on "%s".\n' "$_nodegroup" "$_master"
        done
    fi
}

nodegroups_alert() { _getargs '_type _master'
    if test 1 -eq $alerts; then
        for _nodegroup do # @PAR_LOOP_BEGIN@
            nodes_alert "$_type" $(nodes_get "$nodetypes_to_process" 'needsreboot' 1 "$_master" "$_nodegroup")
        done              # @PAR_LOOP_END@
    fi
}

nodegroups_alert_remove() { _getargs '_master'
    if test 1 -eq $alerts; then
        for _nodegroup do # @PAR_LOOP_BEGIN@
            nodes_alert_remove $(nodes_get "$nodetypes_to_process" 'needsreboot' 1 "$_master" "$_nodegroup")
        done              # @PAR_LOOP_END@
    fi
}

nodegroups_tag() { _getargs '_tags _what _master'
    if test 1 -ne $resume; then
        for _nodegroup do # @PAR_LOOP_BEGIN@
            if _in "$_what" 'nodegroups' 'clusters'; then
                _ssh_sudo 1 'tag' "$_master" "gnt-group add-tags '$_nodegroup' $_tags" || \
                    _die_r ${?:-$status} 'failed setting "%s" tags on nodegroup "%s".\n' "$_tags" "$_nodegroup"
            else
                nodes_tag "$_tags" "$_master" $(nodes_get "$nodetypes_to_process" '' 1 "$_master" "$_nodegroup")
            fi
        done              # @PAR_LOOP_END@
    fi
}

nodegroups_untag() { _getargs '_tags _what _master'
    for _nodegroup do # @PAR_LOOP_BEGIN@
        if _in "$_what" 'nodegroups' 'clusters'; then
            _ssh_sudo 1 'tag' "$_master" "gnt-group remove-tags '$_nodegroup' $_tags" || \
                _die_r ${?:-$status} 'failed to remove "%s" tags from nodegroup "%s".\n' "$_tags" "$_nodegroup"
        else
            nodes_untag "$_tags" "$_master" $(nodes_get "$nodetypes_to_process" '' 1 "$_master" "$_nodegroup")
        fi
    done              # @PAR_LOOP_END@
}

nodegroups_roll() { _getargs '_master'
    for _nodegroup do # @PAR_LOOP_BEGIN@
        if test -z "$nodes" && test 1 -eq $reboot_groups; then
            rebootgroups_roll "$_master" "$_nodegroup"
        else
            nodes_roll 0 0 "$_master" $(nodes_get "$nodetypes_to_process" 'needsreboot' 1 "$_master" "$_nodegroup")
        fi
        nodegroups_rebalance "$_master" "$_nodegroup"
    done              # @PAR_LOOP_END@
}

nodegroups_kill() { _getargs '_kill_mode _master'
    for _nodegroup do # @PAR_LOOP_BEGIN@
        nodes_kill "$_kill_mode" "$_master" $(nodes_get '' '' 1 "$_master" "$_nodegroup")
    done              # @PAR_LOOP_END@
}

#### clusters non-invasive

masters_canonical_get() {
    {
        for _master do # @PAR_LOOP_BEGIN@
            _ssh_sudo 0 'normal' "$_master" 'gnt-cluster getmaster' || \
                _die_r ${?:-$status} 'failed to get canonical master URL from "%s".\n' "$_master"
        done           # @PAR_LOOP_END@
    } | _newline_to_space_pipe
}

clusters_verify() {
    for _master do # @PAR_LOOP_BEGIN@
        _ssh_sudo 0 'normal' "$_master" 'gnt-cluster verify' >/dev/null || \
            _die_r ${?:-$status} 'failed verifying cluster on "%s".\n' "$_master"
    done           # @PAR_LOOP_END@
}

#### clusters invasive

queues_empty() {
    for _master do # @PAR_LOOP_BEGIN@
        ## --filter from ganeti <= 2.9 does not handle some negations well yet, so must index by id and use grep instead
    _jobs="$(
        {
             _ssh_sudo 0 'normal' "$_master" 'gnt-job list -o id,status --no-headers --separator="|"' || \
                 _die_r ${?:-$status} 'failed getting list of existing active jobs from "%s".\n' "$_master"
        } | grep -v '|\(success\|error\|canceled\)$' | cut -d\| -f1 | _newline_to_space_pipe)"
        if test 1 -eq $dryrun; then
            _jobs="_fake_job_1_ _fake_job_2_"
            _info 'dryrun note: seeing we are not actually changing the queue we just populate the job-list with silly example values for the sake of syntax checking.\n'
        fi
        if test -n "$_jobs"; then
            _failed_jobs="$(jobs_wait "$_master" $_jobs)"
            test -z "$_failed_jobs" || \
                _die 'failed waiting for jobs "%s".\n' "$_failed_jobs"
        fi
    done           # @PAR_LOOP_END@
}

queues_drain() {
    for _master do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_master" 'gnt-cluster queue drain' || \
            _die_r ${?:-$status} 'failed draining the queue on "%s".\n' "$_master"
    done           # @PAR_LOOP_END@
}

queues_undrain() {
    for _master do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_master" 'gnt-cluster queue undrain' || \
            _die_r ${?:-$status} 'failed undraining the queue on "%s".\n' "$_master"
    done           # @PAR_LOOP_END@
}

queues_lock() {
    if test 1 -eq $lock_cluster; then
        #TODO: just drain, empty, and undrain for now until proper locking is done
        queues_drain "$@"
        queues_empty "$@"
        queues_undrain "$@"
    fi
}

queues_unlock() {
    if test 1 -eq $lock_cluster; then
        true # for now a no-op (see TODO comment above)
    fi
}

watchers_pause() {
    if test 1 -eq $pause_watcher; then
        for _master do # @PAR_LOOP_BEGIN@
            _ssh_sudo 1 'normal' "$_master" 'gnt-cluster watcher pause 3600' || \
                _die_r ${?:-$status} 'failed pausing watcher on "%s".\n' "$_master"
        done           # @PAR_LOOP_END@
    fi
}

watchers_unpause() {
    if test 1 -eq $pause_watcher; then
        for _master do # @PAR_LOOP_BEGIN@
            # ignore non-zero exit code - maybe the pause timed out already
            _ssh_sudo 1 'normal' "$_master" 'gnt-cluster watcher continue'
        done           # @PAR_LOOP_END@
    fi
}

watchers_run() {
    for _master do # @PAR_LOOP_BEGIN@
        _ssh_sudo 1 'normal' "$_master" '/usr/sbin/ganeti-watcher' || \
            _die_r ${?:-$status} 'failed manually running watcher on "%s".\n' "$_master"
    done           # @PAR_LOOP_END@
}

clusters_pool_size() { _getargs '_action'
    # NB: using "get" the order of results may be randomly mixed if using --parallel
    #     (so call one-at-a-time if so)
    for _master do # @PAR_LOOP_BEGIN@
        _cluster_pool_size="$(
            _ssh_sudo 0 'normal' "$_master" 'gnt-cluster info | sed -n -e '\''/^Cluster parameters:/! b; : LOOP; n; s/^ \{1,\}candidate pool size: \{1,\}//; t PRINT; b LOOP; : PRINT; p; q'\''' || \
                _die_r ${?:-$status} 'failed to get candidate-pool-size from "%s".\n' "$_master")"
        case "$_action" in
            get)
                printf '%s' "$_cluster_pool_size"
                return
                ;;
            reduce)
                _symbol='-'
                ;;
            increase)
                _symbol='+'
                ;;
        esac
        _ssh_sudo 1 'normal' "$_master" "gnt-cluster modify --candidate-pool-size $(expr $_cluster_pool_size $_symbol 1)" || \
            _die_r ${?:-$status} 'failed to %s candidate-pool-size on "%s".\n' "$_action" "$_master"
    done           # @PAR_LOOP_END@
}

clusters_alert() { _getargs '_type'
    if test 1 -eq $alerts; then
        for _master do # @PAR_LOOP_BEGIN@
            nodegroups_alert "$_type" "$_master" $(nodegroups_get "$_master")
        done           # @PAR_LOOP_END@
    fi
}

clusters_alert_remove() {
    if test 1 -eq $alerts; then
        for _master do # @PAR_LOOP_BEGIN@
            nodegroups_alert_remove "$_master" $(nodegroups_get "$_master")
        done           # @PAR_LOOP_END@
    fi
}

clusters_tag() { _getargs '_tags _what'
    if test 1 -ne $resume; then
        for _master do # @PAR_LOOP_BEGIN@
            if _in "$_what" 'clusters'; then
                _ssh_sudo 1 'tag' "$_master" "gnt-cluster add-tags '$_master' $_tags" || \
                    _die_r ${?:-$status} 'failed setting "%s" tags on cluster with master "%s".\n' "$_tags" "$_master"
            else
                nodegroups_tag "$_tags" "$_what" "$_master" $(nodegroups_get "$_master")
            fi
        done           # @PAR_LOOP_END@
    fi
}

clusters_untag() { _getargs '_tags _what'
    for _master do # @PAR_LOOP_BEGIN@
        if _in "$_what" 'clusters'; then
            _ssh_sudo 1 'tag' "$_master" "gnt-cluster remove-tags '$_master' $_tags" || \
                _die_r ${?:-$status} 'failed to remove "%s" tags from cluster with master "%s".\n' "$_tags" "$_master"
        else
            nodegroups_untag "$_tags" "$_what" "$_master" $(nodegroups_get "$_master")
        fi
    done           # @PAR_LOOP_END@
}

clusters_roll() {
    for _master do # @PAR_LOOP_BEGIN@
        nodegroups_roll "$_master" $(nodegroups_get "$_master")
    done           # @PAR_LOOP_END@
}

clusters_kill() { _getargs '_kill_mode'
    for _master do # @PAR_LOOP_BEGIN@
        nodegroups_kill "$_kill_mode" "$_master" $(nodegroups_get "$_master")
        if test 2 -ne $_kill_mode; then
            watchers_run "$_master"
            # @PAR_BLOCK_BEGIN@
            clusters_alert_remove "$_master"
            # @PAR_BLOCK_BARRIER@
            clusters_untag 'locked' 'nodegroups' "$_master"
            # @PAR_BLOCK_END@
        fi
    done           # @PAR_LOOP_END@
}

#### main invasive

prerun() { _getargs '_kill_mode _cmd'
    _warn 'About to execute %s on nodes which match:\n' "$_cmd"
    _warn '  (master-nodes) %s\n' "$masters"
    test -z "$nodegroups" || _warn '  (nodegroups %s)\n' "$nodegroups"
    test -z "$nodes" || _warn '  (nodes %s)\n' "$nodes"
    test -z "$instances" || _die 'specifying instances as matches (for matching their containing nodes) is not yet implemented.\n'
    #TODO: test -z "$instances" || _warn '  (instances %s)\n' "$instances"
    if test 2 -ne $_kill_mode; then
        _warn 'ARE YOU SURE? (Ctrl-C in the next 10 seconds if not).\n'
        if test 1 -ne $dryrun; then
            sleep 10
            actions_started=1
        fi
    fi
}

start() { _getargs '_kill_mode'
    test 2 -eq $_kill_mode || queues_lock "$@"
    watchers_pause "$@"
    if test 0 -eq $_kill_mode && test 1 -ne $serial_nodes && test 5 -gt $(
        # ignore exit code - any failure will most likely also fail this test anyway
        _ssh_sudo 0 'normal' "$_master" 'grep -o -a -- '\''\(skip\|ignore\)-non-redundant\|one-step-only\|node-tags\|full-evacuation'\'' "$(which hroller)"' | wc -l
    ); then
        _warn 'an older less capable version of hroller is present so nodes will be cycled serially rather than using hroller'\''s output.\n'
        serial_nodes=1
    fi
}

finish() { _getargs '_kill_mode'
    if test 2 -ne $_kill_mode; then
        watchers_unpause "$@"
        queues_unlock "$@"
        clusters_verify "$@"
    fi
}

roll() { set -- $(masters_canonical_get $masters)
    read -r top_pid _temp </proc/self/stat
    prerun 0 'roll'
    for _master do # @PAR_LOOP_BEGIN@
        read -r top_pid_cluster _temp </proc/self/stat
        # @PAR_BLOCK_BEGIN@
        clusters_tag "$tags" 'nodes' "$_master"
        # @PAR_BLOCK_BARRIER@
        clusters_alert 'start' "$_master"
        # @PAR_BLOCK_END@
        _alert_pause
        start 0 "$_master"
        clusters_roll "$_master"
        finish 0 "$_master"
    done           # @PAR_LOOP_END@
}

kill() { set -- $(masters_canonical_get $masters)
    read -r top_pid _temp </proc/self/stat
    # _kill_mode => 0:not-a-kill, 1:kill-reboot-restore, 2:kill-asap-shutdown-exit
    if _in 'needsmaintenance' $tags; then
        _kill_mode=2
    else
        _kill_mode=1
    fi
    prerun "$_kill_mode" 'kill'
    for _master do # @PAR_LOOP_BEGIN@
        read -r top_pid_cluster _temp </proc/self/stat
        # @PAR_BLOCK_BEGIN@
        clusters_tag 'locked' 'nodegroups' "$_master"
        # @PAR_BLOCK_BARRIER@
        test 2 -eq $_kill_mode || clusters_alert 'start' "$_master"
        # @PAR_BLOCK_END@
        start "$_kill_mode" "$_master"
        clusters_kill "$_kill_mode" "$_master"
        finish "$_kill_mode" "$_master"
    done          # @PAR_LOOP_END@
}

#### [keep this reminder to retain the preceding blank line for source-rewriting]
