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
    src/MemoryGraph.cpp
    src/LocalAgentsRegister.cpp
)

set(SQLITE_SRC
    thirdparty/sqlite/sqlite3.c
)

set(INCLUDE_DIRS
    include
    ${GODOT_CPP_DIR}/include
    ${GODOT_CPP_DIR}/gen/include
    ${LLAMA_CPP_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/sqlite
)

add_library(localagents SHARED ${SRC} ${SQLITE_SRC})

target_include_directories(localagents PRIVATE ${INCLUDE_DIRS})

target_link_libraries(localagents PRIVATE godot-cpp llama)

target_compile_definitions(localagents PRIVATE
    SQLITE_ENABLE_JSON1
    SQLITE_ENABLE_FTS5
    SQLITE_THREADSAFE=1
    SQLITE_DEFAULT_MEMSTATUS=0
    SQLITE_OMIT_LOAD_EXTENSION
    SQLITE_USE_URI=1
)

if (WIN32)
    set_target_properties(localagents PROPERTIES OUTPUT_NAME "localagents.windows")
elseif (APPLE)
    set_target_properties(localagents PROPERTIES
        OUTPUT_NAME "localagents.macos"
        INSTALL_RPATH "@loader_path")
else()
    set_target_properties(localagents PROPERTIES OUTPUT_NAME "localagents.linux")
endif()

install(TARGETS localagents
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION bin
    ARCHIVE DESTINATION bin)
