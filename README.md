# PhoneLink · 手机消息同步到电脑

把荣耀（或任意 Android）手机收到的**短信**和**所有 App 通知**（微信 / QQ / 银行 / 验证码……）
实时推送到 Windows 电脑。手机端**完全静默**：没有界面、没有声音、没有打扰，**开机自动启动**，
杀掉后台也会自己回来。

```
手机 (Android)                              电脑 (Windows)
┌─────────────────────────┐                ┌──────────────────────────┐
│ 通知监听 + 短信广播      │  HTTP POST     │ Node 服务 (8787)         │
│ 前台服务保活（静默）     │ ─────────────► │  ├ SQLite 存档           │
│ 断网时本地排队不丢消息   │  LAN / WiFi    │  ├ 控制台实时打印        │
│ 开机广播自启 + 看门狗    │                │  ├ 网页 http://127.0.0.1:8787
└─────────────────────────┘                │  └ 桌面弹窗通知          │
                                           └──────────────────────────┘
```

---

## 一、快速开始（三步）

### 第 1 步：电脑端启动接收服务

双击 `pc\start.bat`。

屏幕上会打印出**手机需要填的 IP** 和**配对令牌**，例如：

```
  本机名称 : MY-PC
  手机填的 IP : 192.168.1.100   (以太网)
  端口      : 8787
  配对令牌  : A1B2C3
  网页查看  : http://127.0.0.1:8787/
```

浏览器会自动打开消息网页。**这个窗口保持开着**（后面可设成开机自启）。

### 第 2 步：放行防火墙（只需一次）

右键 `pc\allow-firewall.ps1` → **使用 PowerShell 运行**（会弹 UAC，点「是」）。
只放行本网段，不放行公网。

> 如果跳过这一步，手机连电脑时会被 Windows 防火墙挡住，表现为「连不上」。

### 第 3 步：安装手机 App（数据线，一次性）

1. 手机开启开发者选项：**设置 → 关于手机 → 连点「版本号」7 次**
2. **设置 → 系统和更新 → 开发人员选项 → 打开「USB 调试」**
3. 数据线连接电脑，手机上弹出「是否允许 USB 调试」→ 点**允许**
4. 在电脑上运行：

```powershell
# 在项目根目录（含 install.ps1 的那层）执行
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

这个脚本会自动完成：安装 APK → 授予短信/通知权限 → 开启通知使用权 →
加入电池优化白名单 → **把电脑 IP 和令牌直接写进 App** → 启动同步服务。

**手机端不需要点任何按钮。**

> 没有数据线？用无线调试：
> `install.ps1 -PairHost 手机IP:配对端口 -PairCode 6位配对码`（Android 11+，在
> 开发者选项 → 无线调试 里查看），之后 `install.ps1 -Wireless 手机IP`。

---

## 二、荣耀手机必做的最后设置（重要！）

荣耀 MagicOS 的应用启动管理**无法用脚本代劳**，不做这两步的话，手机锁屏一段时间后
系统会把同步服务杀掉。**只需要做一次**：

| # | 位置 | 操作 |
|---|------|------|
| 1 | 设置 → 应用 → **应用启动管理** → PhoneLink | 关闭「自动管理」，把 **自启动 / 关联启动 / 后台活动** 三项全部打开 |
| 2 | 设置 → 电池 → 更多电池设置 | 关闭对 PhoneLink 的省电限制 / 允许后台高耗电 |

App 界面里有按钮可以**直接跳到这两个页面**。

做完后就可以拔数据线了。之后手机**重启、锁屏、一键清理后台**，同步服务都会自己回来：

- **开机广播**（BOOT_COMPLETED / QUICKBOOT_POWERON）→ 立即拉起
- **JobScheduler 看门狗**（每 15 分钟，可跨重启持久化）→ 被杀后自动复活
- **START_STICKY 前台服务** → 系统回收后自动重建

---

## 三、日常使用

| 想做什么 | 怎么做 |
|---|---|
| 看消息 | 电脑网页 `http://127.0.0.1:8787/`（实时刷新、可搜索、可按应用筛选） |
| 看消息流水 | 跑着的那个黑色窗口会实时打印 |
| 翻历史 / 存档 | `pc\data\messages.log`（纯文本，可直接搜）、`pc\data\messages.db`（SQLite） |
| 导出 | 网页右上角「导出全部」 |
| 电脑开机自动接收 | 运行一次 `pc\install-autostart.ps1`（登录后最小化启动，不打扰） |
| 取消电脑自启 | `pc\install-autostart.ps1 -Uninstall` |
| 临时验证（没有手机时） | `node pc\simulate-phone.js` 模拟手机推几条消息 |

**电脑换了 IP 或路由器重新分配了地址？** 不用管 —— App 里的「自动搜索电脑」默认开启，
推送连续失败时会自动用 UDP 广播重新找到电脑（前提是第 2 步放行了 UDP 8788）。

---

## 四、它到底能收到什么？

| 通道 | 内容 | 需要什么权限 |
|---|---|---|
| **通知监听** | 微信 / QQ / 短信 / 银行 / 验证码等**所有 App 的通知**，含联系人名和正文 | 通知使用权（脚本已自动开启） |
| **短信广播** | 短信**完整原文**（不受通知栏截断影响），支持长短信自动拼接 | RECEIVE_SMS + READ_SMS |
| **短信补发** | 服务重启后自动回扫收件箱，补上宕机期间漏掉的短信 | READ_SMS |

> 两条通道是**互为备份**的：即使短信权限被系统拒绝（Android 10+ 对短信权限有硬限制），
> 通知通道仍然能拿到短信内容，功能不受影响。

---

## 五、目录结构

```
PhoneLink\                     ← 文件夹名必须纯英文，原因见第六节
├─ README.md                 本文档
├─ build.ps1                 重新构建 APK（无需 Gradle / 无需联网）
├─ install.ps1               一键装到手机（adb + 自动授权 + 自动写配置）
├─ phonelink.jks             签名密钥（首次构建自动生成，**不进仓库**，见下）
├─ dist\PhoneLink.apk        ← 构建产物，装到手机的就是它
├─ android\                  手机端源码（纯 Java，零第三方依赖）
│  ├─ AndroidManifest.xml
│  ├─ res\mipmap-*\          应用图标
│  └─ src\com\phonelink\app\
│     ├─ MainActivity.java   一次性设置界面
│     ├─ PushService.java    前台常驻服务 / 排队重发 / 自动重新发现电脑
│     ├─ NotifListener.java  通知监听（万能通道）
│     ├─ SmsReceiver.java    短信广播接收
│     ├─ SmsBackfill.java    宕机期间短信补发
│     ├─ BootReceiver.java   开机自启
│     ├─ WatchdogJob.java    看门狗，被杀自动复活
│     ├─ Db.java             本地 SQLite 发件箱（断网不丢消息）
│     ├─ Net.java            HTTP + UDP 发现
│     └─ Config.java / Msg.java
├─ pc\                       电脑端
│  ├─ server.js              Node 接收服务（零 npm 依赖）
│  ├─ start.bat              启动
│  ├─ public\index.html      消息网页
│  ├─ allow-firewall.ps1     放行防火墙（需管理员）
│  ├─ install-autostart.ps1  电脑开机自启
│  ├─ simulate-phone.js      模拟手机，用于自测
│  ├─ config.json            端口 / 令牌（首次运行自动生成）
│  └─ data\                  消息存档（messages.db / messages.log）
└─ toolchain\                构建工具链（约 1 GB，装一次就够）
   ├─ jdk-17\                Temurin JDK 17
   ├─ android-sdk\           platform-tools / build-tools 34 / android-34
   ├─ downloads\             安装包缓存（可删，需要时会重新下载）
   └─ setup-toolchain.ps1    工具链损坏时重新安装
```

---

## 六、重新构建 APK

工具链已装好，**不需要 Gradle、不需要联网**：

```powershell
# 在项目根目录执行
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

产物：`dist\PhoneLink.apk`。

流程：`aapt2 compile → aapt2 link → javac → d8 → 打包 → zipalign → apksigner`。
工具链位置：`toolchain\`（JDK 17 + Android SDK 34，随项目一起走）。
`build.ps1` 用脚本自身所在目录定位工具链，**整个 `PhoneLink` 文件夹可以随便挪**；
如果 `toolchain\` 缺失，它还会回退去找用户目录下的 `android-toolchain`。
工具链损坏时运行 `toolchain\setup-toolchain.ps1` 重装（约 500 MB 下载）。

> **签名密钥不在仓库里。** `phonelink.jks` 首次构建时自动生成，且被 `.gitignore` 排除。
> 所以：如果你 clone 后重新构建，得到的是**另一个密钥签名的 APK**——全新安装没问题，
> 但**无法覆盖升级**手机上用旧密钥装的版本（Android 会拒绝）。想平滑升级，
> 请自己保管好 `phonelink.jks` 并保持 `build.ps1` 里的口令不变。

> ⚠️ **路径必须是纯英文。** aapt2 / zipalign 这类 C++ 原生程序在 Windows 下用 ANSI 代码页
> 接收参数，中文路径会被错误解码（本项目最初就踩过这个坑，报错是
> `failed to open directory: 系统找不到指定的文件`）。所以 `PhoneLink` 这个归类文件夹
> **不能**放进 `本地工具`、`资源与运行环境` 这类中文目录下。
> 另外注意：javac / keytool 是 Java 程序（走 Unicode），它们不受影响——
> 出问题的只有原生 exe 和 .bat。
>
> 还有第二个坑：PowerShell 5.1 读**无 BOM 的 UTF-8** 脚本时按 GBK 解码。本项目最初的
> 工具链脚本因此把 SDK 装进了一个乱码目录。现在带中文的 .ps1 全部是 **UTF-8 with BOM**，
> 纯 ASCII 的则无所谓——改脚本时请保持这个约定。

---

## 七、通信协议（想自己改的话）

**推送消息** `POST http://<电脑IP>:8787/api/messages`

```json
{
  "device": "HONOR XYZ",
  "messages": [
    { "id": "uuid", "ts": 1789934404827, "kind": "sms",
      "pkg": "sms", "app": "短信", "title": "10086",
      "text": "您本月流量已使用 3.2GB", "sender": "10086", "slot": 0 },
    { "id": "uuid", "ts": 1789934404828, "kind": "notif",
      "pkg": "com.tencent.mm", "app": "微信",
      "title": "张三", "text": "晚上一起吃饭吗？", "sender": "", "slot": -1 }
  ]
}
```

- 请求头 `X-Token: <配对令牌>`；令牌不对返回 **401**（手机端会提示「令牌不正确」）
- 返回 `{"ok":true,"accepted":n,"stored":m}`；手机只有拿到 2xx 才删除本地副本
- **幂等**：`id` 相同不会重复入库，所以重发是安全的

**心跳 / 连接测试** `POST /api/heartbeat`
→ `{"device":"...","battery":86,"queued":0}`，带 `"test":true` 时只做连通性测试。

**局域网自动发现** UDP `8788`：手机广播 `PHONELINK_DISCOVER_V1`，
电脑回 `PHONELINK|<端口>|<电脑名>`。

**其他接口**：`GET /api/history?q=&kind=&app=&limit=`、`GET /api/status`、
`GET /api/export`、`GET /api/stream`（SSE 实时推送）。

---

## 八、常见问题

**Q：手机 App 一直显示「电脑不可达」**
1. 手机和电脑是不是同一个 WiFi？（手机开热点给电脑也行，反过来不行）
2. `pc\allow-firewall.ps1` 跑过没有？
3. 电脑上 `start.bat` 那个窗口还开着吗？
4. 打开手机 App → 点「自动搜索电脑」；还不行就手填电脑 IP。

**Q：短信收不到 / App 里短信权限显示未授权**
Android 10+ 对短信权限有硬限制，`pm grant` 可能失败。**不影响使用**——
通知通道照样能把短信内容发过来。想要完整原文，可以在 App 里点「申请短信权限」手动允许。

**Q：重启手机后不同步了**
荣耀的「应用启动管理」没设好，回到 [第二节](#二、荣耀手机必做的最后设置重要) 再检查一遍。
另外确认 App 界面里「状态：已开启」——只要它显示已开启，重启后就会自动拉起。

**Q：换了 WiFi，电脑 IP 变了**
不用管，会自动重新发现。想手动确认就打开 App 点一下搜索。

**Q：消息会不会丢？**
不会。手机端每条消息先写进本地 SQLite 发件箱，**收到电脑 2xx 确认才删除**，
断网期间排队，恢复后按顺序补发（默认保留 7 天）。电脑端按 `id` 去重，重发不会重复入库。

**Q：电脑上没收到桌面弹窗？**
`pc\config.json` 里把 `"toast": true`（默认开）。部分系统通知设置会屏蔽匿名 AppID 的
弹窗——网页和控制台不受影响。

**Q：想改端口**
编辑 `pc\config.json` 的 `port`，然后重跑一次 `install.ps1`（或者直接在手机 App 里改端口）。

---

## 九、安全说明

- 只在**局域网**内通信，数据不经过任何第三方服务器，全程不联网外发。
- `X-Token` 配对令牌保护写入接口（读接口是本机网页用，不暴露到公网即可）。
- 应用 `debuggable=true`：这是为了让 `install.ps1` 能把配置直接写进 App、实现零手工设置。
  代价是**拿到你手机 adb 权限的人可以读该 App 数据**。自己用没问题；
  如果你介意，把 `AndroidManifest.xml` 里的 `android:debuggable="true"` 删掉后重建，
  代价是手机端要手动填一次 IP。
- 防火墙规则限定 `RemoteAddress LocalSubnet`，公网访问不到。
- 短信和通知属于高度隐私数据，`pc\data\` 目录请自行注意备份与清理。

---

## 十、仓库里**没有**的东西

以下几项被 `.gitignore` 排除，clone 后不会出现，属正常现象：

| 项 | 原因 | 怎么补回来 |
|---|---|---|
| `toolchain\`（约 1 GB） | JDK + Android SDK 体积过大 | 运行 `toolchain\setup-toolchain.ps1` 自动下载 |
| `phonelink.jks` | 签名密钥，口令固定，公开等于任何人都能签出可覆盖安装的 APK | `build.ps1` 首次运行会自动生成 |
| `pc\config.json` | 内含配对令牌 | `server.js` 首次运行自动生成并打印 |
| `pc\data\` | 你的消息记录 | 运行时自动创建 |

---

## 许可证

[MIT](LICENSE) © 2026 Aliww2468
