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
    let highwayRatio: Double // 快速路/主干道比例 (0.0 ~ 1.0)
    let isRecommended: Bool
}

@MainActor
final class RoutePreferenceEngine {

    /// 对一组候选路线基于偏好进行多维特征提取与智能排序
    static func evaluateRoutes(
        _ routes: [MKRoute],
        preference: RoutePreference
    ) -> [RouteAssessment] {
        guard !routes.isEmpty else { return [] }

        // 1. 特征分析
        var scoredList: [(route: MKRoute, lights: Int, hwRatio: Double)] = []

        for route in routes {
            var lightsCount = 0
            var highwayDistance: CLLocationDistance = 0

            for step in route.steps {
                let text = step.instructions.lowercased()
                // 估算路口数（转弯、掉头、交叉路口通常伴随红绿灯）
                if text.contains("转") || text.contains("直行进入") || text.contains("路口") {
                    lightsCount += 1
                }

                // 统计主干道、高架、高速公路里程
                if text.contains("高速") || text.contains("高架") || text.contains("快速路") || text.contains("大道") {
                    highwayDistance += step.distance
                }
            }

            // 基础红绿灯密度估算（按普通道路平均每 600 米一个红绿灯，快速路免除）
            let nonHwDist = max(0, route.distance - highwayDistance)
            let baseLights = Int(nonHwDist / 600.0)
            let totalEstimatedLights = max(2, lightsCount + baseLights)

            let ratio = route.distance > 0 ? (highwayDistance / route.distance) : 0
            scoredList.append((route, totalEstimatedLights, ratio))
        }

        // 2. 根据偏好排序找出优选路线
        let sorted = scoredList.sorted { a, b in
            switch preference {
            case .leastCongested:
                // 预计通行耗时最短
                return a.route.expectedTravelTime < b.route.expectedTravelTime

            case .highwayFirst:
                // 高速/主干道比例最高；若接近则选耗时短的
                if abs(a.hwRatio - b.hwRatio) > 0.15 {
                    return a.hwRatio > b.hwRatio
                }
                return a.route.expectedTravelTime < b.route.expectedTravelTime

            case .shortestDistance:
                // 物理里程最短
                return a.route.distance < b.route.distance

            case .fewestLights:
                // 红绿灯估算最少
                return a.lights < b.lights
            }
        }

        // 3. 构造展示卡片元数据
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