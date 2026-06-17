# svn:// 协议 - 报告命令集详解

## 概述

报告命令集（Report Command Set）是 `svn://` 协议中**客户端描述工作副本状态**的专用命令集合。它仅在 `update`、`switch`、`status`、`diff` 四个主命令触发的会话中出现，用于让客户端向服务端汇报"我的工作副本现在是什么样子"。

服务端收集完报告后，计算差异，然后通过**编辑器命令集**将变更推送给客户端。

### 命令流转模型

```
客户端发送 update/switch/status/diff
   │
   ▼
服务端进入报告命令集（不返回命令响应）
   │
   ├── set-path  ──┐
   ├── delete-path  ├── 客户端描述工作副本状态（可多条，无响应）
   ├── link-path  ──┘
   │
   ▼
finish-report ──► auth-request ──► 编辑器命令集（服务端发送变更）
   │
   ▼
服务端发送空 command-response ( )（表示报告阶段成功结束）
```

### 核心设计特点：无响应流水线

**所有报告命令都没有响应**（除 `finish-report` 外）。这是协议的重要优化：

- 客户端可以连续发送多条 `set-path`/`delete-path`/`link-path`，无需等待服务端确认，极大减少网络往返延迟
- 如果某条报告命令在服务端产生了错误，该错误会被**暂存**，后续所有报告命令被忽略
- 错误最终在 `finish-report` 时，通过编辑器的 `abort-edit` + 调用命令的 `command-response` 返回给客户端
- `abort-report` 产生的错误被静默忽略

### 触发关系

| 主命令 | 触发报告命令集 | 说明 |
|--------|---------------|------|
| `update` | 是 | 客户端汇报 WC 状态，服务端计算与最新版本的差异 |
| `switch` | 是 | 类似 update，但目标 URL 不同 |
| `status` | 是 | 客户端汇报 WC 状态，服务端返回锁信息变更 |
| `diff` | 是 | 客户端汇报 WC 状态，服务端计算并返回文本/属性差异 |
| `commit` | 否 | 直接进入编辑器命令集（无报告阶段） |
| `replay`/`replay-range` | 否 | 直接进入编辑器命令集（无报告阶段） |
| 其他命令 | 否 | 原地返回响应 |

---

## 服务端调度结构

服务端通过 `report_driver_baton_t` 结构体在报告处理期间维护状态：

```c
typedef struct report_driver_baton_t {
  server_baton_t *sb;          /* 服务器全局 baton */
  const char *repos_url;       /* 解码后的仓库 URL */
  void *report_baton;          /* svn_repos 层报告 baton */
  svn_error_t *err;            /* 暂存的首个错误（用于流水线错误延迟） */
  int entry_counter;           /* set-path/link-path 的调用次数 */
  svn_boolean_t only_empty_entries;  /* 是否所有条目都是 start_empty */
  svn_revnum_t *from_rev;      /* diff 日志用：记录 set-path "" 的版本号 */
} report_driver_baton_t;
```

命令分发表：

```c
static const svn_ra_svn__cmd_entry_t report_commands[] = {
  { "set-path",      set_path },
  { "delete-path",   delete_path },
  { "link-path",     link_path },
  { "finish-report", finish_report, NULL, TRUE },  /* TRUE = 退出命令循环 */
  { "abort-report",  abort_report,  NULL, TRUE },  /* TRUE = 退出命令循环 */
  { NULL }
};
```

> 注：`finish-report` 和 `abort-report` 的 `TRUE` 标志表示收到该命令后退出命令处理循环，返回上层主命令。

---

## 命令详解

### 1. `set-path` — 声明工作副本路径的存在及版本

```
params: ( path:string rev:number start-empty:bool [ ( lock-token:string ) ] [ depth:word ] )
```

**作用**：告诉服务端"我的工作副本中存在路径 `path`，它来自版本 `rev`，深度为 `depth`"。这是最核心的报告命令，每个 update/switch/status/diff 会话中至少会有一条 `set-path ""`（空路径，代表目标根）。

**线上格式说明**：`lock-token` 包在内层子元组 `(...)` 中，不指定时子元组为空 `()`。`depth` 是普通可选参数。服务端解析格式串为 `"crb?(?c)?w"`。

**客户端写入格式串**（`marshal.c`）：`c` path + `r` rev + `b` start-empty + `(` + `?c` lock-token + `)` + `?` + `w` depth

#### 参数详解

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8 relpath) | 是 | 工作副本内相对于目标（target）的路径。空字符串 `""` 表示目标根节点。路径必须规范化（canonical relpath） |
| `rev` | number | 是 | 该路径在工作副本中对应的修订版本号。对于本地新增的路径可使用 `SVN_INVALID_REVNUM`（-1）或 `0` |
| `start-empty` | bool | 是 | 若为 `true` 且 `path` 是目录，指示服务端"假设该目录没有子项和属性"。用于"低置信度"客户端报告（如工作副本被损坏或升级时）。若为 `false`，服务端会假定该目录在 `rev` 版本中的所有子项仍然存在于工作副本中，无需逐一报告 |
| `lock-token` | string (opaque) | 否 | 工作副本中持有的该路径的锁令牌。如果没有锁，此字段省略 |
| `depth` | word | 否 | 工作副本中该路径的深度限制。取值为 `empty`、`files`、`immediates`、`infinity`、`exclude`。如果省略，服务端默认为 `infinity`（兼容旧客户端） |

#### depth 取值含义

| 值 | 含义 |
|----|------|
| `empty` | 该路径存在但不包含任何子项 |
| `files` | 包含文件子项，但不包含子目录 |
| `immediates` | 包含文件子项和直接子目录（但子目录本身不递归） |
| `infinity` | 完全递归，包含所有后代 |
| `exclude` | 该路径在报告中被排除（不出现在 diff 计算中） |

#### `update` 的 `target` 与 `set-path` 的 `path` 的关系

报告命令中的 `path` 参数是**相对于 `update`/`switch`/`status`/`diff` 命令的 `target` 参数**的，而不是直接相对于会话 URL。服务端在处理时会自动将 `target` 拼接到 `path` 前面：

```c
// reporter.c: write_path_info()
path = svn_relpath_join(b->s_operand, path, pool);
```

这意味着：

| 参数 | 含义 | 存储 |
|------|------|------|
| `target`（主命令参数） | 相对于**会话 URL**（`fs_path`）的偏移，定义操作锚点 | `s_operand` |
| `path`（`set-path` 参数） | 相对于 **`target`** 的偏移 | 与 `s_operand` 拼接 |

仓库中的实际路径 = `fs_path` + `target` + `path`。

**具体示例**：假设会话 URL 是 `svn://server/repo`（`fs_path = "/"`）

```
场景 A：update(target="")   → 锚点 = /
  set-path(path="")          → 指向 /
  set-path(path="trunk")     → 指向 /trunk
  set-path(path="trunk/src") → 指向 /trunk/src

场景 B：update(target="trunk")  → 锚点 = /trunk
  set-path(path="")             → 指向 /trunk
  set-path(path="src")          → 指向 /trunk/src
  set-path(path="src/main.c")   → 指向 /trunk/src/main.c
```

`target` 同时也决定了**编辑器返回路径的根**（`t_path = fs_path + target`）。因此：

- `update(target="")` 后，编辑器的 `open-root` 对应 `/`，`add-file("trunk/src/main.c")` 对应 `/trunk/src/main.c`
- `update(target="trunk")` 后，编辑器的 `open-root` 对应 `/trunk`，`add-file("src/main.c")` 对应 `/trunk/src/main.c`

典型场景中 `target` 通常为空字符串 `""`，此时 `set-path` 的 `path` 直接相对于会话 URL。

#### 调用顺序约束

- **第一条报告命令**必须是 `set-path ""`（空路径），用于设置目标的根版本号
- 所有报告调用必须按**深度优先**（depth-first）顺序：先父后子，同一父节点的所有子节点在其兄弟节点之前
- 如果操作的目标相对锚点被本地删除或切换，初始 `set-path ""` 后需紧跟 `delete-path ""` 或 `link-path ""`

#### 服务端执行逻辑

1. 解析参数，规范化路径为 canonical relpath
2. 如果 `depth_word` 存在，调用 `svn_depth_from_word()` 转换为 `svn_depth_t`
3. 如果 `path` 是 `""`（根路径）且 `from_rev` 非 NULL，记录 `rev` 到 `*from_rev`（用于 diff 日志）
4. 调用 `svn_repos_set_path3(report_baton, path, rev, depth, start_empty, lock_token, pool)`
5. 递增 `entry_counter`
6. 如果 `start_empty` 为 false，将 `only_empty_entries` 设为 false

#### 协议线上格式示例

```
( set-path ( "" 42 true ( ) ) )
( set-path ( "trunk/src" 100 false ( ) infinity ) )
( set-path ( "trunk/docs" 95 false ( "opaquelocktoken:abc-123" ) files ) )
```

---

### 2. `delete-path` — 声明工作副本路径缺失

```
params: ( path:string )
```

**作用**：告诉服务端"我的工作副本中**不存在**路径 `path`"。典型场景：本地删除的文件/目录，或者因为冲突/错误而丢失的条目。服务端据此在编辑驱动中生成 `add_file`/`add_directory` 操作来恢复这些路径。

**服务端解析格式串**：`"c"`

#### 参数详解

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8 relpath) | 是 | 工作副本内相对于目标的缺失路径 |

#### 服务端执行逻辑

1. 解析参数，规范化路径为 canonical relpath
2. 调用 `svn_repos_delete_path(report_baton, path, pool)`
3. 该调用通知报告系统：此路径不存在于工作副本中，需要在编辑驱动中重新添加

#### 典型使用场景

- `svn update` 时发现本地有文件被删除（但仓库中还存在），服务端需要重新添加该文件
- 操作的 target 本身在本地不存在，紧跟初始 `set-path ""` 之后调用 `delete-path ""`

#### 协议线上格式示例

```
( delete-path ( "trunk/removed-file.c" ) )
( delete-path ( "" ) )   ← 目标本身在本地缺失
```

---

### 3. `link-path` — 声明工作副本路径指向不同仓库路径

```
params: ( path:string url:string rev:number start-empty:bool [ ( lock-token:string ) ] [ depth:word ] )
```

**作用**：类似 `set-path`，但关键区别在于：工作副本中的 `path` **不是**对当前仓库同路径的反映，而是对**另一个仓库 URL** 在版本 `rev` 处的反映。这是 `svn switch` 操作的核心机制。

**线上格式说明**：`lock-token` 包在内层子元组 `(...)` 中，与 `set-path` 相同。服务端解析格式串为 `"ccrb?(?c)?w"`。

**服务端解析格式串**：`"ccrb?(?c)?w"`

#### 参数详解

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8 relpath) | 是 | 工作副本内的路径，相对于报告目标根 |
| `url` | string (UTF-8 URL) | 是 | 该工作副本路径实际对应的**绝对仓库 URL**。注意：这是一个完整 URL，包含 scheme（如 `svn://...`） |
| `rev` | number | 是 | `url` 对应的修订版本号 |
| `start-empty` | bool | 是 | 同 `set-path`：若为 `true` 且为目录，假设目录无子项 |
| `lock-token` | string (opaque) | 否 | 该路径的锁令牌，若无锁则省略 |
| `depth` | word | 否 | 深度限制，省略时默认为 `infinity` |

#### 与 `set-path` 的核心区别

```
set-path:  path（WC 路径） 对应  当前仓库的同路径
link-path: path（WC 路径） 对应  url（另一个仓库路径）
```

源码注释（serve.c 第 920 行）对此也有感叹：
> *WHAT?!  The link path is an absolute URL?!  Didn't see that coming...*

#### 服务端执行逻辑

1. 解析参数
2. 规范化 `path` 为 canonical relpath，规范化 `url` 为 canonical URI
3. 转换 `url` 为仓库内文件系统路径 `fs_path`（通过 `get_fs_path()` 从仓库 URL 解析）
4. 调用 `svn_repos_link_path3(report_baton, path, fs_path, rev, depth, start_empty, lock_token, pool)`

> 注意：虽然协议传输的是完整 URL，但服务端内部会将其转换为文件系统路径再传递给 `svn_repos` 层。

#### 典型使用场景

- `svn switch`：工作副本从 `trunk` 切换到 `branches/feature` 时，用 `link-path` 告知服务端本地路径现在对应分支路径
- `svn switch --relocate`：仓库 URL 变更时重新映射

#### 协议线上格式示例

```
( link-path ( "" "svn://server/repo/branches/feature" 200 true ( ) ) )
( link-path ( "subdir" "svn://server/repo/branches/feature/subdir" 200 false ( ) infinity ) )
```

---

### 4. `finish-report` — 完成报告并触发编辑驱动

```
params: ( )
```

**作用**：通知服务端"我的工作副本状态描述完毕"。服务端随后执行差异计算，并通过编辑器命令集将变更推送给客户端。这是报告命令集中**唯一有交互响应**的命令。

**服务端解析格式串**：无参数解析

#### 完整执行流程

**客户端侧**（`ra_svn_finish_report`）：

```
1. 发送 ( finish-report ( ) )
2. 处理 auth-request（handle_auth_request）
3. 驱动编辑器（svn_ra_svn_drive_editor2）—— 接收并处理编辑器命令
4. 读取 command-response（空元组）
```

**服务端侧**（`finish_report` + `accept_report`）：

```
1. 发送 trivial auth-request（空机制列表，无需重新认证）
2. 调用 svn_repos_finish_report(report_baton, pool)
   ├── 计算工作副本与目标版本的差异
   └── 驱动网络编辑器（向客户端发送编辑器命令）
3. 编辑器命令全部发送完毕后
4. 发送空 command-response ( )
```

#### 响应机制

`finish-report` 本身不直接返回 `command-response`。实际的响应流程是：

```
客户端：                          服务端：
( finish-report ( ) )  ──────►
                               ( ( ) "" )         ← auth-request（trivial，空机制）
                               ( target-revision 42 )
                               ( open-root ... )
                               ...编辑器命令...
                               ( close-edit ( ) )
                               ( success ( ) )    ← command-response（空元组）
```

如果报告过程中发生错误：

```
客户端：                          服务端：
( finish-report ( ) )  ──────►
                               ( ( ) "" )         ← auth-request
                               ( abort-edit ( ) ) ← 中止编辑
                               ( failure ( ... ) ) ← command-response 携带错误
```

#### 协议约束

- 调用 `finish-report` 后，不得再调用任何报告命令
- 如果报告期间有错误（`rb.err` 非 NULL），服务端调用 `SVN_CMD_ERR` 返回错误，由上层 `handle_commands()` 转换为 `failure` 响应

---

### 5. `abort-report` — 中止报告操作

```
params: ( )
```

**作用**：通知服务端"取消本次报告操作"。客户端在报告过程中遇到本地错误时调用此命令来清理服务端状态。

**服务端解析格式串**：无参数解析

#### 执行逻辑

1. 服务端收到后调用 `svn_repos_abort_report(report_baton, pool)`
2. **任何错误都被静默忽略**（`svn_error_clear`）
3. 清理报告期间分配的所有资源（文件系统事务等）

#### 协议约束

- 调用 `abort-report` 后，不得再调用任何报告命令（包括 `finish-report`）
- `abort-report` 命令本身**没有响应**（所有报告命令都无响应）
- 即使 `abort-report` 失败，错误也被忽略——协议设计上认为报告中止不需要错误反馈

#### 典型使用场景

- 客户端在发送报告命令的过程中发现本地 I/O 错误
- 用户中断操作（Ctrl+C）

---

## 协议数据类型说明

### String 参数的语义

| 命令 | 参数 | C 类型 | 实际语义 |
|------|------|--------|----------|
| `set-path` | `path` | `const char *` | UTF-8 相对路径（canonical relpath） |
| `set-path` | `lock-token` | `const char *` | 不透明标识符（opaque lock token） |
| `delete-path` | `path` | `const char *` | UTF-8 相对路径（canonical relpath） |
| `link-path` | `path` | `const char *` | UTF-8 相对路径（canonical relpath） |
| `link-path` | `url` | `const char *` | UTF-8 绝对 URL（含 scheme） |
| `link-path` | `lock-token` | `const char *` | 不透明标识符（opaque lock token） |

### Word 参数

| 命令 | 参数 | 取值范围 |
|------|------|----------|
| `set-path` | `depth` | `empty`、`files`、`immediates`、`infinity`、`exclude` |
| `link-path` | `depth` | 同上 |

### Bool 参数

| 命令 | 参数 | 含义 |
|------|------|------|
| `set-path` | `start-empty` | `true` = 假设目录无子项；`false` = 服务端假定子项存在 |
| `link-path` | `start-empty` | 同上 |

### Number 参数

| 命令 | 参数 | 含义 |
|------|------|------|
| `set-path` | `rev` | 工作副本中该路径的版本号，`-1` 表示无效/新增 |
| `link-path` | `rev` | 链接目标 URL 的版本号 |

---

## 完整交互示例

### 示例 1：简单 `svn update`

工作副本在版本 42，目标为根目录，深度 infinity，有两个文件被本地修改：

```
客户端：                                    服务端：
────────                                    ────────

← ( update ( 50 "" true infinity ) )       ← 主命令 update

      ── 进入报告命令集 ──

( set-path ( "" 42 true ( ) infinity ) )  ──►    （无响应，流水线）
( set-path ( "src" 42 false ( ) infinity ) ) ─►  （无响应）
( set-path ( "src/main.c" 42 false ( ) ) )  ──►  （无响应）
( set-path ( "src/util.c" 42 false ) )  ──►  （无响应）
( set-path ( "docs" 42 false files ) )  ──►  （无响应）
( finish-report ( ) )                   ──►

      ── 服务端发送 auth-request ──

                                      ◄──  ( ( ) "" )

      ── 进入编辑器命令集 ──

                                      ◄──  ( target-revision 50 )
                                      ◄──  ( open-root ( "" 42 50 ) )
                                      ◄──  ( open-file ( "src/main.c" ... ) )
                                      ◄──  ( apply-textdelta ... )
                                      ◄──  ( change-file-prop ... )
                                      ◄──  ( close-file ( "src/main.c" ... ) )
                                      ◄──  ( close-dir ( "" ) )
                                      ◄──  ( close-edit ( ) )

      ── 报告阶段结束，返回 command-response ──

                                      ◄──  ( success ( ) )

      ── 回到主命令集 ──
```

### 示例 2：`svn switch` 到分支

工作副本从 `trunk` 切换到 `branches/release-2.0`：

```
客户端：                                    服务端：
────────                                    ────────

← ( switch ( 100 "" true
    "svn://repo/branches/release-2.0"
    infinity true false ) )

      ── 进入报告命令集 ──

( set-path ( "" 42 true infinity ) )  ──►    （无响应）
( link-path ( ""
    "svn://repo/branches/release-2.0"
    100 false infinity ) )            ──►    （无响应，切换目标映射）
( set-path ( "src" 42 false infinity ) ) ─►  （无响应）
( link-path ( "src"
    "svn://repo/branches/release-2.0/src"
    100 false infinity ) )            ──►    （无响应）
( finish-report ( ) )                   ──►

      ── 编辑器和响应同 update 示例 ──
```

### 示例 3：`svn update` 后有本地删除

工作副本中 `old-file.c` 被本地删除：

```
客户端：                                    服务端：
────────                                    ────────

← ( update ( 50 "" true infinity ) )

( set-path ( "" 42 false infinity ) )  ──►   （无响应）
( delete-path ( "old-file.c" ) )        ──►  （无响应，告知服务端此路径缺失）
( finish-report ( ) )                   ──►

                                      ◄──  ( ( ) "" )        ← auth-request
                                      ◄──  ( target-revision 50 )
                                      ◄──  ...
                                      ◄──  ( add-file ( "old-file.c" ... ) )  ← 服务端重新添加
                                      ◄──  ...
                                      ◄──  ( close-edit ( ) )
                                      ◄──  ( success ( ) )
```

---

## 与 C API 的对应关系

### `svn_ra_reporter3_t` vtable

报告命令集与 `svn_ra_reporter3_t` 结构体（定义于 `svn_ra.h`）一一对应：

| 协议命令 | C API 函数指针 | 说明 |
|----------|----------------|------|
| `set-path` | `(*set_path)` | 声明路径存在及版本/深度 |
| `delete-path` | `(*delete_path)` | 声明路径缺失 |
| `link-path` | `(*link_path)` | 声明路径映射到不同仓库 URL |
| `finish-report` | `(*finish_report)` | 完成报告，触发编辑驱动 |
| `abort-report` | `(*abort_report)` | 中止报告操作 |

### `svn_repos` 层对应函数

服务端将报告命令传递给 `svn_repos` 层的报告系统：

| 报告命令 | `svn_repos` 函数 |
|----------|-------------------|
| `set-path` | `svn_repos_set_path3(report_baton, path, rev, depth, start_empty, lock_token, pool)` |
| `delete-path` | `svn_repos_delete_path(report_baton, path, pool)` |
| `link-path` | `svn_repos_link_path3(report_baton, path, fs_path, rev, depth, start_empty, lock_token, pool)` |
| `finish-report` | `svn_repos_finish_report(report_baton, pool)` |
| `abort-report` | `svn_repos_abort_report(report_baton, pool)` |

### 初始化函数

报告会话由 `svn_repos_begin_report3()` 初始化，其参数由触发报告的主命令提供：

```c
svn_repos_begin_report3(
  &report_baton,   /* 输出：报告 baton */
  rev,             /* 目标版本 */
  repos,           /* 仓库对象 */
  fs_base,         /* 仓库文件系统基础路径 */
  target,          /* 操作目标 */
  tgt_path,        /* 目标路径（switch 场景下指向不同路径） */
  text_deltas,     /* 是否发送文本增量 */
  depth,           /* 操作深度 */
  ignore_ancestry, /* 是否忽略节点祖先关系 */
  send_copyfrom_args, /* 是否发送 copy-from 信息 */
  editor,          /* 网络编辑器（用于向客户端发送变更） */
  edit_baton,
  authz_read_func, /* 权限检查回调 */
  authz_read_baton,
  zero_copy_limit, /* 零拷贝优化阈值 */
  pool
);
```

---

## 关键设计要点总结

### 1. 流水线无响应设计

报告命令是协议中**唯一使用无响应设计**的命令集，这是一个精心权衡的结果：

- **优势**：update/switch 操作可能需要发送成百上千条 `set-path` 命令。如果每条都要等待响应，网络 RTT 将使操作极其缓慢
- **代价**：错误处理变复杂——需要延迟报告错误，在 `finish-report` 时统一处理
- **实现**：服务端通过 `rb.err` 暂存首个错误，后续命令直接跳过处理

### 2. 深度优先调用顺序

报告命令的调用顺序必须遵循**深度优先遍历**规则。这不是任意约定，而是 `svn_repos` 层差异计算算法的要求——它按顺序流式处理路径，不能回溯。

### 3. 初始空路径约定

每次报告会话的**第一条命令**必须是 `set-path ""`，设置根版本号。这是因为服务端需要知道工作副本的基线版本才能开始差异计算。

### 4. `link-path` 的 URL 转路径转换

`link-path` 在协议层传输的是完整 URL，但服务端内部会将其转换为文件系统路径（`fs_path`），然后传递给 `svn_repos_link_path3()`。这是一个值得注意的抽象层转换点。

### 5. `finish-report` 的双重角色

`finish-report` 既是报告命令集的终止命令，也是编辑器命令集的触发器。它的 auth-request + editor commands + command-response 构成了一个完整的"报告结果"响应。
