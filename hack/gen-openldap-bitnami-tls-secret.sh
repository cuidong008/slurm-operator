#!/usr/bin/env bash
# 为 examples/openldap-bitnami-minimal.yaml 生成 Secret：服务端证书 + CA（tls.crt / tls.key / ca.crt）。
# Bitnami 镜像要求显式提供 LDAP_TLS_* 文件路径（无内置默认证书）。
#
# 用法：
#   ./hack/gen-openldap-bitnami-tls-secret.sh [namespace] [service_name]
# 默认：namespace=openldap，service_name=openldap
# SAN 会包含：<svc>、<svc>.<ns>.svc.cluster.local、<svc>.<ns>.svc、localhost
set -euo pipefail

NS="${1:-openldap}"
SVC="${2:-openldap}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=openldap-bitnami-lab-ca"

openssl genrsa -out tls.key 4096
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=${SVC}.${NS}.svc.cluster.local"

cat >v3.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName=DNS:${SVC},DNS:${SVC}.${NS}.svc.cluster.local,DNS:${SVC}.${NS}.svc,DNS:localhost
EOF

openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out tls.crt -days 825 -sha256 -extfile v3.ext

kubectl create secret generic openldap-bitnami-tls -n "$NS" \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret openldap-bitnami-tls applied in namespace $NS (Service ${SVC})"
