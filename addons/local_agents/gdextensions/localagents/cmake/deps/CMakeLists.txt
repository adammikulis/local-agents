cmake_minimum_required(VERSION 3.20)
project(localagents-deps LANGUAGES CXX C)

# godot-cpp and llama.cpp, built ONCE per (dep commit, compiler, flags) into a content-addressed cache
# entry. Every artifact a consumer needs -- libraries, tools, godot-cpp's headers and generated bindings,
# llama.cpp's headers -- is STAGED INTO the entry, and la_deps.cmake names them relative to its own
# location, so the entry does not depend on the worktree that filled it.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(GODOT_CPP_DIR "" CACHE PATH "Path to godot-cpp sources")
set(LLAMA_CPP_DIR "" CACHE PATH "Path to llama.cpp sources")
set(LA_DEPS_ENTRY "" CACHE PATH "Cache entry root the built dependencies are staged into")
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot API version; must be one the pinned godot-cpp carries")

if (MSVC)
    set(GODOTCPP_USE_STATIC_CPP OFF CACHE BOOL "Use the DLL runtime shared with llama.cpp and vcpkg" FORCE)
endif()

set(LLAMA_BUILD_COMMON ON CACHE BOOL "llama: build common utils" FORCE)
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "llama: build tools (llama-cli, etc.)" FORCE)
set(LLAMA_BUILD_SERVER ON CACHE BOOL "llama: build server example" FORCE)
set(LLAMA_CURL ON CACHE BOOL "llama: enable curl support" FORCE)

if (NOT EXISTS "${GODOT_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp not found at '${GODOT_CPP_DIR}'. Run scripts/fetch_dependencies.sh")
endif()
if (NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found at '${LLAMA_CPP_DIR}'. Run scripts/fetch_dependencies.sh")
endif()
if (NOT LA_DEPS_ENTRY)
    message(FATAL_ERROR "LA_DEPS_ENTRY is unset. build_extension.sh passes the cache entry to stage into.")
endif()

add_subdirectory("${GODOT_CPP_DIR}" "${CMAKE_BINARY_DIR}/godot-cpp")
add_subdirectory("${LLAMA_CPP_DIR}" "${CMAKE_BINARY_DIR}/llama.cpp")

set(LA_DEP_TARGETS godot-cpp llama llama-common mtmd ggml ggml-base ggml-cpu ggml-blas ggml-metal)

# source directory -> destination under the entry. A directory that moves upstream fails its copy, which
# is the build going red rather than a consumer compiling against headers that are not there.
set(LA_HEADER_STAGE
    "${GODOT_CPP_DIR}/include|include/godot-cpp"
    "${CMAKE_BINARY_DIR}/godot-cpp/gen/include|include/godot-cpp-gen"
    "${LLAMA_CPP_DIR}/include|include/llama"
    "${LLAMA_CPP_DIR}/ggml/include|include/llama"
    "${LLAMA_CPP_DIR}/vendor|include/llama"
    "${LLAMA_CPP_DIR}/common|include/llama/common")

set(LA_DEPS_CONTENT "")
foreach(t IN LISTS LA_DEP_TARGETS)
    if (TARGET ${t})
        string(REPLACE "-" "_" var "${t}")
        string(APPEND LA_DEPS_CONTENT
            "set(LA_DEP_${var} \"\${CMAKE_CURRENT_LIST_DIR}/lib/$<TARGET_LINKER_FILE_NAME:${t}>\")\n")
    endif()
endforeach()
# godot-cpp's usage requirements, resolved. A binding compiled against different definitions than the
# library is an ABI mismatch that links and then crashes, so these travel with the artifact.
string(APPEND LA_DEPS_CONTENT
    "set(LA_GODOT_CPP_MSVC_RUNTIME \"$<TARGET_PROPERTY:godot-cpp,MSVC_RUNTIME_LIBRARY>\")\n"
    "set(LA_GODOT_CPP_DEFS \"$<TARGET_PROPERTY:godot-cpp,INTERFACE_COMPILE_DEFINITIONS>\")\n"
    "set(LA_GODOT_CPP_OPTIONS \"$<TARGET_PROPERTY:godot-cpp,INTERFACE_COMPILE_OPTIONS>\")\n"
    "set(LA_GODOT_CPP_INCLUDES \"\${CMAKE_CURRENT_LIST_DIR}/include/godot-cpp;\${CMAKE_CURRENT_LIST_DIR}/include/godot-cpp-gen\")\n"
    "set(LA_LLAMA_INCLUDES \"\${CMAKE_CURRENT_LIST_DIR}/include/llama;\${CMAKE_CURRENT_LIST_DIR}/include/llama/common\")\n")
file(GENERATE OUTPUT "${LA_DEPS_ENTRY}/la_deps.cmake" CONTENT "${LA_DEPS_CONTENT}")

add_custom_target(la_deps ALL DEPENDS godot-cpp llama llama-common)
foreach(t IN ITEMS llama-cli llama-server mtmd)
    if (TARGET ${t})
        add_dependencies(la_deps ${t})
    endif()
endforeach()

add_custom_command(TARGET la_deps POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${LA_DEPS_ENTRY}/include" "${LA_DEPS_ENTRY}/lib")
foreach(pair IN LISTS LA_HEADER_STAGE)
    string(REPLACE "|" ";" parts "${pair}")
    list(GET parts 0 stage_src)
    list(GET parts 1 stage_dst)
    add_custom_command(TARGET la_deps POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${stage_src}" "${LA_DEPS_ENTRY}/${stage_dst}")
endforeach()
add_custom_command(TARGET la_deps POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_BINARY_DIR}/bin" "${LA_DEPS_ENTRY}/lib")
foreach(t IN LISTS LA_DEP_TARGETS)
    if (TARGET ${t})
        add_custom_command(TARGET la_deps POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:${t}>" "${LA_DEPS_ENTRY}/lib/")
        if (WIN32)
            get_target_property(dep_type ${t} TYPE)
            if (dep_type STREQUAL "SHARED_LIBRARY")
                add_custom_command(TARGET la_deps POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_LINKER_FILE:${t}>" "${LA_DEPS_ENTRY}/lib/")
            endif()
        endif()
    endif()
endforeach()
