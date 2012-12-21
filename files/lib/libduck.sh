#!/bin/bash

# if this file exists, the installation loop should not run.
export installer_status="/.installer_status"
export default_log="/var/log/duckinstaller.log"
export target="/target"

info()    { echo "    INFO : $@"; }
warning() { echo " WARNING : $@"; }
error()   { echo "   ERROR : $@"; }

timeout_with() {
    timeout=$1
    title=$2

    echo -n "$title $timeout, "

    i=$timeout
    while [[ $i -gt 1 ]]; do
        sleep 1
        i=$[ $i - 1 ]
        echo -n "$i, "
    done

    sleep 1
    echo "OK"

    return 0
}

run_installer() {
    for script in /lib/duck.d/[0-9][0-9]-*; do
        [ ! -f $script ] && continue

        info "Running $script"
        logger -t installer "running: $script"

        if ! $script; then
            error "Installation step failed!"
            return 1
        fi
    done

    return 0
}

in_target() {
    # run chroot invocation inside of a subshell
    # this allows us to override some useful environment variables
    # at leisure.

    command="$1"

    info "in-target: $command"

    (
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export LC_ALL=C
        export LANGUAGE=C
        export LANG=C
        exec chroot $target bash -c "$command"
    )

    return $?
}


# get audodb variable
a_get()     { eval $(duckdb get "$1" "$2"); }
# set single duckdb variable
a_set()     { eval $(duckdb set "$1" "$2"); }
# list duckdb variables
a_list()    { duckdb list; }
# read duckdb variables from cmdline
a_cmdline() { duckdb cmdline /proc/cmdline; }
# read duckdb variables from file
a_file()    { duckdb file "$1"; }
# read duckdb variables from url
a_url()     { duckdb url "$1"; }
