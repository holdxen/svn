
set_xmakever("2.8.0")

add_rules("mode.debug", "mode.release")

-- Force all packages to build from source, not use system packages
add_requireconfs("*", {system = false})

local rootdir = os.scriptdir()

-- sqlite backend: "amalgamation" (pre-built sqlite3.c) or "source" (from src/*.c)
-- On Windows, amalgamation is always used (source requires tclsh for generated files)
option("sqlite_backend")
    set_default("auto")
    set_showmenu(true)
    set_description("sqlite backend: auto | amalgamation | source")
    set_values("auto", "amalgamation", "source")
option_end()

-- ============================================================
-- Package definitions
-- ============================================================

-- 1. zlib
package("zlib")
    set_sourcedir(path.join(rootdir, "zlib"))
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
        })
    end)
package_end()

-- 2. libexpat
package("libexpat")
    set_sourcedir(path.join(rootdir, "libexpat", "expat"))
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DEXPAT_BUILD_TOOLS=OFF",
            "-DEXPAT_BUILD_EXAMPLES=OFF",
            "-DEXPAT_BUILD_TESTS=OFF",
            "-DEXPAT_BUILD_DOCS=OFF",
        })
    end)
package_end()

-- 3. openssl
package("openssl")
    set_sourcedir(path.join(rootdir, "openssl"))
    add_deps("zlib")
    on_install(function (package)
        local packagedir = package:installdir()
        local zlib_dir = package:dep("zlib"):installdir()
        -- Clean stale build artifacts from previous builds in the source tree,
        -- otherwise old object files get linked alongside new ones causing errors
        try
        {
            function ()
                if package:is_plat("windows") then
                    os.vrunv("nmake", {"clean"}, {try = true})
                else
                    os.vrunv("make", {"clean"}, {try = true})
                end
            end,
            catch
            {
                function (errors)
                    print("warning: failed to clean")
                    print(errors)
                end
            }
        }
        -- On Windows, OpenSSL's Configure expects the full path to the .lib file
        -- for --with-zlib-lib (not a directory like on Unix with -L prefix)
        local zlib_lib_path
        if package:is_plat("windows") then
            zlib_lib_path = path.join(zlib_dir, "lib", "zlib.lib")
        else
            zlib_lib_path = path.join(zlib_dir, "lib")
        end
        local configs = {
            "shared", "zlib",
            "--prefix=" .. packagedir,
            "--openssldir=" .. packagedir .. "/ssl",
            "--with-zlib-include=" .. path.join(zlib_dir, "include"),
            "--with-zlib-lib=" .. zlib_lib_path,
        }
        if package:is_debug() then table.insert(configs, "-g") end
        if package:is_plat("macosx") then
            table.insert(configs, 1, package:is_arch("x86_64") and "darwin64-x86_64-cc" or "darwin64-arm64-cc")
        elseif package:is_plat("linux") then
            if package:is_arch("x86_64") then
                table.insert(configs, 1, "linux-x86_64")
            elseif package:is_arch("x86") then
                table.insert(configs, 1, "linux-elf")
            elseif package:arch() == "arm64-v8a" or package:arch() == "aarch64" or package:arch() == "arm64" then
                table.insert(configs, 1, "linux-aarch64")
            end
        elseif package:is_plat("windows") then
            table.insert(configs, 1, package:is_arch("x64") and "VC-WIN64A" or "VC-WIN32")
            os.vrunv("perl", table.join({"Configure"}, configs))
            os.vrunv("nmake")
            os.vrunv("nmake", {"install_sw"})
            os.rm(path.join(packagedir, "lib", "*.a"))
            os.rm(path.join(packagedir, "lib", "*.lib"))
            return
        end
        os.vrunv("perl", table.join({"Configure"}, configs))
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install_sw"})
        os.rm(path.join(packagedir, "lib", "*.a"))
    end)
package_end()

-- 4. sqlite backend
-- Use --sqlite_backend=amalgamation|source to choose (default: auto).
-- On Windows, amalgamation is always used (source build requires tclsh).
-- g_sqlite_headers_dir is set in on_load and used in after_build.
local g_sqlite_headers_dir = nil

target("sqlite3")
    set_kind("shared")
    set_targetdir(path.join(rootdir, "build", "install", "lib"))
    if is_plat("linux") then
        add_syslinks("pthread", "dl", "m")
    elseif is_plat("windows") then
        add_defines("SQLITE_API=__declspec(dllexport)")
        add_cxflags("/MD")
        add_syslinks("msvcrt")
    end
    on_load(function (target)
        local backend = get_config("sqlite_backend") or "auto"
        -- Windows always uses amalgamation (source build needs tclsh for generated files)
        if is_plat("windows") and backend ~= "amalgamation" then
            backend = "amalgamation"
            if get_config("sqlite_backend") == "source" then
                print("warning: --sqlite_backend=source is not supported on Windows, using amalgamation.")
            end
        end

        local amalgamation_dir = nil
        for _, d in ipairs(os.dirs(path.join(os.scriptdir(), "sqlite-amalgamation-*"))) do
            amalgamation_dir = d
            break
        end

        if backend == "amalgamation" or (backend == "auto" and amalgamation_dir) then
            if not amalgamation_dir then
                raise("Amalgamation directory not found (sqlite-amalgamation-*/).\n"
                    .. "Download from https://sqlite.org/download.html and extract to project root.")
            end
            if not os.isfile(path.join(amalgamation_dir, "sqlite3.c")) then
                raise("sqlite3.c not found in " .. amalgamation_dir)
            end
            target:add("files", path.join(amalgamation_dir, "sqlite3.c"))
            target:add("includedirs", amalgamation_dir)
            g_sqlite_headers_dir = amalgamation_dir
            print("sqlite3: using amalgamation backend (" .. path.filename(amalgamation_dir) .. ")")
        else
            -- Source backend (requires generated files: parse.c, opcodes.c, etc.)
            local sqlite_src = path.join(os.scriptdir(), "sqlite", "src")
            if not os.isdir(sqlite_src) then
                raise("sqlite source directory not found at sqlite/src/")
            end
            target:add("files", path.join(sqlite_src, "*.c"))
            target:add("files", path.join(os.scriptdir(), "sqlite", "src", "test_demovfs.c"))
            for _, f in ipairs(os.files(path.join(sqlite_src, "test*.c"))) do
                target:remove("files", f)
            end
            target:remove("files", path.join(sqlite_src, "tclsqlite.c"))
            target:add("includedirs", sqlite_src)
            target:add("includedirs", path.join(os.scriptdir(), "sqlite"))
            target:add("defines", "SQLITE_CORE")
            g_sqlite_headers_dir = path.join(os.scriptdir(), "sqlite")
            print("sqlite3: using source backend")
        end
    end)
    after_build(function (target)
        if not g_sqlite_headers_dir then return end
        local installdir = path.join(os.scriptdir(), "build", "install")
        local incdir = path.join(installdir, "include")
        os.mkdir(incdir)
        os.cp(path.join(g_sqlite_headers_dir, "sqlite3.h"), incdir)
        os.cp(path.join(g_sqlite_headers_dir, "sqlite3ext.h"), incdir)

        local pcdir = path.join(installdir, "lib", "pkgconfig")
        os.mkdir(pcdir)
        local pc_content = [[
prefix=${pcfiledir}/../..
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: sqlite3
Description: SQLite database engine
Version: 3.53.2
Libs: -L${libdir} -lsqlite3
Libs.private: -lpthread -ldl -lm
Cflags: -I${includedir}
]]
        io.writefile(path.join(pcdir, "sqlite3.pc"), pc_content)
    end)
target_end()

-- 5. apr
package("apr")
    set_sourcedir(path.join(rootdir, "apr"))
    add_deps("libexpat")
    on_load(function (package)
        if package:is_plat("windows") then
            package:add("syslinks", "wsock32", "ws2_32", "advapi32", "shell32", "rpcrt4")
        end
    end)
    on_install("linux", "macosx", function (package)
        local configs = {
            "--prefix=" .. package:installdir(),
            "--enable-shared",
            "--enable-static=no",
            "--enable-nonportable-atomics",
        }
        -- Clean stale build files from previous runs
        if os.isfile("Makefile") then
            os.vrunv("make", {"distclean"}, {try = true})
        end
        if package:is_plat("linux") then
            os.vrunv("sh", {"./buildconf"})
            io.replace("configure", "RM='$RM'", "RM='$RM -f'")
        else
            io.replace("configure.in", "pid_t_fmt='#error Can not determine the proper size for pid_t'", "pid_t_fmt='#define APR_PID_T_FMT \"d\"'")
            os.vrunv("sh", {"./buildconf"})
            table.insert(configs, 1, "CFLAGS=-DAPR_IOVEC_DEFINED")
        end
        os.vrunv("sh", table.join({"./configure"}, configs))
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install"})
        os.rm(path.join(package:installdir(), "lib", "*.a"))
    end)
    on_install("windows", function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON", "-DINSTALL_PDB=OFF",
        })
    end)
package_end()

-- 5.5 apr-iconv (optional, for character encoding conversion)
-- Note: Only needed on Linux/macOS. On Windows, subversion uses its own
-- Win32 API-based character encoding (svn_subr__win32_xlate) and does not
-- depend on apr_xlate / apr-iconv at all.
package("apr-iconv")
    set_sourcedir(path.join(rootdir, "apr-iconv"))
    add_deps("apr")
    on_install("windows", function (package)
        -- No-op: apr-iconv has no CMake/MSVC build system and is not needed on Windows
    end)
    on_install("linux", "macosx", function (package)
        local apr_dir = package:dep("apr"):installdir()
        -- Clean stale build files (apr-util's configure re-runs apr-iconv's
        -- configure with wrong --prefix, corrupting the Makefiles and .la file)
        if os.isfile("Makefile") then
            os.vrunv("make", {"distclean"}, {try = true})
        end
        os.vrunv("sh", {"./buildconf"})
        os.vrunv("sh", {"./configure",
            "--prefix=" .. package:installdir(),
            "--with-apr=" .. apr_dir,
            "--enable-shared",
            "--enable-static=no",
        })
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install"})
        os.rm(path.join(package:installdir(), "lib", "*.a"))
    end)
package_end()

-- 5.8 libxcrypt (Linux only, provides libcrypt.so for apr-util)
package("libxcrypt")
    set_sourcedir(path.join(rootdir, "libxcrypt"))
    on_install("linux", function (package)
        if os.isfile("Makefile") then
            os.vrunv("make", {"distclean"}, {try = true})
        end
        os.vrunv("sh", {"./autogen.sh"})
        os.vrunv("sh", {"./configure",
            "--prefix=" .. package:installdir(),
            "--enable-shared",
            "--enable-static=no",
            "--disable-obsolete-api",
            "--disable-werror",
        })
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install"})
        os.rm(path.join(package:installdir(), "lib", "*.a"))
    end)
    on_install("macosx", "windows", function (package)
    end)
package_end()

-- 6. apr-util
package("apr-util")
    set_sourcedir(path.join(rootdir, "apr-util"))
    add_deps("apr", "libexpat", "openssl")
    on_load(function (package)
        -- apr-iconv only needed on Linux/macOS for character encoding;
        -- on Windows, subversion uses Win32 API directly (no apr_xlate needed)
        if not package:is_plat("windows") then
            package:add("deps", "apr-iconv")
        end
        if package:is_plat("linux") then
            package:add("deps", "libxcrypt")
        end
    end)
    on_install("linux", "macosx", function (package)
        local apr_src = path.join(rootdir, "apr")
        local apr_dir = package:dep("apr"):installdir()
        local apr_iconv_dir = package:dep("apr-iconv"):installdir()
        local expat_dir = package:dep("libexpat"):installdir()
        local openssl_dir = package:dep("openssl"):installdir()

        local envs = {}
        if package:is_plat("linux") then
            local xcrypt_dir = package:dep("libxcrypt"):installdir()
            envs = {
                LDFLAGS = "-L" .. path.join(xcrypt_dir, "lib"),
                CPPFLAGS = "-I" .. path.join(xcrypt_dir, "include"),
            }
        end

        -- Clean stale build files from previous runs
        if os.isfile("Makefile") then
            os.vrunv("make", {"distclean"}, {try = true})
        end

        -- Run buildconf with source paths
        os.vrunv("sh", {"./buildconf", "--with-apr=" .. apr_src})

        -- NOTE: Do NOT pass --with-apr-iconv=../apr-iconv here!
        -- apr-util's configure re-runs apr-iconv's configure as a sub-package
        -- with --prefix set to apr-util's prefix, which corrupts apr-iconv's
        -- Makefiles and .la file. Use --with-iconv instead to link against
        -- the already-installed apr-iconv.
        os.vrunv("sh", {"./configure",
            "--prefix=" .. package:installdir(),
            "--with-apr=" .. apr_dir,
            "--with-expat=" .. expat_dir,
            "--without-libxml2",
            "--with-iconv=" .. apr_iconv_dir,
            "--without-sqlite3",
            "--without-pgsql",
            "--without-ldap",
            "--without-odbc",
            "--with-openssl=" .. openssl_dir,
            "--with-crypto",
            "--enable-shared",
            "--enable-static=no",
        }, {envs = envs})
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install"})
        os.rm(path.join(package:installdir(), "lib", "*.a"))
    end)
    on_install("windows", function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON", "-DAPU_HAVE_ICONV=OFF",
            "-DAPU_BUILD_TEST=OFF", "-DAPU_HAVE_SQLITE3=OFF",
            "-DAPU_HAVE_PGSQL=OFF", "-DAPR_HAS_LDAP=OFF",
            "-DAPU_HAVE_ODBC=OFF", "-DAPU_HAVE_CRYPTO=OFF",
            "-DAPU_DSO_BUILD=ON", "-DINSTALL_PDB=OFF",
        })
    end)
package_end()

-- 7. subversion (depends on all packages except serf)
package("subversion")
    set_sourcedir(path.join(rootdir, "subversion"))
    add_deps("zlib", "openssl", "apr", "libexpat", "apr-util", "libxcrypt")
    on_install(function (package)

        os.vrunv("git", {"restore", "."}, {curdir = path.join(os.scriptdir(), "subversion")})

        local python = package:is_plat("windows") and "python" or "python3"
        os.vrunv(python, {"gen-make.py", "-t", "cmake"})

        local patches = os.files(path.join(os.scriptdir(), "patches", "subversion", "**.patch"))
        table.sort(patches)

        for _, patch in ipairs(patches) do
            os.vrunv("git", {"apply", "--ignore-space-change", "--ignore-whitespace", patch}, {
                curdir = path.join(os.scriptdir(), "subversion")
            })
        end

        -- Find dependencies in the install directory
        local installdir = path.join(rootdir, "build", "install")

        local sqlite3_lib
        if package:is_plat("windows") then
            sqlite3_lib = path.join(installdir, "lib", "sqlite3.lib")
        elseif package:is_plat("macosx") then
            sqlite3_lib = path.join(installdir, "lib", "libsqlite3.dylib")
        else
            sqlite3_lib = path.join(installdir, "lib", "libsqlite3.so")
        end

        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DCMAKE_PREFIX_PATH=" .. installdir,
            "-DSerf_ROOT=" .. installdir,
            "-DSQLite3_LIBRARY=" .. sqlite3_lib,
            "-DSQLite3_INCLUDE_DIR=" .. path.join(installdir, "include"),
            "-DSVN_SQLITE_USE_AMALGAMATION=OFF",
            "-DSVN_ENABLE_TESTS=OFF",
            "-DSVN_ENABLE_TOOLS=OFF",
            "-DSVN_ENABLE_NLS=OFF",
            "-DSVN_ENABLE_TUI=OFF",
            "-DSVN_ENABLE_SWIG_PERL=OFF",
            "-DSVN_ENABLE_SWIG_PYTHON=OFF",
            "-DSVN_ENABLE_SWIG_RUBY=OFF",
            "-DSVN_ENABLE_APACHE_MODULES=OFF",
            "-DSVN_BUILD_SHARED_FS=ON",
            "-DSVN_ENABLE_AUTH_KEYCHAIN=" .. (package:is_plat("macosx") and "ON" or "OFF"),
            "-DSVN_ENABLE_AUTH_GNOME_KEYRING=" .. (package:is_plat("linux") and "ON" or "OFF"),
            "-DSVN_ENABLE_AUTH_KWALLET=" .. (package:is_plat("linux") and "ON" or "OFF"),
        })
    end)
package_end()

-- ============================================================
-- Install dependencies (except subversion, which needs serf)
-- ============================================================
add_requires("zlib", "libexpat", "openssl",
             "apr", "apr-util", "libxcrypt")

-- ============================================================
-- Serf target (built with xmake, not as package)
-- Uses on_load to dynamically find package paths
-- ============================================================
target("serf")
    set_kind("shared")
    set_basename("serf-1")

    -- Source files
    add_files("serf/context.c", "serf/incoming.c", "serf/outgoing.c", "serf/ssltunnel.c")
    add_files("serf/buckets/*.c")
    add_files("serf/auth/*.c")

    -- Include own headers
    add_includedirs("serf")

    -- Defines
    add_defines("SERF_SHARED", "OPENSSL_NO_STDIO")

    -- System libraries
    if is_plat("linux") then
        add_syslinks("pthread")
    elseif is_plat("windows") then
        add_syslinks("ws2_32", "crypt32", "rpcrt4", "advapi32", "user32", "gdi32")
        -- /MD是编译器选项，指定多线程DLL运行时库
        add_cxflags("/MD")
        -- 链接CRT库，提供_DllMainCRTStartup入口点
        add_syslinks("msvcrt")
    end

    -- Output to install directory
    set_targetdir("build/install/lib")

    -- Dynamically find and add dependency paths
    on_load(function (target)
        import("core.project.project")

        -- Get dependency package objects from project
        local dep_names = {"apr", "apr-util", "openssl", "zlib", "libexpat"}
        for _, name in ipairs(dep_names) do
            local pkg = project.required_package(name)
            if pkg then
                local dir = pkg:installdir()
                if dir then
                    target:add("includedirs", path.join(dir, "include"), {public = true})
                    if name == "apr" or name == "apr-util" then
                        target:add("includedirs", path.join(dir, "include", "apr-1"), {public = true})
                    end
                    target:add("linkdirs", path.join(dir, "lib"), {public = true})
                    -- Embed rpath for OpenSSL so libserf-1.so can find libssl/libcrypto at runtime
                    if name == "openssl" then
                        target:add("rpathdirs", path.join(dir, "lib"), {public = true})
                    end
                end
            end
        end
        -- Add link libraries
        target:add("links", "ssl", "crypto", "z", "apr-1", "aprutil-1")
    end)

    -- After build, copy headers and generate pkg-config file
    after_build(function (target)
        import("core.project.project")
        local installdir = path.join(os.scriptdir(), "build", "install")
        local incdir = path.join(installdir, "include", "serf-1")
        os.mkdir(incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf.h"), incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf_bucket_types.h"), incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf_bucket_util.h"), incdir)

        -- Generate serf-1.pc for pkg-config (needed by subversion's CMake build)
        -- Collect OpenSSL library path for the Libs field
        local openssl_libdir = ""
        local openssl_pkg = project.required_package("openssl")
        if openssl_pkg then
            openssl_libdir = path.join(openssl_pkg:installdir(), "lib")
        end
        local pcdir = path.join(installdir, "lib", "pkgconfig")
        os.mkdir(pcdir)
        local pc_content = string.format([[
prefix=${pcfiledir}/../..
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include/serf-1

Name: serf
Description: Serf - a high performance HTTP client library
Version: 1.3.10
Libs: -L${libdir} -lserf-1 -L%s -lssl -lcrypto
Cflags: -I${includedir}
]], openssl_libdir)
        io.writefile(path.join(pcdir, "serf-1.pc"), pc_content)
    end)
target_end()

-- ============================================================
-- Build target - triggers serf build
-- ============================================================
target("svn-build")
    set_kind("phony")
    add_deps("serf", "sqlite3")
target_end()

-- ============================================================
-- Install target - copies files and fixes rpath
-- ============================================================
target("subversion-install")
    set_kind("phony")

    on_install(function (target)
        local installdir = path.join(os.scriptdir(), "build", "install")

        -- Get all package install directories from cache
        local pkg_dirs = {}
        local pkg_cache = path.join(os.scriptdir(), "build", ".packages")
        if os.isdir(pkg_cache) then
            for _, letter_dir in ipairs(os.dirs(path.join(pkg_cache, "*"))) do
                for _, name_dir in ipairs(os.dirs(path.join(letter_dir, "*"))) do
                    for _, hash_dir in ipairs(os.dirs(path.join(name_dir, "latest", "*"))) do
                        if path.filename(hash_dir) ~= "cache" and os.isdir(path.join(hash_dir, "lib")) then
                            table.insert(pkg_dirs, hash_dir)
                        end
                    end
                end
            end
        end

        -- Copy files from all package directories
        for _, pkg_dir in ipairs(pkg_dirs) do
            -- Copy lib files using cp -a to preserve symlinks
            if os.isdir(path.join(pkg_dir, "lib")) then
                os.mkdir(path.join(installdir, "lib"))
                -- cp -a preserves symlinks and file attributes
                os.vrunv("cp", {"-a", "-n",
                    path.join(pkg_dir, "lib", "."),
                    path.join(installdir, "lib")})
                -- Remove static libraries after copy
                os.rm(path.join(installdir, "lib", "*.a"))
                os.rm(path.join(installdir, "lib", "*.la"))
            end
            -- Copy bin files
            if os.isdir(path.join(pkg_dir, "bin")) then
                os.mkdir(path.join(installdir, "bin"))
                os.vrunv("cp", {"-a", "-n",
                    path.join(pkg_dir, "bin", "."),
                    path.join(installdir, "bin")})
            end
            -- Copy include files
            if os.isdir(path.join(pkg_dir, "include")) then
                os.mkdir(path.join(installdir, "include"))
                for _, d in ipairs(os.dirs(path.join(pkg_dir, "include", "*"))) do
                    local dirname = path.filename(d)
                    os.mkdir(path.join(installdir, "include", dirname))
                    for _, f in ipairs(os.files(path.join(d, "*"))) do
                        os.cp(f, path.join(installdir, "include", dirname))
                    end
                end
                for _, f in ipairs(os.files(path.join(pkg_dir, "include", "*"))) do
                    os.cp(f, path.join(installdir, "include"))
                end
            end
        end

        -- Fix dynamic library paths for distribution

        -- Helper to resolve symlinks (os.realpath not available in xmake v3)
        local function resolve_path(filepath)
            local out = os.iorunv("readlink", {"-f", filepath}, {try = true})
            if out then
                return out:match("^%s*(.-)%s*$")
            end
            return filepath
        end

        if os.host() == "macosx" then
            local bindir = path.join(installdir, "bin")
            local libdir = path.join(installdir, "lib")

            -- Fix library install names (deduplicate symlinks)
            local seen_dylib = {}
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
                local real = resolve_path(libfile)
                if real and not seen_dylib[real] then
                    seen_dylib[real] = true
                    local libname = path.filename(libfile)
                    os.vrunv("install_name_tool", {"-id", "@rpath/" .. libname, libfile}, {try = true})
                end
            end

            -- Fix absolute path references in dylibs (deduplicate symlinks)
            seen_dylib = {}
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
                local real = resolve_path(libfile)
                if real and not seen_dylib[real] then
                    seen_dylib[real] = true
                    local otool_out = os.iorunv("otool", {"-L", libfile})
                    if otool_out then
                        for line in otool_out:gmatch("[^\n]+") do
                            local old_path = line:match("%s+(/Users/.-%.dylib)")
                            if old_path then
                                local dep_name = path.filename(old_path)
                                os.vrunv("install_name_tool", {"-change", old_path, "@rpath/" .. dep_name, libfile}, {try = true})
                            end
                        end
                    end
                end
            end

            -- Fix binaries
            for _, binfile in ipairs(os.files(path.join(bindir, "*"))) do
                local fname = path.filename(binfile)
                if fname ~= "c_rehash" and not fname:match("-config$") then
                    local f = io.open(binfile, "rb")
                    if f then
                        local magic = f:read(4)
                        f:close()
                        if magic and magic:len() >= 4 then
                            local b1, b2 = magic:byte(1), magic:byte(2)
                            if (b1 == 0xCF and b2 == 0xFA) or (b1 == 0xCE and b2 == 0xFA) or (b1 == 0xCA and b2 == 0xFE) then
                                os.vrunv("install_name_tool", {"-add_rpath", "@executable_path/../lib", binfile}, {try = true})
                                local otool_out = os.iorunv("otool", {"-L", binfile})
                                if otool_out then
                                    for line in otool_out:gmatch("[^\n]+") do
                                        local old_path = line:match("%s+(/Users/.-%.dylib)")
                                        if old_path then
                                            local dep_name = path.filename(old_path)
                                            os.vrunv("install_name_tool", {"-change", old_path, "@rpath/" .. dep_name, binfile}, {try = true})
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

        elseif os.host() == "linux" then
            local bindir = path.join(installdir, "bin")
            local libdir = path.join(installdir, "lib")

            -- Helper: replace absolute DT_NEEDED paths with just the filename
            local function fix_needed(elfpath)
                local needed_out = os.iorunv("patchelf", {"--print-needed", elfpath}, {try = true})
                if not needed_out then return end
                for line in needed_out:gmatch("[^\n]+") do
                    local needed = line:match("^%s*(.-)%s*$")
                    if needed and needed:match("^/") then
                        -- Absolute path in DT_NEEDED, replace with basename
                        local basename = path.filename(needed)
                        os.vrunv("patchelf", {"--replace-needed", needed, basename, elfpath}, {try = true})
                        print("  fixed needed: " .. elfpath .. ": " .. needed .. " -> " .. basename)
                    end
                end
            end

            -- Deduplicate: os.files() follows symlinks, so the same actual
            -- file may appear multiple times through different symlink names.
            local seen = {}
            for _, libfile in ipairs(os.files(path.join(libdir, "*.so*"))) do
                local real = resolve_path(libfile)
                if real and not seen[real] then
                    seen[real] = true
                    os.vrunv("patchelf", {"--set-rpath", "$ORIGIN", libfile}, {try = true})
                    fix_needed(libfile)
                end
            end

            for _, binfile in ipairs(os.files(path.join(bindir, "*"))) do
                local f = io.open(binfile, "rb")
                if f then
                    local magic = f:read(4)
                    f:close()
                    if magic and magic:len() >= 4 and magic:byte(1) == 0x7f and magic:byte(2) == 0x45 then
                        os.vrunv("patchelf", {"--set-rpath", "$ORIGIN/../lib", binfile}, {try = true})
                        fix_needed(binfile)
                    end
                end
            end

        elseif os.host() == "windows" then
            local bindir = path.join(installdir, "bin")
            local libdir = path.join(installdir, "lib")

            if os.isdir(libdir) then
                os.mkdir(bindir)
                for _, dll in ipairs(os.files(path.join(libdir, "*.dll"))) do
                    os.cp(dll, bindir)
                end
            end
        end

        print("============================================================")
        print("Subversion and all dependencies installed to:")
        print("  " .. installdir)
        print("============================================================")
    end)
target_end()
