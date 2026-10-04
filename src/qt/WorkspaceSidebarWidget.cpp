#include "WorkspaceSidebarWidget.h"
#include "SessionEditDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QFont>
#include <QColor>

WorkspaceSidebarWidget::WorkspaceSidebarWidget(QWidget *parent)
    : QWidget(parent) {

    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    // 1. Albero dei sistemi
    m_tree = new QTreeWidget(this);
    m_tree->setHeaderHidden(true);
    m_tree->setIndentation(12);
    m_tree->setStyleSheet(
        "QTreeWidget { background-color: #1e1e1e; color: #dcdcdc; border: none; }"
        "QTreeWidget::item { height: 24px; }"
        "QTreeWidget::item:selected { background-color: #264f78; color: #ffffff; }"
    );

    layout->addWidget(m_tree);

    // 2. Bottom Bar ben visibile con alto contrasto
    QWidget *bottomBar = new QWidget(this);
    bottomBar->setFixedHeight(30);
    bottomBar->setStyleSheet("background-color: #2d2d2d; border-top: 1px solid #444444;");

    QHBoxLayout *btnLayout = new QHBoxLayout(bottomBar);
    btnLayout->setContentsMargins(6, 3, 6, 3);
    btnLayout->setSpacing(6);

    QPushButton *addBtn = new QPushButton("+", bottomBar);
    QPushButton *remBtn = new QPushButton("-", bottomBar);
    QPushButton *editBtn = new QPushButton("Edit", bottomBar);

    QString btnStyle = 
        "QPushButton { background-color: #3c3c3c; color: #ffffff; border: 1px solid #555555; border-radius: 3px; font-weight: bold; font-size: 11px; }"
        "QPushButton:hover { background-color: #007acc; border-color: #0099ff; }";

    addBtn->setStyleSheet(btnStyle);
    remBtn->setStyleSheet(btnStyle);
    editBtn->setStyleSheet(btnStyle);

    addBtn->setFixedSize(24, 22);
    remBtn->setFixedSize(24, 22);
    editBtn->setFixedHeight(22);

    addBtn->setToolTip("Add Session");
    remBtn->setToolTip("Remove Selected");
    editBtn->setToolTip("Edit Selected Session");

    btnLayout->addWidget(addBtn);
    btnLayout->addWidget(remBtn);
    btnLayout->addWidget(editBtn);
    btnLayout->addStretch();

    layout->addWidget(bottomBar);

    connect(m_tree, &QTreeWidget::itemDoubleClicked, this, &WorkspaceSidebarWidget::onItemDoubleClicked);
    connect(addBtn, &QPushButton::clicked, this, &WorkspaceSidebarWidget::onAddClicked);
    connect(remBtn, &QPushButton::clicked, this, &WorkspaceSidebarWidget::onRemoveClicked);
    connect(editBtn, &QPushButton::clicked, this, &WorkspaceSidebarWidget::onEditClicked);
}

void WorkspaceSidebarWidget::setWorkspace(DXWorkspace *ws) {
    m_workspace = ws;
    reloadSidebar();
}

void WorkspaceSidebarWidget::reloadSidebar() {
    m_tree->clear();
    if (!m_workspace) return;

    for (int gIdx = 0; gIdx < m_workspace->groups.size(); ++gIdx) {
        const auto &group = m_workspace->groups[gIdx];

        QTreeWidgetItem *groupItem = new QTreeWidgetItem(m_tree);
        groupItem->setText(0, group.name.toUpper());
        groupItem->setFlags(groupItem->flags() & ~Qt::ItemIsSelectable);
        
        groupItem->setData(0, Qt::UserRole, gIdx);
        groupItem->setData(0, Qt::UserRole + 1, -1);

        QFont font = groupItem->font(0);
        font.setBold(true);
        font.setPointSize(10);
        groupItem->setFont(0, font);
        groupItem->setForeground(0, QColor("#888888"));

        for (int sIdx = 0; sIdx < group.sessions.size(); ++sIdx) {
            const auto &session = group.sessions[sIdx];

            QTreeWidgetItem *sessItem = new QTreeWidgetItem(groupItem);
            sessItem->setText(0, session.name.isEmpty() ? session.host : session.name);
            
            sessItem->setData(0, Qt::UserRole, gIdx);
            sessItem->setData(0, Qt::UserRole + 1, sIdx);
        }
    }
    m_tree->expandAll();
}

void WorkspaceSidebarWidget::onItemDoubleClicked(QTreeWidgetItem *item, int) {
    if (!item || !m_workspace) return;

    int gIdx = item->data(0, Qt::UserRole).toInt();
    int sIdx = item->data(0, Qt::UserRole + 1).toInt();

    if (sIdx < 0 || gIdx < 0 || gIdx >= m_workspace->groups.size()) return;
    if (sIdx >= m_workspace->groups[gIdx].sessions.size()) return;

    const DXSessionConfig &cfg = m_workspace->groups[gIdx].sessions[sIdx];
    emit sessionDoubleClicked(cfg);
}

void WorkspaceSidebarWidget::onAddClicked() {
    if (!m_workspace) return;

    SessionEditDialog dlg(nullptr, this);
    if (dlg.exec() == QDialog::Accepted) {
        DXSessionConfig newConfig = dlg.getSessionConfig();

        if (m_workspace->groups.isEmpty()) {
            DXWorkspaceGroup defaultGroup;
            defaultGroup.name = "MAIN SYSTEMS";
            m_workspace->groups.append(defaultGroup);
        }

        int targetGroup = 0;
        QTreeWidgetItem *current = m_tree->currentItem();
        if (current) {
            targetGroup = current->data(0, Qt::UserRole).toInt();
            if (targetGroup < 0 || targetGroup >= m_workspace->groups.size()) {
                targetGroup = 0;
            }
        }

        m_workspace->groups[targetGroup].sessions.append(newConfig);
        WorkspaceManager::instance().saveWorkspaces();
        reloadSidebar();
    }
}

void WorkspaceSidebarWidget::onEditClicked() {
    QTreeWidgetItem *item = m_tree->currentItem();
    if (!item || !m_workspace) return;

    int gIdx = item->data(0, Qt::UserRole).toInt();
    int sIdx = item->data(0, Qt::UserRole + 1).toInt();

    if (gIdx < 0 || sIdx < 0 || gIdx >= m_workspace->groups.size()) return;
    if (sIdx >= m_workspace->groups[gIdx].sessions.size()) return;

    DXSessionConfig &targetConfig = m_workspace->groups[gIdx].sessions[sIdx];

    SessionEditDialog dlg(&targetConfig, this);
    if (dlg.exec() == QDialog::Accepted) {
        targetConfig = dlg.getSessionConfig();
        WorkspaceManager::instance().saveWorkspaces();
        reloadSidebar();
    }
}

void WorkspaceSidebarWidget::onRemoveClicked() {
    QTreeWidgetItem *item = m_tree->currentItem();
    if (!item || !m_workspace) return;

    int gIdx = item->data(0, Qt::UserRole).toInt();
    int sIdx = item->data(0, Qt::UserRole + 1).toInt();

    if (gIdx < 0 || gIdx >= m_workspace->groups.size()) return;

    if (sIdx >= 0) {
        if (sIdx < m_workspace->groups[gIdx].sessions.size()) {
            m_workspace->groups[gIdx].sessions.removeAt(sIdx);
        }
    } else {
        m_workspace->groups.removeAt(gIdx);
    }

    WorkspaceManager::instance().saveWorkspaces();
    reloadSidebar();
}