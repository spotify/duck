#!/bin/bash
# vim: filetype=sh
. /lib/libduck.sh
a_get_into target duck/target

info "Removing policy-rc.d"

policy_rcd=$target/usr/sbin/policy-rc.d
rm -f $policy_rcd
