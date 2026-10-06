import XCTest

@testable import OpenSuperWhisper

/// Long dictation's pure parts: where the growing WAV is cut and how unfinished sentences carry
/// over to the next chunk.
final class LongDictationCoreTests: XCTestCase {
    private typealias Core = LongDictationCore
    private let sr = 16000
    private let params = LongDictationCore.CutParameters(targetSeconds: 30, maxSeconds: 45,
                                                         minGapMs: 300, silenceDb: -40)
    private var seed: UInt32 = 1

    /// Deterministic noise in -1...1.
    private func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 23) - 1
    }

    /// Speech-like noise with 100 ms dips, never long enough to count as a pause.
    private func speech(_ seconds: Double, amp: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { i in
            noise() * ((i / (sr / 10)) % 12 == 11 ? amp * 0.02 : amp)
        }
    }

    private func silence(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { _ in noise() * 0.001 }
    }

    private func seconds(_ samples: Int) -> Double { Double(samples) / Double(sr) }

    func testCutsInTheMiddleOfTheFirstPauseAfterTheTarget() {
        let samples = speech(20) + silence(0.6) + speech(13) + silence(0.5) + speech(7)
        let cut = Core.findCut(samples: samples, params)
        XCTAssertEqual(seconds(cut?.at ?? 0), 33.85, accuracy: 0.05)
        XCTAssertEqual(cut?.hard, false)
    }

    func testNoisyMicrophoneStillCutsAtAQuieterGap() {
        // Background around -31 dBFS, the gap around -39 dBFS: both above the -40 dB setting.
        let background: (Double, Float) -> [Float] = { s, amp in
            (0..<Int(s * Double(self.sr))).map { _ in self.noise() * amp }
        }
        let talk: (Double) -> [Float] = { s in zip(self.speech(s), background(s, 0.05)).map(+) }
        let samples = talk(31) + background(0.6, 0.02) + talk(10)
        let cut = Core.findCut(samples: samples, params)
        XCTAssertEqual(seconds(cut?.at ?? 0), 31.3, accuracy: 0.05)
        XCTAssertEqual(cut?.hard, false)
    }

    func testWaitsBeforeTheTargetAndBeforeMaxWithoutAPause() {
        XCTAssertNil(Core.findCut(samples: speech(10) + silence(1) + speech(5), params))
        XCTAssertNil(Core.findCut(samples: speech(38), params))
    }

    func testCutsAtTheQuietestPointWithoutAPause() {
        let samples = speech(40) + speech(0.4, amp: 0.05) + speech(10)
        let cut = Core.findCut(samples: samples, params)
        XCTAssertEqual(seconds(cut?.at ?? 0), 40.2, accuracy: 0.25)
        XCTAssertLessThanOrEqual(cut?.at ?? 0, 45 * sr)
        XCTAssertEqual(cut?.hard, true)
    }

    func testChunksLeaveTheUncutRest() {
        let samples = speech(33) + silence(0.5) + speech(32) + silence(0.5) + speech(5)
        let split = Core.chunks(samples: samples, params)
        XCTAssertEqual(split.chunks.count, 2)
        XCTAssertEqual(seconds(split.chunks[0].samples.count), 33.24, accuracy: 0.05)
        XCTAssertEqual(split.consumed, split.chunks.map(\.samples.count).reduce(0, +))
    }

    func testChunkAfterAHardCutRepeatsTheOverlap() {
        let samples = speech(50) + speech(10)
        let split = Core.chunks(samples: samples, params)
        XCTAssertEqual(split.chunks.count, 1)
        XCTAssertTrue(split.chunks[0].hardCut)
        let overlap = Int(Core.overlapSeconds * Double(sr))
        XCTAssertEqual(split.consumed, split.chunks[0].samples.count - overlap)
        XCTAssertEqual(Array(samples[split.consumed..<split.chunks[0].samples.count]),
                       Array(split.chunks[0].samples.suffix(overlap)))
    }

    func testSpliceDropsTheDoubledWords() {
        let r = Core.spliceOverlap(previous: "We met at the station and then", next: "and then we went home.")
        XCTAssertEqual(r.previous, "We met at the station and then")
        XCTAssertEqual(r.next, "we went home.")
    }

    func testSpliceDropsAFragmentOnEitherSide() {
        var r = Core.spliceOverlap(previous: "We walked to the old sta", next: "to the old station, Then")
        XCTAssertEqual(r.previous, "We walked to the old")
        XCTAssertEqual(r.next, "station, Then")
        r = Core.spliceOverlap(previous: "We walked to the old station", next: "he old station, then home")
        XCTAssertEqual(r.previous, "We walked to the old station")
        XCTAssertEqual(r.next, "then home")
    }

    func testSpliceWithoutSharedWordsKeepsBoth() {
        let r = Core.spliceOverlap(previous: "First part ends here", next: "here second part begins")
        XCTAssertEqual(r.previous, "First part ends here")
        XCTAssertEqual(r.next, "here second part begins")
    }

    func testSilentAudioIsSkippedAndAnySoundIsNot() {
        XCTAssertTrue(Core.isSilent(samples: silence(2), sampleRate: sr, silenceDb: -40))
        XCTAssertFalse(Core.isSilent(samples: silence(2) + speech(0.1) + silence(2), sampleRate: sr, silenceDb: -40))
        XCTAssertTrue(Core.isSilent(samples: [], sampleRate: sr, silenceDb: -40))
    }

    func testFindCutWithoutWholeFramesWaits() {
        var p = params
        p.sampleRate = 0
        XCTAssertNil(Core.findCut(samples: speech(1), p))
    }

    func testReadsAGrowingStereoWAVWithPaddingChunk() throws {
        var wav = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put32(0)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(3); put16(2); put32(16000); put32(128000); put16(8); put16(32)
        wav.append(contentsOf: Array("FLLR".utf8)); put32(5); wav.append(contentsOf: [0, 0, 0, 0, 0, 0])
        wav.append(contentsOf: Array("data".utf8)); put32(0)
        for value: Float in [0.5, -0.5, 0.2, 0.4, 1] { put32(value.bitPattern) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try XCTUnwrap(Core.readMono(url: url, fromFrame: 0))
        XCTAssertEqual(read.sampleRate, 16000)
        XCTAssertEqual(read.samples.count, 2)
        XCTAssertEqual(read.samples[1], 0.3, accuracy: 1e-6)
        XCTAssertEqual(Core.readMono(url: url, fromFrame: 1)?.samples.count, 1)
    }

    func testWrittenChunkRoundTrips() {
        let data = Core.wavData(samples: [0.25, -0.75], sampleRate: 16000)
        let layout = Core.parseWAVLayout(data)
        XCTAssertEqual(layout, Core.WAVLayout(dataOffset: 44, channels: 1, sampleRate: 16000))
        XCTAssertEqual(Core.monoSamples(interleaved: data.subdata(in: 44..<data.count), channels: 1),
                       [0.25, -0.75])
    }

    func testCarryKeepsTheUnfinishedSentence() {
        var r = Core.carry(pending: "", chunk: "Hello there. This is a test and")
        XCTAssertEqual(r.complete, "Hello there.")
        XCTAssertEqual(r.pending, "This is a test and")
        r = Core.carry(pending: r.pending, chunk: "it continues! More")
        XCTAssertEqual(r.complete, "This is a test and it continues!")
        XCTAssertEqual(r.pending, "More")
    }

    func testCarryWithoutASentenceEndKeepsEverything() {
        let r = Core.carry(pending: "Version 3.14", chunk: "is out")
        XCTAssertEqual(r.complete, "")
        XCTAssertEqual(r.pending, "Version 3.14 is out")
    }

    func testCarrySplitsGermanAfterClosingQuote() {
        let r = Core.carry(pending: "", chunk: "Er sagte: \u{201E}Komm morgen.\u{201C} Dann ging er? Und dann")
        XCTAssertEqual(r.complete, "Er sagte: \u{201E}Komm morgen.\u{201C} Dann ging er?")
        XCTAssertEqual(r.pending, "Und dann")
    }

    func testCarrySplitsAfterCJKSentenceMarks() {
        let r = Core.carry(pending: "", chunk: "\u{4ECA}\u{65E5}\u{306F}\u{3002}\u{884C}\u{304F}\u{FF1F}\u{307E}\u{3060}")
        XCTAssertEqual(r.complete, "\u{4ECA}\u{65E5}\u{306F}\u{3002}\u{884C}\u{304F}\u{FF1F}")
        XCTAssertEqual(r.pending, "\u{307E}\u{3060}")
    }

    func testCarryFlushesTooMuchUnpunctuatedText() {
        let words = Array(repeating: "word", count: 400).joined(separator: " ")
        var r = Core.carry(pending: "Done. " + words, chunk: "tail")
        XCTAssertEqual(r.complete, "Done. " + words)
        XCTAssertEqual(r.pending, "tail")
        let blob = String(repeating: "x", count: 1600)
        r = Core.carry(pending: "", chunk: blob)
        XCTAssertEqual(r.complete, blob)
        XCTAssertEqual(r.pending, "")
    }
}
