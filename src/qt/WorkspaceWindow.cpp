
#include <QVBoxLayout>
#include <QMenuBar>
#include <QMenu>
#include <QApplication>
#include <QMessageBox>
#include <QFileDialog>

#include "WorkspaceWindow.h"
#include "PreferencesDialog.h"
#include "ShortcutsDialog.h"
#include "ConnectionDialog.h"

WorkspaceWindow::WorkspaceWindow(QWidget *parent)
    : QMainWindow(parent) {

    setWindowTitle("DX3270 Workspace");
    resize(1200, 800);
    setMinimumSize(800, 500);

    WorkspaceManager::instance().loadWorkspaces();
    setupUi();
    setupMenuBar();

    if (!WorkspaceManager::instance().workspaces().isEmpty()) {
        m_sidebar->setWorkspace(&WorkspaceManager::instance().workspaces().first());
    }
}

void WorkspaceWindow::setupUi() {
    m_mainSplitter = new QSplitter(Qt::Horizontal, this);
    m_mainSplitter->setHandleWidth(2);
    m_mainSplitter->setStyleSheet("QSplitter::handle { background-color: #333333; }");
    m_mainSplitter->setChildrenCollapsible(false);

    m_sidebar = new WorkspaceSidebarWidget(m_mainSplitter);
    m_sidebar->setMinimumWidth(220);
    m_sidebar->setMaximumWidth(350);

    m_paneContainer = new QWidget(m_mainSplitter);
    m_paneContainer->setStyleSheet("background-color: #101010;");

    QVBoxLayout *containerLayout = new QVBoxLayout(m_paneContainer);
    containerLayout->setContentsMargins(0, 0, 0, 0);

    m_emptyLabel = new QLabel("Nessuna sessione attiva\nFai doppio clic su un sistema nella barra laterale per connetterti", m_paneContainer);
    m_emptyLabel->setAlignment(Qt::AlignCenter);
    m_emptyLabel->setStyleSheet("color: #666666; font-size: 13px; font-weight: 500;");
    containerLayout->addWidget(m_emptyLabel);

    m_transferDockPlaceholder = new QWidget(m_mainSplitter);
    m_transferDockPlaceholder->setMinimumWidth(250);
    m_transferDockPlaceholder->hide();

    m_mainSplitter->addWidget(m_sidebar);
    m_mainSplitter->addWidget(m_paneContainer);
    m_mainSplitter->addWidget(m_transferDockPlaceholder);

    m_mainSplitter->setStretchFactor(0, 0);
    m_mainSplitter->setStretchFactor(1, 1);
    m_mainSplitter->setStretchFactor(2, 0);

    setCentralWidget(m_mainSplitter);

    connect(m_sidebar, &WorkspaceSidebarWidget::sessionDoubleClicked, this, &WorkspaceWindow::onSessionDoubleClicked);
}

void WorkspaceWindow::onSessionDoubleClicked(const DXSessionConfig &config) {
    ConnectionSettings settings;
    settings.host = config.host;
    settings.port = config.port;
    settings.useSSL = config.useSSL;
    settings.verifyCert = config.verifyCert;
    settings.protocol = config.protocol;
    settings.model = config.model;
    settings.codePage = config.codePage;
    settings.customFastPaths = config.customFastPaths;

    TerminalPaneWidget *newPane = new TerminalPaneWidget(settings, this);
    m_allPanes.append(newPane);

    connect(newPane, &TerminalPaneWidget::paneFocused, this, &WorkspaceWindow::onPaneFocused);
    connect(newPane, &TerminalPaneWidget::splitRequested, this, &WorkspaceWindow::onSplitRequested);
    connect(newPane, &TerminalPaneWidget::closeRequested, this, &WorkspaceWindow::onCloseRequested);

    // Connessione per il broadcast a gruppi
    connect(newPane, &TerminalPaneWidget::broadcastIspfCommandRequested, this, &WorkspaceWindow::onBroadcastIspfRequested);
    connect(newPane, &TerminalPaneWidget::broadcastOobCommandRequested, this, &WorkspaceWindow::onBroadcastOobRequested);

    if (m_allPanes.count() == 1) {
        setRootWidget(newPane);
    } else if (m_activePane) {
        replaceWidget(m_activePane, newPane);
        m_allPanes.removeOne(m_activePane);
        m_activePane->setParent(nullptr);
        m_activePane->deleteLater();
    }

    setActivePane(newPane);
}

void WorkspaceWindow::onBroadcastIspfRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender) {
    for (auto *pane : m_allPanes) {
        if (pane != sender && pane->commandDock() && pane->commandDock()->linkGroup() == group) {
            pane->terminalWidget()->executeISPFCommand(cmd);
        }
    }
}

void WorkspaceWindow::onBroadcastOobRequested(const QString &cmd, const QString &group, TerminalPaneWidget *sender) {
    for (auto *pane : m_allPanes) {
        if (pane != sender && pane->commandDock() && pane->commandDock()->linkGroup() == group) {
            pane->executeOobCommand(cmd);
        }
    }
}

void WorkspaceWindow::onPaneFocused(TerminalPaneWidget *pane) {
    setActivePane(pane);
}

void WorkspaceWindow::onSplitRequested(TerminalPaneWidget *pane, Qt::Orientation orientation) {
    if (!pane) return;

    ConnectionSettings settings = pane->settings();

    TerminalPaneWidget *newPane = new TerminalPaneWidget(settings, this);
    m_allPanes.append(newPane);

    connect(newPane, &TerminalPaneWidget::paneFocused, this, &WorkspaceWindow::onPaneFocused);
    connect(newPane, &TerminalPaneWidget::splitRequested, this, &WorkspaceWindow::onSplitRequested);
    connect(newPane, &TerminalPaneWidget::closeRequested, this, &WorkspaceWindow::onCloseRequested);

    connect(newPane, &TerminalPaneWidget::broadcastIspfCommandRequested, this, &WorkspaceWindow::onBroadcastIspfRequested);
    connect(newPane, &TerminalPaneWidget::broadcastOobCommandRequested, this, &WorkspaceWindow::onBroadcastOobRequested);

    QSplitter *split = new QSplitter(orientation, this);
    split->setHandleWidth(2);
    split->setStyleSheet("QSplitter::handle { background-color: #007acc; }");
    split->setChildrenCollapsible(false);

    replaceWidget(pane, split);

    split->addWidget(pane);
    split->addWidget(newPane);

    QList<int> sizes;
    sizes << 500 << 500;
    split->setSizes(sizes);

    setActivePane(newPane);
}

void WorkspaceWindow::onCloseRequested(TerminalPaneWidget *pane) {
    if (!pane) return;

    m_allPanes.removeOne(pane);

    QSplitter *parentSplitter = qobject_cast<QSplitter*>(pane->parentWidget());

    pane->setParent(nullptr);
    pane->deleteLater();

    if (parentSplitter) {
        if (parentSplitter->count() == 1) {
            QWidget *remainingChild = parentSplitter->widget(0);
            replaceWidget(parentSplitter, remainingChild);
            parentSplitter->deleteLater();
        } else if (parentSplitter->count() == 0) {
            parentSplitter->deleteLater();
        }
    }

    if (m_activePane == pane) {
        m_activePane = nullptr;
        if (!m_allPanes.isEmpty()) {
            setActivePane(m_allPanes.last());
        }
    }

    checkEmptyState();
}

void WorkspaceWindow::setActivePane(TerminalPaneWidget *pane) {
    for (auto *p : m_allPanes) {
        p->setActive(p == pane);
    }
    m_activePane = pane;

    if (m_activePane) {
        setWindowTitle(QString("DX3270 Workspace - %1").arg(m_activePane->settings().host));
    } else {
        setWindowTitle("DX3270 Workspace");
    }
}

void WorkspaceWindow::setRootWidget(QWidget *widget) {
    QVBoxLayout *layout = qobject_cast<QVBoxLayout*>(m_paneContainer->layout());
    if (!layout) return;

    m_emptyLabel->hide();
    layout->addWidget(widget);
}

void WorkspaceWindow::replaceWidget(QWidget *oldWidget, QWidget *newWidget) {
    QWidget *parent = oldWidget->parentWidget();
    QSplitter *splitter = qobject_cast<QSplitter*>(parent);

    if (splitter) {
        int index = splitter->indexOf(oldWidget);
        splitter->insertWidget(index, newWidget);
    } else if (parent == m_paneContainer) {
        QVBoxLayout *layout = qobject_cast<QVBoxLayout*>(m_paneContainer->layout());
        if (layout) {
            layout->removeWidget(oldWidget);
            layout->addWidget(newWidget);
        }
    }
}

void WorkspaceWindow::checkEmptyState() {
    if (m_allPanes.isEmpty()) {
        m_emptyLabel->show();
        setWindowTitle("DX3270 Workspace");
    }
}

void WorkspaceWindow::setupMenuBar() {
    // Creare il QMenuBar con 'nullptr' dice a Qt di usarlo come barra 
    // di sistema globale su macOS (mentre su Windows/Linux rimarrà nella finestra).
    QMenuBar *globalMenuBar = new QMenuBar(nullptr);
    setMenuBar(globalMenuBar);

    // --- File Menu ---
    QMenu *fileMenu = globalMenuBar->addMenu("&File");
    
    QAction *newConnAct = fileMenu->addAction("New Connection...");
    newConnAct->setShortcut(QKeySequence("Ctrl+N"));
    connect(newConnAct, &QAction::triggered, this, &WorkspaceWindow::onOpenConnectionDialog);
    
    fileMenu->addSeparator();

    QAction *prefAct = fileMenu->addAction("Preferences...");
    prefAct->setShortcut(QKeySequence("Ctrl+,"));
    connect(prefAct, &QAction::triggered, this, &WorkspaceWindow::onOpenPreferences);
    
    fileMenu->addSeparator();
    
    QAction *closeTabAct = fileMenu->addAction("Close Tab");
    closeTabAct->setShortcut(QKeySequence("Ctrl+W"));
    connect(closeTabAct, &QAction::triggered, this, [this]() {
        if (m_activePane) onCloseRequested(m_activePane);
    });

    fileMenu->addSeparator();

    QAction *reconnectAct = fileMenu->addAction("Reconnect Session");
    reconnectAct->setShortcut(QKeySequence("Ctrl+R"));
    connect(reconnectAct, &QAction::triggered, this, [this]() {
        if (m_activePane) m_activePane->reconnectSession();
    });

    fileMenu->addSeparator();

    QAction *screenshotAct = fileMenu->addAction("Save Screenshot...");
    screenshotAct->setShortcut(QKeySequence("Ctrl+Shift+P"));
    connect(screenshotAct, &QAction::triggered, this, &WorkspaceWindow::onSaveScreenshot);

    QAction *exportAct = fileMenu->addAction("Export as Text...");
    exportAct->setShortcut(QKeySequence("Ctrl+Shift+T"));
    connect(exportAct, &QAction::triggered, this, &WorkspaceWindow::onExportText);

    fileMenu->addSeparator();

    QAction *quitAct = fileMenu->addAction("Quit DX3270");
    quitAct->setShortcut(QKeySequence("Ctrl+Q"));
    connect(quitAct, &QAction::triggered, qApp, &QApplication::quit);

    // --- View Menu ---
    QMenu *viewMenu = globalMenuBar->addMenu("&View");
    
    QAction *dockAct = viewMenu->addAction("Toggle Command Dock");
    dockAct->setShortcut(QKeySequence("Ctrl+K"));
    connect(dockAct, &QAction::triggered, this, &WorkspaceWindow::onToggleCommandDock);
    
    QAction *sidebarAct = viewMenu->addAction("Toggle Transfer Dock");
    sidebarAct->setShortcut(QKeySequence("Ctrl+Shift+U"));
    connect(sidebarAct, &QAction::triggered, this, [this]() {
        m_transferDockPlaceholder->setVisible(!m_transferDockPlaceholder->isVisible());
    });
    
    QMenu *debugMenu = globalMenuBar->addMenu("&Debug");
    QAction *debugAct = debugMenu->addAction("Traffic Monitor");
    debugAct->setShortcut(QKeySequence("Ctrl+D"));
    connect(debugAct, &QAction::triggered, this, &WorkspaceWindow::onOpenDebugMonitor);

    viewMenu->addSeparator();

    QAction *timeMachineAct = viewMenu->addAction("3270 Time-Machine");
    timeMachineAct->setShortcut(QKeySequence("Ctrl+Alt+T"));
    connect(timeMachineAct, &QAction::triggered, this, &WorkspaceWindow::onToggleTimeMachine);

    // --- Help Menu ---
    QMenu *helpMenu = globalMenuBar->addMenu("&Help");
    
    QAction *shortcutsAct = helpMenu->addAction("Keyboard Shortcuts");
    shortcutsAct->setShortcut(QKeySequence("Ctrl+/"));
    connect(shortcutsAct, &QAction::triggered, this, &WorkspaceWindow::onOpenShortcuts);
    
    QAction *aboutAct = helpMenu->addAction("About DX3270");
    connect(aboutAct, &QAction::triggered, this, [this]() {
        QMessageBox::about(this, "About DX3270", "<b>DX3270 Terminal Emulator</b><br>v1.7.7<br><br>Written by Swen Skalski");
    });
}

void WorkspaceWindow::onOpenConnectionDialog() {
    ConnectionDialog dlg(this);
    if (dlg.exec() == QDialog::Accepted) {
        ConnectionSettings s = dlg.getSettings();
        TerminalPaneWidget *newPane = new TerminalPaneWidget(s, this);
        m_allPanes.append(newPane);
        
        connect(newPane, &TerminalPaneWidget::paneFocused, this, &WorkspaceWindow::onPaneFocused);
        connect(newPane, &TerminalPaneWidget::splitRequested, this, &WorkspaceWindow::onSplitRequested);
        connect(newPane, &TerminalPaneWidget::closeRequested, this, &WorkspaceWindow::onCloseRequested);
        connect(newPane, &TerminalPaneWidget::broadcastIspfCommandRequested, this, &WorkspaceWindow::onBroadcastIspfRequested);
        connect(newPane, &TerminalPaneWidget::broadcastOobCommandRequested, this, &WorkspaceWindow::onBroadcastOobRequested);

        if (m_allPanes.count() == 1) {
            setRootWidget(newPane);
        } else if (m_activePane) {
            replaceWidget(m_activePane, newPane);
            m_allPanes.removeOne(m_activePane);
            m_activePane->setParent(nullptr);
            m_activePane->deleteLater();
        }
        setActivePane(newPane);
    }
}

void WorkspaceWindow::onOpenPreferences() {
    PreferencesDialog dlg(this);
    if (dlg.exec() == QDialog::Accepted) {
        // Applica le preferenze a tutti i terminali aperti
        for (auto *pane : m_allPanes) {
            pane->terminalWidget()->update();
        }
    }
}

void WorkspaceWindow::onOpenShortcuts() {
    ShortcutsDialog dlg(this);
    dlg.exec();
}

void WorkspaceWindow::onToggleCommandDock() {
    if (m_activePane && m_activePane->commandDock()) {
        m_activePane->commandDock()->setVisible(!m_activePane->commandDock()->isVisible());
    }
}

void WorkspaceWindow::onToggleTimeMachine() {
    if (m_activePane && m_activePane->terminalWidget()) {
        m_activePane->terminalWidget()->toggleTimeMachine();
    }
}

void WorkspaceWindow::onSaveScreenshot() {
    if (!m_activePane || !m_activePane->terminalWidget()) return;
    
    QString fileName = QFileDialog::getSaveFileName(this, "Save Screenshot", "DX3270_screenshot.png", "Images (*.png)");
    if (!fileName.isEmpty()) {
        // Magia di Qt: grab() cattura visivamente l'intero widget del terminale!
        QPixmap pixmap = m_activePane->terminalWidget()->grab();
        pixmap.save(fileName, "PNG");
    }
}

void WorkspaceWindow::onExportText() {
    if (!m_activePane || !m_activePane->terminalWidget()) return;
    
    // Su Cocoa avevamo la logica che iterava sullo ScreenBuffer.
    // Lo predisponiamo e avvisiamo l'utente (o implementi la lettura del buffer text).
    QMessageBox::information(this, "Export", "Export text functionality is under migration.");
}

void WorkspaceWindow::onOpenDebugMonitor() {
    // Come da nostro file todo.md, il "DebugWindowWidget" è uno dei prossimi moduli da creare.
    QMessageBox::information(this, "Traffic Monitor", "The Traffic Monitor module will be implemented in the next step (See todo.md).");
}