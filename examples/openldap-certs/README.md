# Compose 用 TLS 文件

由 `./hack/gen-openldap-compose-certs.sh` 生成 `tls.crt`、`tls.key`、`ca.crt` 后，`examples/docker-compose.openldap.yml` 会只读挂载本目录到容器 `/certs`。可选第二参数写入 LDAP 宿主机 IP（SAN）。

**权限（必做）**：slapd 以 **UID 1001** 运行，必须能读私钥。生成后请在**宿主机**执行：

```bash
sudo chown 1001:1001 tls.crt tls.key ca.crt
sudo chmod 640 tls.key
```

否则首次初始化时 **cn=config 里不会出现 `olcTLSCertificate*`**，slapd 会拒绝 StartTLS（日志：`unsupported extended operation` / OID `1.3.6.1.4.1.1466.20037`）。已有数据卷时，补权限后可执行 `./hack/apply-openldap-slapd-tls.sh` 写入 TLS 路径。

Slurm Login 的 SSSD 使用 **`ldaps://<IP>:636`**（见 `helm/slurm/values.yaml`）时，若出现 `ldap_install_tls failed`，可将 **`ldap_tls_cipher_suite`** 设为 **`NORMAL`**（勿强制带冒号的优先级串，以免 GnuTLS 解析异常）。

勿将私钥提交到版本库（见仓库根 `.gitignore`）。
