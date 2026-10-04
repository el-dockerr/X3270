#pragma once
#include <QMainWindow>
#include <memory>
#include <thread>
#include <atomic>
#include "ConnectionDialog.h" // <--- FONDAMENTALE: importa ConnectionSettings
#include "../core/TN3270Session.h"
#include "../core/ScreenBuffer.h"
#include "../core/EbcdicCodec.h"
#include "../core/DataStreamParser.h"
#include "../core/KeyboardState.h"

class TerminalWidget;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    // Il nuovo costruttore che riceve le impostazioni dalla finestra di dialogo
    explicit MainWindow(const ConnectionSettings& settings, QWidget *parent = nullptr);
    ~MainWindow() override;

private:
    TerminalWidget *terminal;
    
    // Core Engine Pointers
    std::shared_ptr<x3270::ScreenBuffer> m_screen;
    std::shared_ptr<x3270::EbcdicCodec> m_codec;
    std::shared_ptr<x3270::TN3270Session> m_session;
    std::shared_ptr<x3270::DataStreamParser> m_parser;
    std::shared_ptr<x3270::KeyboardState> m_kbd;

    // Networking
    std::thread m_networkThread;
    std::atomic<bool> m_isClosing {false};
};