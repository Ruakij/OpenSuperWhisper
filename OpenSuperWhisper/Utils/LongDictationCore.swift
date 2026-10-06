import Foundation

/// Pure pieces of long dictation: reading the WAV the recorder is still writing, finding where to
/// cut it, and carrying an unfinished sentence over to the next chunk. Foundation only, so the
/// logic is testable without a recorder, an engine or a model.
enum LongDictationCore {

    // MARK: - WAV

    struct WAVLayout: Equatable {
        /// Byte offset of the first sample, right after the "data" chunk header.
        let dataOffset: Int
        let channels: Int
        let sampleRate: Int

        var bytesPerFrame: Int { channels * MemoryLayout<Float32>.size }
    }

    /// Finds the sample data of a 32-bit float WAV from its header. The size fields of a file
    /// still being recorded are not final, so the data chunk's own size is ignored: the samples
    /// run from `dataOffset` to wherever the file currently ends. Chunks other than "fmt " and
    /// "data" (AVAudioRecorder writes a "FLLR" padding chunk) are skipped.
    static func parseWAVLayout(_ header: Data) -> WAVLayout? {
        let bytes = [UInt8](header)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }

        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var pos = 12
        var channels: Int?
        var sampleRate = 0
        while pos + 8 <= bytes.count {
            let id = tag(pos)
            let size = u32(pos + 4)
            let body = pos + 8
            if id == "data" {
                guard let channels else { return nil }
                return WAVLayout(dataOffset: body, channels: channels, sampleRate: sampleRate)
            }
            if id == "fmt " {
                guard body + 16 <= bytes.count else { return nil }
                let format = u16(body)
                let bits = u16(body + 14)
                // 3 = IEEE float, 0xFFFE = extensible (float subformat when 32 bits here).
                guard format == 3 || format == 0xFFFE, bits == 32 else { return nil }
                channels = max(1, u16(body + 2))
                sampleRate = u32(body + 4)
            }
            pos = body + size + (size & 1)
        }
        return nil
    }

    /// Downmixes interleaved little-endian Float32 frames to mono. A trailing partial frame
    /// (the recorder may be mid-write) is ignored.
    static func monoSamples(interleaved data: Data, channels: Int) -> [Float] {
        let channels = max(1, channels)
        let frameCount = data.count / (channels * 4)
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount)
        data.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    let bits = raw.loadUnaligned(fromByteOffset: (frame * channels + ch) * 4, as: UInt32.self)
                    sum += Float(bitPattern: UInt32(littleEndian: bits))
                }
                out[frame] = sum / Float(channels)
            }
        }
        return out
    }

    /// The mono samples of the WAV at `url` from frame `fromFrame` to the current end of the
    /// file, with its sample rate. nil while the header is not written yet or not float.
    static func readMono(url: URL, fromFrame: Int) -> (samples: [Float], sampleRate: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // AVAudioRecorder pads its header to 4 KiB with a FLLR chunk; twice that is ample.
        guard let header = try? handle.read(upToCount: 8192), let layout = parseWAVLayout(header),
              (try? handle.seek(toOffset: UInt64(layout.dataOffset + fromFrame * layout.bytesPerFrame))) != nil
        else { return nil }
        let data = (try? handle.readToEnd()) ?? Data()
        return (monoSamples(interleaved: data, channels: layout.channels), layout.sampleRate)
    }

    /// A complete mono 32-bit float WAV holding `samples`.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 4
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(3); put16(1); put32(sampleRate); put32(sampleRate * 4); put16(4); put16(32)
        data.append(contentsOf: Array("data".utf8)); put32(payload)
        // Every Apple platform is little-endian, so the samples go over as they lie in memory.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Cut finding

    struct CutParameters {
        var targetSeconds: Double
        var maxSeconds: Double
        var minGapMs: Int
        var silenceDb: Double
        var sampleRate: Int = 16000
    }

    static let frameMs = 20

    /// Where to cut the uncut audio `samples`, as a sample index, or nil to keep waiting.
    ///
    /// Once at least `targetSeconds` are buffered, cuts at the middle of the first run of
    /// 20 ms frames below `silenceDb` that lasts `minGapMs` and reaches past the target. Without
    /// such a run, waits until `maxSeconds` and then cuts at the middle of the quietest
    /// `minGapMs` window in [target, max]; that cut is `hard`, as it can split a word.
    static func findCut(samples: [Float], _ p: CutParameters) -> (at: Int, hard: Bool)? {
        let frameLen = p.sampleRate * frameMs / 1000
        guard frameLen > 0 else { return nil }
        let frames = samples.count / frameLen
        let targetFrame = Int(p.targetSeconds * 1000) / frameMs
        let maxFrame = max(targetFrame, Int(p.maxSeconds * 1000) / frameMs)
        guard frames >= targetFrame else { return nil }

        let gapFrames = max(1, (p.minGapMs + frameMs - 1) / frameMs)
        let searchEnd = min(frames, maxFrame)
        let energies = frameEnergies(samples, frameLen: frameLen, count: searchEnd)
        let threshold = silenceThreshold(p.silenceDb)

        var runStart: Int?
        for f in 0..<searchEnd {
            if energies[f] < threshold {
                if runStart == nil { runStart = f }
            } else {
                runStart = nil
            }
            if let start = runStart, f + 1 - start >= gapFrames, f + 1 > targetFrame {
                // Let the run grow to its end (or to what is buffered) before picking its middle.
                var end = f + 1
                while end < searchEnd, energies[end] < threshold { end += 1 }
                return ((start + end) / 2 * frameLen, false)
            }
        }

        guard frames >= maxFrame else { return nil }
        let window = min(gapFrames, maxFrame - targetFrame)
        guard window > 0 else { return (maxFrame * frameLen, true) }
        var best = targetFrame
        var bestSum = Float.greatestFiniteMagnitude
        var sum = energies[targetFrame..<targetFrame + window].reduce(0, +)
        for start in targetFrame...(maxFrame - window) {
            if start > targetFrame { sum += energies[start + window - 1] - energies[start - 1] }
            if sum < bestSum { bestSum = sum; best = start }
        }
        return ((best + window / 2) * frameLen, true)
    }

    /// Whether every whole 20 ms frame of `samples` is below `silenceDb`. Whisper invents text
    /// ("Thank you.") for silent audio, so such a chunk is not transcribed at all.
    static func isSilent(samples: [Float], sampleRate: Int, silenceDb: Double) -> Bool {
        let frameLen = sampleRate * frameMs / 1000
        guard frameLen > 0 else { return true }
        let threshold = silenceThreshold(silenceDb)
        return frameEnergies(samples, frameLen: frameLen, count: samples.count / frameLen)
            .allSatisfy { $0 < threshold }
    }

    /// Mean square of each of the first `count` frames.
    private static func frameEnergies(_ samples: [Float], frameLen: Int, count: Int) -> [Float] {
        (0..<count).map { f in
            var sum: Float = 0
            for s in samples[f * frameLen..<(f + 1) * frameLen] { sum += s * s }
            return sum / Float(frameLen)
        }
    }

    /// RMS in dBFS compared as mean square: 20*log10(rms) < db  <=>  ms < 10^(db/10).
    private static func silenceThreshold(_ db: Double) -> Float { Float(pow(10, db / 10)) }

    /// Audio a chunk after a hard cut repeats from the end of the previous one, so a word split
    /// by the cut is whole in at least one of them; `spliceOverlap` drops the doubled words.
    static let overlapSeconds = 1.0

    /// Splits off every chunk `findCut` finds in `samples`, in order, each with whether its cut
    /// was hard. After a hard cut the next chunk starts `overlapSeconds` before it. `consumed`
    /// is where the uncut rest begins, which is not returned.
    static func chunks(samples: [Float], _ p: CutParameters)
        -> (chunks: [(samples: [Float], hardCut: Bool)], consumed: Int) {
        var start = 0
        var out: [(samples: [Float], hardCut: Bool)] = []
        while let cut = findCut(samples: Array(samples[start...]), p), cut.at > 0 {
            out.append((Array(samples[start..<start + cut.at]), cut.hard))
            let overlap = cut.hard ? min(Int(overlapSeconds * Double(p.sampleRate)), cut.at / 2) : 0
            start += cut.at - overlap
        }
        return (out, start)
    }

    // MARK: - Overlap splice

    /// How many words at the end of `previous` and the start of `next` the overlap can span.
    static let overlapWords = 12

    /// Removes the words two chunks share after a hard cut. Finds the longest run of at least two
    /// words (compared without case and punctuation) common to the last `overlapWords` words of
    /// `previous` and the first `overlapWords` of `next`, keeps `previous` up to the end of that
    /// run and `next` after it, which also drops a word fragment the cut left on either side.
    /// Without such a run both come back unchanged.
    static func spliceOverlap(previous: String, next: String) -> (previous: String, next: String) {
        func words(_ text: String) -> [(range: Range<String.Index>, key: String)] {
            text.split(whereSeparator: \.isWhitespace).map { word in
                (word.startIndex..<word.endIndex,
                 String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
            }
        }
        let prev = Array(words(previous).suffix(overlapWords))
        let allNext = words(next)
        let nxt = Array(allNext.prefix(overlapWords))
        var best = (length: 1, prevEnd: 0, nextEnd: 0)
        for i in prev.indices {
            for j in nxt.indices {
                var length = 0
                while i + length < prev.count, j + length < nxt.count,
                      !prev[i + length].key.isEmpty, prev[i + length].key == nxt[j + length].key {
                    length += 1
                }
                if length > best.length { best = (length, i + length - 1, j + length - 1) }
            }
        }
        guard best.length >= 2 else { return (previous, next) }
        let kept = String(previous[..<prev[best.prevEnd].range.upperBound])
        let after = best.nextEnd + 1 < allNext.count
            ? String(next[allNext[best.nextEnd + 1].range.lowerBound...]) : ""
        return (kept, after)
    }

    // MARK: - Sentence carry

    // CJK sentence marks need no following space: the next sentence starts right after them.
    private static let sentenceEnd = try! NSRegularExpression(
        pattern: "[.!?]+[\"'\u{201C}\u{201D}\u{2018}\u{2019}\u{00BB}\u{00AB})]*(?=\\s|$)|[\u{3002}\u{FF01}\u{FF1F}]+[\u{300D}\u{300F}\u{FF09}]*")

    /// Unfinished text longer than about one chunk's worth is flushed anyway, so output without
    /// punctuation cannot pile up into one huge cleanup call at the end.
    static let maxPendingCharacters = 1500

    /// Appends `chunk` to the unfinished `pending` text and splits the result after its last
    /// sentence end. `complete` is ready for cleanup; `pending` waits for the next chunk. A
    /// `pending` over `maxPendingCharacters` is cut at its last whitespace, or flushed whole.
    static func carry(pending: String, chunk: String) -> (complete: String, pending: String) {
        let text = joined([pending, chunk])
        let ns = text as NSString
        var complete = ""
        var pending = text
        if let last = sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)).last {
            let cut = last.range.location + last.range.length
            complete = ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ns.substring(from: cut).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard pending.count > maxPendingCharacters else { return (complete, pending) }
        guard let space = pending.lastIndex(where: \.isWhitespace) else { return (joined([complete, pending]), "") }
        return (joined([complete, String(pending[..<space])]),
                pending[space...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Non-empty pieces joined by a single space.
    static func joined(_ pieces: [String]) -> String {
        pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
