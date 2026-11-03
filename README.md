# NaviApp V2.5

SwiftUI + MapKit 导航 App（iOS 17+，iPhone only）。

本仓库面向**云端免签编译**整理：不含 `.xcodeproj`，由 CI 用 XcodeGen 现场生成。

## 目录

```
NaviApp/
├── NaviApp/                          # 源码
│   ├── NaviApp.swift
│   ├── ContentView.swift
│   ├── LaneGuidanceView.swift
│   ├── NavigationEngine.swift
│   ├── RoutePlanner.swift
│   ├── RoutePreference.swift
│   ├── VoiceNavigation.swift
│   ├── Info.plist
│   └── Assets.xcassets/
├── project.yml                       # XcodeGen 工程描述
└── .github/workflows/build-ipa.yml   # 免签编译流水线
```

## 出 IPA

推送到 `main` 自动触发；或 Actions → Build Unsigned IPA → Run workflow。
产物在 run 页面的 Artifacts 里。

## 产物是未签名 IPA

GitHub runner 上没有你的签名证书，产物 **unsigned**，不能直接装机。需要用 Apple ID 重签：

- 免费 Apple ID：Sideloadly / AltStore，7 天有效，最多 3 个 App
- 付费开发者账号：真机证书，1 年有效

重签前建议改 Bundle ID（当前 `com.naviapp.NaviApp`）。

## 相对原稿的改动

原稿 `Naviapp_完整源代码v2.5.md` 无法直接编译，已修：

1. `LaneGuidanceView.swift` 缺 `import CoreLocation`（用了 `CLLocationDistance`）
2. `NavigationEngine.swift` 4 处 `MKMapPoint.distance(to:)` —— 该 API 不存在，改为 `MKMetersBetweenMapPoints`
3. `ContentView.swift` `onChange(of:)` 单参数闭包（iOS 17 已废弃）
4. `Info.plist` 缺 `MinimumOSVersion` / `CFBundleIconName`
5. 工作流 `xcodebuild` 命令被压成一行（反斜杠续行丢失）
6. 缺 `.xcodeproj`、缺 Assets 图标

## 已知限制

- 车道是 `synthesizeLanes` 按转向文案模拟的 4 条，不是高精地图真实车道
- 路口/红绿灯数量从转向文案估算
- 转向文案匹配是中文硬编码，英文系统下会失效
