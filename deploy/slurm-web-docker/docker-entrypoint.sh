#!/usr/bin/env bash
set -euo pipefail

role="${1:?usage: docker-entrypoint.sh agent|gateway}"
shift || true

run_as_slurm_web() {
    if id slurm-web &>/dev/null; then
        runuser -u slurm-web -- "$@"
    else
        exec "$@"
    fi
}

lib=/var/lib/slurm-web
mkdir -p "$lib"
chmod 755 "$lib" 2>/dev/null || true

agent_host="${AGENT_HOST:-slurm-web-agent}"
public_url="${SLURM_WEB_PUBLIC_URL:-http://localhost:5011}"

# slurm-web gen-jwt-key loads the same settings stack as agent/gateway and validates
# [agents].url. Write gateway.ini *before* gen-jwt-key (and before any slurm-web CLI).
if [[ "$role" == "gateway" ]]; then
    ldap_on=false
    case "${SLURM_WEB_LDAP_ENABLED:-}" in
        1|true|TRUE|yes|YES|on|ON) ldap_on=true ;;
    esac

    if [[ "$ldap_on" == true ]]; then
        lud="${SLURM_WEB_LDAP_URI:-ldap://host.docker.internal:389}"
        lub="${SLURM_WEB_LDAP_USER_BASE:-ou=users,dc=example,dc=org}"
        lgb="${SLURM_WEB_LDAP_GROUP_BASE:-ou=groups,dc=example,dc=org}"
        lbd="${SLURM_WEB_LDAP_BIND_DN:-cn=admin,dc=example,dc=org}"
        lbp="${SLURM_WEB_LDAP_BIND_PASSWORD:-admin}"
        cat >/etc/slurm-web/gateway.ini <<EOF
[service]
interface = 0.0.0.0
port = 5011

[ui]
host = ${public_url}

[agents]
url =
  http://${agent_host}:5012

[authentication]
enabled = yes
method = ldap

[ldap]
uri = ${lud}
user_base = ${lub}
group_base = ${lgb}
bind_dn = ${lbd}
bind_password = ${lbp}
starttls = no
EOF
    else
        cat >/etc/slurm-web/gateway.ini <<EOF
[service]
interface = 0.0.0.0
port = 5011

[ui]
host = ${public_url}

[agents]
url =
  http://${agent_host}:5012

[authentication]
enabled = no
EOF
    fi
elif [[ "$role" == "agent" ]]; then
    # Stub for CLI validation only; this container runs agent on :5012 (not gateway).
    cat >/etc/slurm-web/gateway.ini <<EOF
[service]
interface = 127.0.0.1
port = 5011

[ui]
host = http://127.0.0.1:5011

[agents]
url =
  http://127.0.0.1:5012

[authentication]
enabled = no
EOF
else
    echo "usage: agent|gateway" >&2
    exit 1
fi
chmod 644 /etc/slurm-web/gateway.ini 2>/dev/null || true

if [[ ! -f "$lib/jwt.key" ]]; then
    echo "Generating Slurm-web JWT key at $lib/jwt.key"
    slurm-web gen-jwt-key
fi

if [[ "$role" == "agent" ]]; then
    # Bind-mount is :ro and often root:root 600; slurm-web cannot read it. Copy into the named volume.
    if [[ ! -f /run/slurmrestd.key ]]; then
        echo "ERROR: mount the cluster Slurm JWT signing key at /run/slurmrestd.key (see docker-compose)." >&2
        exit 1
    fi
    if [[ ! -s /run/slurmrestd.key ]]; then
        echo "ERROR: /run/slurmrestd.key is empty (0 bytes). The host file is empty or kubectl did not extract the key." >&2
        echo "Recreate secrets/slurmrestd.key (namespace/secret name may differ), e.g.:" >&2
        echo "  kubectl get secret slurm-auth-jwt -n slurm -o jsonpath='{.data.jwt\\.key}' | base64 -d > secrets/slurmrestd.key" >&2
        echo "  # 或: kubectl ... -o json | jq -r '.data[\"jwt.key\"]' | base64 -d > secrets/slurmrestd.key" >&2
        echo "Then: wc -c secrets/slurmrestd.key   # should be > 0 (often 32+ bytes)" >&2
        exit 1
    fi
    # Keep the Slurm cluster JWT copy off the named volume shared with gateway.
    # Both services mount slurm-web-data on /var/lib/slurm-web; concurrent gen-jwt / defaults
    # can leave slurmrestd.key truncated (Slurm-web then reports "key is empty").
    cluster_jwt=/etc/slurm-web/slurm-cluster-jwt.key
    cp -f /run/slurmrestd.key "$cluster_jwt"
    if [[ ! -s "$cluster_jwt" ]]; then
        echo "ERROR: copy to $cluster_jwt failed or result is empty." >&2
        exit 1
    fi
    chmod 400 "$cluster_jwt"
    if id slurm-web &>/dev/null; then
        chown slurm-web:slurm-web "$cluster_jwt" "$lib/jwt.key"
    fi

    cluster="${SLURM_CLUSTER_NAME:-slurm}"
    uri="${SLURMRESTD_URI:-http://host.docker.internal:6820}"

    cat >/etc/slurm-web/agent.ini <<EOF
[service]
cluster = ${cluster}
interface = 0.0.0.0
port = 5012

[racksdb]
enabled=false

[slurmrestd]
uri = ${uri}
auth = jwt
jwt_key = ${cluster_jwt}
EOF
    chmod 644 /etc/slurm-web/agent.ini 2>/dev/null || true
    run_as_slurm_web slurm-web agent "$@"

elif [[ "$role" == "gateway" ]]; then
    if id slurm-web &>/dev/null; then
        chown slurm-web:slurm-web "$lib/jwt.key" 2>/dev/null || true
    fi
    run_as_slurm_web slurm-web gateway "$@"
fi
