# Subversion Build System - LLM Reference

## Project Structure

```
/Users/zhouguiqing/Documents/Code/Build/svn/
├── xmake.lua          # Main build configuration (17KB)
├── build.sh           # One-step build script
├── generate.lua       # Helper script for serf
├── XMAKE_SKILL.md     # xmake reference manual
│
├── zlib/              # Compression library (cmake)
├── libexpat/          # XML parser (cmake)
├── openssl/           # TLS/SSL (Configure/make)
├── sqlite/            # Database (autoconf)
├── apr/               # Apache Portable Runtime (autoconf/cmake)
├── apr-util/          # APR utilities (autoconf/cmake)
├── serf/              # HTTP client (xmake target)
├── subversion/        # VCS (cmake)
│
└── build/
    ├── .packages/     # xmake package cache
    └── install/       # Output directory
        ├── bin/       # Executables (svn, svnadmin, etc.)
        ├── lib/       # Shared libraries (.dylib/.so/.dll)
        └── include/   # Headers
```

## Build System

**Tool**: xmake v2.8.0+ (Lua-based build system)

**Key files**:
- `xmake.lua`: Defines 7 packages + 2 targets
- `build.sh`: Wrapper script (3 steps)

## Dependencies

```
subversion (package, cmake)
├── sqlite (package, autoconf)
├── openssl (package, Configure/make)
│   └── zlib (package, cmake)
├── serf (target, xmake add_files)
│   ├── apr (package, autoconf/cmake)
│   │   └── libexpat (package, cmake)
│   ├── apr-util (package, autoconf/cmake)
│   │   ├── apr
│   │   └── libexpat
│   ├── openssl
│   └── zlib
├── apr
├── apr-util
├── libexpat
└── zlib
```

## Package vs Target

| Component | Type | Build Method | Reason |
|-----------|------|--------------|--------|
| zlib | package | cmake | Has CMakeLists.txt |
| libexpat | package | cmake | Has CMakeLists.txt |
| openssl | package | Configure/make | No cmake, uses Perl |
| sqlite | package | autoconf | Has configure script |
| apr | package | autoconf/cmake | Both available |
| apr-util | package | autoconf/cmake | Both available |
| serf | target | xmake add_files | No cmake, SCons only |
| subversion | package | cmake | Has CMakeLists.txt |

## Build Commands

```bash
# Full build (recommended)
./build.sh

# Manual steps
xmake build -y svn-build      # Build serf + install deps
xmake require -y subversion   # Build subversion
xmake install -y subversion-install  # Copy to build/install

# Clean
rm -rf build .xmake
```

## xmake.lua Architecture

### Packages (on_install callbacks)

```lua
package("zlib")
    set_sourcedir(path.join(rootdir, "zlib"))
    on_install(function (package)
        import("package.tools.cmake").install(package, {...})
    end)
package_end()
```

### Serf Target (on_load callback)

```lua
target("serf")
    set_kind("shared")
    add_files("serf/*.c", "serf/buckets/*.c", "serf/auth/*.c")
    on_load(function (target)
        -- Dynamically find package paths
        import("core.project.project")
        local pkg = project.required_package("apr")
        target:add("includedirs", pkg:installdir() .. "/include")
        target:add("links", "ssl", "crypto", "z", "apr-1", "aprutil-1")
    end)
target_end()
```

### Install Target (after_install callback)

```lua
target("subversion-install")
    set_kind("phony")
    on_install(function (target)
        -- Copy from .packages cache to build/install
        -- Fix rpath (macOS: install_name_tool, Linux: patchelf)
    end)
target_end()
```

## Cross-Platform Handling

### macOS
- Compiler: cc (Apple Clang)
- Library extension: .dylib
- Rpath fix: `install_name_tool -id @rpath/libfoo.dylib`
- Binary fix: `install_name_tool -add_rpath @executable_path/../lib`

### Linux
- Compiler: cc (gcc/clang)
- Library extension: .so
- Rpath fix: `patchelf --set-rpath $ORIGIN`

### Windows
- Compiler: cl (MSVC)
- Library extension: .dll + .lib
- System libs: ws2_32, crypt32, rpcrt4, advapi32, user32, gdi32

## Key xmake APIs Used

```lua
-- Package management
add_requires("pkg", {system = false})
add_requireconfs("*", {system = false})

-- Package definition
package("name")
    set_sourcedir(path)
    add_deps("dep1", "dep2")
    on_install(function (package)
        import("package.tools.cmake").install(package, configs)
        import("package.tools.autoconf").install(package, configs)
    end)
package_end()

-- Target definition
target("name")
    set_kind("shared"/"static"/"binary"/"phony")
    add_files("src/*.c")
    add_includedirs("include", {public = true})
    add_links("lib1", "lib2")
    add_syslinks("pthread")
    on_load(function (target) ... end)
    after_build(function (target) ... end)
    on_install(function (target) ... end)
target_end()

-- Script domain
os.vrunv("cmd", {"arg1", "arg2"})
os.cp(src, dst)
os.mkdir(dir)
import("core.project.project")
project.required_package("name")
```

## Output Structure

```
build/install/
├── bin/
│   ├── svn                    # Main client
│   ├── svnadmin               # Repo admin
│   ├── svnserve               # Server
│   ├── svnlook                # Repo inspector
│   ├── svndumpfilter          # Dump filter
│   ├── svnsync                # Repo sync
│   ├── svnversion             # WC version
│   ├── svnbench               # Benchmark
│   ├── svnmucc                # Multi-URL commit
│   ├── svnrdump               # Remote dump
│   ├── svnfsfs                # FSFS tool
│   ├── openssl                # OpenSSL CLI
│   ├── sqlite3                # SQLite CLI
│   ├── apr-1-config           # APR config
│   └── apu-1-config           # APR-util config
├── lib/
│   ├── libsvn_client-1.dylib  # SVN client lib
│   ├── libsvn_delta-1.dylib   # SVN delta lib
│   ├── libsvn_fs-1.dylib      # SVN filesystem
│   ├── libsvn_ra-1.dylib      # SVN remote access
│   ├── libsvn_repos-1.dylib   # SVN repository
│   ├── libsvn_subr-1.dylib    # SVN utilities
│   ├── libsvn_wc-1.dylib      # SVN working copy
│   ├── libserf-1.dylib        # HTTP client
│   ├── libapr-1.dylib         # APR
│   ├── libaprutil-1.dylib     # APR-util
│   ├── libssl.dylib           # OpenSSL SSL
│   ├── libcrypto.dylib        # OpenSSL crypto
│   ├── libz.dylib             # zlib
│   ├── libexpat.dylib         # Expat XML
│   └── libsqlite3.dylib       # SQLite
└── include/
    ├── svn/                   # SVN headers
    ├── serf-1/                # Serf headers
    ├── apr-1/                 # APR headers
    ├── openssl/               # OpenSSL headers
    ├── expat.h                # Expat header
    ├── sqlite3.h              # SQLite header
    ├── zlib.h                 # zlib header
    └── zconf.h                # zlib config
```

## Version Information

| Component | Version | License |
|-----------|---------|---------|
| Subversion | 1.16.0-dev | Apache-2.0 |
| APR | 1.7.6 | Apache-2.0 |
| APR-util | 1.7.0 | Apache-2.0 |
| OpenSSL | 1.1.1w | Apache-2.0 |
| SQLite | 3.54.0 | Public Domain |
| zlib | 1.3.2 | zlib |
| libexpat | 2.8.1 | MIT |
| serf | 1.3.10 | Apache-2.0 |

## Platform Compatibility

| Platform | Architecture | Status |
|----------|--------------|--------|
| macOS | arm64 | ✅ Tested |
| macOS | x86_64 | ✅ Supported |
| Linux | x86_64 | ✅ Supported |
| Linux | arm64 | ✅ Supported |
| Windows | x64 | ⚠️ Needs testing |
| Windows | x86 | ⚠️ Needs testing |

## Build Time Estimate

| Step | Time (first build) | Time (cached) |
|------|-------------------|---------------|
| zlib | ~5s | instant |
| libexpat | ~5s | instant |
| openssl | ~60s | instant |
| sqlite | ~10s | instant |
| apr | ~15s | instant |
| apr-util | ~10s | instant |
| serf | ~2s | instant |
| subversion | ~30s | instant |
| install | ~5s | ~5s |
| **Total** | **~2-3 min** | **~10s** |

## Troubleshooting

### Issue: `apr_pools.h not found`
**Cause**: Dependencies not built yet
**Fix**: Run `xmake build -y svn-build` first

### Issue: `Could NOT find Serf`
**Cause**: serf not built before subversion
**Fix**: Run `xmake build -y svn-build` before `xmake require -y subversion`

### Issue: `dyld Library not loaded` (macOS)
**Cause**: Rpath not set correctly
**Fix**: Run `xmake install -y subversion-install` to fix paths

### Issue: `xmake` command hangs
**Cause**: Deadlock from calling xmake inside xmake callback
**Fix**: Kill process, use `build.sh` instead of manual commands
