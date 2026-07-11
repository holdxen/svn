from abc import ABC, abstractmethod
from pathlib import Path
import subprocess
import platform
import os
import shutil
import re


# ============================================================
# 平台工具类
# ============================================================

class Platform:
    @staticmethod
    def os():
        return platform.system()

    @staticmethod
    def arch():
        return platform.machine()

    @staticmethod
    def is_x64():
        return Platform.arch() in ("x86_64", "amd64", "AMD64")

    @staticmethod
    def is_arm64():
        return Platform.arch() in ("arm64", "aarch64")

    @staticmethod
    def is_x86():
        return Platform.arch() in ("i386", "i686", "x86")
    
    @staticmethod
    def is_loongarch64():
        return Platform.arch() == "loongarch64"

    @staticmethod
    def is_linux():
        return Platform.os() == "Linux"

    @staticmethod
    def is_windows():
        return Platform.os() == "Windows"

    @staticmethod
    def is_darwin():
        return Platform.os() == "Darwin"

    @staticmethod
    def delete_path(path):
        p = Path(path)
        if not p.exists():
            return
        if p.is_file():
            p.unlink()
        elif p.is_dir():
            shutil.rmtree(p)

    @staticmethod
    def remove_static_libs(lib_dir):
        """删除静态库文件 (.a)，保留 .la（libtool 依赖链需要）"""
        lib_dir = Path(lib_dir)
        if not lib_dir.exists():
            return
        for f in lib_dir.glob("*.a"):
            f.unlink()

    @staticmethod
    def remove_la_files(lib_dir):
        """删除 libtool .la 元数据文件（构建全部完成后调用）"""
        lib_dir = Path(lib_dir)
        if not lib_dir.exists():
            return
        for f in lib_dir.glob("*.la"):
            f.unlink()

    @staticmethod
    def cpu_count():
        return os.cpu_count() or 1

    @staticmethod
    def cmake_generator_args():
        """Windows 上指定 VS2017 x64 生成器参数"""
        if Platform.is_windows():
            return ["-G", "Visual Studio 15 2017", "-A", "x64"]
        return []

    @staticmethod
    def cmake_build_config_args():
        """Windows MSVC 多配置生成器需指定 --config Release"""
        if Platform.is_windows():
            return ["--config", "Release"]
        return []

    @staticmethod
    def run(cmd, cwd=None, env=None, check=True):
        """执行命令，打印命令内容"""
        print(f"  > {' '.join(str(c) for c in cmd)}")
        if cwd:
            print(f"    cwd: {cwd}")
        subprocess.run(cmd, cwd=cwd, env=env, check=check)


# ============================================================
# 项目基类
# ============================================================

class Project(ABC):
    """所有依赖项目的基类"""

    def __init__(self, source_dir: str):
        self.source = source_dir

    @property
    @abstractmethod
    def name(self) -> str:
        """项目名称"""
        ...

    def ready(self, target: str):
        """构建前检查，默认无操作"""
        pass

    @abstractmethod
    def compile(self, target: str):
        """执行编译安装"""
        pass

    def finished(self, target: str):
        """构建后清理，默认无操作"""
        pass

    def clean(self):
        """清理构建产物，默认删除源码目录下的 cmake-build"""
        build_dir = Path(self.source).joinpath("cmake-build")
        if build_dir.exists():
            shutil.rmtree(build_dir)
            print(f"  Removed: {build_dir}")


# ============================================================
# 1. zlib (CMake)
# ============================================================

class ZLib(Project):
    def __init__(self):
        super().__init__("./zlib")

    @property
    def name(self):
        return "zlib"

    def compile(self, target: str):
        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)


# ============================================================
# 2. libexpat (CMake)
# ============================================================

class Libexpat(Project):
    def __init__(self):
        super().__init__("./libexpat")

    @property
    def name(self):
        return "libexpat"

    def clean(self):
        build_dir = Path(self.source).joinpath("expat", "cmake-build")
        if build_dir.exists():
            shutil.rmtree(build_dir)
            print(f"  Removed: {build_dir}")

    def ready(self, target: str):
        cmake_file = Path(self.source).joinpath("expat", "CMakeLists.txt")
        if not cmake_file.exists():
            raise FileNotFoundError(f"CMakeLists.txt not found in {cmake_file}")

    def compile(self, target: str):
        build_dir = Path(self.source).joinpath("expat", "cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            "-DEXPAT_BUILD_TOOLS=OFF",
            "-DEXPAT_BUILD_EXAMPLES=OFF",
            "-DEXPAT_BUILD_TESTS=OFF",
            "-DEXPAT_BUILD_DOCS=OFF",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)


# ============================================================
# 3. openssl (Perl Configure + make/nmake)
# ============================================================

class Openssl(Project):
    def __init__(self):
        super().__init__("./openssl")

    @property
    def name(self):
        return "openssl"

    def clean(self):
        # 清理旧的构建文件
        if Path(self.source).joinpath("Makefile").exists():
            try:
                if Platform.is_windows():
                    Platform.run(["nmake", "clean"], cwd=self.source, check=False)
                else:
                    Platform.run(["make", "clean"], cwd=self.source, check=False)
            except Exception:
                print("  warning: failed to clean openssl")


    def compile(self, target: str):
        # 清理旧的构建产物（避免残留对象文件导致链接错误）
        self.clean()

        zlib_dir = Path(target).absolute()
        zlib_include = str(zlib_dir.joinpath("include"))

        # Windows 需要完整的 .lib 路径，Unix 只需要目录路径（-L 前缀）
        if Platform.is_windows():
            zlib_lib = str(zlib_dir.joinpath("lib", "libz.lib"))
        else:
            zlib_lib = str(zlib_dir.joinpath("lib"))

        # 确定平台目标
        compile_target = None
        if Platform.is_darwin():
            if Platform.is_arm64():
                compile_target = "darwin64-arm64-cc"
            elif Platform.is_x64():
                compile_target = "darwin64-x86_64-cc"
        elif Platform.is_linux():
            if Platform.is_arm64():
                compile_target = "linux-aarch64"
            elif Platform.is_x64():
                compile_target = "linux-x86_64"
            elif Platform.is_x86():
                compile_target = "linux-elf"
            elif Platform.is_loongarch64():
                compile_target = "linux64-loongarch64"
        elif Platform.is_windows():
            if Platform.is_x64():
                compile_target = "VC-WIN64A"
            elif Platform.is_x86():
                compile_target = "VC-WIN32"

        if compile_target is None:
            raise Exception(f"Unsupported platform: {Platform.os()} {Platform.arch()}")

        args = [
            compile_target,
            "shared",
            "zlib",
            f"--prefix={target}",
            f"--openssldir={Path(target).joinpath('ssl')}",
            f"--with-zlib-include={zlib_include}",
            f"--with-zlib-lib={zlib_lib}",
        ]

        Platform.run(["perl", "Configure"] + args, cwd=self.source)

        if Platform.is_windows():
            Platform.run(["nmake"], cwd=self.source)
            Platform.run(["nmake", "install_sw"], cwd=self.source)
        else:
            Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
            Platform.run(["make", "install_sw"], cwd=self.source)

        # 删除静态库（只保留共享库）
        Platform.remove_static_libs(Path(target).joinpath("lib"))


# ============================================================
# 4. sqlite3 (CMake, amalgamation)
# ============================================================

class Sqlite3(Project):
    def __init__(self):
        super().__init__("./sqlite-amalgamation")

    @property
    def name(self):
        return "sqlite3"

    def ready(self, target: str):
        src = Path(self.source)
        if not src.joinpath("sqlite3.c").exists():
            raise FileNotFoundError(f"sqlite3.c not found in {self.source}")
        if not src.joinpath("sqlite3.h").exists():
            raise FileNotFoundError(f"sqlite3.h not found in {self.source}")

    def compile(self, target: str):
        self._generate_cmakelists()

        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)

    def _generate_cmakelists(self):
        """生成 CMakeLists.txt"""
        content = """cmake_minimum_required(VERSION 3.15)
project(sqlite3 C)

add_library(sqlite3 SHARED sqlite3.c)

target_include_directories(sqlite3 PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

if(WIN32)
    target_compile_definitions(sqlite3 PRIVATE "SQLITE_API=__declspec(dllexport)")
    target_compile_options(sqlite3 PRIVATE /MD)
    target_link_libraries(sqlite3 PRIVATE ws2_32)
else()
    set_target_properties(sqlite3 PROPERTIES
        POSITION_INDEPENDENT_CODE ON
    )
    if(APPLE)
        set_target_properties(sqlite3 PROPERTIES
            INSTALL_NAME_DIR "@rpath"
        )
    endif()
endif()

if(UNIX AND NOT APPLE)
    target_link_libraries(sqlite3 PRIVATE pthread dl m)
elseif(APPLE)
    target_link_libraries(sqlite3 PRIVATE pthread dl m)
endif()

# Install library
install(TARGETS sqlite3
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

# Install headers
install(FILES sqlite3.h sqlite3ext.h DESTINATION include)

# Generate and install pkg-config file
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/sqlite3.pc"
"prefix=${CMAKE_INSTALL_PREFIX}
exec_prefix=\\${prefix}
libdir=\\${exec_prefix}/lib
includedir=\\${prefix}/include

Name: sqlite3
Description: SQLite database engine
Version: 3.53.2
Libs: -L\\${libdir} -lsqlite3
Libs.private: -lpthread -ldl -lm
Cflags: -I\\${includedir}
")

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/sqlite3.pc"
    DESTINATION lib/pkgconfig
)
"""
        Path(self.source).joinpath("CMakeLists.txt").write_text(content)


# ============================================================
# 5. apr (autoconf on Unix, CMake on Windows)
# ============================================================

class Apr(Project):
    def __init__(self):
        super().__init__("./apr")

    @property
    def name(self):
        return "apr"

    def clean(self):
        # 清理旧的构建文件
        try:
            if Path(self.source).joinpath("Makefile").exists():
                Platform.run(["make", "distclean"], cwd=self.source, check=False)
        except Exception:
            print("  warning: failed to clean apr")
        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)


    def ready(self, target: str):
        if not Platform.is_windows():
            if not Path(self.source).joinpath("buildconf").exists():
                raise FileNotFoundError(f"buildconf script not found in {self.source}")

    def compile(self, target: str):
        # 恢复源文件（撤销之前的补丁）
        Platform.run(["git", "restore", "."], cwd=self.source)

        # 应用补丁
        patches_dir = Path("./patches/apr")
        if patches_dir.exists():
            patches = sorted(patches_dir.glob("*.patch"))
            for patch in patches:
                Platform.run([
                    "git", "apply", "--ignore-space-change",
                    "--ignore-whitespace", str(patch.absolute()),
                ], cwd=self.source)

        if Platform.is_windows():
            self._compile_cmake(target)
        else:
            self._compile_autoconf(target)

    def _compile_autoconf(self, target: str):
        self.clean()

        configs = [
            f"--prefix={target}",
            "--enable-shared",
            "--enable-static=no",
            "--enable-nonportable-atomics",
        ]

        if Platform.is_linux():
            Platform.run(["sh", "./buildconf"], cwd=self.source)
            # 修复 configure 中 RM 变量缺少 -f 标志的问题
            configure_path = Path(self.source).joinpath("configure")
            content = configure_path.read_text()
            content = content.replace("RM='$RM'", "RM='$RM -f'")
            configure_path.write_text(content)
        else:
            # macOS: 修复 pid_t 格式化问题
            configure_in = Path(self.source).joinpath("configure.in")
            content = configure_in.read_text()
            content = content.replace(
                "pid_t_fmt='#error Can not determine the proper size for pid_t'",
                "pid_t_fmt='#define APR_PID_T_FMT \"d\"'",
            )
            configure_in.write_text(content)
            Platform.run(["sh", "./buildconf"], cwd=self.source)
            # macOS 需要额外定义避免编译错误
            configs.insert(0, "CFLAGS=-DAPR_IOVEC_DEFINED")

        Platform.run(["sh", "./configure"] + configs, cwd=self.source)
        Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
        Platform.run(["make", "install"], cwd=self.source)

        Platform.remove_static_libs(Path(target).joinpath("lib"))

    def _compile_cmake(self, target: str):
        self.clean()
        build_dir = Path(self.source).joinpath("cmake-build").absolute()

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            "-DINSTALL_PDB=OFF",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)


# ============================================================
# 5.5 apr-iconv (autoconf, 仅 Linux/macOS)
# ============================================================

class AprIconv(Project):
    def __init__(self):
        super().__init__("./apr-iconv")

    @property
    def name(self):
        return "apr-iconv"

    def clean(self):
        # 清理旧的构建文件
        try:
            if Path(self.source).joinpath("Makefile").exists():
                Platform.run(["make", "distclean"], cwd=self.source, check=False)
        except Exception:
            print("  warning: failed to clean apr-iconv")


    def compile(self, target: str):
        # Windows 不需要 apr-iconv（subversion 使用 Win32 API 进行字符编码）
        if Platform.is_windows():
            print("  Skipping apr-iconv on Windows (not needed)")
            return

        if Path(self.source).joinpath("Makefile").exists():
            Platform.run(["make", "distclean"], cwd=self.source, check=False)

        apr_dir = str(Path(target).absolute())

        Platform.run(["sh", "./buildconf"], cwd=self.source)
        Platform.run([
            "sh", "./configure",
            f"--prefix={target}",
            f"--with-apr={apr_dir}",
            "--enable-shared",
            "--enable-static=no",
        ], cwd=self.source)
        Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
        Platform.run(["make", "install"], cwd=self.source)

        # 只删除 .a，保留 .la（apr-util 的 libtool 链接时需要 libapriconv-1.la）
        Platform.remove_static_libs(Path(target).joinpath("lib"))


# ============================================================
# 5.8 libxcrypt (仅 Linux, 提供 libcrypt.so)
# ============================================================

class Libxcrypt(Project):
    def __init__(self):
        super().__init__("./libxcrypt")

    @property
    def name(self):
        return "libxcrypt"

    def compile(self, target: str):
        if not Platform.is_linux():
            print(f"  Skipping libxcrypt on {Platform.os()} (Linux only)")
            return

        if Path(self.source).joinpath("Makefile").exists():
            Platform.run(["make", "distclean"], cwd=self.source, check=False)

        Platform.run(["sh", "./autogen.sh"], cwd=self.source)
        Platform.run([
            "sh", "./configure",
            f"--prefix={target}",
            "--enable-shared",
            "--enable-static=no",
            "--disable-obsolete-api",
            "--disable-werror",
        ], cwd=self.source)
        Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
        Platform.run(["make", "install"], cwd=self.source)

        Platform.remove_static_libs(Path(target).joinpath("lib"))


# ============================================================
# 6. apr-util (autoconf on Unix, CMake on Windows)
# ============================================================

class AprUtil(Project):
    def __init__(self):
        super().__init__("./apr-util")

    @property
    def name(self):
        return "apr-util"

    def compile(self, target: str):
        # 恢复源文件（撤销之前的补丁）
        Platform.run(["git", "restore", "."], cwd=self.source)

        # 应用补丁
        patches_dir = Path("./patches/apr-util")
        if patches_dir.exists():
            patches = sorted(patches_dir.glob("*.patch"))
            for patch in patches:
                Platform.run([
                    "git", "apply", "--ignore-space-change",
                    "--ignore-whitespace", str(patch.absolute()),
                ], cwd=self.source)

        if Platform.is_windows():
            self._compile_cmake(target)
        else:
            self._compile_autoconf(target)

    def _compile_autoconf(self, target: str):
        if Path(self.source).joinpath("Makefile").exists():
            Platform.run(["make", "distclean"], cwd=self.source, check=False)

        # 依赖路径
        apr_dir = str(Path(target).absolute())
        apr_iconv_dir = str(Path(target).absolute())
        expat_dir = str(Path(target).absolute())
        openssl_dir = str(Path(target).absolute())
        apr_src = str(Path("./apr").absolute())

        # 运行 buildconf（使用 check=False，因为 RPM spec 生成等非关键步骤可能失败，
        # 但不影响后续 configure）
        Platform.run(["sh", "./buildconf", f"--with-apr={apr_src}"], cwd=self.source, check=False)

        # NOTE: 不要传 --with-apr-iconv=../apr-iconv！
        # apr-util 的 configure 会以错误的 --prefix 重新运行 apr-iconv 的 configure，
        # 导致 Makefile 和 .la 文件被破坏。使用 --with-iconv 来链接已安装的 apr-iconv。
        args = [
            f"--prefix={target}",
            f"--with-apr={apr_dir}",
            f"--with-expat={expat_dir}",
            "--without-libxml2",
            f"--with-iconv={apr_iconv_dir}",
            "--without-sqlite3",
            "--without-pgsql",
            "--without-ldap",
            "--without-odbc",
            f"--with-openssl={openssl_dir}",
            "--with-crypto",
            "--enable-shared",
            "--enable-static=no",
        ]

        env = os.environ.copy()
        if Platform.is_linux():
            # Linux 上需要 libxcrypt 提供 libcrypt
            xcrypt_dir = str(Path(target).absolute())
            env["LDFLAGS"] = env.get("LDFLAGS", "") + f" -L{xcrypt_dir}/lib"
            env["CPPFLAGS"] = env.get("CPPFLAGS", "") + f" -I{xcrypt_dir}/include"

        Platform.run(["sh", "./configure"] + args, cwd=self.source, env=env)
        Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
        Platform.run(["make", "install"], cwd=self.source)

        Platform.remove_static_libs(Path(target).joinpath("lib"))

    def _compile_cmake(self, target: str):
        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            "-DAPU_HAVE_ICONV=OFF",
            "-DAPU_BUILD_TEST=OFF",
            "-DAPU_HAVE_SQLITE3=OFF",
            "-DAPU_HAVE_PGSQL=OFF",
            "-DAPR_HAS_LDAP=OFF",
            "-DAPU_HAVE_ODBC=OFF",
            "-DAPU_HAVE_CRYPTO=ON",
            f"-DOPENSSL_ROOT_DIR={target}",
            f"-DOPENSSL_INCLUDE_DIR={Path(target).joinpath('include')}",
            f"-DOPENSSL_CRYPTO_LIBRARY={Path(target).joinpath('lib', 'libcrypto.lib')}",
            f"-DOPENSSL_SSL_LIBRARY={Path(target).joinpath('lib', 'libssl.lib')}",
            "-DOPENSSL_FOUND=ON",
            "-DAPU_DSO_BUILD=ON",
            "-DINSTALL_PDB=OFF",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)


# ============================================================
# 7. serf (CMake, 生成 CMakeLists.txt)
# ============================================================

class Serf(Project):
    def __init__(self):
        super().__init__("./serf")

    @property
    def name(self):
        return "serf"

    def compile(self, target: str):
        self._generate_cmakelists(target)

        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
        ]
        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + args, cwd=build_dir)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)

    def _generate_cmakelists(self, target: str):
        """生成 CMakeLists.txt"""
        install_dir = str(Path(target).absolute()).replace("\\", "/")

        content = f"""cmake_minimum_required(VERSION 3.15)
project(serf C)

# Collect source files
file(GLOB SERF_ROOT_SRCS "${{CMAKE_CURRENT_SOURCE_DIR}}/*.c")
file(GLOB SERF_BUCKET_SRCS "${{CMAKE_CURRENT_SOURCE_DIR}}/buckets/*.c")
file(GLOB SERF_AUTH_SRCS "${{CMAKE_CURRENT_SOURCE_DIR}}/auth/*.c")

add_library(serf-1 SHARED
    ${{SERF_ROOT_SRCS}}
    ${{SERF_BUCKET_SRCS}}
    ${{SERF_AUTH_SRCS}}
)
set_target_properties(serf-1 PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)

# Include directories: own headers + dependency headers
target_include_directories(serf-1 PRIVATE
    ${{CMAKE_CURRENT_SOURCE_DIR}}
    "{install_dir}/include"
    "{install_dir}/include/apr-1"
)

# Compile definitions
target_compile_definitions(serf-1 PRIVATE SERF_SHARED OPENSSL_NO_STDIO)

# Link directories (all dependency libs are in the same install dir)
target_link_directories(serf-1 PRIVATE "{install_dir}/lib")

# Platform-specific settings
if(WIN32)
    target_compile_options(serf-1 PRIVATE /MD)
    target_link_libraries(serf-1 PRIVATE
        libssl libcrypto libz libapr-1 libaprutil-1
        ws2_32 crypt32 rpcrt4 advapi32 user32 gdi32
    )
else()
    set_target_properties(serf-1 PROPERTIES
        POSITION_INDEPENDENT_CODE ON
    )
    target_link_libraries(serf-1 PRIVATE ssl crypto z apr-1 aprutil-1)
    if(APPLE)
        set_target_properties(serf-1 PROPERTIES
            INSTALL_NAME_DIR "@rpath"
        )
        target_link_options(serf-1 PRIVATE
            "SHELL:-Wl,-rpath,{install_dir}/lib"
        )
    elseif(UNIX)
        target_link_libraries(serf-1 PRIVATE pthread)
        target_link_options(serf-1 PRIVATE
            "SHELL:-Wl,-rpath,{install_dir}/lib"
        )
    endif()
endif()

# Install library
install(TARGETS serf-1 EXPORT SerfTargets
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

# Install headers
install(FILES
    serf.h
    serf_bucket_types.h
    serf_bucket_util.h
    DESTINATION include/serf-1
)

# Generate and install pkg-config file
file(WRITE "${{CMAKE_CURRENT_BINARY_DIR}}/serf-1.pc"
"prefix={install_dir}
exec_prefix=\\${{prefix}}
libdir=\\${{exec_prefix}}/lib
includedir=\\${{prefix}}/include/serf-1

Name: serf
Description: Serf - a high performance HTTP client library
Version: 1.3.10
Libs: -L\\${{libdir}} -lserf-1 -L\\${{libdir}} -lssl -lcrypto
Cflags: -I\\${{includedir}}
")

install(FILES "${{CMAKE_CURRENT_BINARY_DIR}}/serf-1.pc"
    DESTINATION lib/pkgconfig
)

# Generate CMake config files
include(CMakePackageConfigHelpers)
write_basic_package_version_file(
    "${{CMAKE_CURRENT_BINARY_DIR}}/SerfConfigVersion.cmake"
    VERSION 1.3.10
    COMPATIBILITY AnyNewerVersion
)
install(EXPORT SerfTargets
    FILE SerfConfig.cmake
    NAMESPACE Serf::
    DESTINATION lib/cmake/Serf
)
install(FILES "${{CMAKE_CURRENT_BINARY_DIR}}/SerfConfigVersion.cmake"
    DESTINATION lib/cmake/Serf
)
"""
        Path(self.source).joinpath("CMakeLists.txt").write_text(content)


# ============================================================
# 8. cyrus-sasl (autotools, 依赖 openssl)
# ============================================================

class CyrusSasl(Project):
    def __init__(self):
        super().__init__("./cyrus-sasl")

    @property
    def name(self):
        return "cyrus-sasl"

    def clean(self):
        try:
            if Path(self.source).joinpath("Makefile").exists():
                Platform.run(["make", "distclean"], cwd=self.source, check=False)
        except Exception:
            print("  warning: failed to clean cyrus-sasl")

    def compile(self, target: str):
        installdir = str(Path(target).absolute())
        sasl_dir = str(Path(target).joinpath("lib", "sasl2"))

        if Platform.is_windows():
            self._compile_windows(target)
            return

        if Path(self.source).joinpath("Makefile").exists():
            Platform.run(["make", "distclean"], cwd=self.source, check=False)

        # 源码如果是 release tarball 可能已自带 configure，否则需要 autoreconf
        if not Path(self.source).joinpath("configure").exists():
            autogen_env = os.environ.copy()
            autogen_env["NOCONFIGURE"] = "1"
            Platform.run(["sh", "./autogen.sh"], cwd=self.source, env=autogen_env)

        configs = [
            f"--prefix={installdir}",
            "--enable-shared",
            "--disable-static",
            f"--with-openssl={installdir}",
            f"--with-plugindir={sasl_dir}",
            f"--with-configdir={sasl_dir}",
            "--with-saslauthd=no",
            "--with-dblib=none",
            "--enable-gssapi=no",
            "--disable-ldapdb",
            "--disable-sql",
            "--disable-macos-framework",
            "--enable-plain",
            "--enable-anon",
            "--enable-scram",
            "--disable-srp",
            "--disable-otp",
        ]

        env = os.environ.copy()
        env["PKG_CONFIG_PATH"] = (
            f"{installdir}/lib/pkgconfig"
            + (f":{env.get('PKG_CONFIG_PATH', '')}" if env.get("PKG_CONFIG_PATH") else "")
        )

        Platform.run(["sh", "./configure"] + configs, cwd=self.source, env=env)
        Platform.run(["make", f"-j{Platform.cpu_count()}"], cwd=self.source)
        Platform.run(["make", "install"], cwd=self.source)

        Platform.remove_static_libs(Path(target).joinpath("lib"))
        Platform.remove_static_libs(Path(sasl_dir))

    def _compile_windows(self, target: str):
        installdir = str(Path(target).absolute())
        openssl_include = str(Path(target).joinpath("include"))
        openssl_libpath = str(Path(target).joinpath("lib"))
        make_args = [
            "/f", "NTMakefile",
            f"prefix={installdir}",
            f"OPENSSL_INCLUDE={openssl_include}",
            f"OPENSSL_LIBPATH={openssl_libpath}",
            "STATIC=no",
            "SASLDB=NONE",
        ]
        Platform.run(
            ["nmake"] + make_args,
            cwd=self.source,
        )
        Platform.run(
            ["nmake"] + make_args + ["install"],
            cwd=self.source,
        )


# ============================================================
# 9. subversion (CMake, 依赖所有上述库)
# ============================================================

class Subversion(Project):
    def __init__(self):
        super().__init__("./subversion")

    @property
    def name(self):
        return "subversion"

    def compile(self, target: str):
        # 恢复源文件（撤销之前的补丁）
        Platform.run(["git", "restore", "."], cwd=self.source)

        # 生成 CMake 构建文件
        Platform.run(["python3", "gen-make.py", "-t", "cmake"], cwd=self.source)

        # 应用补丁
        patches_dir = Path("./patches/subversion")
        if patches_dir.exists():
            patches = sorted(patches_dir.glob("*.patch"))
            for patch in patches:
                Platform.run([
                    "git", "apply", "--ignore-space-change", str(patch.absolute()),
                ], cwd=self.source)

        # 构建目录
        build_dir = Path(self.source).joinpath("cmake-build").absolute()
        Platform.delete_path(build_dir)
        build_dir.mkdir(parents=True)

        installdir = str(Path(target).absolute())

        # sqlite3 库路径（按平台）
        if Platform.is_windows():
            sqlite3_lib = str(Path(target).joinpath("lib", "sqlite3.lib"))
        elif Platform.is_darwin():
            sqlite3_lib = str(Path(target).joinpath("lib", "libsqlite3.dylib"))
        else:
            sqlite3_lib = str(Path(target).joinpath("lib", "libsqlite3.so"))

        cmake_args = [
            f"-DCMAKE_INSTALL_PREFIX={target}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            f"-DCMAKE_PREFIX_PATH={installdir}",
            f"-DSerf_ROOT={installdir}",
            f"-DSQLite3_LIBRARY={sqlite3_lib}",
            f"-DSQLite3_INCLUDE_DIR={Path(target).joinpath('include')}",
            "-DSVN_SQLITE_USE_AMALGAMATION=OFF",
            "-DSVN_ENABLE_TESTS=OFF",
            "-DSVN_ENABLE_TOOLS=OFF",
            "-DSVN_ENABLE_NLS=OFF",
            "-DSVN_ENABLE_TUI=OFF",
            "-DSVN_ENABLE_SASL=ON",
            "-DSVN_ENABLE_SWIG_PERL=OFF",
            "-DSVN_ENABLE_SWIG_PYTHON=OFF",
            "-DSVN_ENABLE_SWIG_RUBY=OFF",
            "-DSVN_ENABLE_APACHE_MODULES=OFF",
            "-DSVN_BUILD_SHARED_FS=ON",
            "-DSVN_INSTALL_PRIVATE_H=ON"
        ]

        if Platform.is_windows():
            cmake_args.append("-DSVN_USE_PKG_CONFIG=OFF")

        if Platform.is_darwin():
            cmake_args.append("-DSVN_ENABLE_AUTH_KEYCHAIN=ON")
        else:
            cmake_args.append("-DSVN_ENABLE_AUTH_KEYCHAIN=OFF")

        if Platform.is_linux():
            cmake_args.extend([
                "-DSVN_ENABLE_AUTH_GNOME_KEYRING=ON",
                "-DSVN_ENABLE_AUTH_KWALLET=ON",
            ])
        else:
            cmake_args.extend([
                "-DSVN_ENABLE_AUTH_GNOME_KEYRING=OFF",
                "-DSVN_ENABLE_AUTH_KWALLET=OFF",
            ])

        env = os.environ.copy()
        env["PKG_CONFIG_PATH"] = (
            f"{installdir}/lib/pkgconfig"
            + (f":{env.get('PKG_CONFIG_PATH', '')}" if env.get("PKG_CONFIG_PATH") else "")
        )

        Platform.run(["cmake", ".."] + Platform.cmake_generator_args() + cmake_args, cwd=build_dir, env=env)
        Platform.run(["cmake", "--build", "."] + Platform.cmake_build_config_args() + [f"-j{Platform.cpu_count()}"], cwd=build_dir)
        Platform.run(["cmake", "--install", "."] + Platform.cmake_build_config_args(), cwd=build_dir)


# ============================================================
# 动态库路径修复
# ============================================================

def fix_dynamic_library_paths(target: str):
    """修复动态库路径，确保可移植性"""
    if Platform.is_darwin():
        fix_darwin_paths(target)
    elif Platform.is_linux():
        fix_linux_paths(target)
    elif Platform.is_windows():
        fix_windows_paths(target)


def _resolve_symlink(filepath):
    """解析符号链接到实际路径"""
    try:
        return str(Path(filepath).resolve())
    except Exception:
        return str(filepath)


def fix_darwin_paths(target: str):
    """修复 macOS 的动态库路径"""
    lib_dir = Path(target).joinpath("lib")
    bin_dir = Path(target).joinpath("bin")

    # 1. 修复库的 install name（去重符号链接）
    seen_dylibs = set()
    for lib_file in lib_dir.glob("*.dylib"):
        real = _resolve_symlink(lib_file)
        if real in seen_dylibs:
            continue
        seen_dylibs.add(real)

        lib_name = lib_file.name
        Platform.run(
            ["install_name_tool", "-id", f"@rpath/{lib_name}", str(lib_file)],
            check=False,
        )

    # 2. 修复库中的绝对路径引用（去重符号链接）
    seen_dylibs = set()
    for lib_file in lib_dir.glob("*.dylib"):
        real = _resolve_symlink(lib_file)
        if real in seen_dylibs:
            continue
        seen_dylibs.add(real)

        result = subprocess.run(
            ["otool", "-L", str(lib_file)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                match = re.search(r"(/Users/\S+\.dylib)", line)
                if match:
                    old_path = match.group(1)
                    dep_name = Path(old_path).name
                    Platform.run(
                        ["install_name_tool", "-change", old_path,
                         f"@rpath/{dep_name}", str(lib_file)],
                        check=False,
                    )

    # 3. 修复可执行文件
    if not bin_dir.exists():
        return

    for bin_file in bin_dir.iterdir():
        if not bin_file.is_file():
            continue
        if bin_file.name in ("c_rehash",) or bin_file.name.endswith("-config"):
            continue

        try:
            with open(bin_file, "rb") as f:
                magic = f.read(4)
            if len(magic) < 4:
                continue
            b1, b2 = magic[0], magic[1]
            # Mach-O magic numbers
            if not ((b1 == 0xCF and b2 == 0xFA) or
                    (b1 == 0xCE and b2 == 0xFA) or
                    (b1 == 0xCA and b2 == 0xFE)):
                continue
        except Exception:
            continue

        # 添加 rpath
        Platform.run(
            ["install_name_tool", "-add_rpath", "@executable_path/../lib",
             str(bin_file)],
            check=False,
        )

        # 修复依赖路径
        result = subprocess.run(
            ["otool", "-L", str(bin_file)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                match = re.search(r"(/Users/\S+\.dylib)", line)
                if match:
                    old_path = match.group(1)
                    dep_name = Path(old_path).name
                    Platform.run(
                        ["install_name_tool", "-change", old_path,
                         f"@rpath/{dep_name}", str(bin_file)],
                        check=False,
                    )


def fix_linux_paths(target: str):
    """修复 Linux 的动态库路径"""
    lib_dir = Path(target).joinpath("lib")
    bin_dir = Path(target).joinpath("bin")

    def fix_needed(elfpath):
        """替换 DT_NEEDED 中的绝对路径为文件名"""
        result = subprocess.run(
            ["patchelf", "--print-needed", str(elfpath)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            return
        for line in result.stdout.split("\n"):
            needed = line.strip()
            if needed.startswith("/"):
                basename = Path(needed).name
                Platform.run(
                    ["patchelf", "--replace-needed", needed, basename,
                     str(elfpath)],
                    check=False,
                )
                print(f"  fixed needed: {elfpath}: {needed} -> {basename}")

    # 修复库（去重符号链接）
    seen = set()
    for lib_file in lib_dir.glob("*.so*"):
        real = _resolve_symlink(lib_file)
        if real in seen:
            continue
        seen.add(real)
        Platform.run(
            ["patchelf", "--set-rpath", "$ORIGIN", str(lib_file)],
            check=False,
        )
        fix_needed(lib_file)

    # 修复可执行文件
    if not bin_dir.exists():
        return

    for bin_file in bin_dir.iterdir():
        if not bin_file.is_file():
            continue
        try:
            with open(bin_file, "rb") as f:
                magic = f.read(4)
            if len(magic) >= 4 and magic[0] == 0x7F and magic[1] == 0x45:  # ELF
                Platform.run(
                    ["patchelf", "--set-rpath", "$ORIGIN/../lib", str(bin_file)],
                    check=False,
                )
                fix_needed(bin_file)
        except Exception:
            pass


def fix_windows_paths(target: str):
    """修复 Windows 的 DLL 路径（将 DLL 从 lib 复制到 bin）"""
    lib_dir = Path(target).joinpath("lib")
    bin_dir = Path(target).joinpath("bin")

    if lib_dir.exists():
        bin_dir.mkdir(parents=True, exist_ok=True)
        for dll in lib_dir.glob("*.dll"):
            shutil.copy2(dll, bin_dir)


# ============================================================
# 主入口
# ============================================================

def main():
    import sys

    output = str(Path("./output").absolute())

    projects = [
        ZLib(),
        Libexpat(),
        Sqlite3(),
        Openssl(),
        Apr(),
        AprIconv(),
        Libxcrypt(),
        AprUtil(),
        Serf(),
        CyrusSasl(),
        Subversion(),
    ]

    if len(sys.argv) > 1 and sys.argv[1] == "clean":
        print("Cleaning build directories...")
        for project in projects:
            project.clean()
        # 清理输出目录
        output_dir = Path(output)
        if output_dir.exists():
            shutil.rmtree(output_dir)
            print(f"  Removed: {output_dir}")
        print("Clean complete!")
        return

    Platform.delete_path(Path(output))

    for project in projects:
        print(f"\n{'=' * 60}")
        print(f"Building {project.name}")
        print(f"{'=' * 60}")

        project.ready(output)
        project.compile(output)
        project.finished(output)

    # 所有项目构建完成，清理 libtool .la 文件（构建期间需要保留以维护依赖链）
    Platform.remove_la_files(Path(output).joinpath("lib"))
    Platform.remove_la_files(Path(output).joinpath("lib").joinpath("iconv"))
    Platform.delete_path(Path(output).joinpath("build-1"))
    Platform.delete_path(Path(output).joinpath("share"))
    Platform.delete_path(Path(output).joinpath("bin").joinpath("apr-1-config"))
    Platform.delete_path(Path(output).joinpath("bin").joinpath("apu-1-config"))
    Platform.delete_path(Path(output).joinpath("bin").joinpath("c_rehash"))

    # 修复动态库路径（对应 xmake.lua 中 subversion-install target）
    print(f"\n{'=' * 60}")
    print("Fixing dynamic library paths")
    print(f"{'=' * 60}")
    fix_dynamic_library_paths(output)

    print(f"\n{'=' * 60}")
    print(f"Build complete!")
    print(f"Output: {output}")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
