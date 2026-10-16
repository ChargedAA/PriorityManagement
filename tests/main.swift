import Foundation
import AVFoundation

// Offline harness: feeds a wav file through BeatAnalyzer and prints events.
// usage: beattest file.wav   (VERBOSE=1 for analyzer log lines)

engineLogSink = nil
if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
    engineLogSink = { print("LOG \($0)") }
}

guard CommandLine.arguments.count > 1 else { print("usage: beattest file.wav"); exit(1) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url)
let sr = file.processingFormat.sampleRate
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buf)
let ch = Int(buf.format.channelCount)
let n = Int(buf.frameLength)
var mono = [Float](repeating: 0, count: n)
for c in 0..<ch {
    let p = buf.floatChannelData![c]
    for i in 0..<n { mono[i] += p[i] / Float(ch) }
}

let analyzer = BeatAnalyzer(sampleRate: sr)
var now = 0.0
analyzer.onBeat = { t, p, k, bib, m in print(String(format: "BEAT %.4f %.4f %d %d %d", t, p, k, bib, m)) }
analyzer.onDrop = { t in print(String(format: "DROP %.4f", t)) }
analyzer.onSection = { t in print(String(format: "SECTION %.4f", t)) }
analyzer.onLost = { print(String(format: "LOST %.4f", now)) }
analyzer.onEnergy = { t, i, r in print(String(format: "ENERGY %.2f %.3f %.3f", t, i, r)) }

// Optional: MODEL_IN loads a saved loudness model first, MODEL_OUT saves it at the end
if let p = ProcessInfo.processInfo.environment["MODEL_IN"],
   let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
   let m = try? JSONDecoder().decode([Float].self, from: d) { analyzer.loadEnergyModel(m) }

let chunk = 1024
var i = 0
while i < n {
    let end = min(n, i + chunk)
    now = Double(end) / sr
    analyzer.feed(Array(mono[i..<end]), startTime: Double(i) / sr)
    i = end
}
if let p = ProcessInfo.processInfo.environment["MODEL_OUT"],
   let d = try? JSONEncoder().encode(analyzer.exportEnergyModel()) { try? d.write(to: URL(fileURLWithPath: p)) }
print("DONE")
