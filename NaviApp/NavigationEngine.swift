import Foundation
import MapKit
import CoreLocation

@MainActor
final class NavigationEngine: ObservableObject {

    @Published var isNavigating = false
    @Published var currentLocation: CLLocation?
    @Published var currentNavRoute: NavRoute?

    // 🌟 [P1] 平滑安全的当前导航坐标（弱信号/隧道下冻结保护，避免地图车模跟随杂波剧烈抖动）
    @Published var filteredNavLocation: CLLocation?

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

    // 途经点航段追踪
    @Published var currentLegIndex: Int = 0
    @Published var currentLegBadgeTitle: String = ""
    private var hasReachedViaPoint = false

    private var currentPreference: RoutePreference = .leastCongested

    // 🌟 [P0] 任务版本令牌与可取消的主动并发超时 Task 句柄
    private var isRerouting = false
    private var activeRerouteTaskId: UUID?
    private var currentRerouteTask: Task<Void, Never>?
    private var activeTimeoutTask: Task<Void, Never>?

    // 🌟 [P0] 严格同步线段索引与物理进度
    private var lastMatchedSegmentIndex: Int = 0
    private var maxTraveledDistance: CLLocationDistance = 0

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
        self.maxTraveledDistance = 0
        self.filteredNavLocation = nil

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
        self.maxTraveledDistance = 0
        self.filteredNavLocation = nil

        // 取消所有进行中重算与超时监控
        cancelOngoingReroute()
        self.statusMessage = "导航已结束"
    }

    private func cancelOngoingReroute() {
        self.currentRerouteTask?.cancel()
        self.currentRerouteTask = nil
        self.activeTimeoutTask?.cancel()
        self.activeTimeoutTask = nil
        self.activeRerouteTaskId = nil
        self.isRerouting = false
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

        // 🌟 [P1] 弱信号/隧道检测：如果坐标不可靠，同步冻结车模位置，禁止使用该点刷新吸附折线！
        let accuracy = location.horizontalAccuracy
        let isAccuracyPoor = (accuracy < 0 || accuracy > 35.0)
        let isDataStale = abs(location.timestamp.timeIntervalSinceNow) > 5.0

        if isAccuracyPoor || isDataStale {
            self.isWeakGPSSignal = true
            self.statusMessage = "🛰️ 弱信号·位置已冻结"
            self.consecutiveOffRouteCount = 0
            // 保持 filteredNavLocation 为最后可信坐标，不让车模乱晃
            return
        } else {
            self.isWeakGPSSignal = false
            // 接收合法坐标作为当前安全导航坐标
            self.filteredNavLocation = location
        }

        // 途经点到达检测
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

        // 终点到达判断
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

        // 偏航检测
        let distanceToRoute = distanceFromRoute(location.coordinate, navRoute.combinedPolyline)

        if distanceToRoute > 45.0 {
            consecutiveOffRouteCount += 1

            if consecutiveOffRouteCount >= 2 {
                if !isOffRoute {
                    onOffRoute?()
                }
                isOffRoute = true
                statusMessage = "偏航中·重新规划路线..."

                // 偏航暂估 ETA 独立展示
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
            let distance = MKMetersBetweenMapPoints(userPoint, nearestPoint)
            minimumDistance = min(minimumDistance, distance)
        }

        return minimumDistance
    }

    /// 🌟 [P0] 偏航重算：主动并发超时 Task 与完整途经点组合重织
    private func triggerImmediateReroute(
        from location: CLLocation,
        navRoute: NavRoute,
        preference: RoutePreference
    ) {
        // 如果当前已有重算正在执行且未超时，平稳等待，严禁并发打断已有请求
        if isRerouting {
            return
        }

        let thisTaskId = UUID()
        self.activeRerouteTaskId = thisTaskId
        self.isRerouting = true

        // 🌟 [P0] 启动主动超时守护 Task（8 秒主动熔断，彻底消灭被动等待）
        self.activeTimeoutTask?.cancel()
        self.activeTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 秒
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if self.activeRerouteTaskId == thisTaskId && self.isRerouting {
                    print("⚠️ 偏航重算主动触发 8 秒超时熔断，主动取消网络任务并释放锁")
                    self.currentRerouteTask?.cancel()
                    self.isRerouting = false
                    self.statusMessage = "网络较慢，正在重试重算..."
                }
            }
        }

        // 启动真正重算异步任务
        self.currentRerouteTask?.cancel()
        self.currentRerouteTask = Task {
            defer {
                Task { @MainActor in
                    if self.activeRerouteTaskId == thisTaskId {
                        self.isRerouting = false
                        self.activeTimeoutTask?.cancel()
                    }
                }
            }

            let newFullNavRoute: NavRoute?

            // 🌟 [P0] 途经点航段偏航重织：完整保留 Leg2
            if let via = navRoute.viaMapItem, !self.hasReachedViaPoint {
                let req1 = MKDirections.Request()
                req1.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
                req1.destination = via
                req1.transportType = .automobile

                do {
                    let res1 = try await MKDirections(request: req1).calculate()
                    guard let newLeg1 = res1.routes.first else { return }

                    let leg2 = navRoute.subRoutes.count > 1 ? navRoute.subRoutes[1] : nil
                    if let existingLeg2 = leg2 {
                        newFullNavRoute = NavRoute(firstLeg: newLeg1, secondLeg: existingLeg2, via: via, destination: navRoute.destinationMapItem)
                    } else {
                        newFullNavRoute = NavRoute(singleRoute: newLeg1, destination: navRoute.destinationMapItem)
                    }
                } catch {
                    newFullNavRoute = nil
                }
            } else {
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
                req.destination = navRoute.destinationMapItem
                req.transportType = .automobile

                do {
                    let res = try await MKDirections(request: req).calculate()
                    if let r = res.routes.first {
                        newFullNavRoute = NavRoute(singleRoute: r, destination: navRoute.destinationMapItem)
                    } else {
                        newFullNavRoute = nil
                    }
                } catch {
                    newFullNavRoute = nil
                }
            }

            guard let bestRoute = newFullNavRoute else { return }

            await MainActor.run {
                guard self.activeRerouteTaskId == thisTaskId else { return }

                self.currentNavRoute = bestRoute
                self.remainingDistance = bestRoute.distance
                self.remainingTime = bestRoute.expectedTravelTime
                self.isOffRoute = false
                self.consecutiveOffRouteCount = 0
                self.lastMatchedSegmentIndex = 0
                self.maxTraveledDistance = 0
                self.statusMessage = "已重新规划 \(preference.rawValue) 路线"

                self.currentStepIndex = 0
                if let firstStep = bestRoute.steps.first(where: { !$0.instructions.isEmpty }) {
                    self.nextStepInstruction = firstStep.instructions
                    self.distanceToNextTurn = firstStep.distance
                    self.currentLanes = self.synthesizeLanes(for: firstStep.instructions)
                    self.onStepAdvance?(self.nextStepInstruction)
                }

                self.onRerouted?(bestRoute)
            }
        }
    }

    /// 🌟 [P0] 修复投影线段索引与参数完全原子一致性计算
    private func updateRemainingProgress(_ location: CLLocation, navRoute: NavRoute) {
        let polyline = navRoute.combinedPolyline
        guard polyline.pointCount >= 2 else { return }

        let points = polyline.points()
        let userPoint = MKMapPoint(location.coordinate)
        let totalSegments = polyline.pointCount - 1

        let searchStart = max(0, lastMatchedSegmentIndex - 10)
        let searchEnd = min(totalSegments - 1, lastMatchedSegmentIndex + 35)

        // 预先准备各段累积物理距离表
        var segmentStartDistances = [CLLocationDistance](repeating: 0, count: totalSegments)
        var runDist: CLLocationDistance = 0
        for i in 0..<totalSegments {
            segmentStartDistances[i] = runDist
            runDist += MKMetersBetweenMapPoints(points[i], points[i + 1])
        }

        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var chosenCalculatedAlongDistance: CLLocationDistance = 0
        var chosenSegmentIndex: Int = lastMatchedSegmentIndex

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
            let distToLine = MKMetersBetweenMapPoints(userPoint, nearestPoint)

            // 原子计算当前候选线段的沿线总米数
            let thisSegmentLength = MKMetersBetweenMapPoints(a, b)
            let thisAlongDistance = segmentStartDistances[index] + thisSegmentLength * t

            // 🌟 原子绑定：最优垂距时，线段索引与该线段上的投影进度必须来自同一个实体！
            if distToLine < bestDistance {
                bestDistance = distToLine
                chosenSegmentIndex = index
                chosenCalculatedAlongDistance = thisAlongDistance
            }
        }

        // 🌟 [P0] 线段与物理距离双向原子单调推进，杜绝参数与线段脱节
        lastMatchedSegmentIndex = max(lastMatchedSegmentIndex, chosenSegmentIndex)
        maxTraveledDistance = max(maxTraveledDistance, chosenCalculatedAlongDistance)

        let distanceAlongRoute = maxTraveledDistance

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
