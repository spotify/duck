#!/bin/bash
set -e

# static variables
export DUCK_VERSION="0.1"
export DUCKDB_CONF="/duckdb.conf"
export DUCKDB_JSON="/duckdb.json"
# if this file exists, the installation loop should not run.
export INSTALLER_STATUS="/.installer_status"
# default logging location.
export DEFAULT_LOG="/var/log/duckinstall.log"
export DUCK_LOGIN="/sbin/ducklogin"
export DUCK_HOOKS="/lib/duck-hooks.d"
export DUCK_PYTHONLIB="/lib/python-duck"
export PYTHONPATH="$DUCK_PYTHONLIB"

invoke_hook() {
  name=$1
  shift
  path=$DUCK_HOOKS/$name
  [[ -x $path ]] && ( $path "$@" || true )
}

info()    {
  echo "INFO : $@";
  invoke_hook log info "$@"
}

warning() {
  echo "WARNING : $@";
  invoke_hook log warning "$@"
}

error()   {
  echo "ERROR : $@";
  invoke_hook log error "$@"
}

timeout_with() {
    timeout=$1
    title=$2

    echo "$title $timeout,"

    i=$timeout
    while [[ $i -gt 1 ]]; do
        i=$[ $i - 1 ]
        sleep 1
        echo "$i,"
    done

    sleep 1
    echo "OK."

    return 0
}

run_installer() {
    duckdb set --json duck/hooks-enabled false

    info "duckdb: Loading Static Variables"

    if [[ -f $DUCKDB_CONF ]]; then
      info "duckdb: Loading $DUCKDB_CONF"
      duckdb file $DUCKDB_CONF
    fi

    if [[ -f $DUCKDB_JSON ]]; then
      info "duckdb: Loading $DUCKDB_JSON"
      duckdb file --json $DUCKDB_JSON
    fi

    info "duckdb: Loading /proc/cmdline"

    if ! duckdb cmdline /proc/cmdline; then
        error "duckdb: Failed to load kernel arguments"
        exit 1
    fi

    duckdb set --json duck/hooks-enabled true

    for script in /lib/duck.d/[0-9][0-9]-*; do
        [[ ! -x $script ]] && continue

        info "Running: $script"
        logger -t installer "running: $script"

        if ! $script; then
            error "Failed: $script"
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

    command="$@"

    info "in-target: $command"

    (
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export LC_ALL=C
        export LANGUAGE=C
        export LANG=C
        exec chroot $target $command
    )

    return $?
}


# get single duckdb variable
a_get() {
    export DUCK_RETURN=""
    export DUCK_OK="no"

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
