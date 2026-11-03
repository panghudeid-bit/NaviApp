import Foundation
import AVFoundation

@MainActor
final class VoiceNavigation: ObservableObject {

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isMuted = false
    @Published var currentInstruction = ""

    init() {
        configureAudioSession()
    }

    /// 配置车载导航音频会话（支持静音拨片下播报、降低背景音乐音量）
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .mixWithOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("音频会话配置异常：\(error.localizedDescription)")
        }
    }

    /// 播报导航提示
    func speak(_ text: String) {
        guard !isMuted, !text.isEmpty else { return }

        currentInstruction = text

        // 避免多条语音同时重叠
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    /// 静音
    func mute() {
        isMuted = true
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 恢复语音
    func unmute() {
        isMuted = false
    }

    /// 停止播报
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 播报偏航
    func announceOffRoute() {
        speak("您已偏离规划路线，正在重新规划")
    }

    /// 播报到达
    func announceArrival() {
        speak("已到达目的地附近，导航结束")
    }
}
