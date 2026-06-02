
set_xmakever("2.8.0")

add_rules("mode.debug", "mode.release")

-- Force all packages to build from source, not use system packages
add_requireconfs("*", {system = false})

local rootdir = os.scriptdir()

-- ============================================================
-- Package definitions using xmake's package system
-- Each package installs to xmake's managed package directory
-- ============================================================

-- 1. zlib (no deps)
package("zlib")
    set_homepage("https://zlib.net")
    set_description("Compression library")
    set_license("zlib")
    set_sourcedir(path.join(rootdir, "zlib"))
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
        })
    end)
package_end()

-- 2. libexpat (no deps)
package("libexpat")
    set_homepage("https://libexpat.github.io")
    set_description("XML parser library")
    set_license("MIT")
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

-- 3. openssl (depends: zlib)
package("openssl")
    set_homepage("https://www.openssl.org")
    set_description("TLS/SSL library")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "openssl"))
    add_deps("zlib")
    on_install(function (package)
        local packagedir = package:installdir()
        local zlib_dir = package:dep("zlib"):installdir()
        local configs = {
            "shared",
            "zlib",
            "--prefix=" .. packagedir,
            "--openssldir=" .. packagedir .. "/ssl",
            "--with-zlib-include=" .. path.join(zlib_dir, "include"),
            "--with-zlib-lib=" .. path.join(zlib_dir, "lib"),
        }
        if package:is_debug() then
            table.insert(configs, "-g")
        end
        if package:is_plat("macosx") then
            if package:is_arch("x86_64") then
                table.insert(configs, 1, "darwin64-x86_64-cc")
            elseif package:is_arch("arm64") then
                table.insert(configs, 1, "darwin64-arm64-cc")
            end
        elseif package:is_plat("linux") then
            if package:is_arch("x86_64") then
                table.insert(configs, 1, "linux-x86_64")
            elseif package:is_arch("x86") then
                table.insert(configs, 1, "linux-elf")
            end
        end
        os.vrunv("perl", table.join({"Configure"}, configs))
        os.vrunv("make", {"-j", tostring(os.default_njob())})
        os.vrunv("make", {"install_sw"})
    end)
package_end()

-- 4. sqlite (no deps)
package("sqlite")
    set_homepage("https://sqlite.org")
    set_description("SQL database engine")
    set_license("Public Domain")
    set_sourcedir(path.join(rootdir, "sqlite"))
    on_install(function (package)
        local packagedir = package:installdir()
        import("package.tools.autoconf").install(package, {
            "--prefix=" .. packagedir,
            "--enable-shared",
            "--disable-static",
        })
    end)
package_end()

-- 5. apr (depends: libexpat)
package("apr")
    set_homepage("https://apr.apache.org")
    set_description("Apache Portable Runtime")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "apr"))
    add_deps("libexpat")
    if is_plat("windows") then
        add_syslinks("wsock32", "ws2_32", "advapi32", "shell32", "rpcrt4")
    end
    on_install("linux", "macosx", function (package)
        local configs = {}
        if package:is_plat("linux") then
            os.vrunv("sh", {"./buildconf"})
            io.replace("configure", "RM='$RM'", "RM='$RM -f'")
        else
            io.replace("configure.in", "pid_t_fmt='#error Can not determine the proper size for pid_t'", "pid_t_fmt='#define APR_PID_T_FMT \"d\"'")
            os.vrunv("sh", {"./buildconf"})
            table.insert(configs, "CFLAGS=-DAPR_IOVEC_DEFINED")
        end
        table.insert(configs, "--enable-shared=yes")
        table.insert(configs, "--enable-static=no")
        import("package.tools.autoconf").install(package, configs)
        os.rm(package:installdir("lib/*.a"))
    end)
    on_install("windows", function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DINSTALL_PDB=OFF",
        })
    end)
package_end()

-- 6. apr-util (depends: apr, libexpat)
package("apr-util")
    set_homepage("https://apr.apache.org")
    set_description("Apache Portable Runtime Utility")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "apr-util"))
    add_deps("apr", "libexpat")
    on_install("linux", "macosx", function (package)
        local apr_src = path.join(rootdir, "apr")
        local apr_dir = package:dep("apr"):installdir()
        os.vrunv("sh", {"./buildconf", "--with-apr=" .. apr_src})
        local expat_dir = package:dep("libexpat"):installdir()
        local configs = {
            "--with-apr=" .. apr_dir,
            "--with-expat=" .. expat_dir,
            "--without-libxml2",
            "--without-iconv",
            "--without-sqlite3",
            "--without-pgsql",
            "--without-ldap",
            "--without-odbc",
            "--without-crypto",
            "--enable-shared=yes",
            "--enable-static=no",
        }
        import("package.tools.autoconf").install(package, configs)
        os.rm(package:installdir("lib/*.a"))
    end)
    on_install("windows", function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DAPU_HAVE_ICONV=OFF",
            "-DAPU_BUILD_TEST=OFF",
            "-DAPU_HAVE_SQLITE3=OFF",
            "-DAPU_HAVE_PGSQL=OFF",
            "-DAPR_HAS_LDAP=OFF",
            "-DAPU_HAVE_ODBC=OFF",
            "-DAPU_HAVE_CRYPTO=OFF",
            "-DAPU_DSO_BUILD=ON",
            "-DINSTALL_PDB=OFF",
        })
    end)
package_end()

-- 7. serf (depends: apr, apr-util, openssl, zlib)
package("serf")
    set_homepage("https://serf.apache.org")
    set_description("HTTP client library")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "serf"))
    add_deps("apr", "apr-util", "openssl", "zlib")
    on_install(function (package)
        local srcdir = package:sourcedir()
        local packagedir = package:installdir()
        local apr_dir = package:dep("apr"):installdir()
        local apr_inc = path.join(apr_dir, "include", "apr-1")
        local libdir = path.join(packagedir, "lib")

        -- Collect all source files recursively
        local sourcefiles = {}
        for _, f in ipairs(os.files(path.join(srcdir, "*.c"))) do
            table.insert(sourcefiles, f)
        end
        for _, f in ipairs(os.files(path.join(srcdir, "buckets", "*.c"))) do
            table.insert(sourcefiles, f)
        end
        for _, f in ipairs(os.files(path.join(srcdir, "auth", "*.c"))) do
            table.insert(sourcefiles, f)
        end

        -- Compile flags
        local aprutil_dir = package:dep("apr-util"):installdir()
        local openssl_dir = package:dep("openssl"):installdir()
        local zlib_dir = package:dep("zlib"):installdir()

        local cflags = {
            "-I" .. srcdir,
            "-I" .. apr_inc,
            "-I" .. path.join(aprutil_dir, "include", "apr-1"),
            "-I" .. path.join(openssl_dir, "include"),
            "-I" .. path.join(zlib_dir, "include"),
            "-DSERF_SHARED",
            "-DOPENSSL_NO_STDIO",
        }
        if not package:is_debug() then
            table.insert(cflags, "-O2")
            table.insert(cflags, "-DNDEBUG")
        else
            table.insert(cflags, "-g")
            table.insert(cflags, "-DDEBUG")
        end

        -- Compile all source files
        os.mkdir(path.join(packagedir, "build"))
        local objectfiles = {}
        for _, src in ipairs(sourcefiles) do
            local basename = path.filename(src):gsub("%.c$", "")
            local obj = path.join(packagedir, "build", basename .. ".o")
            os.vrunv("cc", table.join(cflags, {"-c", src, "-o", obj}))
            table.insert(objectfiles, obj)
        end

        -- Link shared library
        local libname
        local linkflags = {}
        if package:is_plat("macosx") then
            libname = "libserf-1.dylib"
            table.insert(linkflags, "-Wl,-install_name," .. path.join(libdir, libname))
        elseif package:is_plat("linux") then
            libname = "libserf-1.so"
            table.insert(linkflags, "-Wl,-soname," .. libname)
        end

        os.mkdir(libdir)
        local libpath = path.join(libdir, libname)

        -- Add library search paths
        table.insert(linkflags, "-L" .. path.join(apr_dir, "lib"))
        table.insert(linkflags, "-L" .. path.join(aprutil_dir, "lib"))
        table.insert(linkflags, "-L" .. path.join(openssl_dir, "lib"))
        table.insert(linkflags, "-L" .. path.join(zlib_dir, "lib"))

        os.vrunv("cc", table.join({"-shared", "-o", libpath}, objectfiles, linkflags, {
            "-lssl", "-lcrypto", "-lz", "-lapr-1", "-laprutil-1",
        }))

        -- Install headers
        local incdir = path.join(packagedir, "include", "serf-1")
        os.mkdir(incdir)
        os.cp(path.join(srcdir, "serf.h"), incdir)
        os.cp(path.join(srcdir, "serf_bucket_types.h"), incdir)
        os.cp(path.join(srcdir, "serf_bucket_util.h"), incdir)
    end)
package_end()

-- 8. subversion (depends: all above)
package("subversion")
    set_homepage("https://subversion.apache.org")
    set_description("Version control system")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "subversion"))
    add_deps("sqlite", "openssl", "serf", "apr-util", "apr", "libexpat", "zlib")
    on_install(function (package)
        -- Generate cmake targets file
        os.vrunv("python3", {"gen-make.py", "-t", "cmake"})
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DSVN_ENABLE_TESTS=OFF",
            "-DSVN_ENABLE_TOOLS=OFF",
            "-DSVN_ENABLE_NLS=OFF",
            "-DSVN_ENABLE_TUI=OFF",
            "-DSVN_ENABLE_SWIG_PERL=OFF",
            "-DSVN_ENABLE_SWIG_PYTHON=OFF",
            "-DSVN_ENABLE_SWIG_RUBY=OFF",
            "-DSVN_ENABLE_APACHE_MODULES=OFF",
            "-DSVN_BUILD_SHARED_FS=ON",
        })
    end)
package_end()

-- ============================================================
-- Main target
-- ============================================================
add_requires("zlib", "libexpat", "openssl", "sqlite",
             "apr", "apr-util", "serf", "subversion")

target("subversion-build")
    set_kind("phony")
    add_packages("zlib", "libexpat", "openssl", "sqlite",
                 "apr", "apr-util", "serf", "subversion")

    -- Install: copy all built files to the install directory
    after_install(function (target)
        local installdir = path.join(os.scriptdir(), "build", "install")
        local pkgdir = path.join(os.scriptdir(), "build", ".packages")

        -- Copy all package outputs to the install directory
        local pkg_names = {"zlib", "libexpat", "openssl", "sqlite", "apr", "apr-util", "serf", "subversion"}
        for _, pkg_name in ipairs(pkg_names) do
            local pkg_path = path.join(pkgdir, pkg_name:sub(1,1), pkg_name, "latest")
            if os.isdir(pkg_path) then
                -- Find the actual package directory (with hash)
                for _, hash_dir in ipairs(os.dirs(path.join(pkg_path, "*"))) do
                    -- Copy lib files
                    if os.isdir(path.join(hash_dir, "lib")) then
                        os.mkdir(path.join(installdir, "lib"))
                        for _, libfile in ipairs(os.files(path.join(hash_dir, "lib", "*"))) do
                            os.cp(libfile, path.join(installdir, "lib"))
                        end
                    end
                    -- Copy include files
                    if os.isdir(path.join(hash_dir, "include")) then
                        os.mkdir(path.join(installdir, "include"))
                        for _, incdir in ipairs(os.dirs(path.join(hash_dir, "include", "*"))) do
                            local dirname = path.filename(incdir)
                            os.mkdir(path.join(installdir, "include", dirname))
                            for _, incfile in ipairs(os.files(path.join(incdir, "*"))) do
                                os.cp(incfile, path.join(installdir, "include", dirname))
                            end
                        end
                        -- Also copy direct include files
                        for _, incfile in ipairs(os.files(path.join(hash_dir, "include", "*"))) do
                            os.cp(incfile, path.join(installdir, "include"))
                        end
                    end
                    -- Copy bin files
                    if os.isdir(path.join(hash_dir, "bin")) then
                        os.mkdir(path.join(installdir, "bin"))
                        for _, binfile in ipairs(os.files(path.join(hash_dir, "bin", "*"))) do
                            os.cp(binfile, path.join(installdir, "bin"))
                        end
                    end
                end
            end
        end

        -- Fix rpath for macOS binaries
        if os.host() == "macosx" then
            local bindir = path.join(installdir, "bin")
            local libdir = path.join(installdir, "lib")

            -- Fix library install names
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
                local libname = path.filename(libfile)
                os.vrunv("install_name_tool", {"-id", path.join(libdir, libname), libfile}, {try = true})
            end

            -- Fix rpath for subversion binaries
            for _, binfile in ipairs(os.files(path.join(bindir, "svn*"))) do
                os.vrunv("install_name_tool", {"-add_rpath", libdir, binfile}, {try = true})
            end

            -- Fix library references in all installed dylibs
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
                local libname = path.filename(libfile)
                -- Get current dependencies
                local otool_out = os.iorunv("otool", {"-L", libfile})
                if otool_out then
                    for line in otool_out:gmatch("[^\n]+") do
                        -- Find absolute paths to our packages directory
                        local old_path = line:match("%s+(/Users/.-%.dylib)")
                        if old_path and old_path:match("build/.packages") then
                            local dep_name = path.filename(old_path)
                            local new_path = path.join(libdir, dep_name)
                            os.vrunv("install_name_tool", {"-change", old_path, new_path, libfile}, {try = true})
                        end
                    end
                end
            end
        end

        print("============================================================")
        print("Subversion and all dependencies installed to:")
        print("  " .. installdir)
        print("============================================================")
    end)
target_end()
