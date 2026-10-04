// src/qt/WorkspaceManager.h
#pragma once

#include <QString>
#include <QList>
#include <QJsonObject>
#include <QJsonArray>
#include "../core/TerminalModel.h"
#include "../core/EbcdicCodec.h"

struct DXFastPath {
    QString title;
    QString cmd;
    QJsonObject toJson() const;
    static DXFastPath fromJson(const QJsonObject &json);
};

struct DXSessionConfig {
    QString name;
    QString host;
    uint16_t port{23};
    bool useSSL{false};
    bool verifyCert{true};
    QString caBundle;
    int protocol{0}; // 0 = TN3270, 1 = TN5250
    x3270::TerminalModel model{x3270::TerminalModel::Model2};
    x3270::CodePage codePage{x3270::CodePage::CP037};

    QList<DXFastPath> customFastPaths;
    
    QJsonObject toJson() const;
    static DXSessionConfig fromJson(const QJsonObject &json);
};

struct DXWorkspaceGroup {
    QString name;
    QList<DXSessionConfig> sessions;

    QJsonObject toJson() const;
    static DXWorkspaceGroup fromJson(const QJsonObject &json);
};

struct DXWorkspace {
    QString name;
    QList<DXWorkspaceGroup> groups;

    QJsonObject toJson() const;
    static DXWorkspace fromJson(const QJsonObject &json);
};

class WorkspaceManager {
public:
    static WorkspaceManager& instance();

    bool loadWorkspaces();
    bool saveWorkspaces();

    QList<DXWorkspace>& workspaces() { return m_workspaces; }

private:
    WorkspaceManager() = default;
    QString getConfigPath() const;
    QList<DXWorkspace> m_workspaces;
};