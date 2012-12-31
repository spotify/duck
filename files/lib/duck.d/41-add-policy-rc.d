#!/bin/bash

set -e

. /lib/libduck.sh

a_get duck/target
target="$ret"

policy_rcd=$target/usr/sbin/policy-rc.d

(
    set -e
    echo "#!/bin/bash"
    echo "exit 101"
) > $policy_rcd

chmod +x $policy_rcd
