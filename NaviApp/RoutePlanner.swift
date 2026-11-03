import Foundation
import MapKit

@MainActor
final class RoutePlanner: ObservableObject {

    @Published var alternatives: [MKRoute] = []
    @Published var selectedRoute: MKRoute?
    @Published var viaRoutes: [MKRoute] = []
    @Published var errorMessage = ""

    // 获取指定地址的坐标
    func searchPlace(_ query: String) async throws -> MKMapItem {

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        let response = try await MKLocalSearch(
            request: request
        ).start()

        guard let item = response.mapItems.first else {
            throw NSError(
                domain: "GPSNavigator",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "没有找到该地点"
                ]
            )
        }

        return item
    }

    // 规划候选路线
    func calculateAlternatives(
        from start: MKMapItem,
        to destination: MKMapItem
    ) async throws {

        let request = MKDirections.Request()

        request.source = start
        request.destination = destination

        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let response = try await MKDirections(
            request: request
        ).calculate()

        alternatives = response.routes

        selectedRoute = response.routes.first
    }

    // 规划经过途经点的路线
    func calculateViaRoute(
        start: MKMapItem,
        via: MKMapItem,
        destination: MKMapItem
    ) async throws {

        let firstRequest = MKDirections.Request()

        firstRequest.source = start
        firstRequest.destination = via
        firstRequest.transportType = .automobile

        let firstResponse = try await MKDirections(
            request: firstRequest
        ).calculate()

        let secondRequest = MKDirections.Request()

        secondRequest.source = via
        secondRequest.destination = destination
        secondRequest.transportType = .automobile

        let secondResponse = try await MKDirections(
            request: secondRequest
        ).calculate()

        guard let first = firstResponse.routes.first,
              let second = secondResponse.routes.first else {

            throw NSError(
                domain: "GPSNavigator",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "途经路线规划失败"
                ]
            )
        }

        viaRoutes = [first, second]
    }
}
