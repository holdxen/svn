# 修订版（Revision）语义

## 1. 概述

修订版（Revision）是 Subversion 版本控制的核心概念。每次成功提交产生一个新的修订版，修订版号全局递增。修订版是整个仓库的原子快照——不是单个文件的版本号。

定义于 `include/svn_types.h`，核心类型 `svn_revnum_t`。

---

## 2. 修订版号

### 2.1 类型定义

```c
typedef long int svn_revnum_t;
#define SVN_INVALID_REVNUM ((svn_revnum_t) -1)
```

修订版号从 0 开始，每次 +1。

### 2.2 全局性

**关键特性**：修订版号是仓库级的，不是文件级的。

```
r1: 添加 /trunk/README
r2: 修改 /trunk/src/main.c
r3: 添加 /branches/feature
```

每个修订版包含仓库中所有路径在该时刻的完整状态。文件没有独立的版本号——一个文件的"最后修改版本"是最近一次修改它的仓库修订版。

### 2.3 原子性

一次 commit 产生一个修订版，包含所有变更。不存在"半个修订版"——要么全部成功，要么全部回滚。

---

## 3. Revision 0

### 3.1 特殊性

Revision 0 是空仓库的初始修订版，在 `svnadmin create` 时自动创建：

```
r0:
  / (dir, empty)
```

- 只有一个空根目录
- 没有文件内容
- 所有后续操作基于 r0 开始

### 3.2 在协议中的表示

```
svn_revnum_t = -1 → SVN_INVALID_REVNUM（"无修订版"）
svn_revnum_t = 0  → Revision 0
```

协议中使用 Number 类型传输，`-1` 表示无效/未指定。

---

## 4. 不可变修订版

### 4.1 核心不变性

一旦提交的修订版**永不修改**：
- 文件内容不可变
- 目录结构不可变
- 节点属性不可变

唯一例外是**修订属性**（revprops），如 `svn:log` 可以通过 `svn propset --revprop` 修改。

### 4.2 实现保障

FSFS 层面：
- Revision 文件写入后以只读模式打开
- `write-lock` 文件保护写入操作
- 新修订版只能追加，不能修改已有修订版

### 4.3 Mixed-Revision Working Copy

工作副本可以是混合修订版的——不同文件/目录可以处于不同修订版：

```
wc/
├── README        (r10)
├── src/
│   └── main.c    (r15)  ← 单独 update 了这个文件
└── lib/
    └── utils.c   (r8)   ← 这个文件还没 update
```

`svn update` 将整个 WC 同步到同一修订版。

---

## 5. 修订版引用方式

### 5.1 关键字

| 关键字 | 说明 |
|--------|------|
| `HEAD` | 仓库中最新的修订版 |
| `BASE` | 工作副本中节点的 BASE 修订版 |
| `COMMITTED` | 节点最后一次修改的修订版 |
| `PREV` | COMMITTED - 1 |

### 5.2 数字修订版

```
svn log -r100           # 修订版 100
svn log -r100:200       # 修订版 100 到 200
svn log -r{2024-01-15}  # 按日期查找
svn log -rHEAD          # 最新修订版
svn log -rBASE:HEAD     # 从 BASE 到 HEAD
```

### 5.3 Peg Revision 语法

```
path@REV    # 使用 @ 后缀指定 peg revision
```

---

## 6. 修订版的内部结构

### 6.1 FSFS 中的修订版数据

每个修订版包含：

```
Revision N:
  ├── Representations    # 文件内容和属性的存储块
  ├── Node-Revisions     # 每个被修改节点的元数据
  ├── Changed Paths      # 本修订版中变更的路径列表
  └── Trailer            # 索引/偏移信息
```

### 6.2 Changed Paths

记录本修订版中哪些路径发生了变化：

```c
typedef struct change_t {
  svn_string_t path;
  svn_fs_path_change2_t info;  // 变更类型（add/delete/replace/modify）
} change_t;
```

变更类型：
| 类型 | 说明 |
|------|------|
| `svn_fs_path_change_modify` | 修改内容或属性 |
| `svn_fs_path_change_add` | 新增 |
| `svn_fs_path_change_delete` | 删除 |
| `svn_fs_path_change_replace` | 替换（删后加） |
| `svn_fs_path_change_reset` | 重置 |

### 6.3 修订版属性

每个修订版附带不可变属性（除 revprop 外）：

| 属性 | 说明 |
|------|------|
| `svn:author` | 提交者 |
| `svn:date` | 提交时间（ISO 8601） |
| `svn:log` | 日志消息 |

存储在 FSFS 的 `db/revprops/` 目录中。

---

## 7. 修订版在协议中的使用

### 7.1 svn:// 协议

```
get-latest-rev  →  ( rev:number )     # 获取最新修订版号
get-dated-rev   →  ( rev:number )     # 按日期获取
rev-proplist    →  ( proplist )        # 获取修订版属性
```

修订版号通过 Number 类型传输（无符号 64 位），`-1` 表示 `SVN_INVALID_REVNUM`。

### 7.2 编辑器命令

```
open-root     ( [rev:number] root-token )   # rev = 基础修订版
open-file     ( path dir-token file-token rev:number )   # rev = 文件的基础修订版
target-rev    ( rev:number )   # 目标修订版
```

---

## 参考源码

- `include/svn_types.h` — `svn_revnum_t` 定义
- `libsvn_fs_fs/fs_fs.c` — current 文件读写
- `libsvn_fs_fs/low_level.c` — 修订版文件解析
- `libsvn_fs_fs/revprops.c` — 修订版属性
- `include/svn_opt.h` — 修订版解析（日期、关键字）
