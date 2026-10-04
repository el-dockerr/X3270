#include "MainWindow.h"
#include "TerminalWidget.h"
#include "../core/TerminalModel.h"
#include <QMetaObject>

MainWindow::MainWindow(const ConnectionSettings& settings, QWidget *parent) 
    : QMainWindow(parent) {
    
    // Imposta il titolo iniziale
    setWindowTitle(QString("DX3270 Qt - %1:%2").arg(settings.host).arg(settings.port));

    // 1. Inizializzazione Core Components usando le impostazioni scelte dall'utente
    m_screen = std::make_shared<x3270::ScreenBuffer>(settings.model);
    m_codec = std::make_shared<x3270::EbcdicCodec>(settings.codePage);
    
    // Nota: al momento istanziamo TN3270Session di default per il PoC.
    // In futuro qui metteremo un if (settings.protocol == 1) per istanziare TN5250Session.
    m_session = std::make_shared<x3270::TN3270Session>();
    m_session->setModel(settings.model);
    
    m_parser = std::make_shared<x3270::DataStreamParser>(*m_screen, *m_codec);
    m_kbd = std::make_shared<x3270::KeyboardState>(*m_screen, *m_codec);

    // 2. Setup Interfaccia Grafica
    terminal = new TerminalWidget(this);
    terminal->setScreenBuffer(m_screen.get(), m_codec.get(), m_kbd.get());
    
    setCentralWidget(terminal);
    
    // Calcolo dimensioni e protezione contro il collasso della finestra
    terminal->adjustSize();
    resize(terminal->sizeHint());
    setMinimumSize(600, 400); // Impedisce fisicamente a macOS di schiacciare la finestra a 0x0

    // 3. Routing dei Callback C++ (Network Thread -> UI Thread via Qt)
    m_parser->setUnlockCallback([this]() {
        QMetaObject::invokeMethod(this, [this]() { 
            m_kbd->unlock(); 
            terminal->update();
        });
    });

    m_parser->setSendCallback([this](const std::vector<uint8_t> &data) {
        m_session->sendRecord(data);
    });

    m_kbd->setSendCallback([this](const std::vector<uint8_t> &record) -> bool {
        return m_session->sendRecord(record);
    });

    m_session->setDataCallback([this](const std::vector<uint8_t> &record) {
        std::vector<uint8_t> recCopy = record;
        
        // Invia l'esecuzione sul Thread UI principale per aggiornare i widget in sicurezza
        QMetaObject::invokeMethod(this, [this, recCopy]() {
            if (m_isClosing) return;
            const std::vector<uint8_t> *payload = &recCopy;
            std::vector<uint8_t> stripped;
            
            // Gestione Header TN3270E (Rimuove i 5 byte iniziali se presenti)
            if (m_session->tn3270eActive() && recCopy.size() >= 5) {
                if (recCopy[0] == 0x00) { // DT_3270_DATA
                    stripped.assign(recCopy.begin() + 5, recCopy.end());
                    payload = &stripped;
                }
            }
            m_parser->processRecord(*payload);
            terminal->update(); // Forza il ridisegno dopo aver elaborato i dati
        });
    });

    m_session->setConnectedCallback([this]() {
        QMetaObject::invokeMethod(this, [this]() {
            if (m_isClosing) return;
            m_kbd->unlock();
            setWindowTitle(QString("DX3270 Qt - Connected to %1").arg(windowTitle().split("-").last().trimmed()));
            terminal->update();
        });
    });

    m_session->setErrorCallback([this](const std::string& errorMsg) {
        QString errorStr = QString::fromStdString(errorMsg);
        QMetaObject::invokeMethod(this, [this, errorStr]() {
            if (m_isClosing) return;
            setWindowTitle(QString("DX3270 Qt - Error: %1").arg(errorStr));
        });
    });

    // 4. Lancio del Background Thread per la connessione Telnet
    std::string targetHost = settings.host.toStdString();
    uint16_t targetPort = settings.port;
    bool useSSL = settings.useSSL;
    bool verifyCert = settings.verifyCert;

    m_networkThread = std::thread([this, targetHost, targetPort, useSSL, verifyCert]() {
        // La chiamata connect blocca il thread finché la negoziazione Telnet non è terminata
        if (m_session->connect(targetHost, targetPort, useSSL, verifyCert, "")) {
            // Se la connessione ha successo, avviamo il ciclo di lettura bloccante
            m_session->readLoop();
        }
    });
}

MainWindow::~MainWindow() {
    m_isClosing = true;
    
    // Disconnette la sessione in modo sicuro
    if (m_session) {
        m_session->disconnect();
    }
    
    // Attende la terminazione pulita del thread di rete
    if (m_networkThread.joinable()) {
        m_networkThread.join();
    }
}