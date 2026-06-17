# svn:// 协议 - 编辑器命令集详解

## 概述

编辑器命令集（Editor Command Set）是 `svn://` 协议中最核心的部分，用于在客户端和服务器之间传输**增量编辑操作**。它实现了一套完整的树形结构操作协议，可以描述对仓库目录树的任意修改。

### 使用场景

| 操作 | 驱动方 | 消费方 |
|------|--------|--------|
| **commit（提交）** | 客户端 | 服务端 |
| **update（更新）** | 服务端 | 客户端 |
| **checkout（检出）** | 服务端 | 客户端 |
| **switch（切换）** | 服务端 | 客户端 |
| **diff（差异）** | 服务端 | 客户端 |
| **status（状态）** | 服务端 | 客户端 |
| **replay（回放）** | 服务端 | 客户端 |

### 核心设计原则

1. **无逐条响应**：编辑器命令不返回逐条响应（仅 `close-edit` 和 `abort-edit` 有响应），这避免了每个操作都产生一次网络往返延迟。
2. **提前错误报告**：消费方可以在编辑过程中**任意时刻**发送一个 `failure` 响应来提前终止编辑。驱动方必须定期检查连接上是否有等待的数据（即错误报告），如果发现则发送 `abort-edit` 终止编辑。
3. **TCP 死锁防护**：消费方发送错误时使用非阻塞 I/O。如果写入被阻塞（因为驱动方还在发送数据），消费方必须继续读取并丢弃编辑命令，直到写入解除阻塞或读到 `abort-edit`。
4. **Token 引用机制**：每个打开的目录/文件通过唯一 token 引用，避免重复传输完整路径。

---

## Token 机制详解

Token 是编辑器命令集的核心概念。每当通过 `open-root`、`add-dir`、`open-dir`、`add-file`、`open-file` 创建或打开一个节点时，都会生成一个唯一 token。后续所有对该节点的操作都通过这个 token 来引用，而不是通过路径。

### Token 生成规则

Token 是一个字符串，格式为：`类型前缀 + 递增序号`

- 目录 token：`d0`、`d1`、`d2` ...
- 文件 token：`c0`、`c1`、`c2` ...

序号从一个从 0 开始递增的计数器（`next_token`）产生，确保唯一性。

### Token 的生命周期

```
创建（open-root / add-dir / open-dir / add-file / open-file）
  → 使用（change-*-prop / delete-entry / add-* / open-* / apply-textdelta 等）
    → 销毁（close-dir / close-file）
```

消费方维护一个 token → baton 的哈希表。创建时注册，关闭时移除。

---

## 协议 String 参数的实际数据类型

在协议层面，`string` 类型的定义是 `1*DIGIT ":" *OCTET space`，理论上可以携带任意字节。但在 Subversion 的 C API 中，参数严格区分为两种类型：

| C 类型 | 含义 | 协议编码 |
|--------|------|----------|
| `const char *` | NUL 终止的 C 字符串，**UTF-8 文本** | `length:content ` |
| `const svn_string_t *` | 带长度的字节串（`data` + `len`），**任意二进制** | `length:content ` |

两者的协议编码格式相同（都是 `长度:内容`），但语义不同。实现时必须按正确的类型处理。

### 所有 string 参数的类型分类

#### UTF-8 文本（`const char *`）

这些参数是 NUL 终止的 UTF-8 字符串，不包含嵌入式 NUL 字节：

| 命令 | 参数 | 说明 |
|------|------|------|
| `delete-entry` | `path` | 要删除的条目路径（如 `trunk/old-file.txt`） |
| `add-dir` | `path` | 新目录的路径 |
| `add-dir` | `copy-path` | 复制来源路径（URL 或 fspath） |
| `open-dir` | `path` | 已存在目录的路径 |
| `add-file` | `path` | 新文件的路径 |
| `add-file` | `copy-path` | 复制来源路径（URL 或 fspath） |
| `open-file` | `path` | 已存在文件的路径 |
| `absent-dir` | `path` | 缺失目录的路径 |
| `absent-file` | `path` | 缺失文件的路径 |
| `change-dir-prop` | `name` | 属性名称（如 `svn:ignore`、`svn:mergeinfo`） |
| `change-file-prop` | `name` | 属性名称（如 `svn:executable`、`svn:eol-style`） |
| `apply-textdelta` | `base-checksum` | MD5 校验和的十六进制表示（32 个 ASCII 字符） |
| `close-file` | `text-checksum` | MD5 校验和的十六进制表示（32 个 ASCII 字符） |

#### 任意二进制（`const svn_string_t *`）

这些参数可以包含任意字节，包括 NUL 字节和非 UTF-8 数据：

| 命令 | 参数 | 说明 |
|------|------|------|
| `change-dir-prop` | `value` | 目录属性值。某些属性（如 `svn:mergeinfo`）是 UTF-8 文本，但自定义属性可能是二进制数据 |
| `change-file-prop` | `value` | 文件属性值。同上，可能是 UTF-8 也可能是二进制 |
| `textdelta-chunk` | `chunk` | svndiff 编码的差异数据块，纯二进制格式 |

#### 不透明标识符（`const char *`，但非语义文本）

Token 参数虽然类型是 `const char *`，但它们是不透明的标识符，不是有意义的文本路径：

| 命令 | 参数 | 说明 |
|------|------|------|
| `open-root` | `root-token` | 根目录 token（如 `d0`） |
| `add-dir` | `parent-token`、`child-token` | 父目录和新目录的 token |
| `open-dir` | `parent-token`、`child-token` | 父目录和已打开目录的 token |
| `close-dir` | `dir-token` | 要关闭的目录 token |
| `delete-entry` | `dir-token` | 父目录 token |
| `change-dir-prop` | `dir-token` | 目标目录 token |
| `absent-dir` | `parent-token` | 父目录 token |
| `add-file` | `dir-token`、`file-token` | 父目录 token 和新文件 token |
| `open-file` | `dir-token`、`file-token` | 父目录 token 和文件 token |
| `close-file` | `file-token` | 要关闭的文件 token |
| `apply-textdelta` | `file-token` | 目标文件 token |
| `textdelta-chunk` | `file-token` | 目标文件 token |
| `textdelta-end` | `file-token` | 目标文件 token |
| `change-file-prop` | `file-token` | 目标文件 token |
| `absent-file` | `parent-token` | 父目录 token |

### 关键注意事项

1. **属性值的二义性**：`change-dir-prop` 和 `change-file-prop` 的 `value` 参数在协议中是 `svn_string_t`（二进制），但实际内容取决于属性类型：
   - `svn:log`、`svn:author`、`svn:date` 等标准属性 → UTF-8 文本
   - `svn:mergeinfo` → UTF-8 文本（有特定格式）
   - `svn:executable` → 值固定为 `*`（ASCII）
   - 自定义属性（无 `svn:` 前缀）→ 可能是任意二进制数据

2. **路径编码**：所有路径参数都是 UTF-8 编码的相对路径（相对于编辑根目录），使用 `/` 作为路径分隔符。即使在不使用 `/` 的操作系统（如 Windows）上，协议中也统一使用 `/`。

3. **校验和格式**：`base-checksum` 和 `text-checksum` 虽然是 ASCII 文本（MD5 的十六进制表示），但它们在 C API 中的类型是 `const char *`，不是 `svn_string_t`。

4. **svndiff 数据**：`textdelta-chunk` 的 `chunk` 参数是唯一确定为纯二进制的参数，它使用 svndiff 格式编码，包含压缩后的差异数据。

---

## 命令详解

### 1. `target-rev` - 设置目标修订版本

```
( target-rev ( rev:number ) )
```

**作用**：通知消费方本次编辑操作的目标修订版本号。这是编辑会话中可选的第一步，通常在 update/switch 操作中使用，告诉消费方："我要把你的工作副本更新到哪个版本"。

**参数说明**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `rev` | number | 目标修订版本号。即编辑完成后，工作副本应该对应的版本号。 |

**示例**：
```
( target-rev ( 42 ) )
```
表示本次编辑要将工作副本更新到修订版本 42。

**调用时机**：必须在 `open-root` 之前调用（如果调用的话）。

---

### 2. `open-root` - 打开编辑根目录

```
( open-root ( [rev:number] ) root-token:string )
```

**作用**：开始一次编辑操作，打开目录树的根节点。这是每次编辑会话中**必须**调用的第一个实质性命令。它创建了编辑的"锚点"，后续所有目录和文件操作都从这个根开始。

**线上格式说明**：`rev` 是可选参数，包在内层子元组 `(...)` 中；`root-token` 在子元组外面。格式串为 `(?r)s`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `rev` | number | 否 | 基准修订版本号。表示"我要修改的这个目录树是基于哪个版本的"。对于 commit 操作，这是工作副本的基准版本；对于 update 操作，这是当前工作副本的版本。如果不指定，子元组为空 `()`。 |
| `root-token` | string | 是 | 根目录的唯一标识符。由驱动方生成，后续所有对根目录的操作（如添加子节点、修改属性、关闭目录）都通过这个 token 引用。通常格式为 `d0`。 |

**示例**：
```
( open-root ( ( 42 ) d0 ) )
```
以修订版本 42 为基准打开根目录，分配 token `d0`。

```
( open-root ( ( ) d0 ) )
```
不指定基准版本打开根目录（子元组为空）。

**副作用**：消费方会创建一个与根目录关联的 baton 对象，并将 `root-token` 注册到 token 哈希表中。

---

### 3. `delete-entry` - 删除条目

```
( delete-entry ( path:string ( [rev:number] ) dir-token:string ) )
```

**作用**：从指定目录中删除一个条目（可以是文件或子目录）。这用于表达"在目标版本中，这个路径应该不存在"。

**线上格式说明**：`path`、`( [rev] )`、`dir-token` 都在内层元组中。`rev` 是可选参数，包在子元组 `(...)` 中。格式串为 `c(?r)s`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 要删除的条目的**相对路径**（相对于编辑根目录或仓库根）。是目录名或文件名，如 `trunk/old-file.txt`。 |
| `rev` | number | 否 | 用于验证的修订版本号。表示"在我看到的版本中，这个条目存在于版本 rev"。消费方可以用它来检测冲突。如果不指定，子元组为空 `()`。 |
| `dir-token` | string | 是 | 父目录的 token。指明从哪个目录中删除条目。必须是之前通过 `open-root`、`add-dir` 或 `open-dir` 创建的有效目录 token。 |

**示例**：
```
( delete-entry ( trunk/old-dir ( 42 ) d0 ) )
```
从 token 为 `d0` 的目录中删除名为 `trunk/old-dir` 的条目，声称该条目在版本 42 中存在。

---

### 4. `add-dir` - 添加新目录

```
( add-dir ( path:string parent-token:string child-token:string [copy-path:string copy-rev:number] ) )
```

**作用**：在指定父目录下创建一个新的子目录。这表示"在这个父目录下新增了一个子目录"。

**线上格式说明**：`copy-path` 和 `copy-rev` 是可选参数，一起包在内层子元组 `(...)` 中。格式串为 `css(?cr)`。没有复制来源时子元组为空 `()`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 新目录的**相对路径**。如 `trunk/new-dir`。 |
| `parent-token` | string | 是 | 父目录的 token。新目录将作为该父目录的子节点创建。 |
| `child-token` | string | 是 | 新目录的唯一标识符。由驱动方生成，后续用于引用这个新目录。通常格式为 `d1`、`d2` 等。 |
| `copy-path` | string | 否 | 复制来源路径。如果这个新目录是从仓库中其他位置复制过来的（即 `svn copy` 操作），这里指定来源路径（URL 或 fspath）。如果存在 `copy-path`，则必须同时指定 `copy-rev`。 |
| `copy-rev` | number | 否 | 复制来源修订版本号。表示从 `copy-path` 的哪个版本复制。只有当 `copy-path` 存在时才有意义。 |

**示例**：
```
( add-dir ( trunk/new-branch d0 d1 ( ) ) )
```
在 `d0`（父目录）下新建目录 `trunk/new-branch`，新目录 token 为 `d1`，无复制来源。

```
( add-dir ( trunk/feature d0 d2 ( svn://server/repos/trunk 42 ) ) )
```
在 `d0` 下新建目录 `trunk/feature`，内容来自仓库 `svn://server/repos/trunk` 的版本 42（即复制/分支操作），新目录 token 为 `d2`。

**约束**：`copy-path` 和 `copy-rev` 必须同时出现或同时不出现（都在同一个子元组内）。

---

### 5. `open-dir` - 打开已有目录

```
( open-dir ( path:string parent-token:string child-token:string [rev:number] ) )
```

**作用**：打开一个已经存在于仓库中的目录，以便对其内容进行修改（添加/删除子节点、修改属性等）。与 `add-dir` 不同，`open-dir` 表示这个目录本身不是新增的，只是需要对其内容进行编辑。

**线上格式说明**：`rev` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `css(?r)`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 目录的**相对路径**。 |
| `parent-token` | string | 是 | 父目录的 token。 |
| `child-token` | string | 是 | 这个已打开目录的新 token。由驱动方分配，后续引用此目录时使用。 |
| `rev` | number | 否 | 基准修订版本号。表示"我打开的这个目录是基于版本 rev 的状态"。消费方据此判断后续操作是否有冲突。如果不指定，子元组为空 `()`。 |

**示例**：
```
( open-dir ( trunk/src d0 d1 ( 42 ) ) )
```
在 `d0`（父目录）下打开已存在的目录 `trunk/src`，基于版本 42，分配 token `d1`。

**`add-dir` vs `open-dir` 的区别**：
- `add-dir`：目录是新创建的，仓库中之前不存在
- `open-dir`：目录已存在于仓库中，只是要修改其内容

---

### 6. `change-dir-prop` - 修改目录属性

```
( change-dir-prop ( dir-token:string name:string [value:string] ) )
```

**作用**：设置、修改或删除目录的一个属性（property）。Subversion 中的属性是键值对，用于存储元数据（如 `svn:ignore`、`svn:externals` 等自定义属性）。

**线上格式说明**：`value` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `sc(?s)`。删除属性时，value 为 NULL，线上写为空元组 `( )`。value 使用 `string` 类型（带长度前缀），不是 `cstring`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `dir-token` | string | 是 | 目录的 token。指定要修改哪个目录的属性。 |
| `name` | string | 是 | 属性名称。如 `svn:ignore`、`svn:mergeinfo`、`my-custom-prop` 等。 |
| `value` | string | 否 | 属性值。如果指定则设置/修改属性为该值；如果**不指定**则**删除**该属性。 |

**示例**：
```
( change-dir-prop ( d0 svn:ignore ( 20:*.o
*.so
build/ ) ) )
```
设置 `d0` 目录的 `svn:ignore` 属性为 `*.o\n*.so\nbuild/`。

```
( change-dir-prop ( d0 svn:mergeinfo ( ) ) )
```
删除 `d0` 目录的 `svn:mergeinfo` 属性（空元组表示删除）。

---

### 7. `close-dir` - 关闭目录

```
( close-dir ( dir-token:string ) )
```

**作用**：表示对某个目录的所有编辑操作已完成。关闭后，该目录的 token 失效，不能再被引用。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `dir-token` | string | 是 | 要关闭的目录的 token。 |

**示例**：
```
( close-dir ( d1 ) )
```
关闭 token 为 `d1` 的目录。

**约束**：
- 必须在目录的所有子节点（子目录和文件）都已关闭后才能关闭该目录
- 关闭后 token 从哈希表中移除，关联的内存池被销毁
- 所有通过 `open-root`、`add-dir`、`open-dir` 创建的目录都必须最终被关闭

---

### 8. `absent-dir` - 声明缺失目录

```
( absent-dir ( path:string parent-token:string ) )
```

**作用**：通知消费方，在指定父目录下存在一个目录，但服务端**无法或不愿**提供其内容。这通常发生在授权（authz）限制了访问权限的情况下——服务器知道这个目录存在，但当前用户没有权限读取其内容。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 缺失目录的路径。 |
| `parent-token` | string | 是 | 父目录的 token。 |

**示例**：
```
( absent-dir ( trunk/secret-project d0 ) )
```
声明在 `d0` 目录下有一个名为 `trunk/secret-project` 的子目录，但无法提供其内容。

**能力要求**：需要双方都支持 `absent-entries` 能力。如果不支持，该命令会被静默忽略。

**`absent-dir` vs `delete-entry` 的区别**：
- `delete-entry`：该条目在目标版本中应该被删除
- `absent-dir`：该条目存在于仓库中，但因为权限等原因无法传输

---

### 9. `add-file` - 添加新文件

```
( add-file ( path:string dir-token:string file-token:string [copy-path:string copy-rev:number] ) )
```

**作用**：在指定目录下创建一个新文件。文件创建后，可以通过后续的 `apply-textdelta` 设置内容，通过 `change-file-prop` 设置属性，最终通过 `close-file` 关闭。

**线上格式说明**：`copy-path` 和 `copy-rev` 是可选参数，一起包在内层子元组 `(...)` 中。格式串为 `css(?cr)`。没有复制来源时子元组为空 `()`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 新文件的**相对路径**。如 `trunk/src/main.c`。 |
| `dir-token` | string | 是 | 父目录的 token。新文件将作为该目录的子节点创建。 |
| `file-token` | string | 是 | 新文件的唯一标识符。由驱动方生成，通常格式为 `c0`、`c1` 等。 |
| `copy-path` | string | 否 | 复制来源路径。如果文件是从其他位置复制来的，指定来源 URL 或 fspath。 |
| `copy-rev` | number | 否 | 复制来源修订版本号。仅当 `copy-path` 存在时有效。 |

**示例**：
```
( add-file ( trunk/README.md d0 c0 ( ) ) )
```
在 `d0` 目录下新建文件 `trunk/README.md`，token 为 `c0`，无复制来源。

```
( add-file ( trunk/config.ini d0 c1 ( svn://server/repos/trunk/config.ini 100 ) ) )
```
在 `d0` 下新建文件 `trunk/config.ini`，内容来自仓库中版本 100 的同名文件。

**约束**：`copy-path` 和 `copy-rev` 必须同时出现或同时不出现（都在同一个子元组内）。

---

### 10. `open-file` - 打开已有文件

```
( open-file ( path:string dir-token:string file-token:string [rev:number] ) )
```

**作用**：打开一个已存在于仓库中的文件，以便修改其内容或属性。与 `add-file` 不同，`open-file` 表示文件本身不是新增的。

**线上格式说明**：`rev` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `css(?r)`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 文件的**相对路径**。 |
| `dir-token` | string | 是 | 父目录的 token。 |
| `file-token` | string | 是 | 文件的新 token。由驱动方分配。 |
| `rev` | number | 否 | 基准修订版本号。表示"我打开的这个文件是基于版本 rev 的内容"。消费方据此判断后续文本差异是否应用正确。如果不指定，子元组为空 `()`。 |

**示例**：
```
( open-file ( trunk/src/main.c d0 c0 ( 42 ) ) )
```
在 `d0` 目录下打开已存在的文件 `trunk/src/main.c`，基于版本 42 的内容，分配 token `c0`。

**`add-file` vs `open-file` 的区别**：
- `add-file`：文件是新创建的，仓库中之前不存在
- `open-file`：文件已存在于仓库中，只是要修改其内容

---

### 11. `apply-textdelta` - 开始文本差异应用

```
( apply-textdelta ( file-token:string [base-checksum:string] ) )
```

**作用**：通知消费方开始接收文件内容的增量修改数据。这标志着一个文件文本修改会话的开始。后续必须跟随一个或多个 `textdelta-chunk` 命令，最终以一个 `textdelta-end` 命令结束。

**线上格式说明**：`base-checksum` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `s(?c)`。不指定时子元组为空 `()`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file-token` | string | 是 | 文件的 token。指定要修改哪个文件的内容。 |
| `base-checksum` | string | 否 | 基础内容的 MD5 校验和（十六进制字符串）。用于验证文件的基础内容是否与预期一致。消费方在应用差异前会校验现有文件内容的 MD5 是否匹配。如果不指定则跳过校验。对于新增文件（`add-file`），基础内容为空，通常不指定。 |

**示例**：
```
( apply-textdelta ( c0 ( ) ) )
```
开始修改 `c0` 文件的内容，不校验基础内容。

```
( apply-textdelta ( c0 ( d41d8cd98f00b204e9800998ecf8427e ) ) )
```
开始修改 `c0` 文件的内容，要求基础内容的 MD5 为 `d41d8cd98f00b204e9800998ecf8427e`。

**svndiff 格式**：后续的 `textdelta-chunk` 数据使用 svndiff 差分编码格式。根据双方协商的能力，可能使用 svndiff v0、v1 或 v2：
- v0：无压缩
- v1：使用压缩（需要 `svndiff1` 能力）
- v2：更高效的压缩（需要 `accepts-svndiff2` 能力）

**约束**：每个文件在同一时间只能有一个活跃的 `apply-textdelta` 会话。如果在会话未结束时再次发送 `apply-textdelta`，消费方会报错。

---

### 12. `textdelta-chunk` - 传输差异数据块

```
( textdelta-chunk ( file-token:string chunk:string ) )
```

**作用**：传输文件差异（delta）数据的一个片段。差异数据使用 svndiff 格式编码，可能包含多个窗口（window），每个窗口描述如何将源文本转换为目标文本。数据被拆分成多个 chunk 传输，以控制内存使用。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file-token` | string | 是 | 文件的 token。与之前 `apply-textdelta` 指定的文件一致。 |
| `chunk` | string | 是 | 差异数据的二进制块。使用 svndiff 编码格式。每个 chunk 可以包含一个或多个 svndiff 窗口，或者一个窗口的部分数据。 |

**示例**：
```
( textdelta-chunk ( c0 152:...binary-svndiff-data... ) )
```
向 `c0` 文件写入 152 字节的 svndiff 差异数据。

**约束**：
- 必须在 `apply-textdelta` 之后调用
- 必须在 `textdelta-end` 之前调用
- 所有 chunk 的数据按顺序拼接，组成完整的 svndiff 流

---

### 13. `textdelta-end` - 结束差异传输

```
( textdelta-end ( file-token:string ) )
```

**作用**：通知消费方文件差异数据传输完毕。消费方会关闭 svndiff 流处理器，完成对文件内容的应用。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file-token` | string | 是 | 文件的 token。 |

**示例**：
```
( textdelta-end ( c0 ) )
```
结束 `c0` 文件的差异数据传输。

**完整的文件修改序列**：
```
( apply-textdelta ( c0 base-checksum ) )   ← 开始
( textdelta-chunk ( c0 200:.... ) )        ← 数据块 1
( textdelta-chunk ( c0 150:.... ) )        ← 数据块 2
( textdelta-end ( c0 ) )                   ← 结束
```

---

### 14. `change-file-prop` - 修改文件属性

```
( change-file-prop ( file-token:string name:string [value:string] ) )
```

**作用**：设置、修改或删除文件的一个属性。与 `change-dir-prop` 完全类似，只是作用于文件而非目录。

**线上格式说明**：`value` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `sc(?s)`。删除属性时，value 为 NULL，线上写为空元组 `( )`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file-token` | string | 是 | 文件的 token。 |
| `name` | string | 是 | 属性名称。常见的如 `svn:executable`（可执行标志）、`svn:eol-style`（行尾风格）、`svn:mime-type`（MIME 类型）等。 |
| `value` | string | 否 | 属性值。指定则设置属性；不指定则删除属性。 |

**示例**：
```
( change-file-prop ( c0 svn:executable ( 4:* ) ) )
```
设置 `c0` 文件的 `svn:executable` 属性为 `*`（标记为可执行）。

```
( change-file-prop ( c0 svn:mime-type ( ) ) )
```
删除 `c0` 文件的 `svn:mime-type` 属性（空元组表示删除）。

---

### 15. `close-file` - 关闭文件

```
( close-file ( file-token:string [text-checksum:string] ) )
```

**作用**：表示对某个文件的所有编辑操作已完成。关闭后，该文件的 token 失效。

**线上格式说明**：`text-checksum` 是可选参数，包在内层子元组 `(...)` 中。格式串为 `s(?c)`。不指定时子元组为空 `()`。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file-token` | string | 是 | 要关闭的文件的 token。 |
| `text-checksum` | string | 否 | 文件最终内容的 MD5 校验和（十六进制字符串，32 字符）。消费方在应用了所有文本差异后，可以验证结果文件的 MD5 是否匹配此值。如果不指定则跳过校验。 |

**示例**：
```
( close-file ( c0 ( d8e8fca2dc0f896fd7cb4cb0031ba249 ) ) )
```
关闭 `c0` 文件，验证最终内容的 MD5 为 `d8e8fca2dc0f896fd7cb4cb0031ba249`。

```
( close-file ( c0 ( ) ) )
```
关闭 `c0` 文件，不校验最终内容。

**约束**：
- 必须在 `apply-textdelta`/`textdelta-end` 序列完成后才能调用（如果修改了文件内容的话）
- 必须在所有 `change-file-prop` 调用完成后才能调用
- 关闭后 token 从哈希表移除，关联的文件内存池被释放
- 当所有文件引用归零时，文件共享内存池会被清空

---

### 16. `absent-file` - 声明缺失文件

```
( absent-file ( path:string parent-token:string ) )
```

**作用**：通知消费方，在指定父目录下存在一个文件，但服务端**无法或不愿**提供其内容。原因通常是授权限制。

**参数说明**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 缺失文件的路径。 |
| `parent-token` | string | 是 | 父目录的 token。 |

**示例**：
```
( absent-file ( trunk/secrets/passwords.txt d0 ) )
```
声明在 `d0` 目录下存在 `trunk/secrets/passwords.txt` 文件，但无法提供其内容。

**能力要求**：需要双方都支持 `absent-entries` 能力。

---

### 17. `close-edit` - 结束编辑

```
( close-edit ( ) )
  response: ( )
```

**作用**：表示整个编辑会话已成功完成。这是编辑操作的**正常终止信号**。

**参数**：无。

**响应**：空的成功响应 `( success ( ) )`。

**示例**：
```
( close-edit ( ) )
```

**行为**：
1. 驱动方发送 `close-edit`
2. 消费方执行最终提交/应用逻辑
3. 消费方返回 `( success ( ) )`
4. 编辑会话正式结束

**约束**：
- 在调试模式下，所有目录和文件必须在此之前已关闭（token 哈希表为空），否则报错
- `close-edit` 和 `abort-edit` 二者必选其一

---

### 18. `abort-edit` - 中止编辑

```
( abort-edit ( ) )
  response: ( )
```

**作用**：通知消费方放弃整个编辑会话，回滚所有未提交的更改。

**参数**：无。

**响应**：空的成功响应 `( success ( ) )`。

**示例**：
```
( abort-edit ( ) )
```

**触发场景**：
1. 驱动方自身发现错误，主动中止
2. 驱动方收到消费方提前发送的 `failure` 响应后，发送 `abort-edit`
3. 用户手动取消操作

---

### 19. `finish-replay` - 完成回放

```
( finish-replay ( ) )
```

**作用**：仅在 `replay` 操作中使用，由服务端发送给客户端，表示回放操作已全部完成。这不是一个标准的编辑器命令，只在 replay 上下文中有效。

**参数**：无。

**约束**：如果在非 replay 上下文中收到此命令，消费方会返回 `SVN_ERR_RA_SVN_UNKNOWN_CMD` 错误。

---

## 典型编辑序列示例

### 示例 1：提交新文件（Commit）

客户端驱动，服务端消费。场景：在 `trunk/` 下新增一个 `README.md` 文件。

```
# 设置目标版本（可选）
C: ( target-rev ( 42 ) )

# 打开根目录，基于版本 42
C: ( open-root ( 42 d0 ) )

# 打开已存在的 trunk 目录
C: ( open-dir ( trunk d0 d1 42 ) )

# 在 trunk 下新建文件
C: ( add-file ( trunk/README.md d1 c0 ) )

# 设置文件属性
C: ( change-file-prop ( c0 svn:eol-style 6:native ) )

# 开始写入文件内容
C: ( apply-textdelta ( c0 ) )

# 发送 svndiff 数据
C: ( textdelta-chunk ( c0 50:...svndiff-data... ) )

# 结束差异传输
C: ( textdelta-end ( c0 ) )

# 关闭文件，附校验和
C: ( close-file ( c0 abc123def456789012345678901234 ) )

# 关闭 trunk 目录
C: ( close-dir ( d1 ) )

# 关闭根目录
C: ( close-dir ( d0 ) )

# 完成编辑
C: ( close-edit ( ) )
S: ( success ( ) )
```

### 示例 2：更新工作副本（Update/Checkout）

服务端驱动，客户端消费。场景：将工作副本更新到版本 50，涉及修改 `main.c` 和删除 `old.h`。

```
# 设置目标版本
S: ( target-rev ( 50 ) )

# 打开根目录
S: ( open-root ( 42 d0 ) )

# 打开 trunk/src 目录
S: ( open-dir ( trunk/src d0 d1 42 ) )

# 打开已有文件 main.c
S: ( open-file ( trunk/src/main.c d1 c0 42 ) )

# 修改 main.c 的内容
S: ( apply-textdelta ( c0 a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4 ) )
S: ( textdelta-chunk ( c0 100:...svndiff-data... ) )
S: ( textdelta-end ( c0 ) )

# 关闭 main.c
S: ( close-file ( c0 f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4 ) )

# 删除 old.h
S: ( delete-entry ( trunk/src/old.h 42 d1 ) )

# 关闭 src 目录
S: ( close-dir ( d1 ) )

# 关闭根目录
S: ( close-dir ( d0 ) )

# 完成编辑
S: ( close-edit ( ) )
C: ( success ( ) )
```

### 示例 3：复制/分支操作（Copy）

```
# 打开根目录
C: ( open-root ( 42 d0 ) )

# 在 branches 下创建新目录（从 trunk 复制）
C: ( add-dir ( branches/feature-x d0 d1 svn://server/repos/trunk 42 ) )

# 打开复制来的文件并修改
C: ( open-file ( branches/feature-x/main.c d1 c0 42 ) )
C: ( apply-textdelta ( c0 ... ) )
C: ( textdelta-chunk ( c0 80:... ) )
C: ( textdelta-end ( c0 ) )
C: ( close-file ( c0 ) )

# 关闭
C: ( close-dir ( d1 ) )
C: ( close-dir ( d0 ) )
C: ( close-edit ( ) )
```

---

## 错误处理机制

### 消费方提前报错

编辑操作中，消费方可以在任意时刻发送 `failure` 响应来提前终止：

```
# 驱动方正在发送编辑命令...
D: ( add-file ( trunk/file.txt d0 c0 ) )
D: ( apply-textdelta ( c0 ) )
D: ( textdelta-chunk ( c0 200:... ) )

# 消费方发现错误，发送 failure（使用非阻塞 I/O）
C: ( failure ( ( 160013 "Can't write file" "serve.c" 1234 ) ) )

# 驱动方检测到有数据可读（即错误），中止编辑
D: ( abort-edit ( ) )
C: ( success ( ) )
```

### 驱动方检测错误的机制

驱动方通过 `check_for_error` 机制定期检测连接上是否有来自消费方的数据。具体策略：

1. 每次写入操作前检查 `error_check_interval` 计数器
2. 如果已达到检查间隔，调用 `data_available()` 检测连接
3. 如果发现有数据可读，说明消费方发送了错误
4. 驱动方发送 `abort-edit`，读取并返回消费方的错误信息

### 写阻塞时的死锁防护

当消费方尝试发送错误但写操作被阻塞（因为驱动方还在发送数据）时：
1. 消费方设置 `block_handler` 回调
2. 回调中读取并**丢弃**驱动方的编辑命令
3. 直到写入解除阻塞或读到 `abort-edit`
4. 这防止了 TCP 双向满缓冲导致的死锁

---

## 命令调用顺序约束

编辑器命令必须遵循严格的调用顺序：

```
1. target-rev（可选，必须在 open-root 之前）
2. open-root（必须，创建根 token）
3. 对每个目录/文件的操作序列：
   - 目录：add-dir/open-dir → [子节点操作...] → close-dir
   - 文件：add-file/open-file → [apply-textdelta → textdelta-chunk* → textdelta-end] → [change-file-prop*] → close-file
4. close-dir（根目录）
5. close-edit 或 abort-edit
```

**关键约束**：
- 子节点必须在父节点关闭之前关闭
- `textdelta-chunk` 必须在 `apply-textdelta` 之后、`textdelta-end` 之前
- 每个文件只能有一个活跃的 `apply-textdelta` 会话
- `close-edit` 时所有目录和文件必须已关闭

---

**参考源码**：
- `subversion/libsvn_ra_svn/editorp.c` - 编辑器驱动与消费实现
- `subversion/libsvn_ra_svn/protocol` - 协议规范
- `subversion/include/svn_delta.h` - delta_editor_t 接口定义
