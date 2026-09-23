# RustDesk 定制客户端构建套件（custom-rustdesk-client）

一键编译「**把自建服务器地址和 Key 写死、且隐藏网络设置界面**」的 RustDesk 客户端，
覆盖 **Windows / macOS / Linux / Android** 四平台。结构改编自
[njfkib/rustdesk-build](https://github.com/njfkib/rustdesk-build/tree/main/.github/workflows)，
但源码源改为**官方 rustdesk/rustdesk 1.4.9** 仓库，无需任何 PAT/私有仓库。

---

## 一、你的配置（config.json）

```json
{
  "appName": "RustDesk",
  "server": {
    "host": "175g.cf",
    "rendezvousPort": 21116,
    "relayPort": 21117,
    "key": "joaX2z6rQ9W8Yu6+ElpVb+1mjQVDsWkyFtIJc6c0t7U="
  },
  "hide": {
    "network": true,
    "security": true,
    "server": true,
    "proxy": true,
    "websocket": true,
    "remotePrinter": true
  },
  "signMode": "delete",
  "androidAppId": "com.carriez.flutter_hbb"
}
```

| 字段 | 含义 | 说明 |
| --- | --- | --- |
| `appName` | 客户端显示名称 | 改为其他名字时，Windows 包名/产物名会随之变化（见"可选改动"） |
| `server.host` | **ID / 中继服务器地址** | 本套件默认为 `175g.cf`，改这里即可整体替换 |
| `server.rendezvousPort` | ID 服务器端口 | 默认 `21116` |
| `server.relayPort` | 中继服务器端口 | 默认 `21117` |
| `server.key` | **服务器公钥** | 写死进源码 + custom.txt，客户端无法在界面篡改 |
| `hide.*` | 界面隐藏开关 | `network` 生效依赖 `security/server/proxy/websocket/remotePrinter` 全开（见第二节"顺序依赖"） |
| `signMode` | custom.txt 签名处理 | `delete` = 删掉验签逻辑（**信任自建服务器**）；`verify-check` = 保留校验逻辑不额外改动（不推荐）；留空 = 不触碰该项 |
| `androidAppId` | Android 包名 | 改为其他值时自动替换 Android 包名（`build.gradle` 中 `com.carriez.flutter_hbb`） |

> **安全提醒**：把 key 写死进客户端 = 客户端永久信任该服务器。请确保 `175g.cf` 只被你和信任的人控制。

---

## 二、三个关键设计（为什么这么做）

### 1. custom.txt 的命名与位置（官方机制，非魔改）
官方 1.4.9 通过**可执行文件同目录下的 `custom.txt`** 加载定制配置
（`libs/hbb_common/src/../common.rs` 中 `load_custom_client`），
macOS 分支固定读 `.app/Contents/Resources/custom.txt`。本套件：

- **Windows**：在 `flutter/assets/custom.txt`（即源码目录根）生成，打包后随可执行文件同目录；
- **macOS**：放进 `.app/Contents/Resources/`（njfkib 原版放 Contents/MacOS 是错的，已在 build-macos.yml 中修正）；
- **Linux**：放进 `flutter/tmpdeb/usr/share/rustdesk/`，build.py 的 deb 流程自动拷入 `/usr/share/rustdesk/custom.txt`；
- **Android**：放进 `flutter/assets/custom.txt`，MainService.kt 启动时读 `assets/custom.txt`。

### 2. 隐藏网络设置为什么放进 `override-settings`（顺序依赖）
`hide-network-settings` 必须放在 `override-settings` 内，才能进 BUILTIN_SETTINGS
（`get_builtin_option` 只读 BUILTIN_SETTINGS；放顶层会进 HARD_SETTINGS 而不生效）。
`gen_custom_txt.py` 自动生成：

```json
{
  "app-name": "RustDesk",
  "override-settings": {
    "custom-rendezvous-server": "175g.cf:21116",
    "relay-server": "175g.cf:21117",
    "key": "joaX2z6rQ9W8Yu6+ElpVb+1mjQVDsWkyFtIJc6c0t7U=",
    "hide-network-settings": "Y",
    "hide-security-settings": "Y",
    "hide-server-settings": "Y",
    "hide-proxy-settings": "Y",
    "hide-websocket-settings": "Y",
    "hide-remote-printer-settings": "Y"
  }
}
```

> 顺序依赖：`hide-network-settings` 只在 `hide-security-settings` 同时为 `Y` 时才隐藏网络入口。
> 因此 `config.json` 中六个 hide 开关**默认全开**。

### 3. 为什么要删签名（signMode=delete）
custom.txt 内含服务器 key，RustDesk 默认会对 custom.txt 做防篡改签名校验（使用内置私钥对应公钥）。
该私钥属于官方，我们无法为其签名，**若不做处理，客户端会忽略 custom.txt**。
`signMode=delete` 会精确删除 `src/common.rs` 中三行验签块（`const KEY` + `get_rs_pk` + `sign::verify`），
使 custom.txt 直接以 base64(JSON) 被信任——**这是让自建服务器生效的前提**。
`patch/apply-config.sh` 中该删除块带 `grep` 断言，替换失败会 `exit 1` 直接中断 CI，不会产出"看起来成功实则无效"的包。

---

## 三、使用步骤（fork → dispatch）

1. **Fork 本仓库** 到自己的 GitHub 账号（Actions 需要你的仓库才能跑）。
2. 可选：编辑 `config.json`（改服务器地址/Key/隐藏项/包名）。
3. 进入仓库 **Actions** 页，选择要构建的平台 workflow：
   - `build-custom-client-windows`
   - `build-custom-client-macos`
   - `build-custom-client-linux`
   - `build-custom-client-android`
4. 点击 **Run workflow**（Android/Linux/Mac 可按需填 `arch` / `format` 输入）→ 等待构建完成。
5. 在构建产物（Artifacts）中下载对应平台的安装包，安装后即：
   - ID 服务器 / 中继服务器 / Key **已写死**，无法在界面修改；
   - 网络设置界面被隐藏（设置页不再有"网络"入口）。

> 手动触发（workflow_dispatch）即可，**无需任何私密变量 / PAT**。

---

## 四、目录结构

```
custom-rustdesk-client/
├── config.json                 # ★ 你的配置（服务器/Key/隐藏项/包名）
├── .github/workflows/
│   ├── bridge.yml              # 生成跨语言 bridge 代码（build.rs 真实产物）
│   ├── build-windows.yml       # Windows（msvc）：exe + nsis 安装包
│   ├── build-macos.yml         # macOS：universal dmg + custom.txt 进 Resources
│   ├── build-linux.yml         # Ubuntu 24.04（x86_64）：.deb + 可选 AppImage
│   └── build-android.yml       # Android（aarch64/armv7/x86_64）：apk 或 aab
├── patch/
│   └── apply-config.sh         # ★ 核心补丁：写死 host/key + 删验签 + MainService 读 assets
└── tools/
    └── gen_custom_txt.py       # 由 config.json 生成 base64(JSON) 的 custom.txt
```

### apply-config.sh 做了什么（三处确定性补丁）
1. `libs/hbb_common/src/config.rs`：`RENDEZVOUS_SERVERS` → `["175g.cf"]`、`RS_PUB_KEY` → 你的 Key；
2. `src/common.rs`（signMode=delete 时）：删除 3 行验签块；
3. `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt`：
   `FFI.startServer(configPath, "")` → `readCustomClientConfig()`（新增读 `assets/custom.txt` 的 helper）。
4. 调用 `gen_custom_txt.py` 生成 base64 的 `custom.txt`。

三处替换均带失败断言，任一失败立即 `exit 1`，避免"补丁没生效却出了包"。

---

## 五、可选的额外改动

| 想改什么 | 文件 | 做法 |
| --- | --- | --- |
| appName（显示名称） | `config.json` | 改 `appName`；Windows/Mac/Linux/Android workflow 中已按 `filename` 改名产物 |
| Android 包名 | `config.json` | 改 `androidAppId`，`.github/workflows/build-android.yml` 自动替换 `build.gradle` |
| Android 隐藏"反诈提示弹窗" | `build-android.yml`（已内置） | `server_page.dart` 中 `show-scam-warning` 已替换为 `"N"` |
| 保留官方 custom.txt 签名 | `config.json` | `signMode` 置空/`verify-check`（不推荐，custom.txt 将不被信任，隐藏项失效） |

---

## 六、故障排查

| 症状 | 原因 / 处理 |
| --- | --- |
| 构建失败在 vcpkg 步骤 | 查看 vcpkg 日志：build_android_deps.sh 失败时会打印所有 `*.log`。常见为网络抖动，重跑一次（vcpkg 有 GitHub Actions 二进制缓存，二次跑很快） |
| Flutter 构建报 dropdown_menu 相关错误 | 各 workflow 已内置 `flutter_3.24.4_dropdown_menu_enableFilter.diff` 补丁（上游 1.4.9 自家 CI 同款）；若某平台仍报错，确认 flutter 版本是 3.24.5，或手动 `git apply` 该 diff |
| Job 超时（GitHub 免费 6h） | Linux/Android 首次冷构建最久（vcpkg 下载 + cargo）。可调大 `set-swap-space` 或换更大 runner；二次构建因缓存显著加快 |
| 安装了软件但连接不上服务器 | 确认 `175g.cf` 的 21116/21117 端口放行、key 与服务器 `rustdesk-server` 配置一致；确认 ServerPort 未自定义 |
| 界面仍显示"网络"设置 | 检查 custom.txt 是否随包落地（Windows `%ProgramFiles%\RustDesk\`、macOS `Contents/Resources/`、Linux `/usr/share/rustdesk/`）；确认 `hide` 六项全为 true（顺序依赖） |
| msys/本地试跑 apply-config.sh 报 sed 错 | 本脚本按 Linux sed 编写（CI 环境），本地 Windows Git Bash 若 GNU sed 可用则无碍；建议直接在 CI 中验证 |

---

## 七、版本与致谢

- 源码版本：官方 `rustdesk/rustdesk` **v1.4.9**（`libs/hbb_common` 子模块锁定 `7e1c392c62d39c364127307cd408421dd5f8cfb0`）
- workflow 结构参考：[njfkib/rustdesk-build](https://github.com/njfkib/rustdesk-build)
- 本套件按上游 1.4.9 源码事实重新实现（含 njfkib 中错误的 macOS custom.txt 路径修正），
  请以 GitHub Actions 实际运行结果为准；测试通过前请勿在生产环境分发。