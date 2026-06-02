---
name: xmake
description: >-
  全面的 xmake 构建工具参考手册（基于 Lua 的跨平台 C/C++/多语言构建系统、工程生成器与包管理器，对标
  Make/Ninja + CMake/Meson + vcpkg/Conan + distcc + ccache）。覆盖 xmake.lua 的全部描述域 API
  （target/option/rule/task/package/toolchain 及其所有 set_*/add_*/on_*/before_*/after_* 接口）、
  全部脚本域内置模块（os/io/path/string/table/hash/import 等）、所有命令行命令与参数
  （xmake、config/f、build、run、test、install、package、project、require/xrepo、repo、service 等）、
  条件判断接口、包管理（add_requires/xrepo）、交叉编译、工具链、C++20 模块、构建缓存、分布式编译、
  工程文件生成（vsxmake/cmake/ninja/compile_commands）等所有功能。无论用户是在编写或调试 xmake.lua、
  集成第三方库、配置交叉编译、生成 IDE 工程，还是询问任何 xmake 命令、API、规则或特性，都应使用本技能。
  当涉及 .xmake、xmake.lua、xrepo、xpack 或 "用 xmake 构建" 时务必参考此文件。
---

# Xmake 完全参考手册

Xmake 是一个基于 Lua 脚本语言的轻量级跨平台构建工具。它本身除标准库外无任何外部依赖，使用
`xmake.lua` 文件以简洁可读的语法来维护工程构建。

> **定位**：Xmake ≈ 构建后端（Make/Ninja）+ 工程生成器（CMake/Meson）+ 包管理器
> （vcpkg/Conan）+ 远程/分布式编译（distcc）+ 编译缓存（ccache/sccache）。
> 最新稳定版本：**v3.0.8**（2026-03）。可用 `xmake update` 升级。

## 使用本手册的方式

本手册按"域"划分，这是理解 xmake 的关键：

1. **命令行层**：在终端执行的 `xmake xxx` 命令（见 §1）。
2. **描述域（description scope）**：`xmake.lua` 中直接书写的配置接口，如 `target()`、`add_files()`。
   这一层是声明式的，在工程加载阶段执行（见 §3–§9）。
3. **脚本域（script scope）**：写在 `on_xxx`/`before_xxx`/`after_xxx`/`task` 回调里的命令式 Lua 代码，
   可调用 `os`、`io`、`import` 等内置模块（见 §10–§12）。

判断一个 API 属于哪个域：直接顶格写在 `xmake.lua` 里的是描述域；写在回调函数体里、操作文件/进程/字符串的是脚本域。

---

## 1. 命令行命令（CLI）

通用形式：`xmake [task] [options] [target]`。不带 task 时默认执行 `build`。
常用全局参数：`-P/--project DIR`（指定工程目录）、`-F/--file FILE`（指定 xmake.lua）、
`-D/--diagnosis`（诊断输出）、`-v/--verbose`（详细输出）、`-q/--quiet`（静默）、`-y/--yes`（自动确认）、
`--root`（允许 root 运行）、`--version`、`--help`（任意命令后加 `-h` 看其帮助）。

### 1.1 构建相关

- `xmake` / `xmake build [target]`：构建。`xmake` 构建默认/所有目标，`xmake foo` 只构建 foo，
  `xmake -a` 构建全部目标。常用：`-r/--rebuild`（重新构建）、`-w/--warning`（显示警告）、
  `-v`（显示命令行）、`-j N/--jobs=N`（并行任务数）、`--all`、`-g/--group=PATTERN`（按分组构建）。
- `xmake -r` / `xmake rebuild`：清理后重新构建。
- `xmake b` 是 `build` 的简写。
- `xmake clean [target]` / `xmake c`：清理构建产物。`-a/--all` 清理全部（含依赖）。
- `xmake run [target] [args...]` / `xmake r`：运行目标程序，可透传命令行参数；
  `-d/--debug` 用调试器（lldb/gdb/windbg）启动，`-w/--workdir=DIR` 指定工作目录。
- `xmake install [target]`：安装目标。`-o/--installdir=DIR` 指定安装目录，`--admin` 管理员权限，
  `--all`，`-g/--group`。
- `xmake uninstall [target]`：卸载。
- `xmake package [target]` / `xmake p`：打包（生成 .tar.gz / 库归档等，配合 `xmake install` 输出）。
- `xmake pack`：基于 XPack 插件生成安装包（nsis/zip/srpm/rpm/deb/runself/wix/srczip 等格式，见 §9）。
- `xmake test [target/pattern]`：运行通过 `add_tests` 定义的测试（见 §4.18）。
  `-g/--group`，`-j N`，`--build`（先构建）。

### 1.2 配置相关

- `xmake config [options]` / `xmake f`：配置工程。核心参数：
  - `-p/--plat=PLAT`：目标平台（`windows`、`linux`、`macosx`、`android`、`iphoneos`、
    `watchos`、`appletvos`、`mingw`、`cross`、`wasm`、`bsd`、`cross` 等）。
  - `-a/--arch=ARCH`：架构（`x86`、`x64`、`x86_64`、`i386`、`arm`、`arm64`、`armv7`、
    `arm64-v8a`、`armeabi-v7a`、`riscv64`、`loong64`、`mips` 等，取决于平台）。
  - `-m/--mode=MODE`：构建模式（`debug`、`release`、`releasedbg`、`minsizerel`、`check`、`profile`、`coverage`、`valgrind`、`asan`、`tsan`、`lsan`、`ubsan` 等，由 `set_modes`/规则提供）。
  - `-k/--kind=KIND`：默认目标类型（`static`、`shared`、`binary`）。
  - `-o/--buildir=DIR`：构建输出目录（默认 `build`）。
  - `--cc`、`--cxx`、`--ld`、`--ar`、`--sh`、`--as`、`--mm`、`--mxx` 等：手动指定工具。
  - `--toolchain=NAME`：指定工具链（如 `clang`、`gcc`、`msvc`、`llvm`、`cross`、`muslcc`）。
  - `--sdk=DIR`：交叉编译 SDK 根目录；`--bin=DIR`、`--cross=PREFIX`、`--sysroot=DIR`。
  - `--ndk=DIR`、`--ndk_sdkver`、`--ndk_stdcxx`：Android NDK 相关。
  - `--vs=VERSION`、`--vs_toolset`、`--vs_sdkver`、`--vs_runtime`（MT/MD/MTd/MDd）：MSVC 相关。
  - `-c/--clean`：清理之前的配置缓存后重新配置。
  - `--require=y/n`：是否处理依赖包；`--policies=...`：设置策略。
  - `--menu`：进入图形化（curses）配置菜单。
  - 任意 `option()`/`set_config` 定义的自定义选项也作为 `--name=value` 出现。
- `xmake global [options]` / `xmake g`：配置全局（用户级）设置，如 `--proxy`、`--ccache`、
  `--network=private`、`--pkg_searchdirs`、`--theme`、`--mirror` 等。
- `xmake check [checker]`：运行内置/自定义检查器（如 `clang.tidy`、`api`、`xmake`）做静态检查。
- `xmake show [options]`：显示信息。`--list=KEY`（如 `--list=targets/plats/toolchains/...`）、
  `-t/--target=NAME`（显示某目标详情）、`--json`。

### 1.3 工程创建与生成

- `xmake create [options] [name]` / `xmake new`：创建新工程。
  `-l/--language=LANG`（`c`、`c++`、`cuda`、`objc`、`objc++`、`swift`、`rust`、`go`、`dlang`、
  `zig`、`fortran`、`vala`、`nim`、`pascal` 等）、`-t/--template=NAME`（`console`、`static`、
  `shared`、`qt.console`、`qt.widgetapp`、`qt.quickapp`、`tbox`、`xmake-module` 等模板）、
  `-P DIR`。例如：`xmake create -l c++ -t console hello`。
- `xmake project -k KIND [options]`：生成第三方工程文件。`-k` 可取：
  - `vsxmake`（**推荐**的 Visual Studio 工程，复用 xmake 构建）；`vs`（原生 vcxproj，
    可 `--vs=2022`）；`cmake`（CMakeLists.txt）；`ninja`（build.ninja）；`xcode`；
    `makefile`；`compile_commands`（生成 `compile_commands.json` 供 clangd/cmake 使用）；
    `compile_flags`；`ccmd`。
  - `-m "debug,release"`：指定要生成的模式组合；`-o DIR`：输出目录。
  - 例：`xmake project -k compile_commands -x`（实时刷新）。

### 1.4 包管理（详见 §13）

- `xmake require [options] [packages...]`：管理依赖包。
  `--list`、`-i/--info`、`-s/--search=Q`、`--fetch`、`-c/--clean`、`-f/--force`、
  `--mode=`、`--extra=`、`-l/--links`。等价命令推荐用独立的 `xrepo`。
- `xrepo install/remove/update/list/info/search/fetch/scan/clean PKG`：xrepo 包管理子命令。
- `xrepo env [-b prog] / shell / -- cmd`：进入包虚拟环境或在其中执行命令。
- `xmake repo [options]`：管理包仓库。`--add NAME URL [branch]`、`--remove NAME`、
  `--list`、`-u/--update`、`--clear`、`-g/--global`。

### 1.5 扩展、服务与其它

- `xmake update [version]`：更新/升级 xmake 自身。`-s/--scriptonly`（仅更新 lua 脚本）、
  `--uninstall`（卸载）、`--integrate`（集成到 shell）。可指定版本回滚：`xmake update v3.0.7`。
- `xmake lua [script.lua / -c "code"]` / `xmake l`：执行任意 Lua 脚本或交互式 REPL，
  常用于调试内置模块，如 `xmake l os.host`、`xmake l lib.detect.find_program gcc`。
- `xmake macro [name]` / `xmake m`：录制/回放命令宏。`--begin`、`--end`、`-b/-e`、`.show` 等内置宏。
- `xmake watch [options]`：监视文件变化自动重新构建/运行（v2.9+）。`-r/--run`、`-b/--build`、
  `-c/--commands`、`-d/--dirs`。
- `xmake format [files]`：用 clang-format 格式化源码（v2.9+）。
- `xmake service [options]`：远程/分布式编译服务。`--start/--stop/--restart`、
  `--config`、`--logs`，配合 `xmake l private.service.client_config` 与 `-c` 客户端连接。
- `xmake doxygen`：用 doxygen 生成文档（插件）。
- `xmake plugin`：插件管理。

> 提示：几乎所有命令都支持 `xmake <cmd> --help` 查看完整参数；自定义 `task()`（§6）也会
> 作为新命令出现在 `xmake --help` 列表中。

---

## 2. xmake.lua 工程结构总览

一个最小工程：

```lua
target("hello")
    set_kind("binary")     -- 目标类型
    add_files("src/*.c")   -- 源文件
```

典型的较完整工程骨架（注意各 API 所属的作用域）：

```lua
-- 全局描述域：set_xxx/add_xxx 此处为"根作用域"，对所有 target 生效
set_project("myproject")
set_version("1.0.0", {build = "%Y%m%d%H%M"})
set_xmakever("2.9.0")            -- 要求的最低 xmake 版本
add_rules("mode.debug", "mode.release")   -- 引入内置构建模式规则

set_languages("c++20")
set_warnings("all", "error")

add_requires("fmt", "spdlog 1.x")          -- 声明依赖包

option("enable_foo")                        -- 自定义选项
    set_default(false)
    set_showmenu(true)
option_end()

includes("src", "tests")                    -- 包含子工程目录

target("mylib")
    set_kind("static")
    add_files("src/*.cpp")
    add_includedirs("include", {public = true})
    add_packages("fmt")
    if has_config("enable_foo") then
        add_defines("ENABLE_FOO")
    end

target("app")
    set_kind("binary")
    add_deps("mylib")                       -- 依赖其他 target
    add_files("app/*.cpp")
    after_build(function (target)           -- 脚本域回调
        os.cp(target:targetfile(), "$(projectdir)/bin")
    end)
```

**作用域规则**：`target()`/`option()`/`rule()`/`task()`/`package()`/`toolchain()` 会开启一个新作用域，
直到下一个同类块或显式的 `xxx_end()`。在 target 块内的 `add_*`/`set_*` 只作用于该 target；
写在所有块之前/之间的根作用域配置会被其后的 target 继承（受 §4.1 继承规则约束）。

**内置变量（在字符串中用 `$(name)` 引用）**：`$(projectdir)`、`$(buildir)`、`$(curdir)`、
`$(scriptdir)`、`$(programdir)`、`$(globaldir)`、`$(tmpdir)`、`$(os)`、`$(host)`、`$(arch)`、
`$(plat)`、`$(mode)`、`$(kind)`、`$(prefix)`、`$(env XXX)`、`$(reg ...)`、`$(shell cmd)`、
`$(version)`、`$(git ...)`，以及任意配置项 `$(name)`。

---

## 3. 条件判断接口（描述域 / 脚本域通用）

这些函数用于在 `xmake.lua` 中按平台、架构、模式等做条件分支：

- `is_plat(plats...)`：当前目标平台是否匹配（支持 lua 正则，如 `is_plat("android")`、`is_plat("macosx", "iphoneos")`）。
- `is_arch(archs...)`：当前架构是否匹配（如 `is_arch("arm.*")` 匹配所有 arm 变体）。
- `is_os(oss...)`：目标操作系统（`windows`、`linux`、`macosx`、`android`、`ios`、`bsd` 等）。
- `is_mode(modes...)`：构建模式（`debug`、`release` 等）。
- `is_kind(kinds...)`：默认目标类型（`static`/`shared`/`binary`）。
- `is_host(hosts...)`：**编译主机** 操作系统（区别于目标平台；如 NDK 可在多种主机上构建）。
- `is_subhost(hosts...)`：子系统主机（cygwin/msys2 环境下与 `is_host` 不同）。
- `is_subarch(archs...)`：子系统架构。
- `is_cross()`：当前是否为交叉编译。
- `is_config("name", values...)`：某配置项是否等于给定值（支持正则与 lua pattern）。
- `has_config("name", ...)`：某 `option`/配置是否启用（true）。
- `get_config("name")`：取某配置项当前值。
- `has_package("name")`：某依赖包是否已启用（可在 target 内判断包是否可用）。

示例：

```lua
if is_plat("windows") then
    add_defines("WIN32")
elseif is_plat("linux", "macosx") then
    add_syslinks("pthread")
end

if is_mode("debug") then
    set_symbols("debug")
    set_optimize("none")
else
    set_optimize("fastest")
    set_strip("all")
end
```

脚本域中还可用 `os.host()`、`os.arch()`、`os.is_host(...)` 等做更细的判断（见 §10）。

---

## 4. target() 目标描述接口（核心）

`target("name")` 定义一个构建目标，`target_end()` 结束（可省略，下一个块自动结束）。
target 是 xmake 配置的核心，下列接口大多既可写在 target 内，也可写在根作用域作为默认值。

### 4.1 基础设置

- `set_kind(kind)`：目标类型。可选：`binary`（可执行）、`static`（静态库）、`shared`（动态库）、
  `object`（仅生成目标文件）、`headeronly`（仅头文件库，不编译）、`moduleonly`（C++ 模块库）、
  `phony`（伪目标，仅承载脚本/依赖）。
- `set_default(true/false)`：是否为默认构建目标（`xmake` 不指定目标时是否构建/安装/运行）。
- `set_enabled(true/false)`：是否启用该 target（false 时完全不加载）。
- `set_options(name, ...)` / `add_options(name, ...)`：关联 `option()`，使选项配置注入该 target。
- `add_deps(dep, ..., {inherit = true/false})`：声明目标依赖。依赖会被自动按序构建并链接；
  默认继承被依赖目标导出的（public）配置，`{inherit=false}` 关闭继承。
- `set_group("path/group")`：分组（IDE 工程内的虚拟目录 / `xmake build -g` 过滤）。
- `set_license("MIT")`：许可证标注。

**配置继承与可见性**：`add_includedirs/add_defines/add_links/...` 默认是 *private*（仅自身）。
加 `{public = true}` 则导出给依赖它的子目标（接口级）；`{interface = true}` 仅导出不自用。
这与 CMake 的 PRIVATE/PUBLIC/INTERFACE 语义一致。

### 4.2 输出文件控制

- `set_targetdir(dir)`：目标文件输出目录（默认在 `build/` 下）。
- `set_objectdir(dir)`：中间 object 文件目录。
- `set_dependir(dir)`：依赖文件（.d）目录。
- `set_basename("name")`：去掉前后缀的基础文件名。
- `set_filename("libxxx.a")`：完整文件名（覆盖前后缀）。
- `set_prefixname("lib")` / `set_suffixname("-d")` / `set_extension(".so")`：分别设置前缀/后缀/扩展名。
- `set_installdir(dir)`：安装目录。

### 4.3 源文件与文件组

- `add_files("src/*.c", "src/**.cpp", {options})`：添加源文件，支持通配符 `*`（单层）与 `**`（递归）。
  可选项：`{rule = "xxx"}` 指定规则、`{defines=}`、`{cflags=}`、`{cxxflags=}` 等给这批文件单独加 flags、
  `{sourcekind = "cc"}` 指定源类型、`{always_added = true}`。
- `remove_files("src/test/*.c")` / `del_files(...)`：从已添加集合中移除匹配文件（支持通配符）。
- `add_headerfiles("include/(**.h)", {prefixdir=, install=})`：安装的头文件。括号 `()` 内为保留的相对路径结构。
- `add_installfiles("res/*.txt", {prefixdir = "share/foo"})`：安装时附带的资源文件。
- `add_extrafiles("xmake.lua")`：仅在 IDE 工程中显示、不参与编译的额外文件。
- `add_configfiles("config.h.in", {variables = {...}, pattern = "@(.-)@"})`：模板配置文件，
  在配置阶段做变量替换生成（见 §4.16）。

### 4.4 头文件 / 链接目录

- `add_includedirs(dir, ..., {public=, private=, interface=})`：头文件搜索目录（`-I`）。
- `add_sysincludedirs(dir, ...)`：系统头文件目录（`-isystem`，抑制其警告）。
- `add_linkdirs(dir, ...)`：库搜索目录（`-L`）。
- `add_rpathdirs(dir, ..., {install=})`：运行时库搜索路径（`-rpath`），可用 `@loader_path`/`$ORIGIN`。
- `add_frameworkdirs(dir, ...)`：macOS/iOS framework 搜索目录。

### 4.5 链接库

- `add_links("foo", "bar")`：链接非系统库（`-lfoo`），按声明顺序在前。
- `add_syslinks("pthread", "m", "dl")`：系统库链接，**始终排在最后**（保证依赖顺序）。
- `add_frameworks("Foundation", "CoreFoundation")`：链接 Apple framework。
- `add_linkorders("a", "b", {...})`：精确控制链接顺序（v2.8.6+，处理循环依赖/分组）。
- `add_linkgroups("a", "b", {group=true, whole=true})`：把库放入 `--start-group/--end-group`
  或 `--whole-archive`（v2.8.6+）。

### 4.6 宏定义与编译/链接标志

- `add_defines("DEBUG", "VERSION=\"1.0\"")` / `add_undefines("NDEBUG")`：预处理宏（`-D`/`-U`）。
- `add_cflags(flags)`：C 编译标志；`add_cxflags(flags)`：C/C++ 通用标志；
  `add_cxxflags(flags)`：仅 C++ 标志。可加 `{force = true}` 跳过自动检测强制传入，
  或 `{tools = "gcc"}` 仅对特定工具生效。
- `add_mflags / add_mxflags / add_mxxflags`：Objective-C / 通用 / Objective-C++ 标志。
- `add_asflags`：汇编器标志；`add_ldflags`：链接器标志（binary）；
  `add_arflags`：静态库归档标志；`add_shflags`：动态库链接标志（shared）。
- 其它语言：`add_scflags`（Swift）、`add_gcflags`（Go）、`add_dcflags`（D）、`add_rcflags`（Rust）、
  `add_zcflags`（Zig）、`add_fcflags`（Fortran）、`add_vala flags` 等。
- CUDA：`add_cuflags`、`add_culdflags`、`add_cugencodes("native", "sm_70")`、`add_cuflags`。
- 资源：`add_rcflags`（Windows .rc，需配合 rule）、`add_mrcflags`。
- NDK：`add_ndkflags`。

> 抽象 API（`add_defines`/`add_includedirs`/`set_optimize` 等）跨编译器自动映射，**优先使用**；
> 只有当抽象 API 不覆盖某选项时，才退化到 `add_cxxflags` 等原始 flags，并自行处理编译器兼容性。

### 4.7 语言、警告、优化、符号、运行时

- `set_languages("c11", "c++20")` / `set_languages("clatest", "cxxlatest")`：语言标准。
- `set_warnings(level...)`：`none`、`less`、`more`、`all`、`allextra`、`extra`、`pedantic`、`everything`、`error`。
  例：`set_warnings("all", "error")`。
- `set_optimize(level)`：`none`(-O0)、`fast`(-O1)、`faster`(-O2)、`fastest`(-O3)、`smallest`(-Os)、
  `aggressive`(-Ofast)。
- `set_symbols(level...)`：`none`、`debug`、`hidden`、`global`、`local`，以及 msvc 专用的
  `edit`、`embed`（需与 `debug` 组合，v2.3.9+）。例：`set_symbols("debug", "hidden")`。
- `set_strip("debug"/"all")`：去除符号/调试信息。
- `set_fpmodels(model...)`：浮点模型，`fast`、`strict`、`precise`、`except`（v 较新）。
- `set_runtimes("MT"/"MD"/"MTd"/"MDd")`：MSVC 运行时；也支持 `c++_static`/`c++_shared`/`stdc++_static`/
  `stdc++_shared`（libc++/libstdc++ 静态或动态）。
- `set_exceptions("cxx", "objc")` / `set_exceptions("no-cxx")`：异常开关（v2.9+）。
- `set_encodings("utf-8")` / `set_encodings("source:utf-8", "target:utf-8")`：源/执行字符集。
- `set_pcheader("header.h")` / `set_pcxxheader("header.hpp")`：预编译头（PCH）。

### 4.8 工具链与平台覆盖

- `set_toolchains("clang", "yasm")` / `set_toolchains("@muslcc")`：为该 target 指定工具链
  （`@` 前缀表示来自包的工具链，见 §13）。
- `set_toolset("cc", "clang")` / `set_toolset("cxx", "$(env CXX)")`：替换单个工具。
- `set_plat("cross")` / `set_arch("arm64")`：覆盖该 target 的平台/架构（少见，用于混合编译）。
- `set_runtimes(...)`：见上。

### 4.9 包、选项、规则、值

- `add_packages("fmt", "zlib", {public=, links=, configs=})`：绑定 `add_requires` 声明的依赖包。
- `add_options("opt1", "opt2")`：关联自定义选项（同 `set_options`）。
- `add_rules("rule1", "qt.widgetapp", {values})`：应用内置或自定义规则（见 §5、§17）。
- `set_values("key", v1, v2)` / `add_values("key", v)`：给规则传值（如 `set_values("qt.env", ...)`）。
- `set_configvar("HAS_FOO", 1, {quote=false})`：定义供 `add_configfiles` 模板替换的配置变量。

### 4.10 运行环境

- `set_rundir("$(projectdir)/tests")`：`xmake run` 的工作目录。
- `set_runenv("PATH", path)`：覆盖运行环境变量。
- `add_runenvs("PATH", dir1, dir2)`：向环境变量追加（自动用分隔符拼接）。
- `add_tests(...)`：定义测试（见 §4.18）。

### 4.11 编译期探测（用于 option 与 target）

下列接口可探测函数/头文件/类型/代码片段是否可用，常配合 `option()` 或 `set_configvar`：

- `add_cfuncs / add_cxxfuncs("func")`、`add_cincludes / add_cxxincludes("header.h")`、
  `add_ctypes / add_cxxtypes("type")`、`add_cflags`、`add_csnippets / add_cxxsnippets("name", "code", {...})`。
  探测结果会写入配置变量供 config.h 使用。

### 4.12 版本与导出

- `set_version("1.2.3", {build = "%Y%m%d", soname = true})`：设置版本，可生成 `soname`、注入到 config 变量。
- `set_policy("build.optimization.lto", true)`：针对该 target 设策略（见 §15）。

### 4.13 目标级脚本回调（on_/before_/after_）

这些接口接收一个函数，进入**脚本域**，参数通常为 `target` 实例（见 §11 的实例 API）。
每个阶段都有 `on_`（替换默认行为）、`before_`（默认之前）、`after_`（默认之后）三种：

- 加载/配置：`on_load(function (target) ... end)`、`on_config(...)`。
- 构建：`on_build`、`on_build_file(function (target, sourcefile, opt) end)`、
  `on_build_files(function (target, sourcebatch, opt) end)`、`before_build`/`after_build` 等。
- 链接：`on_link`、`before_link`、`after_link`。
- 清理：`on_clean`、`before_clean`、`after_clean`。
- 安装/卸载：`on_install`、`on_uninstall`、`before_/after_` 变体。
- 打包：`on_package`。
- 运行：`on_run`、`before_run`、`after_run`。
- 测试：`on_test`。

示例：

```lua
target("app")
    set_kind("binary")
    add_files("src/*.c")
    after_build(function (target)
        print("built: %s", target:targetfile())
        os.cp(target:targetfile(), "$(buildir)/dist/")
    end)
    on_run(function (target)
        os.execv(target:targetfile(), {"--help"})
    end)
```

### 4.14 多语言专用接口（节选）

- C++ 模块：`set_languages("c++20")` 后，`.mpp`/`.cppm`/`.ixx`/`.cxx` 会被识别为模块单元（见 §16）；
  `add_files("src/*.mpp", {public = true})` 导出模块接口。
- Swift：`set_kind` + `add_files("*.swift")`；`add_scflags`。
- Rust/Go/D/Zig/Nim/Fortran/Vala/Pascal：相应 `add_files("*.rs"/".go"/...)`，
  并用 `add_rcflags`/`add_gcflags`/`add_dcflags`/`add_zcflags`/`add_fcflags` 等。
- Cuda：`add_files("*.cu")`、`add_cugencodes(...)`、`set_values("cuda.build.devlink", true)`。
- Qt：`add_rules("qt.widgetapp"/"qt.console"/"qt.quickapp"/"qt.static"/"qt.shared")`，
  `add_frameworks("QtCore", "QtWidgets")`，`add_files("*.ui", "*.qrc")`，`add_moc/add_rc`。
- WDK/驱动、Protobuf/gRPC（`add_rules("protobuf.cpp")`）、Lex/Yacc（`add_rules("lex","yacc")`）、
  Win SDK 资源（`add_files("*.rc")` + `add_rules("win.sdk.resource")`）等，均通过内置规则支持。

### 4.15 目标分组、批量与正则

`target()` 名称支持在 `xmake build/install -g "lib_*"` 中按 `set_group` 过滤；
也可用 `for ... do target(...) end` 在 Lua 中批量生成目标。

### 4.16 配置文件生成（config.h）

```lua
set_configvar("VERSION", "1.0")
set_configvar("HAS_PTHREAD", 1)
add_configfiles("config.h.in")   -- 形如 #define VERSION "${VERSION}" 的模板
```

模板里 `${VAR}`、`${define VAR}`、`@VAR@`（自定义 pattern）会被替换；
未定义的 `${define X}` 会输出 `/* #undef X */`。

### 4.17 自定义安装命令

在 target 或 rule 中可用 `on_installcmd`/`on_uninstallcmd`/`on_packagecmd`（脚本域）批处理生成
安装命令，供 `xmake install` 与 XPack 共用（见 §9）。

### 4.18 单元测试（add_tests）

```lua
target("test_math")
    set_kind("binary")
    add_files("test_math.cpp")
    add_tests("default")                       -- 默认：运行成功即通过
    add_tests("args", {runargs = {"--all"}})   -- 传参
    add_tests("pass_output", {runargs = "1+1", pass_outputs = "2"})  -- 校验 stdout
    add_tests("fail_output", {fail_outputs = "error"})
    add_tests("group", {group = "math"})       -- 分组，xmake test -g math
```

`add_tests(name, {runargs=, rundir=, runenvs=, pass_outputs=, fail_outputs=, plat=, arch=,
trim_output=, timeout=, group=})`。用 `xmake test [pattern]` 运行，返回非零码或输出匹配判定结果。

---

## 5. option() 自定义选项接口

`option("name") ... option_end()` 定义可在命令行 `--name=value` 或菜单中配置的选项，
也可用作编译期特性探测。

- `set_default(value)`：默认值（布尔或字符串）。
- `set_showmenu(true)`：是否显示在 `xmake f --menu` 菜单和 `--help` 中。
- `set_description("desc", "line2")`：菜单描述。
- `set_category("group")`：菜单分类。
- `set_values("a", "b", "c")`：可选值列表（菜单中可选择）。
- `set_configvar("NAME", value, {quote=})`：选项启用时定义配置变量（写入 config.h）。
- 探测类（决定该选项是否"可用/为真"）：`add_cincludes`、`add_cxxincludes`、`add_cfuncs`、
  `add_cxxfuncs`、`add_ctypes`、`add_cxxtypes`、`add_csnippets`、`add_cxxsnippets`、
  `add_links`、`add_linkdirs`、`add_includedirs`、`add_defines`、`add_cflags` 等。
- `add_deps("other_option")`：选项依赖。
- `on_check(function (option) ... end)` / `after_check(...)`：自定义检测逻辑。
- `set_sourcekind("cxx")`：探测时使用的编译器类型。

示例：探测系统是否有某函数，结果驱动宏定义与链接：

```lua
option("pthread")
    set_default(false)
    set_showmenu(true)
    add_cfuncs("pthread_create")
    add_cincludes("pthread.h")
    add_links("pthread")
    set_configvar("HAVE_PTHREAD", 1)
option_end()

target("app")
    add_options("pthread")
    add_files("src/*.c")
```

`xmake f --pthread=y` 启用；`has_config("pthread")` 在描述域判断；config.h 中得到 `HAVE_PTHREAD`。

---

## 6. task() 自定义任务/插件接口

`task("name") ... task_end()` 定义新的 `xmake <name>` 子命令（即"插件任务"）。

- `set_menu({usage=, description=, options={...}})`：定义命令行菜单与参数。
- `set_category("plugin"/"action"/"build")`：任务分类（`plugin` 会进入插件列表）。
- `on_run(function () ... end)` 或 `on_run("module.function")`：任务执行体（脚本域）。

```lua
task("hello")
    set_menu({
        usage = "xmake hello [options]",
        description = "Say hello.",
        options = {
            {'n', "name", "kv", nil, "Set the name."}
        }})
    on_run(function ()
        import("core.base.option")
        print("hello %s!", option.get("name") or "xmake")
    end)
```

执行：`xmake hello -n world`。`option` 模块用于读取任务参数。

---

## 7. rule() 自定义构建规则接口

规则把一组文件扩展名与一套构建/安装逻辑绑定，可被 `add_rules("name")` 应用到 target，
也可作为依赖被其它 rule 复用。xmake 内置了大量规则（见 §17）。

- `set_extensions(".md", ".in")`：该规则处理的文件扩展名（使 `add_files` 自动应用此规则）。
- `set_kind("object"/"static"/...)`：规则关联的目标类型。
- `add_deps("other.rule", {order = true})` / `add_orders("a", "b")`：规则间依赖与执行顺序。
- `add_imports("core.project.depend")`：预导入模块到所有回调。
- 脚本回调（脚本域）：
  - `on_load(function (target) end)`、`on_config(...)`：加载/配置阶段。
  - `on_build(target, opt)`：整体构建；`on_buildcmd(target, batchcmds, opt)`：生成批处理命令（懒执行，
    更适合并行/IDE）。
  - 逐文件：`on_build_file(target, sourcefile, opt)` / `on_buildcmd_file(target, batchcmds, sourcefile, opt)`。
  - 批量文件：`on_build_files(target, sourcebatch, opt)` / `on_buildcmd_files(...)`。
  - `on_link`、`on_clean`、`on_install` / `on_installcmd`、`on_uninstall` / `on_uninstallcmd`、
    `on_package` / `on_packagecmd`、`on_run`，以及全部 `before_*`/`after_*` 变体。

示例：把 `.md` 编译为 `.html`：

```lua
rule("markdown")
    set_extensions(".md", ".markdown")
    on_build_file(function (target, sourcefile, opt)
        import("core.project.depend")
        import("utils.progress")
        local targetfile = path.join(target:autogendir(), path.basename(sourcefile) .. ".html")
        depend.on_changed(function ()
            progress.show(opt.progress, "${color.build.object}markdown %s", sourcefile)
            os.vrunv("pandoc", {"-o", targetfile, sourcefile})
        end, {files = sourcefile})
    end)

target("docs")
    set_kind("object")
    add_rules("markdown")
    add_files("doc/*.md")
```

`batchcmds`（在 `on_buildcmd_*` 中）支持 `:vrunv`、`:show`、`:mkdir`、`:cp`、`:add_depfiles`、
`:add_depvalues`、`:set_depmtime`、`:set_depcache` 等，用于声明式地生成命令并自动做增量判断。

---

## 8. 全局/工程级描述接口

写在根作用域，影响整个工程与所有子工程文件：

### 8.1 工程元信息

- `set_project("name")`：工程名。
- `set_version("1.2.3", {build = "%Y%m%d%H%M", soname = true})`：版本（可注入配置变量、生成 soname）。
- `set_xmakever("2.9.0")`：要求的最低 xmake 版本。

### 8.2 子工程与目录

- `includes("src", "tests", "**/xmake.lua", {rootdir = "..."})`：包含子目录/子文件。
  支持 `@builtin/...` 内置辅助脚本（v2.8.5+），如 `includes("@builtin/xpack")`（启用 XPack）、
  `includes("@builtin/check")`（检测辅助）。
- `add_moduledirs(dir)`：自定义 import 模块目录。
- `add_plugindirs(dir)`：自定义插件目录。
- `add_repositories("my-repo url [branch]")`：添加包仓库（见 §13）。

### 8.3 模式、平台、架构白名单与默认值

- `add_rules("mode.debug", "mode.release", "mode.releasedbg", "mode.minsizerel", "mode.check",
  "mode.profile", "mode.coverage", "mode.asan", "mode.tsan", "mode.lsan", "mode.ubsan", "mode.valgrind")`：
  启用内置构建模式规则（提供 `-m` 可选模式与默认 flags）。
- `set_allowedplats("windows", "linux", "macosx")`：限制允许的平台。
- `set_allowedarchs("x64", "arm64")`、`set_allowedmodes("debug", "release")`：限制架构/模式。
- `set_defaultplat("linux")`、`set_defaultarchs("x86_64")`、`set_defaultmode("release")`：默认值。

### 8.4 依赖声明（见 §13 展开）

- `add_requires("pkg version", ..., {configs=, optional=, system=, alias=, group=, host=})`。
- `add_requireconfs("pkg.**", {configs = {...}, override = true})`：批量配置依赖（含传递依赖）。
- `add_requirepkgs(...)`：v3 新接口的别名形式。

### 8.5 命名空间与策略

- `namespace("ns", function () ... end)`：命名空间隔离 target/option/rule 名（v2.9.4+），
  内部用 `ns::name` 引用。
- `set_policy("policy.name", value)`：根作用域全局策略（见 §15）。
- `set_config("name", value)`：为配置项设默认值（等价命令行 `xmake f --name=value` 的默认）。
- `get_config("name")`：读取配置。

---

## 9. toolchain() 与 XPack 打包接口

### 9.1 toolchain() 自定义工具链

`toolchain("name") ... toolchain_end()` 定义可复用的工具链，供 `set_toolchains` / `xmake f --toolchain=`。

- `set_kind("standalone")`：工具链类型。
- `set_homepage` / `set_description`。
- `set_toolset("cc", "clang")`、`set_toolset("cxx", "clang", "clang++")`、`set_toolset("ld", ...)`、
  `set_toolset("ar"/"sh"/"as"/"mm"/"mxx"/"sc"/"gc"/"dc"/"rc"/"strip"/"ranlib", ...)`：绑定具体工具。
- `set_sdkdir(dir)` / `set_bindir(dir)` / `set_cross("prefix-")`：SDK / 可执行目录 / 交叉前缀。
- `set_archs("arm64")`、`set_runtimes("MT", "MD")`。
- `add_defines / add_includedirs / add_linkdirs / add_cflags / add_ldflags ...`：工具链级默认 flags。
- `on_check(function (toolchain) return true end)`：探测工具链是否可用。
- `on_load(function (toolchain) ... end)`：加载时动态设置（可读 `toolchain:config(...)`）。

```lua
toolchain("my-clang")
    set_kind("standalone")
    set_toolset("cc", "clang")
    set_toolset("cxx", "clang", "clang++")
    set_toolset("ld", "clang++", "clang")
    on_check(function (toolchain)
        return import("lib.detect.find_tool")("clang")
    end)
toolchain_end()

target("app")
    set_toolchains("my-clang")
```

内置工具链：`msvc`、`clang`、`clang-cl`、`gcc`、`gfortran`、`llvm`、`cross`、`mingw`、`gnu-rm`（arm-none-eabi）、
`ndk`、`xcode`、`emcc`（Emscripten/wasm）、`icc`/`icx`、`zig`、`rust`、`go`、`dlang`、`nim`、
`cosmocc`、`muslcc`、`tinycc`、`circle`、`nvcc`、`wasi`、`gnu-rm` 等。

### 9.2 XPack 安装包描述（需 `includes("@builtin/xpack")`）

`xpack("name") ... ` 生成安装包，常见接口：

- `set_formats("nsis", "zip", "targz", "srpm", "rpm", "deb", "runself", "wix", "srczip", "srctargz")`：包格式。
- `set_version("1.0")`（不设则用绑定 target 或工程版本）。
- `set_homepage / set_title / set_description / set_author / set_maintainer / set_copyright / set_company`。
- `set_license("MIT")` / `set_licensefile("LICENSE")`。
- `set_basename("foo-$(plat)-$(arch)-v$(version)")`。
- `add_targets("foo", "bar")`：绑定要安装的 target（连同其 headerfiles/installfiles 一并打包）。
- `add_installfiles("res/*.txt", {prefixdir = "share"})` / `add_sourcefiles(...)`（源码包）。
- `add_components("LongPath", {...})` + `on_component(...)`：NSIS 组件式安装。
- `set_iconfile("foo.ico")`、`set_bindir / set_libdir / set_includedir / set_prefixdir`。
- 脚本：`on_load`、`before_package`、`on_installcmd`、`on_uninstallcmd`、`after_package`。

```lua
includes("@builtin/xpack")
xpack("myapp")
    set_formats("nsis", "zip")
    set_title("My App")
    set_version("1.0.0")
    add_targets("myapp")
    add_installfiles("(assets/**)", {prefixdir = "assets"})
```

用 `xmake pack` 生成安装包到 `build/xpack/`。

---

## 10. 脚本域内置模块（builtins）

在 `on_*`/`before_*`/`after_*`/`task` 回调中可直接使用以下模块（无需 import）。

### 10.1 内置全局函数

- `print(fmt, ...)` / `printf` / `cprint` / `cprintf`：打印，`cprint` 支持颜色标记
  （如 `cprint("${red}error${clear}")`、`${bright}`、`${green}`、`${dim}`、`${color.build.object}`）。
- `format(fmt, ...)` / `vformat(fmt, ...)`：格式化字符串（`vformat` 还会展开 `$(var)` 内置变量）。
- `raise(msg, ...)`：抛出异常（中断构建）。
- `try { function() ... end, catch { function(errors) ... end }, finally { ... } }`：xmake 的异常处理结构。
- `pairs(t, [filter])` / `ipairs(t, [map], ...)`：扩展版遍历，支持过滤/映射回调。
- `ifelse(cond, a, b)`、`assert(value, msg)`、`inherit(...)`。

### 10.2 os 模块（文件、目录、进程、环境、信息）

文件/目录：`os.cp(src, dst, {rootdir=,symlink=})`、`os.mv`、`os.rm`、`os.trycp`、`os.tryrm`、
`os.cpdir`/`os.mvdir`/`os.rmdir`、`os.mkdir`、`os.cd`、`os.ln(src,link)`、`os.readlink`、
`os.isdir`、`os.isfile`、`os.islink`、`os.exists`、`os.filesize`、
`os.files(pattern)`、`os.dirs(pattern)`、`os.filedirs(pattern)`（通配符列举）。

进程执行：
- `os.run(cmd)` / `os.runv(prog, {args}, {opt})`：静默执行，失败抛异常。
- `os.exec(cmd)` / `os.execv(prog, {args})`：执行并直通输出。
- `os.iorun(cmd)` / `os.iorunv(prog, {args})`：执行并捕获 `(stdout, stderr)`。
- `os.vrun/os.vrunv/os.vexec/os.vexecv`：在 `-v` 下回显命令行的版本。
- `opt` 可含 `{shell=, envs=, curdir=, stdout=, stderr=, try=, timeout=}`。

环境与路径：`os.getenv` / `os.setenv` / `os.addenv` / `os.getenvs`、`os.curdir()`、`os.scriptdir()`、
`os.programdir()`、`os.projectdir()`、`os.tmpdir()`、`os.tmpfile()`、`os.workingdir()`。

系统信息：`os.host()`、`os.arch()`、`os.subhost()`、`os.subarch()`、`os.is_host(...)`、`os.cpuinfo()`、
`os.meminfo()`、`os.nuldev()`、`os.date(fmt)`、`os.time()`、`os.mclock()`、`os.argv()`、`os.args(argv)`、`os.raise`。

### 10.3 io 模块（读写）

- `io.open(path, mode)` → file 对象（`:read`/`:write`/`:lines`/`:close`/`:print`/`:printf`/`:seek`）。
- `io.readfile(path, {encoding=})` / `io.writefile(path, data, {encoding=})`：整文件读写。
- `io.load(path)` / `io.save(path, obj)`：序列化/反序列化 Lua 对象。
- `io.cat(path)` / `io.tail(path, n)` / `io.lines(path)`：查看内容。
- `io.gsub(path, pattern, repl)` / `io.replace(path, pat, repl, {plain=})`：原地替换文件内容。
- `io.print` / `io.printf` / `io.stdin` / `io.stdout` / `io.stderr`。

### 10.4 path 模块

`path.join(a, b, ...)`、`path.directory(p)`、`path.filename(p)`、`path.basename(p)`、
`path.extension(p)`、`path.absolute(p, [rootdir])`、`path.relative(p, [rootdir])`、`path.translate(p)`、
`path.is_absolute(p)`、`path.split(p)`、`path.splitenv(envstr)`、`path.pattern(p)`、
`path.cygwin_path(p)`、`path.unix_path(p)`、`path.envsep()`。

### 10.5 string 模块（在原生基础上扩展）

`s:startswith(x)`、`s:endswith(x)`、`s:split(sep, {plain=, strict=})`、`s:trim()`/`:ltrim()`/`:rtrim()`、
`s:lower()`/`:upper()`、`s:replace(a, b, {plain=})`、`string.format`、`string.pluralize`、
`string.serialize`/`string.deserialize`、`s:lastof(p)`。

### 10.6 table 模块

`table.join(t1, t2, ...)`（合并返回新表）、`table.join2(t1, t2)`（原地合并）、`table.append`、
`table.copy` / `table.clone`、`table.contains(t, v)`、`table.keys(t)` / `table.values(t)` / `table.orderkeys`、
`table.unique(t)`、`table.slice(t, i, j)`、`table.remove_if(t, pred)`、`table.wrap(v)` / `table.unwrap(t)`、
`table.to_array`、`table.concat`、`table.empty`、`table.reverse`。

### 10.7 hash / 其它

- `hash.uuid()`、`hash.md5(str/file)`、`hash.sha1`、`hash.sha256`、`hash.xxhash128`。
- `coroutine`、`bit`（位运算）、`math`、`signal`（v 较新，捕获信号）等也可用。

---

## 11. 脚本域中的实例 API

回调里拿到的 `target`/`package`/`option`/`toolchain` 是对象，常用方法：

### 11.1 target 实例（`target:`）

- `target:name()`、`target:kind()`、`target:targetfile()`、`target:targetdir()`、`target:objectfile(src)`、
  `target:filename()`、`target:basename()`、`target:autogendir()`。
- `target:sourcefiles()`、`target:sourcebatches()`、`target:objectfiles()`、`target:headerfiles()`。
- `target:get("key")` / `target:set("key", v)` / `target:add("key", v)` / `target:values("key")`：
  读写任意配置（如 `target:get("links")`）。
- `target:dep("name")` / `target:deps()` / `target:orderdeps()`：依赖。
- `target:pkg("name")` / `target:pkgs()`：绑定的包。
- `target:has_cfuncs/has_cxxfuncs/has_cincludes/check_csnippets(...)`：脚本内做编译期探测。
- `target:data("key")` / `target:data_set(...)`：自定义数据存储。
- `target:is_plat(...)`、`target:is_arch(...)`、`target:is_binary()` / `:is_shared()` / `:is_static()`。
- `target:installdir()`、`target:rundir()`、`target:scriptdir()`。

### 11.2 package 实例（`package:`，见 §13.5）

`package:name()`、`package:version()`、`package:installdir()`、`package:config("key")`、
`package:has_cfuncs(...)`、`package:is_plat(...)`、`package:is_debug()`、`package:dep(...)`、
`package:fetch()`、`package:librarydeps()` 等。

### 11.3 option / toolchain 实例

option：`option:name()`、`option:enabled()`、`option:value()`、`option:get(...)`、`option:check()`。
toolchain：`toolchain:name()`、`toolchain:tool("cc")`、`toolchain:config(key)`、`toolchain:is_standalone()`。

---

## 12. import：导入扩展模块

`import("module.path", {alias=, rootdir=, inherit=, anonymous=})` 在脚本域加载更强大的模块。常用：

### 12.1 base / project

- `core.base.option`：`option.get("name")` 读任务参数。
- `core.base.task`：`task.run("taskname", {...})` 调度任务。
- `core.base.semver`：版本号比较 `semver.compare`、`semver.satisfies("1.2.0", ">=1.0")`。
- `core.base.json`：`json.encode/decode`。
- `core.project.config`：`config.get("arch")`、`config.buildir()`、`config.plat()`。
- `core.project.project`：`project.targets()`、`project.target("name")`、`project.option(...)`、`project.required_packages()`。
- `core.project.depend`：`depend.on_changed(func, {files=, values=, dependfile=})` 做增量构建。
- `core.project.target`：构造/查询 target。

### 12.2 工具 / 平台

- `core.tool.compiler`：`compiler.compile(...)`、`compiler.compflags(...)`、`compiler.has_flags(...)`。
- `core.tool.linker`：`linker.link(...)`、`linker.linkflags(...)`。
- `core.platform.platform`：`platform.get("arch")`；`core.platform.environment`。

### 12.3 探测（lib.detect）

- `lib.detect.find_program("gcc")`、`find_programver`、`find_tool("clang", {version=})`、
  `find_package("zlib", {system=})`、`find_path`、`find_file`、`find_library`、`find_cudadevices`、
  `check_cxsnippets(...)`、`check_cflags(...)`、`has_cfuncs`/`has_cincludes`/`has_ctypes`。

### 12.4 网络 / 开发 / 工具

- `net.http`：`http.download(url, path)`；`net.fasthttp`；`net.proxy`。
- `devel.git`：`git.clone`、`git.pull`、`git.checkout`、`git.ls_remote`、`git.lastcommit`。
- `utils.archive`：`archive.extract`、`archive.archive`（解压/压缩 zip/tar/gz/xz/7z）。
- `utils.progress`：`progress.show(percent, fmt, ...)` 进度条。
- `utils.binary.bin2c`：把二进制嵌入 C 数组。
- `async.runjobs("name", jobfunc, {total=, comax=})`：并发任务调度。
- `core.cache.localcache` / `core.cache.detectcache`：缓存。

示例（脚本内下载并探测）：

```lua
on_load(function (target)
    import("net.http")
    import("lib.detect.find_package")
    local pkg = find_package("openssl")
    if pkg then
        target:add("links", pkg.links)
        target:add("linkdirs", pkg.linkdirs)
    end
end)
```

---

## 13. 包管理（add_requires / xrepo / 自定义 package）

xmake 内置包管理，官方仓库 `xmake-repo` 提供数百个 C/C++ 包，并可桥接 vcpkg、conan、conda、
homebrew、apt、pacman、pip、cargo 等。

### 13.1 add_requires 声明依赖

```lua
add_requires("tbox 1.6.*", "libpng ~1.16", "zlib")
add_requires("boost", {configs = {iostreams = true}})
add_requires("openssl", {system = false})      -- 强制使用源码包而非系统库
add_requires("libcurl", {optional = true})      -- 可选，找不到不报错
add_requires("llvm 10.x", {alias = "llvm-10"})  -- 别名
add_requires("conan::zlib/1.2.11", {alias = "zlib"})  -- 来自 conan
add_requires("vcpkg::fmt", "brew::pcre2")        -- 第三方包管理器
add_requires("pip::numpy", "cargo::base64")
```

`add_requires(spec, {...})` 选项：
- `system = false`：禁止使用系统已安装库，强制远程下载源码编译。
- `optional = true`：可选依赖。
- `debug = true`：使用调试版本（需包支持）。
- `configs = {shared = true, pic = true, ...}`：传给包的构建配置。
- `alias = "name"`：在 `add_packages` 中使用的别名。
- `version = "1.2.x"`、`group = "ssl"`（互斥分组）、`host = true`（主机工具）、`private = true`、
  `external = false`、`verify = false`、`build = true`。

`add_requireconfs("*.cmake", {...})` / `add_requireconfs("boost.**", {override=true, configs=})`：
批量配置依赖（含传递依赖）。例如统一所有依赖为静态：
```lua
add_requireconfs("*", {configs = {shared = false}})
```

### 13.2 绑定到 target

```lua
target("app")
    set_kind("binary")
    add_files("src/*.c")
    add_packages("tbox", "zlib", "fmt")     -- 自动注入 includedirs/links/defines
```

`add_packages("fmt", {public = true})` 把包传递给依赖此 target 的子目标。

### 13.3 xrepo 命令行包管理

- `xrepo install zlib boost` / `xrepo install "zlib 1.2.x" -j4 -f --shared`：安装包（`-f` 配置项，`-m debug`）。
- `xrepo remove [--all] zlib`、`xrepo update`、`xrepo list`、`xrepo info zlib`、`xrepo search "lib*"`。
- `xrepo fetch --cflags --libs zlib`：取得集成所需的 flags（用于非 xmake 工程）。
- `xrepo env shell`：进入包虚拟环境（PATH/库路径就绪）。
- `xrepo env -- cmake ..` / `xrepo env -b gdb -- ./a.out`：在环境中执行命令/调试。
- `xrepo scan`、`xrepo clean`、`xrepo import/export`（迁移已装包）。

### 13.4 仓库管理

- `xmake repo --add myrepo https://github.com/me/myrepo.git main` / `xmake repo -l` / `xmake repo -u`。
- 工程内：`add_repositories("myrepo https://github.com/me/myrepo.git")`。

### 13.5 编写自定义 package()（用于私有仓库）

放在仓库的 `packages/x/xxx/xmake.lua`：

```lua
package("foo")
    set_homepage("https://example.com")
    set_description("The foo library.")
    set_license("MIT")
    set_urls("https://github.com/org/foo/archive/$(version).tar.gz",
             "https://github.com/org/foo.git")
    add_versions("1.0.0", "<sha256>")
    add_versions("1.1.0", "<sha256>")
    add_deps("zlib", "cmake")
    add_configs("shared", {description = "Build shared library.", default = false, type = "boolean"})
    add_links("foo")
    add_includedirs("include")
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DBUILD_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF")
        })
    end)
    on_test(function (package)
        assert(package:has_cfuncs("foo_init", {includes = "foo.h"}))
    end)
package_end()
```

`package()` 常用接口：`set_kind("library"/"binary"/"toolchain"/"template")`、`set_base("otherpkg")`、
`add_urls(url, {alias=, http_headers=})`、`add_versions`、`add_versionfiles`、`add_patches(version, url, sha256)`、
`add_resources`、`set_sourcedir`、`add_extsources("pkgconfig::foo", "apt::libfoo-dev")`（系统包映射）、
`add_components(...)`、`add_configs`、`on_load`、`on_fetch`、`on_check`、`on_install`、`on_test`、
`on_download`。安装辅助：`import("package.tools.cmake/autoconf/make/meson/ninja/xmake/msbuild/scons/cargo")`。

---

## 14. 交叉编译与工具链

### 14.1 通用交叉编译（cross 平台）

```bash
xmake f -p cross --sdk=/opt/cross-toolchain --arch=arm64
xmake
```

或指定 bin 目录与前缀：
```bash
xmake f -p cross --sdk=/xxx --bin=/xxx/bin --cross=arm-linux-androideabi- --arch=arm
```
也可在 `xmake.lua` 用 `set_toolchains("cross", {sdkdir = "...", cross = "..."})`。

### 14.2 平台预设

- **Android**：`xmake f -p android --ndk=$NDK -a arm64-v8a [--ndk_sdkver=21]`。
- **iOS/watchOS/tvOS**：`xmake f -p iphoneos -a arm64`（macOS + Xcode）。
- **Windows MSVC**：`xmake f -p windows -a x64 --vs=2022 --vs_runtime=MD`。
- **MinGW**：`xmake f -p mingw --mingw=/path/to/mingw -a x86_64`。
- **WebAssembly**：`xmake f -p wasm`（需 emsdk / emcc 工具链）。
- **muslcc 静态交叉**：`add_requires("muslcc"); set_toolchains("@muslcc")`，整条依赖链一起交叉编译。
- **cosmocc**（多平台单一可执行 APE）：`set_toolchains("@cosmocc")`。

### 14.3 工具链选择

`xmake f --toolchain=clang` / `--toolchain=llvm --sdk=/usr/lib/llvm-15` / 来自包：
`add_requires("llvm 15.x", {alias="llvm"}); set_toolchains("llvm@llvm")`。
可同时混用多工具链：`set_toolchains("clang", "nasm")`。

---

## 15. 策略（set_policy）

策略用于微调构建行为，可在根作用域或 target 内设置：`set_policy("name", value)`。
常用策略（节选，完整可查 `xmake l core.project.policy.policies` 或文档）：

- `build.across_targets_in_parallel`（默认 true）：跨目标并行。
- `build.optimization.lto`（true/false）：链接时优化 LTO。
- `build.merge_archive`：合并静态库依赖。
- `build.ccache`（true/false）：是否启用内置缓存。
- `build.warning`：构建时显示警告。
- `build.fence`：模块构建栅栏（C++ modules）。
- `check.auto_ignore_flags`（默认 true）：自动忽略不支持的 flag（关掉可严格报错）。
- `check.auto_map_flags`：自动映射 flag。
- `run.autobuild`：`xmake run` 前自动构建。
- `install.strip_packagelibs`、`package.install_only`、`package.requires_lock`（锁定依赖版本到
  `xmake-requires.lock`）、`package.precompiled`、`package.download.http_headers`。
- `platform.longpaths`（Windows 长路径）。
- `preprocessor.linemarkers`、`preprocessor.gcc.directives_only`。
- `network.mode`（`public`/`private`）。
- `lex.flex` / `yacc.bison` 等工具策略。

```lua
set_policy("build.optimization.lto", true)
set_policy("check.auto_ignore_flags", false)   -- flag 不支持时报错而非静默忽略
```

依赖锁定：`xmake require --lock` 或策略 `package.requires_lock` 生成 `xmake-requires.lock` 固定版本。

---

## 16. C++20/23 模块支持

xmake 原生支持 C++ 模块（无需手动指定依赖顺序，自动扫描）：

```lua
add_rules("mode.debug", "mode.release")
set_languages("c++20")            -- 或 c++23

target("mymod")
    set_kind("static")            -- 也可 moduleonly / shared
    add_files("src/*.cpp")        -- 实现
    add_files("src/*.mpp", {public = true})   -- 模块接口单元（.mpp/.cppm/.ixx/.cxx/.ccm）

target("app")
    set_kind("binary")
    add_deps("mymod")
    add_files("src/main.cpp")
```

要点：模块接口扩展名 `.mpp`（xmake 约定）、`.cppm`、`.ixx`、`.cxx`、`.ccm` 均可；
`{public = true}` 导出模块给依赖者；支持 GCC/Clang/MSVC；标准库模块 `import std;`
通过 `set_policy("build.c++.modules.std", true)` 或工具链支持启用；
头文件单元（header units）也受支持。构建时 xmake 自动做模块依赖扫描与拓扑排序。

---

## 17. 内置规则（add_rules）速查

通过 `add_rules("name")` 应用。常用内置规则：

- 构建模式：`mode.debug`、`mode.release`、`mode.releasedbg`、`mode.minsizerel`、`mode.check`、
  `mode.profile`、`mode.coverage`、`mode.valgrind`、`mode.asan`、`mode.tsan`、`mode.lsan`、`mode.ubsan`。
- C/C++ 通用：`c++`、`c`、`c++.unity_build`（Unity 构建合并编译）、`c.unity_build`、
  `utils.symbols.export_all`（自动导出所有符号，Windows DLL）、
  `utils.symbols.export_list`、`utils.install.cmake_importedlibs`、`utils.install.pkgconfig_importedlibs`。
- 预编译/嵌入：`utils.bin2c`（把二进制转 C 头）、`utils.glsl2spv`（GLSL→SPIR-V）、
  `utils.hlsl2spv`、`utils.ispc`、`utils.merge.object`、`utils.merge.archive`。
- Qt：`qt.console`、`qt.static`、`qt.shared`、`qt.widgetapp`、`qt.quickapp`、`qt.qmldir`、
  `qt.moc`、`qt.ui`、`qt.qrc`。
- WDK：`wdk.driver`、`wdk.binary.driver`、`wdk.umdf.driver`、`wdk.kmdf.driver` 等。
- Windows SDK / DLL：`win.sdk.application`、`win.sdk.resource`、`win.sdk.dotnet`。
- Xcode/Apple：`xcode.application`、`xcode.framework`、`xcode.bundle`。
- 协议/代码生成：`protobuf.cpp`、`protobuf.c`、`grpc.cpp`、`lex`、`yacc`、`flatbuffers`、`thrift`。
- 平台特定：`platform.windows.subsystem`、`platform.linux.driver`。
- LuaJIT/Lua、`module.shared`（可动态加载模块）、`nasm`、`fasm`、`cppfront` 等。

自定义规则见 §7。

---

## 18. 高级特性

### 18.1 编译缓存（xcache）

默认开启本地缓存（类似 ccache）。`xmake g --ccache=y/n` 全局开关；
`set_policy("build.ccache", false)` 工程级关闭。结合远程缓存服务可做团队级缓存。

### 18.2 分布式 / 远程编译（xmake service）

- 服务端：`xmake service --start`（或 `--start -D` 前台）。
- 客户端：`xmake service --connect` 后正常 `xmake`，编译任务分发到远程节点；
  也支持远程编译（在本地编辑、远端构建）与分布式编译（多机负载均衡，lz4 压缩传输）。
- 配置：`xmake service --config` 生成 `~/.xmake/service/server.conf` / `client.conf`。

### 18.3 工程文件生成（与其它工具协作）

```bash
xmake project -k vsxmake -m "debug,release"   # VS 工程（复用 xmake，推荐）
xmake project -k cmake                          # 生成 CMakeLists.txt
xmake project -k ninja                          # build.ninja
xmake project -k compile_commands               # compile_commands.json（clangd/IDE 索引）
xmake project -k xcode                           # Xcode 工程
xmake project -k makefile                        # Makefile
```

`compile_commands` 常配合 `xmake project -k compile_commands -x`（实时刷新）供 VSCode/clangd 使用。

### 18.4 代码覆盖率 / Sanitizers

```lua
add_rules("mode.coverage")     -- 然后 xmake f -m coverage
add_rules("mode.asan")         -- AddressSanitizer：xmake f -m asan
```
或直接 `set_policy("build.sanitizer.address", true)`、`add_cxflags("-fsanitize=address")`。

### 18.5 监视与自动化

`xmake watch -r`：文件变化时自动重新构建并运行（开发热重载）。
`xmake format`：clang-format 格式化。`xmake check clang.tidy`：静态检查。

### 18.6 与 CMake/vcpkg/conan 互操作

- 让别的 CMake 工程用 xmake 装的包：`xrepo fetch --cflags --ldflags pkg`，或生成
  `xmake project -k cmake`。
- 在 xmake 中用 vcpkg/conan 包：`add_requires("vcpkg::fmt")` / `add_requires("conan::zlib/1.2.13")`。
- 在 CMake 工程里调用 xrepo：用 `xrepo.cmake`（`include(xrepo.cmake); xrepo_package("zlib")`）。

---

## 19. 实用约定与常见陷阱

- **抽象优先**：能用 `add_defines/add_includedirs/set_optimize/set_languages/set_warnings` 就别用
  原始 `add_cxxflags("-D.../-I.../-O2/-std=...")`，前者跨编译器自动映射，后者需自管兼容性。
- **链接顺序**：非系统库用 `add_links`（在前），系统库用 `add_syslinks`（自动在后）；
  循环依赖用 `add_linkgroups({group=true})`；不确定时 `xmake -v` 看完整命令行。
- **依赖优于手动链接**：内部库用 `add_deps` 而非手写 `add_links + add_linkdirs`，xmake 自动按序构建链接。
- **public/private 可见性**：库的对外头文件目录/宏要加 `{public = true}` 才会传递给使用方。
- **通配符**：`*` 单层、`**` 递归；`add_headerfiles("inc/(**.h)")` 中括号保留子目录结构。
- **域不要混淆**：`os.*`/`io.*`/`import` 等只能在 `on_*`/`before_*`/`after_*`/`task` 回调（脚本域）里用，
  不能直接顶格写在 target 描述里。描述域里做条件用 `is_plat/is_mode/has_config` 等。
- **重新配置**：改了平台/工具链/选项后用 `xmake f -c` 清配置缓存再配置；改 flags 用 `xmake -r` 重建。
- **查看信息**：`xmake show -l targets`、`xmake show -t app`、`xmake l <module> <args>` 调试内置模块。
- **升级/回滚**：`xmake update`（升级）、`xmake update v3.0.7`（回滚）、`xmake update -s`（仅脚本）。
- **AI 辅助**：官方提供 LLM 优化文档 `https://xmake.io/llms.txt`（索引）与 `https://xmake.io/llms-full.txt`
  （全文）；任何页面加 `.md` 可得 Markdown 版（如 `/api/description/project-target.md`）。

### 最小可用模板（复制即用）

```lua
add_rules("mode.debug", "mode.release")
set_project("demo")
set_version("0.1.0")
set_languages("c++20")
set_warnings("all", "error")

add_requires("fmt")

target("demo")
    set_kind("binary")
    add_files("src/*.cpp")
    add_includedirs("include")
    add_packages("fmt")
    if is_mode("debug") then
        set_symbols("debug")
        set_optimize("none")
    else
        set_strip("all")
        set_optimize("fastest")
    end
```

构建运行：`xmake f -m release && xmake && xmake run demo`。
