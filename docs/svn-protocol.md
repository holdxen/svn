# Subversion `svn://` 协议详细规范

## 1. 协议概述

`svn://` 是 Apache Subversion 的自定义网络协议，用于客户端与 `svnserve` 服务器之间的通信。协议运行在 TCP 之上，默认端口为 **3690**（定义于 `svn_ra_svn.h` 中的 `SVN_RA_SVN_PORT`）。

协议当前版本为 **Version 2**（不再支持 Version 1）。

URL 格式为：
```
svn://[user@]hostname[:port]/repository-path
svn+ssh://[user@]hostname[:port]/repository-path   (通过SSH隧道)
svn+tunnel-name://[user@]hostname[:port]/repository-path  (自定义隧道)
```

## 2. 传输层

### 2.1 直接 TCP 连接

客户端通过 TCP socket 直接连接到服务器的 3690 端口（或自定义端口）。连接启用 TCP keep-alive 以防止网络分区导致的僵尸连接。

### 2.2 隧道模式 (`svn+ssh://`)

URL 中使用 `svn+ssh://` 前缀时，客户端会启动一个 SSH 隧道进程。默认实现为：

```
$SVN_SSH ssh -q -- <hostinfo> svnserve -t
```

隧道进程通过 stdin/stdout 管道传输协议数据。客户端在连接建立时会跳过服务端可能输出的非协议前导数据（如 SSH 的 banner 信息），通过查找 `(` + 空白字符 的模式来定位协议数据的起始位置。

### 2.3 I/O 缓冲

每个连接使用独立的读写缓冲区：
- 读缓冲区大小：`4 × 4096 = 16384` 字节
- 写缓冲区大小：`4 × 4096 = 16384` 字节
- 大于 8KB 的数据块直接发送，不经过缓冲区

## 3. 数据序列化格式（ABNF）

协议使用文本化的数据编码格式。所有数据项（item）以**强制空白符**结尾：

```abnf
item   = word / number / string / list
word   = ALPHA *(ALPHA / DIGIT / "-") space
number = 1*DIGIT space
string = 1*DIGIT ":" *OCTET space
list   = "(" space *item ")" space
space  = 1*(SP / LF)
```

### 3.1 四种基本数据类型

| 类型 | 格式 | 示例 | 说明 |
|------|------|------|------|
| **Word** | `字母数字-` + 空格 | `success ` | 枚举值，区分大小写，最长 25 字符 |
| **Number** | 十进制数字 + 空格 | `42 ` | 无符号 64 位整数 |
| **String** | `长度:内容` + 空格 | `5:hello ` | 可包含任意二进制数据，前缀数字表示字节数 |
| **List** | `( ` 元素* `) ` | `( word 22 ) ` | 可嵌套，元素类型可混合 |

### 3.2 示例

一个包含所有类型的复合数据项：
```
( word 22 6:string ( sublist ) )
```

### 3.3 布尔值

布尔值用 Word 表示：`true` 或 `false`。

### 3.4 列表的语义用途

- **Tuple（元组）**：固定数量的元素，类型各异
- **Optional Tuple（可选元组）**：零个或固定数量的元素
- **Array（数组）**：零个或多个同类型元素

### 3.5 扩展兼容性

实现必须忽略元组中多余的尾部元素，以保证向前兼容。

### 3.6 格式串解析机制（服务端实现）

服务端使用 `svn_ra_svn__parse_tuple()` 函数配合**格式串**来解析客户端发送的元组参数。格式串定义了期望的参数类型和可选性，例如 `set-path` 命令使用 `"crb?(?c)?w"`。

#### 格式字符

| 字符 | C 类型 | 匹配的数据类型 | 默认值（未发送时） |
|------|--------|---------------|-------------------|
| `c` | `const char *` | String | `NULL` |
| `s` | `svn_string_t *` | String | `NULL` |
| `w` | `const char *` | Word | `NULL` |
| `b` | `svn_boolean_t` | Word (`true`/`false`) | `FALSE` |
| `n` | `apr_uint64_t` | Number | `SVN_RA_SVN_UNSPECIFIED_NUMBER` |
| `r` | `svn_revnum_t` | Number | `SVN_INVALID_REVNUM` (-1) |
| `B` | `apr_uint64_t` | Word (`true`/`false`) | `SVN_RA_SVN_UNSPECIFIED_NUMBER` |
| `3` | `svn_tristate_t` | Word (`true`/`false`) | `svn_tristate_unknown` |
| `l` | `svn_ra_svn__list_t *` | List | `NULL` |
| `(...)` | 递归 | 嵌套子元组 | 内部元素各自取默认值 |

#### `?` 前缀：可选参数标记

格式串中的 `?` 放在某个参数（或子元组）**之前**，表示该参数是可选的。其核心语义是：

> **如果元组中的元素在此处用完了，后续所有可选参数自动填充默认值。**

#### 解析算法（两阶段）

源码位于 `marshal.c` 的 `vparse_tuple()` 函数：

**第一阶段：主循环**

```c
for (count = 0; **fmt && count < items->nelts; (*fmt)++, count++)
{
    if (**fmt == '?')  // '?' 在主循环中仅跳过，不做任何事
        (*fmt)++;
    // 按格式字符解析当前元素...
    // 类型不匹配时 break 退出
}
```

同时遍历格式串字符和元组元素。**当元组元素用完时，循环自动退出。**

**第二阶段：默认值填充**

```c
if (**fmt == '?')  // 如果格式串中下一个字符是 '?'
{
    // 遍历剩余所有格式字符，为每个可选参数填充默认值
    for (; **fmt; (*fmt)++)
    {
        switch (**fmt) {
        case 'r': *rev = SVN_INVALID_REVNUM; break;
        case 'c': case 'w': *str = NULL; break;
        case 'b': *boolean = FALSE; break;
        // ... 其他类型各自填充默认值
        }
    }
}
```

#### 实例分析：`set-path` 格式串 `"crb?(?c)?w"`

```
格式串:  c   r   b   ?   (   ?   c   )   ?   w
含义:   path rev bool  [可选区开始]  子元组  lock_token  [子元组结束]  [可选] depth
```

| 客户端发送的元组 | 解析过程 | lock_token | depth_word |
|-----------------|----------|-----------|-----------|
| `( "src" 42 false )` | 3 个元素用完 → `?` 触发默认值填充 | `NULL` | `NULL`（服务端默认 `infinity`） |
| `( "src" 42 false ( "tok" ) )` | 4 个元素，lock-token 正常解析 → `?w` 触发默认值 | `"tok"` | `NULL`（默认 `infinity`） |
| `( "src" 42 false ( ) infinity )` | 5 个元素，lock-token 为空元组，depth 正常解析 | `NULL` | `"infinity"` |
| `( "src" 42 false ( "tok" ) files )` | 5 个元素，全部正常解析 | `"tok"` | `"files"` |

#### C 客户端的发送行为

当前 C 客户端实现**始终发送全部参数**（包括空元组占位），不使用尾部截断优化：

```c
// marshal.c: svn_ra_svn__write_cmd_set_path()
write_tuple_cstring(conn, pool, path);           // 必填
write_tuple_revision(conn, pool, rev);            // 必填
write_tuple_boolean(conn, pool, start_empty);     // 必填
write_tuple_start_list(conn, pool);               // ← 始终发送 (
write_tuple_cstring_opt(conn, pool, lock_token);  // ← NULL 时不写内容，但元组仍在
write_tuple_end_list(conn, pool);                 // ← 始终发送 )
write_tuple_depth(conn, pool, depth);             // ← 始终发送 word
```

因此实际线上格式始终为：

```
无锁令牌: ( set-path ( "src" 42 false ( ) infinity ) )
                               ↑   ↑
                          空元组占位  始终发送
有锁令牌: ( set-path ( "src" 42 false ( "token" ) infinity ) )
```

尾部截断仅在处理旧版客户端时有意义。

#### 与协议规范的关系

协议规范中用 `?` 前缀标注可选参数（如 `? depth:word`），这个标记同时服务于两个目的：

1. **协议层面**：文档化参数可以省略，旧客户端不发送时新服务端仍能正确处理
2. **实现层面**：`vparse_tuple()` 的 `?` 触发默认值填充机制，将缺失参数设为安全的零值

## 4. 连接建立与握手

### 4.1 握手流程

```
客户端                                          服务端
  │                                               │
  │              TCP 连接建立                       │
  │◄──────────────────────────────────────────────│
  │          (1) greeting (服务端问候)               │
  │                                               │
  │──────────────────────────────────────────────►│
  │      (2) version response (客户端版本回应)       │
  │                                               │
  │◄──────────────────────────────────────────────│
  │         (3) auth-request (认证请求)             │
  │                                               │
  │──────────────────────────────────────────────►│
  │         (4) auth-response (认证回应)            │
  │                                               │
  │◄──────────────────────────────────────────────│
  │         (5) challenge(s) (认证挑战)             │
  │                                               │
  │──────────────────────────────────────────────►│
  │         (6) auth token (认证令牌)               │
  │                                               │
  │  ... 可能多轮 challenge/response ...           │
  │                                               │
  │◄──────────────────────────────────────────────│
  │      (7) success + repos-info (认证成功)        │
  │                                               │
  │           可以开始发送命令                       │
```

### 4.2 服务端问候（Greeting）

连接建立后，服务端首先发送：

```
( success ( minver:number maxver:number mechs:list ( cap:word ... ) ) )
```

实际服务端发送示例：
```
( success ( 2 2 () ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries
  commit-revprops depth log-revprops atomic-revprops partial-replay
  inherited-props ephemeral-txnprops file-revs-reverse list ) ) )
```

- `minver=2, maxver=2`：仅支持协议版本 2
- `mechs=()`：空列表（版本 2 中认证机制在后续 auth-request 中发送）
- `cap`：服务端能力列表

### 4.3 客户端回应

客户端选择协议版本并回应：

```
( version:number ( cap:word ... ) url:string ? ra-client:string (? client:string) )
```

示例：
```
( 2 ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries depth mergeinfo
    log-revprops ) svn://localhost/repos "SVN/1.14.0 (x86_64-apple-darwin)" )
```

客户端发送的能力列表：
- `edit-pipeline`（必须）
- `svndiff1`
- `accepts-svndiff2`
- `absent-entries`
- `depth`
- `mergeinfo`
- `log-revprops`

### 4.4 认证请求与响应

服务端发送认证请求：
```
( ( mech:word ... ) realm:string )
```

如果机制列表为空，则无需认证。否则客户端选择一种机制响应：
```
( mech:word [ token:string ] )
```

#### 支持的认证机制

| 机制 | 说明 |
|------|------|
| **ANONYMOUS** | 匿名访问，无凭据 |
| **EXTERNAL** | 使用隧道环境（如 SSH uid）认证 |
| **CRAM-MD5** | 挑战-响应式密码认证 |
| SASL 机制 | 通过 Cyrus SASL 库支持更多机制（如 GSSAPI/Kerberos） |

#### CRAM-MD5 认证流程

1. 服务端发送挑战：`( step challenge:string )`，格式如 `<nonce.timestamp@hostname>`
2. 客户端计算 HMAC-MD5 摘要，发送：`"username hex-digest"`
3. 服务端验证后回复 `( success )` 或 `( failure message:string )`

### 4.5 仓库信息

认证成功后，服务端发送仓库信息：
```
( success ( uuid:string repos-url:string ( cap:word ... ) ) )
```

例如：
```
( success ( 12345678-abcd-efgh-ijkl-123456789abc svn://localhost/repos ( mergeinfo ) ) )
```

## 5. 能力系统（Capabilities）

能力在握手阶段交换，分为服务端能力（S）、客户端能力（C）或两者皆有（CS）：

| 能力名称 | 方向 | 说明 |
|----------|------|------|
| `edit-pipeline` | CS | 编辑管道支持（必须，自 1.0 起） |
| `svndiff1` | CS | svndiff v1 压缩差分格式 |
| `accepts-svndiff2` | CS | 接受 svndiff2 差分格式 |
| `absent-entries` | CS | 支持 absent-dir/absent-file 编辑命令 |
| `commit-revprops` | S | 支持 commit 时指定 rev-props |
| `mergeinfo` | S | 支持 get-mergeinfo 命令 |
| `depth` | S | 支持操作深度和环境深度 |
| `atomic-revprops` | S | 支持 change-rev-prop2 原子操作 |
| `inherited-props` | S | 支持继承属性检索 |
| `list` | S | 支持 list 命令 |
| `log-revprops` | S | 支持日志修订属性 |
| `partial-replay` | S | 支持部分回放 |
| `ephemeral-txnprops` | S | 支持临时事务属性 |
| `file-revs-reverse` | S | 支持反向文件修订遍历 |

## 6. 命令集

协议定义了三个命令集，通过命令切换控制流方向。

### 6.1 通用命令格式

```
command: ( command-name:word params:list )
```

响应格式：
```
command-response: ( success params:list )
                | ( failure ( err:error ... ) )
error: ( apr-err:number message:string file:string line:number )
```

### 6.2 主命令集（Main Command Set）

客户端发送命令，服务端响应。每个命令后服务端会发送 auth-request 进行权限验证。

#### 仓库操作

| 命令 | 参数 | 响应 | 说明 |
|------|------|------|------|
| `reparent` | `( url:string )` | `( )` | 更改会话的父 URL |
| `get-latest-rev` | `( )` | `( rev:number )` | 获取最新修订版本号 |
| `get-dated-rev` | `( date:string )` | `( rev:number )` | 按日期查找修订版本 |
| `check-path` | `( path:string [rev:number] )` | `( kind:node-kind )` | 检查路径类型(none/file/dir/unknown) |
| `stat` | `( path:string [rev:number] )` | `( ? dirent )` | 获取路径状态信息 |

#### 属性操作

| 命令 | 参数 | 响应 | 说明 |
|------|------|------|------|
| `rev-proplist` | `( rev:number )` | `( proplist )` | 列出修订版本所有属性 |
| `rev-prop` | `( rev:number name:string )` | `( [value:string] )` | 获取指定修订属性 |
| `change-rev-prop` | `( rev:number name:string ? value:string )` | `( )` | 修改修订属性 |
| `change-rev-prop2` | `( rev:number name:string [value:string] (dont-care:bool ? previous-value:string) )` | `( )` | 原子修改修订属性 |
| `get-iprops` | `( path:string [rev:number] )` | `( iproplist )` | 获取继承属性 |

#### 文件/目录操作

| 命令 | 参数 | 响应 | 说明 |
|------|------|------|------|
| `get-file` | `( path:string [rev:number] want-props:bool want-contents:bool ? want-iprops:bool )` | `( [checksum:string] rev:number props:proplist [inherited-props:iproplist] )` | 获取文件内容和属性 |
| `get-dir` | `( path:string [rev:number] want-props:bool want-contents:bool ? (dirent-field...) ? want-iprops:bool )` | `( rev:number props:proplist (dirent...) [inherited-props:iproplist] )` | 获取目录内容和属性 |
| `list` | `( path:string [rev:number] depth:word (dirent-field...) ? (pattern:string...) )` | `( )` | 列出目录内容（1.10+） |

`get-file` 如果 `want-contents=true`，响应后服务端会发送文件内容（一系列 string，以空 string 结尾），然后再发送一个 command-response 表示是否出错。

#### 提交操作

```
commit
  params: ( logmsg:string ? ( (lock-path lock-token)... ) keep-locks:bool ? rev-props:proplist )
  response: ( )
```

提交流程：
1. 客户端发送 `commit` 命令
2. 切换到**编辑器命令集**，客户端驱动编辑操作
3. 编辑完成后，服务端发送 auth-request
4. 认证成功发送 commit-info：`( new-rev:number date:string author:string ? (post-commit-err:string) )`

#### 报告类操作（触发 Report 命令集）

| 命令 | 说明 |
|------|------|
| `update` | 更新工作副本 |
| `switch` | 切换到不同 URL |
| `status` | 检查工作副本状态 |
| `diff` | 计算差异 |

流程：客户端发送命令 → 切换到 Report 命令集 → `finish-report` 后服务端发送 auth-request → 切换到 Editor 命令集 → 编辑完成发送响应

#### 日志操作

```
log
  params: ( (target-path:string...) [start-rev:number] [end-rev:number]
            changed-paths:bool strict-node:bool ? limit:number
            ? include-merged-revisions:bool
            all-revprops | revprops (revprop:string...) )
```

服务端逐条发送 log-entry，以 `done` 结尾。

#### 其他命令

- `get-locations` / `get-location-segments`：路径位置查询
- `get-file-revs`：文件修订历史
- `get-mergeinfo`：合并信息查询
- `lock` / `lock-many` / `unlock` / `unlock-many` / `get-lock` / `get-locks`：锁管理
- `replay` / `replay-range`：重放修订操作
- `get-deleted-rev`：查找删除修订版本

### 6.3 编辑器命令集（Editor Command Set）

用于传输增量编辑操作（checkout/update/commit 等）。编辑操作**不返回响应**（除 close-edit/abort-edit 外），但消费方可在任何时候发送错误响应提前终止。

#### 目录操作

| 命令 | 参数 |
|------|------|
| `open-root` | `( [rev:number] root-token:string )` |
| `add-dir` | `( path:string parent-token:string child-token:string [copy-path:string copy-rev:number] )` |
| `open-dir` | `( path:string parent-token:string child-token:string rev:number )` |
| `close-dir` | `( dir-token:string )` |
| `delete-entry` | `( path:string rev:number dir-token:string )` |
| `change-dir-prop` | `( dir-token:string name:string [value:string] )` |
| `absent-dir` | `( path:string parent-token:string )` |

#### 文件操作

| 命令 | 参数 |
|------|------|
| `add-file` | `( path:string dir-token:string file-token:string [copy-path:string copy-rev:number] )` |
| `open-file` | `( path:string dir-token:string file-token:string rev:number )` |
| `close-file` | `( file-token:string [text-checksum:string] )` |
| `apply-textdelta` | `( file-token:string [base-checksum:string] )` |
| `textdelta-chunk` | `( file-token:string chunk:string )` |
| `textdelta-end` | `( file-token:string )` |
| `change-file-prop` | `( file-token:string name:string [value:string] )` |
| `absent-file` | `( path:string parent-token:string )` |

#### 控制命令

| 命令 | 参数 | 响应 |
|------|------|------|
| `target-rev` | `( rev:number )` | 无 |
| `close-edit` | `( )` | `( )` |
| `abort-edit` | `( )` | `( )` |
| `finish-replay` | `( )` | 无（服务端→客户端） |

**Token 机制**：每个打开的目录/文件分配一个唯一 token（字符串），后续操作通过 token 引用，避免重复路径查找。

### 6.4 报告命令集（Report Command Set）

为减少往返延迟，报告命令**不返回响应**。任何错误在调用方命令中返回。

| 命令 | 参数 |
|------|------|
| `set-path` | `( path:string rev:number start-empty:bool ? [lock-token:string] ? depth:word )` |
| `delete-path` | `( path:string )` |
| `link-path` | `( path:string url:string rev:number start-empty:bool ? [lock-token:string] ? depth:word )` |
| `finish-report` | `( )` |
| `abort-report` | `( )` |

## 7. 命令集切换流程

```
初始状态: Main Command Set (客户端发命令)
    │
    ├─ commit ──► Editor Command Set (客户端驱动编辑)
    │               │
    │               └─ close-edit ──► auth-request ──► commit-info ──► 回到 Main
    │
    ├─ update/switch/status/diff ──► Report Command Set (客户端报告)
    │               │
    │               └─ finish-report ──► auth-request ──► Editor Command Set (服务端驱动编辑)
    │                       │
    │                       └─ close-edit ──► response ──► 回到 Main
    │
    └─ replay ──► auth-request ──► Editor Command Set (服务端驱动)
                    │
                    └─ close-edit ──► response ──► 回到 Main
```

## 8. 扩展机制

协议支持三种扩展方式（按优先级排列）：

1. **元组追加**：在任何元组末尾添加新元素，旧实现会忽略多余元素
2. **能力协商**：在连接建立时通过能力列表交换新功能标识
3. **版本升级**：提升协议版本号，双方协商支持的版本范围

### 扩展现有命令的规范

通过 `?` 标记当前位置为合法终止点，然后追加新参数：

```
/* 旧版 */ diff: ( [rev:number] target:string recurse:bool ignore-ancestry:bool url:string )
/* 新版 */ diff: ( [rev:number] target:string recurse:bool ignore-ancestry:bool url:string ? text-deltas:bool )
```

对于可选参数，使用方括号表示：
```
/* 旧版 */ set-path: ( path:string rev:number start-empty:bool )
/* 新版 */ set-path: ( path:string rev:number start-empty:bool ? [lock-token:string] )
```

## 9. 实现限制

- Word 最长 **25** 个字符（实现中 `MAX_WORD_LENGTH=25`）
- 列表嵌套深度限制 **64** 层（`ITEM_NESTING_LIMIT=64`）
- 超过 1MB 的 string 声称会被审慎处理（`SUSPICIOUSLY_HUGE_STRING_SIZE_THRESHOLD=0x100000`）
- 可配置 I/O 大小限制（`max_in` / `max_out`），超出时拒绝请求/响应
- GSSAPI 服务名：`"svn"`

## 10. 典型会话示例

以下是一个简化的 checkout 会话流程：

```
# 1. 服务端问候
S: ( success ( 2 2 () ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries
     commit-revprops depth log-revprops atomic-revprops partial-replay
     inherited-props ephemeral-txnprops file-revs-reverse list ) ) )

# 2. 客户端回应
C: ( 2 ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries depth mergeinfo
     log-revprops ) svn://localhost/repos SVN/1.14.0 )

# 3. 服务端认证请求 (空机制 = 无需认证)
S: ( () 0: )

# 4. 仓库信息
S: ( success ( abc-123-def svn://localhost/repos ( mergeinfo ) ) )

# 5. 客户端请求 update
C: ( update ( 42 0: true infinity false ) )

# 6. 认证请求
S: ( () 0: )

# 7. 客户端报告工作副本状态
C: ( set-path ( 0: 42 false ( ) infinity ) )
C: ( finish-report ( ) )

# 8. 服务端驱动编辑器操作
S: ( open-root ( 42 root-token ) )
S: ( add-dir ( trunk root-token dir-1 ) )
S: ( add-file ( trunk/README dir-1 file-1 ) )
S: ( apply-textdelta ( file-1 ) )
S: ( textdelta-chunk ( file-1 100:....binary-svndiff-data.... ) )
S: ( textdelta-end ( file-1 ) )
S: ( close-file ( file-1 abc123checksum ) )
S: ( close-dir ( dir-1 ) )
S: ( close-edit ( ) )

# 9. 最终响应
S: ( success ( ) )
```

---

**参考源码**：
- `subversion/libsvn_ra_svn/protocol` - 协议规范定义
- `subversion/libsvn_ra_svn/client.c` - 客户端连接实现
- `subversion/libsvn_ra_svn/marshal.c` - 数据序列化/反序列化
- `subversion/libsvn_ra_svn/cram.c` - CRAM-MD5 认证
- `subversion/libsvn_ra_svn/internal_auth.c` - 内置认证机制
- `subversion/svnserve/serve.c` - 服务端实现
- `subversion/include/svn_ra_svn.h` - 能力常量定义
test
