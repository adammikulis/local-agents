cmake_minimum_required(VERSION 3.20)
project(lasim-deps LANGUAGES CXX C)

# glslang and SPIRV-Cross built ONCE per (dep commit, compiler, flags) into a content-addressed cache
# entry. Headers and libraries are STAGED INTO the entry and la_native_deps.cmake names them relative to
# its own location, so the entry does not depend on the worktree that filled it.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(GLSLANG_DIR "" CACHE PATH "Path to glslang sources")
set(SPIRV_CROSS_DIR "" CACHE PATH "Path to SPIRV-Cross sources")
set(LA_NATIVE_DEPS_ENTRY "" CACHE PATH "Cache entry root the built dependencies are staged into")

if (NOT EXISTS "${GLSLANG_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "glslang not found at '${GLSLANG_DIR}'. Run native/scripts/fetch_dependencies.sh")
endif()
if (NOT EXISTS "${SPIRV_CROSS_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "SPIRV-Cross not found at '${SPIRV_CROSS_DIR}'. Run native/scripts/fetch_dependencies.sh")
endif()
if (NOT LA_NATIVE_DEPS_ENTRY)
    message(FATAL_ERROR "LA_NATIVE_DEPS_ENTRY is unset. build.sh passes the cache entry to stage into.")
endif()

# ENABLE_OPT drags in SPIRV-Tools, which lakc does not use: it emits SPIR-V and hands it straight to
# SPIRV-Cross. Off, glslang carries its own spirv headers and needs no second repository.
set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
set(ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)
set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_GLSL ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_MSL ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_C_API OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_UTIL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)

add_subdirectory("${GLSLANG_DIR}" "${CMAKE_BINARY_DIR}/glslang" EXCLUDE_FROM_ALL)
add_subdirectory("${SPIRV_CROSS_DIR}" "${CMAKE_BINARY_DIR}/SPIRV-Cross" EXCLUDE_FROM_ALL)

set(LA_NATIVE_DEP_TARGETS glslang SPIRV MachineIndependent GenericCodeGen OSDependent
    glslang-default-resource-limits spirv-cross-core spirv-cross-glsl spirv-cross-msl)

# source directory -> destination under the entry. A directory that moves upstream fails its copy, which
# is the build going red rather than a consumer compiling against headers that are not there.
set(LA_NATIVE_HEADER_STAGE
    "${GLSLANG_DIR}/glslang|include/glslang/glslang"
    "${GLSLANG_DIR}/SPIRV|include/glslang/SPIRV"
    "${CMAKE_BINARY_DIR}/include|include/glslang-gen")

set(LA_NATIVE_CONTENT "")
foreach(t IN LISTS LA_NATIVE_DEP_TARGETS)
    if (TARGET ${t})
        string(REPLACE "-" "_" var "${t}")
        string(APPEND LA_NATIVE_CONTENT
            "list(APPEND LA_NATIVE_DEP_LIBS \"\${CMAKE_CURRENT_LIST_DIR}/lib/$<TARGET_FILE_NAME:${t}>\")\n")
    endif()
endforeach()
string(APPEND LA_NATIVE_CONTENT
    "set(LA_GLSLANG_INCLUDES \"\${CMAKE_CURRENT_LIST_DIR}/include/glslang;\${CMAKE_CURRENT_LIST_DIR}/include/glslang-gen\")\n"
    "set(LA_SPIRV_CROSS_INCLUDES \"\${CMAKE_CURRENT_LIST_DIR}/include/spirv_cross\")\n")
file(GENERATE OUTPUT "${LA_NATIVE_DEPS_ENTRY}/la_native_deps.cmake" CONTENT "${LA_NATIVE_CONTENT}")

set(LA_NATIVE_BUILT "")
foreach(t IN LISTS LA_NATIVE_DEP_TARGETS)
    if (TARGET ${t})
        list(APPEND LA_NATIVE_BUILT ${t})
    endif()
endforeach()
add_custom_target(la_native_deps ALL DEPENDS ${LA_NATIVE_BUILT})

add_custom_command(TARGET la_native_deps POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${LA_NATIVE_DEPS_ENTRY}/include" "${LA_NATIVE_DEPS_ENTRY}/lib"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LA_NATIVE_DEPS_ENTRY}/include/spirv_cross"
                                               "${LA_NATIVE_DEPS_ENTRY}/lib")
foreach(pair IN LISTS LA_NATIVE_HEADER_STAGE)
    string(REPLACE "|" ";" parts "${pair}")
    list(GET parts 0 stage_src)
    list(GET parts 1 stage_dst)
    add_custom_command(TARGET la_native_deps POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${stage_src}" "${LA_NATIVE_DEPS_ENTRY}/${stage_dst}")
endforeach()
# SPIRV-Cross's headers sit beside its sources; only the public ones are staged.
file(GLOB LA_SPIRV_CROSS_HEADERS "${SPIRV_CROSS_DIR}/*.hpp" "${SPIRV_CROSS_DIR}/*.h")
foreach(h IN LISTS LA_SPIRV_CROSS_HEADERS)
    add_custom_command(TARGET la_native_deps POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${h}" "${LA_NATIVE_DEPS_ENTRY}/include/spirv_cross/")
endforeach()
foreach(t IN LISTS LA_NATIVE_BUILT)
    add_custom_command(TARGET la_native_deps POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:${t}>" "${LA_NATIVE_DEPS_ENTRY}/lib/")
endforeach()
