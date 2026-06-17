# 编辑器 API（Delta Editor）

## 1. 概述

编辑器 API 是 Subversion 中描述目录树增量修改的统一抽象。它定义了"如何表达一棵目录树的变化"，是连接协议层（svn://、http://）与存储层（FSFS、WC）的桥梁。

Subversion 有两代编辑器 API：
- **Ev1**（`svn_delta_editor_t`）：经典版本，使用 token/baton 机制，与 svn:// 协议一一对应
- **Ev2**（`svn_editor_t`）：1.8 引入的简化版，使用路径直接引用，有显式 copy/move 操作

两者通过 compat shim 互转。

源码位于 `subversion/libsvn_delta/`，头文件定义在 `include/svn_delta.h`（Ev1）和 `include/private/svn_editor.h`（Ev2）。

---

## 2. Ev1：svn_delta_editor_t

### 2.1 回调函数列表

`svn_delta_editor_t` 包含 17 个回调函数指针（`svn_delta.h`）：

| 序号 | 回调 | 说明 |
|------|------|------|
| 1 | `set_target_revision` | 设置目标修订号（最先调用） |
| 2 | `open_root` | 打开根目录，返回 root_baton |
| 3 | `delete_entry` | 删除目录条目 |
| 4 | `add_directory` | 添加子目录（可带 copyfrom） |
| 5 | `open_directory` | 打开已有子目录进行修改 |
| 6 | `change_dir_prop` | 修改目录属性 |
| 7 | `close_directory` | 关闭目录 |
| 8 | `absent_directory` | 标记目录为 absent（authz 限制） |
| 9 | `add_file` | 添加文件（可带 copyfrom） |
| 10 | `open_file` | 打开已有文件进行修改 |
| 11 | `apply_textdelta` | 应用文本 delta（返回 window handler） |
| 12 | `change_file_prop` | 修改文件属性 |
| 13 | `close_file` | 关闭文件（可带 checksum） |
| 14 | `absent_file` | 标记文件为 absent |
| 15 | `close_edit` | 编辑完成 |
| 16 | `abort_edit` | 中止编辑 |
| 17 | `apply_textdelta_stream` | 流式 delta（1.10 新增） |

### 2.2 Baton 机制

每个 `add_directory` / `open_directory` / `add_file` / `open_file` 调用都通过输出参数返回一个 `void *baton`。后续对该节点的所有操作都通过 baton 引用，而不是路径。

```
open_root(edit_baton) → root_baton
  └─ add_directory("trunk", root_baton) → dir_baton
       ├─ add_file("trunk/README", dir_baton) → file_baton
       │    ├─ apply_textdelta(file_baton) → handler, handler_baton
       │    │    └─ handler(window, handler_baton) × N
       │    └─ close_file(file_baton, checksum)
       └─ close_directory(dir_baton)
```

### 2.3 调用顺序约束

Ev1 有严格的目录排序规则：
- **目录优先**：必须先 close 所有子节点，才能 close 父目录
- **深度优先**：同一层级的兄弟节点按任意顺序处理
- **先删后加**：`delete_entry` 通常在 `add_*` / `open_*` 之前

### 2.4 文本 Delta 流

`apply_textdelta` 返回一个 `svn_txdelta_window_handler_t`，驱动方逐窗口发送 `svn_txdelta_window_t`：

```c
typedef struct svn_txdelta_window_t {
  apr_size_t sview_offset;       // 源视图偏移
  apr_size_t sview_len;          // 源视图长度
  apr_size_t tview_len;          // 目标视图长度
  apr_size_t num_ops;            // 指令数量
  apr_size_t new_data_len;       // 新增数据长度
  const svn_txdelta_op_t *ops;   // 指令数组
  svn_string_t *new_data;        // 新增数据
} svn_txdelta_window_t;
```

发送 `NULL` 窗口表示结束。

---

## 3. Ev2：svn_editor_t

### 3.1 回调函数列表

Ev2 有 12 个回调（`svn_editor.h`），封装在 `svn_editor_cb_many_t` 中：

| 回调 | 说明 |
|------|------|
| `cb_add_directory` | 添加目录 |
| `cb_add_file` | 添加文件 |
| `cb_add_symlink` | 添加符号链接 |
| `cb_add_absent` | 添加 absent 节点 |
| `cb_alter_directory` | 修改目录（属性） |
| `cb_alter_file` | 修改文件（内容 + 属性） |
| `cb_alter_symlink` | 修改符号链接 |
| `cb_delete` | 删除节点 |
| `cb_copy` | 复制节点（一等公民！） |
| `cb_move` | 移动/重命名节点（一等公民！） |
| `cb_complete` | 编辑完成 |
| `cb_abort` | 中止编辑 |

### 3.2 Ev1 vs Ev2 的核心差异

| 特性 | Ev1 | Ev2 |
|------|-----|-----|
| 节点引用 | baton（void*） | relpath（字符串） |
| Copy | `add_directory(path, copyfrom)` | `cb_copy(src, dst)` |
| Move | 无直接支持（delete + add） | `cb_move(src, dst)` 一等公民 |
| Symlink | `add_file` + `svn:special` | `cb_add_symlink` 独立操作 |
| Once Rule | 无 | 每个路径最多被 add/alter/delete 一次 |
| 取消机制 | 通过 cancellation editor 包装 | 集成在 `svn_editor_t` 中 |
| 目录排序 | 深度优先，先 close 子节点 | 无特定顺序要求 |

### 3.3 Once Rule

Ev2 的"单次引用规则"：在一次编辑过程中，每个 relpath 最多被 `add`/`alter`/`delete`/`copy`/`move` 中的一个操作引用。这简化了编辑器的实现，但要求驱动方在发送前合并对同一路径的多次修改。

---

## 4. 编辑器组合模式

编辑器可以串联（装饰器模式），实现功能叠加：

```
原始编辑器 (wc update editor)
  └─ 被 depth filter editor 包装（过滤深度）
       └─ 被 cancellation editor 包装（检查取消）
            └─ 被 ambient depth filter editor 包装（WC 深度过滤）
```

### 4.1 内置包装编辑器

| 编辑器 | 文件 | 用途 |
|--------|------|------|
| Cancellation editor | `cancel.c` | 在每个回调前检查取消标志 |
| Depth filter editor | `depth_filter_editor.c` | 按请求深度过滤操作 |
| Ambient depth filter | `ambient_depth_filter_editor.c` | 按 WC 实际深度过滤 |
| Debug editor | `debug_editor.c` | 打印所有回调调用 |

### 4.2 默认编辑器模板

`svn_delta_default_editor()` 创建一个全 no-op 的编辑器模板，然后覆盖需要的回调：

```c
svn_delta_editor_t *editor = svn_delta_default_editor(pool);
editor->open_root = my_open_root;
editor->add_file = my_add_file;
// ...
```

### 4.3 Ev1 ↔ Ev2 Shim

`compat.c` 提供双向兼容层：

```c
// Ev1 → Ev2
svn_delta__editor_from_editor()

// Ev2 → Ev1
svn_delta__delta_from_editor()

// 双向 shim 插入
svn_editor__insert_shims()
```

---

## 5. 编辑器的实际使用

### 5.1 Checkout/Update

```
RA 层（驱动方） → Update Editor（消费方 = WC 层）

服务端发送编辑器命令 → RA 层翻译为回调 → WC 层执行写磁盘操作
```

### 5.2 Commit

```
WC 层（驱动方） → FS 编辑器（消费方 = 仓库层）

WC 遍历本地修改 → 转换为编辑器回调 → FS 层执行写入仓库
```

### 5.3 编辑器链

```
Commit 场景:
  client → authz editor → fs commit editor → FSFS

Update 场景:
  RA → cancellation editor → depth filter → WC update editor
```

---

## 6. 关键实现文件

| 文件 | 说明 |
|------|------|
| `include/svn_delta.h` | Ev1 公共 API |
| `include/private/svn_editor.h` | Ev2 私有 API |
| `libsvn_delta/editor.c` | Ev2 实现 |
| `libsvn_delta/compat.c` | Ev1 ↔ Ev2 兼容层 |
| `libsvn_delta/default_editor.c` | 默认 no-op 编辑器 |
| `libsvn_delta/cancel.c` | 取消包装编辑器 |
| `libsvn_delta/text_delta.c` | 文本 delta 流处理 |
| `libsvn_delta/svndiff.c` | svndiff 编解码 |
| `libsvn_delta/xdelta.c` | xdelta 算法 |
| `libsvn_delta/path_driver.c` | 基于路径的编辑器驱动 |

---

## 参考源码

- `include/svn_delta.h` — Ev1 编辑器 API 定义
- `include/private/svn_editor.h` — Ev2 编辑器 API 定义
- `libsvn_delta/editor.c` — Ev2 实现
- `libsvn_delta/compat.c` — 兼容层
- `libsvn_wc/update_editor.c` — WC 更新编辑器（消费方）
- `subversion/libsvn_fs_fs/tree.c` — FS 编辑器（消费方）
