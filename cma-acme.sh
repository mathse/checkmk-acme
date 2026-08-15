#!/usr/bin/env bash

set -euo pipefail

VERSION="0.2.0"

CONFIG="/root/acme/cma-acme.conf"

[[ -r "$CONFIG" ]] || {
    echo "Configuration file not found at $CONFIG"
    exit 1
}

# shellcheck source=/dev/null
source "$CONFIG"

ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME="${ACME_HOME}/acme.sh"

[[ -d "$ACME_HOME" ]] || {
    echo "acme.sh not found at $ACME_HOME .. please install manually"
    exit 1
}

[[ -x "$ACME_HOME/deploy/checkmk_appliance.sh" ]] || {
    echo "Deploy hook not found at $ACME_HOME/deploy/checkmk_appliance.sh .. installing"
    cp -f deploy/checkmk_appliance.sh "$ACME_HOME/deploy/checkmk_appliance.sh"
}


##############################################################################
# Helper functions
##############################################################################

usage() {
cat <<EOF
checkmk-acme ${VERSION}

Usage:

    checkmk-acme issue
    checkmk-acme renew
    checkmk-acme status
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Returns:
#   0 -> standalone appliance
#   0 -> cluster master
#   1 -> cluster standby
is_active_node() {
python3 <<'EOF'
import sys

try:
    import cma
    from cma.config import load_config

    cfg = load_config()

    if not cma.is_cluster_connected():
        sys.exit(0)

    sys.exit(0 if cma.master_node(cfg) else 1)

except Exception:
    # Better continue than block certificate renewals.
    sys.exit(0)
EOF

}

# Returns:
#  -d <node1>.<search_domain> -d <node2>.<search_domain>
node_names() {
python3 <<'EOF'
import sys

try:
    import cma
    from cma.config import load_config

    cfg = load_config()

    first_node = cfg['cluster']['node1_attrs']['name']
    second_node = cfg['cluster']['node2_attrs']['name']
    search_domain = cfg['dns']['search'][0]

    print('-d %s.%s -d %s.%s' % (first_node, search_domain, second_node, search_domain))

except Exception:
    # Better continue than block certificate renewals.
    sys.exit(0)
EOF

}

##############################################################################
# Commands
##############################################################################

issue() {
    if ! is_active_node; then
        echo "Standby node detected. Nothing to do."
        return 0
    fi

    "$ACME" --issue ${ACME_ISSUE_ARGS} $(node_names)
    "$ACME" --deploy -d "${CERT_DOMAIN}" --deploy-hook checkmk_appliance
}

renew() {
    if ! is_active_node; then
        echo "Standby node detected. Nothing to do."
        return 0
    fi
    "$ACME" --renew -d "${CERT_DOMAIN}"
    "$ACME" --deploy -d "${CERT_DOMAIN}" --deploy-hook checkmk_appliance
}

status() {
python3 <<EOF
import os
import shutil
import subprocess

hostname = os.uname().nodename

cluster = "unknown"
role = "unknown"

try:

    import cma
    from cma.config import load_config

    cfg = load_config()
    if cma.is_cluster_connected():
        cluster = "yes"
        role = "master" if cma.master_node(cfg) else "standby"
    else:
        cluster = "no"
        role = "standalone"

except Exception:
    pass

print()
print("Checkmk ACME")
print("============")
print()

print(f"{'Hostname':20}: {hostname}")
print(f"{'Cluster':20}: {cluster}")
print(f"{'Role':20}: {role}")

print()

acme = "${ACME}"

print(f"{'acme.sh':20}: {'installed' if os.path.exists(acme) else 'missing'}")

hook = os.path.join("${ACME_HOME}", "deploy", "checkmk_appliance.sh")

print(f"{'Deploy hook':20}: {'installed' if os.path.exists(hook) else 'missing'}")

print()

try:

    result = subprocess.run(
        [acme, "--list"],
        capture_output=True,
        text=True,
    )

    print(result.stdout.strip())

except Exception:
    pass

EOF

}

##############################################################################
# Main
##############################################################################

case "${1:-}" in

    issue)
        issue
        ;;

    renew)
        renew
        ;;

    status)
        status
        ;;

    *)
        usage
        exit 1
        ;;

esac
