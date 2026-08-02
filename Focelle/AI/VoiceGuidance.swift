@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceGuidance: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastText = ""
    private var lastTime: TimeInterval = 0

    func speak(_ text: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard shouldSpeak(text, now: now) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.stopSpeaking(at: .word)
        synthesizer.speak(utterance)
    }

    func shouldSpeak(_ text: String, now: TimeInterval) -> Bool {
        guard !text.isEmpty, text != lastText || now - lastTime >= 4 else { return false }
        lastText = text
        lastTime = now
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
