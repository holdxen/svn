# RA 层抽象与模块化

## 1. 概述

RA（Repository Access）层是 Subversion 中统一远程仓库访问的抽象层。它定义了一套标准接口，屏蔽不同协议（svn://、http://、file://）的差异，让上层 client 代码可以用统一方式操作任何仓库。

源码位于 `subversion/libsvn_ra/`，三种 RA 实现分别在 `libsvn_ra_svn/`、`libsvn_ra_serf/`、`libsvn_ra_local/`。

---

## 2. 核心接口

### 2.1 svn_ra_session_t

```c
struct svn_ra_session_t {
  const svn_ra__vtable_t *vtable;       // 指向具体 RA 实现的虚表
  svn_cancel_func_t cancel_func;         // 取消函数
  void *cancel_baton;                    // 取消函数的 baton
  apr_pool_t *pool;                      // 内存池
  void *priv;                            // RA 实现私有数据
};
```

### 2.2 svn_ra__vtable_t（虚表）

每个 RA 实现必须提供完整的虚表，定义于 `ra_loader.h`：

```c
typedef struct svn_ra__vtable_t {
  const svn_version_t *(*get_version)(void);
  const char *(*get_description)(apr_pool_t *pool);
  const char * const *(*get_schemes)(apr_pool_t *pool);

  // 会话管理
  svn_error_t *(*open_session)(...);
  svn_error_t *(*dup_session)(...);
  svn_error_t *(*reparent)(...);
  svn_error_t *(*get_session_url)(...);

  // 修订版操作
  svn_error_t *(*get_latest_revnum)(...);
  svn_error_t *(*get_dated_revision)(...);
  svn_error_t *(*change_rev_prop)(...);
  svn_error_t *(*rev_proplist)(...);
  svn_error_t *(*rev_prop)(...);

  // 仓库操作
  svn_error_t *(*get_commit_editor)(...);
  svn_error_t *(*get_file)(...);
  svn_error_t *(*get_dir)(...);
  svn_error_t *(*get_mergeinfo)(...);

  // 报告操作（触发 editor 回调）
  svn_error_t *(*do_update)(...);
  svn_error_t *(*do_switch)(...);
  svn_error_t *(*do_status)(...);
  svn_error_t *(*do_diff)(...);

  // 日志和路径追踪
  svn_error_t *(*get_log)(...);
  svn_error_t *(*check_path)(...);
  svn_error_t *(*stat)(...);
  svn_error_t *(*get_locations)(...);
  svn_error_t *(*get_location_segments)(...);
  svn_error_t *(*get_file_revs)(...);

  // 锁管理
  svn_error_t *(*get_locks)(...);
  svn_error_t *(*lock)(...);
  svn_error_t *(*unlock)(...);

  // 重放
  svn_error_t *(*replay)(...);
  svn_error_t *(*replay_range)(...);

  // 继承属性
  svn_error_t *(*get_inherited_props)(...);

  // ... 更多操作
} svn_ra__vtable_t;
```

---

## 3. RA 实现注册与加载

### 3.1 静态注册表

`ra_loader.c` 维护一个静态的 RA 库注册表：

```c
static const struct ra_lib_defn {
  const char *ra_name;
  const char * const *schemes;
  svn_ra__init_func_t initfunc;
  svn_ra_init_func_t compat_initfunc;
} ra_libraries[] = {
  { "svn",   svn_schemes,   svn_ra_svn__init,   svn_ra_svn__compat_init   },
  { "local", local_schemes, svn_ra_local__init,  svn_ra_local__compat_init },
  { "serf",  dav_schemes,   svn_ra_serf__init,   svn_ra_serf__compat_init  },
  { NULL }
};
```

### 3.2 URL scheme 映射

```c
static const char * const dav_schemes[]   = { "http", "https", NULL };
static const char * const svn_schemes[]   = { "svn", NULL };
static const char * const local_schemes[] = { "file", NULL };
```

### 3.3 加载流程

```
svn_ra_open4(url, ...)
  → 解析 URL scheme
  → 在 ra_libraries 表中查找匹配
  → 如果是静态链接：直接调用 initfunc
  → 如果是动态链接：svn_dso_load("libsvn_ra_<name>-<version>.so")
     → 查找 svn_ra_<name>__init 符号
  → 调用 vtable->open_session()
  → 返回 svn_ra_session_t
```

---

## 4. 三种 RA 实现

### 4.1 ra_svn（svn:// 协议）

| 项目 | 内容 |
|------|------|
| 目录 | `libsvn_ra_svn/` |
| 主要文件 | `client.c`（主 vtable）、`marshal.c`（序列化）、`cram.c`（CRAM-MD5） |
| 传输 | TCP socket，端口 3690 |
| 协议 | SVN 自定义二进制协议 |
| 隧道 | 支持 `svn+ssh://` |

虚表定义在 `client.c` 的 `ra_svn_vtable`。

### 4.2 ra_serf（http/https 协议）

| 项目 | 内容 |
|------|------|
| 目录 | `libsvn_ra_serf/` |
| 主要文件 | `serf.c`（主 vtable）、`commit.c`、`update.c`、`log.c`、`merge.c` |
| 传输 | HTTP/1.1 或 HTTP/2，基于 Apache Serf 异步库 |
| 协议 | WebDAV + DeltaV + SVN 自定义扩展 |
| 版本 | HTTP v1（经典 DeltaV）+ HTTP v2（精简协议） |

虚表定义在 `serf.c` 的 `serf_vtable`。文件数量最多（33 个 .c 文件）。

### 4.3 ra_local（file:// 协议）

| 项目 | 内容 |
|------|------|
| 目录 | `libsvn_ra_local/` |
| 主要文件 | `ra_plugin.c`（主 vtable）、`split_url.c`（路径解析） |
| 传输 | 无网络传输，直接调用 FS 层 API |
| 限制 | 只能访问本地文件系统上的仓库 |

虚表定义在 `ra_plugin.c`。最简单的实现（仅 4 个 .c 文件）。

---

## 5. RA 公共 API

`include/svn_ra.h` 定义了面向 client 层的公共 API：

```c
// 会话管理
svn_ra_open4()
svn_ra_reparent()
svn_ra_get_session_url()

// 修订版
svn_ra_get_latest_revnum()
svn_ra_get_dated_revision()

// 属性
svn_ra_rev_proplist()
svn_ra_rev_prop()
svn_ra_change_rev_prop2()

// 仓库操作
svn_ra_get_file()
svn_ra_get_dir()
svn_ra_get_mergeinfo()

// 报告操作
svn_ra_do_update3()     // 返回 reporter + editor
svn_ra_do_switch3()
svn_ra_do_status2()
svn_ra_do_diff3()

// 提交
svn_ra_get_commit_editor3()

// 日志
svn_ra_get_log2()

// 锁
svn_ra_get_locks()

// 重放
svn_ra_replay_range2()
```

---

## 6. RA 层如何屏蔽协议差异

### 6.1 Report 机制统一

所有 RA 实现都将 `do_update`/`do_switch`/`do_status`/`do_diff` 统一为：
1. 返回一个 `reporter` 对象（`svn_ra_reporter3_t`）
2. 客户端通过 reporter 描述工作副本状态
3. 完成后，服务端通过编辑器回调推送变更

### 6.2 Ev2 统一

新的 RA 实现可以直接提供 Ev2 编辑器接口（`svn_ra__get_commit_ev2()`），通过 compat shim 与 Ev1 兼容。

---

## 参考源码

- `include/svn_ra.h` — RA 公共 API
- `libsvn_ra/ra_loader.h` — 内部虚表定义
- `libsvn_ra/ra_loader.c` — 加载和分发逻辑
- `libsvn_ra_svn/client.c` — ra_svn 实现
- `libsvn_ra_serf/serf.c` — ra_serf 实现
- `libsvn_ra_local/ra_plugin.c` — ra_local 实现
