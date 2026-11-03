import SwiftUI
import MapKit
import CoreLocation

// MARK: - 定位管理器（按需动态配置定位精度与后台常驻）

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()

        manager.delegate = self
        // 初始状态采用普通精度，完全关闭后台更新，节约电池
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 5.0
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    /// 请求权限
    func requestPermission() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
    }

    /// 🌟 修复关键：进入导航时，才动态提速到导航最高精度，并激活后台保活
    func enterNavigationMode() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 1.0
        manager.pausesLocationUpdatesAutomatically = false

        if let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           backgroundModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// 🌟 修复关键：退出导航后，立即撤销后台常驻并降低精度，彻底消除静默耗电
    func exitNavigationMode() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 10.0
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        guard latest.horizontalAccuracy >= 0 else { return }
        location = latest
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("定位异常：\(error.localizedDescription)")
    }
}

// MARK: - 主界面

struct ContentView: View {

    @StateObject private var locationManager = LocationManager()
    @StateObject private var navigationEngine = NavigationEngine()
    @StateObject private var voiceNavigation = VoiceNavigation()
    @StateObject private var routePlanner = RoutePlanner()

    @State private var cameraPosition: MapCameraPosition = .automatic

    @State private var selectedPreference: RoutePreference = .leastCongested
    @State private var routeAssessments: [RouteAssessment] = []

    @State private var destinationText = ""
    @State private var searchResults: [MKMapItem] = []

    @State private var startMapItem: MKMapItem?
    @State private var viaMapItem: MKMapItem?
    @State private var destinationMapItem: MKMapItem?

    // 存储当前所有候选的全程复合路线
    @State private var displayRoutes: [NavRoute] = []
    @State private var selectedRouteIndex: Int = 0

    @State private var startText = ""
    @State private var viaText = ""

    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var viaCoordinate: CLLocationCoordinate2D?
    @State private var endCoordinate: CLLocationCoordinate2D?

    @State private var startName = "我的位置"
    @State private var endName = ""

    @State private var showResults = false
    @State private var showRouteDetails = false
    @State private var isSearching = false
    @State private var isCalculating = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var followUser = true

    @State private var radarPulse = false

    private var selectedRoute: NavRoute? {
        guard selectedRouteIndex < displayRoutes.count else { return nil }
        return displayRoutes[selectedRouteIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {

            // 1. 3D 地形与路线渲染
            Map(position: $cameraPosition) {

                if let loc = locationManager.location {
                    Annotation("当前位置", coordinate: loc.coordinate) {
                        car3DMarker(location: loc)
                    }
                }

                if let via = viaCoordinate {
                    Marker("途经点", coordinate: via)
                        .tint(.orange)
                }

                if let end = endCoordinate {
                    Marker(endName.isEmpty ? "目的地" : endName, coordinate: end)
                        .tint(Color(hex: "FF416C"))
                }

                // 渲染所有候选全程路线的完整折线
                ForEach(Array(displayRoutes.enumerated()), id: \.offset) { index, navRoute in
                    let isCurrent = (index == selectedRouteIndex)

                    ForEach(Array(navRoute.polylines.enumerated()), id: \.offset) { _, poly in
                        if isCurrent {
                            MapPolyline(poly)
                                .stroke(
                                    Color.black.opacity(0.5),
                                    style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
                                )

                            MapPolyline(poly)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color(hex: "0052D4"), Color(hex: "4364F7"), Color(hex: "6FB1FC")],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                                )

                            MapPolyline(poly)
                                .stroke(
                                    Color(hex: "00F2FE"),
                                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                                )
                        } else {
                            MapPolyline(poly)
                                .stroke(
                                    Color.gray.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                                )
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.parking, .gasStation])))
            .mapControls {
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }
            .ignoresSafeArea()

            // 2. 交互悬浮层
            VStack(spacing: 12) {
                if navigationEngine.isNavigating {
                    LaneGuidanceView(
                        lanes: navigationEngine.currentLanes,
                        nextTurnInstruction: navigationEngine.nextStepInstruction,
                        distanceToNextStep: navigationEngine.distanceToNextTurn,
                        isWeakGPS: navigationEngine.isWeakGPSSignal,
                        currentLegTitle: navigationEngine.currentLegBadgeTitle
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    searchAndPreferencePanel
                }

                Spacer()

                if navigationEngine.isNavigating {
                    navigationDashboardView
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !displayRoutes.isEmpty {
                    routeComparisonPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, navigationEngine.isNavigating ? 48 : 56)
            .padding(.bottom, 14)

            if showResults {
                resultsOverlay
            }
        }
        .onAppear {
            locationManager.requestPermission()

            navigationEngine.onOffRoute = {
                voiceNavigation.announceOffRoute()
            }

            navigationEngine.onArrival = {
                voiceNavigation.announceArrival()
                locationManager.exitNavigationMode() // 到达后退出高功耗后台定位
                withAnimation {
                    cameraPosition = .automatic
                }
            }

            navigationEngine.onStepAdvance = { instruction in
                voiceNavigation.speak(instruction)
            }

            navigationEngine.onLaneAdvise = { laneText in
                voiceNavigation.speak(laneText)
            }

            // 到达途经点通知
            navigationEngine.onViaPointReached = { viaName in
                voiceNavigation.speak("已到达途经点\(viaName)，正在继续前往最终目的地", isUrgent: true)
            }

            navigationEngine.onRerouted = { newNavRoute in
                displayRoutes = [newNavRoute]
                selectedRouteIndex = 0
                voiceNavigation.speak("已偏离路线，已为您按\(selectedPreference.rawValue)重算最优路线", isUrgent: true)
            }

            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                radarPulse = true
            }
        }
        .onChange(of: locationManager.location) { newLocation in
            guard let newLocation = newLocation else { return }

            let isUsingCurrentLocation = startText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || startText == "我的位置"
            if isUsingCurrentLocation {
                startCoordinate = newLocation.coordinate
                startMapItem = MKMapItem(placemark: MKPlacemark(coordinate: newLocation.coordinate))
            }

            navigationEngine.updateLocation(newLocation, preference: selectedPreference)

            if navigationEngine.isNavigating {
                update3DNavigationCamera(with: newLocation)
            } else if followUser && displayRoutes.isEmpty {
                moveCamera(to: newLocation.coordinate)
            }
        }
        .alert("提示", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showRouteDetails) {
            routeDetailsSheet
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 3D 拟真车模

    private func car3DMarker(location: CLLocation) -> some View {
        let headingDegrees = (location.course >= 0 ? location.course : (locationManager.heading?.trueHeading ?? 0))
        let isWeak = navigationEngine.isWeakGPSSignal

        return ZStack {
            Circle()
                .stroke((isWeak ? Color.yellow : Color(hex: "00F2FE")).opacity(radarPulse ? 0.0 : 0.7), lineWidth: 2)
                .frame(width: radarPulse ? 72 : 32, height: radarPulse ? 72 : 32)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [(isWeak ? Color.yellow : Color(hex: "0072FF")).opacity(0.55), Color.clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 26
                    )
                )
                .frame(width: 52, height: 52)

            ZStack {
                ConeLightShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.yellow.opacity(0.45), Color.clear],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 36, height: 46)
                    .offset(y: -23)

                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "FFFFFF"), Color(hex: "D8E2EC")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 18, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isWeak ? Color.yellow : Color(hex: "0052D4"), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 5, x: 0, y: 3)

                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "00C6FF"))
                        .frame(width: 12, height: 7)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(hex: "2C3E50").opacity(0.4))
                        .frame(width: 10, height: 8)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "00C6FF"))
                        .frame(width: 12, height: 4)
                }
            }
            .rotationEffect(.degrees(headingDegrees))
        }
    }

    // MARK: - 动态 3D 相机

    private func update3DNavigationCamera(with location: CLLocation) {
        let speed = max(0, location.speed)

        let currentHeading: Double
        if speed < 1.0 {
            currentHeading = locationManager.heading?.trueHeading ?? 0
        } else {
            currentHeading = (location.course >= 0 ? location.course : (locationManager.heading?.trueHeading ?? 0))
        }

        let distance: Double
        let pitch: Double

        if speed < 5.0 {
            distance = 150
            pitch = 65
        } else if speed < 16.0 {
            distance = 220
            pitch = 60
        } else {
            distance = 320
            pitch = 52
        }

        withAnimation(.easeInOut(duration: 0.4)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: location.coordinate,
                    distance: distance,
                    heading: currentHeading,
                    pitch: pitch
                )
            )
        }
    }

    // MARK: - 搜索栏与偏好栏

    private var searchAndPreferencePanel: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: "00F2FE")).frame(width: 8, height: 8)
                    TextField("起点（默认我的位置）", text: $startText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                }

                HStack(spacing: 10) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    TextField("途经点（可选）", text: $viaText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                }

                HStack(spacing: 10) {
                    Circle().fill(Color(hex: "FF416C")).frame(width: 8, height: 8)
                    TextField("输入目的地", text: $destinationText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await searchPlaces() }
                        }

                    if isSearching {
                        ProgressView().tint(Color(hex: "00F2FE"))
                    }

                    Button {
                        Task { await searchPlaces() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("搜索")
                        }
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .disabled(destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()
                .background(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("路线偏好（算法预估）")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if isCalculating {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7).tint(Color(hex: "00F2FE"))
                            Text("正在计算最优路径...")
                                .font(.caption2)
                                .foregroundStyle(Color(hex: "00F2FE"))
                        }
                    }
                }

                HStack(spacing: 8) {
                    ForEach(RoutePreference.allCases) { pref in
                        let isSelected = (selectedPreference == pref)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedPreference = pref
                            }
                            if destinationMapItem != nil || endCoordinate != nil {
                                Task { await calculateRoute() }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: pref.iconName)
                                    .font(.system(size: 11, weight: .bold))
                                Text(pref.rawValue)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                isSelected
                                ? LinearGradient(colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? Color(hex: "00F2FE") : Color.white.opacity(0.1),
                                    lineWidth: isSelected ? 1.5 : 0.5
                                )
                            )
                            .shadow(color: isSelected ? Color(hex: "0072FF").opacity(0.4) : Color.clear, radius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !displayRoutes.isEmpty {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(hex: "00F2FE"))
                        Text("已推荐 \(selectedPreference.rawValue) 最优路线")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "00F2FE"))
                    }

                    Spacer()

                    Button("清除") {
                        clearRoute()
                    }
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(hex: "10141E").opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 8)
    }

    // MARK: - 路线对比卡片

    private var routeComparisonPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(routeAssessments.enumerated()), id: \.offset) { index, item in
                        let isSelected = (index == selectedRouteIndex)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.navRoute.expectedTravelTime.formattedDuration)
                                    .font(.system(size: 22, weight: .heavy))
                                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.8))

                                Spacer()

                                if item.isRecommended {
                                    Text("最优选")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(hex: "00F2FE"))
                                        .foregroundStyle(Color.black)
                                        .clipShape(Capsule())
                                }
                            }

                            Text("全程 \(item.navRoute.distance.formattedMeters)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))

                            HStack(spacing: 5) {
                                ForEach(item.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.12))
                                        .foregroundStyle(Color(hex: "00F2FE"))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                        .frame(width: 170)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    isSelected
                                    ? Color(hex: "0052D4").opacity(0.45)
                                    : Color(hex: "10141E").opacity(0.85)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    isSelected ? Color(hex: "00F2FE") : Color.white.opacity(0.1),
                                    lineWidth: isSelected ? 2 : 0.8
                                )
                        )
                        .shadow(color: isSelected ? Color(hex: "0072FF").opacity(0.4) : Color.clear, radius: 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedRouteIndex = index
                                fitRoute()
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                Button {
                    showRouteDetails = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    swapEndpoints()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title3)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                // 开始导航主按钮
                Button {
                    guard let route = selectedRoute else { return }

                    // 1. 动态激活导航级定位与后台保活
                    locationManager.enterNavigationMode()

                    // 2. 启动引擎
                    navigationEngine.start(navRoute: route, preference: selectedPreference)
                    voiceNavigation.speak("开始3D导航，已为您选择\(selectedPreference.rawValue)路线，全程约\(route.expectedTravelTime.formattedDuration)，请注意行驶安全", isUrgent: true)

                    if let loc = locationManager.location {
                        update3DNavigationCamera(with: loc)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.north.fill")
                        Text("进入 3D 偏好导航")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: Color(hex: "0072FF").opacity(0.5), radius: 10, x: 0, y: 4)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(hex: "10141E").opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 18, x: 0, y: 8)
    }

    // MARK: - 导航仪表盘

    private var navigationDashboardView: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(navigationEngine.remainingTime.formattedDuration)
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(.white)

                        Text(navigationEngine.remainingDistance.formattedMeters)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color(hex: "00F2FE"))
                    }

                    HStack(spacing: 6) {
                        if navigationEngine.isWeakGPSSignal {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text("弱信号守护中")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.yellow)
                        } else {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text(selectedPreference.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                        Text(navigationEngine.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(navigationEngine.isOffRoute ? .orange : .white.opacity(0.7))
                    }
                }

                Spacer()

                Button {
                    if voiceNavigation.isMuted {
                        voiceNavigation.unmute()
                    } else {
                        voiceNavigation.mute()
                    }
                } label: {
                    Image(systemName: voiceNavigation.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }

                Button {
                    navigationEngine.stop()
                    voiceNavigation.stop()
                    locationManager.exitNavigationMode() // 停止导航时退出高功耗后台
                    withAnimation {
                        cameraPosition = .automatic
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(12)
                        .background(Color.red.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(hex: "10141E").opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(navigationEngine.isWeakGPSSignal ? Color.yellow.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 16, x: 0, y: 8)
    }

    // MARK: - 搜索结果列表

    private var resultsOverlay: some View {
        VStack {
            Spacer().frame(height: 160)

            VStack(spacing: 0) {
                HStack {
                    Text("搜索结果").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button("关闭") {
                        showResults = false
                    }
                    .foregroundStyle(Color(hex: "00F2FE"))
                }
                .padding()

                Divider().background(Color.white.opacity(0.12))

                if searchResults.isEmpty {
                    ContentUnavailableView(
                        "未找到相关地点",
                        systemImage: "mappin.slash",
                        description: Text("请尝试输入更具体的道路或商户名称")
                    )
                    .frame(height: 180)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(searchResults.enumerated()), id: \.offset) { index, item in
                                Button {
                                    Task {
                                        await selectDestination(item)
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(Color(hex: "00F2FE"))
                                            .font(.title2)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name ?? "未命名地点")
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)

                                            Text(item.placemark.title ?? "")
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.6))
                                                .lineLimit(2)
                                        }

                                        Spacer()
                                        Image(systemName: "arrow.up.right.circle")
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    .padding()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider().background(Color.white.opacity(0.08))
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                }
            }
            .background(Color(hex: "10141E").opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(radius: 16)

            Spacer()
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 路线详情

    private var routeDetailsSheet: some View {
        NavigationStack {
            List {
                Section("行程概要") {
                    LabeledContent("当前偏好", value: selectedPreference.rawValue)
                    LabeledContent("起点", value: startName)
                    if let via = viaMapItem?.name {
                        LabeledContent("途经点", value: via)
                    }
                    LabeledContent("终点", value: endName)

                    if let route = selectedRoute {
                        LabeledContent("行驶距离", value: route.distance.formattedMeters)
                        LabeledContent("预计时间", value: route.expectedTravelTime.formattedDuration)
                    }
                }

                if let route = selectedRoute {
                    Section("详细转向指引") {
                        ForEach(
                            Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()),
                            id: \.offset
                        ) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color(hex: "00F2FE"))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.instructions)
                                        .foregroundStyle(.white)
                                    Text(step.distance.formattedMeters)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("路线规划详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        showRouteDetails = false
                    }
                    .foregroundStyle(Color(hex: "00F2FE"))
                }
            }
        }
    }

    // MARK: - 地点搜索

    @MainActor
    private func searchPlaces() async {
        let query = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await routePlanner.searchPlace(
                query,
                near: locationManager.location?.coordinate
            )
            showResults = true

            if searchResults.isEmpty {
                errorMessage = "没有找到相关地点"
                showError = true
            }
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
            showError = true
        }
    }

    @MainActor
    private func selectDestination(_ item: MKMapItem) async {
        destinationMapItem = item
        endCoordinate = item.placemark.coordinate
        endName = item.name ?? "目的地"
        showResults = false

        await calculateRoute()
    }

    // MARK: - 综合路线计算（支持起点解析、途经点接入与多备选偏好排序）

    @MainActor
    private func calculateRoute() async {
        isCalculating = true
        defer { isCalculating = false }

        // 1. 解析起点
        let finalStartItem: MKMapItem
        let trimmedStart = startText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedStart.isEmpty || trimmedStart == "我的位置" {
            guard let currentLoc = locationManager.location else {
                errorMessage = "正在获取当前定位，请稍候..."
                showError = true
                return
            }
            finalStartItem = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
            startCoordinate = currentLoc.coordinate
            startName = "我的位置"
        } else {
            do {
                finalStartItem = try await routePlanner.geocodeAddress(
                    trimmedStart,
                    near: locationManager.location?.coordinate
                )
                startCoordinate = finalStartItem.placemark.coordinate
                startName = finalStartItem.name ?? trimmedStart
            } catch {
                errorMessage = "起点地址解析失败：\(error.localizedDescription)"
                showError = true
                return
            }
        }
        startMapItem = finalStartItem

        // 2. 检查终点
        guard let finalEndItem = destinationMapItem ?? (endCoordinate != nil ? MKMapItem(placemark: MKPlacemark(coordinate: endCoordinate!)) : nil) else {
            errorMessage = "请输入并选择目的地"
            showError = true
            return
        }

        // 3. 解析途经点
        let trimmedVia = viaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVia.isEmpty {
            do {
                let viaItem = try await routePlanner.geocodeAddress(
                    trimmedVia,
                    near: locationManager.location?.coordinate
                )
                viaMapItem = viaItem
                viaCoordinate = viaItem.placemark.coordinate
            } catch {
                errorMessage = "途经点解析失败：\(error.localizedDescription)"
                showError = true
                return
            }
        } else {
            viaMapItem = nil
            viaCoordinate = nil
        }

        // 4. 计算全程 NavRoute（直达或途经点复合路线）
        do {
            let routes: [NavRoute]
            if let via = viaMapItem {
                routes = try await routePlanner.calculateViaRoute(
                    start: finalStartItem,
                    via: via,
                    destination: finalEndItem
                )
            } else {
                routes = try await routePlanner.calculateDirectRoutes(
                    from: finalStartItem,
                    to: finalEndItem
                )
            }

            let assessments = RoutePreferenceEngine.evaluateRoutes(
                routes,
                preference: selectedPreference
            )

            routeAssessments = assessments
            displayRoutes = assessments.map { $0.navRoute }
            selectedRouteIndex = 0
            followUser = false

            fitRoute()
        } catch {
            errorMessage = "路线规划失败：\(error.localizedDescription)"
            showError = true
        }
    }

    private func swapEndpoints() {
        guard let startCoord = startCoordinate, let endCoord = endCoordinate else { return }

        let oldStartCoord = startCoord
        let oldStartName = startName
        let oldStartItem = startMapItem ?? MKMapItem(placemark: MKPlacemark(coordinate: oldStartCoord))

        let oldEndCoord = endCoord
        let oldEndName = endName
        let oldEndItem = destinationMapItem ?? MKMapItem(placemark: MKPlacemark(coordinate: oldEndCoord))

        startCoordinate = oldEndCoord
        startName = oldEndName
        startMapItem = oldEndItem
        startText = (oldEndName == "我的位置") ? "" : oldEndName

        endCoordinate = oldStartCoord
        endName = oldStartName
        destinationMapItem = oldStartItem
        destinationText = oldStartName

        Task {
            await calculateRoute()
        }
    }

    private func moveCamera(to coordinate: CLLocationCoordinate2D) {
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1200,
                    longitudinalMeters: 1200
                )
            )
        }
    }

    private func fitRoute() {
        guard let route = selectedRoute else { return }
        withAnimation {
            cameraPosition = .rect(route.combinedPolyline.boundingMapRect)
        }
    }

    private func clearRoute() {
        if navigationEngine.isNavigating {
            navigationEngine.stop()
            voiceNavigation.stop()
            locationManager.exitNavigationMode()
        }

        displayRoutes = []
        routeAssessments = []
        selectedRouteIndex = 0
        destinationMapItem = nil
        viaMapItem = nil
        viaCoordinate = nil
        endCoordinate = nil
        endName = ""
        destinationText = ""
        viaText = ""
        followUser = true
        showResults = false

        if let location = locationManager.location {
            moveCamera(to: location.coordinate)
        }
    }
}

// MARK: - 辅助扩展

extension CLLocationDistance {
    var formattedMeters: String {
        if self >= 1000 {
            return String(format: "%.1f 公里", self / 1000.0)
        } else {
            return String(format: "%.0f 米", max(0, self))
        }
    }
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

struct ConeLightShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let minutes = Int(self / 60)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 {
            return "\(hours)小时\(remainingMinutes)分钟"
        } else {
            return "\(max(1, remainingMinutes))分钟"
        }
    }
}