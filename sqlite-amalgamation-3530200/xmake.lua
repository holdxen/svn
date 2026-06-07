add_rules("mode.debug", "mode.release")

target("sqlite3")
    add_includedirs(os.scriptdir())
    add_files("sqlite3.c")
    set_kind("shared")
    if is_plat("linux") then
        add_syslinks("pthread", "dl", "m")
    elseif is_plat("windows") then
        add_defines("SQLITE_API=__declspec(dllexport)")
        add_cxflags("/MD")
        add_syslinks("msvcrt")
    end