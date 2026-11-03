import Foundation
import Speech
import AVFoundation

/// 语音搜索：把用户说的话识别成文字，用于填充目的地输入框
@MainActor
final class SpeechRecognizer: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var authorizationDenied = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    // MARK: 权限

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.authorizationDenied = (status != .authorized)
            }
        }
    }

    // MARK: 开关

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording else { return }

        transcript = ""
        errorMessage = nil

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.authorizationDenied = true
                    self.errorMessage = "语音识别未授权，请到「设置 → 导航」中开启"
                    return
                }
                self.beginSession()
            }
        }
    }

    func stop() {
        guard isRecording else { return }

        recognitionRequest?.endAudio()
        audioEngine?.stop()
        removeTapIfNeeded()
        audioEngine = nil
        isRecording = false

        // 留一点时间让系统把最终结果吐出来，再彻底释放音频会话
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.cleanup()
        }
    }

    // MARK: 内部实现

    private func beginSession() {
        guard let recognizer = recognizer else {
            errorMessage = "当前设备不支持中文语音识别"
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "语音识别服务暂时不可用，请稍后再试"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // 用 .record 抢占麦克风；duckOthers 让正在播放的导航语音自动压低
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // 真机上麦克风不可用时 sampleRate 会是 0，直接 installTap 会崩溃
            guard format.sampleRate > 0, format.channelCount > 0 else {
                errorMessage = "麦克风不可用，请检查设备"
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .search

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()

            audioEngine = engine
            recognitionRequest = request
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    if let result = result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.finishSession()
                        }
                    }
                    if error != nil {
                        self.finishSession()
                    }
                }
            }
        } catch {
            errorMessage = "无法启动语音识别：\(error.localizedDescription)"
            finishSession()
        }
    }

    private func finishSession() {
        audioEngine?.stop()
        removeTapIfNeeded()
        audioEngine = nil
        isRecording = false
        cleanup()
    }

    private func removeTapIfNeeded() {
        guard tapInstalled, let engine = audioEngine else {
            tapInstalled = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func cleanup() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // 释放音频会话，避免影响后续的导航语音播报
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 会话可能已被系统回收，忽略
        }
    }
}
