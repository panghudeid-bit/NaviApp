import Foundation
import CoreLocation

// MARK: - 空气质量等级

enum AQILevel {
    case good
    case moderate
    case fair
    case poor
    case veryPoor
    case extremelyPoor
    case unknown

    var label: String {
        switch self {
        case .good:          return "优"
        case .moderate:      return "良"
        case .fair:          return "中度"
        case .poor:          return "较差"
        case .veryPoor:      return "很差"
        case .extremelyPoor: return "极差"
        case .unknown:       return "未知"
        }
    }

    /// 欧洲 AQI 分级标准
    static func from(europeanAQI value: Double) -> AQILevel {
        switch value {
        case ..<20:  return .good
        case ..<40:  return .moderate
        case ..<60:  return .fair
        case ..<80:  return .poor
        case ..<100: return .veryPoor
        default:     return .extremelyPoor
        }
    }
}

// MARK: - 天气快照

struct WeatherSnapshot: Equatable {

    var temperature: Int
    var weatherCode: Int
    var aqi: Int?
    var fetchedAt: Date

    var iconName: String {
        WeatherSnapshot.symbol(for: weatherCode)
    }

    var conditionText: String {
        WeatherSnapshot.condition(for: weatherCode)
    }

    var aqiLevel: AQILevel {
        guard let aqi = aqi, aqi >= 0 else { return .unknown }
        return AQILevel.from(europeanAQI: Double(aqi))
    }

    var aqiText: String {
        guard let aqi = aqi else { return "AQI --" }
        return "AQI \(aqi)"
    }

    /// WMO 天气代码 -> SF Symbol
    static func symbol(for code: Int) -> String {
        switch code {
        case 0:            return "sun.max.fill"
        case 1:            return "sun.min.fill"
        case 2:            return "cloud.sun.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51, 53, 55:   return "cloud.drizzle.fill"
        case 56, 57:       return "cloud.sleet.fill"
        case 61, 63, 65:   return "cloud.rain.fill"
        case 66, 67:       return "cloud.sleet.fill"
        case 71, 73, 75:   return "cloud.snow.fill"
        case 77:           return "cloud.snow.fill"
        case 80, 81, 82:   return "cloud.heavyrain.fill"
        case 85, 86:       return "cloud.snow.fill"
        case 95:           return "cloud.bolt.rain.fill"
        case 96, 99:       return "cloud.bolt.rain.fill"
        default:           return "cloud.fill"
        }
    }

    /// WMO 天气代码 -> 中文描述
    static func condition(for code: Int) -> String {
        switch code {
        case 0:            return "晴"
        case 1:            return "晴间多云"
        case 2:            return "多云"
        case 3:            return "阴"
        case 45, 48:       return "雾"
        case 51, 53, 55:   return "毛毛雨"
        case 56, 57:       return "冻毛毛雨"
        case 61, 63, 65:   return "雨"
        case 66, 67:       return "冻雨"
        case 71, 73, 75:   return "雪"
        case 77:           return "雪粒"
        case 80, 81, 82:   return "阵雨"
        case 85, 86:       return "阵雪"
        case 95:           return "雷阵雨"
        case 96, 99:       return "雷暴冰雹"
        default:           return "未知"
        }
    }
}

// MARK: - 天气服务

/// 使用 Open-Meteo 开放接口（无需 API key、无需账号）获取实时温度与空气质量
@MainActor
final class WeatherService: ObservableObject {

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastFetchAt: Date?
    private let refreshInterval: TimeInterval = 15 * 60

    // MARK: 对外接口

    func refreshIfNeeded(for coordinate: CLLocationCoordinate2D, force: Bool = false) async {
        let coordinateMoved: Bool
        if let previous = lastCoordinate {
            coordinateMoved = abs(previous.latitude - coordinate.latitude) > 0.05
                || abs(previous.longitude - coordinate.longitude) > 0.05
        } else {
            coordinateMoved = true
        }

        if !force, !coordinateMoved, let last = lastFetchAt,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }

        await refresh(for: coordinate)
    }

    func refresh(for coordinate: CLLocationCoordinate2D) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        lastCoordinate = coordinate

        let forecastResult = await requestForecast(coordinate)
        let airResult = await requestAirQuality(coordinate)

        guard let forecastValue = forecastResult else {
            lastError = "天气获取失败"
            return
        }

        let temperature = Int(forecastValue.temperature.rounded())
        let aqiValue = airResult.map { Int($0.rounded()) }

        snapshot = WeatherSnapshot(
            temperature: temperature,
            weatherCode: forecastValue.code,
            aqi: aqiValue,
            fetchedAt: Date()
        )
        lastError = nil
        lastFetchAt = Date()
    }

    // MARK: 网络请求

    private struct ForecastPayload {
        let temperature: Double
        let code: Int
    }

    private func requestForecast(_ coordinate: CLLocationCoordinate2D) async -> ForecastPayload? {
        guard let url = makeURL(
            host: "api.open-meteo.com",
            path: "/v1/forecast",
            coordinate: coordinate,
            extra: [URLQueryItem(name: "current", value: "temperature_2m,weather_code")]
        ) else { return nil }

        guard let data = await fetchData(url) else { return nil }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = root["current"] as? [String: Any],
            let temperature = current["temperature_2m"] as? Double
        else { return nil }

        let code = (current["weather_code"] as? Int) ?? 0
        return ForecastPayload(temperature: temperature, code: code)
    }

    private func requestAirQuality(_ coordinate: CLLocationCoordinate2D) async -> Double? {
        guard let url = makeURL(
            host: "air-quality-api.open-meteo.com",
            path: "/v1/air-quality",
            coordinate: coordinate,
            extra: [URLQueryItem(name: "current", value: "european_aqi")]
        ) else { return nil }

        guard let data = await fetchData(url) else { return nil }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = root["current"] as? [String: Any]
        else { return nil }

        if let value = current["european_aqi"] as? Double {
            return value
        }
        if let value = current["european_aqi"] as? Int {
            return Double(value)
        }
        return nil
    }

    private func makeURL(
        host: String,
        path: String,
        coordinate: CLLocationCoordinate2D,
        extra: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", coordinate.longitude)),
            URLQueryItem(name: "timezone", value: "auto")
        ] + extra
        return components.url
    }

    private func fetchData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
