# svn:// 协议 - 主命令集详解

## 概述

主命令集（Main Command Set）是 `svn://` 协议中客户端发起的顶层操作集合，对应 `svn_ra` 接口层的所有操作。它是协议的"入口命令集"——客户端在完成连接握手和认证之后，首先进入的就是主命令集。

### 命令流转模型

```
客户端连接
   │
   ▼
主命令集 ◄────────────────────────────┐
   │                                   │
   ├── commit ─────────► 编辑器命令集 ─┤
   │                                   │
   ├── update/switch/status/diff ──► 报告命令集 ──► 编辑器命令集 ──┤
   │                                   │
   ├── replay/replay-range ──► 编辑器命令集 ─┤
   │                                   │
   └── 其他命令（原地返回）──────────────┘
```

每次客户端发送一个主命令后，服务端会先发送一个 `auth-request` 进行权限确认。如果不需要新的认证（空机制列表），服务端直接进入命令处理并发送响应。

### 命令响应通用格式

所有命令的响应都使用统一的 `command-response` 格式：

```
成功：( success ( 返回参数... ) )
失败：( failure ( ( apr-err:number message:string file:string line:number ) ... ) )
```

**成功格式中的 `...`**：表示**零个或多个返回参数**，具体数量和类型由每个命令自行定义。例如：
- `get-latest-rev` 返回 `( success ( 42 ) )` — 一个参数（版本号）
- `reparent` 返回 `( success ( ) )` — 零个参数（空元组）
- `get-file` 返回 `( success ( ( proplist ) rev:number ) )` — 两个参数

**失败格式中的 `...`**：表示**一个或多个错误条目**。Subversion 的错误是**链式结构**（error trace），类似异常调用栈。每个 `( apr-err message file line )` 是一个错误节点，多个节点串联表示错误的传播链路。例如：

```
( failure
  ( ( 195012 "Authorization failed" "serve.c" 843 )
    ( 220001 "Can't open file" "io.c" 1234 ) ) )
```

表示"因为底层打不开文件，导致上层认证失败"。第一个错误是最终呈现给用户的顶层错误，后续错误是底层原因链。

协议规范文件（`libsvn_ra_svn/protocol`）的原始定义：

```
command-response: ( success params )
                | ( failure ( error ... ) )
error:          ( apr-err:number message:string file:string line:number )
```

---

## 命令详解

### 1. `reparent` — 重新设置会话路径

```
params:   ( url:string )
response: ( )
```

**作用**：将当前会话的仓库路径切换到另一个 URL。URL 必须指向同一个仓库内的路径。

**参数说明**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `url` | string (UTF-8) | 新的会话 URL，必须是完整 URL（含 scheme），指向同一仓库内的路径 |

**服务端处理**：解析格式串 `"c"`，规范化 URL，验证其仍属于同一仓库，然后更新内部 `fs_path`。

**响应**：空元组 `( )` 表示成功。

**典型使用场景**：客户端在多个目录操作之间，避免重新建立连接。

---

### 2. `get-latest-rev` — 获取最新版本号

```
params:   ( )
response: ( rev:number )
```

**作用**：查询仓库当前的最新（HEAD）修订版本号。

**参数说明**：无参数。

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `rev` | number | 仓库当前的 youngest 修订版本号 |

**示例**：
```
客户端发送：( get-latest-rev ( ) )
服务端响应：( success ( 1234 ) )
```

---

### 3. `get-dated-rev` — 按日期查找版本号

```
params:   ( date:string )
response: ( rev:number )
```

**作用**：查找指定时间戳对应的修订版本号，返回该时间或之前最新的版本。

**参数说明**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `date` | string (UTF-8) | ISO 8601 格式的时间戳，如 `2024-01-15T10:30:00.000000Z` |

**服务端处理**：解析格式串 `"c"`，使用 `svn_time_from_cstring()` 转换为内部时间格式，然后查找对应版本。

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `rev` | number | 指定时间或之前最新的修订版本号 |

---

### 4. `change-rev-prop` — 修改修订属性

```
params:   ( rev:number name:string ? value:string )
response: ( )
```

**作用**：修改或删除指定修订版本的某个属性。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 是 | 目标修订版本号 |
| `name` | string (UTF-8) | 是 | 属性名称，如 `svn:log`、`svn:author` |
| `value` | string (binary) | 否 | 新的属性值；省略时表示**删除**该属性 |

> **注意**：`value` 参数的省略方式不是标准的可选元组 `(?s)`，而是直接省略（因为该参数最初是强制的，后来改为可选时为兼容性而特殊处理）。服务端解析格式串为 `"rc?s"`。

**权限要求**：需要写权限。

**响应**：空元组。

---

### 5. `change-rev-prop2` — 原子修改修订属性

```
params:   ( rev:number name:string [ value:string ]
            ( dont-care:bool ? previous-value:string ) )
response: ( )
```

**作用**：原子地修改或删除修订属性，支持 CAS（Compare-And-Swap）语义。需要服务端具有 `atomic-revprops` 能力。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 是 | 目标修订版本号 |
| `name` | string (UTF-8) | 是 | 属性名称 |
| `value` | string (binary) | 否 | 新的属性值；省略（空元组 `()`）时删除属性 |
| `dont-care` | bool | 是 | `true` = 无条件修改；`false` = 仅当前值匹配 `previous-value` 时才修改 |
| `previous-value` | string (binary) | 条件 | 当前期望的属性值；仅当 `dont-care = false` 时必须提供；若 `dont-care = false` 且省略，表示属性当前必须不存在 |

**服务端处理**：解析格式串 `"rc(?s)(b?s)"`。如果 `dont-care = true` 但提供了 `previous-value`，返回错误。

**响应**：空元组。

---

### 6. `rev-proplist` — 列出修订所有属性

```
params:   ( rev:number )
response: ( props:proplist )
```

**作用**：获取指定修订版本的所有属性列表。

**参数说明**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `rev` | number | 目标修订版本号 |

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `props` | proplist | 属性列表，格式为 `( ( name:string value:string ) ... )` |

**proplist 格式**：
```
( ( "svn:author" "alice" ) ( "svn:date" "2024-01-15T10:30:00.000000Z" ) ( "svn:log" "fix bug" ) )
```

---

### 7. `rev-prop` — 获取单个修订属性

```
params:   ( rev:number name:string )
response: ( [ value:string ] )
```

**作用**：获取指定修订版本的单个属性值。

**参数说明**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `rev` | number | 目标修订版本号 |
| `name` | string (UTF-8) | 属性名称 |

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `value` | string (binary) | 属性值；如果属性不存在，返回空元组 `()` |

---

### 8. `commit` — 提交更改

```
params:   ( logmsg:string ? ( ( lock-path:string lock-token:string ) ... )
            keep-locks:bool ? rev-props:proplist )
response: ( )
```

**作用**：开始一次提交操作。服务端发送空响应后，**客户端切换到编辑器命令集**驱动编辑操作。编辑完成后，服务端发送认证请求，认证成功后发送 `commit-info`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `logmsg` | string (UTF-8) | 是 | 提交日志消息（当 `rev-props` 存在时被忽略） |
| `lock-tokens` | list | 否 | 锁令牌数组，每个元素为 `( path:string token:string )`；1.2 之前客户端不发送此参数 |
| `keep-locks` | bool | 是 | `true` = 提交后保留锁；`false` = 提交后自动释放锁 |
| `rev-props` | proplist | 否 | 修订属性表；存在时 `logmsg` 被忽略，仅其中的 `svn:log` 条目有效；1.5 之前客户端不发送此参数 |

**服务端处理**：解析格式串 `"clb?l"`。

**命令执行流程**：
```
客户端发送 commit ──► 服务端返回 ( success ( ) )
                    ──► 客户端驱动编辑器命令集
                    ──► 编辑完成（close-edit）
                    ──► 服务端发送 auth-request
                    ──► 认证交换完成
                    ──► 服务端发送 commit-info
```

**commit-info**（编辑成功后发送）：
```
( new-rev:number date:string author:string ? ( post-commit-err:string ) )
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `new-rev` | number | 新创建的修订版本号 |
| `date` | string (UTF-8) | 提交时间（ISO 8601 格式） |
| `author` | string (UTF-8) | 提交者用户名 |
| `post-commit-err` | string (UTF-8) | 提交后钩子脚本的错误信息（可选） |

---

### 9. `get-file` — 获取文件内容和属性

```
params:   ( path:string [ rev:number ] want-props:bool want-contents:bool
            ? want-iprops:bool )
response: ( [ checksum:string ] rev:number props:proplist
            [ inherited-props:iproplist ] )
```

**作用**：获取指定文件的内容、显式属性和/或继承属性。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 文件相对路径（相对于会话 fs_path） |
| `rev` | number | 否 | 目标修订版本号；省略时使用 HEAD |
| `want-props` | bool | 是 | `true` = 需要返回文件属性 |
| `want-contents` | bool | 是 | `true` = 需要返回文件内容 |
| `want-iprops` | bool | 否 | `true` = 需要返回继承属性；默认为 `false` |

**服务端处理**：解析格式串 `"c(?r)bb?B"`。

**响应**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `checksum` | string (ASCII) | 文件的 MD5 校验和（十六进制）；文件不存在时省略 |
| `rev` | number | 实际使用的修订版本号 |
| `props` | proplist | 文件属性列表 |
| `inherited-props` | iproplist | 继承属性列表（可选） |

**iproplist 格式**：
```
( ( path-or-url:string ( ( name:string value:string ) ... ) ) ... )
```

**文件内容传输**：如果 `want-contents = true`，服务端在发送响应之后，以一系列 `string` 传输文件内容，以**空字符串** `""` 终止，然后再发送一个空的 command-response 指示传输过程中是否有错误。

---

### 10. `get-dir` — 获取目录内容和属性

```
params:   ( path:string [ rev:number ] want-props:bool want-contents:bool
            ? ( field:dirent-field ... ) ? want-iprops:bool )
response: ( rev:number props:proplist ( entry:dirent ... )
            [ inherited-props:iproplist ] )
```

**作用**：获取指定目录的属性、子条目（含选择性字段）和/或继承属性。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 目录相对路径 |
| `rev` | number | 否 | 目标修订版本号；省略时使用 HEAD |
| `want-props` | bool | 是 | 是否需要目录属性 |
| `want-contents` | bool | 是 | 是否需要目录条目列表 |
| `dirent-fields` | list of word | 否 | 请求的条目字段列表；省略时返回所有字段 |
| `want-iprops` | bool | 否 | 是否需要继承属性；默认为 `false` |

**服务端处理**：解析格式串 `"c(?r)bb?l?B"`。

**dirent-field 可选值**：

| 字段名 | 说明 |
|--------|------|
| `kind` | 节点类型（file/dir） |
| `size` | 文件大小（字节） |
| `has-props` | 是否有属性 |
| `created-rev` | 最后修改的修订版本号 |
| `time` | 最后修改时间 |
| `last-author` | 最后修改者 |

**dirent 格式**（每个条目）：
```
( name:string kind:node-kind size:number has-props:bool
  created-rev:number [ created-date:string ] [ last-author:string ] )
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | string (UTF-8) | 条目名称（不含路径前缀） |
| `kind` | word | `file`、`dir` 或 `unknown` |
| `size` | number | 文件大小（字节），目录为 0 |
| `has-props` | bool | 节点是否有自定义属性 |
| `created-rev` | number | 最后修改的修订版本号 |
| `created-date` | string (UTF-8) | 最后修改时间（可选） |
| `last-author` | string (UTF-8) | 最后修改者（可选） |

---

### 11. `check-path` — 检查路径是否存在

```
params:   ( path:string [ rev:number ] )
response: ( kind:node-kind )
```

**作用**：检查指定路径在给定版本中的节点类型。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 相对路径 |
| `rev` | number | 否 | 修订版本号；省略时使用 HEAD |

**服务端处理**：解析格式串 `"c(?r)"`。

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `kind` | word | `none`（不存在）、`file`（文件）、`dir`（目录）或 `unknown` |

---

### 12. `stat` — 获取路径统计信息

```
params:   ( path:string [ rev:number ] )
response: ( ? entry:dirent )
```

**作用**：获取指定路径的详细信息（类似 Unix `stat` 命令）。如果路径不存在，返回空响应。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 相对路径 |
| `rev` | number | 否 | 修订版本号；省略时使用 HEAD |

**服务端处理**：解析格式串 `"c(?r)"`。

**dirent 格式**（存在时）：
```
( kind:word size:number has-props:bool created-rev:number
  [ created-date:string ] [ last-author:string ] )
```

**新增于**：Subversion 1.2。

---

### 13. `get-mergeinfo` — 获取合并信息

```
params:   ( ( path:string ... ) [ rev:number ] inherit:word descendants:bool )
response: ( ( ( path:string merge-info:string ) ... ) )
```

**作用**：查询指定路径的合并信息（mergeinfo），需要服务端具有 `mergeinfo` 能力。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `paths` | list of string | 是 | 路径列表（UTF-8 相对路径） |
| `rev` | number | 否 | 修订版本号；省略时使用 HEAD |
| `inherit` | word | 是 | 继承方式：`nearest`（最近祖先）、`explicit`（仅显式）、`explicit-or-inherited`（显式或继承） |
| `descendants` | bool | 是 | `true` = 同时查询后代路径的合并信息 |

**服务端处理**：解析格式串 `"l(?r)wb"`。

**响应**：包含若干 `( path:string merge-info:string )` 对的列表。如果路径列表为空，返回空响应。

**新增于**：Subversion 1.5。

---

### 14. `update` — 更新工作副本

```
params:   ( [ rev:number ] target:string recurse:bool
            ? depth:word ? send_copyfrom_args:bool ? ignore_ancestry:bool )
response: ( )
```

**作用**：将工作副本更新到指定版本。客户端发送此命令后**切换到报告命令集**，通过 `set-path`、`link-path`、`delete-path` 等命令描述工作副本的当前状态，然后用 `finish-report` 结束报告。服务端收到 `finish-report` 后，**切换到编辑器命令集**，驱动编辑器描述从当前状态到目标版本的差异。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 否 | 目标版本；省略时使用 HEAD |
| `target` | string (UTF-8) | 是 | 更新目标路径（相对于会话根路径），通常是空字符串 `""` 表示整个工作副本 |
| `recurse` | bool | 是 | `true` = 递归更新（对应 depth=infinity）；`false` = 仅当前目录（depth=files）；如果提供了 `depth` 则此参数被覆盖 |
| `depth` | word | 否 | 操作深度：`empty`、`files`、`immediates`、`infinity`、`unknown` |
| `send_copyfrom_args` | bool | 否 | `true` = 编辑器在 add-dir/add-file 时发送 copyfrom 参数；服务端按 tristate 解析，未发送时默认 unknown |
| `ignore_ancestry` | bool | 否 | `true` = 忽略节点祖先关系，按全量差异处理；服务端按 tristate 解析，未发送时默认 unknown（等同于 `false`） |

**服务端处理**：解析格式串 `"(?r)cb?w3?3"`（`3` 表示 tristate：true/false/unspecified）。

**执行流程**：
```
客户端发送 update ──► 客户端进入报告命令集
                   ──► set-path / link-path / delete-path ...
                   ──► finish-report
                   ──► 服务端 auth-request
                   ──► 服务端进入编辑器命令集（驱动编辑）
                   ──► 编辑完成
                   ──► 服务端发送 ( success ( ) )
```

---

### 15. `switch` — 切换工作副本 URL

```
params:   ( [ rev:number ] target:string recurse:bool url:string
            ? depth:word ? send_copyfrom_args:bool ignore_ancestry:bool )
response: ( )
```

**作用**：将工作副本切换到另一个 URL（分支/标签），同时更新内容。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 否 | 目标版本；省略时使用 HEAD |
| `target` | string (UTF-8) | 是 | 工作副本中的目标路径 |
| `recurse` | bool | 是 | 是否递归 |
| `url` | string (UTF-8) | 是 | 切换目标的完整 URL |
| `depth` | word | 否 | 操作深度 |
| `send_copyfrom_args` | bool | 否 | 是否发送 copyfrom 信息；服务端按 tristate 解析，未发送时默认 unknown |
| `ignore_ancestry` | bool | 否 | 是否忽略祖先关系；服务端按 tristate 解析，未发送时默认 unknown（等同于 `true`） |

**服务端处理**：解析格式串 `"(?r)cbc?w?33"`。

**执行流程**：与 `update` 相同（报告命令集 → 编辑器命令集）。

---

### 16. `status` — 检查工作副本状态

```
params:   ( target:string recurse:bool ? [ rev:number ] ? depth:word )
response: ( )
```

**作用**：检查工作副本与仓库之间的差异（哪些文件被修改、添加、删除等）。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `target` | string (UTF-8) | 是 | 目标路径 |
| `recurse` | bool | 是 | 是否递归 |
| `rev` | number | 否 | 对比版本；省略时使用 HEAD |
| `depth` | word | 否 | 操作深度 |

**服务端处理**：解析格式串 `"cb?(?r)?w"`。

**执行流程**：与 `update` 相同。

---

### 17. `diff` — 比较两个版本

```
params:   ( [ rev:number ] target:string recurse:bool ignore-ancestry:bool
            url:string ? text-deltas:bool ? depth:word )
response: ( )
```

**作用**：生成两个版本之间的差异报告（用于 `svn diff`）。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 否 | 比较的目标版本；省略时使用 HEAD |
| `target` | string (UTF-8) | 是 | 工作副本中的目标路径 |
| `recurse` | bool | 是 | 是否递归 |
| `ignore-ancestry` | bool | 是 | `true` = 忽略节点祖先关系 |
| `url` | string (UTF-8) | 是 | 比较基准的完整 URL（"from" URL） |
| `text-deltas` | bool | 否 | `true` = 编辑器中发送文本差异；1.4 之前客户端不发送，默认为 `true` |
| `depth` | word | 否 | 操作深度 |

**服务端处理**：先检查参数个数，5个参数时使用 `"(?r)cbbc"` 格式（1.4 之前的旧客户端，不含 text-deltas 和 depth），否则使用 `"(?r)cbbcb?w"` 格式。

**执行流程**：与 `update` 相同。

---

### 18. `log` — 获取日志

```
params:   ( ( target-path:string ... ) [ start-rev:number ]
            [ end-rev:number ] changed-paths:bool strict-node:bool
            ? limit:number
            ? include-merged-revisions:bool
            all-revprops | revprops ( revprop:string ... ) )
response: ( )
```

**作用**：获取修订版本的日志信息，支持多路径过滤、分页、合并历史等。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `target-paths` | list of string | 是 | 要查询日志的路径列表（UTF-8 相对路径） |
| `start-rev` | number | 否 | 查询范围的起始版本；省略时使用 HEAD |
| `end-rev` | number | 否 | 查询范围的结束版本；省略时使用版本 1 |
| `changed-paths` | bool | 是 | `true` = 返回每个版本修改的路径列表 |
| `strict-node` | bool | 是 | `true` = 严格限定在指定路径的变更 |
| `limit` | number | 否 | 返回的最大日志条数；`0` 表示不限制 |
| `include-merged-revisions` | bool | 否 | `true` = 包含合并带入的版本 |
| `revprop-word` | word | 是 | `all-revprops`（返回所有属性）或 `revprops`（指定属性列表） |
| `revprop-items` | list of string | 条件 | 当 `revprop-word = revprops` 时，指定要返回的属性名列表 |

**服务端处理**：解析格式串 `"l(?r)(?r)bb?n?Bwl"`。

**日志传输**：服务端在发送最终响应之前，逐条发送 `log-entry`，最后发送 `done`。

**log-entry 格式**：
```
( ( change:changed-path-entry ... ) rev:number
  [ author:string ] [ date:string ] [ message:string ]
  ? has-children:bool invalid-revnum:bool
  revprop-count:number rev-props:proplist
  ? subtractive-merge:bool )
| done
```

**changed-path-entry 格式**：
```
( path:string A|D|R|M
  ? ( ? copy-path:string copy-rev:number )
  ? ( ? node-kind:string ? text-mods:bool prop-mods:bool ) )
```

| 字段 | 说明 |
|------|------|
| `path` | 变更路径 |
| `A/D/R/M` | 操作类型：A=添加, D=删除, R=替换, M=修改 |
| `copy-path` | 复制来源路径（仅复制操作） |
| `copy-rev` | 复制来源版本（仅复制操作） |
| `node-kind` | 节点类型：`file` 或 `dir` |
| `text-mods` | 文件内容是否被修改 |
| `prop-mods` | 属性是否被修改 |

---

### 19. `get-locations` — 追踪节点历史位置

```
params:   ( path:string peg-rev:number ( rev:number ... ) )
response: ( )
```

**作用**：追踪一个节点在多个版本中的绝对路径（用于处理重命名/移动后的历史追溯）。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 节点在 `peg-rev` 时的相对路径 |
| `peg-rev` | number | 是 | 锚定版本（peg revision） |
| `revisions` | list of number | 是 | 要查询的版本列表 |

**服务端处理**：解析格式串 `"crl"`。

**位置传输**：逐条发送 `location-entry`，最后发送 `done`。

**location-entry 格式**：
```
( rev:number abs-path:string ) | done
```

---

### 20. `get-location-segments` — 获取节点历史段

```
params:   ( path:string [ peg-rev:number ] [ start-rev:number ] [ end-rev:number ] )
response: ( )
```

**作用**：获取节点在版本范围内的所有历史路径段（每一段是一个连续的路径+版本范围）。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 相对路径 |
| `peg-rev` | number | 否 | 锚定版本；省略时使用 HEAD |
| `start-rev` | number | 否 | 起始版本；省略时使用 HEAD |
| `end-rev` | number | 否 | 结束版本；省略时使用版本 0 |

**服务端处理**：解析格式串 `"c(?r)(?r)(?r)"`。约束：`end-rev ≤ start-rev ≤ peg-rev`。

**段传输**：逐条发送 `location-entry`，最后发送 `done`。

**location-entry 格式**：
```
( range-start:number range-end:number [ abs-path:string ] ) | done
```

---

### 21. `get-file-revs` — 获取文件逐版本差异

```
params:   ( path:string [ start-rev:number ] [ end-rev:number ]
            ? include-merged-revisions:bool )
response: ( )
```

**作用**：获取文件在每个版本中的变更（修订属性 + 属性差异 + 文本差异），用于 `svn blame` 等操作。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 文件相对路径 |
| `start-rev` | number | 否 | 起始版本；省略时使用 HEAD |
| `end-rev` | number | 否 | 结束版本；省略时使用版本 1 |
| `include-merged-revisions` | bool | 否 | 是否包含合并带入的版本 |

**服务端处理**：解析格式串 `"c(?r)(?r)?B"`。

**逐版本传输**：每个版本发送一个 `file-rev` 条目，最后发送 `done`。

**file-rev 格式**：
```
( path:string rev:number rev-props:proplist
  file-props:propdelta ? merged-revision:bool )
| done
```

**propdelta 格式**（属性差异）：
```
( ( name:string [ value:string ] ) ... )
```
- 如果 `value` 存在，表示属性被修改为该值
- 如果 `value` 不存在（空元组），表示属性被删除

**文本差异**：每个 `file-rev` 之后，服务端以一系列 `string` 发送 svndiff 编码的文本差异，以空字符串终止。如果该版本没有文本修改，仅发送空字符串终止符。

---

### 22. `lock` — 锁定文件

```
params:   ( path:string [ comment:string ] steal-lock:bool
            [ current-rev:number ] )
response: ( lock:lockdesc )
```

**作用**：对单个文件加锁。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 文件相对路径 |
| `comment` | string (UTF-8) | 否 | 锁注释 |
| `steal-lock` | bool | 是 | `true` = 强制夺取已有的锁 |
| `current-rev` | number | 否 | 当前已知版本，用于验证 |

**服务端处理**：解析格式串 `"c(?c)b(?r)"`。

**lockdesc 格式**：
```
( path:string token:string owner:string [ comment:string ]
  created:string [ expires:string ] )
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `path` | string (UTF-8) | 锁定文件的仓库路径 |
| `token` | string (UTF-8) | 锁令牌（唯一标识符） |
| `owner` | string (UTF-8) | 锁持有者用户名 |
| `comment` | string (UTF-8) | 锁注释（可选） |
| `created` | string (UTF-8) | 创建时间（ISO 8601） |
| `expires` | string (UTF-8) | 过期时间（可选，ISO 8601） |

---

### 23. `lock-many` — 批量锁定文件

```
params:   ( [ comment:string ] steal-lock:bool ( ( path:string
            [ current-rev:number ] ) ... ) )
response: ( )
```

**作用**：对多个文件批量加锁。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `comment` | string (UTF-8) | 否 | 所有锁的统一注释 |
| `steal-lock` | bool | 是 | 是否强制夺取已有的锁 |
| `path-revs` | list | 是 | 锁请求列表，每个元素为 `( path:string [ current-rev:number ] )` |

**服务端处理**：解析格式串 `"(?c)bl"`。

**逐个结果传输**：服务端对每个路径发送 `lock-info`，最后发送 `done`。

**lock-info 格式**：
```
( success ( lock:lockdesc ) ) | ( failure ( err:error ) ) | done
```

---

### 24. `unlock` — 解锁文件

```
params:   ( path:string [ token:string ] break-lock:bool )
response: ( )
```

**作用**：解除单个文件的锁。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 文件相对路径 |
| `token` | string (UTF-8) | 否 | 锁令牌；如果 `break-lock = true` 可省略 |
| `break-lock` | bool | 是 | `true` = 强制解除他人的锁（需要管理员权限） |

**服务端处理**：解析格式串 `"c(?c)b"`。

---

### 25. `unlock-many` — 批量解锁文件

```
params:   ( break-lock:bool ( ( path:string [ token:string ] ) ... ) )
response: ( )
```

**作用**：对多个文件批量解锁。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `break-lock` | bool | 是 | 是否强制解除他人的锁 |
| `unlock-tokens` | list | 是 | 解锁请求列表，每个元素为 `( path:string [ token:string ] )` |

**服务端处理**：解析格式串 `"bl"`。

**逐个结果传输**：对每个路径发送 `pre-response`，最后发送 `done`。

**pre-response 格式**：
```
( success ( path:string ) ) | ( failure ( err:error ) ) | done
```

---

### 26. `get-lock` — 获取单个文件的锁信息

```
params:   ( path:string )
response: ( [ lock:lockdesc ] )
```

**作用**：查询指定文件当前的锁信息。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 文件相对路径 |

**服务端处理**：解析格式串 `"c"`。

**响应**：如果文件有锁，返回 `lockdesc`；如果无锁，返回空元组 `()`。

---

### 27. `get-locks` — 获取目录下的所有锁

```
params:   ( path:string ? [ depth:word ] )
response: ( ( lock:lockdesc ... ) )
```

**作用**：获取指定路径下（含子路径）的所有锁信息。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 目录相对路径 |
| `depth` | word | 否 | 搜索深度：`empty`（仅当前）、`files`（直接子文件）、`immediates`、`infinity`（递归）；默认为 `infinity` |

**服务端处理**：解析格式串 `"c?(?w)"`。

**响应**：锁描述列表。

---

### 28. `replay` — 重放单个修订版本

```
params:   ( revision:number low-water-mark:number send-deltas:bool )
response: ( )
```

**作用**：重放指定修订版本的所有变更（用于 `svnsync` 镜像同步）。服务端**切换到编辑器命令集**驱动编辑操作。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `revision` | number | 是 | 要重放的修订版本号 |
| `low-water-mark` | number | 是 | 低水位标记——低于此版本的节点差异可以省略（仅发送最终状态） |
| `send-deltas` | bool | 是 | `true` = 发送完整的文本/属性差异；`false` = 仅发送节点结构变更 |

**服务端处理**：解析格式串 `"rrb"`。

**执行流程**：
```
客户端发送 replay ──► auth-request
                   ──► 服务端驱动编辑器命令集
                   ──► 编辑完成
                   ──► 服务端发送 finish-replay
                   ──► 服务端发送 ( success ( ) )
```

> **`finish-replay`** 是编辑器命令集中的特殊命令，仅在 replay 场景中由服务端发送给客户端，标志一次 replay 编辑完成。

---

### 29. `replay-range` — 批量重放版本范围

```
params:   ( start-rev:number end-rev:number low-water-mark:number
            send-deltas:bool )
response: ( )
```

**作用**：批量重放一个版本范围内的所有修订版本（用于 `svnsync` 高效同步多个版本）。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `start-rev` | number | 是 | 范围起始版本 |
| `end-rev` | number | 是 | 范围结束版本 |
| `low-water-mark` | number | 是 | 低水位标记 |
| `send-deltas` | bool | 是 | 是否发送文本差异 |

**服务端处理**：解析格式串 `"rrrb"`。

**执行流程**：对 `start-rev` 到 `end-rev` 的每个版本：
1. 发送 `( revprops ( props:proplist ) )` — 该版本的修订属性
2. 驱动编辑器命令集重放该版本
3. 发送 `finish-replay`

所有版本完成后发送 `( success ( ) )`。

---

### 30. `get-deleted-rev` — 查找路径被删除的版本

```
params:   ( path:string peg-rev:number end-rev:number )
response: ( deleted-rev:number )
```

**作用**：在版本范围 `[peg-rev, end-rev]` 内查找指定路径被删除的版本号。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 相对路径 |
| `peg-rev` | number | 是 | 起始版本 |
| `end-rev` | number | 是 | 结束版本 |

**服务端处理**：解析格式串 `"crr"`。

**响应**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `deleted-rev` | number | 路径被删除的版本号 |

**特殊情况**：如果路径在范围内未被删除，服务端返回 `SVN_ERR_ENTRY_MISSING_REVISION` 错误（新客户端将其理解为"未删除"）。

---

### 31. `get-iprops` — 获取继承属性

```
params:   ( path:string [ rev:number ] )
response: ( inherited-props:iproplist )
```

**作用**：获取指定路径从祖先路径继承的所有属性。需要服务端具有 `inherited-props` 能力。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 相对路径 |
| `rev` | number | 否 | 修订版本号；省略时使用 HEAD |

**服务端处理**：解析格式串 `"c(?r)"`。

**iproplist 格式**：
```
( ( path-or-url:string ( ( name:string value:string ) ... ) ) ... )
```

每个元素包含一个祖先路径及其在该路径上设置的属性列表。

**新增于**：Subversion 1.8。

---

### 32. `list` — 列出目录内容

```
params:   ( path:string [ rev:number ] depth:word
            ( field:dirent-field ... ) ? ( pattern:string ... ) )
response: ( )
```

**作用**：按指定深度和过滤模式列出目录内容，返回每个条目的路径和选择性字段。比 `get-dir` 更灵活，支持深度控制和名称过滤。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string (UTF-8) | 是 | 目录相对路径 |
| `rev` | number | 否 | 修订版本号；省略时使用 HEAD |
| `depth` | word | 是 | 遍历深度：`empty`、`files`、`immediates`、`infinity` |
| `dirent-fields` | list of word | 是 | 要返回的字段列表（同 `get-dir` 中的 dirent-field） |
| `patterns` | list of string | 否 | 文件名过滤模式列表（glob 模式） |

**服务端处理**：解析格式串 `"c(?r)w?l?l"`。

**条目传输**：逐条发送 `dirent`，最后发送 `done`。

**dirent 格式**：
```
( rel-path:string kind:node-kind
  ? [ size:number ] [ has-props:bool ] [ created-rev:number ]
    [ created-date:string ] [ last-author:string ] )
| done
```

> **与 `get-dir` 的区别**：`list` 返回的每个条目包含 `rel-path`（相对于查询路径的路径），而 `get-dir` 返回的条目仅包含 `name`（条目名）。

**新增于**：Subversion 1.10。需要服务端具有 `list` 能力。

---

## 命令分类汇总

### 版本查询类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `get-latest-rev` | 获取 HEAD 版本 | 直接响应 |
| `get-dated-rev` | 按日期查找版本 | 直接响应 |
| `get-deleted-rev` | 查找删除版本 | 直接响应 |

### 属性操作类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `rev-proplist` | 列出修订所有属性 | 直接响应 |
| `rev-prop` | 获取单个修订属性 | 直接响应 |
| `change-rev-prop` | 修改修订属性 | 直接响应 |
| `change-rev-prop2` | 原子修改修订属性 | 直接响应 |
| `get-iprops` | 获取继承属性 | 直接响应 |

### 节点查询类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `check-path` | 检查节点类型 | 直接响应 |
| `stat` | 获取节点详情 | 直接响应 |
| `get-file` | 获取文件内容和属性 | 响应 + 流式内容 |
| `get-dir` | 获取目录内容和属性 | 直接响应 |
| `list` | 灵活列出目录 | 流式条目 + done |
| `get-mergeinfo` | 获取合并信息 | 直接响应 |

### 历史追溯类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `log` | 获取日志 | 流式条目 + done |
| `get-locations` | 追踪节点位置 | 流式条目 + done |
| `get-location-segments` | 获取历史段 | 流式条目 + done |
| `get-file-revs` | 获取文件逐版本差异 | 流式条目 + done |

### 编辑操作类（切换命令集）

| 命令 | 作用 | 切换目标 |
|------|------|----------|
| `commit` | 提交 | → 编辑器命令集 |
| `update` | 更新 | → 报告命令集 → 编辑器命令集 |
| `switch` | 切换 URL | → 报告命令集 → 编辑器命令集 |
| `status` | 检查状态 | → 报告命令集 → 编辑器命令集 |
| `diff` | 差异比较 | → 报告命令集 → 编辑器命令集 |
| `replay` | 重放版本 | → 编辑器命令集 |
| `replay-range` | 批量重放 | → 编辑器命令集（多次） |

### 锁管理类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `lock` | 锁定文件 | 返回 lockdesc |
| `lock-many` | 批量锁定 | 流式结果 + done |
| `unlock` | 解锁文件 | 直接响应 |
| `unlock-many` | 批量解锁 | 流式结果 + done |
| `get-lock` | 查询单个锁 | 直接响应 |
| `get-locks` | 查询所有锁 | 直接响应 |

### 会话管理类

| 命令 | 作用 | 响应方式 |
|------|------|----------|
| `reparent` | 切换会话路径 | 直接响应 |
