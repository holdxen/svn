# 错误处理体系

## 1. 概述

Subversion 使用链式错误结构（`svn_error_t`）来表达和传播错误。每个错误包含错误码、消息、源文件位置，并通过 `child` 指针链接到底层原因，形成类似异常调用栈的错误链。

定义于 `include/svn_types.h`（结构体）和 `include/svn_error.h`（API），错误码定义在 `include/svn_error_codes.h`。

---

## 2. svn_error_t 结构体

```c
typedef struct svn_error_t {
  apr_status_t apr_err;          // 错误码（APR 错误码或 SVN 自定义码）
  const char *message;           // 详细错误消息
  struct svn_error_t *child;     // 子错误（构成错误链）
  apr_pool_t *pool;              // 分配池
  const char *file;              // 源文件（仅 SVN_DEBUG）
  long line;                     // 源行号（仅 SVN_DEBUG）
} svn_error_t;
```

### 2.1 错误链

错误通过 `child` 指针链接，形成从外层到底层的链：

```
顶层错误 (SVN_ERR_AUTHZ_INSUFFICIENT, "Authorization failed")
  └─ child (SVN_ERR_FS_NOT_FOUND, "Can't open file 'foo'")
       └─ child (APR_ENOENT, "No such file or directory")
```

- 第一个错误是最终呈现给用户的顶层错误
- 后续错误是底层原因链
- 类似异常的"cause"链

### 2.2 Debug 模式

在 `SVN_DEBUG` 编译模式下，错误创建宏会自动记录文件名和行号：

```c
#define svn_error_create \
  (svn_error__locate(__FILE__,__LINE__), (svn_error_create))
```

非 debug 模式下 `file` 和 `line` 字段不被填充。

---

## 3. 错误码体系

### 3.1 错误码空间

SVN 错误码基于 APR 错误码空间，从 `APR_OS_START_USERERR` 开始偏移：

```
APR 错误码:  0 ~ APR_OS_START_USERERR-1
SVN 错误码:  APR_OS_START_USERERR + category * SVN_ERR_CATEGORY_SIZE + offset
```

```c
#define SVN_ERR_CATEGORY_SIZE  5000
```

### 3.2 错误码分类

| 分类 | 偏移倍数 | 前缀 | 说明 |
|------|---------|------|------|
| Bad | 1 | `SVN_ERR_BAD_*` | 输入验证错误 |
| XML | 2 | `SVN_ERR_XML_*` | XML 解析错误 |
| IO | 3 | `SVN_ERR_IO_*` | I/O 错误 |
| Stream | 4 | `SVN_ERR_STREAM_*` | 流错误 |
| Node | 5 | `SVN_ERR_NODE_*` | 节点错误 |
| Entry | 6 | `SVN_ERR_ENTRY_*` | Entry 错误（旧 WC 格式） |
| WC | 7 | `SVN_ERR_WC_*` | Working Copy 错误 |
| FS | 8 | `SVN_ERR_FS_*` | 文件系统错误 |
| Repos | 9 | `SVN_ERR_REPOS_*` | Repository 错误 |
| RA | 10 | `SVN_ERR_RA_*` | RA 通用错误 |
| RA/DAV | 11 | `SVN_ERR_RA_DAV_*` | RA/DAV 错误 |
| RA/Local | 12 | `SVN_ERR_RA_LOCAL_*` | RA/Local 错误 |
| Svndiff | 13 | `SVN_ERR_SVNDIFF_*` | Svndiff 错误 |
| APMOD | 14 | `SVN_ERR_APMOD_*` | Apache 模块错误 |
| Client | 15 | `SVN_ERR_CLIENT_*` | Client 错误 |
| Misc | 16 | `SVN_ERR_MISC_*` | 杂项错误 |
| CL | 17 | `SVN_ERR_CL_*` | 命令行错误 |
| RA/SVN | 18 | `SVN_ERR_RA_SVN_*` | RA/svn 错误 |
| AuthN | 19 | `SVN_ERR_AUTHN_*` | 认证错误 |
| AuthZ | 20 | `SVN_ERR_AUTHZ_*` | 授权错误 |
| Diff | 21 | `SVN_ERR_DIFF_*` | Diff 错误 |
| RA/Serf | 22 | `SVN_ERR_RA_SERF_*` | RA/serf 错误 |
| Malfunc | 23 | `SVN_ERR_MALFUNC_*` | Malfunction 错误 |
| X509 | 24 | `SVN_ERR_X509_*` | X.509 证书错误 |

### 3.3 分类检测

```c
#define SVN_ERROR_IN_CATEGORY(apr_err, category) \
  (((apr_err) >= APR_OS_START_USERERR + (category) * SVN_ERR_CATEGORY_SIZE) \
   && ((apr_err) < APR_OS_START_USERERR + ((category) + 1) * SVN_ERR_CATEGORY_SIZE))
```

### 3.4 APR 错误码

底层 I/O 错误使用 APR 错误码（映射到操作系统 errno）：
```
APR_ENOENT    → 文件不存在
APR_EACCES    → 权限拒绝
APR_EEXIST    → 文件已存在
```

---

## 4. 错误创建与操作 API

### 4.1 创建错误

```c
// 基本创建
svn_error_t *svn_error_create(apr_status_t apr_err,
                              svn_error_t *child,
                              const char *message);

// printf 格式化
svn_error_t *svn_error_createf(apr_status_t apr_err,
                               svn_error_t *child,
                               const char *fmt, ...);

// 包装 APR 错误
svn_error_t *svn_error_wrap_apr(apr_status_t status,
                                const char *fmt, ...);

// 快速包装（复制错误码）
svn_error_t *svn_error_quick_wrap(svn_error_t *child,
                                  const char *new_msg);

// 格式化快速包装
svn_error_t *svn_error_quick_wrapf(svn_error_t *child,
                                   const char *fmt, ...);
```

### 4.2 组合错误

```c
// 两个错误组合为一个
svn_error_t *svn_error_compose_create(svn_error_t *err1,
                                      svn_error_t *err2);

// 将 new_err 追加到 chain 末尾
void svn_error_compose(svn_error_t *chain, svn_error_t *new_err);
```

### 4.3 查询错误链

```c
// 找到最底层错误
svn_error_t *svn_error_root_cause(const svn_error_t *err);

// 在链中查找特定错误码
svn_error_t *svn_error_find_cause(const svn_error_t *err,
                                  apr_status_t apr_err);
```

### 4.4 内存管理

```c
// 深拷贝错误链
svn_error_t *svn_error_dup(const svn_error_t *err);

// 释放错误链
void svn_error_clear(svn_error_t *error);
```

---

## 5. 关键宏

### 5.1 SVN_ERR

最常用的错误传播宏——如果表达式返回错误，立即 return：

```c
#define SVN_ERR(expr)  \
  do { \
    svn_error_t *svn_err__temp = (expr); \
    if (svn_err__temp) \
      return svn_error_trace(svn_err__temp); \
  } while (0)
```

### 5.2 SVN_ERR_W

带消息包装的变体：

```c
#define SVN_ERR_W(expr, wrap_msg)  \
  do { \
    svn_error_t *svn_err__temp = (expr); \
    if (svn_err__temp) \
      return svn_error_quick_wrap(svn_err__temp, wrap_msg); \
  } while (0)
```

### 5.3 SVN_NO_ERROR

```c
#define SVN_NO_ERROR  NULL   // "无错误" 的值
```

---

## 6. 错误在协议中的传输

svn:// 协议中的错误通过 `failure` 响应传输：

```
( failure
  ( ( apr-err:number message:string file:string line:number )
    ( apr-err:number message:string file:string line:number )
    ...
  )
)
```

每个 `( apr-err message file line )` 是一个错误节点，多个节点串联表示错误链。

---

## 7. 错误处理最佳实践

```c
// 典型模式：逐步操作，每步检查
svn_error_t *err;

err = svn_io_file_open(&file, path, APR_READ, APR_OS_DEFAULT, pool);
if (err)
  return svn_error_quick_wrapf(err, "Can't open '%s'", path);

err = read_content(file, &content, pool);
if (err) {
  svn_error_clear(svn_io_file_close(file, pool));  // 清理
  return err;
}

// 确保关闭文件
return svn_io_file_close(file, pool);
```

关键原则：
1. 错误必须被处理或传播，不能忽略
2. 使用 `svn_error_clear()` 释放已处理的错误
3. 错误发生时清理已打开的资源
4. 使用 `SVN_ERR` 宏简化错误传播

---

## 参考源码

- `include/svn_types.h` — `svn_error_t` 结构体定义
- `include/svn_error.h` — 错误 API
- `include/svn_error_codes.h` — 所有错误码定义
- `libsvn_subr/error.c` — 错误实现
- `libsvn_ra_svn/marshal.c` — 协议层错误序列化
