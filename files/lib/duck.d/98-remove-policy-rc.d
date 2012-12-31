#!/bin/bash

set -e

. /lib/libduck.sh

a_get duck/target
target="$ret"

info "Removing policy-rc.d"

policy_rcd=$target/usr/sbin/policy-rc.d
rm -f $policy_rcd
