import Foundation
import Accelerate
import CoreAudio

// MARK: - Logging

/// Debug logging is off by default. Enable with:
///   defaults write com.example.prioritymanagement debugLog -bool true
/// The log goes to ~/Library/Logs/PriorityManagement/beatengine.log (user-only permissions).
let engineLogEnabled: Bool = UserDefaults.standard.bool(forKey: "debugLog")
var engineLogSink: ((String) -> Void)? = engineLogEnabled ? { s in
    let line = "\(Date()): \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PriorityManagement")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = dir.appendingPathComponent("beatengine.log").path
    if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(d); fh.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600]) }
} : nil
func engineLog(_ s: String) { engineLogSink?(s) }

// MARK: - Host clock

private let machTimebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
}()
func hostSeconds(fromTicks t: UInt64) -> Double {
    Double(t) * Double(machTimebase.numer) / Double(machTimebase.denom) / 1_000_000_000
}
func hostSecondsNow() -> Double { hostSeconds(fromTicks: mach_absolute_time()) }

// MARK: - Analyzer
//
// Pure DSP, no CoreAudio. Feed mono samples with the audio-clock time of the first sample.
// All event times are in that same clock.
//
// Pipeline:
//   STFT (2048 window, ~100 Hz frame rate)
//   -> 24 log-spaced bands, log-compressed
//   -> SuperFlux style onset strength (half-wave rectified log difference vs max-filtered previous frame)
//   -> local mean removal + running scale normalisation (level independent)
//   -> autocorrelation tempo estimate with a log-Gaussian prior and hysteresis
//   -> comb filter phase estimate, then a beat clock that is nudged toward each new estimate
//   -> beats are announced slightly ahead of time so the UI can fire exactly when the sound is heard
//   -> separate bass-energy drop detector and a beat-synchronous spectral novelty (section change) detector

final class BeatAnalyzer {
    /// beatInBar is 0 for beat one, -1 while the meter is unknown. meter is 3 or 4, or 0 when unknown.
    var onBeat: ((_ time: Double, _ period: Double, _ number: Int, _ beatInBar: Int, _ meter: Int) -> Void)?
    var onDrop: ((_ time: Double) -> Void)?
    var onSection: ((_ time: Double) -> Void)?
    var onLost: (() -> Void)?

    // Tunables
    var detectOffset: Double = 0.015   // onset time is estimated as frame end time minus this
    var beatLead: Double = 0.10        // beats are announced this many seconds before they happen

    let fs: Double
    let frameRate: Double
    private let N = 2048
    private let half = 1024
    private let hop: Int
    private let log2n: vDSP_Length = 11
    private let fft: FFTSetup
    private var window = [Float](repeating: 0, count: 2048)
    private var windowed = [Float](repeating: 0, count: 2048)
    private var realp = [Float](repeating: 0, count: 1024)
    private var imagp = [Float](repeating: 0, count: 1024)
    private var magSq = [Float](repeating: 0, count: 1024)
    private let nBands = 24
    private var bandEdges = [Int]()
    private var bandWeight = [Float]()
    private var lowEdge = 7

    // Stream bookkeeping
    private var pending = [Float]()
    private var pendingStart: Int64 = 0
    private var anchorSample: Int64 = 0
    private var anchorTime: Double = 0
    private var lastEndTime: Double = 0

    // Spectral state
    private var prevL = [Float](repeating: 0, count: 24)
    private var bandL = [Float](repeating: 0, count: 24)
    private var havePrev = false

    // Envelopes
    private var mu: Float = 0
    private var sc: Float = 0
    private let alphaMu: Float
    private let alphaSc: Float
    private var onsetEnv = [Float]()
    private var lowRing = [Float]()
    private var bandHist = [[Float]]()
    private var framesSinceReset = 0
    private var silentFrames = 0

    // Tempo and clock
    private var lag: Double = 0            // beat period in frames (fractional), 0 = no tempo
    private var tempoConf: Float = 0
    private var pendingCount = 0
    private var lowConfCount = 0
    private var clockActive = false
    private var nextBeat: Double = 0
    private var beatNumber = 0
    private var badPhaseCount = 0
    private var badPeakCount = 0
    private var phasePeak: Float = 0
    private var consumerLocked = false

    // Drop and section
    private var lastDropTime = -100.0
    private var lastSectionTime = -100.0
    private var noveltyHist = [Float]()
    private var lastStatus = -100.0
    private var bassPeak: Float = 0

    // Meter
    private var beatTimes = [Double]()          // time of every emitted beat since the clock locked
    private var accLow = [Float](), accOn = [Float](), accNov = [Float]()   // per-beat accent features
    private var meter = 0                       // 0 unknown, otherwise 3 or 4
    private var downbeatPhase = 0               // beats whose number % meter == downbeatPhase are beat one
    private var pendingMeter = 0, pendingPhase = 0, pendingMeterCount = 0, weakMeterCount = 0
    private var meterScore: Float = 0

    // Per-song loudness model and risers
    /// intensity: 0 to 1, how loud the song is right now compared with its own range. riser: 0 to 1, a build up is happening.
    var onEnergy: ((_ time: Double, _ intensity: Double, _ riser: Double) -> Void)?
    private var energyDB: Float = -80
    private var energyHist = [Float](repeating: 0, count: 81)   // 1 dB bins from -80 to 0 dBFS
    private var energyCount: Float = 0
    private let alphaE: Float
    private var hfStartBin = 100
    private var hfAccum: Float = 0
    private var hfAccumN = 0
    private var hfRing = [Float]()                               // high frequency power in dB, one value per 0.1 s
    private var hfBase: Float = 0
    private var riserHold = 0
    private var riserStartTime: Double? = nil
    private var riserLevel: Float = 0

    init(sampleRate: Double) {
        let rate = sampleRate
        let h = max(64, Int((rate / 100).rounded()))
        let fr = rate / Double(h)
        fs = rate
        hop = h
        frameRate = fr
        alphaMu = Float(1 - exp(-1 / (0.5 * fr)))
        alphaSc = Float(1 - exp(-1 / (3.0 * fr)))
        alphaE = Float(1 - exp(-1 / (1.5 * fr)))
        fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(2048), Int32(vDSP_HANN_NORM))

        let fLo = 40.0
        let fHi = min(14000.0, rate * 0.45)
        var edges = [Int]()
        var prev = 1
        for i in 0...24 {
            let f = fLo * pow(fHi / fLo, Double(i) / 24.0)
            var b = Int((f * 2048.0 / rate).rounded())
            b = max(b, prev + (i == 0 ? 0 : 1))
            b = min(b, 1024 - (24 - i))
            edges.append(b); prev = b
        }
        bandEdges = edges
        for b in 0..<24 {
            let center = 0.5 * Double(edges[b] + edges[b + 1]) * rate / 2048.0
            bandWeight.append(center < 200 ? 1.5 : 1.0)
        }
        lowEdge = max(3, Int((150.0 * 2048.0 / rate).rounded()))
        hfStartBin = max(10, min(1000, Int((3000.0 * 2048.0 / rate).rounded())))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Call when a new track starts so old tempo and envelopes do not linger.
    func reset() { resetState(notify: false) }

    private func resetState(notify: Bool) {
        onsetEnv.removeAll(); lowRing.removeAll(); bandHist.removeAll()
        framesSinceReset = 0; havePrev = false; mu = 0; sc = 0
        lag = 0; tempoConf = 0; pendingCount = 0; lowConfCount = 0
        clockActive = false; beatNumber = 0; badPhaseCount = 0; badPeakCount = 0; phasePeak = 0
        noveltyHist.removeAll(); bassPeak = 0; resetMeter()
        hfRing.removeAll(); hfAccum = 0; hfAccumN = 0; hfBase = 0
        riserHold = 0; riserStartTime = nil; riserLevel = 0
        if notify && consumerLocked { consumerLocked = false; onLost?() }
        consumerLocked = false
    }

    private func loseLock() {
        engineLog("lost beat lock")
        resetMeter()
        lag = 0; clockActive = false; beatNumber = 0; pendingCount = 0; lowConfCount = 0
        badPhaseCount = 0; badPeakCount = 0
        if consumerLocked { consumerLocked = false; onLost?() }
    }

    // MARK: Input

    func feed(_ samples: [Float], startTime: Double) {
        anchorSample = pendingStart + Int64(pending.count)
        anchorTime = startTime
        pending.append(contentsOf: samples)
        while pending.count >= N {
            let endSample = pendingStart + Int64(N)
            let endTime = anchorTime + Double(endSample - anchorSample) / fs
            processFrame(endTime: endTime)
            pending.removeFirst(hop)
            pendingStart += Int64(hop)
        }
    }

    // MARK: Per-frame processing

    private func processFrame(endTime: Double) {
        lastEndTime = endTime

        var rms: Float = 0
        pending.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length(N)) }
        if rms < 2e-4 {
            silentFrames += 1
            if silentFrames == Int(frameRate) {
                if framesSinceReset > 0 { engineLog("silence, resetting") }
                resetState(notify: true)
            }
            return
        }
        silentFrames = 0

        // Window and FFT
        pending.withUnsafeBufferPointer { src in
            windowed.withUnsafeMutableBufferPointer { dst in
                vDSP_vmul(src.baseAddress!, 1, window, 1, dst.baseAddress!, 1, vDSP_Length(N))
            }
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magSq.withUnsafeMutableBufferPointer { m in
                    vDSP_zvmags(&split, 1, m.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Band levels (log compressed RMS magnitude per band)
        magSq.withUnsafeBufferPointer { m in
            for b in 0..<nBands {
                let lo = bandEdges[b], hi = bandEdges[b + 1]
                var s: Float = 0
                vDSP_sve(m.baseAddress! + lo, 1, &s, vDSP_Length(hi - lo))
                bandL[b] = logf(1 + sqrtf(s / Float(hi - lo)))
            }
        }
        var lowS: Float = 0
        magSq.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + 1, 1, &lowS, vDSP_Length(lowEdge - 1)) }
        let lowAmp = sqrtf(lowS)

        // Onset strength: SuperFlux style
        var onset: Float = 0
        if havePrev {
            for b in 0..<nBands {
                var pm = prevL[b]
                if b > 0 { pm = max(pm, prevL[b - 1]) }
                if b < nBands - 1 { pm = max(pm, prevL[b + 1]) }
                let d = bandL[b] - pm
                if d > 0 { onset += d * bandWeight[b] }
            }
        }
        prevL = bandL; havePrev = true

        // Level-independent normalisation
        let n = Float(framesSinceReset + 1)
        if framesSinceReset == 0 { mu = onset }
        mu += (onset - mu) * max(alphaMu, 1 / n)
        let e = max(0, onset - mu)
        sc += (e - sc) * max(alphaSc, 1 / n)
        var en = min(e / max(sc, 0.15), 6)
        if framesSinceReset < 30 { en = 0 }

        // Loudness and high frequency energy (for per-song intensity and risers)
        let db = 20 * log10f(max(rms, 1e-5))
        if framesSinceReset == 0 { energyDB = db }
        energyDB += (db - energyDB) * alphaE
        var hf: Float = 0
        magSq.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + hfStartBin, 1, &hf, vDSP_Length(half - hfStartBin)) }
        hfAccum += 10 * log10f(hf + 1e-2); hfAccumN += 1
        if hfAccumN == 10 {
            hfRing.append(hfAccum / 10); hfAccum = 0; hfAccumN = 0
            if hfRing.count > 300 { hfRing.removeFirst(50) }
        }

        onsetEnv.append(en); lowRing.append(lowAmp); bandHist.append(bandL)
        if onsetEnv.count > 1400 {
            onsetEnv.removeFirst(200); lowRing.removeFirst(200); bandHist.removeFirst(200)
        }
        framesSinceReset += 1

        if framesSinceReset % 5 == 0 { detectDrop() }
        if framesSinceReset % 25 == 0 { updateEnergy(time: endTime) }
        if framesSinceReset >= Int(2.5 * frameRate) {
            if framesSinceReset % 50 == 0 { estimateTempo() }
            if lag > 0 && framesSinceReset % 10 == 0 { estimatePhase() }
        }
        emitBeats()
        updateAccents()

        if endTime - lastStatus >= 2.0 {
            lastStatus = endTime
            let bpm = lag > 0 ? 60.0 * frameRate / lag : 0
            engineLog(String(format: "rms=%.4f bpm=%.1f conf=%.2f peak=%.2f locked=%@ meter=%d score=%.2f",
                             rms, bpm, tempoConf, phasePeak, clockActive ? "yes" : "no", meter, meterScore))
        }
    }

    // MARK: Tempo

    private func tempoWeight(_ l: Int) -> Float {
        let bpm = 60.0 * frameRate / Double(l)
        let x = log2(bpm / 118.0) / 0.9
        return Float(exp(-0.5 * x * x))
    }

    private func estimateTempo() {
        let W = min(onsetEnv.count, Int(4.5 * frameRate))
        guard W >= Int(2.5 * frameRate) else { return }
        var x = Array(onsetEnv.suffix(W))
        var mean: Float = 0
        for v in x { mean += v }
        mean /= Float(W)
        for i in 0..<W { x[i] -= mean }
        var r0: Float = 0
        x.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress!, 1, $0.baseAddress!, 1, &r0, vDSP_Length(W)) }
        r0 /= Float(W)
        guard r0 > 1e-4 else { return }

        let lagMin = Int((frameRate * 60 / 190).rounded(.up))
        let lagMax = min(Int(frameRate * 60 / 62), W / 2 - 2)
        guard lagMax > lagMin + 2 else { return }
        var acf = [Float](repeating: 0, count: lagMax + 3)
        x.withUnsafeBufferPointer { xp in
            for l in (lagMin - 1)...(lagMax + 1) {
                var d: Float = 0
                vDSP_dotpr(xp.baseAddress!, 1, xp.baseAddress! + l, 1, &d, vDSP_Length(W - l))
                acf[l] = d / Float(W - l) / r0
            }
        }

        var bestL = -1
        var bestS: Float = -1
        for l in lagMin...lagMax {
            let s = acf[l] * tempoWeight(l)
            if acf[l] > acf[l - 1] && acf[l] >= acf[l + 1] && s > bestS { bestS = s; bestL = l }
        }
        guard bestL > 0 else { return }

        // Octave check: a fast tempo whose half-tempo period is also well supported is usually
        // the subdivision (hats, eighth notes) rather than the beat.
        if 60.0 * frameRate / Double(bestL) > 140 && bestL * 2 + 2 <= lagMax {
            var l2 = bestL * 2
            for l in (bestL * 2 - 2)...(bestL * 2 + 2) where acf[l] > acf[l2] { l2 = l }
            if acf[l2] >= 0.7 * acf[bestL] { bestL = l2 }
        }

        // Parabolic refinement
        let y0 = acf[bestL - 1], y1 = acf[bestL], y2 = acf[bestL + 1]
        let denom = y0 - 2 * y1 + y2
        var delta: Float = 0
        if abs(denom) > 1e-6 { delta = max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) }
        let lagFrac = Double(bestL) + Double(delta)
        let conf = y1

        if conf < (lag == 0 ? 0.25 : 0.15) {
            lowConfCount += 1
            if lag > 0 && lowConfCount >= 8 { loseLock() }
            return
        }
        lowConfCount = 0

        if lag == 0 {
            lag = lagFrac; tempoConf = conf; pendingCount = 0
            engineLog(String(format: "tempo acquired %.1f bpm conf=%.2f", 60.0 * frameRate / lag, conf))
        } else if abs(lagFrac / lag - 1) < 0.04 {
            lag = 0.6 * lag + 0.4 * lagFrac
            tempoConf = conf; pendingCount = 0
        } else {
            // A different tempo. Only switch if it clearly beats whatever supports the current one.
            var support: Float = 0
            let cl = Int(lag.rounded())
            for l in max(lagMin, cl - 2)...min(lagMax, cl + 2) { support = max(support, acf[l]) }
            if conf > 1.3 * support || support < 0.08 {
                pendingCount += 1
                if pendingCount >= 3 {
                    engineLog(String(format: "tempo switch %.1f -> %.1f bpm", 60.0 * frameRate / lag, 60.0 * frameRate / lagFrac))
                    lag = lagFrac; tempoConf = conf; pendingCount = 0
                    clockActive = false; beatNumber = 0; resetMeter()
                }
            } else {
                pendingCount = 0
            }
        }
    }

    // MARK: Phase and clock

    private func estimatePhase() {
        let T = lag
        let W = min(onsetEnv.count, Int(4.5 * frameRate))
        guard Double(W) > T * 3, T > 8 else { return }
        let x = Array(onsetEnv.suffix(W))
        var es = [Float](repeating: 0, count: W)
        for i in 0..<W {
            let a = i > 0 ? x[i - 1] : x[i]
            let c = i < W - 1 ? x[i + 1] : x[i]
            es[i] = 0.25 * a + 0.5 * x[i] + 0.25 * c
        }
        let pMax = Int(T.rounded(.up))
        let K = min(10, Int(Double(W - 1) / T))
        var scores = [Float](repeating: 0, count: pMax)
        var sum: Float = 0
        for p in 0..<pMax {
            var s: Float = 0
            var wgt: Float = 1
            for k in 0..<K {
                let i = (W - 1) - Int((Double(p) + Double(k) * T).rounded())
                if i < 1 { break }
                s += wgt * es[i]
                wgt *= 0.93
            }
            scores[p] = s; sum += s
        }
        var bestP = 0
        for p in 1..<pMax where scores[p] > scores[bestP] { bestP = p }
        let meanScore = sum / Float(pMax)
        phasePeak = scores[bestP] / max(meanScore, 1e-4)

        // Fractional phase (circular parabola)
        let sm = scores[(bestP - 1 + pMax) % pMax], s0 = scores[bestP], sp = scores[(bestP + 1) % pMax]
        let d = sm - 2 * s0 + sp
        var frac = 0.0
        if abs(d) > 1e-6 { frac = Double(max(-0.5, min(0.5, 0.5 * (sm - sp) / d))) }
        let pFrac = Double(bestP) + frac

        let period = T / frameRate
        let bEst = lastEndTime - pFrac / frameRate - detectOffset

        if !clockActive {
            guard phasePeak >= 1.3 else { return }
            var nb = bEst
            while nb < lastEndTime - 0.02 { nb += period }
            resetMeter()
            nextBeat = nb; clockActive = true; beatNumber = 0; badPhaseCount = 0; badPeakCount = 0
            engineLog(String(format: "beat clock locked: %.1f bpm peak=%.2f", 60.0 / period, phasePeak))
        } else {
            if phasePeak < 1.12 {
                badPeakCount += 1
                if badPeakCount >= 25 { loseLock(); return }
            } else {
                badPeakCount = 0
            }
            guard phasePeak >= 1.15 else { return }
            let n = ((nextBeat - bEst) / period).rounded()
            let cand = bEst + n * period
            let err = cand - nextBeat
            if abs(err) > 0.2 * period {
                badPhaseCount += 1
                if badPhaseCount >= 4 { nextBeat = cand; badPhaseCount = 0 }
            } else {
                badPhaseCount = 0
                nextBeat += 0.3 * err
            }
        }
    }

    private func emitBeats() {
        guard clockActive, lag > 0 else { return }
        let period = lag / frameRate
        while nextBeat < lastEndTime - 0.5 * period { nextBeat += period }
        while nextBeat <= lastEndTime + beatLead {
            beatNumber += 1
            consumerLocked = true
            beatTimes.append(nextBeat)
            let bib = meter > 0 ? (((beatNumber - downbeatPhase) % meter) + meter) % meter : -1
            onBeat?(nextBeat, period, beatNumber, bib, meter)
            if meter == 0 || bib == 0 { evaluateSection(time: nextBeat) }
            nextBeat += period
        }
    }

    // MARK: Meter (which beat is beat one)
    //
    // Every beat gets three accent scores measured around its time: bass level just after it, attack
    // strength, and how much the spectrum changes across it (bass note or chord changes). Those are
    // z-scored, blended, and folded by 3 and by 4. The grouping that explains the most variance wins,
    // and the position with the biggest accent is beat one.

    private func resetMeter() {
        beatTimes.removeAll(); accLow.removeAll(); accOn.removeAll(); accNov.removeAll()
        meter = 0; downbeatPhase = 0
        pendingMeter = 0; pendingPhase = 0; pendingMeterCount = 0; weakMeterCount = 0; meterScore = 0
    }

    private func frameIdx(_ t: Double) -> Int {
        let i = onsetEnv.count - 1 - Int(((lastEndTime - t) * frameRate).rounded())
        return max(0, min(onsetEnv.count - 1, i))
    }

    private func updateAccents() {
        guard clockActive, lag > 0, !onsetEnv.isEmpty else { return }
        let period = lag / frameRate
        while accLow.count < beatTimes.count {
            let t = beatTimes[accLow.count]
            let w = min(0.25, 0.4 * period)
            if lastEndTime < t + 0.03 + max(w, 0.2) { break }       // wait until the whole beat has been heard
            if lastEndTime - t > 10 { accLow.append(0); accOn.append(0); accNov.append(0); continue }

            var on: Float = 0
            let a0 = frameIdx(t + 0.005), a1 = frameIdx(t + 0.07)
            if a1 >= a0 { for i in a0...a1 { on = max(on, onsetEnv[i]) } }

            let l0 = frameIdx(t + 0.03), l1 = max(l0, frameIdx(t + 0.03 + w))
            var low: Float = 0
            for i in l0...l1 { low += lowRing[i] }
            low /= Float(l1 - l0 + 1)

            let b0 = frameIdx(t - 0.25), b1 = max(b0, frameIdx(t - 0.03))
            let c0 = frameIdx(t + 0.03), c1 = max(c0, frameIdx(t + 0.23))
            var diff: Float = 0
            for b in 0..<nBands {
                var before: Float = 0, after: Float = 0
                for i in b0...b1 { before += bandHist[i][b] }
                before /= Float(b1 - b0 + 1)
                for i in c0...c1 { after += bandHist[i][b] }
                after /= Float(c1 - c0 + 1)
                diff += (after - before) * (after - before)
            }
            accLow.append(low); accOn.append(on); accNov.append(sqrtf(diff / Float(nBands)))
            estimateMeter()
        }
    }

    private func estimateMeter() {
        let total = accLow.count
        guard total >= 12 else { return }
        let n = min(total, 40), start = total - n

        func zs(_ a: [Float]) -> [Float] {
            let s = Array(a[start..<total])
            var m: Float = 0
            for v in s { m += v }
            m /= Float(n)
            var v2: Float = 0
            for v in s { v2 += (v - m) * (v - m) }
            let sd = max(sqrtf(v2 / Float(n)), 0.1 * abs(m) + 1e-4)   // relative floor so flat features stay quiet
            return s.map { ($0 - m) / sd }
        }
        let zl = zs(accLow), zo = zs(accOn), zn = zs(accNov)
        var a = [Float](repeating: 0, count: n)
        for j in 0..<n { a[j] = 0.35 * zl[j] + 0.30 * zo[j] + 0.35 * zn[j] }
        var mean: Float = 0
        for v in a { mean += v }
        mean /= Float(n)
        var sst: Float = 0
        for v in a { sst += (v - mean) * (v - mean) }
        guard sst > 1e-3 else { return }

        var bestM = 0, bestPhase = 0
        var bestScore: Float = -1
        for M in [3, 4] {
            var sums = [Float](repeating: 0, count: M), cnt = [Float](repeating: 0, count: M)
            for j in 0..<n { let p = (start + j + 1) % M; sums[p] += a[j]; cnt[p] += 1 }
            var ssb: Float = 0, bm: Float = -1e9
            var bp = 0
            for p in 0..<M where cnt[p] > 0 {
                let m = sums[p] / cnt[p]
                ssb += cnt[p] * (m - mean) * (m - mean)
                if m > bm { bm = m; bp = p }
            }
            let adj = 1 - (1 - ssb / sst) * Float(n - 1) / Float(n - M)   // adjusted R squared
            let score = adj + (M == 4 ? 0.05 : 0)                          // 4/4 is the common case
            if score > bestScore { bestScore = score; bestM = M; bestPhase = bp }
        }
        meterScore = bestScore

        if bestScore < 0.12 {
            if meter != 0 {
                weakMeterCount += 1
                if weakMeterCount >= 6 { engineLog("meter unclear, dropping it"); meter = 0; weakMeterCount = 0 }
            }
            return
        }
        weakMeterCount = 0
        if bestM == meter && bestPhase == downbeatPhase { pendingMeterCount = 0; pendingMeter = 0; return }
        if bestM == pendingMeter && bestPhase == pendingPhase {
            pendingMeterCount += 1
        } else {
            pendingMeter = bestM; pendingPhase = bestPhase; pendingMeterCount = 1
        }
        if pendingMeterCount >= (meter == 0 ? 2 : 5) {
            meter = bestM; downbeatPhase = bestPhase
            pendingMeterCount = 0; pendingMeter = 0
            engineLog(String(format: "meter %d, downbeat phase %d, score %.2f", meter, downbeatPhase, bestScore))
        }
    }

    // MARK: Energy relative to the song, and risers
    //
    // A histogram of this song's loudness (1 dB bins, slowly forgetting) gives its median and spread.
    // Intensity says where the current loudness sits in that range, so a quiet song's chorus and a loud
    // song's chorus both read as high. The model can be saved per track and loaded when the song returns.

    func exportEnergyModel() -> [Float] { energyHist + [energyCount] }

    func loadEnergyModel(_ m: [Float]?) {
        if let m = m, m.count == 82 {
            energyHist = Array(m[0..<81]); energyCount = m[81]
        } else {
            energyHist = [Float](repeating: 0, count: 81); energyCount = 0
        }
    }

    private func updateEnergy(time: Double) {
        let bin = max(0, min(80, Int((energyDB + 80).rounded())))
        for i in 0..<81 { energyHist[i] *= 0.9995 }
        energyCount = energyCount * 0.9995 + 1
        energyHist[bin] += 1

        func pct(_ q: Float) -> Float {
            let target = q * energyCount
            var acc: Float = 0
            for i in 0..<81 { acc += energyHist[i]; if acc >= target { return Float(i) - 80 } }
            return 0
        }
        let p10 = pct(0.1), p50 = pct(0.5), p90 = pct(0.9)
        let spread = max(p90 - p10, 5)                  // a floor keeps a steady song from flickering
        var level = 0.5 + (energyDB - p50) / (1.2 * spread)
        level = max(0, min(1, level))
        let conf = min(1, energyCount / 80)             // trust grows over the first ~20 s
        level = 0.5 + (level - 0.5) * conf
        onEnergy?(time, Double(level), Double(updateRiser(time: time)))
    }

    // A riser is high frequency energy climbing steadily over several seconds.
    private func updateRiser(time: Double) -> Float {
        let n = 40
        guard hfRing.count >= n else { return 0 }
        let y = Array(hfRing.suffix(n))
        var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        for i in 0..<n {
            let x = Float(i)
            sx += x; sy += y[i]; sxx += x * x; sxy += x * y[i]; syy += y[i] * y[i]
        }
        let nf = Float(n)
        let cov = sxy - sx * sy / nf
        let vx = sxx - sx * sx / nf
        let vy = syy - sy * sy / nf
        let slope = vx > 0 ? cov / vx * 10 : 0                     // dB per second
        let r2 = (vx > 0 && vy > 1e-6) ? (cov * cov) / (vx * vy) : 0
        var head: Float = 0, tail: Float = 0
        for i in 0..<5 { head += y[i]; tail += y[n - 1 - i] }
        let rise = (tail - head) / 5                               // dB gained across the window

        if slope > 1.2 && r2 > 0.55 && rise > 5 {
            riserHold += 1
        } else if slope < 0.3 {
            riserHold = 0
        } else {
            riserHold = max(0, riserHold - 1)
        }
        if riserHold >= 3 {
            if riserStartTime == nil { riserStartTime = time; engineLog(String(format: "riser started, slope %.1f dB/s", slope)) }
            riserLevel = Float(min(1, (time - (riserStartTime ?? time)) / 5.0))
        } else {
            if riserStartTime != nil { engineLog("riser ended") }
            riserStartTime = nil
            riserLevel *= 0.6
        }
        return riserLevel
    }

    // MARK: Section change (beat-synchronous spectral novelty)

    private func evaluateSection(time: Double) {
        let bf = Int(lag.rounded())
        guard bf > 10, bandHist.count >= 8 * bf else { return }
        let count = bandHist.count
        var recent = [Float](repeating: 0, count: nBands)
        var prior = [Float](repeating: 0, count: nBands)
        for i in (count - 2 * bf)..<count { for b in 0..<nBands { recent[b] += bandHist[i][b] } }
        for i in (count - 8 * bf)..<(count - 2 * bf) { for b in 0..<nBands { prior[b] += bandHist[i][b] } }
        var acc: Float = 0
        for b in 0..<nBands {
            let diff = recent[b] / Float(2 * bf) - prior[b] / Float(6 * bf)
            acc += diff * diff
        }
        let novelty = sqrtf(acc / Float(nBands))
        if noveltyHist.count >= 8 {
            var m: Float = 0
            for v in noveltyHist { m += v }
            m /= Float(noveltyHist.count)
            var s: Float = 0
            for v in noveltyHist { s += (v - m) * (v - m) }
            s = sqrtf(s / Float(noveltyHist.count))
            let z = (novelty - m) / max(s, 0.05)
            if z > 2.5 && novelty > 0.35 && time - lastSectionTime > 5 {
                lastSectionTime = time
                engineLog(String(format: "section change novelty=%.2f z=%.1f", novelty, z))
                onSection?(time)
            }
        }
        noveltyHist.append(novelty)
        if noveltyHist.count > 32 { noveltyHist.removeFirst() }
    }

    // MARK: Drop (bass returns after a bass-less stretch)

    // A drop is bass coming back at full strength after at least two seconds with no kick-level bass.
    // The reference level is a slowly decaying peak so it survives a long breakdown.
    private func detectDrop() {
        let nCur = 20, sub = 25, quietSpan = 200
        let c = lowRing.count
        guard c >= quietSpan + nCur + sub else { return }

        func mean(_ from: Int, _ count: Int) -> Float {
            var s: Float = 0
            for i in from..<(from + count) { s += lowRing[i] }
            return s / Float(count)
        }
        bassPeak = max(bassPeak * 0.9988, mean(c - sub, sub))   // ~30 s half-life at 20 updates/s

        let cur = mean(c - nCur, nCur)
        var quietMax: Float = 0, quietSum: Float = 0, blocks = 0
        var j = c - nCur - quietSpan
        while j + sub <= c - nCur {
            let m = mean(j, sub)
            quietMax = max(quietMax, m); quietSum += m; blocks += 1
            j += sub
        }
        let quietMean = quietSum / Float(max(blocks, 1))
        let t = lastEndTime - 0.06
        if quietMax < 0.35 * bassPeak && cur > 0.6 * bassPeak && cur > 3 * max(quietMean, 1e-3) && t - lastDropTime > 6 {
            lastDropTime = t
            engineLog(String(format: "DROP cur=%.1f quietMax=%.1f peak=%.1f", cur, quietMax, bassPeak))
            onDrop?(t)
        }
    }
}

// MARK: - System audio tap (CATap, no microphone)

final class SystemAudioTap {
    /// mono samples, host-clock seconds of the first sample
    var onAudio: (([Float], Double) -> Void)?
    private(set) var sampleRate: Double = 48000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func prepare() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        var tid = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tid) == noErr else { engineLog("tap creation failed"); return false }
        tapID = tid

        var uid: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString>.stride)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyUID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        withUnsafeMutablePointer(to: &uid) { _ = AudioObjectGetPropertyData(tid, &addr, 0, nil, &sz, $0) }

        var fmt = AudioStreamBasicDescription()
        var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var faddr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyFormat),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        if AudioObjectGetPropertyData(tid, &faddr, 0, nil, &fsz, &fmt) == noErr, fmt.mSampleRate > 8000 {
            sampleRate = fmt.mSampleRate
            engineLog("tap format: \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, flags=\(fmt.mFormatFlags)")
        } else {
            engineLog("tap format unavailable, assuming 48000")
        }

        let cfg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PriorityBeatTap",
            kAudioAggregateDeviceUIDKey: "com.graham.prioritymanagement.beattap",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(cfg as CFDictionary, &aid) == noErr else {
            engineLog("aggregate device creation failed"); return false
        }
        aggID = aid
        return true
    }

    func begin() -> Bool {
        typealias IOProc = @convention(block) (
            UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>,
            UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>,
            UnsafePointer<AudioTimeStamp>) -> Void
        let block: IOProc = { [weak self] _, inputData, inputTime, _, _ in
            guard let self = self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard abl.count > 0 else { return }
            var mono: [Float]
            if abl.count == 1 {
                let buf = abl[0]
                let ch = max(1, Int(buf.mNumberChannels))
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                guard frames > 0 else { return }
                mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<ch { s += p[i * ch + c] }
                    mono[i] = s / Float(ch)
                }
            } else {
                var frames = Int.max
                for b in abl { frames = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size) }
                guard frames > 0, frames != Int.max else { return }
                mono = [Float](repeating: 0, count: frames)
                for b in abl {
                    guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { mono[i] += p[i] }
                }
                let inv = 1 / Float(abl.count)
                for i in 0..<frames { mono[i] *= inv }
            }
            let ticks = inputTime.pointee.mHostTime
            let t = ticks != 0 ? hostSeconds(fromTicks: ticks) : hostSecondsNow()
            self.onAudio?(mono, t)
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil, block) == noErr,
              AudioDeviceStart(aggID, ioProcID) == noErr else {
            engineLog("IO proc failed"); return false
        }
        engineLog("tap running")
        return true
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, ioProcID)
            if let p = ioProcID { AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown); ioProcID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - Output latency of the default output device

func defaultOutputLatencySeconds() -> Double {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
          dev != 0 else { return 0 }

    func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                                           mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        _ = AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v)
        return v
    }
    let outScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeOutput)
    var rate: Float64 = 0
    var rsz = UInt32(MemoryLayout<Float64>.size)
    var raddr = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate),
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    _ = AudioObjectGetPropertyData(dev, &raddr, 0, nil, &rsz, &rate)
    guard rate > 1000 else { return 0 }

    var frames = Double(u32(dev, AudioObjectPropertySelector(kAudioDevicePropertyLatency), outScope))
    frames += Double(u32(dev, AudioObjectPropertySelector(kAudioDevicePropertySafetyOffset), outScope))
    frames += Double(u32(dev, AudioObjectPropertySelector(kAudioDevicePropertyBufferFrameSize), outScope))

    // First output stream latency
    var ssz: UInt32 = 0
    var saddr = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreams),
        mScope: outScope,
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    if AudioObjectGetPropertyDataSize(dev, &saddr, 0, nil, &ssz) == noErr, ssz >= UInt32(MemoryLayout<AudioStreamID>.size) {
        var streams = [AudioStreamID](repeating: 0, count: Int(ssz) / MemoryLayout<AudioStreamID>.size)
        if AudioObjectGetPropertyData(dev, &saddr, 0, nil, &ssz, &streams) == noErr, let first = streams.first {
            frames += Double(u32(first, AudioObjectPropertySelector(kAudioStreamPropertyLatency),
                                 AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)))
        }
    }
    return frames / rate
}

// MARK: - Engine (tap + analyzer + latency compensated callbacks on the main queue)

final class BeatEngine {
    /// period in seconds, beat number since lock (1 = first beat after lock), beat in bar (0 = beat one, -1 unknown), meter (3, 4 or 0)
    var onBeat: ((Double, Int, Int, Int) -> Void)?
    var onDrop: (() -> Void)?
    var onSection: (() -> Void)?
    var onLost: (() -> Void)?
    /// intensity (0 to 1, relative to this song) and riser (0 to 1), about four times a second
    var onEnergy: ((Double, Double) -> Void)?
    /// Positive delays the visuals, negative advances them. Use to fine tune sync by ear.
    var visualOffset: Double = 0.0

    private let tap = SystemAudioTap()
    private var analyzer: BeatAnalyzer?
    private let queue = DispatchQueue(label: "beatengine.analysis", qos: .userInteractive)
    private let epochLock = NSLock()
    private var epochValue = 0
    private var outLatency: Double = 0
    private var lastLatencyCheck: Double = -100

    // Loudness models remembered per track (analysis queue only)
    private var energyStore: [String: [Float]] = [:]
    private var currentTrackKey: String?
    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PriorityManagement")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("energy.json")
    }()

    private var epoch: Int { epochLock.lock(); defer { epochLock.unlock() }; return epochValue }
    private func bumpEpoch() { epochLock.lock(); epochValue += 1; epochLock.unlock() }

    func start() -> Bool {
        guard tap.prepare() else { return false }
        let a = BeatAnalyzer(sampleRate: tap.sampleRate)
        analyzer = a
        loadStore()
        if let k = currentTrackKey { a.loadEnergyModel(energyStore[k]) }
        a.onEnergy = { [weak self] _, intensity, riser in
            DispatchQueue.main.async { self?.onEnergy?(intensity, riser) }
        }

        a.onBeat = { [weak self] time, period, number, bib, meter in
            guard let self = self else { return }
            let fire = time + self.latency() + self.visualOffset
            let delay = fire - hostSecondsNow()
            if delay < -0.5 * period { return }
            let ep = self.epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                guard let self = self, ep == self.epoch else { return }
                self.onBeat?(period, number, bib, meter)
            }
        }
        a.onDrop = { [weak self] time in
            guard let self = self else { return }
            let delay = time + self.latency() + self.visualOffset - hostSecondsNow()
            let ep = self.epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                guard let self = self, ep == self.epoch else { return }
                self.onDrop?()
            }
        }
        a.onSection = { [weak self] time in
            guard let self = self else { return }
            let delay = time + self.latency() + self.visualOffset - hostSecondsNow()
            let ep = self.epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                guard let self = self, ep == self.epoch else { return }
                self.onSection?()
            }
        }
        a.onLost = { [weak self] in
            guard let self = self else { return }
            self.bumpEpoch()
            DispatchQueue.main.async { [weak self] in self?.onLost?() }
        }

        tap.onAudio = { [weak self] mono, t in
            guard let self = self else { return }
            self.queue.async { self.analyzer?.feed(mono, startTime: t) }
        }
        guard tap.begin() else { return false }
        engineLog("engine started at \(tap.sampleRate) Hz")
        return true
    }

    /// Call on pause so the analyzer starts fresh (the song's loudness model is kept).
    func reset() {
        bumpEpoch()
        queue.async { [weak self] in self?.analyzer?.reset() }
    }

    /// Call when a different track starts. Saves the previous song's loudness model and loads this one's if it has been heard before.
    func beginTrack(_ key: String) {
        bumpEpoch()
        queue.async { [weak self] in
            guard let self = self, let a = self.analyzer else { return }
            if let k = self.currentTrackKey { self.energyStore[k] = a.exportEnergyModel() }
            self.currentTrackKey = key
            a.loadEnergyModel(self.energyStore[key])
            a.reset()
            self.saveStore()
        }
    }

    func stop() {
        queue.sync {
            if let k = currentTrackKey, let a = analyzer { energyStore[k] = a.exportEnergyModel() }
            saveStore()
        }
        tap.stop()
        bumpEpoch()
    }

    private func saveStore() {
        if energyStore.count > 300 {
            for k in energyStore.keys.prefix(energyStore.count - 300) where k != currentTrackKey { energyStore[k] = nil }
        }
        if let data = try? JSONEncoder().encode(energyStore) { try? data.write(to: BeatEngine.storeURL, options: .atomic) }
    }

    private func loadStore() {
        if let d = try? Data(contentsOf: BeatEngine.storeURL),
           let s = try? JSONDecoder().decode([String: [Float]].self, from: d) { energyStore = s }
    }

    // Runs on the analysis queue
    private func latency() -> Double {
        let now = hostSecondsNow()
        if now - lastLatencyCheck > 5 {
            lastLatencyCheck = now
            outLatency = defaultOutputLatencySeconds()
            engineLog(String(format: "output latency %.0f ms", outLatency * 1000))
        }
        return outLatency
    }
}
