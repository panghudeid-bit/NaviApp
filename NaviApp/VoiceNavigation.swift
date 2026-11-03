import Foundation
import AVFoundation

@MainActor
final class VoiceNavigation: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isMuted = false
    @Published var currentInstruction = ""

    private var speechQueue: [String] = []
    private var isSpeaking = false
    private var lastSpokenText = ""

    override init() {
        super.init()
        synthesizer.delegate = self
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

    func speak(_ text: String, isUrgent: Bool = false) {
        guard !isMuted, !text.isEmpty else { return }

        if text == lastSpokenText && isSpeaking && !isUrgent {
            return
        }

        if isUrgent {
            speechQueue.removeAll()
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            enqueueAndPlay(text)
        } else {
            speechQueue.append(text)
            processNextSpeechIfNeeded()
        }
    }

    private func processNextSpeechIfNeeded() {
        guard !isSpeaking, !speechQueue.isEmpty else { return }
        let nextText = speechQueue.removeFirst()
        enqueueAndPlay(nextText)
    }

    private func enqueueAndPlay(_ text: String) {
        isSpeaking = true
        lastSpokenText = text
        currentInstruction = text

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.processNextSpeechIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.processNextSpeechIfNeeded()
        }
    }

    func mute() {
        isMuted = true
        speechQueue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func unmute() {
        isMuted = false
    }

    func stop() {
        speechQueue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentInstruction = ""
    }

    func announceOffRoute() {
        speak("您已偏离规划路线，正在重新规划最优路线", isUrgent: true)
    }

    func announceArrival() {
        speak("已到达目的地附近，导航结束", isUrgent: true)
    }
}