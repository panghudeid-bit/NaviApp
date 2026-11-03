import Foundation
import MapKit
import CoreLocation

@MainActor
final class NavigationEngine: ObservableObject {

    @Published var isNavigating = false
    @Published var currentLocation: CLLocation?
    @Published var currentNavRoute: NavRoute?

    @Published var remainingDistance: CLLocationDistance = 0
    @Published var remainingTime: TimeInterval = 0

    @Published var isOffRoute = false
    @Published var hasArrived = false
    @Published var statusMessage = "等待开始导航"

    @Published var currentStepIndex: Int = 0
    @Published var nextStepInstruction: String = ""
    @Published var distanceToNextTurn: CLLocationDistance = 0

    @Published var currentLanes: [LaneInfo] = []
    private var lastAnnouncedLaneStep: Int = -1

    @Published var isWeakGPSSignal = false
    private var consecutiveOffRouteCount = 0

    // 🌟 多航段状态追踪（如：途经点 -> 终点）
    @Published var currentLegIndex: Int = 0
    @Published var currentLegBadgeTitle: String = ""
    private var hasReachedViaPoint = false

    private var currentPreference: RoutePreference = .leastCongested

    // 🌟 修复关键：偏航重算状态锁与超时安全熔断机制（彻底消除并发取消死循环）
    private var isRerouting = false
    private var rerouteTask: Task<Void, Never>?
    private var rerouteStartTime: TimeInterval = 0

    // 🌟 修复关键：滑动窗口局部投影历史线段索引（防止吸附到高架下/平行路）
    private var lastMatchedSegmentIndex: Int = 0

    // 事件通知
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?
    var onViaPointReached: ((String) -> Void)?
    var onStepAdvance: ((String) -> Void)?
    var onLaneAdvise: ((String) -> Void)?
    var onRerouted: ((NavRoute) -> Void)?

    func start(
        navRoute: NavRoute,
        preference: RoutePreference = .leastCongested
    ) {
        stop()

        self.currentNavRoute = navRoute
        self.currentPreference = preference

        self.isNavigating = true
        self.hasArrived = false
        self.isOffRoute = false
        self.isWeakGPSSignal = false
        self.consecutiveOffRouteCount = 0
        self.hasReachedViaPoint = false
        self.currentLegIndex = 0

        self.remainingDistance = navRoute.distance
        self.remainingTime = navRoute.expectedTravelTime

        self.currentStepIndex = 0
        self.lastAnnouncedLaneStep = -1
        self.lastMatchedSegmentIndex = 0

        updateLegBadge()

        if let firstValidStep = navRoute.steps.first(where: { !$0.instructions.isEmpty }) {
            self.nextStepInstruction = firstValidStep.instructions
            self.distanceToNextTurn = firstValidStep.distance
            self.currentLanes = synthesizeLanes(for: firstValidStep.instructions)
        } else {
            self.nextStepInstruction = "沿当前道路直行"
            self.distanceToNextTurn = 500
            self.currentLanes = synthesizeLanes(for: "直行")
        }

        self.statusMessage = "3D 导航中"
    }

    func stop() {
        self.isNavigating = false
        self.isOffRoute = false
        self.hasArrived = false
        self.isWeakGPSSignal = false
        self.currentLanes = []
        self.consecutiveOffRouteCount = 0
        self.hasReachedViaPoint = false
        self.currentLegIndex = 0
        self.currentLegBadgeTitle = ""

        self.currentNavRoute = nil
        self.remainingDistance = 0
        self.remainingTime = 0
        self.currentStepIndex = 0
        self.distanceToNextTurn = 0
        self.nextStepInstruction = ""
        self.lastMatchedSegmentIndex = 0

        self.rerouteTask?.cancel()
        self.rerouteTask = nil
        self.isRerouting = false
        self.statusMessage = "导航已结束"
    }

    private func updateLegBadge() {
        if let nav = currentNavRoute, nav.viaMapItem != nil {
            if !hasReachedViaPoint {
                currentLegBadgeTitle = "前往途经点"
            } else {
                currentLegBadgeTitle = "前往终点"
            }
        } else {
            currentLegBadgeTitle = ""
        }
    }

    func updateLocation(
        _ location: CLLocation,
        preference: RoutePreference = .leastCongested
    ) {
        currentLocation = location
        self.currentPreference = preference

        guard isNavigating, let navRoute = currentNavRoute else { return }

        // 1. 弱信号/隧道检测
        let accuracy = location.horizontalAccuracy
        let isAccuracyPoor = (accuracy < 0 || accuracy > 35.0)
        let isDataStale = abs(location.timestamp.timeIntervalSinceNow) > 6.0

        if isAccuracyPoor || isDataStale {
            self.isWeakGPSSignal = true
            self.statusMessage = "🛰️ 弱信号·保持路线"
            self.consecutiveOffRouteCount = 0
            updateRemainingProgress(location, navRoute: navRoute)
            return
        } else {
            self.isWeakGPSSignal = false
        }

        // 2. 途经点到达判断与无缝换段
        if let via = navRoute.viaMapItem, !hasReachedViaPoint {
            let viaCoord = via.placemark.coordinate
            let distToVia = location.distance(from: CLLocation(latitude: viaCoord.latitude, longitude: viaCoord.longitude))

            if distToVia < 40.0 {
                hasReachedViaPoint = true
                currentLegIndex = 1
                updateLegBadge()
                onViaPointReached?(via.name ?? "途经点")
            }
        }

        // 3. 终点到达判断
        let destCoord = navRoute.destinationMapItem.placemark.coordinate
        let distanceToDestination = location.distance(from: CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude))

        if distanceToDestination < 35.0 {
            if !hasArrived {
                onArrival?()
            }
            hasArrived = true
            isNavigating = false
            currentLanes = []
            statusMessage = "已到达目的地附近"
            return
        }

        // 4. 偏航检测
        let distanceToRoute = distanceFromRoute(location.coordinate, navRoute.combinedPolyline)

        if distanceToRoute > 45.0 {
            consecutiveOffRouteCount += 1

            if consecutiveOffRouteCount >= 2 {
                if !isOffRoute {
                    onOffRoute?()
                }
                isOffRoute = true
                statusMessage = "正在重新规划最优路线..."

                // 🌟 偏航期间依然基于终点测距动态刷新剩余指标，仪表盘不卡死停滞！
                let straightLineDist = distanceToDestination
                remainingDistance = straightLineDist * 1.25
                let avgSpeed = max(8.0, location.speed)
                remainingTime = remainingDistance / avgSpeed

                triggerImmediateReroute(from: location, navRoute: navRoute, preference: currentPreference)
            }
        } else {
            consecutiveOffRouteCount = 0
            isOffRoute = false
            statusMessage = "3D 导航中"
            updateRemainingProgress(location, navRoute: navRoute)
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

    /// 🌟 修复关键：带状态硬锁与超时熔断的偏航重算，绝对不会 1.5 秒自我取消
    private func triggerImmediateReroute(
        from location: CLLocation,
        navRoute: NavRoute,
        preference: RoutePreference
    ) {
        let now = Date().timeIntervalSince1970

        // 1. 如果正在重算，检查是否超时（超过 8 秒视同网络卡死，才释放重新发起），严禁无脑打断！
        if isRerouting {
            if now - rerouteStartTime > 8.0 {
                print("重算超时，强制重置锁状态")
                rerouteTask?.cancel()
                isRerouting = false
            } else {
                // 网络计算正在进行中，平稳等待其返回，绝不 cancel！
                return
            }
        }

        isRerouting = true
        rerouteStartTime = now

        rerouteTask = Task {
            defer {
                Task { @MainActor in
                    self.isRerouting = false
                }
            }

            // 如果途经点尚未到达，重算保持前往途经点再到终点；若已过途经点，则直接重算到终点
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))

            if let via = navRoute.viaMapItem, !self.hasReachedViaPoint {
                request.destination = via
            } else {
                request.destination = navRoute.destinationMapItem
            }

            request.transportType = .automobile
            request.requestsAlternateRoutes = true

            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled, !response.routes.isEmpty else { return }

                // 转换并评分
                let newNavRoutes = response.routes.map {
                    NavRoute(singleRoute: $0, destination: navRoute.destinationMapItem)
                }

                let assessments = RoutePreferenceEngine.evaluateRoutes(
                    newNavRoutes,
                    preference: preference
                )

                guard let bestRoute = assessments.first?.navRoute else { return }

                self.currentNavRoute = bestRoute
                self.remainingDistance = bestRoute.distance
                self.remainingTime = bestRoute.expectedTravelTime
                self.isOffRoute = false
                self.consecutiveOffRouteCount = 0
                self.lastMatchedSegmentIndex = 0
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

    /// 🌟 修复关键：滑动窗口局部投影算法（彻底消灭平行路与高架吸附跳变）
    private func updateRemainingProgress(_ location: CLLocation, navRoute: NavRoute) {
        let polyline = navRoute.combinedPolyline
        guard polyline.pointCount >= 2 else { return }

        let points = polyline.points()
        let userPoint = MKMapPoint(location.coordinate)
        let totalSegments = polyline.pointCount - 1

        // 局部搜索窗口：只在上次匹配段前后范围（前退 10 段，前瞻 35 段）搜索，避免远距离吸附
        let searchStart = max(0, lastMatchedSegmentIndex - 10)
        let searchEnd = min(totalSegments - 1, lastMatchedSegmentIndex + 35)

        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var bestSegIndex = lastMatchedSegmentIndex
        var bestT: Double = 0

        for index in searchStart...searchEnd {
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
            let dist = userPoint.distance(to: nearestPoint)

            if dist < bestDistance {
                bestDistance = dist
                bestSegIndex = index
                bestT = t
            }
        }

        // 更新历史匹配锚点段（单向往前滚动）
        lastMatchedSegmentIndex = max(lastMatchedSegmentIndex, bestSegIndex)

        // 累加计算已行驶米数
        var cumulativeDistance: CLLocationDistance = 0
        for i in 0..<bestSegIndex {
            cumulativeDistance += points[i].distance(to: points[i + 1])
        }
        let currentSegMeters = points[bestSegIndex].distance(to: points[bestSegIndex + 1])
        let distanceAlongRoute = cumulativeDistance + currentSegMeters * bestT

        // 剩余里程与耗时严格单调递减
        remainingDistance = max(0, navRoute.distance - distanceAlongRoute)
        let ratio = navRoute.distance > 0 ? (remainingDistance / navRoute.distance) : 0
        remainingTime = max(0, navRoute.expectedTravelTime * ratio)

        // 步骤推进
        var stepAccum: CLLocationDistance = 0
        var candidateIndex = currentStepIndex
        var matched = false

        for (idx, step) in navRoute.steps.enumerated() {
            stepAccum += step.distance
            if distanceAlongRoute < stepAccum {
                candidateIndex = idx
                distanceToNextTurn = max(0, stepAccum - distanceAlongRoute)
                matched = true
                break
            }
        }

        if !matched {
            candidateIndex = max(0, navRoute.steps.count - 1)
            distanceToNextTurn = 0
        }

        let finalStepIndex = max(currentStepIndex, candidateIndex)

        if finalStepIndex != currentStepIndex && finalStepIndex < navRoute.steps.count {
            currentStepIndex = finalStepIndex
            let instruction = navRoute.steps[finalStepIndex].instructions
            if !instruction.isEmpty {
                nextStepInstruction = instruction
                currentLanes = synthesizeLanes(for: instruction)
                onStepAdvance?(instruction)
            }
        }

        if distanceToNextTurn <= 400 && distanceToNextTurn > 150 && lastAnnouncedLaneStep != currentStepIndex {
            lastAnnouncedLaneStep = currentStepIndex
            let advise = generateLaneSpeechAdvice(for: nextStepInstruction)
            if !advise.isEmpty {
                onLaneAdvise?(advise)
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
            return "前方请准备左转，请注意观察路面标线提前变道"
        } else if text.contains("右转") || text.contains("匝道") || text.contains("出口") {
            return "前方请准备右转，请注意观察路面标线提前变道"
        } else if text.contains("掉头") {
            return "前方请准备掉头，请提前并入左侧转向道"
        } else {
            return "请沿当前道路继续直行"
        }
    }
}