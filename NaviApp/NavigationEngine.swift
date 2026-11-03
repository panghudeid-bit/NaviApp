import Foundation
import MapKit
import CoreLocation

@MainActor
final class NavigationEngine: ObservableObject {

    @Published var isNavigating = false
    @Published var currentLocation: CLLocation?
    @Published var currentRoute: MKRoute?

    @Published var remainingDistance: CLLocationDistance = 0
    @Published var remainingTime: TimeInterval = 0

    @Published var isOffRoute = false
    @Published var hasArrived = false

    @Published var statusMessage = "等待开始导航"

    @Published var currentStepIndex: Int = 0
    @Published var nextStepInstruction: String = ""

    private var destination: MKMapItem?
    private var lastRerouteTime = Date.distantPast
    private var isRerouting = false

    // 回调通知
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?
    var onStepAdvance: ((String) -> Void)?
    var onRerouted: ((MKRoute) -> Void)?

    /// 开始导航
    func start(route: MKRoute, destination: MKMapItem) {
        self.currentRoute = route
        self.destination = destination

        self.isNavigating = true
        self.hasArrived = false
        self.isOffRoute = false

        self.remainingDistance = route.distance
        self.remainingTime = route.expectedTravelTime

        self.currentStepIndex = 0

        // 获取第一个有效的指示步骤
        if let firstValidStep = route.steps.first(where: { !$0.instructions.isEmpty }) {
            self.nextStepInstruction = firstValidStep.instructions
        } else {
            self.nextStepInstruction = "沿当前道路直行"
        }

        self.statusMessage = "导航进行中"
    }

    /// 停止导航
    func stop() {
        self.isNavigating = false
        self.isOffRoute = false
        self.hasArrived = false
        self.statusMessage = "导航已结束"
    }

    /// 核心位置更新驱动
    func updateLocation(_ location: CLLocation) {
        currentLocation = location

        guard isNavigating,
              let route = currentRoute,
              let destination = destination else {
            return
        }

        // 1. 到达终点判断（距离目的地 35 米以内视为已到达）
        let destinationLocation = CLLocation(
            latitude: destination.placemark.coordinate.latitude,
            longitude: destination.placemark.coordinate.longitude
        )

        let distanceToDestination = location.distance(from: destinationLocation)

        if distanceToDestination < 35 {
            if !hasArrived {
                onArrival?()
            }
            hasArrived = true
            isNavigating = false
            statusMessage = "已到达目的地"
            return
        }

        // 2. 偏航检测：计算当前位置到规划折线的垂直距离
        let distanceToRoute = distanceFromRoute(location.coordinate, route.polyline)

        // 偏航阈值设为 60 米（防止高架、峡谷漂移误触）
        if distanceToRoute > 60 {
            if !isOffRoute {
                onOffRoute?()
            }
            isOffRoute = true
            statusMessage = "正在重新规划路线"

            Task {
                await reroute(from: location, to: destination)
            }
        } else {
            isOffRoute = false
            statusMessage = "导航进行中"

            // 3. 沿路线累积计算真实剩余距离、时间和转向步骤提示
            updateRemainingProgress(location, route: route)
        }
    }

    /// 计算指定点到折线段的最小垂距
    private func distanceFromRoute(
        _ coordinate: CLLocationCoordinate2D,
        _ polyline: MKPolyline
    ) -> CLLocationDistance {
        let userPoint = MKMapPoint(coordinate)
        guard polyline.pointCount >= 2 else {
            return .greatestFiniteMagnitude
        }

        let points = polyline.points()
        var minimumDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in 0..<(polyline.pointCount - 1) {
            let a = points[index]
            let b = points[index + 1]

            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy

            let t: Double
            if lengthSquared == 0 {
                t = 0
            } else {
                t = max(0, min(1, ((userPoint.x - a.x) * dx + (userPoint.y - a.y) * dy) / lengthSquared))
            }

            let nearestPoint = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = userPoint.distance(to: nearestPoint)
            minimumDistance = min(minimumDistance, distance)
        }

        return minimumDistance
    }

    /// 偏航重规划
    private func reroute(from location: CLLocation, to destination: MKMapItem) async {
        // 频率限制节流保护（至少间隔 8 秒）
        guard !isRerouting, Date().timeIntervalSince(lastRerouteTime) > 8 else {
            return
        }

        isRerouting = true
        lastRerouteTime = Date()
        defer { isRerouting = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        request.destination = destination
        request.transportType = .automobile

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let newRoute = response.routes.first else { return }

            self.currentRoute = newRoute
            self.remainingDistance = newRoute.distance
            self.remainingTime = newRoute.expectedTravelTime
            self.isOffRoute = false
            self.statusMessage = "已重新规划路线"

            // 更新步骤指示
            self.currentStepIndex = 0
            if let firstStep = newRoute.steps.first(where: { !$0.instructions.isEmpty }) {
                self.nextStepInstruction = firstStep.instructions
                self.onStepAdvance?(self.nextStepInstruction)
            }

            // 同步通知外层界面刷新绘制
            self.onRerouted?(newRoute)
        } catch {
            self.statusMessage = "重新规划失败，请检查网络"
        }
    }

    /// 更新行驶进度与转向引导
    private func updateRemainingProgress(_ location: CLLocation, route: MKRoute) {
        let polyline = route.polyline
        guard polyline.pointCount >= 2 else { return }

        let points = polyline.points()
        let userPoint = MKMapPoint(location.coordinate)

        var cumulativeDistance: CLLocationDistance = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var distanceAlongRoute: CLLocationDistance = 0

        // 沿折线计算用户已行驶距离
        for index in 0..<(polyline.pointCount - 1) {
            let a = points[index]
            let b = points[index + 1]
            let segmentLength = a.distance(to: b)

            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy

            let t: Double
            if lengthSquared == 0 {
                t = 0
            } else {
                t = max(0, min(1, ((userPoint.x - a.x) * dx + (userPoint.y - a.y) * dy) / lengthSquared))
            }

            let nearestPoint = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = userPoint.distance(to: nearestPoint)

            if distance < bestDistance {
                bestDistance = distance
                distanceAlongRoute = cumulativeDistance + segmentLength * t
            }

            cumulativeDistance += segmentLength
        }

        // 更新剩余总距离与时间
        remainingDistance = max(0, route.distance - distanceAlongRoute)
        let remainingRatio = route.distance > 0 ? remainingDistance / route.distance : 0
        remainingTime = route.expectedTravelTime * remainingRatio

        // 步骤跟踪：根据已行驶距离判定当前步骤
        var stepCumulative: CLLocationDistance = 0
        var detectedStepIndex = 0

        for (index, step) in route.steps.enumerated() {
            stepCumulative += step.distance
            if distanceAlongRoute < stepCumulative {
                detectedStepIndex = index
                break
            }
        }

        if detectedStepIndex != currentStepIndex && detectedStepIndex < route.steps.count {
            currentStepIndex = detectedStepIndex
            let instruction = route.steps[detectedStepIndex].instructions
            if !instruction.isEmpty {
                nextStepInstruction = instruction
                onStepAdvance?(instruction)
            }
        }
    }
}
