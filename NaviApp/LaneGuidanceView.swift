import SwiftUI

// MARK: - 转向示意朝向定义

enum LaneDirection: String, CaseIterable {
    case straight = "直行"
    case left = "左转"
    case right = "右转"
    case straightLeft = "直行+左转"
    case straightRight = "直行+右转"
    case uTurn = "掉头"

    var iconName: String {
        switch self {
        case .straight:
            return "arrow.up"
        case .left:
            return "arrow.turn.up.left"
        case .right:
            return "arrow.turn.up.right"
        case .straightLeft:
            return "arrow.triangle.branch"
        case .straightRight:
            return "arrow.triangle.turn.up.right.diamond"
        case .uTurn:
            return "arrow.uturn.left"
        }
    }
}

// MARK: - 示意车道模型

struct LaneInfo: Identifiable, Equatable {
    let id = UUID()
    let direction: LaneDirection
    let isRecommended: Bool

    var iconName: String {
        direction.iconName
    }
}

// MARK: - 转向示意 HUD 悬浮指示栏

struct LaneGuidanceView: View {
    let lanes: [LaneInfo]
    let nextTurnInstruction: String
    let distanceToNextStep: CLLocationDistance
    let isWeakGPS: Bool
    var currentLegTitle: String = "" // 支持多航段提示（如：正前往途经点 / 正前往目的地）

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "00C6FF"), Color(hex: "0072FF")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .shadow(color: Color(hex: "0072FF").opacity(0.5), radius: 8, x: 0, y: 3)

                    Image(systemName: "arrow.turn.up.right.diamond.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(nextTurnInstruction.isEmpty ? "沿当前道路直行" : nextTurnInstruction)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if !currentLegTitle.isEmpty {
                            Text(currentLegTitle)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.8))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Text(distanceToNextStep > 0 ? "\(distanceToNextStep.formattedMeters)后" : "即将通过路口")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(hex: "00F2FE"))

                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))

                        if isWeakGPS {
                            Text("弱信号·保持当前路线")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.yellow)
                        } else {
                            Text("转向示意·以实际标线为准")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(isWeakGPS ? Color.yellow : Color(hex: "00F2FE"))
                        .frame(width: 6, height: 6)
                    Text(isWeakGPS ? "弱网守护" : "转向示意")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(isWeakGPS ? Color.yellow : Color(hex: "00F2FE"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke((isWeakGPS ? Color.yellow : Color(hex: "00F2FE")).opacity(0.4), lineWidth: 1)
                )
            }

            Divider()
                .background(Color.white.opacity(0.15))

            HStack(spacing: 8) {
                ForEach(lanes) { lane in
                    VStack(spacing: 4) {
                        Image(systemName: lane.direction.iconName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(lane.isRecommended ? Color(hex: "00F2FE") : Color.white.opacity(0.35))
                            .shadow(
                                color: lane.isRecommended ? Color(hex: "00F2FE").opacity(0.8) : Color.clear,
                                radius: lane.isRecommended ? 6 : 0
                            )

                        Capsule()
                            .fill(
                                lane.isRecommended
                                ? LinearGradient(colors: [Color(hex: "00F2FE"), Color(hex: "4FACFE")], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                lane.isRecommended
                                ? Color(hex: "0072FF").opacity(0.35)
                                : Color.white.opacity(0.04)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                lane.isRecommended ? Color(hex: "00F2FE").opacity(0.8) : Color.white.opacity(0.08),
                                lineWidth: lane.isRecommended ? 1.5 : 0.6
                            )
                    )
                    .scaleEffect(lane.isRecommended ? 1.04 : 0.96)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: lane.isRecommended)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "10141E").opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: "00F2FE").opacity(0.5), Color.white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Color.black.opacity(0.6), radius: 16, x: 0, y: 8)
    }
}