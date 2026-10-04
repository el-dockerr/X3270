#pragma once

#include <QMainWindow>
#include <QSplitter>
#include <QLabel>
#include <QList>

#include "WorkspaceSidebarWidget.h"
#include "TerminalPaneWidget.h"
#include "WorkspaceManager.h"

class WorkspaceWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit WorkspaceWindow(QWidget *parent = nullptr);
    ~WorkspaceWindow() override = default;

private slots:
    void onSessionDoubleClicked(const DXSessionConfig &config);
    void onPaneFocused(TerminalPaneWidget *pane);
    void onSplitRequested(TerminalPaneWidget *pane, Qt::Orientation orientation);
    void onCloseRequested(TerminalPaneWidget *pane);

    // Slot per il broadcast a gruppi
    void onBroadcastIspfRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender);
    void onBroadcastOobRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender);

    // Application menu actions
    void onOpenPreferences();
    void onOpenShortcuts();
    void onOpenConnectionDialog();
    void onToggleCommandDock();
    void onToggleTimeMachine();
    // Additional actions
    void onSaveScreenshot();
    void onExportText();
    void onOpenDebugMonitor();
private:
    void setupUi();
    void setActivePane(TerminalPaneWidget *pane);
    void setRootWidget(QWidget *widget);
    void replaceWidget(QWidget *oldWidget, QWidget *newWidget);
    void checkEmptyState();
    void setupMenuBar();

    QSplitter *m_mainSplitter{nullptr};
    WorkspaceSidebarWidget *m_sidebar{nullptr};
    QWidget *m_paneContainer{nullptr};
    QWidget *m_transferDockPlaceholder{nullptr};
    QLabel *m_emptyLabel{nullptr};

    QList<TerminalPaneWidget*> m_allPanes;
    TerminalPaneWidget *m_activePane{nullptr};
};