# Export Editor 实现详解

## 1. 概述

Export editor 是 `svn export` 命令的核心，负责将仓库数据写入本地文件系统（无 `.svn` 目录）。它实现了一个精简的 Ev1 Delta Editor，只关注"把文件内容正确写出来"。

源码位于 `subversion/libsvn_client/export.c`。

---

## 2. Editor 包装链

Export 不是单独工作的，从协议命令到实际磁盘写入经过 4 层 editor：

```
ra_svn driver（协议解析，分发命令）
  → depth_filter_editor（按深度过滤节点）
    → cancellation_editor（每个回调前检查取消）
      → export editor（实际写文件）
```

### 2.1 ra_svn driver 层

位于 `libsvn_ra_svn/editorp.c`，`svn_ra_svn_drive_editor2()` 实现主事件循环：

```c
while (!ds.done) {
    svn_ra_svn_read_tuple(session->conn, pool, "wl", &cmd_word, &params);
    cmd = cmd_lookup(cmd_word);        // 命令名 → handler 映射
    SVN_ERR(cmd->handler(ds, params));
}
```

支持 19 个协议命令：`set-target-revision`、`open-root`、`delete-entry`、`add-dir`、`add-file`、`open-dir`、`open-file`、`change-dir-prop`、`change-file-prop`、`close-dir`、`close-file`、`absent-dir`、`absent-file`、`apply-textdelta`、`textdelta-chunk`、`textdelta-end`、`close-edit`、`apply-textdelta-stream`。

### 2.2 depth_filter_editor

位于 `libsvn_delta/depth_filter_editor.c`。根据请求深度（empty/files/immediates/infinity）过滤节点。被过滤的节点 baton 标记 `filtered=TRUE`，`apply_textdelta` 使用 noop handler 吞掉数据。

### 2.3 cancellation_editor

位于 `libsvn_delta/cancel.c`。实现全部 15 个回调，每个回调先调用 `cancel_func` 检查用户是否取消，然后透传到下层 editor。如果 `cancel_func` 为 NULL，则不包装（直接返回原 editor）。

### 2.4 export editor

位于 `libsvn_client/export.c`，`get_editor_ev1()` 注册 8 个回调：

| 回调 | 实现函数 | 说明 |
|------|----------|------|
| `set_target_revision` | `set_target_revision` | 记录修订号 |
| `open_root` | `open_root` | 创建导出根目录 |
| `add_directory` | `add_directory` | 创建子目录 |
| `change_dir_prop` | `change_dir_prop` | 缓存 svn:externals |
| `close_directory` | `close_directory` | 释放目录 pool |
| `add_file` | `add_file` | 构建 file_baton |
| `change_file_prop` | `change_file_prop` | 缓存文件属性 |
| `apply_textdelta` | `apply_textdelta` | 创建写入流 |
| `close_file` | `close_file` | 校验 + 安装文件 |

其余回调使用 `default_editor.c` 的 no-op 实现。

---

## 3. Token 机制

ra_svn 协议是无状态的文本命令流，用 token（字符串标识符）引用节点。driver 层维护一个哈希表将 token 映射到 baton：

```c
// editorp.c
typedef struct ra_svn_driver_state_t {
    svn_delta_editor_t *editor;
    apr_hash_t *tokens;           // token(字符串) → ra_svn_edit_entry_t
    ra_svn_edit_entry_t *last_token; // 最近使用的 token（缓存）
    svn_boolean_t done;
    apr_pool_t *file_pool;
    int file_refs;
    // ...
} ra_svn_driver_state_t;
```

`store_token()` 存入哈希表并更新 `last_token` 缓存；`lookup_token()` 先查 `last_token`（大多数命令操作的是最后一个节点），miss 时查哈希表。

---

## 4. file_refs 引用计数

文件操作可能交错（多个文件的 add/apply-textdelta/chunk/close 穿插），`file_pool` 用于批量回收文件 baton 内存：

- `add_file` / `open_file` / `apply_textdelta` → `file_refs++`
- `textdelta_end` / `close_file` → 销毁 file subpool，`file_refs--`
- 当 `file_refs == 0` 时，销毁整个 `file_pool` 并重建

目录则不同：每个目录有独立 subpool，`close_directory` 时直接销毁。

---

## 5. 各回调实现详解

### 5.1 set_target_revision

```c
eb->target_revision = *rev;   // 记录到 edit_baton
```

仅记录，不做 I/O。在 `close_edit` 中用于发通知。

### 5.2 open_root

调用 `open_root_internal()` 创建导出根目录（如果不存在），构建 root baton。

### 5.3 add_directory

1. 检查路径合法性（不能是保留路径）
2. `svn_io_make_dir_recursively()` 创建目录（含中间目录）
3. 发送 `svn_wc_notify_action_add` 通知

### 5.4 change_dir_prop

只处理 `svn:externals` 属性，存入 `eb->externals` 哈希表（分配在顶层 pool 中，不受目录 pool 销毁影响）。其他所有目录属性静默忽略。

svn:externals 的实际导出被延迟到 `close_edit` 之后，在 `export_directory()` 函数末尾统一处理。

### 5.5 close_directory

销毁该目录 baton 的 subpool，释放内存。

### 5.6 add_file

只构建 `file_baton` 结构体，记录路径、URL、关键字替换信息等。**不创建任何文件**，不做 I/O。

### 5.7 change_file_prop

只缓存以下 7 个属性到 file_baton，不做 I/O：

| 属性 | 字段 | 用途 |
|------|------|------|
| `svn:eol-style` | `fb->eol_style_val` | 行尾转换（apply_textdelta 时配置） |
| `svn:keywords` | `fb->keywords_val` | 关键字替换（apply_textdelta 时配置） |
| `svn:executable` | `fb->executable_val` | 可执行权限（close_file 时设置） |
| `svn:special` | `fb->special` | 特殊文件标记 |
| `svn:entry:committed-rev` | `fb->revision` | $Rev$ 关键字值 |
| `svn:entry:committed-date` | `fb->date` | $Date$ 值 + 文件 mtime |
| `svn:entry:last-author` | `fb->author` | $Author$ 关键字值 |

其他属性（svn:mime-type、自定义属性等）静默忽略。`value == NULL`（删除属性）也忽略。

### 5.8 apply_textdelta

这是文件创建的起点。执行流程：

1. 调用 `open_working_file_writer()` 创建临时文件写入器
2. 调用 `svn_txdelta_apply2()` 设置 delta apply handler
3. 返回 handler + baton 给 driver 层

后续 `textdelta-chunk` 和 `textdelta-end` 协议命令直接操作返回的 handler，**不经过 editor 回调**。

### 5.9 close_file

1. MD5 校验：将 apply 阶段累计的 `fb->text_digest` 与服务端 `close-file` 命令中的校验和比对
2. Finalize：flush 写入流
3. Install：`svn_wc__working_file_writer_install()` 将临时文件 rename 到目标路径
4. 设置 mtime（使用 `svn:entry:committed-date`）

---

## 6. 文件写入管线

### 6.1 数据流全景

```
textdelta-chunk 原始字节（TCP）
    ↓
svn_txdelta_parse_svndiff()       ← ra_svn 层：svndiff → delta windows
    ↓
svn_txdelta_apply2()              ← window handler：空 base + delta → fulltext
    │                               同时累计 MD5 → fb->text_digest
    ↓
svn_subst_stream_translated()     ← writer 翻译层：EOL 转换 + 关键字展开
    ↓
apr_file_write()                  ← 写入临时文件
```

### 6.2 临时文件创建

在 `open_working_file_writer()` 中，通过 `svn_dirent_dirname(fb->path)` 取得目标文件所在目录，在该目录下创建临时文件。

临时文件名生成逻辑（`io.c` 中 `temp_file_create()`）：

| 平台 | 方式 | 示例 |
|------|------|------|
| Unix/macOS/Linux | `svn-XXXXXX` 模板 + `mkstemp()` | `svn-a3Bf9K` |
| Windows | `(GetTickCount()<<11) + 7*atomic_inc + PID` 格式化为十六进制 | `svn-1A2B3C` |

临时文件创建在目标文件**同级目录**，保证 close_file 的 rename 是同一文件系统上的原子操作。

### 6.3 文件安装（rename）

调用链：`svn_wc__working_file_writer_install` → `svn_stream__install_stream` → `svn_io_file_rename2`

| 平台 | 最终 API |
|------|----------|
| macOS/Linux | `apr_file_rename()` → POSIX `rename()` |
| Windows | `win32_file_rename()` → `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` |

Windows 还有一个优化：文件还打开时先尝试 `svn_io__win_rename_open_file`（对打开句柄 rename），失败才退化为 close + rename。

---

## 7. 关键字替换系统

关键字替换分两步：**构建值表** + **流式扫描替换**。

### 7.1 构建关键字值表

`svn_subst_build_keywords3()`（`subst.c`）解析 `svn:keywords` 字符串（如 `"Rev Author Date"`），按空格分割，对每个关键字调用 `keyword_printf()` 生成值。

格式符号表：

| 符号 | 含义 | 示例 |
|------|------|------|
| `%r` | revision 号 | `1234` |
| `%a` | author | `john` |
| `%d` | 短日期 | `2024-01-15 10:30:00Z` |
| `%D` | 长日期 | `2024-01-15 10:30:00 +0000 (...)` |
| `%u` | URL | `svn://server/trunk/main.c` |
| `%b` | basename | `main.c` |
| `%P` | repos 相对路径 | `trunk/main.c` |
| `%R` | repos root | `svn://server` |
| `%_` | 空格 | |

每个标准关键字注册多个别名（如 `Rev` = `Revision` = `LastChangedRevision`），大小写不敏感。

### 7.2 流式扫描替换

`translate_chunk()`（`subst.c`）是一个**逐字节状态机**，通过 `translation_baton` 维护跨 chunk 状态：

```c
struct translation_baton {
    const char *eol_str;           // 目标行尾
    apr_hash_t *keywords;          // 关键字值表
    char interesting[256];         // '$'、'\r'、'\n' 标记为 TRUE
    char newline_buf[2];           // 行尾状态缓存
    apr_size_t newline_off;
    char keyword_buf[255];         // 关键字缓冲（$ 到 $ 之间）
    apr_size_t keyword_off;
};
```

核心循环：

1. **普通字符**（`interesting[ch] == FALSE`）→ 大块 memcpy 直接写出
2. **遇到 `$`** → 进入关键字缓冲模式，继续缓冲直到第二个 `$` 或换行
   - 遇到 `$` → `match_keyword()` 检查是否已知关键字
   - 匹配 → `translate_keyword_subst()` 原地替换
   - 不匹配 → 原样写出
3. **遇到 `\r` / `\n`** → 替换为配置的 `eol_str`

关键字替换支持两种格式：

| 格式 | 未展开 | 展开 |
|------|--------|------|
| 可变长度 | `$Rev$` | `$Rev: 1234 $` |
| 固定长度 | `$Rev::       $` | `$Rev:: 1234  $`（超长用 `#` 截断） |

### 7.3 跨 svndiff 窗口状态保持

`translation_baton` 持久化在翻译流上，跨所有 textdelta-chunk 和 svndiff window 保持状态。如果一个关键字被 svndiff window 切断（如 `$Rev` 在窗口 1，`: 1234 $` 在窗口 2），baton 的 `keyword_buf` 和 `keyword_off` 会保留中间状态，在下一个 chunk 到达时继续处理。

行尾也有同样保护：`\r\n` 的 `\r` 如果在窗口末尾，`newline_buf` 会缓存它等待 `\n`。

### 7.4 MD5 校验时机

MD5 在翻译层**之前**计算。`svn_txdelta_apply2` 的第三个参数 `fb->text_digest` 接收 apply 阶段产出的原始 fulltext 的 MD5，不包含 EOL 转换和关键字展开。这样校验的是仓库中存储的真实内容，不受平台差异影响。

---

## 8. 为什么不需要 open_directory 和 open_file

Export 的 reporter 使用 `start_empty=TRUE` 报告空基线，告诉服务端"我本地什么都没有"。因此服务端只会发送 `add-directory` 和 `add-file`，不会发送 `open-directory` 和 `open-file`。

这两个回调使用 `default_editor.c` 的 no-op 实现即可。

---

## 9. 关键实现文件

| 文件 | 说明 |
|------|------|
| `libsvn_client/export.c` | export editor 主实现 |
| `libsvn_ra_svn/editorp.c` | ra_svn 协议驱动层 |
| `libsvn_delta/cancel.c` | cancellation editor |
| `libsvn_delta/depth_filter_editor.c` | 深度过滤 editor |
| `libsvn_delta/default_editor.c` | 默认 no-op editor |
| `libsvn_subr/subst.c` | 关键字替换 + EOL 转换 |
| `libsvn_subr/io.c` | 临时文件创建、rename |
| `libsvn_subr/stream.c` | install stream（临时文件写入） |
| `libsvn_wc/working_file_writer.c` | 文件写入器封装 |
