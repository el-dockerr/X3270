#pragma once

#include <QWidget>
#include <QLabel>
#include <QToolButton>
#include <thread>
#include <memory>
#include <atomic>

#include "CommandDockWidget.h"
#include "TerminalWidget.h"
#include "ConnectionDialog.h"

#include "../core/TN3270Session.h"
#include "../core/DataStreamParser.h"
#include "../core/ScreenBuffer.h"
#include "../core/EbcdicCodec.h"
#include "../core/KeyboardState.h"

class TerminalPaneWidget : public QWidget {
    Q_OBJECT

public:
    explicit TerminalPaneWidget(const ConnectionSettings &settings, QWidget *parent = nullptr);
    ~TerminalPaneWidget() override;

    void setActive(bool active);
    bool isActive() const { return m_isActive; }

    TerminalWidget* terminalWidget() { return m_terminal; }
    CommandDockWidget* commandDock() { return m_commandDock; }
    const ConnectionSettings& settings() const { return m_settings; }

    void executeOobCommand(const QString &cmd);
    void reconnectSession();

signals:
    void paneFocused(TerminalPaneWidget *pane);
    void splitRequested(TerminalPaneWidget *pane, Qt::Orientation orientation);
    void closeRequested(TerminalPaneWidget *pane);

    // Segnali per il broadcast a gruppi di terminali
    void broadcastIspfCommandRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender);
    void broadcastOobCommandRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender);

protected:
    void mousePressEvent(QMouseEvent *event) override;

private:
    void setupHeader();
    void startSession();

    ConnectionSettings m_settings;
    QWidget *m_headerView{nullptr};
    QLabel *m_titleLabel{nullptr};
    TerminalWidget *m_terminal{nullptr};
    CommandDockWidget *m_commandDock{nullptr};

    std::shared_ptr<x3270::ScreenBuffer> m_screen;
    std::shared_ptr<x3270::EbcdicCodec> m_codec;
    std::shared_ptr<x3270::TN3270Session> m_session;
    std::shared_ptr<x3270::DataStreamParser> m_parser;
    std::shared_ptr<x3270::KeyboardState> m_kbd;

    std::thread m_networkThread;
    std::atomic<bool> m_isClosing{false};
    bool m_isActive{false};
};