cmake_minimum_required(VERSION 3.20)
project(localagents-gdextension LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(LOCAL_AGENTS_BUILD_SHARED "Build shared library" ON)

set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/godot-cpp" CACHE PATH "Path to godot-cpp")
set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/llama.cpp" CACHE PATH "Path to llama.cpp sources")

if (NOT EXISTS "${GODOT_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp not found. Run scripts/fetch_dependencies.py")
endif()

if (NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found. Run scripts/fetch_dependencies.py")
endif()

add_subdirectory(${GODOT_CPP_DIR} "${CMAKE_BINARY_DIR}/godot-cpp" EXCLUDE_FROM_ALL)
add_subdirectory(${LLAMA_CPP_DIR} "${CMAKE_BINARY_DIR}/llama.cpp" EXCLUDE_FROM_ALL)

set(SRC
    src/AgentNode.cpp
    src/AgentRuntime.cpp
    src/LocalAgentsRegister.cpp
)

set(INCLUDE_DIRS
    include
    ${GODOT_CPP_DIR}/include
    ${GODOT_CPP_DIR}/gen/include
    ${LLAMA_CPP_DIR}/include
)

add_library(localagents SHARED ${SRC})

target_include_directories(localagents PRIVATE ${INCLUDE_DIRS})

target_link_libraries(localagents PRIVATE godot-cpp llama)

if (WIN32)
    set_target_properties(localagents PROPERTIES OUTPUT_NAME "localagents.windows")
elseif (APPLE)
    set_target_properties(localagents PROPERTIES OUTPUT_NAME "localagents.macos")
else()
    set_target_properties(localagents PROPERTIES OUTPUT_NAME "localagents.linux")
endif()

install(TARGETS localagents
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION bin
    ARCHIVE DESTINATION bin)
