#!/bin/bash
# vim: filetype=sh
. /lib/libduck.sh
a_get_into target duck/target

policy_rcd=$target/usr/sbin/policy-rc.d

(
    set -e
    echo "#!/bin/bash"
    echo "exit 101"
) > $policy_rcd

chmod +x $policy_rcd
