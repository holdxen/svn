# 钩子脚本（Hook Scripts）

## 1. 概述

钩子脚本是 Subversion 服务端的事件驱动机制，允许仓库管理员在特定操作的关键节点执行自定义逻辑。常见用途包括：提交验证、提交通知、权限细粒度控制等。

钩子位于仓库的 `hooks/` 目录下，每个钩子是一个可执行文件（shell 脚本、Python、Perl 等）。

源码位于 `libsvn_repos/hooks.c`，钩子名定义在 `libsvn_repos/repos.h`。

---

## 2. 钩子列表

### 2.1 提交相关

| 钩子 | 触发时机 | 参数 | stdin |
|------|----------|------|-------|
| **start-commit** | 事务创建前 | `repos, user, capabilities, txn_name` | 无 |
| **pre-commit** | 事务提交前 | `repos, txn_name` | LOCK-TOKENS（如果有） |
| **post-commit** | 事务提交后 | `repos, rev, txn_name` | 无 |

### 2.2 修订属性相关

| 钩子 | 触发时机 | 参数 | stdin |
|------|----------|------|-------|
| **pre-revprop-change** | 修改 rev-prop 前 | `repos, rev, author, name, action` | 新属性值 |
| **post-revprop-change** | 修改 rev-prop 后 | `repos, rev, author, name, action` | 旧属性值 |

`action` 参数值：`A`（添加）、`M`（修改）、`D`（删除）。

### 2.3 锁相关

| 钩子 | 触发时机 | 参数 | stdin |
|------|----------|------|-------|
| **pre-lock** | 加锁前 | `repos, path, username, comment, steal_lock` | 无 |
| **post-lock** | 加锁后 | `repos, username` | paths（每行一个） |
| **pre-unlock** | 解锁前 | `repos, path, username, token, break_lock` | 无 |
| **post-unlock** | 解锁后 | `repos, username` | paths（每行一个） |

### 2.4 Sentinel（读/写哨兵）

| 钩子 | 触发时机 | 说明 |
|------|----------|------|
| **read-sentinels** | 读操作前 | 控制读访问 |
| **write-sentinels** | 写操作前 | 控制写访问 |

定义于 `repos.h`：
```c
#define SVN_REPOS__HOOK_START_COMMIT        "start-commit"
#define SVN_REPOS__HOOK_PRE_COMMIT          "pre-commit"
#define SVN_REPOS__HOOK_POST_COMMIT         "post-commit"
#define SVN_REPOS__HOOK_READ_SENTINEL       "read-sentinels"
#define SVN_REPOS__HOOK_WRITE_SENTINEL      "write-sentinels"
#define SVN_REPOS__HOOK_PRE_REVPROP_CHANGE  "pre-revprop-change"
#define SVN_REPOS__HOOK_POST_REVPROP_CHANGE "post-revprop-change"
#define SVN_REPOS__HOOK_PRE_LOCK            "pre-lock"
#define SVN_REPOS__HOOK_POST_LOCK           "post-lock"
#define SVN_REPOS__HOOK_PRE_UNLOCK          "pre-unlock"
#define SVN_REPOS__HOOK_POST_UNLOCK         "post-unlock"
```

---

## 3. 执行模型

### 3.1 执行流程

```
1. check_hook_cmd()   — 检查钩子文件是否存在（Windows 尝试 .exe/.cmd/.bat/.wsf）
2. 读取 hooks-env     — 加载环境变量配置
3. svn_io_start_cmd3() — 启动子进程，传入参数和环境变量
4. check_hook_result() — 等待子进程退出，读取 stderr
5. 根据退出码决定继续还是拒绝
```

### 3.2 退出码语义

| 退出码 | 语义 |
|--------|------|
| **0** | 成功，继续操作 |
| **非 0** | 失败，拒绝操作（仅 pre-* 和 start-* 钩子有效） |

`post-*` 钩子的退出码被忽略（操作已完成）。

### 3.3 同步/异步

- **pre-* 钩子**：同步执行，必须等待完成后才能继续
- **post-* 钩子**：同步执行，但退出码不影响操作结果
- 钩子超时：可通过配置设定超时时间

### 3.4 stderr 处理

钩子的 stderr 输出会被：
1. 读取到内存
2. 转换为 UTF-8 编码
3. 包含在错误消息中返回给客户端（pre-* 钩子失败时）

---

## 4. 环境变量

### 4.1 默认环境变量

钩子脚本在一个**最小化的环境**中执行，默认情况下：
- 清除大部分环境变量
- 仅保留必要的安全变量

### 4.2 hooks-env 配置

通过 `conf/hooks-env` 文件自定义环境变量（INI 格式）：

```ini
[default]
PATH=/usr/local/bin:/usr/bin
LANG=en_US.UTF-8

[pre-commit]
MY_CUSTOM_VAR=value
SVNLOOK=/usr/local/bin/svnlook
```

- `[default]` 段：对所有钩子生效
- `[<hook-name>]` 段：仅对指定钩子生效
- 钩子特定段会覆盖 default 段的同名变量

定义于 `repos.h`：
```c
#define SVN_REPOS__CONF_HOOKS_ENV           "hooks-env"
#define SVN_REPOS__HOOKS_ENV_DEFAULT_SECTION "default"
```

---

## 5. 典型钩子示例

### 5.1 pre-commit：验证提交

```bash
#!/bin/sh
REPOS="$1"
TXN="$2"

# 检查日志消息非空
SVNLOOK=/usr/bin/svnlook
$SVNLOOK log -t "$TXN" "$REPOS" | grep -q "[a-zA-Z0-9]"
if [ $? -ne 0 ]; then
  echo "Empty log message not allowed" >&2
  exit 1
fi

# 检查不允许提交 .exe 文件
$SVNLOOK changed -t "$TXN" "$REPOS" | grep -q "\.exe$"
if [ $? -eq 0 ]; then
  echo "Cannot commit .exe files" >&2
  exit 1
fi

exit 0
```

### 5.2 post-commit：发送通知

```bash
#!/bin/sh
REPOS="$1"
REV="$2"

# 发送提交通知邮件
/usr/local/bin/svn-commit-email.pl "$REPOS" "$REV" dev-team@example.com &
exit 0
```

### 5.3 pre-revprop-change：允许修改日志

```bash
#!/bin/sh
REPOS="$1"
REV="$2"
USER="$3"
PROPNAME="$4"
ACTION="$5"

# 仅允许修改 svn:log
if [ "$PROPNAME" = "svn:log" -a "$ACTION" = "M" ]; then
  exit 0
fi

echo "Only svn:log modification is allowed" >&2
exit 1
```

---

## 6. svnlook 工具

`svnlook` 是钩子脚本最常用的辅助工具，用于在仓库本地查看事务或修订版信息：

```bash
svnlook changed -t TXN REPOS     # 查看变更路径
svnlook log -t TXN REPOS         # 查看日志消息
svnlook author -t TXN REPOS      # 查看提交者
svnlook diff -t TXN REPOS        # 查看差异
svnlook info -t TXN REPOS        # 查看提交信息
```

`-t` 参数表示查看事务（pre-commit 场景），`-r` 表示查看修订版（post-commit 场景）。

---

## 参考源码

- `libsvn_repos/hooks.c` — 钩子执行逻辑
- `libsvn_repos/repos.h` — 钩子名和环境变量常量
- `svnserve/serve.c` — svnserve 中的钩子调用
- `libsvn_repos/repos.c` — 仓库创建（含模板钩子）
