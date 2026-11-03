import SwiftUI
import MapKit
import CoreLocation

// MARK: - 定位管理

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 2.0 // 2 米更新一次，提供极为细腻的 3D 航向平滑
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
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
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        authorizationStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        location = latest
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        heading = newHeading
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("定位失败：\(error.localizedDescription)")
    }
}

// MARK: - 主界面

struct ContentView: View {

    @StateObject private var locationManager = LocationManager()
    @StateObject private var navigationEngine = NavigationEngine()
    @StateObject private var voiceNavigation = VoiceNavigation()

    // iOS 17+ 3D 沉浸式相机
    @State private var cameraPosition: MapCameraPosition = .automatic

    @State private var destinationText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var selectedDestination: MKMapItem?

    @State private var displayRoutes: [MKRoute] = []
    @State private var selectedRouteIndex: Int = 0

    @State private var startText = ""
    @State private var viaText = ""

    @State private var startCoordinate: CLLocationCoordinate2D?
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

    // 拟真 3D 脉冲动画开关
    @State private var radarPulse = false

    private var selectedRoute: MKRoute? {
        guard selectedRouteIndex < displayRoutes.count else { return nil }
        return displayRoutes[selectedRouteIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {

            // 1. 3D 真实地形与建筑地图
            Map(position: $cameraPosition) {

                // 自定义 3D 车道级拟真车模与雷达脉冲光标（替代默认蓝点）
                if let loc = locationManager.location {
                    Annotation("当前位置", coordinate: loc.coordinate) {
                        car3DMarker(location: loc)
                    }
                }

                // 2. 立体车道级多层渲染（3D 管道阴影底座 + 渐变车道路面 + 核心发光引导带）
                ForEach(Array(displayRoutes.enumerated()), id: \.offset) { index, route in
                    let isCurrent = (index == selectedRouteIndex)

                    if isCurrent {
                        // 底层：3D 立体路面沥青投影层
                        MapPolyline(route.polyline)
                            .stroke(
                                Color.black.opacity(0.35),
                                style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round)
                            )

                        // 中层：真实车道级深蓝高附着路面
                        MapPolyline(route.polyline)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.05, green: 0.35, blue: 0.95),
                                        Color(red: 0.00, green: 0.65, blue: 1.00)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                            )

                        // 顶层：车道核心高光发光流光带
                        MapPolyline(route.polyline)
                            .stroke(
                                Color.cyan.opacity(0.9),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                            )
                    } else {
                        // 备选路线
                        MapPolyline(route.polyline)
                            .stroke(
                                Color.gray.opacity(0.5),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                            )
                    }
                }

                // 终点立标
                if let end = endCoordinate {
                    Marker(
                        endName.isEmpty ? "目的地" : endName,
                        coordinate: end
                    )
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.parking, .gasStation])))
            .mapControls {
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }
            .ignoresSafeArea()

            // 浮动面板层
            VStack(spacing: 12) {
                if navigationEngine.isNavigating {
                    // 导航中：顶部悬浮 3D 车道级指示栏
                    LaneGuidanceView(
                        lanes: navigationEngine.currentLanes,
                        nextTurnInstruction: navigationEngine.nextStepInstruction,
                        distanceToNextStep: navigationEngine.distanceToNextTurn
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    searchPanel
                }

                Spacer()

                if let route = selectedRoute {
                    routePanel(route)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, navigationEngine.isNavigating ? 50 : 58)
            .padding(.bottom, 12)

            // 搜索结果
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
                withAnimation {
                    cameraPosition = .automatic
                }
            }

            navigationEngine.onStepAdvance = { instruction in
                voiceNavigation.speak(instruction)
            }

            // 车道级变道播报
            navigationEngine.onLaneAdvise = { laneText in
                voiceNavigation.speak(laneText)
            }

            navigationEngine.onRerouted = { newRoute in
                displayRoutes = [newRoute]
                selectedRouteIndex = 0
            }

            // 启动雷达光波动画
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                radarPulse = true
            }
        }
        .onChange(of: locationManager.location) { newLocation in
            guard let newLocation = newLocation else { return }

            if startCoordinate == nil {
                startCoordinate = newLocation.coordinate
            }

            navigationEngine.updateLocation(newLocation)

            // 导航视角自适应插值更新：实时 3D 俯仰与视距控制
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

    // MARK: - 3D 拟真车模与雷达脉冲光标

    private func car3DMarker(location: CLLocation) -> some View {
        let headingDegrees = (location.course >= 0 ? location.course : (locationManager.heading?.trueHeading ?? 0))

        return ZStack {
            // 扩散雷达波
            Circle()
                .stroke(Color.cyan.opacity(radarPulse ? 0.0 : 0.6), lineWidth: 2)
                .frame(width: radarPulse ? 70 : 30, height: radarPulse ? 70 : 30)

            // 车辆光晕底座
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.5), Color.clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: 24
                    )
                )
                .frame(width: 48, height: 48)

            // 3D 拟真车模外观（立体渐变箭头、车头大灯光束）
            ZStack {
                // 车灯远光照射效果
                ConeLightShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.yellow.opacity(0.4), Color.clear],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 38, height: 44)
                    .offset(y: -22)

                // 立体小车模底壳
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 18, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.blue, lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 3)

                // 车窗与车顶涂装
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: 12, height: 7)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 10, height: 8)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: 12, height: 4)
                }
            }
            .rotationEffect(.degrees(headingDegrees))
        }
    }

    // MARK: - 3D 导航动态视距计算

    private func update3DNavigationCamera(with location: CLLocation) {
        let currentHeading = (location.course >= 0 ? location.course : (locationManager.heading?.trueHeading ?? 0))
        let speed = max(0, location.speed) // 单位：米/秒

        // 智能视距控制：低速（路口/转弯）拉近并加大仰角；高速拉远开阔视野
        let distance: Double
        let pitch: Double

        if speed < 5.0 {
            // 时速 < 18km/h（路口待转/起步）：超近景 3D 沉浸式俯仰
            distance = 150
            pitch = 65
        } else if speed < 16.0 {
            // 时速 18~60km/h（市区道路）
            distance = 220
            pitch = 60
        } else {
            // 高速行驶
            distance = 320
            pitch = 52
        }

        withAnimation(.easeInOut(duration: 0.5)) {
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

    // MARK: 搜索栏

    private var searchPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 8, height: 8)
                TextField("起点（默认我的位置）", text: $startText)
                    .textFieldStyle(.plain)
            }

            HStack(spacing: 10) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                TextField("途经点（可选）", text: $viaText)
                    .textFieldStyle(.plain)
            }

            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 8, height: 8)
                TextField("输入目的地", text: $destinationText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchPlaces() }
                    }

                if isSearching {
                    ProgressView()
                }

                Button("搜索") {
                    Task { await searchPlaces() }
                }
                .fontWeight(.semibold)
                .disabled(destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !displayRoutes.isEmpty {
                Divider()
                HStack {
                    Label("3D 路线已规划", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("清除路线") {
                        clearRoute()
                    }
                    .foregroundStyle(.red)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4)
    }

    // MARK: 搜索结果列表

    private var resultsOverlay: some View {
        VStack {
            Spacer().frame(height: 125)

            VStack(spacing: 0) {
                HStack {
                    Text("搜索结果").font(.headline)
                    Spacer()
                    Button("关闭") {
                        showResults = false
                    }
                }
                .padding()

                Divider()

                if searchResults.isEmpty {
                    ContentUnavailableView(
                        "没有搜索结果",
                        systemImage: "magnifyingglass",
                        description: Text("请尝试输入更具体的地点名称")
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
                                        Image(systemName: "mappin.and.ellipse")
                                            .foregroundStyle(.blue)
                                            .font(.title3)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name ?? "未命名地点")
                                                .fontWeight(.medium)
                                                .foregroundStyle(.primary)

                                            Text(item.placemark.title ?? "")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 350)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 5)

            Spacer()
        }
        .padding(.horizontal, 14)
    }

    // MARK: 路线与导航控制面板

    private func routePanel(_ route: MKRoute) -> some View {
        VStack(spacing: 14) {

            // 头部：总里程与时间信息
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        navigationEngine.isNavigating
                            ? navigationEngine.remainingTime.formattedDuration
                            : route.expectedTravelTime.formattedDuration
                    )
                    .font(.system(size: 28, weight: .bold))

                    Text(
                        navigationEngine.isNavigating
                            ? String(format: "剩余 %.1f 公里 · 3D 车道导航中", navigationEngine.remainingDistance / 1000)
                            : String(format: "全程 %.1f 公里", route.distance / 1000)
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "car.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
            }

            // 按钮操作区
            if navigationEngine.isNavigating {
                HStack(spacing: 12) {
                    Button {
                        navigationEngine.stop()
                        withAnimation {
                            cameraPosition = .automatic
                        }
                    } label: {
                        Label("结束导航", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        if voiceNavigation.isMuted {
                            voiceNavigation.unmute()
                        } else {
                            voiceNavigation.mute()
                        }
                    } label: {
                        Image(systemName: voiceNavigation.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title3)
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        showRouteDetails = true
                    } label: {
                        Label("路线详情", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        fitRoute()
                    } label: {
                        Label("全览路线", systemImage: "arrow.up.left.and.arrow.down.right")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button {
                    swapEndpoints()
                } label: {
                    Label("交换起点和终点", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }

                // 开始导航主按钮
                Button {
                    guard let route = selectedRoute, let destination = selectedDestination else { return }

                    navigationEngine.start(route: route, destination: destination)
                    voiceNavigation.speak("开始车道级3D导航，全程约\(route.expectedTravelTime.formattedDuration)，请沿当前车道行驶")

                    if let loc = locationManager.location {
                        update3DNavigationCamera(with: loc)
                    }
                } label: {
                    HStack {
                        Image(systemName: "location.north.fill")
                        Text("进入车道级 3D 导航")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: Color.blue.opacity(0.35), radius: 8, x: 0, y: 4)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(radius: 5)
    }

    // MARK: 路线详情

    private var routeDetailsSheet: some View {
        NavigationStack {
            List {
                Section("行程信息") {
                    LabeledContent("起点", value: startName)
                    LabeledContent("终点", value: endName)

                    if let route = selectedRoute {
                        LabeledContent("行驶距离", value: String(format: "%.1f 公里", route.distance / 1000))
                        LabeledContent("预计时间", value: route.expectedTravelTime.formattedDuration)
                    }
                }

                if let route = selectedRoute {
                    Section("路线指示步骤") {
                        ForEach(
                            Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()),
                            id: \.offset
                        ) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.instructions)
                                    Text(String(format: "%.0f 米", step.distance))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("路线详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        showRouteDetails = false
                    }
                }
            }
        }
    }

    // MARK: 搜索地点

    @MainActor
    private func searchPlaces() async {
        let query = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let location = locationManager.location {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            searchResults = response.mapItems
            showResults = true

            if response.mapItems.isEmpty {
                errorMessage = "没有找到相关地点"
                showError = true
            }
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: 选择目的地

    @MainActor
    private func selectDestination(_ item: MKMapItem) async {
        selectedDestination = item
        endCoordinate = item.placemark.coordinate
        endName = item.name ?? "目的地"
        showResults = false

        await calculateRoute()
    }

    // MARK: 计算路线

    @MainActor
    private func calculateRoute() async {
        guard let start = startCoordinate, let end = endCoordinate else {
            errorMessage = "无法获取起点或终点，请检查定位权限"
            showError = true
            return
        }

        isCalculating = true
        defer { isCalculating = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile

        do {
            let response = try await MKDirections(request: request).calculate()

            guard response.routes.first != nil else {
                errorMessage = "没有可用的驾车路线"
                showError = true
                return
            }

            displayRoutes = response.routes
            selectedRouteIndex = 0
            followUser = false

            fitRoute()
        } catch {
            errorMessage = "路线规划失败：\(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: 交换起点和终点

    private func swapEndpoints() {
        guard let start = startCoordinate, let end = endCoordinate else { return }

        startCoordinate = end
        endCoordinate = start

        let previousStartName = startName
        startName = endName
        endName = previousStartName

        Task {
            await calculateRoute()
        }
    }

    // MARK: 地图操作

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
            cameraPosition = .rect(route.polyline.boundingMapRect)
        }
    }

    private func clearRoute() {
        if navigationEngine.isNavigating {
            navigationEngine.stop()
        }

        displayRoutes = []
        selectedRouteIndex = 0
        selectedDestination = nil
        endCoordinate = nil
        endName = ""
        destinationText = ""
        followUser = true
        showResults = false

        if let location = locationManager.location {
            moveCamera(to: location.coordinate)
        }
    }
}

// MARK: - 车灯锥形渐变形状

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

// MARK: - 时间格式化

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
