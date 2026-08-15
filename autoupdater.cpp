#include "autoupdater.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QProcess>
#include <QStandardPaths>
#include <QSettings>
#include <QDebug>
#include <QNetworkRequest>
#include <QUrl>
#include <QDateTime>
#include <QFileInfo>
#include <QTimer>
#include <QCryptographicHash>
#include <QSet>
#include <QHash>
#include <QtConcurrent/QtConcurrent>
#ifdef Q_OS_WIN
#  include <windows.h>
#  include <shellapi.h>
#endif

// §43 版本号单一来源：CMakeLists.txt 顶部 PHOENIX_APP_VERSION 经编译宏注入。
// 兜底值仅在极端情况（未走 CMake 配置）下生效。
#ifndef PHOENIX_VERSION_STR
#define PHOENIX_VERSION_STR "1.0.0"
#endif

static QString qlgxPath()
{
    return QCoreApplication::applicationDirPath() + "/qlgx.txt";
}

static void qlgxLog(const QString &msg)
{
    QFile f(qlgxPath());
    if (f.open(QIODevice::Append | QIODevice::Text)) {
        QTextStream ts(&f);
        ts << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << "  " << msg << "\n";
        f.close();
    }
    qDebug().noquote() << "[qlgx]" << msg;
}

AutoUpdater* AutoUpdater::s_instance = nullptr;

AutoUpdater* AutoUpdater::instance()
{
    if (!s_instance) {
        s_instance = new AutoUpdater();
    }
    return s_instance;
}

AutoUpdater::AutoUpdater(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
    , m_currentVersion(QStringLiteral(PHOENIX_VERSION_STR))
{
    // 从设置中读取跳过的版本
    QSettings settings;
    m_skippedVersion = settings.value("update/skippedVersion", "").toString();
    
    qDebug() << "AutoUpdater initialized, current version:" << m_currentVersion;

    // §43 启动自检：上次更新是否真的成功（bat 换入后版本对不对）
    checkPendingUpdateResult();
}

void AutoUpdater::checkPendingUpdateResult()
{
    QString pendingPath = QCoreApplication::applicationDirPath() + "/update_pending.txt";
    QFile f(pendingPath);
    if (!f.exists())
        return;
    QString expected;
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        expected = QString::fromUtf8(f.readLine()).trimmed();
        f.close();
    }
    if (expected == m_currentVersion) {
        qlgxLog(QString("更新自检: ✅ 成功, 当前版本=%1").arg(m_currentVersion));
    } else {
        qlgxLog(QString("更新自检: ❌ 失败! 期望版本=%1, 实际运行=%2 "
                        "(换入未完成/文件被锁, 详见 update_extract.log)")
                .arg(expected, m_currentVersion));
    }
    f.remove();
}

void AutoUpdater::setStatusText(const QString &s)
{
    if (m_statusText == s) return;
    m_statusText = s;
    emit statusTextChanged();
}

void AutoUpdater::setUpdateUrl(const QString &url)
{
    m_updateCheckUrl = url;
    qDebug() << "Update check URL set to:" << url;
}

void AutoUpdater::checkForUpdates()
{
    if (m_updateCheckUrl.isEmpty()) {
        qlgxLog("checkForUpdates: 更新服务器地址未配置, 跳过");
        emit updateError("更新服务器地址未配置");
        return;
    }
    
    if (m_isChecking) {
        return;
    }
    
    m_isChecking = true;
    emit checkingChanged();
    
    qlgxLog(QString("checkForUpdates: 开始检查, URL=%1").arg(m_updateCheckUrl));
    
    QUrl url(m_updateCheckUrl);
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    
    QNetworkReply *reply = m_networkManager->get(req);
    
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        m_isChecking = false;
        emit checkingChanged();
        
        if (reply->error() != QNetworkReply::NoError) {
            qlgxLog(QString("checkForUpdates: 网络请求失败, error=%1").arg(reply->errorString()));
            emit updateError("检查更新失败: " + reply->errorString());
            reply->deleteLater();
            return;
        }
        
        QByteArray data = reply->readAll();
        // ⭐ 2026-08-14 排查 CDN 缓存不一致：记录 HTTP 状态码 + 最终 URL + 原始响应体，
        //   下次再弹更新框时 qlgx.txt 能直接证明服务器当时返回了什么
        int httpCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qlgxLog(QString("checkForUpdates: 收到响应 %1 bytes, HTTP=%2, finalUrl=%3")
                .arg(data.size()).arg(httpCode).arg(reply->url().toString()));
        qlgxLog(QString("checkForUpdates: 原始响应体=%1")
                .arg(QString::fromUtf8(data.left(400)).replace('\n', ' ')));
        reply->deleteLater();
        
        parseVersionInfo(data);
    });
}

void AutoUpdater::parseVersionInfo(const QByteArray &data)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        qlgxLog("parseVersionInfo: JSON 格式错误, 原始数据=" + QString::fromUtf8(data).left(200));
        emit updateError("版本信息格式错误");
        return;
    }
    
    QJsonObject obj = doc.object();
    
    m_latestVersion = obj["version"].toString();
    m_downloadUrl = obj["downloadUrl"].toString();
    m_downloadExeUrl = obj["downloadExe"].toString();
    m_manifestUrl = obj["manifestUrl"].toString();   // §43 有此字段即走清单差量
    m_changelog = obj["changelog"].toString();
    m_forceUpdate = obj["forceUpdate"].toBool(false);
    m_updateMode = obj["updateMode"].toInt(0);
    
    QString info = QString("parseVersionInfo: 当前=%1, 最新=%2, updateMode=%3, manifestUrl=%4, "
                           "downloadUrl=%5, downloadExe=%6, forceUpdate=%7")
        .arg(m_currentVersion, m_latestVersion)
        .arg(m_updateMode)
        .arg(m_manifestUrl.isEmpty() ? "(无,走legacy zip/exe)" : m_manifestUrl)
        .arg(m_downloadUrl, m_downloadExeUrl)
        .arg(m_forceUpdate ? "true" : "false");
    qlgxLog(info);
    
    if (compareVersions(m_latestVersion, m_currentVersion)) {
        m_hasUpdate = true;
        qlgxLog("parseVersionInfo: 发现新版本, 弹出更新对话框");
        emit updateAvailable(m_latestVersion, m_changelog);
    } else {
        m_hasUpdate = false;
        qlgxLog("parseVersionInfo: 已是最新版本, 无需更新");
    }
    
    emit updateInfoChanged();
}

bool AutoUpdater::compareVersions(const QString &v1, const QString &v2)
{
    // 比较版本号，v1 > v2 返回 true
    QStringList parts1 = v1.split('.');
    QStringList parts2 = v2.split('.');
    
    int maxLen = qMax(parts1.size(), parts2.size());
    
    for (int i = 0; i < maxLen; i++) {
        int num1 = (i < parts1.size()) ? parts1[i].toInt() : 0;
        int num2 = (i < parts2.size()) ? parts2[i].toInt() : 0;
        
        if (num1 > num2) return true;
        if (num1 < num2) return false;
    }
    
    return false;  // 相等
}

// ============================================================================
// §43 清单差量更新
//   流程: manifest.json → 后台逐文件 SHA256 比对 → 只下差异文件到 update_stage\
//        → 逐文件校验 → bat 等进程真退出 + robocopy 换入 → 重启 → 下次启动自检
//   任何一步失败: 正式目录零损伤, stage 保留（下次重试续传已下好的文件）
// ============================================================================

bool AutoUpdater::isSafeRelPath(const QString &p)
{
    if (p.isEmpty()) return false;
    if (p.contains("..")) return false;
    if (p.startsWith('/') || p.startsWith('\\')) return false;
    if (p.contains(':')) return false;
    return true;
}

QString AutoUpdater::fileSha256(const QString &filePath)
{
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    QCryptographicHash h(QCryptographicHash::Sha256);
    if (!h.addData(&f))
        return QString();
    return QString::fromLatin1(h.result().toHex()).toLower();
}

void AutoUpdater::downloadAndInstall()
{
    if (m_isDownloading) {
        qlgxLog("downloadAndInstall: 已在下载中, 忽略重复请求");
        return;
    }

    // §43: 有 manifestUrl 就走清单差量（自动算出该更哪些文件, 不再人肉猜 updateMode）
    if (!m_manifestUrl.isEmpty()) {
        startManifestUpdate();
        return;
    }

    qlgxLog(QString("downloadAndInstall: (legacy) 开始, updateMode=%1").arg(m_updateMode));
    
    QString actualDownloadUrl;
    QString fileName;
    QString tempDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    
    if (m_updateMode == 0 && !m_downloadExeUrl.isEmpty()) {
        actualDownloadUrl = m_downloadExeUrl;
        fileName = tempDir + "/HuanJing_update.exe";
        qlgxLog("downloadAndInstall: 模式0, 直接下载 exe, url=" + actualDownloadUrl);
    } else {
        actualDownloadUrl = m_downloadUrl;
        fileName = tempDir + "/HuanJing_update.zip";
        qlgxLog(QString("downloadAndInstall: 模式%1, 下载完整包 zip, url=%2")
                .arg(m_updateMode).arg(actualDownloadUrl));
    }
    
    if (actualDownloadUrl.isEmpty()) {
        qlgxLog("downloadAndInstall: 下载地址为空! 中止");
        emit updateError("下载地址为空");
        return;
    }
    
    m_isDownloading = true;
    m_downloadProgress = 0;
    emit downloadingChanged();
    emit downloadProgressChanged();
    
    m_downloadFile = new QFile(fileName);
    if (!m_downloadFile->open(QIODevice::WriteOnly)) {
        qlgxLog("downloadAndInstall: 无法创建下载文件: " + m_downloadFile->errorString());
        emit updateError("无法创建下载文件: " + m_downloadFile->errorString());
        m_isDownloading = false;
        emit downloadingChanged();
        delete m_downloadFile;
        m_downloadFile = nullptr;
        return;
    }
    
    qlgxLog("downloadAndInstall: 开始下载 -> " + fileName);
    
    QUrl downloadUrl(actualDownloadUrl);
    QNetworkRequest downloadReq(downloadUrl);
    m_downloadReply = m_networkManager->get(downloadReq);
    
    connect(m_downloadReply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        if (total > 0) {
            int pct = static_cast<int>(received * 100 / total);
            if (pct != m_downloadProgress) {
                m_downloadProgress = pct;
                emit downloadProgressChanged();
                if (pct % 25 == 0)
                    qlgxLog(QString("downloadAndInstall: 下载进度 %1% (%2/%3 bytes)")
                            .arg(pct).arg(received).arg(total));
            }
        }
    });
    
    connect(m_downloadReply, &QNetworkReply::readyRead, this, [this]() {
        if (m_downloadFile) {
            m_downloadFile->write(m_downloadReply->readAll());
        }
    });
    
    connect(m_downloadReply, &QNetworkReply::finished, this, [this]() {
        m_isDownloading = false;
        emit downloadingChanged();
        
        if (m_downloadFile) {
            m_downloadFile->close();
            qlgxLog(QString("downloadAndInstall: 文件已写入, 大小=%1 bytes, 路径=%2")
                    .arg(m_downloadFile->size()).arg(m_downloadFile->fileName()));
        }
        
        if (m_downloadReply->error() != QNetworkReply::NoError) {
            qlgxLog("downloadAndInstall: 下载失败! error=" + m_downloadReply->errorString()
                    + ", httpCode=" + QString::number(
                          m_downloadReply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()));
            emit updateError("下载失败: " + m_downloadReply->errorString());
            if (m_downloadFile) {
                m_downloadFile->remove();
                delete m_downloadFile;
                m_downloadFile = nullptr;
            }
            m_downloadReply->deleteLater();
            m_downloadReply = nullptr;
            return;
        }
        
        qlgxLog("downloadAndInstall: 下载完成, 准备安装...");
        emit downloadComplete();

        QString appDir      = QCoreApplication::applicationDirPath();
        QString actualExeName = QFileInfo(QCoreApplication::applicationFilePath()).fileName();
        QString tempDir     = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
        QString zipFile     = tempDir + "/HuanJing_update.zip";
        QString exeFile     = tempDir + "/HuanJing_update.exe";
        QString batFile     = tempDir + "/update_huanjing.bat";

        bool directExeDownload = (m_updateMode == 0 && !m_downloadExeUrl.isEmpty());
        bool exeRenamed        = (actualExeName.compare("HuanJing.exe", Qt::CaseInsensitive) != 0);

        QString nAppDir  = QDir::toNativeSeparators(appDir);
        QString nTempDir = QDir::toNativeSeparators(tempDir);
        QString nZipFile = QDir::toNativeSeparators(zipFile);
        QString nExeFile = QDir::toNativeSeparators(exeFile);
        QString nExePath = nAppDir + "\\" + actualExeName;

        qlgxLog(QString("downloadAndInstall: appDir=%1, actualExe=%2, directExe=%3, renamed=%4")
                .arg(appDir, actualExeName)
                .arg(directExeDownload ? "true" : "false")
                .arg(exeRenamed ? "true" : "false"));

        QFile batScript(batFile);
        if (batScript.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream out(&batScript);
            out.setEncoding(QStringConverter::System);

            out << "@echo off\n";
            // 不切代码页 — bat 用 GBK 写入，与 cmd 默认代码页一致，中文路径才能正确解析
            out << "echo.\n";
            out << "echo  HuanJing Updater\n";
            out << "echo  =====================================\n";
            out << "echo.\n";

            // 解压明细日志（脚本在程序退出后运行，必须自己写文件）
            out << "set \"ULOG=" << nAppDir << "\\update_extract.log\"\n";
            out << "echo ==== HuanJing update %date% %time% ==== > \"%ULOG%\"\n";
            out << "echo  解压明细将写入: %ULOG%\n";

            // 强制结束 HuanJing 进程并等待释放文件锁
            out << "echo  [1/3] 等待旧程序退出...\n";
            out << "taskkill /F /IM HuanJing.exe /T >nul 2>&1\n";
            out << "taskkill /F /IM " << actualExeName << " /T >nul 2>&1\n";
            out << "timeout /t 2 /nobreak >nul\n";
            out << "echo.\n";

            // 防呆：解压若被多套了一层目录(zip 带 release/ 之类前缀，文件落到 appDir\子目录\)，
            // 把那层目录里的内容挪回根目录覆盖。正常解压时无子目录含 HuanJing.exe，自动跳过。
            auto writeUnnestFix = [&]() {
                out << "for /d %%D in (\"" << nAppDir << "\\*\") do (\n";
                out << "    if exist \"%%D\\HuanJing.exe\" (\n";
                out << "        echo  检测到多层目录，正在修正: %%D\n";
                out << "        echo --- fix nested dir: %%D --- >> \"%ULOG%\"\n";
                out << "        xcopy \"%%D\\*\" \"" << nAppDir << "\\\" /E /H /Y >> \"%ULOG%\" 2>&1\n";
                out << "        rd /s /q \"%%D\"\n";
                out << "    )\n";
                out << ")\n";
            };

            if (directExeDownload) {
                out << "echo  [2/3] 正在替换程序文件...\n";
                out << "echo --- copy exe --- >> \"%ULOG%\"\n";
                out << "copy /y \"" << nExeFile << "\" \"" << nExePath << "\" >> \"%ULOG%\" 2>&1\n";
                out << "del \"" << nExeFile << "\" >nul 2>&1\n";
            } else if (m_updateMode == 0) {
                out << "echo  [2/3] 正在解压程序包（请稍候）...\n";
                // tar.exe 是 Win10 1803+ 内置工具，对中文路径支持比 powershell Expand-Archive 好
                // -C 切到目标目录，-x 解压，-v 逐个列出文件（含覆盖失败的错误行），-f 指定 zip 文件
                out << "if not exist \"" << nAppDir << "\" md \"" << nAppDir << "\"\n";
                out << "echo --- tar -xv --- >> \"%ULOG%\"\n";
                out << "tar -xv -f \"" << nZipFile << "\" -C \"" << nAppDir << "\" >> \"%ULOG%\" 2>&1\n";
                out << "if errorlevel 1 (\n";
                out << "    echo  tar 解压失败，回退到 powershell ...\n";
                out << "    echo --- powershell Expand-Archive --- >> \"%ULOG%\"\n";
                out << "    powershell -NoProfile -Command \"Expand-Archive -LiteralPath \\\""
                    << nZipFile << "\\\" -DestinationPath \\\"" << nAppDir << "\\\" -Force\" >> \"%ULOG%\" 2>&1\n";
                out << ")\n";
                out << "del \"" << nZipFile << "\" >nul 2>&1\n";
                writeUnnestFix();
                if (exeRenamed) {
                    out << "if exist \"" << nAppDir << "\\HuanJing.exe\" "
                        << "ren \"" << nAppDir << "\\HuanJing.exe\" \"" << actualExeName << "\"\n";
                }
            } else {
                // 模式1 全量更新：直接解压到 appDir
                out << "echo  [2/3] 正在解压完整更新包（请稍候，文件较大）...\n";
                out << "if not exist \"" << nAppDir << "\" md \"" << nAppDir << "\"\n";
                out << "echo --- tar -xv --- >> \"%ULOG%\"\n";
                out << "tar -xv -f \"" << nZipFile << "\" -C \"" << nAppDir << "\" >> \"%ULOG%\" 2>&1\n";
                out << "if errorlevel 1 (\n";
                out << "    echo  tar 解压失败，回退到 powershell ...\n";
                out << "    echo --- powershell Expand-Archive --- >> \"%ULOG%\"\n";
                out << "    powershell -NoProfile -Command \"Expand-Archive -LiteralPath \\\""
                    << nZipFile << "\\\" -DestinationPath \\\"" << nAppDir << "\\\" -Force\" >> \"%ULOG%\" 2>&1\n";
                out << "    if errorlevel 1 (\n";
                out << "        echo  解压失败，请手动更新（详细见 %ULOG%）\n";
                out << "        pause\n";
                out << "        exit /b 1\n";
                out << "    )\n";
                out << ")\n";
                out << "del \"" << nZipFile << "\" >nul 2>&1\n";
                writeUnnestFix();
                if (exeRenamed) {
                    out << "if exist \"" << nAppDir << "\\HuanJing.exe\" "
                        << "ren \"" << nAppDir << "\\HuanJing.exe\" \"" << actualExeName << "\"\n";
                }
            }

            out << "echo.\n";
            out << "echo  [3/3] 更新完成，正在重启程序...\n";
            out << "echo.\n";
            out << "start \"\" \"" << nExePath << "\"\n";
            out << "del \"%~f0\"\n";
            batScript.close();

            qlgxLog("downloadAndInstall: bat 已写入 " + batFile);

            m_isInstalling = true;
            emit installingChanged();
            emit installReady();

            // ShellExecuteW 弹出可见 bat 窗口（与父进程是否有控制台无关）
            QString nBatFile = QDir::toNativeSeparators(batFile);
            QString shellParam = QString("/c \"%1\"").arg(nBatFile);
            ShellExecuteW(nullptr, L"open", L"cmd.exe",
                          reinterpret_cast<const wchar_t*>(shellParam.utf16()),
                          reinterpret_cast<const wchar_t*>(nAppDir.utf16()),
                          SW_SHOWNORMAL);

            qlgxLog("downloadAndInstall: ShellExecuteW 已调用，立即退出");
            // 与测试版一致：立即退出，bat 的 timeout/t 3 等待结束后再解压
            QCoreApplication::quit();
        } else {
            qlgxLog("downloadAndInstall: 无法创建 bat 脚本!");
            emit updateError("无法创建更新脚本");
        }

        if (m_downloadFile) {
            delete m_downloadFile;
            m_downloadFile = nullptr;
        }
        m_downloadReply->deleteLater();
        m_downloadReply = nullptr;
    });
}

// ---------------------------------------------------------------------------
// §43.1 拉 manifest.json
// ---------------------------------------------------------------------------
void AutoUpdater::startManifestUpdate()
{
    m_isDownloading = true;
    m_downloadProgress = 0;
    emit downloadingChanged();
    emit downloadProgressChanged();
    setStatusText("正在获取更新清单...");

    QString url = m_manifestUrl;
    url += (url.contains('?') ? "&v=" : "?v=") + QString::number(QDateTime::currentMSecsSinceEpoch());
    qlgxLog("manifest: 拉取清单 " + url);

    QNetworkReply *reply = m_networkManager->get(QNetworkRequest(QUrl(url)));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            reply->deleteLater();
            abortManifestUpdate("获取更新清单失败: " + reply->errorString());
            return;
        }
        QByteArray data = reply->readAll();
        reply->deleteLater();
        onManifestReceived(data);
    });
}

void AutoUpdater::onManifestReceived(const QByteArray &data)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        abortManifestUpdate("更新清单格式错误");
        return;
    }
    QJsonObject obj = doc.object();
    m_manifestVersion = obj["version"].toString();
    m_manifestBaseUrl = obj["baseUrl"].toString();
    while (m_manifestBaseUrl.endsWith('/'))
        m_manifestBaseUrl.chop(1);

    m_manifestAll.clear();
    QJsonArray files = obj["files"].toArray();
    qint64 totalBytes = 0;
    for (const QJsonValue &v : files) {
        QJsonObject fo = v.toObject();
        ManifestFile mf;
        mf.path = fo["path"].toString();
        mf.size = static_cast<qint64>(fo["size"].toDouble());
        mf.sha256 = fo["sha256"].toString().toLower();
        if (!isSafeRelPath(mf.path) || mf.sha256.size() != 64) {
            abortManifestUpdate("清单含非法条目: " + mf.path);
            return;
        }
        totalBytes += mf.size;
        m_manifestAll.append(mf);
    }
    if (m_manifestAll.isEmpty() || m_manifestBaseUrl.isEmpty()) {
        abortManifestUpdate("更新清单为空或缺 baseUrl");
        return;
    }
    qlgxLog(QString("manifest: 版本=%1, 文件数=%2, 总大小=%3 MB, baseUrl=%4")
            .arg(m_manifestVersion).arg(m_manifestAll.size())
            .arg(totalBytes / 1024.0 / 1024.0, 0, 'f', 1).arg(m_manifestBaseUrl));

    // 后台线程逐文件 SHA256 比对（几百 MB 哈希需数秒，不能堵主线程）
    setStatusText("正在比对本地文件...");
    QString appDir = QCoreApplication::applicationDirPath();
    m_stageDir = appDir + "/update_stage";
    QString stageDir = m_stageDir;
    QVector<ManifestFile> all = m_manifestAll;

    (void)QtConcurrent::run([this, appDir, stageDir, all]() {
        QVector<ManifestFile> need;      // 本地缺失/不一致
        QSet<QString> stagedOk;          // stage 里已有且哈希正确（上次没下完的续用）
        qint64 needBytes = 0;
        QHash<QString, ManifestFile> needMap;

        int idx = 0;
        for (const ManifestFile &mf : all) {
            ++idx;
            if ((idx % 100) == 0) {
                int i = idx, n = all.size();
                QMetaObject::invokeMethod(this, [this, i, n]() {
                    setStatusText(QString("正在比对本地文件 %1/%2 ...").arg(i).arg(n));
                }, Qt::QueuedConnection);
            }
            QString localPath = appDir + "/" + mf.path;
            QFileInfo fi(localPath);
            bool same = fi.exists() && fi.size() == mf.size
                        && fileSha256(localPath) == mf.sha256;
            if (!same) {
                need.append(mf);
                needMap.insert(mf.path, mf);
            }
        }

        // 清理 stage：不在本次差量里的一律删掉（防旧版本残留被 robocopy 一起搬进正式目录）；
        // 在差量里且哈希已正确的记为 stagedOk（断点续传：跳过重下）。
        QDir sd(stageDir);
        if (sd.exists()) {
            QDirIterator it(stageDir, QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext()) {
                QString fp = it.next();
                QString rel = sd.relativeFilePath(fp);
                auto found = needMap.constFind(rel);
                if (found != needMap.constEnd()
                        && QFileInfo(fp).size() == found->size
                        && fileSha256(fp) == found->sha256) {
                    stagedOk.insert(rel);
                } else {
                    QFile::remove(fp);
                }
            }
        }

        QVector<ManifestFile> toDownload;
        for (const ManifestFile &mf : need) {
            if (stagedOk.contains(mf.path)) continue;
            toDownload.append(mf);
            needBytes += mf.size;
        }

        int stagedCount = stagedOk.size();
        int needCount = need.size();
        QMetaObject::invokeMethod(this, [this, toDownload, needBytes, stagedCount, needCount]() {
            m_needFiles = toDownload;
            m_needTotalBytes = needBytes;
            m_doneBytes = 0;
            m_fileIndex = 0;
            m_fileRetry = 0;
            qlgxLog(QString("manifest: 比对完成, 差异文件=%1 (stage已备好=%2, 需下载=%3, 共 %4 MB)")
                    .arg(needCount).arg(stagedCount).arg(toDownload.size())
                    .arg(needBytes / 1024.0 / 1024.0, 0, 'f', 1));
            onDiffReady();
        }, Qt::QueuedConnection);
    });
}

void AutoUpdater::onDiffReady()
{
    // 差异为 0 且 stage 也没有备好的文件 → 打包/发布配置有问题（版本号更新了但内容没变）
    if (m_needFiles.isEmpty()) {
        bool stageHasFiles = false;
        QDirIterator it(m_stageDir, QDir::Files, QDirIterator::Subdirectories);
        stageHasFiles = it.hasNext();
        if (!stageHasFiles) {
            abortManifestUpdate(QString("清单(%1)与本地文件完全一致, 无需更新 — "
                                        "请检查服务器 manifest 是否用旧文件生成").arg(m_manifestVersion));
            return;
        }
        // stage 里已备齐（上次下载完成但换入失败的重试场景）→ 直接换入
        qlgxLog("manifest: 无需下载, stage 已备齐, 直接换入");
        finalizeManifestUpdate();
        return;
    }
    downloadNextManifestFile();
}

// ---------------------------------------------------------------------------
// §43.2 串行下载差异文件到 stage，逐文件 SHA256 校验，单文件失败重试 3 次
// ---------------------------------------------------------------------------
void AutoUpdater::downloadNextManifestFile()
{
    if (m_fileIndex >= m_needFiles.size()) {
        finalizeManifestUpdate();
        return;
    }

    const ManifestFile mf = m_needFiles[m_fileIndex];
    QString stagePath = m_stageDir + "/" + mf.path;
    QDir().mkpath(QFileInfo(stagePath).absolutePath());

    setStatusText(QString("下载 %1/%2: %3").arg(m_fileIndex + 1).arg(m_needFiles.size()).arg(mf.path));

    m_downloadFile = new QFile(stagePath);
    if (!m_downloadFile->open(QIODevice::WriteOnly)) {
        QString err = m_downloadFile->errorString();
        delete m_downloadFile;
        m_downloadFile = nullptr;
        abortManifestUpdate(QString("无法创建暂存文件 %1: %2").arg(mf.path, err));
        return;
    }

    QUrl url(m_manifestBaseUrl + "/" + mf.path);
    m_downloadReply = m_networkManager->get(QNetworkRequest(url));

    connect(m_downloadReply, &QNetworkReply::readyRead, this, [this]() {
        if (m_downloadFile)
            m_downloadFile->write(m_downloadReply->readAll());
    });

    connect(m_downloadReply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64) {
        if (m_needTotalBytes > 0) {
            int pct = static_cast<int>((m_doneBytes + received) * 100 / m_needTotalBytes);
            pct = qBound(0, pct, 100);
            if (pct != m_downloadProgress) {
                m_downloadProgress = pct;
                emit downloadProgressChanged();
            }
        }
    });

    connect(m_downloadReply, &QNetworkReply::finished, this, [this, mf]() {
        QString stagePath = m_stageDir + "/" + mf.path;
        if (m_downloadFile) {
            m_downloadFile->close();
            delete m_downloadFile;
            m_downloadFile = nullptr;
        }
        QNetworkReply::NetworkError netErr = m_downloadReply->error();
        QString errStr = m_downloadReply->errorString();
        int httpCode = m_downloadReply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        m_downloadReply->deleteLater();
        m_downloadReply = nullptr;

        QString failReason;
        if (netErr != QNetworkReply::NoError) {
            failReason = QString("网络错误 %1 (http=%2)").arg(errStr).arg(httpCode);
        } else {
            QFileInfo fi(stagePath);
            if (fi.size() != mf.size)
                failReason = QString("大小不符 期望=%1 实际=%2").arg(mf.size).arg(fi.size());
            else if (fileSha256(stagePath) != mf.sha256)
                failReason = "SHA256 校验失败";
        }

        if (!failReason.isEmpty()) {
            QFile::remove(stagePath);
            m_fileRetry++;
            qlgxLog(QString("manifest: ❌ %1 下载失败(%2), 第%3次").arg(mf.path, failReason).arg(m_fileRetry));
            if (m_fileRetry >= 3) {
                abortManifestUpdate(QString("文件 %1 连续 3 次下载失败: %2").arg(mf.path, failReason));
                return;
            }
            downloadNextManifestFile();  // 重试同一文件（m_fileIndex 未动）
            return;
        }

        // 本文件成功
        m_doneBytes += mf.size;
        m_fileIndex++;
        m_fileRetry = 0;
        downloadNextManifestFile();
    });
}

void AutoUpdater::abortManifestUpdate(const QString &reason)
{
    qlgxLog("manifest: ⛔ 更新中止 — " + reason + "（正式目录未动, stage 保留可续传）");
    if (m_downloadReply) {
        m_downloadReply->disconnect(this);   // 防 abort 触发 finished 回调摸空指针
        m_downloadReply->abort();
        m_downloadReply->deleteLater();
        m_downloadReply = nullptr;
    }
    if (m_downloadFile) {
        m_downloadFile->close();
        delete m_downloadFile;
        m_downloadFile = nullptr;
    }
    m_isDownloading = false;
    emit downloadingChanged();
    setStatusText("");
    emit updateError(reason);
}

// ---------------------------------------------------------------------------
// §43.3 换入：bat 轮询等进程真退出（不再盲等 2s）→ robocopy 带重试搬入 → 重启
//   robocopy 退出码 >=8 = 有文件没搬进去 → 不启动新程序、保留 stage，重跑 bat 可续
// ---------------------------------------------------------------------------
void AutoUpdater::finalizeManifestUpdate()
{
    qlgxLog(QString("manifest: 全部文件就绪(共 %1 个), 准备换入并重启").arg(m_needFiles.size()));
    m_isDownloading = false;
    emit downloadingChanged();
    emit downloadComplete();
    setStatusText("正在安装更新...");

    QString appDir        = QCoreApplication::applicationDirPath();
    QString actualExeName = QFileInfo(QCoreApplication::applicationFilePath()).fileName();
    QString tempDir       = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    QString batFile       = tempDir + "/update_huanjing.bat";
    bool exeRenamed       = (actualExeName.compare("HuanJing.exe", Qt::CaseInsensitive) != 0);

    QString nAppDir   = QDir::toNativeSeparators(appDir);
    QString nStageDir = QDir::toNativeSeparators(m_stageDir);
    QString nExePath  = nAppDir + "\\" + actualExeName;

    // §43 自检标记：下次启动比对版本判定更新成败（checkPendingUpdateResult）
    {
        QFile pf(appDir + "/update_pending.txt");
        if (pf.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream ts(&pf);
            ts << m_manifestVersion << "\n"
               << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << "\n";
        }
    }

    QFile batScript(batFile);
    if (!batScript.open(QIODevice::WriteOnly | QIODevice::Text)) {
        abortManifestUpdate("无法创建更新脚本");
        return;
    }
    QTextStream out(&batScript);
    out.setEncoding(QStringConverter::System);   // GBK, 与 cmd 默认代码页一致

    out << "@echo off\n";
    out << "echo.\n";
    out << "echo  HuanJing Updater (manifest)\n";
    out << "echo  =====================================\n";
    out << "set \"ULOG=" << nAppDir << "\\update_extract.log\"\n";
    out << "echo ==== HuanJing manifest update to " << m_manifestVersion
        << " %date% %time% ==== > \"%ULOG%\"\n";

    // [1/3] 轮询等待进程真正退出（Phoenix 析构有多处 waitForDone(3000)，盲等 2s 是旧版失败主因）
    out << "echo  [1/3] 等待旧程序退出...\n";
    out << "set /a WAITED=0\n";
    out << ":waitloop\n";
    out << "tasklist /FI \"IMAGENAME eq HuanJing.exe\" 2>nul | find /i \"HuanJing.exe\" >nul\n";
    out << "if not errorlevel 1 goto stillrunning\n";
    if (exeRenamed) {
        out << "tasklist /FI \"IMAGENAME eq " << actualExeName << "\" 2>nul | find /i \""
            << actualExeName << "\" >nul\n";
        out << "if not errorlevel 1 goto stillrunning\n";
    }
    out << "goto readytocopy\n";
    out << ":stillrunning\n";
    out << "set /a WAITED+=1\n";
    out << "if %WAITED% GEQ 30 goto killhard\n";
    out << "timeout /t 1 /nobreak >nul\n";
    out << "goto waitloop\n";
    out << ":killhard\n";
    out << "echo  等待超时, 强制结束进程 >> \"%ULOG%\"\n";
    out << "taskkill /F /IM HuanJing.exe /T >nul 2>&1\n";
    if (exeRenamed)
        out << "taskkill /F /IM " << actualExeName << " /T >nul 2>&1\n";
    out << "timeout /t 2 /nobreak >nul\n";
    out << ":readytocopy\n";
    out << "taskkill /F /IM QtWebEngineProcess.exe >nul 2>&1\n";
    out << "echo  进程已退出(等待 %WAITED% 秒) >> \"%ULOG%\"\n";

    // [2/3] robocopy 从 stage 搬入正式目录（/R:10 /W:1 自带重试, 抗杀软瞬时锁）
    out << "echo  [2/3] 正在换入更新文件...\n";
    out << "robocopy \"" << nStageDir << "\" \"" << nAppDir
        << "\" /E /R:10 /W:1 /NP >> \"%ULOG%\" 2>&1\n";
    out << "if errorlevel 8 goto copyfail\n";
    out << "rd /s /q \"" << nStageDir << "\" >nul 2>&1\n";
    if (exeRenamed) {
        // 用户改过 exe 名: 新 HuanJing.exe 换入后复制为实际名字
        out << "if exist \"" << nAppDir << "\\HuanJing.exe\" (\n";
        out << "    copy /y \"" << nAppDir << "\\HuanJing.exe\" \"" << nExePath << "\" >> \"%ULOG%\" 2>&1\n";
        out << ")\n";
    }

    // [3/3] 重启
    out << "echo  [3/3] 更新完成，正在重启程序...\n";
    out << "start \"\" \"" << nExePath << "\"\n";
    out << "del \"%~f0\"\n";
    out << "exit /b 0\n";

    // 换入失败: 不启动程序、保留 stage(重开程序点更新可续)，把 robocopy 日志留在 ULOG
    out << ":copyfail\n";
    out << "echo.\n";
    out << "echo  [失败] 文件换入失败(robocopy 退出码 %errorlevel%)，详见 %ULOG%\n";
    out << "echo  请关闭占用程序(杀毒软件/资源管理器)后, 重新打开幻境再点一次更新即可续传。\n";
    out << "echo  换入失败 robocopy exit=%errorlevel% >> \"%ULOG%\"\n";
    out << "pause\n";
    out << "exit /b 1\n";
    batScript.close();

    qlgxLog("manifest: bat 已写入 " + batFile + ", 退出程序交给脚本换入");

    m_isInstalling = true;
    emit installingChanged();
    emit installReady();

    QString nBatFile = QDir::toNativeSeparators(batFile);
    QString shellParam = QString("/c \"%1\"").arg(nBatFile);
    ShellExecuteW(nullptr, L"open", L"cmd.exe",
                  reinterpret_cast<const wchar_t*>(shellParam.utf16()),
                  reinterpret_cast<const wchar_t*>(nAppDir.utf16()),
                  SW_SHOWNORMAL);
    QCoreApplication::quit();
}

void AutoUpdater::skipVersion()
{
    if (!m_latestVersion.isEmpty()) {
        m_skippedVersion = m_latestVersion;
        QSettings settings;
        settings.setValue("update/skippedVersion", m_skippedVersion);
        qDebug() << "Skipped version:" << m_skippedVersion;
    }
    m_hasUpdate = false;
    emit updateInfoChanged();
}
