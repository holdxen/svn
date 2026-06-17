# 合并与祖先追踪（Merge Tracking）

## 1. 概述

合并追踪是 Subversion 的核心功能之一，用于记录"哪些修订版已经从一条分支合并到了另一条分支"。这使得后续的合并可以自动跳过已合并的部分，避免重复合并和冲突。

核心机制基于 `svn:mergeinfo` 版本化属性。

源码主要位于：
- `libsvn_client/merge.c` — 合并算法实现（13019 行，SVN 最大的单个源文件之一）
- `libsvn_subr/mergeinfo.c` — mergeinfo 解析/格式化/计算

---

## 2. svn:mergeinfo 格式

### 2.1 语法

`svn:mergeinfo` 属性存储在分支根目录（或子目录）上，记录从其他路径合并进来的修订版范围。

```
revisionrange    → REVISION1 "-" REVISION2
revisionelement  → (revisionrange | REVISION) "*"
rangelist        → revisionelement ("," revisionelement)*
revisionline     → PATHNAME ":" rangelist
top              → "" | (revisionline NEWLINE)*
```

### 2.2 示例

```
/trunk:1-6,9,37-38
/trunk/foo:10
```

含义：
- 从 `/trunk` 合并了修订版 1-6、9、37-38
- 从 `/trunk/foo` 合并了修订版 10
- `*` 后缀表示 non-inheritable（不可被子目录继承）

### 2.3 解析/格式化

```c
// 解析
svn_mergeinfo_parse(mergeinfo, input, pool)
  → parse_top() → parse_revision_line() → parse_pathname() + parse_rangelist()

// 格式化
svn_mergeinfo_to_string(output, mergeinfo, pool)

// 规范化（排序 + 合并相邻范围）
svn_rangelist__canonicalize()
```

---

## 3. 核心数据结构

### 3.1 svn_merge_range_t

```c
typedef struct svn_merge_range_t {
  svn_revnum_t start;         // start < end → 正向合并; start > end → 反向合并
  svn_revnum_t end;
  svn_boolean_t inheritable;  // 是否可被子目录继承
} svn_merge_range_t;
```

### 3.2 数据类型层级

```c
svn_rangelist_t       = apr_array_header_t   // svn_merge_range_t* 的有序数组
svn_mergeinfo_t       = apr_hash_t *         // path → svn_rangelist_t*
svn_mergeinfo_catalog_t = apr_hash_t *       // path → svn_mergeinfo_t
```

层级关系：
```
Catalog (多路径的 mergeinfo 集合)
  └─ Mergeinfo (单路径的合并记录)
       └─ Rangelist (范围列表)
            └─ Range (单个范围)
```

---

## 4. 合并算法

### 4.1 公共 API 入口

```c
// 带 peg revision 的合并（最通用）
svn_client_merge_peg5()

// 重新集成合并（分支合并回主干）
svn_client_merge_reintegrate()

// 获取合并摘要
svn_client_get_merging_summary()
```

### 4.2 核心内部入口

`merge.c` 中的 `do_merge()` 函数（约 300 行参数）是所有合并操作的汇聚点。

### 4.3 合并流程

```
1. 确定源和目标的位置与修订版范围
2. 获取源的 mergeinfo 和目标的 mergeinfo
3. 计算差异范围：源范围 - 目标已有范围 = 需要合并的范围
4. 对需要合并的每个范围：
   a. 获取 diff（文本 + 属性差异）
   b. 应用到目标的 WC
   c. 处理冲突
5. 更新目标的 svn:mergeinfo 属性
6. 记录合并结果
```

### 4.4 范围合并算法

```c
// 合并两个相邻或重叠的范围
static svn_boolean_t
combine_ranges(output, in1, in2, consider_inheritance) {
  if (in1->start <= in2->end && in2->start <= in1->end) {
    if (!consider_inheritance || (in1->inheritable == in2->inheritable)) {
      output->start = MIN(in1->start, in2->start);
      output->end   = MAX(in1->end, in2->end);
      output->inheritable = (in1->inheritable || in2->inheritable);
      return TRUE;
    }
  }
  return FALSE;
}
```

---

## 5. 自动合并与分支类型

### 5.1 自动合并决策

`find_automatic_merge()` 决定合并类型：

```
1. 获取源和目标分支的完整位置历史
2. 计算最年轻共同祖先 (YCA, Youngest Common Ancestor)
3. 查找源→目标和目标→源的最新完全合并点
4. 选择 base，决定是 sync 还是 reintegrate：
   - base_on_source >= base_on_target → sync-like（正向同步）
   - base_on_source < base_on_target  → reintegrate-like（重新集成）
```

### 5.2 三种合并模式

| 模式 | 场景 | 实现 |
|------|------|------|
| **Sync** | 定期将主干变更同步到特性分支 | `do_merge()` |
| **Reintegrate** | 将完成的特性分支合并回主干 | `merge_cousins_and_supplement_mergeinfo()` |
| **Cherry-pick** | 选择性地合并特定修订版 | 指定具体范围 |

---

## 6. Mergeinfo 继承

`svn:mergeinfo` 具有继承性：子目录如果自身没有 `svn:mergeinfo`，则从最近的有该属性的祖先目录继承。

### Non-inheritable 标记

范围后的 `*` 表示该范围仅适用于当前目录，不传递给子目录：

```
/trunk:1-100*      → 仅当前目录认为 1-100 已合并
/trunk:1-100       → 子目录也认为已合并
```

---

## 7. 反向合并

`svn_merge_range_t` 中 `start > end` 表示反向合并（撤销已合并的修订版）：

```
反向合并范围 start=10, end=5 → 撤销修订版 6-10 的合并效果
```

---

## 8. 关键实现文件

| 文件 | 大小 | 说明 |
|------|------|------|
| `libsvn_client/merge.c` | 约 500KB | 合并算法（13019 行） |
| `libsvn_subr/mergeinfo.c` | 约 90KB | mergeinfo 解析/计算 |
| `include/svn_mergeinfo.h` | — | mergeinfo 公共 API |
| `libsvn_client/merge_catalog.c` | — | mergeinfo catalog 操作 |

---

## 参考源码

- `libsvn_client/merge.c` — 合并算法实现
- `libsvn_subr/mergeinfo.c` — mergeinfo 格式解析
- `include/svn_mergeinfo.h` — mergeinfo API
- `include/svn_types.h` — `svn_merge_range_t` 定义
- `libsvn_client/merge_catalog.c` — catalog 操作
