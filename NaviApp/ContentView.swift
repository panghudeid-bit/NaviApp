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
        // 针对车载导航优化定位配置
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 3.0 // 每移动 3 米更新一次，平衡灵敏度与电量消耗
        manager.pausesLocationUpdatesAutomatically = false // 导航中不自动暂停定位
    }

    /// 请求定位权限并在已有权限时立即启动定位
    func requestPermission() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        }
    }

    /// 开启定位与方向监测
    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// 停止定位更新
    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // iOS 14+ 推荐的授权变更回调
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    // 兼容 iOS 14 之前的旧版本方法
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

    // 地图镜头位置（iOS 17+）
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

    private var selectedRoute: MKRoute? {
        guard selectedRouteIndex < displayRoutes.count else { return nil }
        return displayRoutes[selectedRouteIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {

            // 地图主体
            Map(position: $cameraPosition) {
                UserAnnotation()

                ForEach(Array(displayRoutes.enumerated()), id: \.offset) { index, route in
                    MapPolyline(route.polyline)
                        .stroke(
                            index == selectedRouteIndex ? Color.blue : Color.gray.opacity(0.65),
                            lineWidth: index == selectedRouteIndex ? 7 : 4
                        )
                }

                if let end = endCoordinate {
                    Marker(
                        endName.isEmpty ? "目的地" : endName,
                        coordinate: end
                    )
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            // 浮动面板与搜索层
            VStack(spacing: 12) {
                if !navigationEngine.isNavigating {
                    searchPanel
                }

                Spacer()

                if let route = selectedRoute {
                    routePanel(route)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, navigationEngine.isNavigating ? 48 : 58)
            .padding(.bottom, 12)

            // 搜索结果覆盖层
            if showResults {
                resultsOverlay
            }
        }
        .onAppear {
            locationManager.requestPermission()

            // 绑定语音与导航事件回调
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

            // 偏航重规划成功后，同步刷新地图上的渲染折线
            navigationEngine.onRerouted = { newRoute in
                displayRoutes = [newRoute]
                selectedRouteIndex = 0
            }
        }
        .onChange(of: locationManager.location) { newLocation in
            guard let newLocation = newLocation else { return }

            if startCoordinate == nil {
                startCoordinate = newLocation.coordinate
            }

            // 核心驱动：传递最新 GPS 坐标至导航引擎
            navigationEngine.updateLocation(newLocation)

            // 视角控制：导航中保持车头朝向跟随；未导航时若开启跟随则居中显示
            if navigationEngine.isNavigating {
                withAnimation(.linear(duration: 0.3)) {
                    cameraPosition = .userLocation(followsHeading: true, fallback: .camera)
                }
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

    // MARK: 搜索栏

    private var searchPanel: some View {
        VStack(spacing: 12) {
            // 起点
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 8, height: 8)
                TextField("起点（默认我的位置）", text: $startText)
                    .textFieldStyle(.plain)
            }

            // 途经点
            HStack(spacing: 10) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                TextField("途经点（可选）", text: $viaText)
                    .textFieldStyle(.plain)
            }

            // 终点 + 搜索按钮
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
                    Label("路线已规划", systemImage: "checkmark.circle.fill")
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
                            ? String(format: "剩余 %.1f 公里", navigationEngine.remainingDistance / 1000)
                            : String(format: "全程 %.1f 公里", route.distance / 1000)
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "car.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
            }

            // 导航中实时提示条
            if navigationEngine.isNavigating {
                VStack(alignment: .leading, spacing: 8) {
                    if !navigationEngine.nextStepInstruction.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.up.right.diamond.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Text(navigationEngine.nextStepInstruction)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }

                    if navigationEngine.isOffRoute {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("已偏离路线，正在重新规划...")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            // 按钮操作区
            if navigationEngine.isNavigating {
                // 导航中：结束导航按钮与静音开关
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
                // 未开始导航：路线详情、全览路线、交换与开始导航
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
                    voiceNavigation.speak("导航开始，全程约\(route.expectedTravelTime.formattedDuration)，请系好安全带，安全行驶")

                    // 镜头切换为车头跟随视角
                    withAnimation {
                        cameraPosition = .userLocation(followsHeading: true, fallback: .camera)
                    }
                } label: {
                    Label("开始导航", systemImage: "location.north.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
