#include "PreferencesDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QLabel>
#include <QSettings>

PreferencesDialog::PreferencesDialog(QWidget *parent) : QDialog(parent) {
    setWindowTitle("DX3270 - Preferences");
    setMinimumWidth(420);
    setupUi();

    // Carica le preferenze salvate
    QSettings settings("DX3270", "CrossPlatform");
    m_fontCheck->setChecked(settings.value("use3270Font", false).toBool());
    m_herculesCheck->setChecked(settings.value("herculesBrackets", false).toBool());
    m_rulerCheck->setChecked(settings.value("crosshairRuler", false).toBool());
    m_timeMachineCheck->setChecked(settings.value("DX3270_EnableTimeMachine", true).toBool());
}

void PreferencesDialog::setupUi() {
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setSpacing(12);

    QLabel *fontHeader = new QLabel("<b>Terminal Font</b>", this);
    m_fontCheck = new QCheckBox("Use IBM 3270 font (by Ricardo Bánffy)", this);
    QLabel *fontNote = new QLabel("Replaces the default font with the authentic IBM 3270 monospace font.\n(Requires app restart)", this);
    fontNote->setStyleSheet("color: #888888; font-size: 11px;");

    QLabel *compatHeader = new QLabel("<b>Compatibility & Features</b>", this);
    m_herculesCheck = new QCheckBox("Display Hercules-style EBCDIC brackets as [ ]", this);
    m_rulerCheck = new QCheckBox("Show Crosshair Ruler (Cursor Guide) by default", this);
    m_timeMachineCheck = new QCheckBox("Record screen history (Time-Machine & Diff)", this);

    layout->addWidget(fontHeader);
    layout->addWidget(m_fontCheck);
    layout->addWidget(fontNote);
    layout->addSpacing(10);
    layout->addWidget(compatHeader);
    layout->addWidget(m_herculesCheck);
    layout->addWidget(m_rulerCheck);
    layout->addWidget(m_timeMachineCheck);
    layout->addStretch();

    QHBoxLayout *btnLayout = new QHBoxLayout();
    QPushButton *cancelBtn = new QPushButton("Cancel", this);
    QPushButton *saveBtn = new QPushButton("Save", this);
    saveBtn->setDefault(true);
    
    btnLayout->addStretch();
    btnLayout->addWidget(cancelBtn);
    btnLayout->addWidget(saveBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(saveBtn, &QPushButton::clicked, this, &PreferencesDialog::onSave);
}

void PreferencesDialog::onSave() {
    QSettings settings("DX3270", "CrossPlatform");
    settings.setValue("use3270Font", m_fontCheck->isChecked());
    settings.setValue("herculesBrackets", m_herculesCheck->isChecked());
    settings.setValue("crosshairRuler", m_rulerCheck->isChecked());
    settings.setValue("DX3270_EnableTimeMachine", m_timeMachineCheck->isChecked());
    accept();
}