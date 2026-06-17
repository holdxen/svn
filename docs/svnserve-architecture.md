# svnserve 服务端架构

## 1. 概述

`svnserve` 是 Subversion 的轻量级服务端进程，实现 `svn://` 协议。它不依赖 Apache HTTP Server，适合小型团队和内部使用。

支持五种运行模式和三种连接处理方式。

源码位于 `subversion/svnserve/`，协议处理核心在 `serve.c`（158KB）。

---

## 2. 运行模式

### 2.1 模式列表

定义于 `svnserve.c`：

```c
enum run_mode {
  run_mode_unspecified,
  run_mode_inetd,       // -i: inetd/xinetd 模式
  run_mode_daemon,      // -d: 守护进程模式
  run_mode_tunnel,      // -t: 隧道模式（SSH）
  run_mode_listen_once, // -X: 只监听一次（调试）
  run_mode_service      // Windows 服务模式
};
```

| 模式 | 启动参数 | 说明 |
|------|----------|------|
| **inetd** | `-i` | 由 inetd/xinetd 启动，处理单个连接 |
| **daemon** | `-d` | 监听端口，持续运行 |
| **tunnel** | `-t` | SSH 隧道模式，通过 stdin/stdout 通信 |
| **listen-once** | `-X` | 监听一个连接后退出（调试用） |
| **service** | — | Windows 服务模式 |

### 2.2 连接处理方式

```c
enum connection_handling_mode {
  connection_mode_fork,   // fork 子进程（默认，APR_HAS_FORK 时）
  connection_mode_thread, // 线程池（-T 选项）
  connection_mode_single  // 单连接（-1/--single-conn）
};
```

| 方式 | 参数 | 说明 |
|------|------|------|
| **fork** | 默认 | 每个连接 fork 一个子进程 |
| **thread** | `-T` | 使用线程池处理连接 |
| **single** | `-1` | 只处理一个连接（调试用） |

---

## 3. 主循环

```
sub_main()
  → 解析命令行参数
  → 打开日志文件
  → 根据 run_mode 分支：

daemon 模式:
  → create_server_socket() — 创建监听 socket
  → while(1) {
      accept_connection()
      → fork/thread/single:
          serve_socket()
            → close_connection()
              → serve() — 进入协议处理
    }

tunnel 模式:
  → serve_socket(stdin/stdout)
    → serve()

inetd 模式:
  → serve_socket(stdin/stdout)
    → serve()
```

---

## 4. 虚拟根（-r 选项）

`-r` 指定一个根目录，客户端 URL 中的路径相对于此目录解析：

```
svnserve -d -r /srv/svn/repos
  → svn://host/project → /srv/svn/repos/project

svnserve -d -r /srv/svn/repos/myproject
  → svn://host/ → /srv/svn/repos/myproject
```

实现逻辑（`svnserve.c` + `serve.c`）：
```
1. svnserve.c: 解析 -r 参数，验证为有效目录
2. serve.c:find_repos():
   → 从 URL 提取路径部分
   → 拼接 root 参数 → full_path
   → svn_repos_find_root_path() 定位仓库根
```

安全性：`repos_path_valid()` 防止 `..` 路径逃逸。

---

## 5. 配置系统

### 5.1 svnserve.conf

位于 `repos/conf/svnserve.conf`，在 `find_repos()` 中加载：

```ini
[general]
anon-access = read          # 匿名用户权限: none / read / write
auth-access = write         # 认证用户权限: none / read / write
password-db = passwd        # 密码数据库文件
authz-db = authz            # 授权文件
groups-db = groups          # 用户组文件
realm = My Repository       # 认证域（默认为仓库 UUID）
force-username-case = none  # 用户名大小写处理: none / lower / upper

[sasl]
use-sasl = false            # 是否使用 Cyrus SASL
min-encryption = 0          # 最小加密强度
max-encryption = 256        # 最大加密强度
```

### 5.2 passwd 文件

```ini
[users]
alice = password123
bob = secret456
```

加载逻辑（`serve.c`）：
```c
load_pwdb_config(repository, cfg) {
  svn_config_get(cfg, &pwdb_path, "general", "password-db", NULL);
  // 从 conf/ 目录加载密码文件
}
```

### 5.3 访问控制

```c
set_access(repository, cfg, read_only) {
  repository->auth_access = get_access(cfg, "auth-access", "write", read_only);
  repository->anon_access = get_access(cfg, "anon-access", "read", read_only);
}
```

---

## 6. 协议处理核心

`serve.c` 中的 `serve()` 函数是协议处理入口：

```
serve()
  → 发送 greeting（服务端问候 + 能力列表）
  → 接收客户端版本回应
  → 协商能力
  → 认证循环
  → 认证成功后发送仓库信息
  → 进入命令处理循环
    → 读取命令
    → auth-request 权限确认
    → 分发到命令处理函数
    → 发送响应
```

### 6.1 命令分发

主命令集的处理在 `serve.c` 的 `main_commands[]` 表中：

```c
// 每个命令: { 命令名, 处理函数 }
static const svn_ra_svn_cmd_entry_t main_commands[] = {
  { "reparent",       cmd_reparent },
  { "get-latest-rev", cmd_get_latest_rev },
  { "get-dated-rev",  cmd_get_dated_rev },
  { "change-rev-prop", cmd_change_rev_prop },
  { "rev-proplist",   cmd_rev_proplist },
  { "rev-prop",       cmd_rev_prop },
  { "commit",         cmd_commit },
  { "get-file",       cmd_get_file },
  { "get-dir",        cmd_get_dir },
  { "update",         cmd_update },
  { "switch",         cmd_switch },
  { "status",         cmd_status },
  { "diff",           cmd_diff },
  { "log",            cmd_log },
  // ... 更多命令
};
```

### 6.2 数据连接结构

```c
typedef struct client_conn_t {
  svn_ra_svn_conn_t *conn;        // 协议连接（I/O 缓冲）
  serve_params_t *params;         // 服务参数
  apr_pool_t *pool;               // 内存池
  // ...
} client_conn_t;

typedef struct serve_params_t {
  const char *root;               // 虚拟根目录
  svn_boolean_t read_only;        // 只读模式
  svn_boolean_t vhost;            // 虚拟主机模式
  svn_boolean_t tunnel;           // 隧道模式
  const char *tunnel_user;        // 隧道用户
  const char *fs_type;            // 文件系统类型
  // ...
} serve_params_t;
```

---

## 7. 虚拟主机模式（--vhost）

```
svnserve -d --vhost
```

URL 中的 hostname 部分作为仓库路径的前缀：
```
svn://host.example.com/project
  → 在 root 目录下查找 host.example.com/project
```

---

## 8. 隧道模式

SSH 隧道模式下，svnserve 通过 stdin/stdout 与客户端通信：

```
客户端 → SSH 连接 → sshd → svnserve -t → stdin/stdout
```

特点：
- 认证由 SSH 完成，svnserve 信任 SSH 提供的用户身份
- `--tunnel-user` 可覆盖 SSH 用户
- 跳过协议握手中的 banner 信息处理

---

## 9. 文件列表

| 文件 | 大小 | 说明 |
|------|------|------|
| `svnserve.c` | 48KB | 主程序，命令行解析，连接处理 |
| `serve.c` | 159KB | SVN 协议处理核心 |
| `server.h` | 9KB | 数据结构定义 |
| `logger.c` | 6KB | 日志记录 |
| `log-escape.c` | 5KB | 日志转义 |
| `cyrus_auth.c` | 13KB | Cyrus SASL 认证 |
| `winservice.c` | 17KB | Windows 服务支持 |

---

## 参考源码

- `svnserve/svnserve.c` — 主程序和运行模式
- `svnserve/serve.c` — 协议处理和命令分发
- `svnserve/server.h` — 数据结构定义
- `include/svn_config.h` — 配置选项常量
