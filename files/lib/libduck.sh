#!/bin/bash

# static variables
export DUCK_VERSION="0.1"
export DUCKDB_CONF="/duckdb.conf"
# if this file exists, the installation loop should not run.
export INSTALLER_STATUS="/.installer_status"
# default logging location.
export DEFAULT_LOG="/var/log/duckinstaller.log"

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

    a_get duck/target
    target="$RET"

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


# get single duckdb variable
a_get() {
    export DUCK_RETURN=""
    export DUCK_OK="yes"

    eval $(duckdb get --sh "$@")

    if [[ "$DUCK_OK" != "yes" ]]; then
        error "Missing required duckdb variable: $1"
        exit 1
    fi

    export RET="$DUCK_RETURN"
}

# set single duckdb variable
a_set() {
    eval $(duckdb set "$@");
}

# Dynamic Variables
a_get duck/mode "testing"
export DUCK_MODE="$RET"
