cmake_minimum_required(VERSION 3.20)
project(localagents-gdextension LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(LOCAL_AGENTS_BUILD_SHARED "Build shared library" ON)

set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/godot-cpp" CACHE PATH "Path to godot-cpp")
set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/llama.cpp" CACHE PATH "Path to llama.cpp sources")

# Enable llama.cpp common utilities so we can reuse chat/template helpers.
set(LLAMA_BUILD_COMMON ON CACHE BOOL "llama: build common utils" ON)
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "llama: build tools (llama-cli, etc.)" ON)
set(LLAMA_BUILD_SERVER ON CACHE BOOL "llama: build server example" ON)
set(LLAMA_CURL ON CACHE BOOL "llama: enable curl support" ON)

if (NOT EXISTS "${GODOT_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp not found. Run scripts/fetch_dependencies.py")
endif()

if (NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found. Run scripts/fetch_dependencies.py")
endif()

add_subdirectory(${GODOT_CPP_DIR} "${CMAKE_BINARY_DIR}/godot-cpp" EXCLUDE_FROM_ALL)
add_subdirectory(${LLAMA_CPP_DIR} "${CMAKE_BINARY_DIR}/llama.cpp" EXCLUDE_FROM_ALL)

set(SIM_SRC
    src/sim/VoxelEditGpuExecutor.cpp
    src/sim/VoxelGpuResourceCache.cpp
    src/sim/VoxelGpuDispatchMetadata.cpp
    src/sim/CoreSimulationPipeline.cpp
    src/sim/CoreSimulationPipelineFieldInputResolution.cpp
    src/sim/CoreSimulationPipelineFieldInputResolutionScalarHelpers.cpp
    src/sim/CoreSimulationPipelineFieldEvolution.cpp
    src/sim/CoreSimulationPipelineInternal.cpp
    src/sim/CoreSimulationPipelineStages.cpp
)

set(HELPER_SRC
    src/helpers/StructureLifecycleNativeHelpers.cpp
    src/helpers/SimulationCoreDictionaryHelpers.cpp
    src/helpers/VoxelEditCpuExecutionHelpers.cpp
    src/helpers/VoxelEditParsingHelpers.cpp
    src/helpers/VoxelEditPayloadValidationHelpers.cpp
    src/helpers/NativeVoxelTerrainMutatorSurfaceDeltaHelpers.cpp
)

set(SRC
    src/AgentNode.cpp
    src/AgentRuntime.cpp
    src/LocalAgentsComputeManager.cpp
    src/LocalAgentsFieldRegistry.cpp
    src/LocalAgentsEnvironmentStageExecutor.cpp
    src/ModelDownloadManager.cpp
    src/NetworkGraph.cpp
    src/LocalAgentsQueryService.cpp
    src/LocalAgentsRegister.cpp
    src/LocalAgentsScheduler.cpp
    src/LocalAgentsSimProfiler.cpp
    src/LocalAgentsSimulationCore.cpp
    src/LocalAgentsNativeVoxelTerrainMutator.cpp
    src/LocalAgentsVoxelOrchestration.cpp
    src/FailureEmissionDeterministicNoise.cpp
    src/SimulationFailureEmissionPlanner.cpp
    ${HELPER_SRC}
    ${SIM_SRC}
    src/VoxelEditEngine.cpp
)

set(SQLITE_SRC
    thirdparty/sqlite/sqlite3.c
)

set(INCLUDE_DIRS
    include
    ${GODOT_CPP_DIR}/include
    ${GODOT_CPP_DIR}/gen/include
    ${LLAMA_CPP_DIR}
    ${LLAMA_CPP_DIR}/include
    ${LLAMA_CPP_DIR}/common
    ${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/sqlite
)

add_library(localagents SHARED ${SRC} ${SQLITE_SRC})

target_include_directories(localagents PRIVATE ${INCLUDE_DIRS})

target_link_libraries(localagents PRIVATE godot-cpp llama common)

if (TARGET llama-cli)
    add_dependencies(localagents llama-cli)
endif()
if (TARGET llama-server)
    add_dependencies(localagents llama-server)
endif()

find_package(CURL REQUIRED)
if (CURL_FOUND)
    target_include_directories(localagents PRIVATE ${CURL_INCLUDE_DIRS})
    target_link_libraries(localagents PRIVATE ${CURL_LIBRARIES})
    target_compile_definitions(localagents PRIVATE LLAMA_USE_CURL)
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
