import SwiftUI

// MARK: - 车道朝向定义

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

// MARK: - 单车道状态模型

struct LaneInfo: Identifiable, Equatable {
    let id = UUID()
    let direction: LaneDirection
    let isRecommended: Bool
}

// MARK: - 车道级 3D HUD 悬浮指示栏

struct LaneGuidanceView: View {
    let lanes: [LaneInfo]
    let nextTurnInstruction: String
    let distanceToNextStep: Double

    var body: some View {
        VStack(spacing: 8) {
            // 顶部：下一路口转向与剩余米数
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                        .shadow(color: .blue.opacity(0.4), radius: 6, x: 0, y: 3)

                    Image(systemName: "arrow.turn.up.right.diamond.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(nextTurnInstruction.isEmpty ? "沿当前道路行驶" : nextTurnInstruction)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(distanceToNextStep > 0 ? String(format: "%.0f 米后转向", distanceToNextStep) : "请在当前路口变道")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                // 3D 车道级徽标
                Text("车道级 3D")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1)
                    )
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // 底部：车道级 3D 箭头矩阵
            HStack(spacing: 8) {
                ForEach(lanes) { lane in
                    VStack(spacing: 4) {
                        Image(systemName: lane.iconName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(lane.isRecommended ? Color.white : Color.gray.opacity(0.7))
                            .shadow(
                                color: lane.isRecommended ? Color.cyan : Color.clear,
                                radius: lane.isRecommended ? 6 : 0
                            )

                        // 推荐车道高亮标线
                        Capsule()
                            .fill(
                                lane.isRecommended
                                ? LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                lane.isRecommended
                                ? Color.blue.opacity(0.55)
                                : Color.black.opacity(0.25)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                lane.isRecommended ? Color.cyan : Color.white.opacity(0.1),
                                lineWidth: lane.isRecommended ? 1.5 : 0.5
                            )
                    )
                    .scaleEffect(lane.isRecommended ? 1.05 : 0.96)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: lane.isRecommended)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.88), Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.6), Color.blue.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
    }
}
