import Foundation
import MapKit

// MARK: - 复合航程路线（NavRoute）

final class NavRoute: Identifiable {
    let id = UUID()
    let polylines: [MKPolyline]
    let combinedPolyline: MKPolyline
    let steps: [MKRoute.Step]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let viaMapItem: MKMapItem?
    let destinationMapItem: MKMapItem

    // 保留原始子航段以供重算时复用
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

        var allSteps: [MKRoute.Step] = []
        allSteps.append(contentsOf: firstLeg.steps)
        allSteps.append(contentsOf: secondLeg.steps)
        self.steps = allSteps

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

// MARK: - 细分网络错误分类器

enum NavError: LocalizedError {
    case noNetwork
    case directionsNotFound
    case locationNotFound(String)
    case general(String)

    var errorDescription: String? {
        switch self {
        case .noNetwork:
            return "网络连接不可用，请检查 Wi-Fi 或蜂窝移动网络设置后重试。"
        case .directionsNotFound:
            return "未找到可通行的驾车路线，起终点之间可能存在渡海阻隔或无道路连接。"
        case .locationNotFound(let name):
            return "未找到相关地点“\(name)”，请尝试输入更详细的地址或道路名称。"
        case .general(let msg):
            return msg
        }
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

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems
        } catch let error as NSError {
            if error.domain == NSURLErrorDomain {
                throw NavError.noNetwork
            }
            throw NavError.general(error.localizedDescription)
        }
    }

    func geocodeAddress(_ text: String, near center: CLLocationCoordinate2D? = nil) async throws -> MKMapItem {
        let items = try await searchPlace(text, near: center)
        guard let first = items.first else {
            throw NavError.locationNotFound(text)
        }
        return first
    }

    /// 直达多备选规划
    func calculateDirectRoutes(
        from startItem: MKMapItem,
        to endItem: MKMapItem
    ) async throws -> [NavRoute] {
        let request = MKDirections.Request()
        request.source = startItem
        request.destination = endItem
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        do {
            let response = try await MKDirections(request: request).calculate()
            guard !response.routes.isEmpty else {
                throw NavError.directionsNotFound
            }
            return response.routes.map { NavRoute(singleRoute: $0, destination: endItem) }
        } catch let error as NSError {
            if error.domain == NSURLErrorDomain {
                throw NavError.noNetwork
            }
            if error.domain == MKErrorDomain && error.code == MKError.directionsNotFound.rawValue {
                throw NavError.directionsNotFound
            }
            throw NavError.general(error.localizedDescription)
        }
    }

    /// 途经点两段式多候选组合规划
    func calculateViaRoutes(
        start: MKMapItem,
        via: MKMapItem,
        destination: MKMapItem
    ) async throws -> [NavRoute] {
        let req1 = MKDirections.Request()
        req1.source = start
        req1.destination = via
        req1.transportType = .automobile
        req1.requestsAlternateRoutes = true

        let res1: MKDirections.Response
        do {
            res1 = try await MKDirections(request: req1).calculate()
        } catch {
            throw NavError.general("前往途经点路线规划失败：\(error.localizedDescription)")
        }

        guard !res1.routes.isEmpty else {
            throw NavError.directionsNotFound
        }

        let req2 = MKDirections.Request()
        req2.source = via
        req2.destination = destination
        req2.transportType = .automobile
        req2.requestsAlternateRoutes = true

        let res2: MKDirections.Response
        do {
            res2 = try await MKDirections(request: req2).calculate()
        } catch {
            throw NavError.general("途经点至终点路线规划失败：\(error.localizedDescription)")
        }

        guard !res2.routes.isEmpty else {
            throw NavError.directionsNotFound
        }

        var combinedRoutes: [NavRoute] = []
        let leg1Count = res1.routes.count
        let leg2Count = res2.routes.count

        combinedRoutes.append(NavRoute(firstLeg: res1.routes[0], secondLeg: res2.routes[0], via: via, destination: destination))

        if leg1Count > 1 {
            combinedRoutes.append(NavRoute(firstLeg: res1.routes[1], secondLeg: res2.routes[0], via: via, destination: destination))
        }

        if leg2Count > 1 && combinedRoutes.count < 3 {
            combinedRoutes.append(NavRoute(firstLeg: res1.routes[0], secondLeg: res2.routes[1], via: via, destination: destination))
        }

        return combinedRoutes
    }
}
