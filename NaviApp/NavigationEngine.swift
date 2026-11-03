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
    private var lastRerouteTime = Date.distantPast
    private var isRerouting = false

    // 事件回调
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?
    var onStepAdvance: ((String) -> Void)?
    var onLaneAdvise: ((String) -> Void)?
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
        self.lastAnnouncedLaneIndex = -1

        // 初始化首个步骤与默认车道排布
        if let firstValidStep = route.steps.first(where: { !$0.instructions.isEmpty }) {
            self.nextStepInstruction = firstValidStep.instructions
            self.distanceToNextTurn = firstValidStep.distance
            self.currentLanes = synthesizeLanes(for: firstValidStep.instructions)
        } else {
            self.nextStepInstruction = "沿当前道路直行"
            self.distanceToNextTurn = 500
            self.currentLanes = synthesizeLanes(for: "直行")
        }

        self.statusMessage = "3D 车道级导航进行中"
    }

    /// 停止导航
    func stop() {
        self.isNavigating = false
        self.isOffRoute = false
        self.hasArrived = false
        self.currentLanes = []
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

        // 2. 偏航检测
        let distanceToRoute = distanceFromRoute(location.coordinate, route.polyline)

        if distanceToRoute > 60 {
            if !isOffRoute {
                onOffRoute?()
            }
            isOffRoute = true
            statusMessage = "正在重新规划 3D 路线..."

            Task {
                await reroute(from: location, to: destination)
            }
        } else {
            isOffRoute = false
            statusMessage = "3D 导航中"

            // 3. 沿路线累积计算真实剩余距离、时间和车道步骤指引
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

    /// 偏航重规划
    private func reroute(from location: CLLocation, to destination: MKMapItem) async {
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
            self.statusMessage = "已重新规划 3D 路线"

            self.currentStepIndex = 0
            if let firstStep = newRoute.steps.first(where: { !$0.instructions.isEmpty }) {
                self.nextStepInstruction = firstStep.instructions
                self.distanceToNextTurn = firstStep.distance
                self.currentLanes = synthesizeLanes(for: firstStep.instructions)
                self.onStepAdvance?(self.nextStepInstruction)
            }

            self.onRerouted?(newRoute)
        } catch {
            self.statusMessage = "重新规划失败，请检查网络"
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

        // 剩余里程与耗时
        remainingDistance = max(0, route.distance - distanceAlongRoute)
        let remainingRatio = route.distance > 0 ? remainingDistance / route.distance : 0
        remainingTime = route.expectedTravelTime * remainingRatio

        // 步骤检测与距下一转向点距离
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

        // 当进入新步骤或路口临近时更新车道级 3D 模型
        if detectedStepIndex != currentStepIndex && detectedStepIndex < route.steps.count {
            currentStepIndex = detectedStepIndex
            let instruction = route.steps[detectedStepIndex].instructions
            if !instruction.isEmpty {
                nextStepInstruction = instruction
                currentLanes = synthesizeLanes(for: instruction)
                onStepAdvance?(instruction)
            }
        }

        // 路口临近变道语音提醒（500 米内变道）
        if distanceToNextTurn < 500 && distanceToNextTurn > 250 && lastAnnouncedLaneIndex != currentStepIndex {
            lastAnnouncedLaneIndex = currentStepIndex
            let laneAdvise = generateLaneSpeechAdvice(for: nextStepInstruction)
            if !laneAdvise.isEmpty {
                onLaneAdvise?(laneAdvise)
            }
        }
    }

    /// 根据路线转向语义智能模拟真实 4 车道配置与推荐车道
    private func synthesizeLanes(for instruction: String) -> [LaneInfo] {
        let text = instruction.lowercased()

        if text.contains("左转") || text.contains("左拐") {
            // 左转路况：左1左转（推荐），左2直行+左转（推荐），中间直行，右侧右转
            return [
                LaneInfo(direction: .left, isRecommended: true),
                LaneInfo(direction: .straightLeft, isRecommended: true),
                LaneInfo(direction: .straight, isRecommended: false),
                LaneInfo(direction: .right, isRecommended: false)
            ]
        } else if text.contains("右转") || text.contains("右拐") || text.contains("匝道") || text.contains("出口") {
            // 右转路况：左侧直行，右侧右转（推荐）
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
            // 默认直行：高亮中间 2 个直行车道
            return [
                LaneInfo(direction: .left, isRecommended: false),
                LaneInfo(direction: .straight, isRecommended: true),
                LaneInfo(direction: .straight, isRecommended: true),
                LaneInfo(direction: .right, isRecommended: false)
            ]
        }
    }

    /// 生成车道级变道提示语音
    private func generateLaneSpeechAdvice(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("左转") {
            return "前方请向左变道，行驶在左侧车道"
        } else if text.contains("右转") || text.contains("匝道") || text.contains("出口") {
            return "前方请向右变道，行驶在右侧车道"
        } else if text.contains("掉头") {
            return "前方请提前并入最左侧掉头车道"
        } else {
            return "请保持在直行车道行驶"
        }
    }
}
