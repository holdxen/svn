# Subversion 属性系统

## 1. 概述

属性（Properties）是 Subversion 中附加在节点（文件/目录）或修订版上的键值对元数据。属性系统是 SVN 许多核心功能的基础：合并追踪（`svn:mergeinfo`）、行尾转换（`svn:eol-style`）、外部引用（`svn:externals`）等都通过属性实现。

属性定义于 `include/svn_props.h`，分类逻辑在 `libsvn_subr/properties.c`。

---

## 2. 两种属性类型

### 2.1 节点属性（Node Properties）

附加在文件或目录节点上，参与版本控制：

```c
// svn_props.h 定义的内置节点属性
#define SVN_PROP_PREFIX       "svn:"

// 可见版本化属性
#define SVN_PROP_MIME_TYPE       "svn:mime-type"       // 文件 MIME 类型
#define SVN_PROP_IGNORE          "svn:ignore"           // 目录忽略模式
#define SVN_PROP_EOL_STYLE       "svn:eol-style"        // 行尾风格
#define SVN_PROP_KEYWORDS        "svn:keywords"         // 关键字替换
#define SVN_PROP_EXECUTABLE      "svn:executable"       // 可执行标志
#define SVN_PROP_NEEDS_LOCK      "svn:needs-lock"       // 需要锁定
#define SVN_PROP_SPECIAL         "svn:special"          // 特殊文件（符号链接）
#define SVN_PROP_EXTERNALS       "svn:externals"        // 外部引用
#define SVN_PROP_MERGEINFO       "svn:mergeinfo"        // 合并历史
```

### 2.2 修订属性（Revision Properties）

附加在修订版上，不参与版本控制（可随时修改）：

```c
#define SVN_PROP_REVISION_AUTHOR       "svn:author"       // 提交者
#define SVN_PROP_REVISION_LOG          "svn:log"          // 日志消息
#define SVN_PROP_REVISION_DATE         "svn:date"         // 提交日期
#define SVN_PROP_REVISION_ORIG_DATE    "svn:original-date" // 原始日期
```

| 特性 | 节点属性 | 修订属性 |
|------|----------|----------|
| 附加对象 | 文件/目录 | 修订版 |
| 版本控制 | 是（每个修订版可不同） | 否（直接修改） |
| 修改方式 | 通过 commit | 通过 `svn propset --revprop` |
| 存储位置 | FSFS 的 representation | FSFS 的 revprops 文件 |

---

## 3. 属性命名空间分类

`svn_property_kind2()` 函数将属性名分为三类：

```c
svn_prop_kind_t svn_property_kind2(const char *prop_name);
```

| 类型 | 前缀 | 说明 | 示例 |
|------|------|------|------|
| `svn_prop_regular_kind` | `svn:` 或无前缀 | 常规版本化属性 | `svn:mime-type`, `myprop` |
| `svn_prop_wc_kind` | `svn:wc:` | WC 内部属性 | `svn:wc:dav_url` |
| `svn_prop_entry_kind` | `svn:entry:` | entries 文件属性 | `svn:entry:committed-rev` |

### 3.1 WC 内部属性（不可见）

```c
#define SVN_PROP_WC_PREFIX     "svn:wc:"
#define SVN_PROP_ENTRY_PREFIX  "svn:entry:"
```

这些属性由工作副本内部使用，用户不可直接操作。

---

## 4. 关键内置属性详解

### 4.1 svn:eol-style

控制行尾转换：

| 值 | 说明 |
|----|------|
| `native` | 检出时使用操作系统原生行尾（Windows=CR LF, Unix=LF） |
| `LF` | 强制使用 LF |
| `CR` | 强制使用 CR |
| `CRLF` | 强制使用 CR LF |

### 4.2 svn:keywords

关键字替换，支持：

| 关键字 | 展开格式 |
|--------|----------|
| `Rev` / `Revision` | `$Rev: 42 $` |
| `Author` | `$Author: alice $` |
| `Date` | `$Date: 2024-01-15 10:30:00 +0800 $` |
| `URL` / `HeadURL` | `$URL: svn://host/repos/trunk/file.c $` |
| `Id` | 以上全部的组合 |

### 4.3 svn:executable / svn:needs-lock / svn:special

布尔属性，值为 `*`（`SVN_PROP_BOOLEAN_TRUE`）：

```c
#define SVN_PROP_BOOLEAN_TRUE "*"
```

### 4.4 svn:externals

跨仓库引用机制。支持 6 种格式：

```
# 旧格式（不支持 peg revision）
DIR URL
DIR -rN URL
DIR -r N URL

# 新格式（支持 peg revision）
URL DIR
-rN URL DIR
-r N URL DIR
```

解析实现：`externals.c` 的 `svn_wc__parse_externals_description()`。

### 4.5 svn:ignore / svn:global-ignores

```
svn:ignore          # 目录级忽略（仅当前目录）
svn:global-ignores  # 可继承的全局忽略（1.8+）
```

### 4.6 svn:auto-props

可继承的自动属性（1.8+），格式类似 `config` 文件的 `auto-props` 段：

```
*.c = svn:eol-style=native
*.h = svn:eol-style=native;svn:keywords=Id
```

---

## 5. 属性适用范围

不同属性适用于不同类型的节点：

| 属性 | 文件 | 目录 |
|------|------|------|
| `svn:mime-type` | ✓ | ✗ |
| `svn:eol-style` | ✓ | ✗ |
| `svn:keywords` | ✓ | ✗ |
| `svn:executable` | ✓ | ✗ |
| `svn:needs-lock` | ✓ | ✗ |
| `svn:special` | ✓ | ✗ |
| `svn:ignore` | ✗ | ✓ |
| `svn:global-ignores` | ✗ | ✓ |
| `svn:auto-props` | ✗ | ✓ |
| `svn:externals` | ✗ | ✓ |
| `svn:mergeinfo` | ✓ | ✓ |

定义于 `properties.c`：
```c
#define SVN_PROP__NODE_DIR_ONLY_PROPS  SVN_PROP_IGNORE, SVN_PROP_INHERITABLE_IGNORES, ...
#define SVN_PROP__NODE_FILE_ONLY_PROPS SVN_PROP_MIME_TYPE, SVN_PROP_EOL_STYLE, ...
#define SVN_PROP__NODE_COMMON_PROPS    SVN_PROP_MERGEINFO, ...
```

---

## 6. 继承属性（Inherited Props）

### 6.1 概念

1.8 引入的继承属性机制。某些属性（`svn:mergeinfo`、`svn:auto-props`、`svn:global-ignores`）可以从祖先目录继承。

```
/repos/trunk/           svn:mergeinfo = /branches/feature:1-100
/repos/trunk/src/       没有 svn:mergeinfo → 继承父目录的值
/repos/trunk/src/lib/   没有 svn:mergeinfo → 继承祖父目录的值
```

### 6.2 数据结构

```c
typedef struct svn_prop_inherited_item_t {
  const char *path_or_url;     // 继承来源的路径/URL
  apr_hash_t *prop_hash;       // 属性名 → 属性值
} svn_prop_inherited_item_t;
```

### 6.3 获取方式

```c
svn_ra_get_inherited_props(session, &iprops, path, revision, pool);
```

对于旧服务端（不支持 `inherited-props` 能力），客户端通过 `svn_ra__get_inherited_props_walk()` 逐层向上爬取。

---

## 7. 事务属性（Ephemeral Transaction Props）

提交过程中的临时属性，不会被持久化到修订版：

```c
#define SVN_PROP_TXN_PREFIX                "svn:txn-"
#define SVN_PROP_TXN_CLIENT_COMPAT_VERSION "svn:txn-client-compat-version"
#define SVN_PROP_TXN_USER_AGENT            "svn:txn-user-agent"
```

---

## 参考源码

- `include/svn_props.h` — 所有属性常量定义
- `libsvn_subr/properties.c` — 属性分类和验证
- `libsvn_wc/externals.c` — svn:externals 解析
- `libsvn_wc/props.c` — WC 层属性操作
- `libsvn_wc/translate.c` — EOL/关键字转换
- `libsvn_ra/ra_loader.c` — 继承属性获取
