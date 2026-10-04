#pragma once

#include <QDialog>
#include <QComboBox>
#include <QLineEdit>
#include <QCheckBox>
#include <QPushButton>
#include <QString>
#include "../core/TerminalModel.h"
#include "../core/EbcdicCodec.h"
#include "WorkspaceManager.h"

// Struttura che ricalca i parametri necessari per il tuo core
struct ConnectionSettings {
    QString host;
    uint16_t port;
    bool useSSL;
    bool verifyCert;
    int protocol; // 0 = TN3270, 1 = TN5250
    x3270::TerminalModel model;
    x3270::CodePage codePage;
    QList<DXFastPath> customFastPaths;
};

class ConnectionDialog : public QDialog {
    Q_OBJECT

public:
    explicit ConnectionDialog(QWidget *parent = nullptr);
    ConnectionSettings getSettings() const;

private:
    QComboBox *m_hostCombo;
    QLineEdit *m_portField;
    QCheckBox *m_sslCheck;
    QCheckBox *m_verifyCertCheck;
    QComboBox *m_protocolCombo;
    QComboBox *m_modelCombo;
    QComboBox *m_codePageCombo;
    QPushButton *m_connectButton;

    void loadLastConnection();
    void saveLastConnection();
    
private slots:
    void onSslToggled(bool checked);
    void onProtocolChanged(int index);
    void onConnectClicked();
};