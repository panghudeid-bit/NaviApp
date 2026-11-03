import Foundation
import MapKit

enum RoutePreference: String, CaseIterable, Identifiable {
    case leastCongested   = "最不堵车"
    case highwayFirst     = "大路优先"
    case shortestDistance = "距离最短"
    case fewestLights     = "少路口"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .leastCongested:
            return "bolt.car.fill"
        case .highwayFirst:
            return "road.lanes"
        case .shortestDistance:
            return "point.topleft.down.to.point.bottomright.curvepath"
        case .fewestLights:
            return "point.filled.topleft.down.curvedto.point.bottomright.up"
        }
    }

    var badgeText: String {
        switch self {
        case .leastCongested:
            return "畅通优选"
        case .highwayFirst:
            return "主干大路"
        case .shortestDistance:
            return "短里程"
        case .fewestLights:
            return "少转弯交汇"
        }
    }
}

struct RouteAssessment: Identifiable {
    let id = UUID()
    let navRoute: NavRoute
    let preferenceMatched: RoutePreference
    let tags: [String]
    let estimatedIntersectionCount: Int
    let highwayRatio: Double
    let isRecommended: Bool
}

@MainActor
final class RoutePreferenceEngine {

    /// 对完整的全程路线进行启发式得分评估
    static func evaluateRoutes(
        _ routes: [NavRoute],
        preference: RoutePreference
    ) -> [RouteAssessment] {
        guard !routes.isEmpty else { return [] }

        var metricsList: [(navRoute: NavRoute, intersections: Int, hwRatio: Double, score: Double)] = []

        let minTime = routes.map { $0.expectedTravelTime }.min() ?? 1.0
        let minDistance = routes.map { $0.distance }.min() ?? 1.0

        for r in routes {
            var intersectionCount = 0
            var highwayDistance: CLLocationDistance = 0

            for step in r.steps {
                let text = step.instructions.lowercased()
                if text.contains("转") || text.contains("直行进入") || text.contains("路口") || text.contains("掉头") {
                    intersectionCount += 1
                }
                if text.contains("高速") || text.contains("高架") || text.contains("快速路") || text.contains("大道") {
                    highwayDistance += step.distance
                }
            }

            let nonHwDist = max(0, r.distance - highwayDistance)
            let baseIntersections = Int(nonHwDist / 700.0)
            let totalEstimatedIntersections = max(2, intersectionCount + baseIntersections)

            let ratio = r.distance > 0 ? (highwayDistance / r.distance) : 0

            let timeFactor = minTime / max(1.0, r.expectedTravelTime)
            let distFactor = minDistance / max(1.0, r.distance)
            let intersectionFactor = 1.0 / Double(max(1, totalEstimatedIntersections))

            let compositeScore: Double
            switch preference {
            case .leastCongested:
                compositeScore = timeFactor * 0.70 + ratio * 0.20 + distFactor * 0.10
            case .highwayFirst:
                compositeScore = ratio * 0.65 + timeFactor * 0.25 + distFactor * 0.10
            case .shortestDistance:
                compositeScore = distFactor * 0.70 + timeFactor * 0.20 + ratio * 0.10
            case .fewestLights:
                compositeScore = intersectionFactor * 0.65 + timeFactor * 0.20 + ratio * 0.15
            }

            metricsList.append((r, totalEstimatedIntersections, ratio, compositeScore))
        }

        let sorted = metricsList.sorted { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            if a.navRoute.expectedTravelTime != b.navRoute.expectedTravelTime {
                return a.navRoute.expectedTravelTime < b.navRoute.expectedTravelTime
            }
            return a.navRoute.distance < b.navRoute.distance
        }

        return sorted.enumerated().map { index, item in
            var tags: [String] = []

            if index == 0 {
                tags.append(preference.badgeText)
            }

            if item.hwRatio > 0.35 {
                tags.append(String(format: "约%.0f%%主干路", item.hwRatio * 100))
            }

            tags.append("约\(item.intersections)处转弯/路口")

            return RouteAssessment(
                navRoute: item.navRoute,
                preferenceMatched: preference,
                tags: tags,
                estimatedIntersectionCount: item.intersections,
                highwayRatio: item.hwRatio,
                isRecommended: (index == 0)
            )
        }
    }
}