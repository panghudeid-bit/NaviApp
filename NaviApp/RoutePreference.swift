import Foundation
import MapKit

// MARK: - 路线偏好类型

enum RoutePreference: String, CaseIterable, Identifiable {
    case leastCongested   = "最不堵车"
    case highwayFirst     = "大路优先"
    case shortestDistance = "距离最短"
    case fewestLights     = "红绿灯最少"

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
            return "stoplight.fill"
        }
    }

    var badgeText: String {
        switch self {
        case .leastCongested:
            return "畅通快充"
        case .highwayFirst:
            return "高速/主干道"
        case .shortestDistance:
            return "超短路程"
        case .fewestLights:
            return "少等红灯"
        }
    }
}

// MARK: - 路线综合评估分析器

struct RouteAssessment: Identifiable {
    let id = UUID()
    let route: MKRoute
    let preferenceMatched: RoutePreference
    let tags: [String]
    let estimatedLightsCount: Int
    let highwayRatio: Double
    let isRecommended: Bool
}

@MainActor
final class RoutePreferenceEngine {

    static func evaluateRoutes(
        _ routes: [MKRoute],
        preference: RoutePreference
    ) -> [RouteAssessment] {
        guard !routes.isEmpty else { return [] }

        var scoredList: [(route: MKRoute, lights: Int, hwRatio: Double)] = []

        for route in routes {
            var lightsCount = 0
            var highwayDistance: CLLocationDistance = 0

            for step in route.steps {
                let text = step.instructions.lowercased()
                if text.contains("转") || text.contains("直行进入") || text.contains("路口") {
                    lightsCount += 1
                }

                if text.contains("高速") || text.contains("高架") || text.contains("快速路") || text.contains("大道") {
                    highwayDistance += step.distance
                }
            }

            let nonHwDist = max(0, route.distance - highwayDistance)
            let baseLights = Int(nonHwDist / 600.0)
            let totalEstimatedLights = max(2, lightsCount + baseLights)

            let ratio = route.distance > 0 ? (highwayDistance / route.distance) : 0
            scoredList.append((route, totalEstimatedLights, ratio))
        }

        let sorted = scoredList.sorted { a, b in
            switch preference {
            case .leastCongested:
                return a.route.expectedTravelTime < b.route.expectedTravelTime
            case .highwayFirst:
                if abs(a.hwRatio - b.hwRatio) > 0.15 {
                    return a.hwRatio > b.hwRatio
                }
                return a.route.expectedTravelTime < b.route.expectedTravelTime
            case .shortestDistance:
                return a.route.distance < b.route.distance
            case .fewestLights:
                return a.lights < b.lights
            }
        }

        return sorted.enumerated().map { index, item in
            var tags: [String] = []

            if index == 0 {
                tags.append(preference.badgeText)
            }

            if item.hwRatio > 0.45 {
                tags.append(String(format: "%.0f%%主干路", item.hwRatio * 100))
            }

            tags.append("约\(item.lights)个红绿灯")

            return RouteAssessment(
                route: item.route,
                preferenceMatched: preference,
                tags: tags,
                estimatedLightsCount: item.lights,
                highwayRatio: item.hwRatio,
                isRecommended: (index == 0)
            )
        }
    }
}