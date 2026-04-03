cmake_minimum_required(VERSION 3.18.1)

project("crypto_keys")

# Release Mode O-LLVM Obfuscation Flags
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    # [警告] 标准 Android NDK 不支持 O-LLVM 混淆！
    # 如果您使用的是标准 NDK (如 25.x, 26.x)，请保持以下行注释状态，否则会导致编译失败 (unknown argument)。
    # 只有当您配置了支持 O-LLVM 的定制 NDK (如 Hikari, Obfuscator-LLVM) 时，才取消注释。
    
    # include(CheckCXXCompilerFlag)
    # check_cxx_compiler_flag("-mllvm -sub" HAS_OLLVM)
    # if(HAS_OLLVM)
        # 启用控制流平坦化 (-fla)
        # add_compile_options("-mllvm" "-fla")
        # 启用指令替换 (-sub)
        # add_compile_options("-mllvm" "-sub")
        # 启用虚假控制流 (-bcf)
        # add_compile_options("-mllvm" "-bcf")
    # endif()
    
    # 剥离符号表 (Strip Symbols) - 标准 NDK 支持此选项
    add_link_options("-s")
endif()

add_library(
        crypto_keys
        SHARED
        keys.cpp)

find_library(
        log-lib
        log)

target_link_libraries(
        crypto_keys
        ${log-lib})
