cmake_minimum_required(VERSION 3.15)
project(pipesync_native C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(MSVC)
    add_compile_options(/utf-8)
endif()

# 1. librclone C-Shared FFI Library (Portable C99 / Win32 / POSIX)
add_library(rclone SHARED
    native/librclone.c
    native/librclone.h
)

set_target_properties(rclone PROPERTIES
    OUTPUT_NAME "librclone"
    PREFIX ""
)

target_include_directories(rclone PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/native
)

target_compile_definitions(rclone PRIVATE BUILDING_LIBRCLONE)

# 2. QuickJS FFI Sandbox Shared Library (Requires GCC/Clang with GNU extensions)
if(NOT MSVC)
    add_library(pipesync_quickjs SHARED
        native/quickjs/pipesync_quickjs.c
        native/quickjs/pipesync_quickjs.h
        native/quickjs/quickjs.c
        native/quickjs/cutils.c
        native/quickjs/libregexp.c
        native/quickjs/libunicode.c
        native/quickjs/dtoa.c
    )

    set_target_properties(pipesync_quickjs PROPERTIES
        OUTPUT_NAME "libpipesync_quickjs"
        PREFIX ""
    )

    target_include_directories(pipesync_quickjs PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/native/quickjs
    )

    target_compile_definitions(pipesync_quickjs PRIVATE 
        BUILDING_PIPESYNC_QJS
        _GNU_SOURCE 
        CONFIG_VERSION="2026-06-04"
    )

    add_custom_command(TARGET pipesync_quickjs POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_SOURCE_DIR}/native
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:pipesync_quickjs>
        ${CMAKE_CURRENT_SOURCE_DIR}/native
    )
endif()

# 3. Test verification executable (POSIX / GCC)
if(NOT MSVC)
    add_executable(test_librclone
        native/test_librclone.c
    )

    target_link_libraries(test_librclone PRIVATE rclone)
    target_include_directories(test_librclone PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/native)

    add_custom_command(TARGET test_librclone POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_SOURCE_DIR}/native
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:test_librclone>
        ${CMAKE_CURRENT_SOURCE_DIR}/native
    )
endif()

# 4. Windows System Tray Host Application (WIN32 Subsystem)
if(WIN32)
    add_executable(PipeSyncTray WIN32
        windows/tray/pipesync_tray.c
        windows/tray/pipesync_tray.rc
    )
    target_link_libraries(PipeSyncTray PRIVATE shell32 advapi32 user32)
    target_include_directories(PipeSyncTray PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/windows/tray)

    add_custom_command(TARGET PipeSyncTray POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_SOURCE_DIR}/build
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:PipeSyncTray>
        ${CMAKE_CURRENT_SOURCE_DIR}/build
    )
endif()

# Copy output binary and libraries to native/ directory
add_custom_command(TARGET rclone POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_SOURCE_DIR}/native
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:rclone>
    ${CMAKE_CURRENT_SOURCE_DIR}/native
)
