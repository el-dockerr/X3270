#include "TerminalPaneWidget.h"
#include "OOBPopoverWidget.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QMetaObject>
#include <QMouseEvent>
#include <QProcess>

TerminalPaneWidget::TerminalPaneWidget(const ConnectionSettings &settings, QWidget *parent)
    : QWidget(parent), m_settings(settings) {

    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    setupHeader();

    m_screen = std::make_shared<x3270::ScreenBuffer>(settings.model);
    m_codec = std::make_shared<x3270::EbcdicCodec>(settings.codePage);
    m_session = std::make_shared<x3270::TN3270Session>();
    m_session->setModel(settings.model);
    m_parser = std::make_shared<x3270::DataStreamParser>(*m_screen, *m_codec);
    m_kbd = std::make_shared<x3270::KeyboardState>(*m_screen, *m_codec);

    m_terminal = new TerminalWidget(this);
    m_terminal->setScreenBuffer(m_screen.get(), m_codec.get(), m_kbd.get());

    m_commandDock = new CommandDockWidget(m_settings.customFastPaths,this);

    layout->addWidget(m_headerView);
    layout->addWidget(m_terminal, 1);
    layout->addWidget(m_commandDock);

    // Esecuzione comandi ISPF + Broadcast
    connect(m_commandDock, &CommandDockWidget::ispfCommandRequested, this, [this](const QString &cmd, const QString &group) {
        m_terminal->executeISPFCommand(cmd);
        if (!group.isEmpty()) {
            emit broadcastIspfCommandRequested(cmd, group, this);
        }
    });

    // Esecuzione comandi SSH OOB + Broadcast
    connect(m_commandDock, &CommandDockWidget::oobCommandRequested, this, [this](const QString &cmd, const QString &group) {
        executeOobCommand(cmd);
        if (!group.isEmpty()) {
            emit broadcastOobCommandRequested(cmd, group, this);
        }
    });

    // Ruler e Time-Machine
    connect(m_commandDock, &CommandDockWidget::toggleRulerRequested, m_terminal, &TerminalWidget::setRulerVisible);
    connect(m_commandDock, &CommandDockWidget::toggleTimeMachineRequested, m_terminal, &TerminalWidget::toggleTimeMachine);

    startSession();
    setActive(true);
}

TerminalPaneWidget::~TerminalPaneWidget() {
    m_isClosing = true;
    if (m_session) m_session->disconnect();
    if (m_networkThread.joinable()) m_networkThread.join();
}

void TerminalPaneWidget::executeOobCommand(const QString &cmd) {
    QString host = m_settings.host;
    QProcess *proc = new QProcess(this);
    QString sshCmd = QString("ssh %1 \"%2\"").arg(host, cmd);

    connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this, [this, proc, cmd, host]() {
        QString output = proc->readAllStandardOutput();
        if (output.isEmpty()) output = proc->readAllStandardError();
        if (output.isEmpty()) output = "(Command executed successfully with no output)";

        OOBPopoverWidget dlg(QString("OOB Result [%1]: %2").arg(host, cmd), output, this);
        dlg.exec();
        proc->deleteLater();
    });

    proc->start("bash", QStringList() << "-c" << sshCmd);
}

void TerminalPaneWidget::setupHeader() {
    m_headerView = new QWidget(this);
    m_headerView->setFixedHeight(24);

    QHBoxLayout *headerLayout = new QHBoxLayout(m_headerView);
    headerLayout->setContentsMargins(8, 0, 4, 0);
    headerLayout->setSpacing(4);

    m_titleLabel = new QLabel(m_settings.host, m_headerView);
    QFont font = m_titleLabel->font();
    font.setPointSize(10);
    font.setBold(true);
    m_titleLabel->setFont(font);

    QToolButton *splitRightBtn = new QToolButton(m_headerView);
    splitRightBtn->setText("[|]");
    splitRightBtn->setToolTip("Split Right");

    QToolButton *splitDownBtn = new QToolButton(m_headerView);
    splitDownBtn->setText("[-]");
    splitDownBtn->setToolTip("Split Down");

    QToolButton *closeBtn = new QToolButton(m_headerView);
    closeBtn->setText("X");
    closeBtn->setToolTip("Close Pane");

    headerLayout->addWidget(m_titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(splitRightBtn);
    headerLayout->addWidget(splitDownBtn);
    headerLayout->addWidget(closeBtn);

    connect(splitRightBtn, &QToolButton::clicked, this, [this](bool) { emit splitRequested(this, Qt::Horizontal); });
    connect(splitDownBtn, &QToolButton::clicked, this, [this](bool) { emit splitRequested(this, Qt::Vertical); });
    connect(closeBtn, &QToolButton::clicked, this, [this](bool) { emit closeRequested(this); });
}

void TerminalPaneWidget::setActive(bool active) {
    m_isActive = active;
    if (!m_headerView) return;
    if (m_isActive) {
        m_headerView->setStyleSheet("background-color: #1a4d80; color: #ffffff;");
    } else {
        m_headerView->setStyleSheet("background-color: #2d2d2d; color: #888888;");
    }
}

void TerminalPaneWidget::mousePressEvent(QMouseEvent *event) {
    emit paneFocused(this);
    QWidget::mousePressEvent(event);
}

void TerminalPaneWidget::startSession() {
    m_parser->setUnlockCallback([this]() {
        QMetaObject::invokeMethod(this, [this]() { m_kbd->unlock(); m_terminal->update(); });
    });
    m_parser->setSendCallback([this](const std::vector<uint8_t> &d) { m_session->sendRecord(d); });
    m_kbd->setSendCallback([this](const std::vector<uint8_t> &r) -> bool { return m_session->sendRecord(r); });

    m_session->setDataCallback([this](const std::vector<uint8_t> &rec) {
        std::vector<uint8_t> recCopy = rec;
        QMetaObject::invokeMethod(this, [this, recCopy]() {
            if (m_isClosing) return;
            const std::vector<uint8_t> *payload = &recCopy;
            std::vector<uint8_t> stripped;
            if (m_session->tn3270eActive() && recCopy.size() >= 5 && recCopy[0] == 0x00) {
                stripped.assign(recCopy.begin() + 5, recCopy.end());
                payload = &stripped;
            }
            m_parser->processRecord(*payload);
            m_terminal->captureCurrentScreenSnapshot();
            m_terminal->update();
        });
    });

    std::string host = m_settings.host.toStdString();
    uint16_t port = m_settings.port;
    bool ssl = m_settings.useSSL;
    bool verify = m_settings.verifyCert;

    m_networkThread = std::thread([this, host, port, ssl, verify]() {
        if (m_session->connect(host, port, ssl, verify, "")) {
            m_session->readLoop();
        }
    });
}

void TerminalPaneWidget::reconnectSession() {
    if (m_isClosing) return;

    // 1. Forza la disconnessione della socket corrente
    if (m_session) {
        m_session->disconnect();
    }

    // 2. Attende che il thread di rete muoia in modo pulito
    if (m_networkThread.joinable()) {
        m_networkThread.join();
    }

    // 3. Pulisce lo schermo per rimuovere i vecchi dati
    if (m_screen) {
        m_screen->eraseAll();
    }
    m_terminal->update();

    // 4. Rilancia il thread e il loop di rete!
    startSession();
}