#pragma once

#include <QString>
#include <QList>
#include <QByteArray>
#include <QDateTime>
#include <QJsonObject>
#include <QJsonArray>

enum CellDiffState {
    CellDiffUnchanged = 0,
    CellDiffModified = 1
};

struct ScreenSnapshot {
    int rows{24};
    int cols{80};
    int cursorRow{0};
    int cursorCol{0};
    QByteArray characterBuffer; // QList<ushort> (unichar UTF-16)
    QByteArray attributeBuffer; // QList<uint32_t> (color/attr)
    qint64 timestamp{0};
    bool pinned{false};

    QJsonObject toJson() const;
    static ScreenSnapshot fromJson(const QJsonObject &obj);
};

class TimeMachineManager {
public:
    static TimeMachineManager& instance();

    void captureSnapshot(int rows, int cols, const ushort *chars, const uint32_t *attrs, int cursorRow, int cursorCol);
    void clearHistory();

    int snapshotCount() const { return m_snapshots.size(); }
    const ScreenSnapshot* snapshotAt(int index) const;
    const QList<ScreenSnapshot>& allSnapshots() const { return m_snapshots; }

    void togglePinAtIndex(int index);
    bool isPinnedAtIndex(int index) const;
    int nextPinnedIndexAfter(int currentIndex) const;
    int prevPinnedIndexBefore(int currentIndex) const;

    QList<int> compareSnapshots(const ScreenSnapshot &current, const ScreenSnapshot &baseline) const;
    int searchHistory(const QString &query, int startIndex, bool backward) const;

    bool exportTrace(const QString &filePath) const;
    bool importTrace(const QString &filePath);

    int baselinePinIndex() const { return m_baselinePinIndex; }
    void setBaselinePinIndex(int idx) { m_baselinePinIndex = idx; }

private:
    TimeMachineManager() = default;

    QList<ScreenSnapshot> m_snapshots;
    int m_baselinePinIndex{-1};
    static constexpr int kMaxSnapshots = 500; // Limite memoria storico
};