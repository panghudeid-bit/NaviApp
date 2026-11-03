import Foundation
import AVFoundation

@MainActor
final class VoiceNavigation: ObservableObject {

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isMuted = false

    @Published var currentInstruction = ""

    // 播报导航提示
    func speak(_ text: String) {

        guard !isMuted else {
            return
        }

        guard !text.isEmpty else {
            return
        }

        currentInstruction = text

        // 避免多条语音同时播放
        synthesizer.stopSpeaking(
            at: .immediate
        )

        let utterance = AVSpeechUtterance(
            string: text
        )

        utterance.voice = AVSpeechSynthesisVoice(
            language: "zh-CN"
        )

        utterance.rate = 0.48

        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    // 静音
    func mute() {

        isMuted = true

        synthesizer.stopSpeaking(
            at: .immediate
        )
    }

    // 恢复语音
    func unmute() {

        isMuted = false
    }

    // 停止语音
    func stop() {

        synthesizer.stopSpeaking(
            at: .immediate
        )
    }

    // 播报偏航
    func announceOffRoute() {

        speak(
            "您已偏离规划路线，正在重新规划"
        )
    }

    // 播报到达
    func announceArrival() {

        speak(
            "您已到达目的地"
        )
    }
}
