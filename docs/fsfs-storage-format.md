# FSFS 仓库存储格式

## 1. 概述

FSFS（Flat File System）是 Subversion 当前唯一使用的仓库后端（BDB 已废弃）。它将仓库数据存储在普通文件系统的目录和文件中，无需数据库引擎。

核心设计原则：
- **不可变修订版**：一旦提交的修订版永不修改
- **内容寻址**：相同内容的表示（representation）可以共享（dedup）
- **增量存储**：文件内容以 svndiff delta 形式存储，减少空间占用

源码位于 `subversion/libsvn_fs_fs/`，其中 `structure` 和 `structure-indexes` 两份纯文本文件是官方格式设计文档。

---

## 2. 目录结构

```
repos/
├── conf/                        # 配置文件
│   ├── svnserve.conf           # svnserve 配置
│   ├── passwd                  # 用户密码
│   ├── authz                   # 路径权限
│   └── hooks-env               # 钩子环境变量
├── db/                          # 数据存储核心
│   ├── format                  # 格式版本号
│   ├── uuid                    # 仓库 UUID
│   ├── current                 # 最新修订版本号
│   ├── txn-current             # 下一个事务 key
│   ├── txn-current-lock        # txn-current 的写锁
│   ├── write-lock              # 仓库写锁
│   ├── min-unpacked-rev        # 最老的未打包修订版
│   ├── fsfs.conf               # FSFS 配置
│   ├── revs/                   # 修订版数据文件
│   │   ├── 0/                  # shard 0 (sharded layout)
│   │   │   ├── 0               # revision 0 的数据
│   │   │   ├── 1               # revision 1 的数据
│   │   │   └── ...
│   │   └── packs/              # 打包文件
│   │       └── 0.pack/
│   │           ├── pack        # 多个 rev 合并后的数据
│   │           ├── manifest    # rev → pack 内偏移映射
│   │           ├── 0.l2p       # L2P 索引
│   │           └── 0.p2l       # P2L 索引
│   ├── revprops/               # 修订版属性文件
│   │   └── 0/
│   │       ├── 0               # revision 0 的属性
│   │       └── ...
│   ├── transactions/           # 活跃事务
│   │   └── <txn-id>.txn/
│   │       ├── changes         # 变更路径记录
│   │       ├── props           # 事务属性
│   │       ├── next-ids        # 下一个临时 ID
│   │       ├── node.<id>.txn   # 节点修订文件
│   │       └── <id>.children   # 目录内容
│   ├── txn-protorevs/          # proto-rev 文件
│   ├── locks/                  # 文件锁存储
│   ├── node-origins/           # 节点来源缓存
│   └── rep-cache.db            # 表示共享缓存 (SQLite)
├── hooks/                       # 钩子脚本
│   ├── start-commit
│   ├── pre-commit
│   ├── post-commit
│   └── ...
└── locks/                       # 仓库级锁文件
```

### 关键文件常量

定义于 `libsvn_fs_fs/fs.h`：

```c
#define PATH_FORMAT           "format"
#define PATH_UUID             "uuid"
#define PATH_CURRENT          "current"
#define PATH_LOCK_FILE        "write-lock"
#define PATH_REVS_DIR         "revs"
#define PATH_REVPROPS_DIR     "revprops"
#define PATH_TXNS_DIR         "transactions"
#define PATH_TXN_CURRENT      "txn-current"
#define PATH_LOCKS_DIR        "locks"
#define PATH_MIN_UNPACKED_REV "min-unpacked-rev"
#define PATH_MANIFEST         "manifest"
#define PATH_PACKED           "pack"
```

---

## 3. Format 文件

`db/format` 文件记录 FSFS 格式版本号，决定仓库支持的特性集。

```
8
layout sharded 1000
addressing logical
```

| Format | SVN 版本 | 主要特性 |
|--------|----------|----------|
| 1 | 1.1+ | 基础格式, svndiff0 |
| 2 | 1.4+ | svndiff1 压缩 |
| 3 | 1.5+ | sharded 布局, txn-current, 独立 proto-revs |
| 4 | 1.6+ | packed shards, rep-sharing, mergeinfo, fsfs.conf |
| 5 | 1.7-dev | SQLite revprops（未发布） |
| 6 | 1.8 | packed revprops |
| 7 | 1.9 | logical addressing, pack-lock, instance ID |
| 8 | 1.10 | svndiff2, 可选 SHA1/uniquifier |

当前最新版本号：`SVN_FS_FS__FORMAT_NUMBER = 8`

### 布局方式

- **linear**：所有 rev 文件平铺在 `db/revs/` 下（format < 3）
- **sharded N**：每 N 个 rev 文件放在一个子目录中，如 `db/revs/0/0`, `db/revs/0/1`, ..., `db/revs/1/1000`

### 寻址方式

- **physical**（format < 7）：通过文件偏移直接定位数据
- **logical**（format 7+）：通过 L2P/P2L 索引映射定位数据

---

## 4. Revision 文件结构

每个 revision 文件（`db/revs/<shard>/<rev>`）包含一个修订版的全部数据：

```
┌─ Text/Property Representations  ← PLAIN 或 DELTA 数据块
├─ Node-Revisions                 ← 节点修订头信息
├─ Changed-Path Data              ← 变更路径列表
├─ Trailer (Footer)               ← 索引/偏移信息
└─ Index Data (format 7+)         ← L2P + P2L 索引
```

### 4.1 Representation（数据表示）

Representation 是文件内容和属性的存储单元。三种类型：

```
PLAIN\n                              → 完整原始内容
DELTA\n                              → 自引用 delta（对空流的 svndiff）
DELTA <rev> <item_index> <length>\n  → 对另一个 rep 的 delta
<svndiff 数据>
ENDREP\n                             → 结束标记
```

定义于 `low_level.c`：
```c
#define REP_PLAIN  "PLAIN"
#define REP_DELTA  "DELTA"
```

### 4.2 Representation 引用

Node-revision 的 `text:` 和 `props:` 字段格式：

```
<rev> <item_index> <size> <expanded_size> <md5> [<sha1>] [<uniquifier>]
```

| 字段 | 说明 |
|------|------|
| `rev` | 所在 revision 号（`-1` 表示在事务中） |
| `item_index` | 在 revision 中的 item 索引 |
| `size` | 磁盘上的表示大小 |
| `expanded_size` | 展开后的全文大小 |
| `md5` | MD5 摘要（32 hex chars） |
| `sha1` | SHA1 摘要（format 4+，format 8+ 可为 `-`） |
| `uniquifier` | 唯一标识符（format 4+，format 8+ 可为 `-`） |

### 4.3 Node-Revision 头信息

每个节点修订（node-revision）以文本格式存储，字段包括：

```
id: <node-rev-id>
type: file 或 dir
count: <predecessor_count>
props: <rep 引用>
text: <rep 引用>
cpath: <created_path>
pred: <predecessor_id>
copyfrom: <rev> <path>
copyroot: <rev> <path>
is-fresh-txn-root: true/false
minfo-here: true/false
minfo-cnt: <mergeinfo_count>
```

定义于 `low_level.c`。

---

## 5. Node-Rev-ID 格式

Node-Rev-ID 是节点的唯一标识，三段式结构：

```
<node_id>.<copy_id>.<txn_or_rev_id>
```

内部结构（`id.c`）：
```c
typedef struct fs_fs__id_t {
  svn_fs_id_t generic_id;
  struct {
    svn_fs_fs__id_part_t node_id;    // 节点唯一标识
    svn_fs_fs__id_part_t copy_id;    // 复制事件标识
    svn_fs_fs__id_part_t txn_id;     // 事务 ID（未提交时）
    svn_fs_fs__id_part_t rev_item;   // 修订号.条目号（已提交时）
  } private_id;
} fs_fs__id_t;
```

### ID 各部分格式

每部分：`<base36_number>[-<revision>]`

| 状态 | 第三段前缀 | 示例 |
|------|-----------|------|
| 已提交 | `r<rev>/<item_index>` | `2g1-45.0-0.r45/2` |
| 事务中 | `t<txn_rev>-<txn_number>` | `_1._0.t34-5` |
| 前缀 `_` | 事务内临时 ID | `_1._0.t34-5` |

解析函数：`id_parse()`（`id.c`）

---

## 6. 事务（Transaction）机制

提交过程通过临时事务完成，事务目录位于 `db/transactions/<txn-id>.txn/`：

```
<txn-id>.txn/
├── changes          # 变更路径记录
├── props            # 事务属性（如 svn:log）
├── next-ids         # 下一个 node_id / copy_id 分配
├── node.<id>.txn    # 临时节点修订
├── <id>.children    # 临时目录内容
└── itemidx          # 当前 item_index 计数器
```

### 提交流程

```
1. 创建事务 → svn_fs_begin_txn2()
2. 在事务中进行编辑操作
3. 提交事务 → svn_fs_commit_txn()
   a. 获取 write-lock
   b. 分配新修订号（current + 1）
   c. 将事务数据写入 rev 文件
   d. 更新 current 文件
   e. 清理事务目录
4. 失败则 abort → svn_fs_abort_txn()
```

事务 ID 通过 `txn-current` 文件原子分配，由 `txn-current-lock` 保护。

---

## 7. Pack 机制

多个连续的 revision 文件可以打包为一个 pack 文件，减少文件数量和小文件 I/O 开销。

### Pack 结构

```
db/revs/<shard>.pack/
├── pack            # 多个 rev 文件拼接
├── manifest        # rev → pack 内偏移映射（每 4 字节一个偏移）
├── <shard>.l2p     # L2P 索引（逻辑 → 物理）
└── <shard>.p2l     # P2L 索引（物理 → 逻辑）
```

`min-unpacked-rev` 文件记录最老的未打包修订版号。

### Pack 操作

`svnadmin pack` 命令触发，由 `pack.c` 实现。Pack 操作需要 `pack-lock` 文件保护（format 7+）。

---

## 8. Rep-Cache（表示共享）

内容寻址去重机制，通过 `rep-cache.db`（SQLite）实现：

```sql
-- rep-cache-db.sql
CREATE TABLE rep_cache (
  hash TEXT NOT NULL PRIMARY KEY,    -- SHA1 摘要
  revision INTEGER NOT NULL,         -- 所在修订版
  item_index INTEGER NOT NULL,       -- item 索引
  size INTEGER NOT NULL,             -- 表示大小
  expanded_size INTEGER NOT NULL     -- 展开后大小
);
```

在 `fsfs.conf` 中启用：
```
[rep-sharing]
enable = true
```

---

## 9. L2P / P2L 索引（Format 7+）

逻辑寻址模式下的双向索引（`index.c`，格式设计见 `structure-indexes`）：

- **L2P（Logical to Physical）**：给定 item_index，返回在 pack 文件中的物理偏移
- **P2L（Physical to Logical）**：给定物理偏移，返回 item_index 和类型

索引采用分页结构，页大小由 `fsfs.conf` 配置。

---

## 10. 关键数据结构

### fs_fs_data_t（文件系统私有数据）

```c
typedef struct fs_fs_data_t {
  int format;                          // 格式版本号
  int max_files_per_dir;               // shard 大小
  svn_boolean_t use_log_addressing;    // 是否逻辑寻址
  svn_revnum_t youngest_rev_cache;     // 缓存的最新版本
  svn_revnum_t min_unpacked_rev;       // 最老的未打包版本
  svn_boolean_t rep_sharing_allowed;   // 是否允许 rep 共享
  svn_sqlite__db_t *rep_cache_db;      // rep-cache 数据库
  // ... 各种缓存和配置
} fs_fs_data_t;
```

### representation_t（数据表示）

```c
typedef struct representation_t {
  unsigned char sha1_digest[APR_SHA1_DIGESTSIZE];
  unsigned char md5_digest[APR_MD5_DIGESTSIZE];
  svn_revnum_t revision;
  apr_uint64_t item_index;
  svn_filesize_t size;
  svn_filesize_t expanded_size;
  // ...
} representation_t;
```

### node_revision_t（节点修订）

```c
typedef struct node_revision_t {
  svn_node_kind_t kind;                // file 或 dir
  const svn_fs_id_t *id;               // node-rev ID
  const svn_fs_id_t *predecessor_id;   // 前驱 node-rev ID
  const char *copyfrom_path;           // 复制来源路径
  svn_revnum_t copyfrom_rev;           // 复制来源版本
  representation_t *prop_rep;          // 属性表示
  representation_t *data_rep;          // 数据表示
  svn_boolean_t has_mergeinfo;         // 是否有 mergeinfo
  // ...
} node_revision_t;
```

---

## 参考源码

- `libsvn_fs_fs/structure` — 官方格式设计文档
- `libsvn_fs_fs/structure-indexes` — 索引格式设计
- `libsvn_fs_fs/fs.h` — 常量定义和核心结构体
- `libsvn_fs_fs/low_level.c` — 底层读写操作
- `libsvn_fs_fs/id.c` — Node-Rev-ID 解析/序列化
- `libsvn_fs_fs/transaction.c` — 事务管理
- `libsvn_fs_fs/pack.c` — 打包操作
- `libsvn_fs_fs/index.c` — L2P/P2L 索引
- `libsvn_fs_fs/rep-cache.c` — 表示共享缓存
