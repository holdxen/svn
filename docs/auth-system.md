# 认证与授权子系统

## 1. 概述

Subversion 的认证/授权系统负责验证用户身份并控制其对仓库路径的访问权限。客户端通过**认证提供者链**获取凭据，服务端通过**授权模块**验证权限。

核心设计：
- **提供者链**：多种凭据获取方式按优先级排列，依次尝试
- **凭据缓存**：成功获取的凭据会缓存到磁盘和内存
- **协议独立**：认证/授权逻辑与传输协议（svn://、http://）解耦

源码位于 `libsvn_subr/auth.c`（认证框架）、`include/svn_auth.h`（公共 API）。

---

## 2. 认证框架

### 2.1 核心结构体

```c
// 认证提供者虚表
typedef struct svn_auth_provider_t {
  const char *cred_kind;                                    // 凭证类型
  svn_error_t *(*first_credentials)(...);                   // 首次获取
  svn_error_t *(*next_credentials)(...);                    // 重试获取
  svn_error_t *(*save_credentials)(...);                    // 保存凭据
} svn_auth_provider_t;

// 认证句柄
struct svn_auth_baton_t {
  apr_hash_t *tables;          // cred_kind → provider_set 映射
  apr_hash_t *parameters;      // 运行时参数
  apr_hash_t *creds_cache;     // 运行时凭证缓存
};
```

### 2.2 凭证类型

| 类型常量 | 字符串值 | 结构体 | 说明 |
|----------|---------|--------|------|
| `SVN_AUTH_CRED_SIMPLE` | `svn.simple` | `svn_auth_cred_simple_t` | 用户名 + 密码 |
| `SVN_AUTH_CRED_USERNAME` | `svn.username` | `svn_auth_cred_username_t` | 仅用户名 |
| `SVN_AUTH_CRED_SSL_CLIENT_CERT` | `svn.ssl.client-cert` | `svn_auth_cred_ssl_client_cert_t` | SSL 客户端证书 |
| `SVN_AUTH_CRED_SSL_CLIENT_CERT_PW` | `svn.ssl.client-passphrase` | `svn_auth_cred_ssl_client_cert_pw_t` | SSL 证书密码 |
| `SVN_AUTH_CRED_SSL_SERVER_TRUST` | `svn.ssl.server` | `svn_auth_cred_ssl_server_trust_t` | SSL 服务器信任 |

### 2.3 凭证获取流程

```
svn_auth_first_credentials(auth_baton, cred_kind, realmstring)
  → 1. 查 creds_cache 内存缓存
  → 2. 遍历对应 cred_kind 的 providers 数组
       → provider[0].first_credentials()
       → provider[1].first_credentials()
       → ...
  → 返回凭据或 NULL

svn_auth_next_credentials(iter_state)
  → 继续尝试当前 provider 的 next_credentials()
  → 或切换到下一个 provider

svn_auth_save_credentials(iter_state)
  → 先尝试产出凭据的 provider 的 save_credentials()
  → 失败则从头遍历所有 provider
```

---

## 3. 认证提供者

### 3.1 简单密码认证（svn.simple）

| 提供者 | 来源 | 说明 |
|--------|------|------|
| 命令行参数 | `--username` / `--password` | 最高优先级 |
| 磁盘缓存 | `~/.subversion/auth/svn.simple/` | 文件缓存 |
| 交互提示 | 终端 | 提示用户输入 |

### 3.2 平台特定提供者

通过 `svn_auth_get_platform_specific_provider()` 加载：

| 提供者 | 平台 | 存储 |
|--------|------|------|
| GNOME Keyring | Linux | GNOME 密钥环 |
| KWallet | Linux | KDE 钱包 |
| Keychain | macOS | 系统钥匙串 |
| GPG Agent | 跨平台 | GPG 代理 |
| Windows CryptoAPI | Windows | Windows 凭据管理器 |

默认优先级顺序：
```
gnome-keyring, kwallet, keychain, gpg-agent, windows-cryptoapi
```

### 3.3 svn:// 协议特定认证

| 机制 | 文件 | 说明 |
|------|------|------|
| ANONYMOUS | `internal_auth.c` | 匿名访问 |
| EXTERNAL | `internal_auth.c` | SSH 隧道环境认证 |
| CRAM-MD5 | `cram.c` | 挑战-响应式密码认证 |
| SASL | `cyrus_auth.c` | Cyrus SASL 框架（GSSAPI 等） |

---

## 4. 凭据缓存

### 4.1 磁盘存储

```
~/.subversion/auth/
├── svn.simple/
│   ├── <md5(realmstring)>     # 凭据文件
│   └── ...
├── svn.username/
│   └── ...
├── svn.ssl.client-cert/
│   └── ...
├── svn.ssl.client-passphrase/
│   └── ...
└── svn.ssl.server/
    └── ...
```

- 文件名 = realmstring 的 MD5 十六进制摘要
- 文件格式为标准 hash（key-value），包含 `K 15 svn:realmstring` 标识

实现位于 `config_auth.c`：
```c
svn_auth__file_path(realmstring, cred_kind)
  → ~/.subversion/auth/<cred_kind>/<md5(realmstring)>
```

### 4.2 内存缓存

`svn_auth_baton_t.creds_cache` 在会话期间缓存已获取的凭据，避免重复访问磁盘。

---

## 5. 服务端认证

### 5.1 svnserve 认证

由 `serve.c` 和 `svnserve.conf` 控制：

```ini
[general]
anon-access = read          # 匿名用户权限: none / read / write
auth-access = write         # 认证用户权限: none / read / write
password-db = passwd        # 密码文件
authz-db = authz            # 授权文件
realm = My Repository       # 认证域
```

`passwd` 文件格式：
```ini
[users]
alice = password123
bob = secret
```

### 5.2 mod_dav_svn 认证

通过 Apache HTTP Server 的认证模块实现：
- Basic Auth
- Digest Auth
- LDAP/AD
- SSPI（Windows 域认证）
- 任何 Apache 支持的认证方式

---

## 6. 授权模型

### 6.1 authz 文件

路径级权限控制，支持组和通配符：

```ini
[groups]
devs = alice, bob
admins = charlie

[/]                     # 仓库根
* = r                   # 默认只读
@devs = rw              # devs 组读写
@admins = rw            # admins 组读写

[/trunk/secret]
* =                     # 拒绝所有
alice = rw              # 仅 alice 可访问

[repos:/branches]       # 跨仓库授权（多仓库共用一个 authz）
bob = rw
```

### 6.2 权限级别

| 权限 | 说明 |
|------|------|
| (空) | 无权限 |
| `r` | 只读 |
| `rw` | 读写 |

### 6.3 authz 实现

服务端通过 `libsvn_repos/authz.c` 检查每个操作的路径权限。关键函数：
- `svn_repos_authz_check_access()` — 检查访问权限
- `svn_repos_authz_read()` — 读取 authz 文件

---

## 7. SSL/TLS 信任

### 7.1 服务器证书验证

客户端收到服务器证书后，检查：
1. 证书链是否可信
2. 证书是否过期
3. 主机名是否匹配
4. 证书指纹是否在已知列表中

如果验证失败，用户可以：
- 临时接受（仅本次会话）
- 永久接受（存储到 `svn.ssl.server/`）
- 拒绝

### 7.2 SSL 客户端证书

某些配置要求客户端提供证书进行双向认证。证书路径和密码通过对应的 provider 获取。

---

## 参考源码

- `include/svn_auth.h` — 认证公共 API
- `libsvn_subr/auth.c` — 认证框架实现
- `libsvn_subr/config_auth.c` — 凭据磁盘存储
- `libsvn_ra_svn/cram.c` — CRAM-MD5 实现
- `libsvn_ra_svn/internal_auth.c` — 内建认证机制
- `libsvn_ra_svn/cyrus_auth.c` — SASL 认证
- `libsvn_repos/authz.c` — 授权检查
- `svnserve/serve.c` — svnserve 认证处理
