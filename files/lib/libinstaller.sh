#!/bin/bash

# if this file exists, the installation loop should not run.
export installer_status="/.installer_status"
export default_log="/var/log/autoinstaller.log"
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
    for script in /lib/installer.d/[0-9][0-9]-*; do
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

# get audodb variable
a_get()     { eval $(autodb get "$1" "$2"); }
# set single autodb variable
a_set()     { eval $(autodb set "$1" "$2"); }
# list autodb variables
a_list()    { autodb list; }
# read autodb variables from cmdline
a_cmdline() { autodb cmdline /proc/cmdline; }
# read autodb variables from file
a_file()    { autodb file "$1"; }
# read autodb variables from url
a_url()     { autodb url "$1"; }
