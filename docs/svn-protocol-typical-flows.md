# svn:// 协议 - 典型操作交互流程

## 概述

本文档以源码为依据，详细展示几个典型操作在 `svn://` 协议层面的**完整交互过程**。每个操作都从 TCP 连接建立开始，到操作完成结束，展示客户端和服务端之间的每一条协议消息。

---

## 一、`svn export`（从远程仓库导出到本地）

### 架构要点

`svn export` 从远程 URL 导出时，在协议层面**完全复用 `update` 命令的 report + editor 机制**，与 `svn checkout` 几乎相同。核心区别仅在于客户端使用的编辑器不同：

- **Export 编辑器**：直接把内容写到磁盘（纯净目录树）
- **WC Update 编辑器**：创建 `.svn` 目录和 `wc.db` 数据库（版本化工作副本）

核心代码位于 `libsvn_client/export.c` 的 `export_directory()` 函数：

```c
/* Manufacture a basic 'report' to the update reporter. */
SVN_ERR(svn_ra_do_update3(ra_session, &reporter, &report_baton,
                          loc->rev, "", depth, FALSE, FALSE,
                          export_editor, edit_baton, ...));

SVN_ERR(reporter->set_path(report_baton, "", loc->rev,
                           svn_depth_infinity,
                           TRUE,   /* "help, my dir is empty!" */
                           NULL, scratch_pool));

SVN_ERR(reporter->finish_report(report_baton, scratch_pool));
```

### 完整协议交互

#### 阶段 1：TCP 连接 + 握手

```
客户端                                                    服务端
══════                                                    ══════

                                                    ◄──  TCP accept on :3690

                                                    ◄──  ( ( 2 2 )
                                                           ( )
                                                           ( edit-pipeline
                                                             svndiff1
                                                             accepts-svndiff2
                                                             absent-entries
                                                             commit-revprops
                                                             depth
                                                             log-revprops
                                                             atomic-revprops
                                                             partial-replay
                                                             inherited-props
                                                             ephemeral-txnprops
                                                             file-revs-reverse
                                                             list ) )
```

客户端读取服务端问候，解析出：
- `minver=2, maxver=2` → 协议版本 2
- 认证机制列表（如 `ANONYMOUS`）
- 服务端能力列表

```
  发送客户端信息 ──────────────────────────────────►
  ( 2
    ( edit-pipeline
      svndiff1
      accepts-svndiff2
      absent-entries
      depth
      mergeinfo
      log-revprops )
    "svn://server/repo/trunk"
    "SVN/1.14.0 (x86_64-apple-darwin17.7.0)"
  )
```

客户端发送：
- 协议版本号 `2`
- 客户端能力列表
- 会话 URL
- 客户端版本字符串 + 自定义字符串

```
                                                    ◄──  auth-request
                                                    ◄──  ( ( ) "<svn://server:3690>" )
                                                         └── 空机制列表 = 无需认证
```

如果服务端返回空机制列表，表示无需认证（匿名访问已授权）。否则进入 SASL 认证交换。

```
                                                    ◄──  仓库信息响应
                                                    ◄──  ( "a1b2c3d4-uuid"
                                                           "svn://server/repo"
                                                           ( mergeinfo ) )
```

服务端返回：
- 仓库 UUID
- 仓库根 URL
- 仓库能力列表（可能比握手时更多）

至此，连接建立完成，进入主命令集。

#### 阶段 2：发送 `update` 主命令

```
( update ( 42 "" true infinity ) )  ──────────────►
  │         │  │ │    │
  │         │  │ │    └── depth: infinity（完全递归）
  │         │  │ └── recurse: true（兼容旧协议）
  │         │  └── target: ""（空路径 = 会话根）
  │         └── rev: 42（目标版本）
  └── 命令名

  等待 auth-request ──────────────────────────────────►
                                                    ◄──  ( ( ) "" )
                                                         └── trivial auth，无需重新认证
```

服务端收到 `update` 命令后：
1. 解析参数：`"(?r)cb?w3?3"` → rev=42, target="", recurse=true, depth=infinity
2. 规范化目标路径
3. 检查读权限（`must_have_access`），发送 trivial auth-request
4. 调用 `accept_report()`，进入报告命令集

#### 阶段 3：报告阶段（无响应流水线）

```
( set-path ( "" 42 true ( ) infinity ) )  ────────────►     （无响应）
  │              │  │  │    │
  │              │  │  │    └── depth: infinity
  │              │  │  └── start_empty: true ★ 关键
  │              │  └── rev: 42（基线版本）
  │              └── path: ""（根路径）
  └── 告诉服务端：我的目录是空的

( finish-report ( ) )  ─────────────────────────────►
```

**关键设计**：`start_empty=true` 告诉服务端"假设我的目录是空的"。服务端计算差异时发现"空目录 vs 版本 42 的完整目录树"→ 所有节点都是"新增"→ 通过编辑器命令全部发送。

这与 `svn checkout` 使用的策略完全相同——两者都是"从无到有"。

报告命令无响应（流水线优化），客户端可连续发送多条而无需等待。

#### 阶段 4：auth-request + 编辑器命令流

```
                                                    ◄──  ( ( ) "" )
                                                         └── trivial auth-request
```

服务端调用 `svn_repos_finish_report()`，开始计算差异并驱动网络编辑器。由于报告了空目录，所有节点都作为"新增"发送：

```
                                                    ◄──  ( target-revision 42 )

                                                    ◄──  ( open-root ( "" -1 42 ) )
                                                         └── 打开根目录
                                                             base-rev = -1（新增，无基础版本）
                                                             target-rev = 42

                                                    ◄──  ( change-dir-prop ( ""
                                                           "svn:ignore" "*.o\n*.a" ) )
```

**目录操作**：

```
                                                    ◄──  ( add-directory ( "src" 42 ) )
                                                         └── 新增 src 目录
                                                             parent-dir-baton = root
                                                             copyfrom-path = null
                                                             copyfrom-rev = -1

                                                    ◄──  ( change-dir-prop ( "src"
                                                           "svn:mergeinfo" "/trunk:1-42" ) )
```

**文件操作**（每个文件包含：新增 → 文本增量 → 属性 → 关闭）：

```
                                                    ◄──  ( add-file ( "src/main.c" 42 ) )
                                                         └── 新增文件 main.c

                                                    ◄──  ( apply-textdelta ( "src/main.c" null ) )
                                                         └── 开始文本增量流
                                                             base-checksum = null（新文件无基础）

                                                    ◄──  ( textdelta-block "...binary data..." )
                                                    ◄──  ( textdelta-block "...more data..." )
                                                    ◄──  ... 多个 textdelta-block ...
                                                    ◄──  ( textdelta-block "" )
                                                         └── 空块 = 文本结束

                                                    ◄──  ( change-file-prop ( "src/main.c"
                                                           "svn:eol-style" "native" ) )
                                                    ◄──  ( change-file-prop ( "src/main.c"
                                                           "svn:keywords" "Id" ) )

                                                    ◄──  ( close-file ( "src/main.c"
                                                           "md5:d41d8cd98f00b204e9800998ecf8427e" ) )
                                                         └── 关闭文件
                                                             text-md5 = 内容校验和
```

更多文件重复同样的 add-file → apply-textdelta → textdelta-block... → change-file-prop → close-file 模式：

```
                                                    ◄──  ( add-file ( "src/util.c" 42 ) )
                                                    ◄──  ( apply-textdelta ( "src/util.c" null ) )
                                                    ◄──  ... textdelta blocks ...
                                                    ◄──  ( close-file ( "src/util.c" "md5:..." ) )

                                                    ◄──  ( close-dir ( "src" ) )
                                                         └── 关闭 src 目录
```

继续处理其他目录和文件：

```
                                                    ◄──  ( add-directory ( "docs" 42 ) )
                                                    ◄──  ... docs 下的文件 ...
                                                    ◄──  ( close-dir ( "docs" ) )
```

**编辑完成**：

```
                                                    ◄──  ( close-dir ( "" ) )
                                                         └── 关闭根目录

                                                    ◄──  ( close-edit ( ) )
                                                         └── 编辑完成
```

#### 阶段 5：命令响应

```
                                                    ◄──  ( success ( ) )
                                                         └── 空元组，update 操作成功完成
```

服务端发送 `command-response`，表示整个 update 操作（含报告 + 编辑）成功。至此回到主命令集。

#### 阶段 6：后处理（客户端本地操作，无协议交互）

1. **空目录特殊处理**：如果导出目标是空目录（`open_root` 从未被调用），客户端手动创建目标目录
2. **`svn:externals` 处理**：如果 depth=infinity 且存在 `svn:externals` 属性，递归执行子 export（可能建立新连接）
3. **通知完成**：调用 `notify_func2` 回调，报告导出完成

### 单文件 Export 的特殊路径

如果导出目标是单个文件（非目录），export 代码走完全不同的路径——**不使用 update/report 机制**，而是直接调用 `get-file` 主命令：

```
( get-file ( "" ( 42 ) false true ) )  ──────────►
  │            │   │      │    │
  │            │   │      │    └── want-contents: true
  │            │   │      └── want-props: false（通过单独调用获取属性）
  │            │   └── rev: 42
  │            └── path: ""
  └── get-file 命令

  等待 auth-request ──────────────────────────────────►
                                                    ◄──  ( ( ) "" )

                                                    ◄──  ( success ( ( ) 42 ) )
                                                         └── props=空（不请求属性时）
                                                             rev=42

  文件内容直接跟在响应之后 ──────────────────────────────►
                                                    ◄──  "...文件原始内容..."
```

客户端在 `get-file` 之前已经通过 `change_file_prop` 风格的本地调用获取了属性，然后用 `svn_ra_get_file()` 直接流式下载文件内容。

### Export vs Checkout 对比

```
                    svn export                    svn checkout
                    ──────────                    ────────────
主命令              update                         update
目标版本            HEAD 或指定                    HEAD 或指定
Report 阶段         1 条 set-path (start_empty)    1 条 set-path (start_empty)
编辑器命令          完全相同                       完全相同
编辑器类型          export_editor (写磁盘)         update_editor (写 WC + .svn)
svn:externals       递归 export                    递归 checkout
svn:keywords        展开                           展开
svn:eol-style       转换行尾                       转换行尾
结果                纯净目录                       带 .svn 的工作副本
```

**在协议层面，`svn export` 和 `svn checkout` 是完全相同的操作**。服务端无法区分两者——它们发送的协议消息一模一样。区别仅在于客户端接收编辑器命令后的处理方式。

服务端的日志解析脚本也直接体现了这一点——checkout 和 export 合并为一个日志类别：`checkout-or-export`。

---

## 二、`svn checkout`（检出工作副本）

### 与 Export 的协议等价性

如前所述，`svn checkout` 在协议层面与 `svn export` **完全相同**：

1. 连接握手 → 完全相同
2. `update` 命令 → 参数完全相同
3. Report 阶段 → 1 条 `set-path "" ... start_empty=true`
4. 编辑器命令流 → 完全相同
5. 最终响应 → 完全相同

唯一区别在客户端：

| 编辑器回调 | Export Editor | WC Update Editor |
|-----------|--------------|-----------------|
| `open_root` | `mkdir(target_path)` | 创建 `.svn/` 目录 + 初始化 `wc.db` |
| `add_directory` | `mkdir(path)` | 创建目录 + 写入 `NODES` 表记录 |
| `add_file` | 创建文件 | 创建 pristine 文件 + 写入 `NODES` 表 |
| `apply_textdelta` | 写入临时文件 → 移动到目标 | 写入 `pristines/` 目录 |
| `change_file_prop` | 关键字展开 / EOL 转换 | 记录到 `wc.db` + 关键字展开 |
| `close_edit` | 无操作 | 写入 `ACTUAL_NODE` 等最终元数据 |

---

## 三、`svn update`（更新工作副本）

### 与 Checkout/Export 的关键区别

`svn update` 的区别在于**报告阶段**——客户端不是报告"空目录"，而是详细描述工作副本的实际状态：

```
── 阶段 1-2：连接 + update 命令（同 checkout/export）──

── 阶段 3：报告阶段（详细描述 WC 状态）──

( set-path ( "" 30 false ( ) infinity ) )  ──────►    （无响应）
  │              │  │  │    │
  │              │  │  │    └── depth: infinity
  │              │  │  └── start_empty: false ★ 目录有内容
  │              │  └── rev: 30（WC 当前版本）
  │              └── path: ""（根）
  └── WC 根目录在版本 30

( set-path ( "src" 30 false ( ) infinity ) )  ────►   （无响应）
  └── src 目录在版本 30

( set-path ( "src/main.c" 30 false ( ) ) )  ──────►   （无响应）
  └── main.c 在版本 30，没有修改

( delete-path ( "old-file.c" ) )  ──────────────►  （无响应）
  └── old-file.c 在 WC 中被本地删除

( set-path ( "src/new.c" 0 false ( ) ) )  ────────►   （无响应）
  └── new.c 是本地新增文件（rev=0 或 INVALID）

( finish-report ( ) )  ─────────────────────────►
```

服务端收到后：
- 比较 WC 状态（版本 30 + 本地修改）与目标版本（42）
- 仅发送**差异**：修改的文件、新增的文件、删除的文件

```
── 阶段 4：编辑器命令（只有差异）──

                                                    ◄──  ( target-revision 42 )
                                                    ◄──  ( open-root ( "" 30 42 ) )
                                                    │    └── 打开根目录
                                                    │        base-rev = 30（已存在）
                                                    │        target-rev = 42

                                                    ◄──  ( open-file ( "src/main.c" 30 42 ) )
                                                    │    └── 打开已有文件，可能需要更新

                                                    ◄──  ( apply-textdelta ( "src/main.c" "md5:old..." ) )
                                                    ◄──  ... 增量文本块 ...
                                                    ◄──  ( close-file ( "src/main.c" "md5:new..." ) )

                                                    ◄──  ( delete-entry ( "old-file.c" 42 ) )
                                                    │    └── 删除 old-file.c（服务端确认删除）

                                                    ◄──  ( add-file ( "src/util.c" 42 ) )
                                                    │    └── 服务端新增了 util.c

                                                    ◄──  ( close-dir ( "" ) )
                                                    ◄──  ( close-edit ( ) )

── 阶段 5：命令响应 ──

                                                    ◄──  ( success ( ) )
```

对比 checkout/export 发送全部内容，update 只发送增量差异，因此数据量通常小得多。

---

## 四、`svn commit`（提交变更）

### 完整交互流程

`commit` 是唯一从**客户端到服务端**方向驱动编辑器命令的操作：

```
── 阶段 1：连接握手（同前）──

── 阶段 2：发送 commit 命令 ──

( commit ( "Fix bug #123" ( ) false ) )  ────────►
  │          │              │  │
  │          │              │  └── keep-locks: false
  │          │              └── lock-tokens: 空列表
  │          └── log-message: "Fix bug #123"
  └── commit 命令

  等待 auth-request ──────────────────────────────────►
                                                    ◄──  ( ( ANONYMOUS ) "realm" )
                                                         └── 需要写权限，可能触发认证
```

认证成功后，服务端切换到**编辑器命令集**，客户端开始驱动编辑器：

```
── 阶段 3：客户端发送编辑器命令 ──

( open-root ( "" -1 ) )  ────────────────────────►
  └── 打开事务根目录

( open-directory ( "src" -1 ) )  ────────────────►
  └── 打开 src 目录

( open-file ( "src/main.c" -1 ) )  ──────────────►
  └── 打开要修改的文件

( apply-textdelta ( "src/main.c" "md5:old..." ) ) ─►
  └── 开始发送文本增量

( textdelta-block "..." )  ──────────────────────►
( textdelta-block "" )  ─────────────────────────►
  └── 文本增量结束

( change-file-prop ( "src/main.c" "svn:mergeinfo" "..." ) ) ─►

( close-file ( "src/main.c" "md5:new..." ) )  ───►
  └── 关闭文件，附带新校验和

( close-directory ( "src" ) )  ──────────────────►

( close-directory ( "" ) )  ─────────────────────►

( close-edit ( ) )  ─────────────────────────────►
  └── 编辑完成，触发服务端提交
```

### 阶段 4：commit-info 响应

```
                                                    ◄──  ( success ( 43 "2024-03-15T10:30:00Z" "john" ) )
                                                         └── 提交成功！
                                                             new-rev = 43
                                                             date = ISO 8601 时间戳
                                                             author = "john"
```

如果提交过程中有非致命错误（如 post-commit hook 失败）：

```
                                                    ◄──  ( success ( 43 "2024-03-15T10:30:00Z" "john"
                                                           ( "post-commit hook failed" ) ) )
                                                         └── 提交成功但有 post-commit 错误
```

---

## 五、`svn diff`（远程差异比较）

### 完整交互流程

`svn diff -r 30:42 svn://server/repo/trunk` 使用 `diff` 主命令 + report + editor：

```
── 阶段 1：连接握手（同前）──

── 阶段 2：发送 diff 命令 ──

( diff ( 42 "" false false
         "svn://server/repo/trunk"
         true infinity ) )  ─────────────────────►
  │        │  │  │    │      │                      │
  │        │  │  │    │      │                      └── depth: infinity
  │        │  │  │    │      └── text-deltas: true（发送文本差异）
  │        │  │  │    └── url: 差异比较的 URL
  │        │  │  └── ignore-ancestry: false
  │        │  └── recurse: false（由 depth 控制）
  │        └── target: ""
  └── rev: 42（目标版本）

  等待 auth-request ──────────────────────────────────►
                                                    ◄──  ( ( ) "" )

── 阶段 3：报告阶段 ──

( set-path ( "" 30 false ( ) infinity ) )  ──────────►   （无响应）
  └── WC 在版本 30 的状态

( finish-report ( ) )  ─────────────────────────►

── 阶段 4：编辑器命令（差异流）──

                                                    ◄──  ( target-revision 42 )
                                                    ◄──  ( open-root ( "" 30 42 ) )

                                                    ◄──  ( open-file ( "src/main.c" 30 42 ) )
                                                    ◄──  ( apply-textdelta ( "src/main.c" "md5:..." ) )
                                                    ◄──  ... textdelta blocks（版本间差异）...
                                                    ◄──  ( close-file ( "src/main.c" "md5:..." ) )

                                                    ◄──  ( delete-entry ( "removed.c" -1 ) )
                                                    │    └── 被删除的文件

                                                    ◄──  ( add-file ( "added.c" 42 ) )
                                                    ◄──  ... 新增文件内容 ...
                                                    ◄──  ( close-file ( "added.c" "md5:..." ) )

                                                    ◄──  ( close-dir ( "" ) )
                                                    ◄──  ( close-edit ( ) )

── 阶段 5：命令响应 ──

                                                    ◄──  ( success ( ) )
```

---

## 六、`svn log`（查看提交日志）

### 完整交互流程

`svn log -r 1:HEAD svn://server/repo/trunk` 使用 `log` 主命令，流式返回日志条目：

```
── 阶段 1：连接握手（同前）──

── 阶段 2：发送 log 命令 ──

( log ( "" ) ( 1 ) ( 42 ) true false 100 false
      "all" ( ) )  ─────────────────────────────►
  │     │      │     │    │    │   │     │    │
  │     │      │     │    │    │   │     │    └── revprop-items: 空（不请求额外属性）
  │     │      │     │    │    │   │     └── revprop-word: "all"（所有属性）
  │     │      │     │    │    │   └── include-merged-revs: false
  │     │      │     │    │    └── limit: 100
  │     │      │     │    └── strict-node: false
  │     │      │     └── changed-paths: true
  │     │      └── start-rev: 1
  │     └── paths: ("")
  └── log 命令

  等待 auth-request ──────────────────────────────────►
                                                    ◄──  ( ( ) "" )

── 阶段 3：流式日志条目 ──

                                                    ◄──  ( log-entry
                                                    │      ( ( "A" "/trunk/src/main.c" -1 -1 -1 )
                                                    │        ( "M" "/trunk/src/util.c" -1 -1 -1 ) )
                                                    │      42 "john" "2024-03-15T10:30:00Z"
                                                    │      "Fix bug #123"
                                                    │      ( "svn:log" "Fix bug #123"
                                                    │        "svn:author" "john"
                                                    │        "svn:date" "2024-03-15T10:30:00Z" ) )

                                                    ◄──  ( log-entry
                                                    │      ( ( "A" "/trunk/README" -1 -1 -1 ) )
                                                    │      41 "jane" "2024-03-14T09:00:00Z"
                                                    │      "Add README"
                                                    │      ( ... ) )

                                                    ◄──  ... 更多 log-entry ...

                                                    ◄──  ( done )
                                                         └── 日志流结束

── 阶段 4：命令响应 ──

                                                    ◄──  ( success ( ) )
```

---

## 七、连接握手详解（所有操作共用）

### 握手消息格式

```
服务端问候:  ( ( minver:number maxver:number )
               mechlist:( word ... )
               server-capabilities:( word ... ) )

客户端响应:  ( protocol-version:number
               client-capabilities:( word ... )
               url:string
               client-version:string
               ? ( client-string:string ) )

认证请求:    ( ( mechlist ) realm:string )
             └── 空 mechlist = 无需认证

仓库信息:    ( uuid:string ? repos-root:string ? repos-capabilities:( word ... ) )
```

### 标准能力列表

**服务端典型能力**：

| 能力 | 说明 |
|------|------|
| `edit-pipeline` | 支持编辑器流水线（必需） |
| `svndiff1` | 支持 svndiff1 压缩格式 |
| `accepts-svndiff2` | 接受 svndiff2 差分格式 |
| `absent-entries` | 支持 absent-file/absent-directory |
| `commit-revprops` | 支持提交时设置 revprops |
| `depth` | 支持深度参数 |
| `log-revprops` | 支持日志修订属性过滤 |
| `atomic-revprops` | 支持 change-rev-prop2 原子操作 |
| `partial-replay` | 支持 replay-range |
| `inherited-props` | 支持继承属性检索 |
| `ephemeral-txnprops` | 支持临时事务属性 |
| `file-revs-reverse` | 支持反向文件修订遍历 |
| `list` | 支持 list 命令 |

**客户端典型能力**：

| 能力 | 说明 |
|------|------|
| `edit-pipeline` | 支持编辑器流水线（必需） |
| `svndiff1` | 支持 svndiff1 格式 |
| `accepts-svndiff2` | 接受 svndiff2 格式 |
| `absent-entries` | 处理 absent 通知 |
| `depth` | 发送深度参数 |
| `mergeinfo` | 请求 mergeinfo |
| `log-revprops` | 使用 revprop 过滤 |
