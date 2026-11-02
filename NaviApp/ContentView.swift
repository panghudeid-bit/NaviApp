import SwiftUI
import MapKit
import CoreLocation

// MARK: - GPS 定位管理

final class LocationManager: NSObject,
                             ObservableObject,
                             CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var authorizationStatus:
        CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startLocation() {
        manager.startUpdatingLocation()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        authorizationStatus = status

        if status == .authorizedWhenInUse ||
           status == .authorizedAlways {
            startLocation()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }

        DispatchQueue.main.async {
            self.location = latest
        }
    }
}

// MARK: - 导航主界面

struct ContentView: View {

    @StateObject private var locationManager =
        LocationManager()

    @State private var cameraPosition:
        MapCameraPosition = .automatic

    @State private var destinationText = ""

    @State private var destination: MKMapItem?

    @State private var route: MKRoute?

    @State private var isSearching = false

    @State private var errorMessage = ""

    @State private var showError = false

    var body: some View {

        ZStack(alignment: .top) {

            // 地图
            Map(position: $cameraPosition) {

                UserAnnotation()

                if let route = route {
                    MapPolyline(
                        route.polyline
                    )
                    .stroke(
                        .blue,
                        lineWidth: 6
                    )
                }

                if let destination = destination {
                    Marker(
                        destination.name ?? "目的地",
                        coordinate:
                            destination.placemark.coordinate
                    )
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            // 顶部搜索框
            VStack(spacing: 12) {

                HStack {

                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(
                        "搜索目的地",
                        text: $destinationText
                    )
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            await searchDestination()
                        }
                    }

                    if !destinationText.isEmpty {
                        Button {
                            destinationText = ""
                            destination = nil
                            route = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await searchDestination()
                        }
                    } label: {
                        Text("搜索")
                            .fontWeight(.semibold)
                    }
                    .disabled(
                        destinationText
                            .trimmingCharacters(
                                in: .whitespaces
                            )
                            .isEmpty
                    )
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(
                    RoundedRectangle(cornerRadius: 16)
                )
                .shadow(radius: 4)

                Spacer()

                // 底部路线信息
                if let route = route {

                    VStack(spacing: 12) {

                        HStack {

                            VStack(alignment: .leading) {

                                Text(
                                    route.expectedTravelTime
                                    .formattedDuration()
                                )
                                .font(.title)
                                .fontWeight(.bold)

                                Text(
                                    String(
                                        format: "距离 %.1f 公里",
                                        route.distance / 1000
                                    )
                                )
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(
                                systemName: "car.fill"
                            )
                            .font(.largeTitle)
                            .foregroundStyle(.blue)
                        }

                        Button {
                            withAnimation {
                                cameraPosition =
                                    .rect(
                                        route.polyline
                                            .boundingMapRect
                                    )
                            }
                        } label: {

                            Text("查看完整路线")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.blue)
                                .foregroundStyle(.white)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 12
                                    )
                                )
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 20)
                    )
                    .shadow(radius: 5)
                    .padding()
                }
            }
            .padding(.horizontal)
            .padding(.top, 60)
        }
        .onAppear {
            locationManager.requestPermission()
        }
        .onChange(
            of: locationManager.location
        ) {
            if let location =
                locationManager.location {

                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: location.coordinate,
                        latitudinalMeters: 1000,
                        longitudinalMeters: 1000
                    )
                )
            }
        }
        .alert(
            "提示",
            isPresented: $showError
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 搜索目的地

    @MainActor
    private func searchDestination() async {

        let query = destinationText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !query.isEmpty else { return }

        isSearching = true

        defer {
            isSearching = false
        }

        let request = MKLocalSearch.Request()

        request.naturalLanguageQuery = query

        if let location =
            locationManager.location {

            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 30000,
                longitudinalMeters: 30000
            )
        }

        do {

            let search = MKLocalSearch(
                request: request
            )

            let response = try await search.start()

            guard let result =
                response.mapItems.first else {

                errorMessage = "没有找到该目的地"
                showError = true
                return
            }

            destination = result

            await calculateRoute(
                to: result
            )

        } catch {

            errorMessage =
                "搜索失败：\(error.localizedDescription)"

            showError = true
        }
    }

    // MARK: - 路线规划

    @MainActor
    private func calculateRoute(
        to destination: MKMapItem
    ) async {

        guard let currentLocation =
            locationManager.location else {

            errorMessage = "尚未获取到当前位置"
            showError = true
            return
        }

        let request = MKDirections.Request()

        request.source = MKMapItem(
            placemark: MKPlacemark(
                coordinate:
                    currentLocation.coordinate
            )
        )

        request.destination = destination

        request.transportType = .automobile

        do {

            let directions = MKDirections(
                request: request
            )

            let response =
                try await directions.calculate()

            guard let bestRoute =
                response.routes.first else {

                errorMessage = "无法规划路线"
                showError = true
                return
            }

            route = bestRoute

            withAnimation {

                cameraPosition = .rect(
                    bestRoute.polyline
                        .boundingMapRect
                )
            }

        } catch {

            errorMessage =
                "路线规划失败：\(error.localizedDescription)"

            showError = true
        }
    }
}

// MARK: - 时间格式化

extension TimeInterval {

    func formattedDuration() -> String {

        let minutes = Int(self / 60)

        let hours = minutes / 60

        let remainingMinutes = minutes % 60

        if hours > 0 {

            return "\(hours)小时\(remainingMinutes)分钟"

        } else {

            return "\(remainingMinutes)分钟"
        }
    }
}

#Preview {
    ContentView()
}
