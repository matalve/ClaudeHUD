import AVFoundation

/// Phone-style ring and done-chime, synthesized into PCM buffers once and
/// played on demand — ports the WebAudio oscillator code from the original.
final class ToneSynth {
    private let engine = AVAudioEngine()
    private let ringPlayer = AVAudioPlayerNode()
    private let dingPlayer = AVAudioPlayerNode()
    private var ringBuffer: AVAudioPCMBuffer?
    private var dingBuffer: AVAudioPCMBuffer?
    private var ringTimer: Timer?
    private var stopTimer: Timer?
    private var started = false

    /// Ring volume 0…1, from the chrome slider. The ding plays at a fixed
    /// level, deliberately not tied to this.
    var ringVolume: Float = 0.6 {
        didSet { ringPlayer.volume = ringVolume }
    }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(ringPlayer)
        engine.attach(dingPlayer)
        engine.connect(ringPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(dingPlayer, to: engine.mainMixerNode, format: format)
        ringPlayer.volume = ringVolume
        // two 0.45s bursts of a 440+480 Hz dual tone — a phone ring
        ringBuffer = render(format: format, seconds: 1.1) { t in
            var sample: Float = 0
            for start in [0.0, 0.6] {
                let local = t - start
                guard local >= 0, local < 0.45 else { continue }
                let env: Float =
                    local < 0.03 ? Float(local / 0.03)
                    : local < 0.4 ? 1
                    : Float(1 - (local - 0.4) / 0.05)
                sample += 0.24 * env * (sinf(Float(2 * .pi * 440 * t)) + sinf(Float(2 * .pi * 480 * t)))
            }
            return sample
        }
        // gentle two-note chime when a session finishes its turn
        dingBuffer = render(format: format, seconds: 0.75) { t in
            var sample: Float = 0
            for (freq, off) in [(880.0, 0.0), (1174.66, 0.13)] {
                let local = t - off
                guard local >= 0, local < 0.55 else { continue }
                let env: Float =
                    local < 0.015 ? Float(local / 0.015)
                    : powf(0.005, Float((local - 0.015) / 0.535)) // exponential decay
                sample += 0.2 * env * sinf(Float(2 * .pi * freq * t))
            }
            return sample
        }
    }

    func setRinging(_ on: Bool) {
        if on {
            guard ringTimer == nil else { return }
            stopTimer?.invalidate()
            stopTimer = nil
            playRing()
            ringTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.playRing()
            }
        } else if ringTimer != nil {
            ringTimer?.invalidate()
            ringTimer = nil
            scheduleEngineStop(after: 1.2)
        }
    }

    func ding() {
        guard let dingBuffer, ensureRunning() else { return }
        dingPlayer.scheduleBuffer(dingBuffer)
        dingPlayer.play()
        scheduleEngineStop(after: 1)
    }

    // A running-but-silent AVAudioEngine keeps a realtime I/O thread and the
    // CoreAudio worker threads alive, burning CPU around the clock — shut it
    // down shortly after the last sound finishes.
    private func scheduleEngineStop(after seconds: TimeInterval) {
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.ringTimer == nil else { return }
            self.ringPlayer.stop()
            self.dingPlayer.stop()
            self.engine.stop()
            self.started = false
        }
    }

    private func playRing() {
        guard ringVolume > 0, let ringBuffer, ensureRunning() else { return }
        ringPlayer.scheduleBuffer(ringBuffer)
        ringPlayer.play()
    }

    private func ensureRunning() -> Bool {
        if !started {
            started = (try? engine.start()) != nil
        } else if !engine.isRunning {
            started = (try? engine.start()) != nil
        }
        return started
    }

    private func render(
        format: AVAudioFormat, seconds: Double, sample: (Double) -> Float
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = sample(Double(i) / format.sampleRate)
        }
        return buffer
    }
}
