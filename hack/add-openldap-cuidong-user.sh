#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0
#
# 在 Bitnami OpenLDAP（与 examples/docker-compose.openldap.yml 一致）中创建
# POSIX 组 group1 与用户 cuidong，供 Slurm Login + SSSD 使用（需与 sssd 中
# ldap_user_search_base / ldap_group_search_base 覆盖的 OU 一致）。
#
# 用法（在仓库根目录，且 bitnami-openldap 已运行）：
#   ./hack/add-openldap-cuidong-user.sh
#   LDAP_USER_PASSWORD='你的密码' ./hack/add-openldap-cuidong-user.sh
#
# 覆盖连接（非本机 compose 时）：
#   LDAP_URI=ldap://openldap.example:389 LDAP_CONTAINER=my-openldap ./hack/add-openldap-cuidong-user.sh
#
set -euo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=example,dc=org}"
LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD:-admin}"
BASE_DN="${BASE_DN:-dc=example,dc=org}"

USER_UID="${USER_UID:-cuidong1}"
GROUP_CN="${GROUP_CN:-group1}"
# 与 Bitnami 预置 user01(1000) 等错开；可按集群规划修改
GID_NUMBER="${GID_NUMBER:-10051}"
UID_NUMBER="${UID_NUMBER:-10054}"
LDAP_USER_PASSWORD="${LDAP_USER_PASSWORD:-cuidong}"

LDAP_CONTAINER="${LDAP_CONTAINER:-bitnami-openldap}"

if ! docker ps --format '{{.Names}}' | grep -qx "$LDAP_CONTAINER"; then
	echo "错误：未找到运行中的容器「${LDAP_CONTAINER}」。请先启动 compose，或设置 LDAP_CONTAINER。" >&2
	exit 1
fi

ldaprun() {
	docker exec -i "$LDAP_CONTAINER" "$@"
}

hash_pw() {
	ldaprun slappasswd -s "$LDAP_USER_PASSWORD" | tr -d '\r\n'
}

user_exists() {
	local filter="(uid=${USER_UID})"
	ldaprun ldapsearch -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
		-b "ou=users,${BASE_DN}" "$filter" dn 2>/dev/null | grep -q '^dn:'
}

# 在整个 suffix 下查找 posixGroup（避免仅搜 ou=groups 时漏检、与 ldapadd 结果不一致）
lookup_posix_group_gid() {
	ldaprun ldapsearch -x -LLL -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
		-b "$BASE_DN" -s sub "(&(objectClass=posixGroup)(cn=${GROUP_CN}))" gidNumber 2>/dev/null \
		| sed -n 's/^gidNumber:[[:space:]]*//p' | head -1 | tr -d '\r'
}

lookup_posix_group_dn() {
	ldaprun ldapsearch -x -LLL -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
		-b "$BASE_DN" -s sub "(&(objectClass=posixGroup)(cn=${GROUP_CN}))" dn 2>/dev/null \
		| sed -n 's/^dn:[[:space:]]*//p' | head -1 | tr -d '\r'
}

ensure_group() {
	local existing_gid rc
	existing_gid="$(lookup_posix_group_gid)"
	if [[ -n "$existing_gid" ]]; then
		echo "组 ${GROUP_CN} 已存在 (gidNumber=${existing_gid})，将用户加入该组。"
		GID_NUMBER="$existing_gid"
		return 0
	fi

	echo "创建 POSIX 组 ${GROUP_CN} (gidNumber=${GID_NUMBER}) ..."
	set +e
	ldaprun ldapadd -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" <<EOF
dn: cn=${GROUP_CN},ou=groups,${BASE_DN}
objectClass: posixGroup
objectClass: top
cn: ${GROUP_CN}
gidNumber: ${GID_NUMBER}
EOF
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		return 0
	fi

	existing_gid="$(lookup_posix_group_gid)"
	if [[ -n "$existing_gid" ]]; then
		echo "组 ${GROUP_CN} 已存在 (gidNumber=${existing_gid})，将用户加入该组。"
		GID_NUMBER="$existing_gid"
		return 0
	fi

	echo "错误：创建组失败 (退出码 ${rc})，且无法解析已有组 ${GROUP_CN}。" >&2
	return 1
}

ou_exists() {
	local ou="$1"
	ldaprun ldapsearch -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
		-b "$ou" -s base '(objectClass=*)' dn 2>/dev/null | grep -q '^dn:'
}

if user_exists; then
	echo "目录中已存在 uid=${USER_UID}，跳过创建。"
	exit 0
fi

if ! ou_exists "ou=users,${BASE_DN}"; then
	echo "错误：未找到 ou=users,${BASE_DN}。请确认 Bitnami OpenLDAP 已正常初始化。" >&2
	exit 1
fi

if ! ou_exists "ou=groups,${BASE_DN}"; then
	echo "创建 ou=groups,${BASE_DN} ..."
	ldaprun ldapadd -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" <<EOF
dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups
EOF
fi

ensure_group || exit 1

PASS_HASH="$(hash_pw)"
echo "创建用户 ${USER_UID} (uidNumber=${UID_NUMBER}, gidNumber=${GID_NUMBER}) ..."
ldaprun ldapadd -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" <<EOF
dn: uid=${USER_UID},ou=users,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: organizationalPerson
objectClass: person
objectClass: top
cn: ${USER_UID}
sn: ${USER_UID}
uid: ${USER_UID}
uidNumber: ${UID_NUMBER}
gidNumber: ${GID_NUMBER}
homeDirectory: /home/${USER_UID}
loginShell: /bin/bash
userPassword: ${PASS_HASH}
EOF

# 将用户加入组（便于 id/groups 展示）；若已存在则忽略
GROUP_DN="$(lookup_posix_group_dn)"
if [[ -z "$GROUP_DN" ]]; then
	GROUP_DN="cn=${GROUP_CN},ou=groups,${BASE_DN}"
fi
{
	ldaprun ldapmodify -x -H ldap://127.0.0.1:389 -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" <<EOF
dn: ${GROUP_DN}
changetype: modify
add: memberUid
memberUid: ${USER_UID}
EOF
} 2>/dev/null || true

echo "完成。Slurm/SSSD 侧请保证："
echo "  - ldap_user_search_base 覆盖 ou=users,${BASE_DN}"
echo "  - ldap_group_search_base 覆盖 ou=groups,${BASE_DN}（或更宽 base）"
echo "  - 登录节点上 getent passwd ${USER_UID} / getent group ${GROUP_CN} 能解析后再提交作业。"
