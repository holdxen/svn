# 工作副本（Working Copy）格式

## 1. 概述

工作副本是 Subversion 客户端本地维护的版本化目录树。它是用户编辑文件的工作空间，也是客户端检测本地修改、执行提交/更新/合并等操作的基础。

当前工作副本格式为 **WC-NG**（Working Copy Next Generation），使用 SQLite 数据库（`wc.db`）存储所有元数据，取代了早期基于 XML 的 `entries` 文件格式。

源码位于 `subversion/libsvn_wc/`，其中 `wc-metadata.sql` 定义了完整的数据库 schema。

---

## 2. 目录结构

```
project/                         # 工作副本根目录
├── .svn/                        # 管理目录
│   ├── wc.db                    # SQLite 元数据数据库（核心）
│   ├── pristine/                # 原始文件内容存储
│   │   ├── ab/
│   │   │   └── abcdef1234...svn-base    # SHA-1 索引的文件
│   │   └── ...
│   ├── tmp/                     # 操作临时空间
│   └── wc.db.lock               # 数据库锁（可选）
├── trunk/                       # 版本化目录
│   └── ...
└── ...
```

### 关键常量

定义于 `wc.h`：
```c
#define SVN_WC__ADM_TMP                 "tmp"
#define SVN_WC__ADM_PRISTINE            "pristine"
```

定义于 `wc_db.c`：
```c
#define SDB_FILE  "wc.db"
#define WCROOT_TEMPDIR_RELPATH   "tmp"
```

---

## 3. 三层数据模型

工作副本的核心设计是 **BASE / WORKING / ACTUAL** 三层模型：

```
┌─────────────────────────────────────────────────────┐
│  ACTUAL（磁盘上实际的文件）                            │
│  - 用户编辑后的内容                                   │
│  - 记录在 ACTUAL_NODE 表                              │
├─────────────────────────────────────────────────────┤
│  WORKING（本地树结构修改）                             │
│  - 本地 add/delete/copy/move 操作                     │
│  - 记录在 NODES 表 op_depth > 0                      │
├─────────────────────────────────────────────────────┤
│  BASE（来自服务端的原始副本）                           │
│  - checkout/update/switch/commit 后同步                │
│  - 记录在 NODES 表 op_depth == 0                     │
│  - 内容存储在 pristine/ 目录                          │
└─────────────────────────────────────────────────────┘
```

### 各层职责

| 层 | 来源 | NODES op_depth | 说明 |
|----|------|----------------|------|
| **BASE** | 服务端 | `== 0` | 绝对原始的仓库副本，只能通过 checkout/update/switch/commit 改变 |
| **WORKING** | 本地操作 | `> 0` | 记录结构性修改（add/delete/copy/move），每层操作用递增的 op_depth 表示 |
| **ACTUAL** | 磁盘文件 | ACTUAL_NODE 表 | 用户实际的文本修改和属性修改 |

### 修改检测

- **文本修改**：将 ACTUAL 文件内容与 BASE/WORKING 中的 pristine 内容做比较
- **属性修改**：将 ACTUAL_NODE 中的 properties 与 NODES 中的 properties 比较
- **树冲突**：记录在 ACTUAL_NODE 的 `tree_conflict_data` / `conflict_data` 字段

API 入口（`wc_db.h`）：
```c
// BASE 树操作
svn_wc__db_base_add_directory()
svn_wc__db_base_add_file()

// WORKING 树操作
svn_wc__db_op_add_directory()
svn_wc__db_op_add_file()
svn_wc__db_op_copy()
svn_wc__db_op_move()
svn_wc__db_op_delete()

// 综合读取（ACTUAL → WORKING → BASE）
svn_wc__db_read_info()
```

---

## 4. wc.db 数据库 Schema

定义于 `wc-metadata.sql`。核心表：

### 4.1 REPOSITORY

```sql
CREATE TABLE REPOSITORY (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  root TEXT UNIQUE NOT NULL,       -- 仓库根 URL
  uuid TEXT NOT NULL               -- 仓库 UUID
);
```

### 4.2 WCROOT

```sql
CREATE TABLE WCROOT (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  local_abspath TEXT UNIQUE        -- 工作副本根的绝对路径
);
```

### 4.3 PRISTINE

```sql
CREATE TABLE PRISTINE (
  checksum TEXT NOT NULL PRIMARY KEY,   -- SHA-1 摘要
  compression INTEGER,                  -- 压缩方式
  size INTEGER NOT NULL,                -- 文件大小
  refcount INTEGER NOT NULL,            -- 引用计数
  md5_checksum TEXT NOT NULL            -- MD5 摘要
);
```

Pristine 文件存储在 `.svn/pristine/` 下，以 SHA-1 索引，扩展名为 `.svn-base`。

### 4.4 NODES（核心表）

```sql
CREATE TABLE NODES (
  wc_id INTEGER NOT NULL REFERENCES WCROOT (id),
  local_relpath TEXT NOT NULL,
  op_depth INTEGER NOT NULL,        -- 0=BASE, >0=WORKING layers
  parent_relpath TEXT,
  repos_id INTEGER REFERENCES REPOSITORY (id),
  repos_path TEXT,
  revision INTEGER,
  presence TEXT NOT NULL,           -- normal/server-excluded/excluded/
                                    -- not-present/incomplete/base-deleted
  moved_here INTEGER,
  moved_to TEXT,
  kind TEXT NOT NULL,               -- file/dir/symlink/unknown
  properties BLOB,
  depth TEXT,
  checksum TEXT REFERENCES PRISTINE (checksum),
  symlink_target TEXT,
  changed_revision INTEGER,
  changed_date INTEGER,
  changed_author TEXT,
  translated_size INTEGER,
  ...
  PRIMARY KEY (wc_id, local_relpath, op_depth)
);
```

`presence` 的取值：
| 值 | 说明 |
|----|------|
| `normal` | 正常存在 |
| `server-excluded` | 被服务端排除（authz） |
| `excluded` | 被客户端排除（sparse checkout） |
| `not-present` | 不存在（已删除/未检出） |
| `incomplete` | 不完整（操作中断） |
| `base-deleted` | 在 WORKING 层被删除 |

### 4.5 ACTUAL_NODE

```sql
CREATE TABLE ACTUAL_NODE (
  wc_id INTEGER NOT NULL REFERENCES WCROOT (id),
  local_relpath TEXT NOT NULL,
  parent_relpath TEXT,
  properties BLOB,              -- NULL = 无修改
  conflict_old TEXT,            -- 旧版冲突文件
  conflict_new TEXT,            -- 新版冲突文件
  conflict_working TEXT,        -- 工作版冲突文件
  prop_reject TEXT,             -- 属性拒绝文件
  changelist TEXT,              -- changelist 名
  text_mod TEXT,                -- 文本修改状态
  tree_conflict_data TEXT,      -- 树冲突数据
  conflict_data BLOB,           -- 完整冲突数据
  older_checksum TEXT REFERENCES PRISTINE (checksum),
  left_checksum TEXT REFERENCES PRISTINE (checksum),
  right_checksum TEXT REFERENCES PRISTINE (checksum),
  PRIMARY KEY (wc_id, local_relpath)
);
```

### 4.6 其他表

| 表 | 用途 |
|----|------|
| `LOCK` | 仓库锁缓存 |
| `WORK_QUEUE` | 待执行的工作项（原子操作队列） |
| `WC_LOCK` | 工作副本锁状态 |
| `EXTERNALS` | 外部引用定义 |
| `TEXTBASE_REFS` | 文本基础引用 |
| `SETTINGS` | WC 级别设置 |

---

## 5. Pristine 存储

`.svn/pristine/` 目录以内容寻址方式存储 BASE 版本的文件：

```
.svn/pristine/
├── ab/
│   └── abcdef1234567890...svn-base    # SHA-1 = abcdef...
└── ...
```

- 文件名 = SHA-1 摘要的前两个字符作为子目录，完整摘要作为文件名
- 扩展名 `.svn-base`
- 引用计数在 PRISTINE 表中维护，为 0 时可清理

---

## 6. Work Queue（工作队列）

`WORK_QUEUE` 表实现了一个原子操作队列，确保 WC 操作的中间状态可以恢复：

```sql
CREATE TABLE WORK_QUEUE (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work BLOB NOT NULL             -- 序列化后的操作描述
);
```

每次 WC 操作（如 update、commit）会将步骤分解为 work items 写入队列。如果操作中断，`svn cleanup` 可以继续执行未完成的工作项。

实现位于 `workqueue.c`。

---

## 7. 冲突记录

冲突分为三类：

| 类型 | 存储位置 | 说明 |
|------|----------|------|
| **文本冲突** | `.mine` / `.r<N>` 文件 | 磁盘上的冲突文件 |
| **属性冲突** | `ACTUAL_NODE.prop_reject` | 属性冲突标记 |
| **树冲突** | `ACTUAL_NODE.conflict_data` | 结构性冲突（如本地删除 vs 远端修改） |

冲突处理实现位于 `conflicts.c`（152KB，WC 层最大的文件之一）。

---

## 8. 关键实现文件

| 文件 | 大小 | 说明 |
|------|------|------|
| `wc_db.c` | 593KB | 数据库操作核心（最大的文件） |
| `update_editor.c` | 222KB | 更新编辑器 |
| `wc_db_update_move.c` | 179KB | move 操作的 DB 更新 |
| `deprecated.c` | 184KB | 废弃 API 兼容层 |
| `conflicts.c` | 153KB | 冲突处理 |
| `status.c` | 108KB | 状态计算 |
| `entries.c` | 108KB | 旧版 entries 兼容 |
| `props.c` | 90KB | 属性操作 |
| `wc-metadata.sql` | 34KB | 数据库 schema |
| `wc-queries.sql` | 63KB | 预编译 SQL 语句 |

---

## 参考源码

- `libsvn_wc/wc-metadata.sql` — 完整数据库 schema
- `libsvn_wc/wc-queries.sql` — 预编译 SQL 查询
- `libsvn_wc/wc_db.h` — 数据库 API 定义（3661 行）
- `libsvn_wc/wc_db.c` — 数据库操作实现
- `libsvn_wc/wc_db_pristine.c` — Pristine 存储实现
- `libsvn_wc/update_editor.c` — Update 编辑器
- `libsvn_wc/conflicts.c` — 冲突处理
- `libsvn_wc/workqueue.c` — 工作队列处理
