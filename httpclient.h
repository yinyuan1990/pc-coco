#ifndef HTTPCLIENT_H
#define HTTPCLIENT_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSettings>
#include <QSysInfo>

/**
 * 登录响应数据结构
 */
struct LoginResponse {
    QString token;
    QString username;
    QString userType;
    QString currentDeviceId;
    QString currentDeviceUsername;
    int bindingCount = 0;
    QString membershipType;
    QString status;
    QString message;
    QJsonArray bindingList;
    int pcActivationLevel = 0;  // PC端等级，1=豪华版，2=AI全能版
    QString pcLevelName;         // 等级名称："豪华版"或"AI全能版"
    QString pcExpireAt;          // AI全能版到期时间（豪华版为空）
    bool pcValid = true;         // 当前等级是否有效
    int deviceLevel = 1;         // iOS设备等级：0=试用, 1=标清, 2=高清, 3=超清, 4=4K
    
    bool isValid() const { return !token.isEmpty(); }
};

/**
 * 保存的账号信息
 */
struct SavedAccount {
    QString username;
    QString password;
    QString lastDeviceUsername;  // 上次选择的设备账号
    QString lastDeviceDisplay;   // 上次选择的设备显示文本
};

/**
 * API 响应包装
 */
struct ApiResponse {
    int code = 0;
    QString message;
    bool success = false;
    QJsonObject data;
    
    static ApiResponse fromJson(const QByteArray &json, int httpCode);
    static ApiResponse error(int code, const QString &msg);
};

/**
 * HTTP 客户端管理器
 * 提供全局的 HTTP 网络请求功能
 */
class HttpClient : public QObject
{
    Q_OBJECT
    
public:
    static HttpClient* instance();
    
    // 设置服务器地址
    void setBaseUrl(const QString &url);
    Q_INVOKABLE QString baseUrl() const { return m_baseUrl; }
    
    // 设置认证 Token
    void setAuthToken(const QString &token);
    Q_INVOKABLE QString authToken() const { return m_authToken; }
    
    // WebSocket URL
    Q_INVOKABLE QString websocketUrl() const;
    
    // 登录信息
    Q_INVOKABLE QString loggedInUsername() const { return m_loggedInUsername; }
    // ⭐ §53.20.2：本机公网出口 IP（登录响应 clientIp）。随 PC_PRESENCE 上报，
    //   设备端与自己的出口比对，防 /24 网段号撞车误判同 WiFi。老后端 → 空。
    Q_INVOKABLE QString publicIp() const { return m_publicIp; }
    // ⭐ 需求#13：登录响应下发的 PC 最新版本号（空=后台未配置，跳过提示）与本机版本
    Q_INVOKABLE QString latestPcVersion() const { return m_latestPcVersion; }
    Q_INVOKABLE QString currentAppVersion() const;
    Q_INVOKABLE QString currentDeviceId() const { return m_currentDeviceId; }
    // ⭐ 2026-07-15：本次登录实际绑定的设备账号（未传 deviceUsername 时后端默认取第一个绑定），
    //   区别于 getSavedDeviceUsername()（用户上次在「切换账号」里选中、希望使用的设备）。
    //   两者不一致时，说明登录默认绑到了别的设备，需要自动切换回用户选中的设备。
    Q_INVOKABLE QString currentDeviceUsername() const { return m_currentDeviceUsername; }
    Q_INVOKABLE int pcActivationLevel() const { return m_pcActivationLevel; }
    Q_INVOKABLE QString pcLevelName() const { return m_pcLevelName; }
    Q_INVOKABLE QString pcExpireAt() const { return m_pcExpireAt; }
    Q_INVOKABLE QString pcDeviceId() const { return m_pcDeviceId; }
    Q_INVOKABLE int deviceLevel() const { return m_deviceLevel; }
    Q_INVOKABLE QVariantList levelFps() const { return m_levelFps; }
    Q_INVOKABLE QVariantList levelExposureFps() const { return m_levelExposureFps; }
    Q_INVOKABLE QJsonArray iceServers() const { return m_iceServers; }
    Q_INVOKABLE bool highSpeed240Allowed() const { return m_highSpeed240Allowed; }
    // ⭐ 2026-07-11：AI 白名单（登录响应下发）。true=该 PC 设备号在总后台 AI 白名单 → 走原来 fps 逻辑，不锁 30。
    Q_INVOKABLE bool aiWhitelisted() const { return m_aiWhitelisted; }
    // ⭐ 2026-07-11：本机是否装了主流 AI 编程工具（Cursor/VSCode/Codex 等）。装了且不在 AI 白名单则推流 fps 锁 30。
    Q_INVOKABLE bool aiCodingToolsDetected() const;
    Q_INVOKABLE void copyToClipboard(const QString &text);

    // ⭐ 设备平台判断：Android 端设备号带 "android" 前缀（见 Android DeviceIDManager.PLATFORM_PREFIX），
    //   iOS 无前缀。用于登录/切换账号列表标注平台，以及决定滤镜走「设备端 STOMP(iOS)」还是「PC 本地(Android)」。
    Q_INVOKABLE bool isAndroidDeviceId(const QString &deviceId) const {
        return deviceId.trimmed().startsWith(QStringLiteral("android"), Qt::CaseInsensitive);
    }
    Q_INVOKABLE QString deviceTypeLabel(const QString &deviceId) const {
        return isAndroidDeviceId(deviceId) ? QStringLiteral("Android") : QStringLiteral("iOS");
    }
    // 当前已连接设备是否 Android（滤镜路由用）
    Q_INVOKABLE bool currentIsAndroid() const { return isAndroidDeviceId(m_currentDeviceId); }
    
    // 登录接口（pcLevel: 1=豪华版, 2=AI全能版）
    // ⭐ 2026-08-01 fallbackOnUnboundDevice：登录页路径置 true——带的设备账号已被解绑（iOS 改密
    //   会解绑全部 PC，code=1004）时自动清除本地设备记忆并不带设备重登一次（后端默认绑第一个绑定设备）。
    //   「切换设备」路径保持 false：目标设备是用户刚点选的，失败必须如实报错。
    Q_INVOKABLE void login(const QString &username, const QString &password, int pcLevel,
                           const QString &deviceUsername = QString(),
                           bool fallbackOnUnboundDevice = false);

    // §44.3 获取最新版 PC 客户端下载地址（公开接口，无需登录）；结果经 latestDownloadUrlReceived 返回
    Q_INVOKABLE void fetchLatestDownloadUrl();

    // §56.29 获取 OTG 专版（看家Otg版本）下载地址；主版连到 OTG 设备时提示下载。结果经 otgClientDownloadUrlReceived 返回
    Q_INVOKABLE void fetchOtgClientDownloadUrl();
    
    // 注册接口（带昵称）
    Q_INVOKABLE void registerUser(const QString &username, const QString &password, const QString &nickname);
    
    // 绑定设备接口（旧接口，保留兼容）
    Q_INVOKABLE void bindDevice(const QString &controlUsername, const QString &deviceUsername, const QString &password);
    
    // 获取绑定设备列表
    Q_INVOKABLE void getBindingDevices(const QString &controlUsername);
    
    // ============ 新设备绑定接口 ============
    // 获取扫码绑定二维码数据
    Q_INVOKABLE void getQRCodeData();
    
    // 查询待验证绑定
    Q_INVOKABLE void getPendingBindings();
    
    // 验证控制端（扫码绑定第二步）
    Q_INVOKABLE void verifyControl(int bindingId, const QString &secondaryPassword);
    
    // 手动绑定设备
    Q_INVOKABLE void manualBind(const QString &deviceNickname, const QString &password, const QString &secondaryPassword);
    
    // 批量查询在线状态（用于切换账号）
    Q_INVOKABLE void getOnlineStatus(const QStringList &controlUsernames);
    
    // 设置设备备注
    Q_INVOKABLE void setRemark(const QString &controlUsername, const QString &deviceUsername, const QString &remark);
    
    // Windows端解绑设备
    Q_INVOKABLE void windowsUnbind(qlonglong bindingId, const QString &password);
    
    // 修改设备登录密码和管理密码
    Q_INVOKABLE void changeDevicePassword(const QString &controlUsername, const QString &deviceUsername, 
                                          const QString &currentSecondaryPassword, 
                                          const QString &newLoginPassword, const QString &newSecondaryPassword);

    // 修改当前登录(控制端)账号自己的登录密码
    Q_INVOKABLE void changeLoginPassword(const QString &oldPassword, const QString &newPassword);

    // PC端自助删除控制账号（同时解除其所有 iOS/Android 设备绑定）
    Q_INVOKABLE void deletePcAccount(const QString &username, const QString &password);
    
    // ============ iOS相机设定接口 ============
    // 获取相机设定（登录成功后调用）
    Q_INVOKABLE void getThinConfig();

    // ⭐ 拉取 iOS 滤镜默认值 (后台动态配置, 用于 PC iosFilterPopup 滑块的 from/to/默认值/步进/联动)
    //   成功时发 iosFilterDefaultsReceived(configJson) 信号, 失败发 iosFilterDefaultsFailed.
    Q_INVOKABLE void getIosFilterDefaults();

    // ⭐ 拉取 iOS 三链路开关/硬件默认值/LUT (GET /api/config/ios-pipeline)
    //   成功时发 iosPipelineReceived(configJson) 信号, 失败发 iosPipelineFailed.
    Q_INVOKABLE void getIosPipeline();

    // ⭐ 拉取相机快门(超级帧率cjfps)配置 (GET /api/config/camera-shutter)
    //   json = {ios:{min,max,step,default}, android:{...}}，按连接设备平台分别生效。
    //   成功时发 cameraShutterConfigReceived(configJson)，失败静默（QML 用内置默认值）。
    Q_INVOKABLE void getCameraShutterConfig();

    // 更新对焦距离
    Q_INVOKABLE void updateFocusDistance(double value);
    
    // 更新曝光补偿
    Q_INVOKABLE void updateExposure(int value);
    
    // 更新图像闪烁
    Q_INVOKABLE void updateFlicker(int value);
    
    // 更新帧率
    Q_INVOKABLE void updateFps(int value);
    
    // 更新镜头变倍
    Q_INVOKABLE void updateZoom(double value);
    
    // 更新清晰度(码率)
    Q_INVOKABLE void updateClarity(int value);
    
    // 更新摄像头方向
    Q_INVOKABLE void updateDirection(const QString &direction);
    
    // 更新画质类型（4k/ultra/high/standard）
    Q_INVOKABLE void updateQualityType(const QString &type);
    
    // 获取缓存的相机设定值（MainPage 初始化时使用）
    Q_INVOKABLE double getCachedZoom() const { return m_cachedZoom; }
    Q_INVOKABLE QString getCachedQualityType() const { return m_cachedQualityType; }
    Q_INVOKABLE int getCachedFps() const { return m_cachedFps; }
    Q_INVOKABLE QString getCachedDirection() const { return m_cachedDirection; }
    
    // ============ 本地存储（多账号支持）============
    // 保存账号信息（添加或更新到账号列表）
    Q_INVOKABLE void saveAccount(const QString &username, const QString &password, 
                                  const QString &deviceUsername = QString(), 
                                  const QString &deviceDisplay = QString());
    
    // 获取所有已保存的账号列表
    Q_INVOKABLE QStringList getSavedAccounts() const;
    
    // 获取指定账号的密码
    Q_INVOKABLE QString getAccountPassword(const QString &username) const;
    
    // 获取指定账号的设备信息
    Q_INVOKABLE QString getAccountDeviceUsername(const QString &username) const;
    Q_INVOKABLE QString getAccountDeviceDisplay(const QString &username) const;
    // ⭐ 2026-08-01：清除某账号本地记住的设备（iOS 改密解绑后旧记忆失效，登录 1004 自动回退时用）
    Q_INVOKABLE void clearAccountDevice(const QString &username);
    // ⭐ 2026-08-01：只更新某账号本地记住的设备（不动密码）。登录成功后把"服务器实际绑定的设备"
    //   写回本地，保证在线灯设备名与画面设备一致、且下次启动不再带着已解绑的旧设备去登（避免再次 1004）。
    Q_INVOKABLE void updateAccountDevice(const QString &username, const QString &deviceUsername, const QString &deviceDisplay);
    // ⭐ 2026-08-01：读取并清除"本次登录发生过设备自动回退"标记（QML 据此弹一次提示）
    Q_INVOKABLE bool consumeDeviceAutoFallback() { bool v = m_deviceAutoFallback; m_deviceAutoFallback = false; return v; }
    
    // 读取上次登录的账号（兼容旧接口）
    Q_INVOKABLE QString getSavedUsername() const;
    Q_INVOKABLE QString getSavedPassword() const;
    Q_INVOKABLE QString getSavedDeviceUsername() const;
    Q_INVOKABLE QString getSavedDeviceDisplay() const;
    
    // 退出登录（只清除token，保留账号列表）
    Q_INVOKABLE void logout();
    
    // 清除保存的账号（清除所有）
    Q_INVOKABLE void clearSavedAccount();
    
    // 删除指定账号
    Q_INVOKABLE void removeAccount(const QString &username);
    
signals:
    // 登录结果信号
    void loginSuccess(const QString &token, const QString &deviceId, const QString &deviceUsername, const QJsonArray &bindingList, int pcActivationLevel, const QString &pcLevelName, const QString &pcExpireAt, int deviceLevel, const QVariantList &levelFps, const QVariantList &levelExposureFps, const QJsonArray &iceServers);
    void loginFailed(int code, const QString &message);
    // §44.2 强制版本号拦截：需要更新时携带 exe 下载地址，QML 弹框点击用浏览器打开
    void loginNeedUpdate(const QString &message, const QString &downloadUrl);
    // §44.3 最新版下载地址获取结果（登录页"最新版下载"按钮用）
    void latestDownloadUrlReceived(const QString &url);
    // §56.29 OTG 专版下载地址获取结果（主版连 OTG 设备时的下载提示用；与上面独立，避免与登录页预取竞态）
    void otgClientDownloadUrlReceived(const QString &url);
    
    // 注册结果信号
    void registerSuccess(const QString &username, const QString &message);
    void registerFailed(int code, const QString &message);
    
    // 绑定设备结果信号
    void bindDeviceSuccess(const QString &message);
    void bindDeviceFailed(int code, const QString &message);
    
    // 获取绑定设备列表结果信号
    void bindingDevicesReceived(const QJsonArray &devices);
    void bindingDevicesFailed(int code, const QString &message);
    
    // 二维码数据结果信号
    void qrCodeDataReceived(const QString &controlUsername);
    void qrCodeDataFailed(int code, const QString &message);
    
    // 待验证绑定结果信号
    void pendingBindingsReceived(const QJsonArray &bindings);
    void pendingBindingsFailed(int code, const QString &message);
    
    // 验证控制端结果信号
    void verifyControlSuccess(const QString &deviceId, const QString &deviceUsername);
    void verifyControlFailed(int code, const QString &message);
    
    // 手动绑定结果信号
    void manualBindSuccess(const QString &deviceId, const QString &deviceUsername);
    void manualBindFailed(int code, const QString &message);
    
    // 在线状态结果信号
    void onlineStatusReceived(const QJsonArray &list);
    void onlineStatusFailed(int code, const QString &message);
    
    // 设置备注结果信号
    void setRemarkSuccess(const QString &controlUsername, const QString &deviceUsername, const QString &remark);
    void setRemarkFailed(int code, const QString &message);
    
    // 解绑结果信号
    void unbindSuccess(qlonglong bindingId, const QString &message);
    void unbindFailed(int code, const QString &message);
    
    // 修改设备管理密码结果信号
    void changePasswordSuccess(const QString &deviceUsername, const QString &message, int notifyCount, int unbindCount);
    void changePasswordFailed(int code, const QString &message);

    // 修改当前登录账号密码结果信号
    void changeLoginPasswordSuccess(const QString &message);
    void changeLoginPasswordFailed(int code, const QString &message);

    // PC端自助删除控制账号结果信号
    void deletePcAccountSuccess(const QString &username, const QString &message);
    void deletePcAccountFailed(const QString &username, int code, const QString &message);
    
    // iOS相机设定结果信号
    void cameraSettingSuccess(const QString &ptype, const QString &message);
    void cameraSettingFailed(const QString &ptype, int code, const QString &message);
    
    // 获取相机设定结果信号
    void thinConfigReceived(double focus, int exposureBias, int cjfps, int fps, int bitrate, const QString &direction, const QString &type, double zoom);
    void thinConfigFailed(int code, const QString &message);

    // ⭐ iOS 滤镜默认值 (后台动态配置)
    //   configJson 是后端 SystemConfig 表中存的整段 JSON 字符串, QML 端解析后应用到滑块属性
    void iosFilterDefaultsReceived(const QString &configJson);
    void iosFilterDefaultsFailed(int code, const QString &message);

    // ⭐ iOS 三链路开关/硬件/LUT 配置 ({switches, hardware, lut} 的 JSON 字符串)
    void iosPipelineReceived(const QString &configJson);
    void iosPipelineFailed(int code, const QString &message);

    // ⭐ 相机快门(超级帧率cjfps)配置 ({ios:{min,max,step,default}, android:{...}} 的 JSON 字符串)
    void cameraShutterConfigReceived(const QString &configJson);

private:
    explicit HttpClient(QObject *parent = nullptr);
    ~HttpClient();
    
    // 通用 POST 请求
    QNetworkReply* post(const QString &endpoint, const QJsonObject &body);
    
    // 通用 GET 请求
    QNetworkReply* get(const QString &endpoint);
    
    // 通用 PUT 请求
    QNetworkReply* put(const QString &endpoint, const QJsonObject &body);
    
    // 发送iOS相机设定更新（通用方法）
    void sendCameraSettingUpdate(const QString &ptype, const QJsonObject &config);
    
    // 构建完整 URL
    QString buildUrl(const QString &endpoint) const;
    
    // 判断是否为免认证接口
    bool isAuthExemptEndpoint(const QString &endpoint) const;
    
    // 生成/获取PC设备唯一标识
    QString generatePcDeviceId();

    // §23.16：剪贴板被占用时的非阻塞重试复制
    void copyToClipboardWithRetry(const QString &text, int attempt);
    
private:
    static HttpClient *s_instance;
    QNetworkAccessManager *m_manager;
    QString m_baseUrl;
    QString m_authToken;
    QString m_loggedInUsername;
    // ⭐ 本次会话密码（仅内存，不落盘）：取消「记住密码」时切换账号仍可用，见 getAccountPassword
    QString m_sessionUsername;
    QString m_sessionPassword;
    QString m_publicIp;               // ⭐ §53.20.2：登录响应回填的公网出口 IP
    QString m_latestPcVersion;        // ⭐ 需求#13：登录响应下发的 PC 最新版本号
    // ⭐ §53.22-附：登录传输层失败（状态码 0，如复用了被掐的 keep-alive 连接）自动重试一次的标记
    bool m_loginNetRetried = false;
    // ⭐ 2026-08-01：本次登录发生过"设备已解绑(1004)→清本地设备→回退默认设备"自动重登，供 QML 弹提示
    bool m_deviceAutoFallback = false;
    // ⭐ §53.23-附：登录请求代数——并发的旧登录请求迟到回调直接丢弃，只认最新一代
    int m_loginGeneration = 0;
    QString m_currentDeviceId;
    QString m_currentDeviceUsername;  // ⭐ 本次登录实际绑定的设备账号
    int m_pcActivationLevel = 0;  // PC端等级，1=豪华版，2=AI全能版
    bool m_aiWhitelisted = false;  // ⭐ AI 白名单：登录响应 aiWhitelisted，命中则走原来 fps 逻辑（不锁 30）
    QString m_pcLevelName;         // 等级名称
    QString m_pcExpireAt;          // AI全能版到期时间
    QString m_pcDeviceId;          // PC设备唯一标识
    int m_deviceLevel = 1;         // iOS设备等级：0=试用, 1=标清, 2=高清, 3=超清, 4=4K
    QVariantList m_levelFps;       // 各等级对应FPS上限，下标0=试用, 1=高清, 2=超清, 3=超高清, 4=超高帧
    QVariantList m_levelExposureFps; // 各等级对应超级帧率上限，下标0=试用, 1=高清, 2=超清, 3=超高清, 4=超高帧
    QJsonArray m_iceServers;         // P2P ICE 服务器列表
    bool m_highSpeed240Allowed = false; // 240fps高速模式总开关（从后端 device.highspeed240.enabled 获取）
    
    // 相机设定缓存（登录成功后从 getThinConfig 获取）
    double m_cachedZoom = 1.0;
    QString m_cachedQualityType = "high";
    int m_cachedFps = 30;
    QString m_cachedDirection = "-1";
};

#endif // HTTPCLIENT_H

