
set_xmakever("2.8.0")

add_rules("mode.debug", "mode.release")

local rootdir = os.scriptdir()

local function cmake_configs(package)
    local configs = {}

    table.insert(configs, "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"))

    return configs
end

package("libexpat")
    add_deps("cmake")
    set_sourcedir(path.join(rootdir, "libexpat/expat"))    

    on_install(function (package)
        local configs = cmake_configs(package)
        import("package.tools.cmake").install(package, configs)
    end)
package_end()

package("apr")
    set_homepage("https://github.com/apache/apr")
    set_description("Mirror of Apache Portable Runtime")
    set_license("Apache-2.0")
    set_sourcedir(path.join(rootdir, "apr"))    
    add_deps("libexpat")


    if is_plat("linux") then
        add_deps("libtool", "python")
        add_patches("1.7.0", path.join(os.scriptdir(), "patches", "1.7.0", "common.patch"), "bbfef69c914ca1ab98a9d94fc4794958334ce5f47d8c08c05e0965a48a44c50d")
    elseif is_plat("windows") then
        add_deps("cmake")
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
        if package:config("shared") then
            table.insert(configs, "--enable-shared=yes")
            table.insert(configs, "--enable-static=no")
        else 
            table.insert(configs, "--enable-shared=no")
            table.insert(configs, "--enable-static=yes")
        end
        import("package.tools.autoconf").install(package, configs)
        if package:config("shared") then
            os.rm(package:installdir("lib/*.a"))
        else
            os.tryrm(package:installdir("lib/*.so*"))
            os.tryrm(package:installdir("lib/*.dylib"))
        end
        package:add("links", "apr-1")
        package:add("includedirs", "include/apr-1")
    end)

    on_install("windows|x86", "windows|x64", function (package)
        local configs = {}
        table.insert(configs, "-DCMAKE_BUILD_TYPE=" .. (package:debug() and "Debug" or "Release"))
        table.insert(configs, "-DAPR_BUILD_SHARED=" .. (package:config("shared") and "ON" or "OFF"))
        table.insert(configs, "-DAPR_BUILD_STATIC=" .. (package:config("shared") and "OFF" or "ON"))
        import("package.tools.cmake").install(package, configs)
        -- libapr-1 is shared, apr-1 is static
        if package:config("shared") then
            package:add("defines", "APR_DECLARE_EXPORT")
            os.rm(package:installdir("lib/apr-1.lib"))
            os.rm(package:installdir("lib/aprapp-1.lib"))
        else
            package:add("defines", "APR_DECLARE_STATIC")
            os.rm(package:installdir("lib/lib*.lib"))
            os.rm(package:installdir("bin/lib*.dll"))
        end
    end)

    on_test(function (package)
        assert(package:has_cfuncs("apr_initialize", {includes = "apr_general.h"}))
    end)
package_end()

-- package("libb")
--     add_deps("cmake", "ninja")
--     set_sourcedir(path.join(rootdir, "thirdparty/libb"))

--     on_install(function (package)
--         local configs = cmake_configs(package)
--         import("package.tools.cmake").install(package, configs)
--     end)
-- package_end()

-- package("myapp")
--     set_kind("binary")
--     add_deps("cmake", "ninja")
--     add_deps("liba", "libb")
--     set_sourcedir(path.join(rootdir, "thirdparty/myapp"))

--     on_install(function (package)
--         local configs = cmake_configs(package)

--         -- 如果 myapp 的 CMakeLists.txt 里用 find_package 找 liba/libb，
--         -- 这里会尝试把 xmake 已安装的依赖传给 CMake。
--         import("package.tools.cmake").install(package, configs, {
--             packagedeps = {"liba", "libb"}
--         })
--     end)

--     -- 让可执行文件安装后的 bin 目录进入运行环境
--     on_load(function (package)
--         package:addenv("PATH", "bin")
--     end)
-- package_end()

add_requires("libexpat", "apr")

target("build-all")
    set_kind("phony")
    add_packages("libexpat", "apr")
