# NaviApp — iOS 导航 App（Xcode 工程 + 云打包）

一个基于 SwiftUI + MapKit 的简易导航 App：搜索目的地、显示驾车路线、预估时长与距离。

本目录是一个**完整可构建的 Xcode 工程**，同时附带 **GitHub Actions 云打包工作流**——即使你手头没有 Mac，也能通过 GitHub 的免费 macOS 云机器编译出可在 iPhone 安装的 `.ipa` 安装包。

---

## 快速路径（推荐，自签证书，无需 $99 账号）

当前工作流 `.github/workflows/build-ipa.yml` 直接输出**未签名 IPA**，全程无需配置任何 Secrets：

1. 把整个工程推到 GitHub（`git init && git add . && git commit -m init && git push`）。
2. 仓库 → **Actions** → 选 **Build Unsigned IPA** → **Run workflow**，等待约 5–10 分钟。
3. 在本次运行页面的 **Artifacts** 里下载 `NaviApp-unsigned-ipa`，解压得到 `NaviApp-unsigned.ipa`。
4. 在手机端自签工具（如「全能签」，需自行购买/导入对应的 P12 证书 + 绑定本机 UDID 的描述文件）中导入这个 IPA 并签名安装。
5. 首次安装后在「设置 → 通用 → VPN 与设备管理」中信任证书；如提示开启开发者模式，到「设置 → 隐私与安全性」打开。

> 注意：这类共享 P12 证书存在**掉签**风险（苹果随时可能撤销），掉签后 App 会闪退，需用证书商家补发的新证书重签。长期稳定使用请走下方「官方 $99 账号路径」。

---

## 目录结构

```
NaviApp/
├── NaviApp.xcodeproj/                  # Xcode 工程
│   ├── project.pbxproj                 # 工程配置（iOS 17+，仅 iPhone 竖屏）
│   └── xcshareddata/xcschemes/         # 共享 Scheme（xcodebuild 必需）
├── NaviApp/                            # 源码
│   ├── NaviApp.swift                   # App 入口
│   ├── ContentView.swift               # 导航主界面（搜索 + 路线规划 + 定位）
│   ├── Info.plist                      # 权限声明（定位）、启动页、显示名称
│   └── Assets.xcassets/AppIcon.appiconset/   # App 图标（空壳，可后补）
├── scripts/exportOptions.plist         # IPA 导出配置（ad-hoc）
├── .github/workflows/build-ipa.yml     # GitHub Actions 云打包
└── README.md
```

> 当前 `PRODUCT_BUNDLE_IDENTIFIER = com.example.NaviApp`，建议改成你自己的（如 `com.yourname.naviapp`）。

---

## 前置条件（必读）

1. **Apple 开发者账号（付费，$99/年）**：iPhone 安装自定义 `.ipa` 必须有开发者账号签名。
   - 免费 Apple ID 只能在本机 Xcode 上做 7 天有效期的真机调试，且每 7 天需重签一次，**无法用于云打包分发**。
2. **一个 GitHub 仓库**（公开或私有均可，私有仓库每月有免费 macOS 构建额度，个人使用足够）。
3. 目标 iPhone（iOS 17 及以上，工程最低支持 17.0）。

---

## 方式一：GitHub Actions 云打包（无 Mac 推荐）

### 第 1 步：准备证书与描述文件

在 [developer.apple.com](https://developer.apple.com) 完成：

| 项目 | 操作 |
|---|---|
| 证书（Certificate） | Certificates → 新建 **Apple Distribution** 证书，导出为 `.p12`（含私钥，需设密码） |
| 设备（Devices） | 把你要安装的 iPhone 的 **UDID** 添加进去（电脑上用爱思助手/Apple Configurator 可查看 UDID） |
| 描述文件（Profile） | Profiles → 新建 **Ad Hoc** 描述文件，关联上面的证书 + 设备，下载 `.mobileprovision` |

记下两样东西：
- **Team ID**：Membership 页面可查（10 位字母数字）
- **描述文件名称**：下载的 `.mobileprovision` 双击打开或用 `security cms -D -i xxx.mobileprovision` 查看，取 `<key>Name</key>` 的值

### 第 2 步：把工程推到 GitHub

```bash
git init
git add .
git commit -m "init NaviApp"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### 第 3 步：配置 Secrets（4 个）

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret 名称 | 值 |
|---|---|
| `CERT_BASE64` | `.p12` 证书文件转 Base64：`certutil -encode xxx.p12 tmp.txt` 后粘贴内容（Windows）；或 `base64 -i xxx.p12`（Mac/Linux） |
| `CERT_PASSWORD` | `.p12` 的导出密码 |
| `DEV_TEAM_ID` | 你的 Team ID |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 转 Base64（同上方法） |
| `PROVISIONING_PROFILE_NAME` | 描述文件的 Name（第 1 步查到的） |

### 第 4 步：触发构建并下载

仓库 → **Actions** 页 → 左侧 **Build iOS IPA** → 右侧 **Run workflow**（手动触发）。

- 每次构建都会先做一次**不签名编译检查**（无需证书也能验证代码能否通过）；
- 配置了 secrets 后，会继续签名 → 导出 `.ipa` → 出现在本次运行的 **Artifacts** 里，下载即可。

### 第 5 步：安装到 iPhone

下载 `NaviApp-ipa` 压缩包，解压得到 `NaviApp.ipa`，然后用：
- **爱思助手**：工具箱 → IPA 签名/安装（如提示签名，用你的 Ad Hoc 描述文件重签），或
- **Apple Configurator 2**（Mac）：添加 IPA 到设备

安装后在 iPhone「设置 → 通用 → VPN 与设备管理」中信任你的开发者证书即可打开。

> 注意：Ad Hoc 包只对描述文件里登记的 UDID 设备有效。换设备需回开发者网站添加 UDID 并重新生成描述文件，更新 Secret 后再跑一次工作流。

---

## 方式二：有 Mac 时本地构建

1. 安装 Xcode 15+（App Store）。
2. 双击打开 `NaviApp.xcodeproj`。
3. 选中 Target `NaviApp` → **Signing & Capabilities**：
   - 勾选 Automatically manage signing；
   - Team 选择你的开发者账号（免费账号可先真机调试 7 天）。
4. 连接 iPhone，选择设备，点 **Run** 直接安装运行；
   或 Product → **Archive** → Distribute App → **Ad Hoc** → 导出 `.ipa` 分发。

---

## 常见问题

| 问题 | 处理 |
|---|---|
| 构建报 `no profiles for ...` | 确认 Ad Hoc 描述文件已包含该设备 UDID，且 `PROVISIONING_PROFILE_NAME` 正确 |
| `exportOptions.plist` 的 `YOUR_TEAM_ID` | 工作流会自动替换；若本地手动导出，请改为你的 Team ID |
| 没有 App 图标 | `AppIcon.appiconset` 目前是空壳，可在 Xcode 中把 1024×1024 PNG 拖入（Assets → AppIcon）；Ad Hoc 安装不强制要求图标 |
| 需要 iOS 17 以下设备 | 修改工程里两处 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`（pbxproj 中）并替换不兼容 API |
| GitHub 私有仓库额度 | macOS 构建每月有免费分钟数，个人小项目足够；超出后仓库需公开或购买额度 |

---

## 自定义提示

- **App 显示名称**：改 `NaviApp/Info.plist` 里的 `CFBundleDisplayName`（当前为「导航」）。
- **定位权限文案**：改 `NSLocationWhenInUseUsageDescription`。
- **Bundle ID**：改 `project.pbxproj` 中 `PRODUCT_BUNDLE_IDENTIFIER`（建议全局替换）。
