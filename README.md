# Subversion 本地构建项目

一站式构建 Apache Subversion 及其所有依赖库。

## 📋 项目概述

本项目将 Subversion 及其所有依赖库的源码组织在一起，使用 [xmake](https://xmake.io) 构建系统实现一键编译，输出完全独立的动态库和可执行文件，支持打包分发。

## 🗂️ 目录结构

```
.
├── build.sh              # 一键构建脚本
├── xmake.lua             # 主构建配置文件
├── generate.lua          # 辅助脚本（生成 serf 构建配置）
│
├── zlib/                 # 压缩库
├── libexpat/             # XML 解析库
├── openssl/              # TLS/SSL 库
├── sqlite/               # 嵌入式数据库
├── apr/                  # Apache 可移植运行时
├── apr-util/             # APR 工具库
├── serf/                 # HTTP 客户端库
├── subversion/           # Subversion 版本控制系统
│
└── build/                # 构建输出目录
    ├── .packages/        # xmake 包缓存
    └── install/          # 最终安装目录
        ├── bin/          # 可执行文件
        ├── lib/          # 动态库
        └── include/      # 头文件
```

## 🔗 依赖关系

```
subversion
├── sqlite
├── openssl
│   └── zlib
├── serf
│   ├── apr
│   │   └── libexpat
│   ├── apr-util
│   │   ├── apr
│   │   └── libexpat
│   ├── openssl
│   └── zlib
├── apr
├── apr-util
├── libexpat
└── zlib
```

## 🚀 快速开始

### 前置要求

- **macOS**: Xcode Command Line Tools
- **Linux**: gcc/g++, make, perl, python3
- **Windows**: Visual Studio (带 C++ 工具集), perl, python3

### 一步构建

```bash
# 构建所有（首次会较慢）
./build.sh

# 清理后重新构建
./build.sh clean
```

### 手动构建（分步）

```bash
# 1. 构建依赖和 serf
xmake build -y svn-build

# 2. 构建 subversion
xmake require -y subversion

# 3. 安装到 build/install
xmake install -y subversion-install
```

## 📦 输出文件

构建完成后，所有文件安装在 `build/install/`：

### 可执行文件 (`bin/`)

| 命令 | 说明 |
|------|------|
| `svn` | Subversion 客户端 |
| `svnadmin` | 仓库管理工具 |
| `svnserve` | SVN 服务器 |
| `svnlook` | 仓库检查工具 |
| `svndumpfilter` | 转储过滤工具 |
| `svnsync` | 仓库同步工具 |
| `svnversion` | 工作副本版本号 |
| `svnbench` | 性能测试工具 |
| `svnmucc` | 多 URL 命令提交 |
| `svnrdump` | 远程转储工具 |
| `svnfsfs` | FSFS 文件系统工具 |

### 动态库 (`lib/`)

- `libsvn_*.dylib/.so/.dll` - Subversion 核心库
- `libserf-1.*` - HTTP 客户端库
- `libapr-1.*`, `libaprutil-1.*` - Apache 运行时
- `libssl.*`, `libcrypto.*` - OpenSSL
- `libz.*` - zlib 压缩
- `libexpat.*` - XML 解析
- `libsqlite3.*` - SQLite 数据库

## 🖥️ 跨平台支持

| 平台 | 状态 | 说明 |
|------|------|------|
| macOS (arm64/x86_64) | ✅ 完全支持 | 自动处理 rpath |
| Linux (x86_64/arm64) | ✅ 完全支持 | 需要 patchelf |
| Windows (x64/x86) | ✅ 支持 | 需要 Visual Studio |

### 平台特定说明

**macOS**:
- 自动使用 `install_name_tool` 修复动态库路径
- 支持 `@rpath` 相对路径，可打包分发

**Linux**:
- 自动使用 `patchelf` 设置 RPATH
- 使用 `$ORIGIN` 相对路径

**Windows**:
- DLL 自动复制到 bin 目录
- 需要 Visual Studio 或 Build Tools

## 🔧 打包分发

构建完成后，可以打包 `build/install/` 目录：

```bash
# macOS/Linux
tar czf subversion-$(uname -s)-$(uname -m).tar.gz -C build/install bin lib

# 解压后即可使用
tar xzf subversion-*.tar.gz
./bin/svn --version
```

## ❓ 常见问题

### Q: 为什么需要两步构建？

A: 因为 serf 没有 CMake 支持，需要使用 xmake 直接编译。而 subversion 依赖 serf，所以必须：
1. 先构建 serf（xmake target）
2. 再构建 subversion（xmake package）

### Q: 如何清理重新构建？

A: 删除 `build/` 和 `.xmake/` 目录：
```bash
rm -rf build .xmake
./build.sh
```

### Q: 如何只构建某个依赖？

A: 使用 `xmake require`：
```bash
xmake require -y zlib
xmake require -y openssl
```

### Q: Windows 上找不到 perl/python？

A: 确保 perl 和 python 在 PATH 中，或使用：
```bash
xmake f --perl="C:\path\to\perl.exe"
```

## 📝 版本信息

| 组件 | 版本 |
|------|------|
| Subversion | 1.16.0-dev |
| APR | 1.7.6 |
| OpenSSL | 1.1.1w |
| SQLite | 3.54.0 |
| zlib | 1.3.2 |
| libexpat | 2.8.1 |
| serf | 1.3.10 |

## 📄 许可证

- Subversion: Apache-2.0
- APR/APR-util: Apache-2.0
- OpenSSL: Apache-2.0
- zlib: zlib
- libexpat: MIT
- SQLite: Public Domain
- serf: Apache-2.0
