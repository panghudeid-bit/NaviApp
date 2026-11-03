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

    func speak(_ text: String) {
        guard !isMuted, !text.isEmpty else { return }

        currentInstruction = text

        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    func mute() {
        isMuted = true
        synthesizer.stopSpeaking(at: .immediate)
    }

    func unmute() {
        isMuted = false
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func announceOffRoute() {
        speak("您已偏离规划路线，正在重新规划 3D 路线")
    }

    func announceArrival() {
        speak("已到达目的地附近，车道级导航结束")
    }
}
