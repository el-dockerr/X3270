#include "ShortcutsDialog.h"
#include <QVBoxLayout>
#include <QHeaderView>
#include <QLabel>

ShortcutsDialog::ShortcutsDialog(QWidget *parent) : QDialog(parent) {
    setWindowTitle("Keyboard Shortcuts");
    resize(560, 500);

    QVBoxLayout *layout = new QVBoxLayout(this);
    QLabel *intro = new QLabel("All keyboard shortcuts available in DX3270.\nTerminal keys are only active while a session is connected.", this);
    intro->setStyleSheet("color: #888888;");
    layout->addWidget(intro);

    m_table = new QTableWidget(0, 2, this);
    m_table->horizontalHeader()->hide();
    m_table->verticalHeader()->hide();
    m_table->horizontalHeader()->setStretchLastSection(true);
    m_table->setColumnWidth(0, 180);
    m_table->setSelectionMode(QAbstractItemView::NoSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setStyleSheet("QTableWidget { border: none; background-color: #1e1e1e; }");
    layout->addWidget(m_table);

    addSection("Function Keys");
    addShortcut("F1 - F12", "PF1 - PF12");
    addShortcut("Shift + F1 - F12", "PF13 - PF24");
    addShortcut("Alt + 1, 2, 3", "PA1, PA2, PA3");

    addSection("Session Control");
    addShortcut("Return / Enter", "Enter — send AID to host");
    addShortcut("Escape", "Reset — unlock keyboard after host error");
    addShortcut("Alt + Escape", "Clear — send Clear AID");

    addSection("Navigation & Editing");
    addShortcut("Tab / Shift+Tab", "Move cursor to next/prev input field");
    addShortcut("Insert / Ctrl+I", "Toggle insert mode");
    addShortcut("Alt + Delete", "Erase to End of Field");

    addSection("Power Tools");
    addShortcut("Ctrl + K", "Command Dock — Spotlight launcher");
    addShortcut("Ctrl + Shift + L", "Smart Log Isolator — toggle noise filter");
    addShortcut("Alt + Click", "Data Inspector — decode selected text");
    addShortcut("Ctrl + Alt + T", "Screen Time-Machine");

    addSection("Application");
    addShortcut("Ctrl + N", "New Connection");
    addShortcut("Ctrl + ,", "Preferences");
    addShortcut("Ctrl + Shift + U", "Toggle Transfer Dock");
    addShortcut("Ctrl + /", "Keyboard Shortcuts");
}

void ShortcutsDialog::addSection(const QString &title) {
    int r = m_table->rowCount();
    m_table->insertRow(r);
    QTableWidgetItem *item = new QTableWidgetItem(title.toUpper());
    item->setBackground(QColor("#2d2d2d"));
    item->setForeground(QColor("#aaaaaa"));
    QFont f = item->font(); f.setBold(true); item->setFont(f);
    m_table->setItem(r, 0, item);
    m_table->setSpan(r, 0, 1, 2);
}

void ShortcutsDialog::addShortcut(const QString &keys, const QString &desc) {
    int r = m_table->rowCount();
    m_table->insertRow(r);
    
    QTableWidgetItem *kItem = new QTableWidgetItem(keys);
    kItem->setForeground(QColor("#ffffff"));
    QFont f("Monospace", 10, QFont::Bold); kItem->setFont(f);
    
    QTableWidgetItem *dItem = new QTableWidgetItem(desc);
    dItem->setForeground(QColor("#dcdcdc"));
    
    m_table->setItem(r, 0, kItem);
    m_table->setItem(r, 1, dItem);
}