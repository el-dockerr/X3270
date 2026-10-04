cmake_minimum_required(VERSION 3.21)
project(DX3270 VERSION 1.7.6 LANGUAGES CXX OBJCXX)

# ==============================================================================
# Optimization and binary size reduction flags (Release)
# ==============================================================================
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release")
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -flto -fdata-sections -ffunction-sections")
    set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} -Wl,-dead_strip")
endif()

# ==============================================================================
# Version / Build number
# ==============================================================================
set(BUILD_NUMBER "1" CACHE STRING "Monotonically increasing build counter")
set(FULL_VERSION "${PROJECT_VERSION}.${BUILD_NUMBER}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ==============================================================================
# Dependencies (OpenSSL)
# ==============================================================================
set(OPENSSL_USE_STATIC_LIBS TRUE)

if(NOT DEFINED OPENSSL_ROOT_DIR AND EXISTS "/opt/homebrew/opt/openssl@3")
    set(OPENSSL_ROOT_DIR "/opt/homebrew/opt/openssl@3")
endif()

find_package(OpenSSL REQUIRED)

# ==============================================================================
# Qt6 Configuration
# ==============================================================================
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Find Qt6 as an optional component. 
# This allows building the macOS native app even if Qt6 is not installed on the system.
find_package(Qt6 COMPONENTS Core Gui Widgets OPTIONAL_COMPONENTS)

# ==============================================================================
# 1. Core C++ Engine (Static Shared Library)
# ==============================================================================
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
    src/core/MacroRecorder.cpp
    src/core/MacroRunner.cpp
    src/core/ScreenStructuralAnalyzer.cpp
    src/core/LogIsolatorEngine.cpp
)

add_library(dx3270_core STATIC ${CORE_SOURCES})

target_include_directories(dx3270_core PUBLIC
    src/core
    ${OPENSSL_INCLUDE_DIR}
)

target_link_libraries(dx3270_core PRIVATE
    OpenSSL::SSL
    OpenSSL::Crypto
)

# ==============================================================================
# 2. Headless Automation Engine CLI (Cross-Platform)
# ==============================================================================
add_executable(dx3270_headless src/core/HeadlessEngine.cpp)
target_link_libraries(dx3270_headless PRIVATE dx3270_core)

# ==============================================================================
# 3. macOS Native UI App (AppKit)
# ==============================================================================
if(APPLE)
    set(UI_APP_SOURCES
        src/ui/main.mm
        src/ui/AppDelegate.mm
    )

    set(UI_TERMINAL_SOURCES
        src/ui/TerminalView.mm
        src/ui/TerminalViewController.mm
        src/ui/TerminalWindowController.mm
        src/ui/DebugWindowController.mm
        src/ui/DataInspectorViewController.mm
        src/ui/CommandDockViewController.mm
        src/ui/OOBPopoverViewController.mm
        src/ui/TransferDockViewController.mm
        src/ui/TimeMachineHUDView.mm
    )

    set(UI_WORKSPACE_SOURCES
        src/ui/WorkspaceViewController.mm
        src/ui/WorkspaceWindowController.mm
        src/ui/WorkspaceSidebarViewController.mm
        src/ui/SessionEditViewController.mm
    )

    set(UI_SETTINGS_SOURCES
        src/ui/ConnectionWindowController.mm
        src/ui/PreferencesWindowController.mm
        src/ui/ShortcutsWindowController.mm
    )

    set(UTILITY_SOURCES
        src/utils/ConfigLoader.mm
        src/utils/TimeMachineManager.mm
        src/utils/VideoRecorder.mm
        src/utils/WorkspaceManager.mm
    )

    set(UI_PANE_SOURCES
        src/ui/TerminalPaneViewController.mm
    )

    set(UI_SOURCES
        ${UI_APP_SOURCES}
        ${UI_TERMINAL_SOURCES}
        ${UI_WORKSPACE_SOURCES}
        ${UI_SETTINGS_SOURCES}
        ${UI_PANE_SOURCES}
        ${UTILITY_SOURCES}
        src/core/MacroSerializer.mm
    )

    # IDE Source Group
    source_group(TREE "${CMAKE_SOURCE_DIR}/src" PREFIX "src" FILES
        ${CORE_SOURCES}
        ${UI_SOURCES}
    )

    # macOS App Bundle
    add_executable(DX3270 MACOSX_BUNDLE ${UI_SOURCES})

    set_target_properties(DX3270 PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/Info.plist"
        MACOSX_BUNDLE_BUNDLE_NAME "DX3270"
        MACOSX_BUNDLE_BUNDLE_VERSION "${BUILD_NUMBER}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.dx3270.macos"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.dx3270.macos"
        MACOSX_BUNDLE_ICON_FILE "AppIcon"
    )

    target_include_directories(DX3270 PRIVATE
        src/ui
        src/utils
    )

    target_link_libraries(DX3270 PRIVATE
        dx3270_core
        "-framework AppKit"
        "-framework Foundation"
        "-framework CoreText"
        "-framework CoreGraphics"
        "-weak_framework UniformTypeIdentifiers"
        "-framework Security"
        "-framework AVFoundation"  
        "-framework CoreMedia"     
        "-framework CoreVideo"     
        "-framework ImageIO"
    )

    target_compile_options(DX3270 PRIVATE
        -Wall
        -Wextra
        -Wno-unused-parameter
    )

    # Resources mapping
    set(FONT_RESOURCES
        resources/fonts/3270-Regular.otf
        resources/fonts/3270SemiCondensed-Regular.otf
        resources/fonts/3270Condensed-Regular.otf
    )
    target_sources(DX3270 PRIVATE ${FONT_RESOURCES})
    set_source_files_properties(${FONT_RESOURCES} PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/fonts"
    )

    target_sources(DX3270 PRIVATE resources/AppIcon.icns)
    set_source_files_properties(resources/AppIcon.icns PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )

    set(JSON_RESOURCES
        resources/commands.json
        resources/panel_rules.json
        resources/patterns.json
    )
    target_sources(DX3270 PRIVATE ${JSON_RESOURCES})
    set_source_files_properties(${JSON_RESOURCES} PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )

    # Compile .mm files as Objective-C++ ARC
    foreach(src_file ${UI_SOURCES})
        set_source_files_properties(${src_file} PROPERTIES
            COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
        )
    endforeach()
endif()

# ==============================================================================
# 4. Cross-Platform UI App (Qt6)
# ==============================================================================
if(Qt6_FOUND)
    message(STATUS "Qt6 found: Building DX3270_Qt target")
    
    set(QT_UI_SOURCES
        src/qt/main.cpp
        src/qt/MainWindow.cpp
        src/qt/TerminalWidget.cpp
        src/qt/ConnectionDialog.cpp
        src/qt/DataInspectorDialog.cpp
        src/qt/SessionEditDialog.cpp
        src/qt/OOBPopoverWidget.cpp
        src/qt/TimeMachineManager.cpp
        src/qt/TimeMachineHUDWidget.cpp
        src/qt/WorkspaceManager.cpp
        src/qt/WorkspaceSidebarWidget.cpp
        src/qt/TerminalPaneWidget.cpp
        src/qt/CommandDockWidget.cpp
        src/qt/WorkspaceWindow.cpp
        src/qt/PreferencesDialog.cpp
        src/qt/ShortcutsDialog.cpp
    )

    set(APP_ICON "resources/AppIcon.icns")
    set_source_files_properties(${APP_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

    if(APPLE)
        add_executable(DX3270_Qt MACOSX_BUNDLE ${QT_UI_SOURCES} ${APP_ICON})
        set_target_properties(DX3270_Qt PROPERTIES MACOSX_BUNDLE_ICON_FILE "AppIcon.icns")
    else()
        add_executable(DX3270_Qt WIN32 ${QT_UI_SOURCES})
    endif()

    target_include_directories(DX3270_Qt PRIVATE src/qt)

    target_link_libraries(DX3270_Qt PRIVATE
        dx3270_core
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
    )
else()
    message(WARNING "Qt6 not found. The DX3270_Qt executable will not be built.")
endif()