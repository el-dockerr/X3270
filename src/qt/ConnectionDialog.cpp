#include "ConnectionDialog.h"
#include <QVBoxLayout>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QSettings>

ConnectionDialog::ConnectionDialog(QWidget *parent) : QDialog(parent) {
    setWindowTitle("DX3270 - Connect to Host");
    setMinimumWidth(400);

    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    QFormLayout *formLayout = new QFormLayout();

    // Inizializzazione Campi
    m_protocolCombo = new QComboBox(this);
    m_protocolCombo->addItems({"TN3270 - Mainframe (z/OS)", "TN5250 - Midrange (IBM i / AS400)"});
    
    m_hostCombo = new QComboBox(this);
    m_hostCombo->setEditable(true); // Permette di digitare o scegliere dalla tendina
    m_hostCombo->setPlaceholderText("hostname or IP");

    m_portField = new QLineEdit("23", this);
    m_portField->setMaximumWidth(80);

    m_sslCheck = new QCheckBox("Use SSL/TLS (port 992)", this);
    m_verifyCertCheck = new QCheckBox("Verify SSL Certificate", this);
    m_verifyCertCheck->setChecked(true);
    m_verifyCertCheck->setEnabled(false);

    m_codePageCombo = new QComboBox(this);
    m_codePageCombo->addItems({"CP037 (US/Canada)", "CP500 (International)", "CP1047 (Open Systems)", "CP280 (Italy)"});

    m_modelCombo = new QComboBox(this);
    onProtocolChanged(0); // Popola i modelli in base al protocollo di default

    // Aggiunta al Form Layout (Allinea tutto automaticamente)
    formLayout->addRow("Protocol:", m_protocolCombo);
    formLayout->addRow("Host:", m_hostCombo);
    formLayout->addRow("Port:", m_portField);
    formLayout->addRow("", m_sslCheck);
    formLayout->addRow("", m_verifyCertCheck);
    formLayout->addRow("Code Page:", m_codePageCombo);
    formLayout->addRow("Screen Model:", m_modelCombo);

    mainLayout->addLayout(formLayout);

    // Pulsanti inferiori
    QHBoxLayout *buttonLayout = new QHBoxLayout();
    QPushButton *cancelButton = new QPushButton("Cancel", this);
    m_connectButton = new QPushButton("Connect", this);
    m_connectButton->setDefault(true); // Evidenziato come default (premi Invio per attivarlo)

    buttonLayout->addStretch();
    buttonLayout->addWidget(cancelButton);
    buttonLayout->addWidget(m_connectButton);
    mainLayout->addLayout(buttonLayout);

    // Connessione dei segnali (Events)
    connect(m_sslCheck, &QCheckBox::toggled, this, &ConnectionDialog::onSslToggled);
    connect(m_protocolCombo, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &ConnectionDialog::onProtocolChanged);
    connect(cancelButton, &QPushButton::clicked, this, &QDialog::reject);
    connect(m_connectButton, &QPushButton::clicked, this, &ConnectionDialog::onConnectClicked);

    loadLastConnection();
}

void ConnectionDialog::onSslToggled(bool checked) {
    m_verifyCertCheck->setEnabled(checked);
    if (checked && m_portField->text() == "23") {
        m_portField->setText("992");
    } else if (!checked && m_portField->text() == "992") {
        m_portField->setText("23");
    }
}

void ConnectionDialog::onProtocolChanged(int index) {
    m_modelCombo->clear();
    if (index == 1) { // 5250
        m_modelCombo->addItems({"Standard - 24x80", "Wide - 27x132"});
    } else {          // 3270
        m_modelCombo->addItems({"Model 2 - 24x80 (default)", "Model 3 - 32x80", "Model 4 - 43x80", "Model 5 - 27x132 (wide)", "Large - 62x160"});
    }
}

void ConnectionDialog::onConnectClicked() {
    if (m_hostCombo->currentText().trimmed().isEmpty()) {
        return; // Manca l'host
    }
    saveLastConnection();
    accept(); // Chiude la modale con codice di successo
}

ConnectionSettings ConnectionDialog::getSettings() const {
    ConnectionSettings s;
    s.host = m_hostCombo->currentText().trimmed();
    s.port = m_portField->text().toUShort();
    s.useSSL = m_sslCheck->isChecked();
    s.verifyCert = m_verifyCertCheck->isChecked();
    s.protocol = m_protocolCombo->currentIndex();
    
    // Mappatura CodePage base
    switch (m_codePageCombo->currentIndex()) {
        case 1:  s.codePage = x3270::CodePage::CP500; break;
        case 2:  s.codePage = x3270::CodePage::CP1047; break;
        case 3:  s.codePage = x3270::CodePage::CP280; break;
        default: s.codePage = x3270::CodePage::CP037; break;
    }

    // Mappatura Modelli
    if (s.protocol == 1) { // 5250
        s.model = (m_modelCombo->currentIndex() == 1) ? x3270::TerminalModel::Model5 : x3270::TerminalModel::Model2;
    } else {               // 3270
        switch(m_modelCombo->currentIndex()) {
            case 1:  s.model = x3270::TerminalModel::Model3; break;
            case 2:  s.model = x3270::TerminalModel::Model4; break;
            case 3:  s.model = x3270::TerminalModel::Model5; break;
            case 4:  s.model = x3270::TerminalModel::LargeCustom; break;
            default: s.model = x3270::TerminalModel::Model2; break;
        }
    }
    return s;
}

// Persistenza tramite QSettings
void ConnectionDialog::loadLastConnection() {
    QSettings settings("DX3270", "CrossPlatform");
    m_hostCombo->setCurrentText(settings.value("LastHost", "").toString());
    m_portField->setText(settings.value("LastPort", "23").toString());
    m_sslCheck->setChecked(settings.value("LastSSL", false).toBool());
}

void ConnectionDialog::saveLastConnection() {
    QSettings settings("DX3270", "CrossPlatform");
    settings.setValue("LastHost", m_hostCombo->currentText().trimmed());
    settings.setValue("LastPort", m_portField->text());
    settings.setValue("LastSSL", m_sslCheck->isChecked());
}