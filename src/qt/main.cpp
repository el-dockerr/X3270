#include <QApplication>
#include "WorkspaceWindow.h"

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    
    // Ricrea il comportamento di AppDelegate.mm: avvia direttamente il Workspace principale
    WorkspaceWindow window;
    window.show();
    
    return app.exec();
}