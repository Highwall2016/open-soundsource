cmake_minimum_required(VERSION 3.12)
project(OpenSoundSourceDriver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

# libASPL subdirectory
add_subdirectory(${CMAKE_SOURCE_DIR}/../third_party/libASPL third_party/libASPL)

# Virtual driver bundle target
set(DRIVER_NAME "OpenSoundSourceDriver")
add_library(${DRIVER_NAME} MODULE
    OSS_PlugIn.cpp
    OSS_Device.cpp
)

# CoreAudio HAL plugins must be `.driver` bundles
set_target_properties(${DRIVER_NAME} PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/VirtualDriver-Info.plist
)

target_link_libraries(${DRIVER_NAME} PRIVATE libASPL)
target_link_libraries(${DRIVER_NAME} PRIVATE
    "-framework CoreAudio"
    "-framework CoreFoundation"
    "-framework AudioToolbox"
)

# Optional: suppress some libASPL or driver warnings during build
target_compile_options(${DRIVER_NAME} PRIVATE -Wall -Wextra -Wno-unused-parameter)
