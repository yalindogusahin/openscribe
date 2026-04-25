cmake_minimum_required(VERSION 3.20)
project(OpenScribeNative LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

set(SOURCES
    src/main.mm
    src/AppDelegate.mm
    src/MainWindow.mm
)

add_executable(OpenScribeNative MACOSX_BUNDLE ${SOURCES})

set_target_properties(OpenScribeNative PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "OpenScribe Native"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.yalindogusahin.openscribe.native"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_INFO_PLIST_NSHIGHRESOLUTIONCAPABLE "YES"
)

target_link_libraries(OpenScribeNative PRIVATE
    "-framework Cocoa"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework AVFoundation"
    "-framework AudioUnit"
    "-framework Metal"
    "-framework MetalKit"
    "-framework QuartzCore"
)

target_compile_options(OpenScribeNative PRIVATE -Wall -Wextra -fobjc-arc)
