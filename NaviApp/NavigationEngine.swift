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

    private var destination: MKMapItem?
    private var lastRerouteTime = Date.distantPast

    // 语音播报回调
    var onOffRoute: (() -> Void)?
    var onArrival: (() -> Void)?

    // 开始导航
    func start(
        route: MKRoute,
        destination: MKMapItem
    ) {
        self.currentRoute = route
        self.destination = destination

        isNavigating = true
        hasArrived = false
        isOffRoute = false

        remainingDistance = route.distance
        remainingTime = route.expectedTravelTime

        statusMessage = "导航进行中"
    }

    // 停止导航
    func stop() {

        isNavigating = false
        isOffRoute = false
        hasArrived = false

        statusMessage = "导航已结束"
    }

    // GPS 位置更新
    func updateLocation(
        _ location: CLLocation
    ) {

        currentLocation = location

        guard isNavigating,
              let route = currentRoute,
              let destination = destination else {
            return
        }

        // 到达判断
        let destinationLocation = CLLocation(
            latitude: destination.placemark.coordinate.latitude,
            longitude: destination.placemark.coordinate.longitude
        )

        let distanceToDestination =
            location.distance(from: destinationLocation)

        if distanceToDestination < 35 {

            if !hasArrived {
                onArrival?()
            }

            hasArrived = true
            isNavigating = false

            statusMessage = "已到达目的地"

            return
        }

        // 计算当前位置与路线的距离
        let distanceToRoute =
            distanceFromRoute(
                location.coordinate,
                route.polyline
            )

        // 超过 60 米视为偏离路线
        if distanceToRoute > 60 {

            if !isOffRoute {
                onOffRoute?()
            }

            isOffRoute = true

            statusMessage = "正在重新规划路线"

            Task {
                await reroute(
                    from: location,
                    to: destination
                )
            }

        } else {

            isOffRoute = false

            statusMessage = "导航进行中"

            updateRemainingProgress(
                location,
                route: route
            )
        }
    }

    // 距离路线最近的距离
    private func distanceFromRoute(
        _ coordinate: CLLocationCoordinate2D,
        _ polyline: MKPolyline
    ) -> CLLocationDistance {

        let userPoint = MKMapPoint(coordinate)

        guard polyline.pointCount >= 2 else {
            return .greatestFiniteMagnitude
        }

        let points = polyline.points()

        var minimumDistance =
            CLLocationDistance.greatestFiniteMagnitude

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

                t = max(
                    0,
                    min(
                        1,
                        (
                            (userPoint.x - a.x) * dx +
                            (userPoint.y - a.y) * dy
                        ) / lengthSquared
                    )
                )
            }

            let nearestPoint = MKMapPoint(
                x: a.x + t * dx,
                y: a.y + t * dy
            )

            let distance =
                userPoint.distance(to: nearestPoint)

            minimumDistance = min(
                minimumDistance,
                distance
            )
        }

        return minimumDistance
    }

    // 偏航后重新规划
    private func reroute(
        from location: CLLocation,
        to destination: MKMapItem
    ) async {

        // 防止短时间内重复请求
        guard Date().timeIntervalSince(
            lastRerouteTime
        ) > 10 else {
            return
        }

        lastRerouteTime = Date()

        let request = MKDirections.Request()

        request.source = MKMapItem(
            placemark: MKPlacemark(
                coordinate: location.coordinate
            )
        )

        request.destination = destination

        request.transportType = .automobile

        do {

            let response = try await MKDirections(
                request: request
            ).calculate()

            guard let newRoute =
                response.routes.first else {
                return
            }

            currentRoute = newRoute

            remainingDistance = newRoute.distance

            remainingTime =
                newRoute.expectedTravelTime

            isOffRoute = false

            statusMessage = "已重新规划路线"

        } catch {

            statusMessage = "重新规划失败，请检查网络"
        }
    }

    // 更新剩余距离和时间（精确版：沿路线累积计算）
    private func updateRemainingProgress(
        _ location: CLLocation,
        route: MKRoute
    ) {

        let polyline = route.polyline

        guard polyline.pointCount >= 2 else {
            return
        }

        let points = polyline.points()

        let userPoint = MKMapPoint(
            location.coordinate
        )

        var cumulativeDistance: CLLocationDistance = 0

        var bestDistance =
            CLLocationDistance.greatestFiniteMagnitude

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

                t = max(
                    0,
                    min(
                        1,
                        (
                            (userPoint.x - a.x) * dx +
                            (userPoint.y - a.y) * dy
                        ) / lengthSquared
                    )
                )
            }

            let nearestPoint = MKMapPoint(
                x: a.x + t * dx,
                y: a.y + t * dy
            )

            let distance =
                userPoint.distance(to: nearestPoint)

            if distance < bestDistance {

                bestDistance = distance

                distanceAlongRoute =
                    cumulativeDistance +
                    segmentLength * t
            }

            cumulativeDistance += segmentLength
        }

        remainingDistance = max(
            0,
            route.distance - distanceAlongRoute
        )

        let remainingRatio =
            route.distance > 0
            ? remainingDistance / route.distance
            : 0

        remainingTime =
            route.expectedTravelTime * remainingRatio
    }
}
