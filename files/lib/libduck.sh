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

setup_duckdb() {
    info "duckdb: Loading Static Variables"

    if [[ -f $DUCKDB_CONF ]]; then
      info "duckdb: Loading $DUCKDB_CONF"
      duckdb url file://$DUCKDB_CONF
    fi

    if [[ -f $DUCKDB_JSON ]]; then
      info "duckdb: Loading $DUCKDB_JSON"
      duckdb url --json file://$DUCKDB_JSON
    fi

    info "duckdb: Loading /proc/cmdline"

    if ! duckdb url --cmdline file:///proc/cmdline; then
        error "duckdb: Failed to load kernel arguments"
        return 1
    fi

    # Time to enable hooks.
    duckdb set --json duck/hooks-enabled true
    duckdb set --json duck/log-hook-enabled true
}

run_installer() {
    if ! setup_duckdb; then
        return 1
    fi

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

# Run a command in the target environment.
# required duckdb variables:
#  - duck/target
in_target() {
    # run chroot invocation inside of a subshell
    # this allows us to override some useful environment variables
    # at leisure.

    a_get_into target duck/target

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
# exports the RET variable containing the value of the requested variable
# or invokes 'exit 1' if it was unable to fetch the value from duckdb.
#
# a_get duck/mode
# duck_mode="$RET"
#
# duckdb supprts the notion of default values, in that case, two arguments
# should be provided, as follows.
#
# a_get duck/mode testing
# duck_mode="$RET"
a_get() {
    export DUCK_RETURN=""
    export DUCK_OK="no"

    eval $(duckdb get --sh "$@")

    if [[ "$DUCK_OK" != "yes" ]]; then
        error "Missing required duckdb variable: $1"
        exit 1
    fi

    export RET=$DUCK_RETURN
}

# This function was introduced because the common idiom of assigning RET
# resulted in code which was error prone.
a_get_into() {
    name=$1
    shift
    a_get "$@"
    export "$name"="$RET"
}

# set single duckdb variable
a_set() {
    eval $(duckdb set "$@");
}

# Dynamic Variables
a_get_into DUCK_MODE duck/mode "testing"
