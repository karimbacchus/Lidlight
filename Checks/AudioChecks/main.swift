// Audio module checks (synthetic audio only). Run: swift run --scratch-path .build-audio AudioChecks

import Foundation
import TestKit
@testable import LidlightAudio

let t = TestRun("Audio")
let sampleRate = 48_000.0

// MARK: Synthetic signal helpers

/// Deterministic noise in -1...1.
struct NoiseSource {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

/// Adds `body(t)` for t in 0..<duration starting at `start` seconds.
func add(_ signal: inout [Float], at start: Double, duration: Double, _ body: (Double) -> Double) {
    let first = Int(start * sampleRate)
    let count = Int(duration * sampleRate)
    for i in 0..<count where first + i < signal.count {
        signal[first + i] += Float(body(Double(i) / sampleRate))
    }
}

func kick(_ signal: inout [Float], at start: Double, amplitude: Double = 0.7) {
    add(&signal, at: start, duration: 0.3) { sin(2 * .pi * 60 * $0) * exp(-$0 / 0.07) * amplitude }
}

func hat(_ signal: inout [Float], at start: Double, amplitude: Double = 0.3) {
    add(&signal, at: start, duration: 0.02) { sin(2 * .pi * 8000 * $0) * exp(-$0 / 0.004) * amplitude }
}

func noiseFloor(seconds: Double, amplitude: Float = 0.002) -> [Float] {
    var rng = NoiseSource()
    return (0..<Int(seconds * sampleRate)).map { _ in rng.next() * amplitude }
}

func kickTrack(bpm: Double, seconds: Double, offset: Double = 0.25) -> (signal: [Float], kickTimes: [Double]) {
    var signal = noiseFloor(seconds: seconds)
    var times: [Double] = []
    var time = offset
    while time < seconds - 0.4 {
        kick(&signal, at: time)
        times.append(time)
        time += 60 / bpm
    }
    return (signal, times)
}

/// Runs a detector over `signal` in 512-sample chunks, also checking `level` stays within 0...1.
func detect(_ signal: [Float]) -> (beats: [BeatDetector.Beat], levelInRange: Bool, maxLevel: Double) {
    let detector = BeatDetector(sampleRate: sampleRate)
    var beats: [BeatDetector.Beat] = []
    var inRange = true
    var maxLevel = 0.0
    var index = 0
    while index < signal.count {
        let end = min(index + 512, signal.count)
        beats += detector.process(Array(signal[index..<end]))
        inRange = inRange && detector.level >= 0 && detector.level <= 1
        maxLevel = max(maxLevel, detector.level)
        index = end
    }
    return (beats, inRange, maxLevel)
}

func intervals(_ beats: [BeatDetector.Beat]) -> [Double] {
    zip(beats.dropFirst(), beats).map { $0.time - $1.time }
}

func checkTempo(bpm: Double) {
    t.test("\(Int(bpm)) BPM kick track") {
        let seconds = 20.0
        let (signal, _) = kickTrack(bpm: bpm, seconds: seconds)
        let result = detect(signal)
        let rate = Double(result.beats.count) / seconds
        let expected = bpm / 60
        let gaps = intervals(result.beats)
        let mean = gaps.reduce(0, +) / Double(max(gaps.count, 1))
        print("    \(Int(bpm)) BPM: \(String(format: "%.2f", rate)) beats/s (expected \(String(format: "%.2f", expected))), mean interval \(String(format: "%.3f", mean)) s, \(result.beats.count) beats")
        t.expectClose(rate, expected, tolerance: expected * 0.10)
        t.expectClose(mean, 60 / bpm, tolerance: 0.03)
        t.expect(gaps.allSatisfy { abs($0 - 60 / bpm) < 0.06 }, "inter-beat intervals should stay near \(60 / bpm) s")
        t.expect(result.levelInRange, "level outside 0...1")
        t.expect(result.beats.allSatisfy { $0.strength >= 0 && $0.strength <= 1 })
    }
}

// MARK: Beat detection

checkTempo(bpm: 120)
checkTempo(bpm: 90)
checkTempo(bpm: 150)

t.test("silence produces no beats and zero level") {
    let result = detect([Float](repeating: 0, count: Int(10 * sampleRate)))
    t.expectEqual(result.beats.count, 0)
    t.expectClose(result.maxLevel, 0, tolerance: 1e-9)
}

t.test("quiet noise floor produces no beats") {
    let result = detect(noiseFloor(seconds: 10))
    t.expectEqual(result.beats.count, 0)
}

t.test("white noise produces (almost) no beats") {
    var rng = NoiseSource()
    let signal = (0..<Int(20 * sampleRate)).map { _ in rng.next() * 0.3 }
    let result = detect(signal)
    print("    white noise: \(result.beats.count) beats in 20 s")
    t.expect(result.beats.count <= 2, "got \(result.beats.count)")
    t.expect(result.levelInRange)
}

t.test("hi-hat-only track produces no beats") {
    var signal = noiseFloor(seconds: 15)
    var time = 0.2
    while time < 14.5 { hat(&signal, at: time); time += 0.125 }
    let result = detect(signal)
    print("    hi-hats only: \(result.beats.count) beats in 15 s")
    t.expectEqual(result.beats.count, 0)
}

t.test("music-like mix at 128 BPM aligns with kicks") {
    let bpm = 128.0, seconds = 20.0
    let beatLength = 60 / bpm
    var signal = noiseFloor(seconds: seconds)
    var kicks: [Double] = []
    var bar = 0
    while Double(bar) * beatLength * 4 < seconds - 2 {
        for beat in 0..<4 {
            let time = 0.25 + (Double(bar) * 4 + Double(beat)) * beatLength
            kick(&signal, at: time, amplitude: 0.6)
            kicks.append(time)
            if beat == 1 || beat == 3 {  // snare: noise burst + body tone
                var rng = NoiseSource(state: UInt64(bar * 4 + beat + 1))
                add(&signal, at: time, duration: 0.15) { (rng.next() * 0.25 + Float(sin(2 * .pi * 200 * $0)) * 0.2).asDouble * exp(-$0 / 0.04) }
            }
            hat(&signal, at: time + beatLength / 2)
            hat(&signal, at: time + beatLength / 4, amplitude: 0.15)
        }
        bar += 1
    }
    // Sustained bass line at 55 Hz, quieter than the kick, re-triggered every half beat.
    var time = 0.25
    while time < seconds - 1 {
        add(&signal, at: time, duration: beatLength / 2) { sin(2 * .pi * 55 * $0) * 0.12 * min(1, $0 * 200) }
        time += beatLength / 2
    }
    let result = detect(signal)
    let matched = kicks.filter { kick in result.beats.contains { $0.time >= kick - 0.01 && $0.time <= kick + 0.05 } }
    let aligned = result.beats.filter { beat in kicks.contains { beat.time >= $0 - 0.01 && beat.time <= $0 + 0.05 } }
    let recall = Double(matched.count) / Double(kicks.count)
    let precision = Double(aligned.count) / Double(max(result.beats.count, 1))
    print("    128 BPM mix: \(result.beats.count) beats for \(kicks.count) kicks, recall \(String(format: "%.2f", recall)), precision \(String(format: "%.2f", precision))")
    t.expect(recall >= 0.9, "recall \(recall)")
    t.expect(precision >= 0.9, "precision \(precision)")
    t.expect(result.levelInRange)
}

t.test("accented kicks are flagged strong, regular ones are not") {
    var signal = noiseFloor(seconds: 20)
    var time = 0.25
    var index = 0
    while time < 19.5 {
        kick(&signal, at: time, amplitude: index % 4 == 0 ? 0.9 : 0.4)
        time += 0.5
        index += 1
    }
    let result = detect(signal)
    let strong = result.beats.filter(\.isStrong).count
    print("    accents: \(strong) strong of \(result.beats.count) beats")
    t.expect(strong >= 2 && Double(strong) <= Double(result.beats.count) * 0.4, "strong count \(strong)")
    t.expect(result.beats.allSatisfy { $0.strength >= 0 && $0.strength <= 1 })
}

t.test("level follows bass energy and stays within 0...1") {
    let (signal, _) = kickTrack(bpm: 120, seconds: 6)
    let result = detect(signal)
    print("    peak level on kicks: \(String(format: "%.2f", result.maxLevel))")
    t.expect(result.maxLevel > 0.5)
    t.expect(result.levelInRange)
}

t.test("reset forgets history") {
    let detector = BeatDetector(sampleRate: sampleRate)
    detector.process(kickTrack(bpm: 120, seconds: 5).signal)
    detector.reset()
    t.expectClose(detector.level, 0, tolerance: 1e-12)
    t.expectEqual(detector.process(noiseFloor(seconds: 2)).count, 0)
}

t.test("works at 44.1 kHz") {
    let rate = 44_100.0
    var signal = [Float](repeating: 0, count: Int(10 * rate))
    var time = 0.25
    while time < 9.5 {
        let first = Int(time * rate)
        for i in 0..<Int(0.3 * rate) where first + i < signal.count {
            let s = Double(i) / rate
            signal[first + i] = Float(sin(2 * .pi * 60 * s) * exp(-s / 0.07) * 0.7)
        }
        time += 0.5
    }
    let beats = BeatDetector(sampleRate: rate).process(signal)
    print("    44.1 kHz: \(beats.count) beats in 10 s")
    t.expect(beats.count >= 17 && beats.count <= 21)
}

// MARK: Ring buffer

t.test("ring buffer preserves order across wraparound") {
    let ring = MonoRingBuffer(minimumCapacity: 64)
    var nextWrite: Float = 0, nextRead: Float = 0
    var scratch = [Float](repeating: 0, count: 40)
    var out = [Float](repeating: 0, count: 40)
    for round in 0..<500 {
        let writeCount = 1 + (round * 7) % 37
        for i in 0..<writeCount { scratch[i] = nextWrite + Float(i) }
        let stored = scratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: writeCount) }
        nextWrite += Float(stored)
        // Samples that didn't fit were dropped from the end; keep the sequence contiguous.
        let readCount = 1 + (round * 11) % 29
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: readCount) }
        for i in 0..<got {
            if out[i] != nextRead + Float(i) { t.fail("round \(round): expected \(nextRead + Float(i)), got \(out[i])"); return }
        }
        nextRead += Float(got)
    }
    t.expect(ring.availableToRead >= 0)
}

t.test("ring buffer drops what does not fit and reports counts") {
    let ring = MonoRingBuffer(minimumCapacity: 16)
    let data = [Float](repeating: 1, count: 40)
    let stored = data.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 40) }
    t.expectEqual(stored, 16)
    t.expectEqual(ring.availableToRead, 16)
    var out = [Float](repeating: 0, count: 40)
    t.expectEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 40) }, 16)
    t.expectEqual(ring.availableToRead, 0)
}

t.test("ring buffer is consistent with a concurrent producer and consumer") {
    let ring = MonoRingBuffer(minimumCapacity: 1024)
    let total = 400_000
    let producer = Thread {
        var next: Float = 0
        var chunk = [Float](repeating: 0, count: 100)
        while Int(next) < total {
            for i in 0..<100 { chunk[i] = next + Float(i) }
            let stored = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 100) }
            if stored < 100 { next += Float(stored); usleep(50) } else { next += 100 }
            // Partial writes drop the tail of the chunk, so the consumer sees a gap-free prefix of each chunk.
            if stored < 100 && stored > 0 { next += Float(100 - stored) }
        }
    }
    producer.start()
    var last: Float = -1
    var monotonic = true
    var out = [Float](repeating: 0, count: 256)
    let deadline = Date().addingTimeInterval(10)
    var seen = 0
    while last < Float(total - 100) && Date() < deadline {
        let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 256) }
        for i in 0..<n { if out[i] <= last { monotonic = false }; last = out[i] }
        seen += n
        if n == 0 { usleep(100) }
    }
    t.expect(monotonic, "samples must arrive in increasing order")
    t.expect(seen > 0)
}

t.finish()

extension Float { var asDouble: Double { Double(self) } }
