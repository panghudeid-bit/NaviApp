import SwiftUI
import CoreLocation

// MARK: - 地图显示模式

enum MapDisplayMode {
    case standard
    case hybrid

    var next: MapDisplayMode {
        self == .standard ? .hybrid : .standard
    }
}

// MARK: - 天气 + 空气质量卡片

struct WeatherCardView: View {

    let snapshot: WeatherSnapshot?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 9) {
            weatherIcon

            if let snap = snapshot {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(snap.temperature)°")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                    Text(snap.aqiText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WeatherCardView.aqiColor(snap.aqiLevel))
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isLoading ? "--°" : "--°")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("AQI --")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "0B0F17").opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var weatherIcon: some View {
        Image(systemName: snapshot?.iconName ?? "cloud.fill")
            .font(.system(size: 20, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: 24)
    }

    static func aqiColor(_ level: AQILevel) -> Color {
        switch level {
        case .good:          return Color(hex: "00E676")
        case .moderate:      return Color(hex: "B2FF59")
        case .fair:          return Color(hex: "FFD166")
        case .poor:          return Color(hex: "FF9800")
        case .veryPoor:      return Color(hex: "FF416C")
        case .extremelyPoor: return Color(hex: "C77DFF")
        case .unknown:       return Color.white.opacity(0.45)
        }
    }
}

// MARK: - 圆形悬浮按钮底座

struct RoundMapButton<Content: View>: View {

    let action: () -> Void
    let content: Content

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color(hex: "0B0F17").opacity(0.72))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 方向指示（西 / 东 / 南 / 北）

struct CompassBadgeView: View {

    /// 设备朝向角度（0 为正北）
    let heading: Double
    let action: () -> Void

    var body: some View {
        RoundMapButton(action: action) {
            VStack(spacing: 1) {
                Text(CompassBadgeView.directionText(for: heading))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(hex: "FF416C"))
                    .rotationEffect(.degrees(-heading))
            }
        }
    }

    /// 把角度换算成八方位中文
    static func directionText(for degrees: Double) -> String {
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 {
            normalized += 360
        }
        let index = Int((normalized + 22.5) / 45.0) % 8
        return names[index]
    }
}

// MARK: - 停车位置标记

struct ParkingMarkerView: View {

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color(hex: "1E88E5"))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(Color.white, lineWidth: 2)
                    )
                Image(systemName: "car.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("停车位置")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color(hex: "1E88E5").opacity(0.95))
                )
        }
    }
}

// MARK: - 当前位置蓝点

struct CurrentLocationDot: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "1E88E5").opacity(0.22))
                .frame(width: 42, height: 42)
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
            Circle()
                .fill(Color(hex: "1E88E5"))
                .frame(width: 15, height: 15)
        }
    }
}
