#!/usr/bin/env bash
# 为 examples/docker-compose.openldap.yml 生成 TLS 文件（tls.crt / tls.key / ca.crt）。
# 与 gen-openldap-bitnami-tls-secret.sh 逻辑一致，SAN 适配 Docker Compose（openldap、localhost）。
#
# 用法：
#   ./hack/gen-openldap-compose-certs.sh [输出目录] [可选：LDAP 宿主机 IP，写入 SAN，供 SSSD 用 IP 连 StartTLS]
# 默认：仓库内 examples/openldap-certs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${ROOT}/examples/openldap-certs}"
LDAP_HOST_IP="${2:-}"
mkdir -p "$OUT"
cd "$OUT"

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=openldap-bitnami-lab-ca"

openssl genrsa -out tls.key 4096
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=openldap"

SAN_LINE="DNS:openldap,DNS:localhost"
if [[ -n "$LDAP_HOST_IP" ]]; then
	SAN_LINE="${SAN_LINE},IP:${LDAP_HOST_IP}"
fi

cat >v3.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName=${SAN_LINE}
EOF

openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out tls.crt -days 825 -sha256 -extfile v3.ext

rm -f tls.csr v3.ext ca.key ca.srl 2>/dev/null || true
chmod 600 tls.key 2>/dev/null || true
chmod 644 tls.crt ca.crt

echo "Wrote tls.crt tls.key ca.crt to ${OUT}"
if [[ -n "$LDAP_HOST_IP" ]]; then
	echo "SAN includes IP:${LDAP_HOST_IP} (for SSSD/StartTLS via host IP)."
fi
echo "Bitnami slapd 以 UID 1001 读私钥；若跳过则 cn=config 无 TLS、StartTLS 失败。宿主机执行："
echo "  sudo chown 1001:1001 \"${OUT}/tls.crt\" \"${OUT}/tls.key\" \"${OUT}/ca.crt\" && sudo chmod 640 \"${OUT}/tls.key\""
echo "Then: docker compose -f examples/docker-compose.openldap.yml up -d"
