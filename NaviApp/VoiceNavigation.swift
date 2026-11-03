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

    // 🌟 [P1] 到达播报完成延迟释放回调
    private var onArrivalSpeechCompleted: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enterNavigationAudioMode() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .mixWithOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("导航音频启动异常：\(error.localizedDescription)")
        }
    }

    func exitNavigationAudioMode() {
        stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("释放音频焦点失败：\(error.localizedDescription)")
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

            // 🌟 [P1] 到达播报全部完成之后，触发外部安全释放回调
            if let callback = self.onArrivalSpeechCompleted {
                self.onArrivalSpeechCompleted = nil
                callback()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.processNextSpeechIfNeeded()
            if let callback = self.onArrivalSpeechCompleted {
                self.onArrivalSpeechCompleted = nil
                callback()
            }
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
        onArrivalSpeechCompleted = nil
    }

    func announceOffRoute() {
        speak("您已偏离规划路线，正在重新规划最优路线", isUrgent: true)
    }

    /// 🌟 [P1] 到达播报：支持播放完成后的回调注入，不被提前掐断
    func announceArrival(onCompletion: (() -> Void)? = nil) {
        self.onArrivalSpeechCompleted = onCompletion
        speak("已到达目的地附近，导航结束", isUrgent: true)
    }
}
