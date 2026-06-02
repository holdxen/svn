
set_xmakever("2.8.0")

add_rules("mode.debug", "mode.release")

-- Force all packages to build from source, not use system packages
add_requireconfs("*", {system = false})

local rootdir = os.scriptdir()

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
        local configs = {
            "shared", "zlib",
            "--prefix=" .. packagedir,
            "--openssldir=" .. packagedir .. "/ssl",
            "--with-zlib-include=" .. path.join(zlib_dir, "include"),
            "--with-zlib-lib=" .. path.join(zlib_dir, "lib"),
        }
	print("config", configs)
	print("plat", package:plat())
	print("arch", package:arch())
        if package:is_debug() then table.insert(configs, "-g") end
        if package:is_plat("macosx") then
            table.insert(configs, 1, package:is_arch("x86_64") and "darwin64-x86_64-cc" or "darwin64-arm64-cc")
        elseif package:is_plat("linux") then
            if package:is_arch("x86_64") then
		  print("x86_64")
                table.insert(configs, 1, "linux-x86_64")
            elseif package:is_arch("x86") then
		  print("x86_64")
                table.insert(configs, 1, "linux-elf")
            elseif package:arch() == "arm64-v8a" or package:arch() == "aarch64" then
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

-- 4. sqlite (single file: sqlite3.c)
target("sqlite3")
    set_kind("shared")
    set_targetdir(path.join(rootdir, "build", "install", "lib"))
    add_files(path.join(rootdir, "sqlite", "sqlite3.c"))
    add_includedirs(path.join(rootdir, "sqlite"))
    add_headerfiles(path.join(rootdir, "sqlite", "sqlite3.h"))
    add_headerfiles(path.join(rootdir, "sqlite", "sqlite3ext.h"))
    if is_plat("linux") then
        add_syslinks("pthread", "dl", "m")
    elseif is_plat("windows") then
        add_defines("SQLITE_API=__declspec(dllexport)")
    end
    after_install(function (target)
        -- Copy headers to install directory
        local installdir = path.join(os.scriptdir(), "build", "install")
        local incdir = path.join(installdir, "include")
        os.mkdir(incdir)
        os.cp(path.join(os.scriptdir(), "sqlite", "sqlite3.h"), incdir)
        os.cp(path.join(os.scriptdir(), "sqlite", "sqlite3ext.h"), incdir)
    end)
target_end()

-- 5. apr
package("apr")
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
            "-DBUILD_SHARED_LIBS=ON", "-DINSTALL_PDB=OFF",
        })
    end)
package_end()

-- 6. apr-util
package("apr-util")
    set_sourcedir(path.join(rootdir, "apr-util"))
    add_deps("apr", "libexpat")
    on_install("linux", "macosx", function (package)
        local apr_src = path.join(rootdir, "apr")
        local apr_dir = package:dep("apr"):installdir()
        os.vrunv("sh", {"./buildconf", "--with-apr=" .. apr_src})
        local expat_dir = package:dep("libexpat"):installdir()
        import("package.tools.autoconf").install(package, {
            "--with-apr=" .. apr_dir, "--with-expat=" .. expat_dir,
            "--without-libxml2", "--without-iconv", "--without-sqlite3",
            "--without-pgsql", "--without-ldap", "--without-odbc",
            "--without-crypto", "--enable-shared=yes", "--enable-static=no",
        })
        os.rm(package:installdir("lib/*.a"))
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
    add_deps("openssl", "apr-util", "apr", "libexpat", "zlib")
    on_install(function (package)
        local python = package:is_plat("windows") and "python" or "python3"
        os.vrunv(python, {"gen-make.py", "-t", "cmake"})

        -- Find dependencies in the install directory
        local installdir = path.join(rootdir, "build", "install")

        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=ON",
            "-DCMAKE_PREFIX_PATH=" .. installdir,
            "-DSerf_ROOT=" .. installdir,
            "-DSQLite3_ROOT=" .. installdir,
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
        })
    end)
package_end()

-- ============================================================
-- Install dependencies (except subversion, which needs serf)
-- ============================================================
add_requires("zlib", "libexpat", "openssl",
             "apr", "apr-util")

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
                end
            end
        end
        -- Add link libraries
        target:add("links", "ssl", "crypto", "z", "apr-1", "aprutil-1")
    end)

    -- After build, copy headers to install directory
    after_build(function (target)
        local incdir = path.join(os.scriptdir(), "build", "install", "include", "serf-1")
        os.mkdir(incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf.h"), incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf_bucket_types.h"), incdir)
        os.cp(path.join(os.scriptdir(), "serf", "serf_bucket_util.h"), incdir)
    end)
target_end()

-- ============================================================
-- Build target - triggers serf build
-- ============================================================
target("svn-build")
    set_kind("phony")
    add_deps("serf")
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
            -- Copy lib files (skip static)
            if os.isdir(path.join(pkg_dir, "lib")) then
                os.mkdir(path.join(installdir, "lib"))
                for _, f in ipairs(os.files(path.join(pkg_dir, "lib", "*"))) do
                    if not f:match("%.a$") then
                        os.cp(f, path.join(installdir, "lib"))
                    end
                end
            end
            -- Copy bin files
            if os.isdir(path.join(pkg_dir, "bin")) then
                os.mkdir(path.join(installdir, "bin"))
                for _, f in ipairs(os.files(path.join(pkg_dir, "bin", "*"))) do
                    os.cp(f, path.join(installdir, "bin"))
                end
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
        if os.host() == "macosx" then
            local bindir = path.join(installdir, "bin")
            local libdir = path.join(installdir, "lib")

            -- Fix library install names
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
                local libname = path.filename(libfile)
                os.vrunv("install_name_tool", {"-id", "@rpath/" .. libname, libfile}, {try = true})
            end

            -- Fix absolute path references in dylibs
            for _, libfile in ipairs(os.files(path.join(libdir, "*.dylib"))) do
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

            for _, libfile in ipairs(os.files(path.join(libdir, "*.so*"))) do
                os.vrunv("patchelf", {"--set-rpath", "$ORIGIN", libfile}, {try = true})
                fix_needed(libfile)
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
