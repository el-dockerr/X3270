// src/qt/WorkspaceManager.cpp
#include "WorkspaceManager.h"
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QJsonDocument>

QJsonObject DXFastPath::toJson() const {
    QJsonObject obj;
    obj["title"] = title;
    obj["cmd"] = cmd;
    return obj;
}

DXFastPath DXFastPath::fromJson(const QJsonObject &json) {
    DXFastPath fp;
    fp.title = json["title"].toString();
    fp.cmd = json["cmd"].toString();
    return fp;
}

QJsonObject DXSessionConfig::toJson() const {
    QJsonObject obj;
    obj["name"] = name;
    obj["host"] = host;
    obj["port"] = port;
    obj["useSSL"] = useSSL;
    obj["verifyCert"] = verifyCert;
    obj["caBundle"] = caBundle;
    obj["protocol"] = protocol;
    obj["model"] = static_cast<int>(model);
    obj["codePage"] = static_cast<int>(codePage);
    QJsonArray fpArray;
    for (const auto &fp : customFastPaths) fpArray.append(fp.toJson());
    if (!fpArray.isEmpty()) obj["customFastPaths"] = fpArray;
    return obj;
}

DXSessionConfig DXSessionConfig::fromJson(const QJsonObject &json) {
    DXSessionConfig cfg;
    cfg.name = json["name"].toString();
    cfg.host = json["host"].toString();
    cfg.port = static_cast<uint16_t>(json["port"].toInt(23));
    cfg.useSSL = json["useSSL"].toBool(false);
    cfg.verifyCert = json["verifyCert"].toBool(true);
    cfg.caBundle = json["caBundle"].toString();
    cfg.protocol = json["protocol"].toInt(0);
    cfg.model = static_cast<x3270::TerminalModel>(json["model"].toInt(0));
    cfg.codePage = static_cast<x3270::CodePage>(json["codePage"].toInt(0));
    
    if (json.contains("customFastPaths")) {
        QJsonArray arr = json["customFastPaths"].toArray();
        for (const auto &val : arr) {
            cfg.customFastPaths.append(DXFastPath::fromJson(val.toObject()));
        }
    }
    return cfg;
}

QJsonObject DXWorkspaceGroup::toJson() const {
    QJsonObject obj;
    obj["name"] = name;
    QJsonArray arr;
    for (const auto &s : sessions) arr.append(s.toJson());
    obj["sessions"] = arr;
    return obj;
}

DXWorkspaceGroup DXWorkspaceGroup::fromJson(const QJsonObject &json) {
    DXWorkspaceGroup grp;
    grp.name = json["name"].toString();
    QJsonArray arr = json["sessions"].toArray();
    for (const auto &val : arr) {
        grp.sessions.append(DXSessionConfig::fromJson(val.toObject()));
    }
    return grp;
}

QJsonObject DXWorkspace::toJson() const {
    QJsonObject obj;
    obj["name"] = name;
    QJsonArray arr;
    for (const auto &g : groups) arr.append(g.toJson());
    obj["groups"] = arr;
    return obj;
}

DXWorkspace DXWorkspace::fromJson(const QJsonObject &json) {
    DXWorkspace ws;
    ws.name = json["name"].toString();
    QJsonArray arr = json["groups"].toArray();
    for (const auto &val : arr) {
        ws.groups.append(DXWorkspaceGroup::fromJson(val.toObject()));
    }
    return ws;
}

WorkspaceManager& WorkspaceManager::instance() {
    static WorkspaceManager mgr;
    return mgr;
}

QString WorkspaceManager::getConfigPath() const {
    QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return QDir(dir).filePath("DXWorkspaces.json");
}

bool WorkspaceManager::loadWorkspaces() {
    QFile file(getConfigPath());
    if (!file.open(QIODevice::ReadOnly)) {
        // Default primo avvio se non esiste file di configurazione
        DXWorkspace ws;
        ws.name = "Main Systems";
        DXWorkspaceGroup grp;
        grp.name = "MAIN SYSTEMS";
        ws.groups.append(grp);
        m_workspaces.append(ws);
        saveWorkspaces();
        return true;
    }

    QByteArray data = file.readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    m_workspaces.clear();
    
    QJsonArray arr = doc.array();
    for (const auto &val : arr) {
        m_workspaces.append(DXWorkspace::fromJson(val.toObject()));
    }
    return true;
}

bool WorkspaceManager::saveWorkspaces() {
    QFile file(getConfigPath());
    if (!file.open(QIODevice::WriteOnly)) return false;

    QJsonArray arr;
    for (const auto &ws : m_workspaces) arr.append(ws.toJson());

    QJsonDocument doc(arr);
    file.write(doc.toJson());
    return true;
}