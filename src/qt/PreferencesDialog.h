#pragma once
#include <QDialog>
#include <QCheckBox>

class PreferencesDialog : public QDialog {
    Q_OBJECT
public:
    explicit PreferencesDialog(QWidget *parent = nullptr);

private slots:
    void onSave();

private:
    void setupUi();
    
    QCheckBox *m_fontCheck;
    QCheckBox *m_herculesCheck;
    QCheckBox *m_rulerCheck;
    QCheckBox *m_timeMachineCheck;
};