cmake_minimum_required(VERSION 3.20)
project(localagents-gdextension LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(LOCAL_AGENTS_BUILD_SHARED "Build shared library" ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(LOCAL_AGENTS_DEPS_ENTRY "" CACHE PATH "Self-contained godot-cpp/llama.cpp cache entry from cmake/deps")

if (NOT EXISTS "${LOCAL_AGENTS_DEPS_ENTRY}/la_deps.cmake")
    message(FATAL_ERROR
        "No dependency cache entry at '${LOCAL_AGENTS_DEPS_ENTRY}'. "
        "Configure through scripts/build_extension.sh, which fills the cache and passes it in.")
endif()
include("${LOCAL_AGENTS_DEPS_ENTRY}/la_deps.cmake")

foreach(dep IN ITEMS godot_cpp llama llama_common mtmd ggml ggml_base ggml_cpu ggml_blas ggml_metal)
    if (LA_DEP_${dep})
        string(REPLACE "_" "-" tgt "${dep}")
        add_library(${tgt} UNKNOWN IMPORTED)
        set_target_properties(${tgt} PROPERTIES IMPORTED_LOCATION "${LA_DEP_${dep}}")
    endif()
endforeach()
set_target_properties(godot-cpp PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${LA_GODOT_CPP_INCLUDES}"
    INTERFACE_COMPILE_DEFINITIONS "${LA_GODOT_CPP_DEFS}"
    INTERFACE_COMPILE_OPTIONS "${LA_GODOT_CPP_OPTIONS}")

# NOTE: the homegrown ecosystem/settlement simulation + native voxel-edit/dispatch
# sources were removed with that stack. Only the LLM/agent/graph runtime remains.
set(SRC
    src/AgentNode.cpp
    src/AgentRuntime.cpp
    src/LAAblate.cpp
    src/LAAbsorptionBands.cpp
    src/LAColumnRadiation.cpp
    src/LABallistics.cpp
    src/LATestMasses.cpp
    src/LAMixtureEnthalpy.cpp
    src/LAPlanetTables.cpp
    src/LAMeltEos.cpp
    src/LAPhaseEos.cpp
    src/LABodySystem.cpp
    src/LAFieldCellMass.cpp
    src/LAGridGeometry.cpp
    src/LAGravitySolve.cpp
    src/LAFieldDriver.cpp
    src/LAFieldLedger.cpp
    src/LAFieldMirrors.cpp
    src/LAThreadClock.cpp
    src/LAFieldSnapshot.cpp
    src/LAFieldStateCache.cpp
    src/LAFieldHydrosphereSeed.cpp
    src/LAFieldLithostaticSeed.cpp
    src/LASubstances.cpp
    src/LAWaterCurves.cpp
    src/NetworkGraph.cpp
    src/LAProcess.cpp
    src/LAProcessSet.cpp
    src/LANoActivation.cpp
    src/LocalAgentsRegister.cpp
)

set(SQLITE_SRC
    thirdparty/sqlite/sqlite3.c
)

set(INCLUDE_DIRS
    include
    ${LA_LLAMA_INCLUDES}
    ${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/sqlite
)

add_library(localagents SHARED ${SRC} ${SQLITE_SRC})

target_include_directories(localagents PRIVATE ${INCLUDE_DIRS})

target_link_libraries(localagents PRIVATE godot-cpp llama llama-common)
foreach(tgt IN ITEMS ggml ggml-base)
    if (TARGET ${tgt})
        target_link_libraries(localagents PRIVATE ${tgt})
    endif()
endforeach()

find_package(CURL REQUIRED)
if (CURL_FOUND)
    target_include_directories(localagents PRIVATE ${CURL_INCLUDE_DIRS})
    target_link_libraries(localagents PRIVATE ${CURL_LIBRARIES})
    target_compile_definitions(localagents PRIVATE LLAMA_USE_CURL)
endif()

if (WIN32)
    # SHA-256 for downloaded-model verification uses the CNG (BCrypt) provider.
    target_link_libraries(localagents PRIVATE bcrypt)
endif()

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
    target_sources(localagents PRIVATE src/LANoActivation.mm)
    target_link_libraries(localagents PRIVATE "-framework AppKit")
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
