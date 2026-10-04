#pragma once

#include <QWidget>
#include <QTreeWidget>
#include <QPushButton>
#include "WorkspaceManager.h"

class WorkspaceSidebarWidget : public QWidget {
    Q_OBJECT

public:
    explicit WorkspaceSidebarWidget(QWidget *parent = nullptr);
    void setWorkspace(DXWorkspace *ws);
    void reloadSidebar();

signals:
    void sessionDoubleClicked(const DXSessionConfig &config);

private slots:
    void onItemDoubleClicked(QTreeWidgetItem *item, int column);
    void onAddClicked();
    void onEditClicked();
    void onRemoveClicked();

private:
    QTreeWidget *m_tree;
    DXWorkspace *m_workspace{nullptr};
};