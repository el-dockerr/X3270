cmake_minimum_required(VERSION 3.21)
project(DX3270 VERSION 1.7.4 LANGUAGES CXX OBJCXX)

# ── Version / Build number ────────────────────────────────────────────────────
# Override on the command line: cmake -DBUILD_NUMBER=42 ..
set(BUILD_NUMBER "1" CACHE STRING "Monotonically increasing build counter")
set(FULL_VERSION "${PROJECT_VERSION}.${BUILD_NUMBER}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ── Dependencies ─────────────────────────────────────────────────────────────
# Link OpenSSL statically so the produced .app is fully self-contained. A
# dynamically-linked build hard-codes an absolute Homebrew path
# (/opt/homebrew/opt/openssl@3 or /usr/local/opt/openssl@3) that does NOT exist
# on an end user's Mac, so the app would fail to launch after download.
set(OPENSSL_USE_STATIC_LIBS TRUE)
find_package(OpenSSL REQUIRED)

# ── Sources ───────────────────────────────────────────────────────────────────
set(CORE_SOURCES
    src/core/TLSTransport.cpp
    src/core/TN3270Session.cpp
    src/core/TN5250Session.cpp
    src/core/EbcdicCodec.cpp
    src/core/ScreenBuffer.cpp
    src/core/DataStreamParser.cpp
    src/core/DataStream5250Parser.cpp
    src/core/KeyboardState.cpp
    src/core/KeyboardState5250.cpp
    src/core/GraphicsBuffer.cpp
    src/core/GocaParser.cpp
)

set(UI_SOURCES
    src/ui/main.mm
    src/ui/AppDelegate.mm
    src/ui/ConnectionWindowController.mm
    src/ui/DebugWindowController.mm
    src/ui/TerminalView.mm
    src/ui/TerminalWindowController.mm
    src/ui/PreferencesWindowController.mm
    src/ui/ShortcutsWindowController.mm
)

# ── App Bundle ────────────────────────────────────────────────────────────────
add_executable(DX3270 MACOSX_BUNDLE
    ${CORE_SOURCES}
    ${UI_SOURCES}
)

set_target_properties(DX3270 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "DX3270"
    MACOSX_BUNDLE_BUNDLE_VERSION "${BUILD_NUMBER}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.dx3270.macos"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.dx3270.macos"
)

target_include_directories(DX3270 PRIVATE
    src/core
    src/ui
    ${OPENSSL_INCLUDE_DIR}
)

target_link_libraries(DX3270 PRIVATE
    OpenSSL::SSL
    OpenSSL::Crypto
    "-framework AppKit"
    "-framework Foundation"
    "-framework CoreText"
    "-framework CoreGraphics"
)

target_compile_options(DX3270 PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)

# ── 3270 font resources ───────────────────────────────────────────────────────
# Fonts by Ricardo Bánffy (https://github.com/rbanffy/3270font), SIL OFL-1.1
set(FONT_RESOURCES
    resources/fonts/3270-Regular.otf
    resources/fonts/3270SemiCondensed-Regular.otf
    resources/fonts/3270Condensed-Regular.otf
)
target_sources(DX3270 PRIVATE ${FONT_RESOURCES})
set_source_files_properties(${FONT_RESOURCES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources/fonts"
)

# ── App icon ──────────────────────────────────────────────────────────────────
target_sources(DX3270 PRIVATE resources/AppIcon.icns)
set_source_files_properties(resources/AppIcon.icns PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources"
)
set_target_properties(DX3270 PROPERTIES
    MACOSX_BUNDLE_ICON_FILE "AppIcon"
)

# ── Compile .mm files as Objective-C++ with ARC ──────────────────────────────
foreach(src_file ${UI_SOURCES})
    set_source_files_properties(${src_file} PROPERTIES
        COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
    )
endforeach()
