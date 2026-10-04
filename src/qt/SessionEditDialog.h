#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QTableWidget>
#include <QList>
#include "WorkspaceManager.h"

class SessionEditDialog : public QDialog {
    Q_OBJECT

public:
    explicit SessionEditDialog(const DXSessionConfig *config = nullptr, QWidget *parent = nullptr);
    DXSessionConfig getSessionConfig() const;

private slots:
    void onSslToggled(bool checked);
    void onProtocolChanged(int index);

    void onAddFastPath();
    void onRemoveFastPath();
    void onMoveFastPathUp();
    void onMoveFastPathDown();

private:
    void setupUi();

    QLineEdit *m_nameField;
    QLineEdit *m_hostField;
    QLineEdit *m_portField;
    QCheckBox *m_sslCheck;
    QCheckBox *m_verifyCertCheck;
    QLineEdit *m_caField;
    QComboBox *m_protocolCombo;
    QComboBox *m_modelCombo;
    QComboBox *m_codePageCombo;

    bool m_isNew{true};
    QTableWidget *m_fastPathsTable;
    QList<DXFastPath> defaultFastPaths() const;
};