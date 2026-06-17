# Subversion HTTP/WebDAV 协议规范

## 1. 协议概述

Subversion 的 HTTP 协议运行在标准 HTTP/1.1（或 HTTP/2）之上，以 **WebDAV (RFC 2518)** 和 **DeltaV (RFC 3253)** 为基础框架，并在其上进行了大量**自定义扩展**，形成了一套领域特定的版本控制协议。

客户端实现位于 `libsvn_ra_serf`（基于 Apache Serf 异步 HTTP 库），服务端实现为 Apache 模块 `mod_dav_svn`。

协议存在两个版本：
- **HTTP v1**（经典 DeltaV 协议）：完全遵循 DeltaV 规范，需要多轮 PROPFIND 发现资源 URL
- **HTTP v2**（精简协议，Subversion 1.7+）：去除了 DeltaV 的冗余发现机制，客户端可直接构造 URL

两个版本共存，客户端通过 OPTIONS 响应判断服务端支持哪个版本，自动降级兼容。

### 1.1 为什么选择 WebDAV/DeltaV

Subversion 早期选择 Apache + WebDAV/DeltaV 的核心原因：
- 可穿越企业防火墙（标准 HTTP 端口）
- 通过 Apache 获得丰富的认证/授权方案
- 标准化 SSL/TLS 加密
- Apache 日志基础设施
- 内置仓库浏览器（仓库 URL 可直接用浏览器访问）
- 中间代理缓存能力

但 DeltaV 协议本身极其复杂且与 Subversion 模型契合度低，因此 Subversion 只使用了 DeltaV 的**一个有限子集**，并在此基础上做了大量自定义扩展。

---

## 2. SVN 对 HTTP/WebDAV 的自定义扩展

这是本文档的重点。SVN 在标准 HTTP/WebDAV/DeltaV 之上引入了以下自定义机制：

### 2.1 自定义 HTTP 头

SVN 定义了大量自定义 HTTP 头，分为两类：**请求头**（客户端 → 服务端）和**响应头**（服务端 → 客户端）。

#### 2.1.1 请求头（客户端发送）

| 头名称 | 定义常量 | 用途 |
|--------|---------|------|
| `X-SVN-VR-Base` | `SVN_DAV_DELTA_BASE_HEADER` | 告知服务端客户端持有的基版本 URL，用于 GET 请求中的增量传输（svndiff）|
| `X-SVN-Options` | `SVN_DAV_OPTIONS_HEADER` | 触发服务端特定行为，如 `lock-break`、`lock-steal`、`release-locks`、`keep-locks` |
| `X-SVN-Version-Name` | `SVN_DAV_VERSION_NAME_HEADER` | 告知服务端客户端操作的基版本号，用于 HTTPv2 写操作的过期检查 |
| `X-SVN-Base-Fulltext-MD5` | `SVN_DAV_BASE_FULLTEXT_MD5_HEADER` | 基版本文件的 MD5 校验和，用于完整性验证 |
| `X-SVN-Result-Fulltext-MD5` | `SVN_DAV_RESULT_FULLTEXT_MD5_HEADER` | 结果文件的 MD5 校验和 |

**`X-SVN-VR-Base` 的增量传输示例**：

```
GET /repos/test/!svn/ver/3/httpd/configure HTTP/1.1
Host: localhost
X-SVN-VR-Base: /repos/test/!svn/ver/2/httpd/configure
Accept-Encoding: svndiff1;q=0.9,svndiff;q=0.8
```

客户端告诉服务端："我有版本 2 的 configure 文件，请给我 v2→v3 的增量。" 服务端可返回 `application/vnd.svn-svndiff` 格式的增量数据，而非完整文件内容。

**`X-SVN-Version-Name` 的过期检查示例**（HTTPv2 写操作）：

```
DELETE /repos/test/!svn/txr/TXN-123/trunk/old-file.c HTTP/1.1
X-SVN-Version-Name: 42
```

服务端据此验证客户端持有的基版本（42）是否仍为最新版本，如已过期则返回错误。

#### 2.1.2 响应头（服务端发送，OPTIONS 响应中）

这些头在 OPTIONS 响应中返回，构成 HTTP v2 协议的发现机制：

| 头名称 | 定义常量 | 用途 | 引入版本 |
|--------|---------|------|---------|
| `SVN-Youngest-Rev` | `SVN_DAV_YOUNGEST_REV_HEADER` | 仓库最新版本号 | 1.7 |
| `SVN-Repository-UUID` | `SVN_DAV_REPOS_UUID_HEADER` | 仓库 UUID | 1.7 |
| `SVN-Repository-Root` | `SVN_DAV_ROOT_URI_HEADER` | 仓库根 URI | 1.7 |
| `SVN-Me-Resource` | `SVN_DAV_ME_RESOURCE_HEADER` | "me 资源" URI（`!svn/me`），HTTPv2 的标志 | 1.7 |
| `SVN-Rev-Stub` | `SVN_DAV_REV_STUB_HEADER` | 修订资源 URL 前缀（`!svn/rev`） | 1.7 |
| `SVN-Rev-Root-Stub` | `SVN_DAV_REV_ROOT_STUB_HEADER` | 修订根资源 URL 前缀（`!svn/rvr`） | 1.7 |
| `SVN-Txn-Stub` | `SVN_DAV_TXN_STUB_HEADER` | 事务资源 URL 前缀（`!svn/txn`） | 1.7 |
| `SVN-Txn-Root-Stub` | `SVN_DAV_TXN_ROOT_STUB_HEADER` | 事务根资源 URL 前缀（`!svn/txr`） | 1.7 |
| `SVN-VTxn-Stub` | `SVN_DAV_VTXN_STUB_HEADER` | 虚拟事务 URL 前缀（`!svn/vtxn`） | 1.7 |
| `SVN-VTxn-Root-Stub` | `SVN_DAV_VTXN_ROOT_STUB_HEADER` | 虚拟事务根 URL 前缀（`!svn/vtxr`） | 1.7 |
| `SVN-Supported-Posts` | `SVN_DAV_SUPPORTED_POSTS_HEADER` | 服务端支持的 POST 类型列表 | 1.8 |
| `SVN-Allow-Bulk-Updates` | `SVN_DAV_ALLOW_BULK_UPDATES` | 是否允许 bulk update（`On`/`Off`/`Prefer`） | 1.8 |
| `SVN-Repository-MergeInfo` | `SVN_DAV_REPOSITORY_MERGEINFO` | 仓库是否支持 mergeinfo（`yes`/`no`） | 1.8 |

**OPTIONS 响应示例**：

```
HTTP/1.1 200 OK
DAV: version-control,checkout,working-resource
DAV: merge,baseline,activity,version-controlled-collection
DAV: http://subversion.tigris.org/xmlns/dav/svn/depth
DAV: http://subversion.tigris.org/xmlns/dav/svn/mergeinfo
DAV: http://subversion.tigris.org/xmlns/dav/svn/log-revprops
DAV: http://subversion.tigris.org/xmlns/dav/svn/svndiff1
DAV: http://subversion.tigris.org/xmlns/dav/svn/svndiff2
SVN-Repository-Root: /repos/test
SVN-Me-Resource: /repos/test/!svn/me
SVN-Youngest-Rev: 42
SVN-Repository-UUID: a1b2c3d4-e5f6-...
SVN-Rev-Stub: /repos/test/!svn/rev
SVN-Rev-Root-Stub: /repos/test/!svn/rvr
SVN-Txn-Stub: /repos/test/!svn/txn
SVN-Txn-Root-Stub: /repos/test/!svn/txr
SVN-Allow-Bulk-Updates: On
SVN-Supported-Posts: create-txn
```

客户端判断 HTTPv2 支持的方式：检查 `SVN-Me-Resource` 头是否存在。源码中的判断宏：

```c
#define SVN_RA_SERF__HAVE_HTTPV2_SUPPORT(sess) ((sess)->me_resource != NULL)
```

#### 2.1.3 其他响应头

| 头名称 | 定义常量 | 用途 |
|--------|---------|------|
| `X-SVN-Creation-Date` | `SVN_DAV_CREATIONDATE_HEADER` | LOCK 成功响应中返回锁的创建时间 |
| `X-SVN-Lock-Owner` | `SVN_DAV_LOCK_OWNER_HEADER` | PROPFIND lockdiscovery 中返回锁的拥有者 |
| `SVN-Txn-Name` | `SVN_DAV_TXN_NAME_HEADER` | POST 创建事务后返回事务名 |
| `SVN-VTxn-Name` | `SVN_DAV_VTXN_NAME_HEADER` | POST 响应中的虚拟事务名 |

### 2.2 自定义 DAV 能力声明（DAV 头扩展值）

SVN 在标准 WebDAV 的 `DAV:` 响应头中追加了自定义的能力值（capability），用于能力协商。这些值使用 SVN 专有的 XML 命名空间前缀 `http://subversion.tigris.org/xmlns/dav/`：

| DAV 头值 | 能力名称 | 含义 | 引入版本 |
|----------|---------|------|---------|
| `.../svn/depth` | depth | 支持 `svn_depth_t`（稀疏检出） | 1.5 |
| `.../svn/mergeinfo` | mergeinfo | 支持合并追踪 | 1.5 |
| `.../svn/log-revprops` | log-revprops | 日志 REPORT 中支持自定义 revprop | 1.5 |
| `.../svn/partial-replay` | partial-replay | 支持子目录级别的 replay | 1.5 |
| `.../svn/atomic-revprops` | atomic-revprops | PROPPATCH 支持 old-value 原子性检查 | 1.7 |
| `.../svn/inherited-props` | inherited-props | 支持继承属性查询 | 1.8 |
| `.../svn/ephemeral-txnprops` | ephemeral-txnprops | 支持临时事务属性 | 1.8 |
| `.../svn/inline-props` | inline-props | update-report 中内联属性（skelta 模式） | 1.8 |
| `.../svn/replay-rev-resource` | replay-rev-resource | 支持对 rev resource 发起 replay | 1.8 |
| `.../svn/reverse-file-revs` | reverse-file-revs | 支持反向 blame 查询 | 1.8 |
| `.../svn/svndiff1` | svndiff1 | 支持 svndiff1 压缩增量格式 | 1.10 |
| `.../svn/svndiff2` | svndiff2 | 支持 svndiff2 增量格式（LZ4 压缩） | 1.10 |
| `.../svn/list` | list | 支持 list REPORT | 1.10 |
| `.../svn/put-result-checksum` | put-result-checksum | PUT 响应中包含结果校验和 | 1.10 |

这些能力值在 OPTIONS 响应的 `DAV:` 头中以逗号分隔返回。客户端在 `capabilities_headers_iterator_callback()` 中逐一解析。

### 2.3 自定义 XML 命名空间

SVN 在 WebDAV XML 交互中使用了三个自定义 XML 命名空间：

| 命名空间 URI | 常量 | 用途 |
|-------------|------|------|
| `http://subversion.tigris.org/xmlns/svn/` | `SVN_DAV_PROP_NS_SVN` | SVN 内建属性（`svn:*` 前缀的属性），客户端和服务端均解释 |
| `http://subversion.tigris.org/xmlns/custom/` | `SVN_DAV_PROP_NS_CUSTOM` | 用户自定义属性，客户端和服务端均忽略 |
| `http://subversion.tigris.org/xmlns/dav/` | `SVN_DAV_PROP_NS_DAV` | 纯网络层属性（wcprop 等），对 FS 和 WC 层不可见 |

此外，SVN 自定义 REPORT 的请求/响应体使用 `svn:` 命名空间前缀（对应 `SVN_XML_NAMESPACE`）。

### 2.4 自定义 REPORT（扩展 WebDAV REPORT 方法）

WebDAV 定义了 REPORT 方法作为通用查询接口。SVN 在此之上定义了 **12 种自定义 REPORT**，每种对应一个特定的查询操作。REPORT 请求发送到 `!svn/me`（HTTPv2）或 VCC URL（HTTPv1）。

#### 2.4.1 update-report — 更新/检出/切换的核心

这是 SVN HTTP 协议中最重要的 REPORT，用于驱动 `svn_repos_dir_delta()` 计算差异。

**请求**：
```xml
<S:update-report send-all="true" xmlns:S="svn:">
  <S:src-path>http://localhost:8080/repos/test/trunk</S:src-path>
  <S:target-revision>42</S:target-revision>
  <S:entry rev="40" start-empty="true"></S:entry>
</S:update-report>
```

- `send-all="true"`：要求服务端在响应中内联所有文件内容和属性（bulk 模式）
- `send-all="false"` 或不设置：仅返回变更描述，客户端需额外 PROPFIND + GET 获取内容（skelta 模式）
- `start-empty="true"`：客户端没有该目录的任何内容，需要完整传输

**响应**（XML 流式编辑器指令）：
```xml
<S:update-report xmlns:S="svn:" xmlns:D="DAV:" send-all="true">
  <S:target-revision rev="42"/>
  <S:open-directory rev="42">
    <D:checked-in><D:href>/repos/test/!svn/ver/42/trunk</D:href></D:checked-in>
    <S:set-prop name="svn:entry:committed-rev">42</S:set-prop>
    <S:add-file name="new-file.c">
      <D:checked-in><D:href>/repos/test/!svn/ver/42/trunk/new-file.c</D:href></D:checked-in>
      <S:set-prop name="svn:entry:committed-rev">42</S:set-prop>
      <S:txdelta>...base64编码的文件内容...</S:txdelta>
    </S:add-file>
    <S:add-directory name="new-dir" bc-url="/repos/test/!svn/bc/42/trunk/new-dir">
      ...目录内容...
    </S:add-directory>
    <S:delete-entry name="old-file.c"/>
  </S:open-directory>
</S:update-report>
```

响应体实质上是一套**编辑器指令流**（editor driving protocol），与 `svn://` 协议的编辑器命令集在语义上完全对等。XML 标签对应 `svn_delta_editor_t` 的方法调用：

| XML 标签 | 对应编辑器方法 |
|----------|--------------|
| `<S:open-directory>` | `open_directory()` |
| `<S:add-directory>` | `add_directory()` |
| `<S:open-file>` | `open_file()` |
| `<S:add-file>` | `add_file()` |
| `<S:delete-entry>` | `delete_entry()` |
| `<S:set-prop>` | `change_file_prop()` / `change_dir_prop()` |
| `<S:remove-prop>` | 删除属性 |
| `<S:txdelta>` | `apply_textdelta()` 的数据流 |
| `<S:absent-directory>` | 权限限制的目录 |
| `<S:absent-file>` | 权限限制的文件 |
| `<S:fetch-file>` | 需要额外 GET 获取的文件（skelta 模式） |
| `<S:fetch-props>` | 需要额外 PROPFIND 获取的属性 |

#### 2.4.2 其他自定义 REPORT

| REPORT 名称 | 用途 | 目标 URL |
|-------------|------|---------|
| `dated-rev-report` | 日期 → 版本号转换 | `!svn/me` |
| `log-report` | 获取日志 | pegrev URI |
| `get-locations` | 路径跨版本定位（peg-rev 追踪） | pegrev URI |
| `get-location-segments` | 获取路径的历史段信息 | pegrev URI |
| `get-locks-report` | 获取锁信息 | 公共 HEAD URI |
| `mergeinfo-report` | 获取合并历史 | pegrev URI |
| `file-revs-report` | blame 数据 | pegrev URI |
| `replay-report` | 重放修订变更（svnsync） | `!svn/me` 或 rev resource |
| `inherited-props-report` | 获取继承属性 | pegrev URI |
| `get-deleted-rev` | 查询路径被删除的版本号 | pegrev URI |

**log-report 请求示例**：
```xml
<S:log-report xmlns:S="svn:">
  <S:start-revision>10</S:start-revision>
  <S:end-revision>1</S:end-revision>
  <S:limit>100</S:limit>
  <S:discover-changed-paths/>
  <S:strict-node-history/>
  <S:revprop>svn:log</S:revprop>
  <S:revprop>svn:author</S:revprop>
  <S:revprop>svn:date</S:revprop>
  <S:path></S:path>
</S:log-report>
```

**dated-rev-report 请求/响应**：
```xml
<!-- 请求 -->
<S:dated-rev-report xmlns:S="svn:" xmlns:D="DAV:">
  <D:creationdate>2024-01-15T10:30:00.000000Z</D:creationdate>
</S:dated-rev-report>

<!-- 响应 -->
<S:dated-rev-report xmlns:S="svn:" xmlns:D="DAV:">
  <D:version-name>4747</D:version-name>
</S:dated-rev-report>
```

**mergeinfo-report 请求/响应**：
```xml
<!-- 请求 -->
<S:mergeinfo-report xmlns:S="svn:">
  <S:revision>42</S:revision>
  <S:inherit>inherited</S:inherit>
  <S:include-descendants>yes</S:include-descendants>
  <S:path>/trunk/src</S:path>
</S:mergeinfo-report>

<!-- 响应 -->
<S:mergeinfo-report xmlns:S="svn:" xmlns:D="DAV:">
  <S:mergeinfo-item>
    <S:mergeinfo-path>/branches/feature</S:mergeinfo-path>
    <S:mergeinfo-info>/branches/feature:10-15,20</S:mergeinfo-info>
  </S:mergeinfo-item>
</S:mergeinfo-report>
```

### 2.5 自定义 URL 资源体系

SVN 在标准 WebDAV 资源模型之上定义了一套特殊的 URL 路径体系（默认前缀 `!svn`，可由服务端 `SVNSpecialURI` 指令配置）：

#### HTTP v1 资源（经典 DeltaV）

| 资源类型 | URL 模式 | 对应 FS 概念 | 用途 |
|---------|---------|------------|------|
| VCC | `!svn/vcc/default` | — | 版本控制配置（REPORT 目标） |
| Baseline | `!svn/bln/REV` | `svn_fs_revision_root()` | 基线资源 |
| Baseline Collection | `!svn/bc/REV/` | revision root 的目录视图 | 特定版本的目录快照 |
| Activity | `!svn/act/UUID/` | `svn_fs_txn_t` | 提交活动（HTTPv1 事务） |
| Version Resource | `!svn/ver/REV/path` | 特定版本的文件 | 历史文件访问 |
| Working Resource | `!svn/wrk/UUID/path` | 事务中的文件 | CHECKOUT 后的工作副本 |

#### HTTP v2 资源（精简协议）

| 资源类型 | URL 模式 | 对应 FS 概念 | 用途 |
|---------|---------|------------|------|
| Me Resource | `!svn/me` | 仓库本身 | REPORT 目标，POST 创建事务 |
| Revision Resource | `!svn/rev/REV` | 修订版本元数据 | PROPFIND/PROPPATCH 操作 revprops |
| Revision Root | `!svn/rvr/REV/[PATH]` | `svn_fs_root_t` + path | GET/PROPFIND/REPORT 特定版本对象 |
| Transaction | `!svn/txn/TXN-NAME` | `svn_fs_txn_t` | PROPFIND/PROPPATCH 事务属性 |
| Transaction Root | `!svn/txr/TXN-NAME/[PATH]` | txn root + path | PUT/DELETE/MKCOL/PROPPATCH 写操作 |
| VTransaction | `!svn/vtxn/NAME` | 虚拟命名事务 | 客户端指定名称的事务 |
| VTransaction Root | `!svn/vtxr/NAME/[PATH]` | 虚拟命名事务根 | 同上，路径级别操作 |

**HTTPv2 的核心改进**：客户端从 OPTIONS 响应中获取 URL stub 后，可以直接拼接构造所有需要的 URL，无需通过多轮 PROPFIND 逐级发现。

### 2.6 自定义 MIME 类型

| MIME 类型 | 常量 | 用途 |
|----------|------|------|
| `application/vnd.svn-svndiff` | `SVN_SVNDIFF_MIME_TYPE` | svndiff 增量数据流，用于 GET 响应和 PUT 请求体 |
| `application/vnd.svn-skel` | `SVN_SKEL_MIME_TYPE` | skel 序列化格式，用于 POST 请求体（HTTPv2 高级操作） |

### 2.7 自定义 PROPPATCH 扩展

标准 WebDAV 的 PROPPATCH 使用 `<D:set>` 和 `<D:remove>` 操作属性。SVN 对此进行了扩展以支持 `svn_ra_change_rev_prop2()` 的原子性语义：

**扩展规则**：
1. 所有属性变更（包括删除）都通过 `<D:set><D:prop>` 传递（而非 `<D:remove>`）
2. 属性删除时，属性标签携带 `V:absent="true"` 属性
3. 原子性检查（old_value_p）通过嵌套 `<V:old-value>` 标签传递，该标签同样支持 `V:absent` 和 `V:encoding` 属性
4. 属性值放在标签的 CDATA 中，二进制数据使用 base64 编码

**PROPPATCH 请求示例**（带原子性检查）：
```xml
<D:propertyupdate xmlns:D="DAV:" xmlns:V="http://subversion.tigris.org/xmlns/dav/"
                  xmlns:S="http://subversion.tigris.org/xmlns/svn/">
  <D:set>
    <D:prop>
      <S:log>V:encoding="base64">5pel5pys6K+l5ZGK</S:log>
    </D:prop>
  </D:set>
</D:propertyupdate>
```

**错误映射**：当 PROPPATCH 中的 old-value 不匹配时，服务端在 207 Multi-Status 响应中返回 `<D:status>HTTP/1.1 412 Precondition Failed</D:status>`，客户端将此映射为 `SVN_ERR_FS_PROP_BASEVALUE_MISMATCH`。

### 2.8 自定义错误传输

SVN 在 HTTP 错误响应体中使用自定义 XML 格式传递结构化错误信息：

```xml
<D:error xmlns:D="DAV:" xmlns:S="svn:">
  <S:error>
    <S:apr-error>195012</S:apr-error>
    <S:message>Authorization failed</S:message>
    <S:file>serve.c</S:file>
    <S:line>843</S:line>
  </S:error>
</D:error>
```

错误命名空间：
- 错误对象命名空间：`svn:`（`SVN_DAV_ERROR_NAMESPACE`）
- 错误标签名：`error`（`SVN_DAV_ERROR_TAG`）

与 `svn://` 协议的链式错误结构不同，HTTP 协议目前只传输单个错误节点（未来计划支持完整的 `svn_error_t` 链）。

---

## 3. 核心操作流程

### 3.1 会话建立与能力交换

```
客户端                                      服务端
  │                                           │
  │──── OPTIONS session_URL ────────────────► │
  │     Body: <D:options>                     │
  │             <D:activity-collection-set/>   │
  │           </D:options>                     │
  │                                           │
  │◄─── 200 OK ────────────────────────────── │
  │     Headers: DAV: ...,svn/depth,...       │
  │              SVN-Me-Resource: ...          │
  │              SVN-Rev-Stub: ...             │
  │              SVN-Txn-Stub: ...             │
  │              SVN-Youngest-Rev: 42          │
  │              SVN-Repository-UUID: ...      │
  │     Body: <D:options-response>            │
  │             <D:activity-collection-set>    │
  │               <D:href>!svn/act</D:href>   │
  │             </D:activity-collection-set>   │
  │           </D:options-response>            │
  │                                           │
```

客户端解析响应后：
1. 从 `DAV:` 头提取能力（depth、mergeinfo、svndiff1/2 等）
2. 从 `SVN-*` 头提取 HTTPv2 URL stub
3. 如果 `SVN-Me-Resource` 存在 → 启用 HTTPv2；否则降级为 HTTPv1
4. 缓存仓库 UUID、根路径、最新版本号

### 3.2 读操作流程（以 checkout/update 为例）

checkout、export、update、switch、diff 在 RA 层共享同一套 `make_update_reporter()` 实现，核心流程如下：

#### 第一步：Reporter 模式构建 REPORT 请求体

`do_update()` 不直接发送 REPORT，而是返回一个 `reporter3_t` 接口给客户端层。客户端通过回调逐步描述本地工作副本状态，构建 XML 请求体：

```c
// reporter3_t 接口
static const svn_ra_reporter3_t ra_serf_reporter = {
  set_path,      // 描述本地已有的路径和版本
  delete_path,   // 描述本地已删除的路径
  link_path,     // 描述 switch 到其他 URL 的路径
  finish_report, // 关闭 XML 并发送 REPORT
  abort_report   // 中止
};
```

- **checkout**（全新检出）：不调用 `set_path()`，直接 `finish_report()`，请求体仅含 `<S:entry rev="..." start-empty="true"/>`
- **update**（增量更新）：通过 `set_path()` 描述 WC 中已有的路径和版本号
- **switch**：通过 `link_path()` 描述目标 URL

#### 第二步：finish_report() 发送 REPORT

`finish_report()` 关闭 XML body 并发送 REPORT 请求。REPORT 的目标 URL 取决于协议版本：

```
HTTPv2: REPORT → !svn/me         （URL 可直接构造，无需发现）
HTTPv1: REPORT → VCC URL          （在 finish_report 内部通过 PROPFIND 链发现 VCC）
```

HTTPv1 的 VCC 发现（`svn_ra_serf__discover_vcc()`）是在 `finish_report()` 内部同步执行的，不是在 REPORT 之前独立完成的步骤。发现结果会被缓存在 session 中。

#### 第三步：解析 REPORT 响应（编辑器指令流）

服务端返回的 update-report 响应是 XML 流式编辑器指令，客户端边解析边驱动 `svn_delta_editor_t`。

#### 第四步（仅 skelta 模式）：按需发起 GET 和 PROPFIND

当 `send-all` 未启用时，响应中包含 `<S:fetch-file>` 和 `<S:fetch-props>` 标记，客户端需要额外请求获取实际内容：

- **GET**（获取文件内容）和 **PROPFIND**（获取属性）对每个需要 fetch 的文件**交错并发**发起（不是分两个阶段），利用多连接（最多 8 个）并行化
- 在发起 GET 前，客户端会先检查本地 SHA1 缓存，如已有相同内容则直接本地复制，跳过 GET
- GET 请求中携带 `Accept-Encoding: svndiff1,svndiff` 头以支持增量传输

**delta base 差异**（GET 增量传输的基版本 URL 构造方式）：
- HTTPv2：客户端从 `rev_root_stub` 直接构造（`!svn/rvr/REV/PATH`），无需服务端交互
- HTTPv1：从 WC prop（`svn:wc:ra_dav:version-url`）读取，若无缓存则需要额外 PROPFIND

```
完整时序（skelta 模式）：

HTTPv1:                                    HTTPv2:
  [reporter: set_path... finish_report]      [reporter: set_path... finish_report]
       │                                          │
       ├─ PROPFIND链 → 发现 VCC                  (不需要，直接构造 !svn/me)
       │                                          │
       ├─ REPORT update-report (→ VCC)           ├─ REPORT update-report (→ !svn/me)
       │    ← XML编辑器指令流                      │    ← XML编辑器指令流
       │                                          │
       └─ 对每个 fetch-file/fetch-props:          └─ 对每个 fetch-file/fetch-props:
            GET + PROPFIND (交错并发)                   GET + PROPFIND (交错并发)
            (delta base 来自 wcprop)                   (delta base 来自 rev_root_stub)
```

**bulk 模式**（`send-all="true"`）下，所有文件内容和属性都内联在 REPORT 响应中，不需要额外的 GET/PROPFIND，流程更简单：

```
HTTPv1: REPORT (→ VCC) ← 含全部内容和属性
HTTPv2: REPORT (→ !svn/me) ← 含全部内容和属性
```

### 3.3 写操作流程（commit）

#### HTTP v1 提交流程

```
1. OPTIONS        → 获取 activity-collection-set
2. PROPFIND       → 发现 VCC、baseline URL、checked-in URL
3. MKACTIVITY     → 创建提交活动
   MKACTIVITY /repos/!svn/act/UUID → 201 Created
4. CHECKOUT       → 检出 baseline 到活动
   CHECKOUT /repos/!svn/vcc/default
   Body: <D:checkout><D:activity-set><D:href>/repos/!svn/act/UUID</D:href></D:activity-set></D:checkout>
   → 201 Created, Location: /repos/!svn/wbl/UUID/REV
5. 对每个变更:
   CHECKOUT 节点 → 获取 working resource
   PUT/PROPPATCH/DELETE/MKCOL/COPY → 操作 working resource
6. MERGE          → 合并活动，完成提交
   MERGE /repos/!svn/act/UUID
7. DELETE         → 清理活动（成功时清理，失败时回滚）
```

#### HTTP v2 提交流程

```
1. POST → !svn/me 创建事务
   POST /repos/!svn/me
   → 201 Created
   ← SVN-Txn-Name: TXN-123-456

2. PROPPATCH → 设置 revprops
   PROPPATCH /repos/!svn/txn/TXN-123-456
   Body: svn:log, svn:author, svn:date ...

3. 对每个变更（直接构造 URL，无需 CHECKOUT）:
   PUT     /repos/!svn/txr/TXN-123-456/trunk/new-file.c
           Content-Type: application/vnd.svn-svndiff
           X-SVN-Version-Name: 42
   DELETE  /repos/!svn/txr/TXN-123-456/trunk/old-file.c
           X-SVN-Version-Name: 42
   MKCOL   /repos/!svn/txr/TXN-123-456/trunk/new-dir
   PROPPATCH /repos/!svn/txr/TXN-123-456/trunk/file.c  (修改属性)
   COPY    /repos/!svn/txr/TXN-123-456/trunk/...       (复制)

4. MERGE → 完成提交
   MERGE /repos/!svn/txn/TXN-123-456

5. 失败时:
   DELETE /repos/!svn/txn/TXN-123-456  (中止事务)
```

**HTTPv2 的关键改进**：
- 消除了 MKACTIVITY（用 POST 替代）
- 消除了所有 CHECKOUT 请求（每个文件变更前不再需要先 CHECKOUT）
- URL 全部可直接构造（不再需要 PROPFIND 发现 opaque URL）
- 直接暴露 SVN 事务名（不再有 activity-UUID 到 txn-name 的间接映射）
- 使用 `X-SVN-Version-Name` 头替代 DeltaV 的 working-resource 版本机制

### 3.4 锁操作

锁操作直接使用标准 WebDAV 的 LOCK/UNLOCK 方法，但 SVN 增加了自定义头扩展语义：

```
svn lock:
  PROPFIND → 获取资源的 checked-in URL
  LOCK public-HEAD-URL
  X-SVN-Options: lock-break (或 lock-steal)
  → 响应中 X-SVN-Creation-Date 头提供锁创建时间

svn unlock:
  PROPFIND → 获取资源的 checked-in URL
  UNLOCK public-HEAD-URL

svn info (锁信息):
  PROPFIND → DAV:lockdiscovery 属性
  → 响应中 X-SVN-Lock-Owner 头提供锁拥有者
```

`X-SVN-Options` 中的锁操作选项：
- `lock-break`：打破他人持有的锁
- `lock-steal`：窃取他人的锁
- `release-locks`：提交时释放所有锁
- `keep-locks`：提交时保留所有锁

---

## 4. 传输优化机制

### 4.1 并行连接

`libsvn_ra_serf` 支持最多 **8 个并行连接**（`SVN_RA_SERF__MAX_CONNECTIONS_LIMIT`），用于 update/checkout 时同时获取多个文件。最少需要 2 个连接以保证协议正常工作。

### 4.2 增量传输（svndiff）

SVN 自定义了 `application/vnd.svn-svndiff` MIME 类型用于增量传输：

- **GET 请求**：客户端通过 `X-SVN-VR-Base` 头告知基版本，通过 `Accept-Encoding: svndiff1;q=0.9,svndiff;q=0.8` 声明支持的增量格式
- **PUT 请求**：客户端直接以 svndiff 格式上传文件变更
- **update-report**：`send-all="true"` 时，`<S:txdelta>` 中包含 base64 编码的 svndiff 数据

svndiff 格式版本：
- `svndiff`（原始格式）
- `svndiff1`（Subversion 1.10+，支持 zlib 压缩）
- `svndiff2`（Subversion 1.10+，支持 LZ4 压缩）

### 4.3 Bulk vs Skelta 更新模式

- **Bulk 模式**（`send-all="true"`）：update-report 响应中包含所有文件内容和属性，一次 REPORT 完成更新
- **Skelta 模式**（`send-all="false"`）：update-report 响应仅包含变更描述（`<S:fetch-file>`、`<S:fetch-props>`），客户端需额外发起 PROPFIND 和 GET 请求获取实际数据

通过 `SVN-Allow-Bulk-Updates` 头控制：
- `On`：两种模式均可
- `Prefer`：服务端偏好 bulk 模式
- `Off`：仅接受 skelta 模式

### 4.4 HTTP 压缩

支持标准 HTTP gzip 压缩（通过 `Accept-Encoding: gzip`），与 svndiff 增量编码独立工作。可通过 `http-compression` 配置项控制：
- `yes`：启用压缩
- `no`：禁用压缩
- `auto`（默认）：根据网络参数自动决定

### 4.5 HTTP/2 支持

当检测到服务端支持 HTTP/2 时（`session->http20 = TRUE`），响应可能乱序返回，客户端的并行请求处理逻辑会适配此特性。

---

## 5. 认证机制

SVN HTTP 协议支持以下认证方式（通过 `http-auth-types` 配置过滤）：

| 认证方式 | 常量 | 说明 |
|---------|------|------|
| Basic | `SERF_AUTHN_BASIC` | HTTP Basic 认证 |
| Digest | `SERF_AUTHN_DIGEST` | HTTP Digest 认证 |
| NTLM | `SERF_AUTHN_NTLM` | Windows NTLM 认证 |
| Negotiate | `SERF_AUTHN_NEGOTIATE` | Kerberos/SPNEGO 协商认证 |

认证通过 Serf 库的 credentials callback 机制实现，回调函数为 `svn_ra_serf__credentials_callback()`，支持重试和代理认证。

SSL/TLS 相关：
- 支持客户端证书认证（通过 `svn_ra_serf__handle_client_cert()` 和 `svn_ra_serf__handle_client_cert_pw()`）
- 支持自定义 CA 证书（`ssl-authority-files` 配置）
- 支持信任系统默认 CA（`ssl-trust-default-ca` 配置，默认启用）

---

## 6. HTTP 方法与 SVN 命令映射总表

### 读操作

| SVN 命令 | HTTP 方法 | 协议细节 |
|---------|----------|---------|
| `svn checkout` / `svn update` | PROPFIND + REPORT | update-report（核心） |
| `svn switch` | OPTIONS + PROPFIND + REPORT | update-report + mergeinfo-report |
| `svn diff` | OPTIONS + PROPFIND + REPORT + GETs | update-report + 并行 GET |
| `svn merge` | OPTIONS + PROPFIND + REPORT + GETs | update-report + mergeinfo-report |
| `svn status -u` | OPTIONS + PROPFIND + REPORT | update-report + get-locks-report |
| `svn log` | OPTIONS + PROPFIND + REPORT | log-report |
| `svn blame` | OPTIONS + PROPFIND + REPORT | file-revs-report |
| `svn ls` | PROPFIND | — |
| `svn ls -v` | PROPFIND + REPORT | get-locks-report |
| `svn cat` | PROPFIND + GET | — |
| `svn info URL` | PROPFIND | — |
| `svn plist URL` | PROPFIND | — |
| `svn pget URL` | PROPFIND | — |
| `-r {DATE}` | REPORT | dated-rev-report |
| `-r X foo@Y` | REPORT | get-locations |

### 写操作

| SVN 命令 | HTTP 方法 | 协议细节 |
|---------|----------|---------|
| `svn commit` | MKACTIVITY + CHECKOUT + PUT + PROPPATCH + DELETE + MKCOL + MERGE (v1) | POST + PUT + PROPPATCH + DELETE + MKCOL + MERGE (v2) |
| `svn import` | OPTIONS + PROPFIND + MKACTIVITY + PROPPATCH + PUT + MKCOL + MERGE | 类似 commit |
| `svn lock` | PROPFIND + LOCK | — |
| `svn unlock` | PROPFIND + UNLOCK | — |
| `svn cp URL URL` | OPTIONS + PROPFIND + MKACTIVITY + PROPPATCH + COPY + MERGE | — |
| `svn mv URL URL` | OPTIONS + PROPFIND + MKACTIVITY + PROPPATCH + COPY + DELETE + MERGE | — |
| `svn rm URL` | OPTIONS + PROPFIND + MKACTIVITY + PROPPATCH + DELETE + MERGE | — |
| `svn mkdir URL` | OPTIONS + PROPFIND + MKACTIVITY + PROPPATCH + MKCOL + MERGE | — |
| `svn pset --revprop` | PROPPATCH | — |

---

## 7. 源码参考

| 文件 | 职责 |
|------|------|
| `subversion/include/svn_dav.h` | 所有 DAV 相关常量定义（自定义头、命名空间、能力值） |
| `subversion/include/private/svn_dav_protocol.h` | REPORT 名称、XML 元素名等协议常量 |
| `subversion/libsvn_ra_serf/serf.c` | RA 模块入口，会话创建，能力交换 |
| `subversion/libsvn_ra_serf/options.c` | OPTIONS 请求处理，能力解析 |
| `subversion/libsvn_ra_serf/ra_serf.h` | 内部类型定义，session 结构，DAV 属性集 |
| `subversion/libsvn_ra_serf/update.c` | update-report 解析（XML 状态机） |
| `subversion/libsvn_ra_serf/commit.c` | 提交编辑器实现（CHECKOUT/PUT/PROPPATCH/MERGE） |
| `subversion/libsvn_ra_serf/property.c` | PROPFIND 实现 |
| `subversion/libsvn_ra_serf/log.c` | log-report 实现 |
| `subversion/libsvn_ra_serf/merge.c` | MERGE 请求实现 |
| `subversion/libsvn_ra_serf/lock.c` | LOCK/UNLOCK 实现 |
| `subversion/libsvn_ra_serf/replay.c` | replay-report 实现 |
| `subversion/notes/http-and-webdav/webdav-protocol` | 协议设计笔记 |
| `subversion/notes/http-and-webdav/http-protocol-v2.txt` | HTTP v2 协议设计文档 |
