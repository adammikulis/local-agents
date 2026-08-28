cmake_minimum_required(VERSION 3.20)
project(localagents-deps LANGUAGES CXX C)

# godot-cpp and llama.cpp, built ONCE per (dep commit, compiler, flags) into a content-addressed cache
# directory. la_deps.cmake below carries the resolved artifact paths and godot-cpp's usage requirements,
# so the extension links what this built without configuring either dependency again.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(GODOT_CPP_DIR "" CACHE PATH "Path to godot-cpp sources")
set(LLAMA_CPP_DIR "" CACHE PATH "Path to llama.cpp sources")
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot API version; must be one the pinned godot-cpp carries")

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

add_subdirectory("${GODOT_CPP_DIR}" "${CMAKE_BINARY_DIR}/godot-cpp")
add_subdirectory("${LLAMA_CPP_DIR}" "${CMAKE_BINARY_DIR}/llama.cpp")

set(LA_DEP_TARGETS godot-cpp llama llama-common mtmd ggml ggml-base ggml-cpu ggml-blas ggml-metal)
set(LA_DEPS_CONTENT "")
foreach(t IN LISTS LA_DEP_TARGETS)
    if (TARGET ${t})
        string(REPLACE "-" "_" var "${t}")
        string(APPEND LA_DEPS_CONTENT "set(LA_DEP_${var} \"$<TARGET_FILE:${t}>\")\n")
    endif()
endforeach()
# godot-cpp's usage requirements, resolved. A binding compiled against different definitions than the
# library is an ABI mismatch that links and then crashes, so these travel with the artifact.
string(APPEND LA_DEPS_CONTENT
    "set(LA_GODOT_CPP_DEFS \"$<TARGET_PROPERTY:godot-cpp,INTERFACE_COMPILE_DEFINITIONS>\")\n"
    "set(LA_GODOT_CPP_INCLUDES \"$<TARGET_PROPERTY:godot-cpp,INTERFACE_INCLUDE_DIRECTORIES>\")\n"
    "set(LA_GODOT_CPP_OPTIONS \"$<TARGET_PROPERTY:godot-cpp,INTERFACE_COMPILE_OPTIONS>\")\n"
    "set(LA_LLAMA_COMMON_INCLUDES \"$<TARGET_PROPERTY:llama-common,INTERFACE_INCLUDE_DIRECTORIES>\")\n")
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/la_deps.cmake" CONTENT "${LA_DEPS_CONTENT}")

add_custom_target(la_deps ALL DEPENDS godot-cpp llama llama-common)
foreach(t IN ITEMS llama-cli llama-server mtmd)
    if (TARGET ${t})
        add_dependencies(la_deps ${t})
    endif()
endforeach()
