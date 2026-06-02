# Subversion Build System - LLM Deep Reference

## Project Overview

This project builds Apache Subversion and all its dependencies from source using xmake. The key challenge is that each sub-project uses a different build system (cmake, autoconf, SCons, custom Configure), and xmake must orchestrate them all.

## Directory Structure

```
/Users/zhouguiqing/Documents/Code/Build/svn/
├── xmake.lua              # Main build configuration (17KB)
├── build.sh               # One-step build wrapper script
├── generate.lua           # Helper to generate serf xmake.lua (unused in final)
├── XMAKE_SKILL.md         # xmake API reference
├── README.md              # Human-readable docs
├── README.llm.md          # This file
│
├── zlib/                  # Compression library
├── libexpat/              # XML parser library
├── openssl/               # TLS/SSL library
├── sqlite/                # Embedded SQL database
├── apr/                   # Apache Portable Runtime
├── apr-util/              # APR utility library
├── serf/                  # HTTP client library
├── subversion/            # Version control system
│
└── build/
    ├── .packages/         # xmake package cache (auto-managed)
    │   ├── z/zlib/latest/<hash>/     # Each package has unique hash
    │   ├── l/libexpat/latest/<hash>/
    │   └── ...
    └── install/           # Final output directory
        ├── bin/           # Executables
        ├── lib/           # Shared libraries
        └── include/       # Headers
```

## Architecture Decisions

### 1. Why Mix Package and Target?

**Problem**: xmake has two build mechanisms:
- `package()`: For external dependencies, uses `on_install` callback
- `target()`: For project targets, uses `add_files` to compile

**Decision**: Use `package()` for most components, `target()` only for serf.

**Reason**:
```
zlib, libexpat, openssl, sqlite, apr, apr-util, subversion
    → Have cmake or autoconf support
    → Use package() with import("package.tools.cmake").install()
    → xmake handles all cross-platform details

serf
    → Only has SCons (Python-based), no cmake/autoconf
    → SCons cannot be called from xmake (would need Python)
    → Use target() with add_files() to compile directly
    → xmake handles compiler selection (cc/cl/clang)
```

### 2. Why serf Cannot Be a Package

**Attempted approaches that failed**:

1. **Call SCons from on_install**: SCons requires Python, adds dependency
2. **Call xmake from on_install**: Causes deadlock (xmake holds project lock)
3. **Use `import("core.tool.compiler")` API**: Also causes deadlock (same lock)
4. **Use `os.vrunv("cc", ...)` directly**: Works but not cross-platform

**Final solution**: Define serf as a `target()` with `add_files()`:
```lua
target("serf")
    set_kind("shared")
    add_files("serf/context.c", "serf/buckets/*.c", "serf/auth/*.c")
    -- xmake automatically selects cc/cl/clang based on platform
target_end()
```

This is the ONLY way to build serf without external tools and without deadlock.

### 3. Why Two-Step Build?

**Problem**: serf is a `target()`, subversion is a `package()`. They have different build triggers:
- `target()`: Built by `xmake build`
- `package()`: Built by `xmake require` or `add_requires`

**Why not one step?**
```lua
-- This WON'T work:
add_requires("subversion")  -- Tries to install subversion package
target("svn-build")
    add_deps("serf")        -- serf not built yet!
    add_packages("subversion")  -- subversion's on_install runs, can't find serf
```

The `package("subversion").on_install` runs during `xmake build`, but serf target hasn't been compiled yet. cmake fails with "Could NOT find Serf".

**Solution**: Two separate commands:
```bash
xmake build -y svn-build      # Step 1: Build serf target
xmake require -y subversion   # Step 2: Build subversion package (serf now exists)
```

### 4. Why Use `on_load` for serf?

**Problem**: serf needs to find header files from apr, openssl, zlib etc. These paths are in xmake's package cache (`build/.packages/<letter>/<name>/<hash>/`), with unpredictable hash values.

**Attempted approaches**:

1. **Hardcode paths**: Won't work, hash changes on rebuild
2. **Use `add_packages("apr")`**: Doesn't inject include/link paths into target
3. **Use `target:pkg("apr")`**: Returns nil because package not bound to target via `add_packages`
4. **Use `project.required_package("apr")`**: Works!

**Final solution**:
```lua
target("serf")
    on_load(function (target)
        import("core.project.project")
        local pkg = project.required_package("apr")
        if pkg then
            local dir = pkg:installdir()
            target:add("includedirs", path.join(dir, "include"))
            target:add("linkdirs", path.join(dir, "lib"))
        end
        target:add("links", "ssl", "crypto", "z", "apr-1", "aprutil-1")
    end)
target_end()
```

**Why `on_load` and not `on_build`?**
- `on_load`: Runs when target is loaded, before any build step
- `on_build`: Runs during compilation, too late for include paths
- Include paths must be available at load time for the compiler to find headers

### 5. Why `{public = true}` for Include Paths?

```lua
target:add("includedirs", path.join(dir, "include"), {public = true})
```

**Reason**: If another target depends on serf (e.g., subversion in future), it needs to inherit serf's include paths. `{public = true}` makes the path transitive.

Without it, any target doing `add_deps("serf")` wouldn't get apr/openssl headers.

### 6. Why Each Package Uses Specific Build Method

| Package | Method | Reason |
|---------|--------|--------|
| zlib | cmake | Has CMakeLists.txt, cmake is most cross-platform |
| libexpat | cmake | Has CMakeLists.txt, disables tools/examples |
| openssl | Configure/make | No cmake, uses Perl Configure script |
| sqlite | autoconf (Unix), cl/link (Windows) | Has configure on Unix, direct compile on Windows |
| apr | autoconf (Unix), cmake (Windows) | CMakeLists.txt has bugs on macOS (includes win32 files) |
| apr-util | autoconf (Unix), cmake (Windows) | Needs apr source path for buildconf |
| serf | xmake target | No cmake/autoconf, only SCons (unusable) |
| subversion | cmake | Has CMakeLists.txt, needs python3 gen-make.py first |

### 7. Why apr Uses autoconf on macOS?

**Problem**: apr's CMakeLists.txt includes both unix and win32 source files unconditionally:
```cmake
SET(APR_SOURCES
  atomic/win32/apr_atomic.c    # Should be unix/ on macOS!
  file_io/unix/copy.c
  file_io/win32/buffer.c       # This fails on macOS
  ...
)
```

This causes compilation errors on macOS because win32 headers don't exist.

**Solution**: Use autoconf which correctly selects platform-specific files:
```lua
on_install("linux", "macosx", function (package)
    os.vrunv("sh", {"./buildconf"})  -- Generates configure from configure.in
    import("package.tools.autoconf").install(package, configs)
end)
on_install("windows", function (package)
    import("package.tools.cmake").install(package, configs)  -- cmake works on Windows
end)
```

### 8. Why apr-util Needs Source Path?

```lua
os.vrunv("sh", {"./buildconf", "--with-apr=" .. apr_src})
```

apr-util's `buildconf` script needs the APR **source directory** (not installed directory) to generate configure. This is because it shares some m4 macros from apr's source.

### 9. Why Remove Static Libraries?

```lua
os.rm(path.join(packagedir, "lib", "*.a"))
```

**Reason**: We want only shared libraries for:
1. Smaller distribution size
2. Single copy of code in memory
3. Easier dependency management
4. User requirement: "编译成动态库"

### 10. Why `add_requireconfs("*", {system = false})`?

```lua
add_requireconfs("*", {system = false})
```

**Reason**: Without this, xmake may detect system-installed libraries (e.g., macOS has zlib.dylib in /usr/lib) and skip building from source. We want consistent builds from our local sources.

### 11. Install Script Design

The `subversion-install` target copies files from xmake's package cache to `build/install/`:

```lua
-- Package cache structure:
build/.packages/
├── z/zlib/latest/<hash>/lib/libz.dylib
├── l/libexpat/latest/<hash>/lib/libexpat.dylib
├── o/openssl/latest/<hash>/lib/libssl.dylib
└── ...
```

**Why not use `xmake install` directly?**
- Each package installs to its own hash-named directory
- We want everything in one flat `build/install/` for distribution
- Need to fix rpath/dylib paths for portability

### 12. macOS Rpath Fix

**Problem**: Dynamic libraries reference each other by absolute path:
```
libsvn_client-1.dylib:
    /Users/.../build/.packages/a/apr/latest/<hash>/lib/libapr-1.0.dylib
```

This breaks when moved to another machine.

**Solution**: Three-step fix:
1. Change library install names to `@rpath/`:
   ```bash
   install_name_tool -id @rpath/libapr-1.0.dylib libapr-1.0.dylib
   ```
2. Update all references in libraries:
   ```bash
   install_name_tool -change /old/path @rpath/libapr-1.0.dylib libfoo.dylib
   ```
3. Add rpath to binaries:
   ```bash
   install_name_tool -add_rpath @executable_path/../lib svn
   ```

Result: `svn` looks for libraries relative to itself, portable across machines.

### 13. Linux Rpath Fix

```bash
patchelf --set-rpath $ORIGIN/../lib svn
```

`$ORIGIN` expands to the directory containing the executable, making it relative.

### 14. Windows Handling

On Windows:
- DLLs must be in same directory as executables (or in PATH)
- The install script copies `.dll` files from `lib/` to `bin/`
- No rpath equivalent needed

### 15. Why `build.sh` Wrapper?

**Problem**: xmake cannot orchestrate target→package ordering in one command.

**Solution**: Shell script that runs three commands sequentially:
```bash
#!/bin/bash
xmake build -y svn-build      # Build serf target
xmake require -y subversion   # Build subversion package
xmake install -y subversion-install  # Copy to build/install
```

## xmake.lua Structure

```
xmake.lua
├── Global settings (set_xmakever, add_rules, add_requireconfs)
├── Package definitions (1-7)
│   ├── zlib (cmake)
│   ├── libexpat (cmake)
│   ├── openssl (Configure/make)
│   ├── sqlite (autoconf/cl)
│   ├── apr (autoconf/cmake)
│   ├── apr-util (autoconf/cmake)
│   └── subversion (cmake)
├── add_requires() - triggers package installation
├── Target: serf (add_files, on_load for deps)
├── Target: svn-build (phony, depends on serf)
└── Target: subversion-install (phony, copies files + fixes rpath)
```

## Key xmake APIs

```lua
-- Package system
package("name")
    set_sourcedir(path)           -- Local source directory
    add_deps("dep1", "dep2")     -- Package dependencies
    on_install(function (pkg)     -- Build callback
        import("package.tools.cmake").install(pkg, configs)
        import("package.tools.autoconf").install(pkg, configs)
    end)
package_end()

-- Target system
target("name")
    set_kind("shared")            -- shared/static/binary/phony
    add_files("src/*.c")          -- Source files (glob supported)
    add_includedirs("include")    -- Include paths
    add_links("lib1")             -- Libraries to link
    add_syslinks("pthread")       -- System libraries (always last)
    on_load(function (target)     -- Load callback (before build)
        target:add("includedirs", dir)
    end)
    after_build(function (target) -- After build callback
        os.cp(src, dst)
    end)
target_end()

-- Package queries
import("core.project.project")
local pkg = project.required_package("name")
local dir = pkg:installdir()      -- Get install directory

-- File operations
os.cp(src, dst)                   -- Copy
os.mkdir(dir)                     -- Create directory
os.rm(pattern)                    -- Remove files
os.vrunv("cmd", {"args"})        -- Run command (verbose)

-- Platform detection
is_plat("macosx", "linux", "windows")
is_arch("x86_64", "arm64")
package:is_plat("macosx")
package:is_arch("arm64")
```

## Build Flow Diagram

```
xmake build -y svn-build
│
├── [1] Install packages via add_requires:
│   ├── zlib (cmake) → build/.packages/z/zlib/<hash>/
│   ├── libexpat (cmake) → build/.packages/l/libexpat/<hash>/
│   ├── openssl (Configure) → build/.packages/o/openssl/<hash>/
│   ├── sqlite (autoconf) → build/.packages/s/sqlite/<hash>/
│   ├── apr (autoconf) → build/.packages/a/apr/<hash>/
│   └── apr-util (autoconf) → build/.packages/a/apr-util/<hash>/
│
├── [2] Build serf target:
│   ├── on_load: Find apr/openssl/zlib paths from package cache
│   ├── add_files: Compile serf/*.c, serf/buckets/*.c, serf/auth/*.c
│   ├── Link: -lssl -lcrypto -lz -lapr-1 -laprutil-1
│   ├── Output: build/install/lib/libserf-1.dylib
│   └── after_build: Copy headers to build/install/include/serf-1/
│
└── [3] Done (subversion not built yet)

xmake require -y subversion
│
└── [1] Install subversion package:
    ├── gen-make.py -t cmake (generate cmake targets)
    ├── cmake with CMAKE_PREFIX_PATH=build/install
    ├── Finds serf in build/install/lib + build/install/include/serf-1
    └── Output: build/.packages/s/subversion/<hash>/

xmake install -y subversion-install
│
├── [1] Copy from .packages to build/install/
│   ├── lib/ (all .dylib/.so/.dll, skip .a)
│   ├── bin/ (all executables)
│   └── include/ (all headers)
│
├── [2] Fix macOS rpaths:
│   ├── install_name_tool -id @rpath/libfoo.dylib
│   ├── install_name_tool -change /old/path @rpath/libfoo.dylib
│   └── install_name_tool -add_rpath @executable_path/../lib
│
└── [3] Done (ready for distribution)
```

## Common Issues and Solutions

### Issue: `apr_pools.h file not found`
**Cause**: serf compiled before apr package installed
**Fix**: Ensure `xmake build -y svn-build` runs before `xmake require -y subversion`

### Issue: `Could NOT find Serf` (cmake error)
**Cause**: subversion's cmake can't find serf library
**Fix**: serf must be built first and installed to `build/install/`

### Issue: `xmake` hangs/deadlocks
**Cause**: Calling `xmake` or `os.vrunv("cc", ...)` inside `on_install` callback
**Root cause**: xmake holds project-level lock, child process waits for same lock
**Fix**: Use `add_files()` in target, not manual compilation in package

### Issue: `dyld Library not loaded` (macOS)
**Cause**: Absolute paths in dylib references
**Fix**: Run `xmake install -y subversion-install` which fixes rpaths

### Issue: `target:pkg("name")` returns nil
**Cause**: Package not bound to target via `add_packages()`
**Fix**: Use `project.required_package("name")` instead

### Issue: `cannot import module: package.manager.install_requires`
**Cause**: Module doesn't exist in xmake
**Fix**: Don't try to install packages from within callbacks

### Issue: Windows serf compilation fails
**Cause**: serf needs Windows system libraries
**Fix**: Add `add_syslinks("ws2_32", "crypt32", "rpcrt4", "advapi32", "user32", "gdi32")`

## Design Principles

1. **Never call xmake from xmake**: Avoids deadlock
2. **Use add_files, not manual compilation**: Cross-platform automatically
3. **Use {public = true} for transitive deps**: Include paths propagate
4. **Use project.required_package()**: Reliable way to find packages
5. **Fix rpaths at install time**: Ensures portability
6. **Remove static libs**: Only keep shared for distribution
7. **Use system = false**: Consistent builds from source
