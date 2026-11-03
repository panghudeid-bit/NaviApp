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

    private var destination: MKMapItem?
    private var currentPreference: RoutePreference = .leastCongested

    // 偏航重算防抖任务，支持瞬间取消并立即触发
    private var isRerouting = false
    private var rerouteTask: Task<Void, Never>?
    private var lastRerouteTimestamp: TimeInterval = 0

    // 事件通知
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?
    var onStepAdvance: ((String) -> Void)?
    var onLaneAdvise: ((String) -> Void)?
    var onRerouted: ((MKRoute) -> Void)?

    /// 开始导航（绑定用户选择偏好）
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

        self.remainingDistance = route.distance
        self.remainingTime = route.expectedTravelTime

        self.currentStepIndex = 0
        self.lastAnnouncedLaneIndex = -1

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

    /// 停止导航
    func stop() {
        self.isNavigating = false
        self.isOffRoute = false
        self.hasArrived = false
        self.currentLanes = []
        self.rerouteTask?.cancel()
        self.statusMessage = "导航已结束"
    }

    /// 核心位置更新驱动（增加敏锐偏航检测与偏好重算传递）
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

        // 1. 到达判断（距离终点 35 米以内）
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

        // 2. 偏航检测（阈值设为 45 米，兼顾灵敏度与抗 GPS 漂移）
        let distanceToRoute = distanceFromRoute(location.coordinate, route.polyline)

        if distanceToRoute > 45 {
            if !isOffRoute {
                onOffRoute?()
            }
            isOffRoute = true
            statusMessage = "正在立马重新规划最优路线..."

            // 核心改进：即刻取消旧任务，立即启动最优偏好算路（仅防 1.5 秒极速重叠）
            triggerImmediateReroute(from: location, to: destination, preference: currentPreference)
        } else {
            isOffRoute = false
            statusMessage = "3D 导航中"
            updateRemainingProgress(location, route: route)
        }
    }

    /// 计算点到折线段的垂直距离
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

    /// 立刻重规划最优路线（毫秒级响应）
    private func triggerImmediateReroute(
        from location: CLLocation,
        to destination: MKMapItem,
        preference: RoutePreference
    ) {
        let now = Date().timeIntervalSince1970
        guard now - lastRerouteTimestamp > 1.5 else { return } // 1.5秒防抖
        lastRerouteTimestamp = now

        rerouteTask?.cancel()
        rerouteTask = Task {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
            request.destination = destination
            request.transportType = .automobile
            request.requestsAlternateRoutes = true // 请求备选以配合偏好选出最优

            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled, !response.routes.isEmpty else { return }

                // 用偏好引擎评分选出当前偏好下的最优路线
                let assessments = RoutePreferenceEngine.evaluateRoutes(
                    response.routes,
                    preference: preference
                )

                guard let bestRoute = assessments.first?.route else { return }

                self.currentRoute = bestRoute
                self.remainingDistance = bestRoute.distance
                self.remainingTime = bestRoute.expectedTravelTime
                self.isOffRoute = false
                self.statusMessage = "已重新规划 \(preference.rawValue) 路线"

                self.currentStepIndex = 0
                if let firstStep = bestRoute.steps.first(where: { !$0.instructions.isEmpty }) {
                    self.nextStepInstruction = firstStep.instructions
                    self.distanceToNextTurn = firstStep.distance
                    self.currentLanes = self.synthesizeLanes(for: firstStep.instructions)
                    self.onStepAdvance?(self.nextStepInstruction)
                }

                // 立即通知 UI 更新路线渲染
                self.onRerouted?(bestRoute)
            } catch {
                if !Task.isCancelled {
                    self.statusMessage = "重算路线中，请稍候..."
                }
            }
        }
    }

    /// 更新进度与车道级引导
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