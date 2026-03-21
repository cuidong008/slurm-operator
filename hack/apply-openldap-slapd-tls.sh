#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0
#
# Bitnami OpenLDAP 若首次启动时读不到 TLS 私钥（常见：宿主机 tls.key 为 600 且属主不是 UID 1001），
# 则 cn=config 里不会写入 olcTLSCertificate*，slapd 会拒绝 StartTLS（日志：unsupported extended operation
# 1.3.6.1.4.1.1466.20037）。本脚本在容器已运行、证书已可读的前提下，用 ldapi + EXTERNAL 把 TLS 路径写入 cn=config。
#
# 前置：宿主机执行（示例）：
#   sudo chown 1001:1001 examples/openldap-certs/tls.{crt,key} examples/openldap-certs/ca.crt
#   sudo chmod 640 examples/openldap-certs/tls.key
#   docker compose -f examples/docker-compose.openldap.yml up -d
#
# 用法：
#   ./hack/apply-openldap-slapd-tls.sh
#   LDAP_CONTAINER=my-openldap TLS_CERT=/certs/tls.crt ... ./hack/apply-openldap-slapd-tls.sh
#
set -euo pipefail

LDAP_CONTAINER="${LDAP_CONTAINER:-bitnami-openldap}"
TLS_CERT="${TLS_CERT:-/certs/tls.crt}"
TLS_KEY="${TLS_KEY:-/certs/tls.key}"
TLS_CA="${TLS_CA:-/certs/ca.crt}"

if ! docker ps --format '{{.Names}}' | grep -qx "$LDAP_CONTAINER"; then
	echo "未找到运行中的容器：$LDAP_CONTAINER" >&2
	exit 1
fi

docker exec -u 1001 "$LDAP_CONTAINER" bash -c "ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_CERT}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_KEY}
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${TLS_CA}
EOF
"
echo "已更新 cn=config TLS。验证（容器内）："
echo "  LDAPTLS_REQCERT=never ldapsearch -ZZ -x -H ldap://127.0.0.1:389 -b '' -s base"
echo "  LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://127.0.0.1:636 -b '' -s base"
