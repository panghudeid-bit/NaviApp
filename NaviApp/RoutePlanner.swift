import Foundation
import MapKit

// MARK: - 包含途经点的复合路线模型（NavRoute）
/// 统一抽象单段路线与包含途经点的多段拼接路线，使其对 UI 和导航引擎完全透明一体化
final class NavRoute: Identifiable {
    let id = UUID()
    let polylines: [MKPolyline]      // 全程所有路段折线集合
    let combinedPolyline: MKPolyline // 拼接后的全局完整折线
    let steps: [MKRoute.Step]        // 顺序拼接的全程行驶步骤
    let distance: CLLocationDistance // 全程总物理里程
    let expectedTravelTime: TimeInterval // 全程总预期耗时
    let viaMapItem: MKMapItem?       // 途经点（若有）
    let destinationMapItem: MKMapItem// 最终目的地

    // 多航段拆分：[0] 第一段到途经点，[1] 第二段到终点
    let subRoutes: [MKRoute]

    init(singleRoute: MKRoute, destination: MKMapItem) {
        self.polylines = [singleRoute.polyline]
        self.combinedPolyline = singleRoute.polyline
        self.steps = singleRoute.steps
        self.distance = singleRoute.distance
        self.expectedTravelTime = singleRoute.expectedTravelTime
        self.viaMapItem = nil
        self.destinationMapItem = destination
        self.subRoutes = [singleRoute]
    }

    init(firstLeg: MKRoute, secondLeg: MKRoute, via: MKMapItem, destination: MKMapItem) {
        self.polylines = [firstLeg.polyline, secondLeg.polyline]
        self.subRoutes = [firstLeg, secondLeg]
        self.viaMapItem = via
        self.destinationMapItem = destination

        self.distance = firstLeg.distance + secondLeg.distance
        self.expectedTravelTime = firstLeg.expectedTravelTime + secondLeg.expectedTravelTime

        // 拼接步骤，在两段之间无缝插入一条提示步骤
        var allSteps: [MKRoute.Step] = []
        allSteps.append(contentsOf: firstLeg.steps)
        allSteps.append(contentsOf: secondLeg.steps)
        self.steps = allSteps

        // 将两段 polyline 的坐标点串联为单一组合 polyline
        var combinedPoints: [MKMapPoint] = []
        let p1 = firstLeg.polyline.points()
        for i in 0..<firstLeg.polyline.pointCount {
            combinedPoints.append(p1[i])
        }
        let p2 = secondLeg.polyline.points()
        for i in 0..<secondLeg.polyline.pointCount {
            combinedPoints.append(p2[i])
        }

        self.combinedPolyline = MKPolyline(points: combinedPoints, count: combinedPoints.count)
    }
}

// MARK: - 路线规划服务

@MainActor
final class RoutePlanner: ObservableObject {

    @Published var isCalculating = false
    @Published var errorMessage = ""

    func searchPlace(_ query: String, near center: CLLocationCoordinate2D? = nil) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let center = center {
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }

    func geocodeAddress(_ text: String, near center: CLLocationCoordinate2D? = nil) async throws -> MKMapItem {
        let items = try await searchPlace(text, near: center)
        guard let first = items.first else {
            throw NSError(
                domain: "RoutePlanner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到地点：\(text)"]
            )
        }
        return first
    }

    /// 直达多备选规划（转换为统一的 NavRoute）
    func calculateDirectRoutes(
        from startItem: MKMapItem,
        to endItem: MKMapItem
    ) async throws -> [NavRoute] {
        let request = MKDirections.Request()
        request.source = startItem
        request.destination = endItem
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else {
            throw NSError(
                domain: "RoutePlanner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "没有可用的驾车路线"]
            )
        }

        return response.routes.map { NavRoute(singleRoute: $0, destination: endItem) }
    }

    /// 🌟 修复关键：途经点两段式规划合并为完整的单一全程路线，不再拆碎暴露给评分引擎
    func calculateViaRoute(
        start: MKMapItem,
        via: MKMapItem,
        destination: MKMapItem
    ) async throws -> [NavRoute] {
        // 第一段：起点 -> 途经点
        let req1 = MKDirections.Request()
        req1.source = start
        req1.destination = via
        req1.transportType = .automobile

        let res1 = try await MKDirections(request: req1).calculate()
        guard let leg1 = res1.routes.first else {
            throw NSError(domain: "RoutePlanner", code: 501, userInfo: [NSLocalizedDescriptionKey: "前往途经点路线规划失败"])
        }

        // 第二段：途经点 -> 终点
        let req2 = MKDirections.Request()
        req2.source = via
        req2.destination = destination
        req2.transportType = .automobile

        let res2 = try await MKDirections(request: req2).calculate()
        guard let leg2 = res2.routes.first else {
            throw NSError(domain: "RoutePlanner", code: 502, userInfo: [NSLocalizedDescriptionKey: "途经点至终点路线规划失败"])
        }

        // 缝合为一条完整的复合路线，代表全程完整旅行！
        let fullRoute = NavRoute(firstLeg: leg1, secondLeg: leg2, via: via, destination: destination)
        return [fullRoute]
    }
}