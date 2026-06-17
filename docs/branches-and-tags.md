# 分支与标签（Branches and Tags）

## 1. 概述

Subversion 的分支和标签本质上就是**目录复制**。与 Git 的指针式分支不同，SVN 的分支是仓库目录树中的一个子目录，通过"廉价复制"（cheap copy）机制创建——O(1) 操作，不复制文件内容。

核心机制：
- **分支** = 仓库中的目录副本（通常是 `/branches/feature`）
- **标签** = 仓库中的目录快照（通常是 `/tags/v1.0`），约定不修改
- **廉价复制** = 只创建元数据，指向源数据的引用

源码涉及 `libsvn_fs_fs/dag.c`（DAG 层复制）和 `libsvn_client/copy.c`（客户端复制）。

---

## 2. 廉价复制（Cheap Copy）

### 2.1 实现原理

`svn_fs_fs__dag_copy()` 实现廉价复制（`dag.c`）：

```
1. 复制源节点的 node-revision 元数据
2. 分配新的 copy_id（标识复制事件）
3. 设置 copyfrom_path 和 copyfrom_rev（记录来源）
4. 创建 successor node（新 ID 指向相同的底层数据）
5. 在目标目录中设置条目指向新 ID
```

关键特性：**不复制文件内容**，只创建新的元数据引用。源和目标共享相同的 representation（数据表示）。

### 2.2 保留历史 vs 不保留

```c
if (preserve_history) {
    // 创建新 node-revision，记录 copyfrom 信息
    to_noderev->copyfrom_path = from_path;
    to_noderev->copyfrom_rev = from_rev;
} else {
    // 直接引用原 ID（不记录来源）
}
```

`svn copy` 命令始终使用 `preserve_history = TRUE`。

---

## 3. Copy-ID 追踪

### 3.1 Copy-ID 在 Node-Rev-ID 中的角色

FSFS 的 node-revision ID 结构：
```
<node_id>.<copy_id>.<txn_or_rev_id>
```

- **node_id**：节点唯一标识
- **copy_id**：复制事件标识——相同 copy_id 的节点来自同一次 copy 操作
- **txn_or_rev_id**：事务 ID 或修订号

### 3.2 Copy-ID 分配

每次 `svn copy` 操作分配一个新的递增 copy_id，通过 `svn_fs_fs__reserve_copy_id()` 获取。

### 3.3 Copy Root

`copyroot_rev` 和 `copyroot_path` 记录复制操作的根节点：

```c
typedef struct node_revision_t {
  // ...
  const char *copyfrom_path;    // 直接来源
  svn_revnum_t copyfrom_rev;    // 直接来源版本
  svn_revnum_t copyroot_rev;    // 复制根版本
  const char *copyroot_path;    // 复制根路径
  // ...
} node_revision_t;
```

---

## 4. Peg Revision 与 Operative Revision

### 4.1 问题场景

当一个文件被重命名/移动后，通过旧名称查询历史会出现歧义：

```
r1: /trunk/foo.c 创建
r5: /trunk/foo.c 重命名为 /trunk/bar.c
r10: /trunk/foo.c 又被重新创建（不同的文件）

# 查询 r1 时的 /trunk/foo.c → 是哪一个？
```

### 4.2 双修订版机制

SVN 引入两个修订版来消除歧义：

| 修订版 | 作用 | 默认值 |
|--------|------|--------|
| **Peg revision** | 定位对象的身份（"哪个对象"） | URL: HEAD, WC: BASE |
| **Operative revision** | 在已定位的对象上执行操作（"哪个时刻"） | 等于 peg |

语法：
```
svn log -r5:10 path@peg_rev
                     ↑ peg revision
          ↑ operative range
```

### 4.3 解析流程

`svn_client__resolve_rev_and_url()`（`ra.c`）：

```
1. 解析 peg revision 和 operative revision 的具体值
2. 通过 peg revision 定位对象在特定时刻的身份
3. 通过 svn_client__repos_locations() 追踪对象在 operative revision 时的 URL
   （对象可能在 operative revision 时有不同的路径名）
4. 返回解析后的 (URL, revision) 组合
```

---

## 5. 分支模型

### 5.1 标准布局

```
/repos/
├── trunk/           # 主线开发
├── branches/        # 特性分支
│   ├── feature-a/
│   └── feature-b/
└── tags/            # 标签（快照）
    ├── v1.0/
    └── v1.1/
```

### 5.2 分支操作

```
# 创建分支
svn copy ^/trunk ^/branches/feature-a -m "Create feature-a branch"

# 切换到分支
svn switch ^/branches/feature-a

# 合并回主干
svn merge --reintegrate ^/branches/feature-a
svn commit -m "Merge feature-a back to trunk"
```

### 5.3 分支 vs 标签

技术实现完全相同，区别仅在约定：
- **分支**：预期会继续修改
- **标签**：约定为只读快照

---

## 6. DAG（有向无环图）

### 6.1 不可变快照

仓库的每个修订版对应一个不可变的目录树快照。DAG 节点是不可变的 node-revision：

```
Revision 5:
  / (dir, id=1.0.r5/0)
  ├── trunk (dir, id=2.0.r3/0)      ← 未修改，复用 r3 的节点
  │   └── file.c (file, id=3.0.r5/1) ← 本修订版修改
  └── branches (dir, id=4.0.r1/0)    ← 未修改，复用 r1 的节点
```

未修改的子树直接复用前一个修订版的节点 ID（不可变性），只有修改路径上的节点创建新 ID。

### 6.2 Clone Child

`svn_fs_fs__dag_clone_child()` 将不可变子节点克隆为可变节点：
```
1. 创建 successor node（新 node_id，相同数据）
2. 替换父目录中的条目 ID
```

---

## 参考源码

- `libsvn_fs_fs/dag.c` — DAG 层廉价复制
- `libsvn_fs_fs/id.c` — Node-Rev-ID 和 copy-id
- `libsvn_client/copy.c` — 客户端复制操作
- `libsvn_client/ra.c` — Peg/Operative revision 解析
- `libsvn_fs_fs/tree.c` — DAG 树操作
