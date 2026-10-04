#pragma once

#include <QWidget>
#include <QComboBox>
#include <QLineEdit>
#include <QPushButton>
#include <QHBoxLayout>

#include "WorkspaceManager.h"

class CommandDockWidget : public QWidget {
    Q_OBJECT

public:
    explicit CommandDockWidget(const QList<DXFastPath> &fastPaths = {},QWidget *parent = nullptr);

    void setLinkGroup(const QString &group) { m_linkGroup = group; }
    QString linkGroup() const { return m_linkGroup; }

signals:
    void ispfCommandRequested(const QString &cmd, const QString &group);
    void oobCommandRequested(const QString &cmd, const QString &group);
    void toggleRulerRequested(bool enabled); // Trasmette lo stato attivo/inattivo
    void toggleTimeMachineRequested();

private slots:
    void onIspfButtonClicked();
    void onIspfReturnPressed();
    void onOobReturnPressed();

private:
    void setupUi();
    void loadFastPaths();

    QComboBox *m_linkGroupCombo;
    QHBoxLayout *m_fastPathsLayout;
    QLineEdit *m_ispfField;
    QLineEdit *m_oobField;
    QPushButton *m_rulerBtn;
    QPushButton *m_timeMachineBtn;
    QString m_linkGroup;
    QList<DXFastPath> m_fastPaths;
};