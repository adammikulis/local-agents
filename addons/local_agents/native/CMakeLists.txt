cmake_minimum_required(VERSION 3.20)
project(lasim LANGUAGES CXX)

# Build with addons/local_agents/native/build.sh. It fetches glslang and SPIRV-Cross, fills the
# content-addressed dependency cache entry, configures this project against it and bakes kernels.blob.
#   cmake -S <this dir> -B build -DCMAKE_BUILD_TYPE=Release -DLA_NATIVE_DEPS_ENTRY=<entry>
#   cmake --build build --parallel
# Nothing here links godot-cpp: the physics device never lives in Godot's process.

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin")

set(LA_NATIVE_DEPS_ENTRY "" CACHE PATH "Filled dependency cache entry")
if (NOT EXISTS "${LA_NATIVE_DEPS_ENTRY}/la_native_deps.cmake")
    message(FATAL_ERROR "No filled dependency entry at '${LA_NATIVE_DEPS_ENTRY}'. Run native/build.sh")
endif()
include("${LA_NATIVE_DEPS_ENTRY}/la_native_deps.cmake")

add_library(la_device STATIC
    src/device/Device.cpp
    src/device/KernelBlob.cpp)
target_include_directories(la_device PUBLIC include)

if (APPLE)
    enable_language(OBJCXX)
    target_sources(la_device PRIVATE src/device/DeviceMetal.mm)
    set_source_files_properties(src/device/DeviceMetal.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_compile_definitions(la_device PUBLIC LA_BACKEND_METAL=1)
    target_link_libraries(la_device PUBLIC "-framework Metal" "-framework Foundation")
endif()

add_executable(lakc
    tools/lakc/main.cpp
    tools/lakc/Compile.cpp)
target_include_directories(lakc PRIVATE include ${LA_GLSLANG_INCLUDES} ${LA_SPIRV_CROSS_INCLUDES})
target_link_libraries(lakc PRIVATE la_device ${LA_NATIVE_DEP_LIBS})

add_executable(lasim
    src/cli/main.cpp
    src/cli/SelftestDevice.cpp
    src/cli/SelftestKernels.cpp)
target_include_directories(lasim PRIVATE include)
target_link_libraries(lasim PRIVATE la_device)

# The kernels are read where they live; the move out of the Godot tree is a later phase.
set(LA_KERNEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../sim/material/kernels3d")
file(GLOB LA_KERNEL_SOURCES "${LA_KERNEL_DIR}/*.glsl" "${LA_KERNEL_DIR}/*.glsli")
add_custom_command(
    OUTPUT "${CMAKE_CURRENT_SOURCE_DIR}/bin/kernels.blob"
    COMMAND lakc --kernels "${LA_KERNEL_DIR}" --out "${CMAKE_CURRENT_SOURCE_DIR}/bin/kernels.blob"
    DEPENDS lakc ${LA_KERNEL_SOURCES}
    COMMENT "lakc: compiling kernels into bin/kernels.blob")
add_custom_target(kernels ALL DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/bin/kernels.blob")
add_dependencies(lasim kernels)
