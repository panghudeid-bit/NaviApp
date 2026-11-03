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
    @Published var distanceToNextTurn: Double = 0

    // 车道级 3D 导航状态
    @Published var currentLanes: [LaneInfo] = []
    private var lastAnnouncedLaneIndex: Int = -1

    // 🌟 隧道与弱信号守护状态
    @Published var isWeakGPSSignal = false
    private var consecutiveOffRouteCount = 0 // 连续偏航确认计数器（防突发单点漂移）
    private var lastValidGPSTimestamp: TimeInterval = 0

    private var destination: MKMapItem?
    private var currentPreference: RoutePreference = .leastCongested

    private var isRerouting = false
    private var rerouteTask: Task<Void, Never>?
    private var lastRerouteTimestamp: TimeInterval = 0

    // 事件通知
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?
    var onStepAdvance: ((String) -> Void)?
    var onLaneAdvise: ((String) -> Void)?
    var onRerouted: ((MKRoute) -> Void)?

    func start(
        route: MKRoute,
        destination: MKMapItem,
        preference: RoutePreference = .leastCongested
    ) {
        self.currentRoute = route
        self.destination = destination
        self.currentPreference = preference

        self.isNavigating = true
        self.hasArrived = false
        self.isOffRoute = false
        self.isWeakGPSSignal = false
        self.consecutiveOffRouteCount = 0

        self.remainingDistance = route.distance
        self.remainingTime = route.expectedTravelTime

        self.currentStepIndex = 0
        self.lastAnnouncedLaneIndex = -1
        self.lastValidGPSTimestamp = Date().timeIntervalSince1970

        if let firstValidStep = route.steps.first(where: { !$0.instructions.isEmpty }) {
            self.nextStepInstruction = firstValidStep.instructions
            self.distanceToNextTurn = firstValidStep.distance
            self.currentLanes = synthesizeLanes(for: firstValidStep.instructions)
        } else {
            self.nextStepInstruction = "沿当前道路直行"
            self.distanceToNextTurn = 500
            self.currentLanes = synthesizeLanes(for: "直行")
        }

        self.statusMessage = "3D 车道级导航中"
    }

    func stop() {
        self.isNavigating = false
        self.isOffRoute = false
        self.hasArrived = false
        self.isWeakGPSSignal = false
        self.currentLanes = []
        self.rerouteTask?.cancel()
        self.statusMessage = "导航已结束"
    }

    /// 核心位置更新驱动（增加隧道与弱信号过滤守卫）
    func updateLocation(
        _ location: CLLocation,
        preference: RoutePreference = .leastCongested
    ) {
        currentLocation = location
        self.currentPreference = preference

        guard isNavigating,
              let route = currentRoute,
              let destination = destination else {
            return
        }

        // ==========================================
        // 🛡️ 核心守卫：隧道与 GPS 弱信号检测
        // ==========================================
        // 1. 水平精度判断（horizontalAccuracy < 0 为无效定位；大于 35 米说明信号严重遮挡或漂移）
        let accuracy = location.horizontalAccuracy
        let isAccuracyPoor = (accuracy < 0 || accuracy > 35.0)

        // 2. 时间戳陈旧性判断（超过 6 秒未收到新卫星信号，判定为断点或长隧道）
        let now = Date().timeIntervalSince1970
        let isDataStale = abs(location.timestamp.timeIntervalSinceNow) > 6.0

        if isAccuracyPoor || isDataStale {
            self.isWeakGPSSignal = true
            self.statusMessage = "🛰️ 进入隧道/信号弱，保持规划"
            self.consecutiveOffRouteCount = 0 // 弱信号期间清空偏航计数

            // 弱信号或隧道内：严禁触发重新规划！沿路线继续推算进度
            updateRemainingProgress(location, route: route)
            return
        } else {
            self.isWeakGPSSignal = false
            self.lastValidGPSTimestamp = now
        }

        // 3. 到达判断（距离终点 35 米以内）
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
            currentLanes = []
            statusMessage = "已到达目的地"
            return
        }

        // 4. 高精度下的偏航检测（结合双重连续确认防抖）
        let distanceToRoute = distanceFromRoute(location.coordinate, route.polyline)

        if distanceToRoute > 45 {
            consecutiveOffRouteCount += 1

            // 必须连续 2 次以上在高精度下确认偏离，才判定为真实偏航（彻底消灭单点跳变误判）
            if consecutiveOffRouteCount >= 2 {
                if !isOffRoute {
                    onOffRoute?()
                }
                isOffRoute = true
                statusMessage = "正在重新规划最优路线..."
                triggerImmediateReroute(from: location, to: destination, preference: currentPreference)
            }
        } else {
            consecutiveOffRouteCount = 0
            isOffRoute = false
            statusMessage = "3D 导航中"
            updateRemainingProgress(location, route: route)
        }
    }

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

    private func triggerImmediateReroute(
        from location: CLLocation,
        to destination: MKMapItem,
        preference: RoutePreference
    ) {
        let now = Date().timeIntervalSince1970
        guard now - lastRerouteTimestamp > 1.5 else { return }
        lastRerouteTimestamp = now

        rerouteTask?.cancel()
        rerouteTask = Task {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
            request.destination = destination
            request.transportType = .automobile
            request.requestsAlternateRoutes = true

            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled, !response.routes.isEmpty else { return }

                let assessments = RoutePreferenceEngine.evaluateRoutes(
                    response.routes,
                    preference: preference
                )

                guard let bestRoute = assessments.first?.route else { return }

                self.currentRoute = bestRoute
                self.remainingDistance = bestRoute.distance
                self.remainingTime = bestRoute.expectedTravelTime
                self.isOffRoute = false
                self.consecutiveOffRouteCount = 0
                self.statusMessage = "已重新规划 \(preference.rawValue) 路线"

                self.currentStepIndex = 0
                if let firstStep = bestRoute.steps.first(where: { !$0.instructions.isEmpty }) {
                    self.nextStepInstruction = firstStep.instructions
                    self.distanceToNextTurn = firstStep.distance
                    self.currentLanes = self.synthesizeLanes(for: firstStep.instructions)
                    self.onStepAdvance?(self.nextStepInstruction)
                }

                self.onRerouted?(bestRoute)
            } catch {
                if !Task.isCancelled {
                    self.statusMessage = "重算路线中，请稍候..."
                }
            }
        }
    }

    private func updateRemainingProgress(_ location: CLLocation, route: MKRoute) {
        let polyline = route.polyline
        guard polyline.pointCount >= 2 else { return }

        let points = polyline.points()
        let userPoint = MKMapPoint(location.coordinate)

        var cumulativeDistance: CLLocationDistance = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var distanceAlongRoute: CLLocationDistance = 0

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

        remainingDistance = max(0, route.distance - distanceAlongRoute)
        let remainingRatio = route.distance > 0 ? remainingDistance / route.distance : 0
        remainingTime = route.expectedTravelTime * remainingRatio

        var stepCumulative: CLLocationDistance = 0
        var detectedStepIndex = 0

        for (index, step) in route.steps.enumerated() {
            stepCumulative += step.distance
            if distanceAlongRoute < stepCumulative {
                detectedStepIndex = index
                distanceToNextTurn = max(0, stepCumulative - distanceAlongRoute)
                break
            }
        }

        if detectedStepIndex != currentStepIndex && detectedStepIndex < route.steps.count {
            currentStepIndex = detectedStepIndex
            let instruction = route.steps[detectedStepIndex].instructions
            if !instruction.isEmpty {
                nextStepInstruction = instruction
                currentLanes = synthesizeLanes(for: instruction)
                onStepAdvance?(instruction)
            }
        }

        if distanceToNextTurn < 500 && distanceToNextTurn > 250 && lastAnnouncedLaneIndex != currentStepIndex {
            lastAnnouncedLaneIndex = currentStepIndex
            let laneAdvise = generateLaneSpeechAdvice(for: nextStepInstruction)
            if !laneAdvise.isEmpty {
                onLaneAdvise?(laneAdvise)
            }
        }
    }

    private func synthesizeLanes(for instruction: String) -> [LaneInfo] {
        let text = instruction.lowercased()

        if text.contains("左转") || text.contains("左拐") {
            return [
                LaneInfo(direction: .left, isRecommended: true),
                LaneInfo(direction: .straightLeft, isRecommended: true),
                LaneInfo(direction: .straight, isRecommended: false),
                LaneInfo(direction: .right, isRecommended: false)
            ]
        } else if text.contains("右转") || text.contains("右拐") || text.contains("匝道") || text.contains("出口") {
            return [
                LaneInfo(direction: .left, isRecommended: false),
                LaneInfo(direction: .straight, isRecommended: false),
                LaneInfo(direction: .straightRight, isRecommended: true),
                LaneInfo(direction: .right, isRecommended: true)
            ]
        } else if text.contains("掉头") {
            return [
                LaneInfo(direction: .uTurn, isRecommended: true),
                LaneInfo(direction: .left, isRecommended: false),
                LaneInfo(direction: .straight, isRecommended: false),
                LaneInfo(direction: .right, isRecommended: false)
            ]
        } else {
            return [
                LaneInfo(direction: .left, isRecommended: false),
                LaneInfo(direction: .straight, isRecommended: true),
                LaneInfo(direction: .straight, isRecommended: true),
                LaneInfo(direction: .right, isRecommended: false)
            ]
        }
    }

    private func generateLaneSpeechAdvice(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("左转") {
            return "前方请向左变道，进入左侧车道"
        } else if text.contains("右转") || text.contains("匝道") || text.contains("出口") {
            return "前方请向右变道，进入右侧车道"
        } else if text.contains("掉头") {
            return "前方请提前并入最左侧掉头车道"
        } else {
            return "请保持在直行车道行驶"
        }
    }
}