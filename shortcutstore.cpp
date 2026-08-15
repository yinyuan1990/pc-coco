#include "shortcutstore.h"

ShortcutStore* ShortcutStore::s_instance = nullptr;

ShortcutStore* ShortcutStore::instance()
{
    if (!s_instance) {
        s_instance = new ShortcutStore();
    }
    return s_instance;
}

ShortcutStore::ShortcutStore(QObject *parent)
    : QObject(parent)
    , m_settings(new QSettings("Acard", "HuanJing_Shortcuts", this))
{
}

QString ShortcutStore::fullscreenViewerKey() const
{
    return m_settings->value("fullscreen_viewer_key", DEFAULT_FULLSCREEN_VIEWER_KEY).toString();
}

void ShortcutStore::setFullscreenViewerKey(const QString &key)
{
    if (fullscreenViewerKey() != key) {
        m_settings->setValue("fullscreen_viewer_key", key);
        emit shortcutsChanged();
    }
}

QString ShortcutStore::realtimeWindowKey() const
{
    return m_settings->value("realtime_window_key", DEFAULT_REALTIME_WINDOW_KEY).toString();
}

void ShortcutStore::setRealtimeWindowKey(const QString &key)
{
    if (realtimeWindowKey() != key) {
        m_settings->setValue("realtime_window_key", key);
        emit shortcutsChanged();
    }
}

QString ShortcutStore::slowmoWindowKey() const
{
    return m_settings->value("slowmo_window_key", DEFAULT_SLOWMO_WINDOW_KEY).toString();
}

void ShortcutStore::setSlowmoWindowKey(const QString &key)
{
    if (slowmoWindowKey() != key) {
        m_settings->setValue("slowmo_window_key", key);
        emit shortcutsChanged();
    }
}

QString ShortcutStore::gridFullscreenKey() const
{
    return m_settings->value("grid_fullscreen_key", DEFAULT_GRID_FULLSCREEN_KEY).toString();
}

void ShortcutStore::setGridFullscreenKey(const QString &key)
{
    if (gridFullscreenKey() != key) {
        m_settings->setValue("grid_fullscreen_key", key);
        emit shortcutsChanged();
    }
}

void ShortcutStore::resetToDefaults()
{
    m_settings->setValue("fullscreen_viewer_key", DEFAULT_FULLSCREEN_VIEWER_KEY);
    m_settings->setValue("realtime_window_key", DEFAULT_REALTIME_WINDOW_KEY);
    m_settings->setValue("slowmo_window_key", DEFAULT_SLOWMO_WINDOW_KEY);
    m_settings->setValue("grid_fullscreen_key", DEFAULT_GRID_FULLSCREEN_KEY);
    emit shortcutsChanged();
}

