### settings for profiles to use

_icinga_server='icinga.fictional-example.com'


### macros

# more terminal output
_verb="verbose=1"
# {} is replaced by the node name as a convenience
_scheddown="monitor_trigger_template=\"_ssh_sudo 1 normal \\\"$_icinga_server\\\" \\\"sched_downtime {} 3600; sched_svc_downtime \\\\\\\"\\\$_master\\\\\\\" ganeti_freemem 3600; sched_svc_downtime \\\\\\\"\\\$_master\\\\\\\" ganeti_joblist 3600\\\"\"";
# safe-mode until clustertool's parallelisation code is more robust
_noparallel="serial_nodes=1"
# hroller doesn't know how to handle some disk_templates
_nohroller="reboot_groups=0"
# workaround "snf-ganeti-eventd vs. ganeti" bug
_nomaster="skip_master=1"
# upgrade debian
_upgrade="custom_commands_string=\"DEBIAN_FRONTEND=noninteractive; export DEBIAN_FRONTEND; aptitude -y update; aptitude -y full-upgrade\""


### profiles

profile_base="$_verb ; $_scheddown"
profile_drbd="$profile_base ; $_noparallel"
profile_sharedfile="$profile_base ; $_noparallel ; $_nohroller"
profile_synnefo="$profile_base ; $_noparallel ; $_nohroller ; $_nomaster"
profile_drbd_u="$profile_drbd ; $_upgrade"
profile_sharedfile_u="$profile_sharedfile ; $_upgrade"
profile_synnefo_u="$profile_synnefo ; $_upgrade"


### index

profiles="drbd sharedfile synnefo drbd_u sharedfile_u synnefo_u"
