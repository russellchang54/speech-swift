import Foundation
import ArgumentParser
import Qwen3ASR
import ParakeetASR
import NemotronStreamingASR
import OmnilingualASR
import SpeechVAD
import AudioCommon

public struct TranscribeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe speech to text (Qwen3-ASR or Parakeet-TDT)"
    )

    @Argument(help: "Audio file to transcribe (WAV, any sample rate)")
    public var audioFile: String

    @Option(name: .long, help: "ASR engine: qwen3 (default), parakeet, nemotron, omnilingual, qwen3-coreml, or qwen3-coreml-full")
    public var engine: String = "qwen3"

    @Option(name: .long, help: "[omnilingual] Window size in seconds: 5 or 10 (default 10) — CoreML backend only")
    public var window: Int = 10

    @Option(name: .long, help: "[omnilingual] Backend: coreml (default) or mlx")
    public var backend: String = "coreml"

    @Option(name: .long, help: "[omnilingual mlx] Variant: 300M (default), 1B, 3B, or 7B")
    public var variant: String = "300M"

    @Option(name: .long, help: "[omnilingual mlx] Quantization bits: 4 (default) or 8")
    public var bits: Int = 4

    @Option(name: .shortAndLong, help: "[qwen3] Model: 0.6B (default), 0.6B-8bit, 1.7B, 1.7B-4bit, or full HuggingFace model ID")
    public var model: String = "0.6B"

    @Option(name: .long, help: "Language hint (optional)")
    public var language: String?

    @Option(name: .long, help: "Context string to bias recognition (e.g., 'Project: Foo, participants: Alice, Bob'). Improves proper-noun accuracy.")
    public var context: String?

    @Option(name: .long, help: "Proper noun list for recognition accuracy (comma-separated, e.g. '浙里办,汇信,企微')")
    public var properNouns: String?

    @Flag(name: .long, help: "Enable streaming transcription with VAD")
    public var stream: Bool = false

    @Option(name: .long, help: "Maximum segment duration in seconds (default 10)")
    public var maxSegment: Float = 10.0

    @Flag(name: .long, help: "Emit partial results during speech")
    public var partial: Bool = false

    @Flag(name: .long, help: "Output as JSON")
    public var json: Bool = false

    @Flag(name: .long, help: "Phone call mode: diarize 2 speakers then transcribe each with speaker labels")
    public var phoneCall: Bool = false

    public init() {}

    public func validate() throws {
        let eng = engine.lowercased()
        guard eng == "qwen3" || eng == "parakeet" || eng == "nemotron" || eng == "omnilingual" || eng == "qwen3-coreml" || eng == "qwen3-coreml-full" else {
            throw ValidationError("--engine must be 'qwen3', 'parakeet', 'nemotron', 'omnilingual', 'qwen3-coreml', or 'qwen3-coreml-full'")
        }
        if eng == "omnilingual" {
            if window != 5 && window != 10 {
                throw ValidationError("--window must be 5 or 10 for omnilingual")
            }
            let backendNorm = backend.lowercased()
            guard backendNorm == "coreml" || backendNorm == "mlx" else {
                throw ValidationError("--backend must be 'coreml' or 'mlx' for omnilingual")
            }
            if backendNorm == "mlx" {
                guard ["300M", "1B", "3B", "7B"].contains(variant.uppercased()) else {
                    throw ValidationError("--variant must be 300M, 1B, 3B, or 7B")
                }
                guard bits == 4 || bits == 8 else {
                    throw ValidationError("--bits must be 4 or 8")
                }
            }
        }
    }

    public func run() throws {
        if phoneCall {
            try runPhoneCallTranscription()
            return
        }
        switch engine.lowercased() {
        case "parakeet":
            try runParakeetTranscription()
        case "nemotron":
            try runNemotronTranscription()
        case "omnilingual":
            try runOmnilingualTranscription()
        case "qwen3-coreml":
            try runCoreMLTranscription()
        case "qwen3-coreml-full":
            try runFullCoreMLTranscription()
        default:
            if stream {
                try runStreamingTranscription()
            } else {
                try runBatchTranscription()
            }
        }
    }

    /// Built-in proper nouns for government/business domain — always injected into ASR context.
    private static let builtinProperNouns = [
        "e照通", "浙里办", "汇信", "汇信CA", "e签宝", "天谷", "企微", "浙政钉",
        "市监", "浙江政务服务网", "市场监督局", "CA证书", "联连APP", "联连用户",
        "联连客户端", "公示系统", "工商年报", "天眼查", "企查查", "企业登记",
        "电子营业执照", "即时申报", "经营异常修复", "经营异常移出", "信用修复",
        "浙江企业在线", "政采云", "乐采云", "政务网", "简易注销", "备案",
        "无违规证明", "汇信移动CA", "天谷CA",
    ]

    /// Parse `--proper-nouns` into a list of terms, merged with the built-in list.
    private func resolveProperNouns() -> [String] {
        var all = Self.builtinProperNouns
        guard let raw = properNouns, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return all
        }
        // Support file path input
        let extras: [String]
        if FileManager.default.fileExists(atPath: raw) {
            if let content = try? String(contentsOfFile: raw, encoding: .utf8) {
                extras = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                extras = []
            }
        } else {
            extras = raw.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        for term in extras where !all.contains(term) {
            all.append(term)
        }
        return all
    }

    /// Build the effective context string, combining `--context` and `--proper-nouns`.
    private func resolveContext() -> String? {
        let nouns = resolveProperNouns()
        var parts = [String]()
        if let ctx = context, !ctx.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(ctx)
        }
        if !nouns.isEmpty {
            let nounList = nouns.joined(separator: "、")
            parts.append("重要专有名词：\(nounList)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    // MARK: - Phone Call

    /// Combined diarization + transcription for 1:1 phone calls.
    private func runPhoneCallTranscription() throws {
        let modelId = resolveASRModelId(model)
        let wantJSON = json
        try runAsync {
            let audioURL = URL(fileURLWithPath: audioFile)
            let audio = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16000)

            // Step 1: Diarize with 2-speaker enforcement
            print("Diarizing speakers...")
            let pipeline = try await DiarizationPipeline.fromPretrained(
                embeddingEngine: .mlx,
                progressHandler: reportProgress
            )
            let diarizeStart = Date()
            let diarizeResult: DiarizationResult = pipeline.diarize(audio: audio, sampleRate: 16000)
            let twoSpeaker = DiarizationHelpers.enforceTwoSpeakers(diarizeResult)
            let labels = DiarizationHelpers.computePhoneCallLabels(twoSpeaker.segments)
            let diarizeElapsed = Date().timeIntervalSince(diarizeStart)

            guard !twoSpeaker.segments.isEmpty else {
                print("No speech detected.")
                return
            }

            // Step 2: Load ASR model
            let detectedSize = ASRModelSize.detect(from: modelId)
            let sizeLabel = detectedSize == .large ? "1.7B" : "0.6B"
            print("Loading ASR model (\(sizeLabel)): \(modelId)")
            let asrModel = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId, progressHandler: reportProgress)
            let effectiveContext = resolveContext()

            // Step 3: Transcribe each segment
            print("Transcribing \(twoSpeaker.segments.count) segments...")
            let transcribeStart = Date()
            var segmentsOut = [[String: Any]]()
            for seg in twoSpeaker.segments {
                let startSample = Int(seg.startTime * 16000)
                let endSample = min(Int(seg.endTime * 16000), audio.count)
                guard endSample > startSample else { continue }

                let segmentAudio = Array(audio[startSample..<endSample])
                let text = asrModel.transcribe(
                    audio: segmentAudio, sampleRate: 16000,
                    language: language, context: effectiveContext)
                let cleaned = verifyAndCorrect(stripContextEcho(text))

                let label = labels[seg.speakerId] ?? "speaker_\(seg.speakerId)"
                segmentsOut.append([
                    "speaker": label,
                    "start": Double(String(format: "%.2f", seg.startTime))!,
                    "end": Double(String(format: "%.2f", seg.endTime))!,
                    "text": cleaned,
                ])
                if !cleaned.isEmpty {
                    print("\(label) [\(String(format: "%.1f", seg.startTime))s]: \(cleaned)")
                }
            }
            let transcribeElapsed = Date().timeIntervalSince(transcribeStart)

            if wantJSON {
                let output: [String: Any] = [
                    "segments": segmentsOut,
                    "diarization_time": Double(String(format: "%.2f", diarizeElapsed))!,
                    "transcription_time": Double(String(format: "%.2f", transcribeElapsed))!,
                    "phone_call": true,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    print("\nJSON:\n\(str)")
                }
            }

            let totalElapsed = diarizeElapsed + transcribeElapsed
            print(String(format: "  Diarization: %.2fs, Transcription: %.2fs, Total: %.2fs",
                         diarizeElapsed, transcribeElapsed, totalElapsed))
        }
    }

    /// Known ASR homophone errors for proper nouns — used to correct the final transcript.
    /// Key = common ASR error form, Value = correct proper noun.
    private static let homophoneCorrections: [String: String] = [
        "这里办": "浙里办",
        "这会办": "浙里办",
        "惠信": "汇信",
        "会信": "汇信",
        "回信": "汇信",
        "企微云": "企微",
        "其为": "企微",
        "齐威": "企微",
        "浙政丁": "浙政钉",
        "浙政顶": "浙政钉",
        "易签宝": "e签宝",
        "壹签宝": "e签宝",
        "天谷C": "天谷CA",
        "天谷新": "天谷CA",
        "天谷行": "天谷CA",
        "天眼茶": "天眼查",
        "天眼差": "天眼查",
        "企茶茶": "企查查",
        "起查查": "企查查",
        "简易筑销": "简易注销",
        "林时申报": "即时申报",
        "信用秀复": "信用修复",
        "信用羞复": "信用修复",
        "正采云": "政采云",
        "政彩云": "政采云",
        "乐彩云": "乐采云",
        "郑务网": "政务网",
        "浙江政府网": "浙江政务服务网",
        "电子营业执照": "电子营业执照",
    ]

    /// Verify the transcript against the proper noun list and correct known
    /// ASR homophone errors via a mapping of common mistakes → correct form.
    private func verifyAndCorrect(_ text: String) -> String {
        var result = text
        for (wrong, correct) in Self.homophoneCorrections {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }
        return result
    }

    /// Strip echoed context prefix from the transcription result.
    private func stripContextEcho(_ text: String) -> String {
        var remaining = text
        let nouns = resolveProperNouns()
        while let period = remaining.firstIndex(of: "。") {
            let prefix = String(remaining[..<period])
            let matchCount = nouns.filter { prefix.contains($0) }.count
            if matchCount >= 3 {
                let after = remaining.index(after: period)
                remaining = String(remaining[after...]).trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }
        return remaining
    }

    private func runBatchTranscription() throws {
        try runAsync {
            let modelId = resolveASRModelId(model)
            let detectedSize = ASRModelSize.detect(from: modelId)
            let sizeLabel = detectedSize == .large ? "1.7B" : "0.6B"

            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 24000)
            print("  Loaded \(audio.count) samples (\(formatDuration(audio.count))s)")

            print("Loading model (\(sizeLabel)): \(modelId)")
            let asrModel = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId, progressHandler: reportProgress)

            print("Transcribing...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let effectiveContext = resolveContext()
            let raw = asrModel.transcribe(audio: audio, sampleRate: 24000, language: language, context: effectiveContext)
            let result = verifyAndCorrect(stripContextEcho(raw))
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let duration = Float(audio.count) / 24000.0
            let rtf = elapsed / Double(duration)

            print("Result: \(result)")
            print(String(format: "  Time: %.2fs, RTF: %.3f", elapsed, rtf))
        }
    }

    private func runStreamingTranscription() throws {
        try runAsync {
            let modelId = resolveASRModelId(model)

            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            print("Loading models...")
            let streaming = try await StreamingASR.fromPretrained(
                asrModelId: modelId, progressHandler: reportProgress)

            let config = StreamingASRConfig(
                maxSegmentDuration: maxSegment,
                language: language,
                emitPartialResults: partial,
                context: resolveContext()
            )

            print("Streaming transcription (VAD + ASR)...")
            let stream = streaming.transcribeStream(
                audio: audio, sampleRate: 16000, config: config)

            for try await segment in stream {
                let tag = segment.isFinal ? "FINAL" : "partial"
                let start = String(format: "%.2f", segment.startTime)
                let end = String(format: "%.2f", segment.endTime)
                print("[\(start)s-\(end)s] [\(tag)] \(segment.text)")
            }
        }
    }

    private func runCoreMLTranscription() throws {
        #if canImport(CoreML)
        try runAsync {
            let modelId = resolveASRModelId(model)

            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            // Load CoreML encoder
            print("Loading CoreML encoder...")
            let coremlEncoder = try await CoreMLASREncoder.fromPretrained(
                progressHandler: reportProgress)

            print("Warming up CoreML...")
            try coremlEncoder.warmUp()

            // Load MLX text decoder
            print("Loading text decoder: \(modelId)")
            let asrModel = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId, progressHandler: reportProgress)

            print("Transcribing (CoreML encoder + MLX decoder)...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try asrModel.transcribe(
                audio: audio, sampleRate: 16000, language: language,
                coremlEncoder: coremlEncoder)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let rtf = elapsed / Double(duration)

            print("Result: \(stripContextEcho(result))")
            print(String(format: "  Time: %.2fs, RTF: %.3f", elapsed, rtf))
        }
        #else
        print("CoreML is not available on this platform.")
        #endif
    }

    private func runFullCoreMLTranscription() throws {
        #if canImport(CoreML)
        try runAsync {
            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            if #available(macOS 15, iOS 18, *) {
                print("Loading full CoreML ASR pipeline...")
                let asrModel = try await CoreMLASRModel.fromPretrained(
                    progressHandler: reportProgress)

                print("Warming up CoreML...")
                let warmupStart = CFAbsoluteTimeGetCurrent()
                try asrModel.warmUp()
                let warmupTime = CFAbsoluteTimeGetCurrent() - warmupStart

                print("Transcribing (full CoreML: encoder + decoder)...")
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try asrModel.transcribe(
                    audio: audio, sampleRate: 16000, language: language)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let rtf = elapsed / Double(duration)

                print("Result: \(stripContextEcho(result))")
                print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
            } else {
                print("Full CoreML ASR requires macOS 15+ / iOS 18+ for MLState KV cache.")
                print("Use --engine qwen3-coreml for hybrid CoreML encoder + MLX decoder.")
            }
        }
        #else
        print("CoreML is not available on this platform.")
        #endif
    }

    private func runParakeetTranscription() throws {
        try runAsync {
            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            print("Loading Parakeet-TDT model: \(ParakeetASRModel.defaultModelId)")
            let parakeetModel = try await ParakeetASRModel.fromPretrained(
                progressHandler: reportProgress)

            print("Warming up CoreML...")
            let warmupStart = CFAbsoluteTimeGetCurrent()
            try parakeetModel.warmUp()
            let warmupTime = CFAbsoluteTimeGetCurrent() - warmupStart

            print("Transcribing...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try parakeetModel.transcribeAudio(audio, sampleRate: 16000, language: language)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let rtf = elapsed / Double(duration)

            print("Result: \(stripContextEcho(result))")
            print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
        }
    }

    private func runNemotronTranscription() throws {
        try runAsync {
            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            print("Loading Nemotron Streaming model: \(NemotronStreamingASRModel.defaultModelId)")
            let model = try await NemotronStreamingASRModel.fromPretrained(
                progressHandler: reportProgress)

            print("Warming up CoreML...")
            let warmupStart = CFAbsoluteTimeGetCurrent()
            try model.warmUp()
            let warmupTime = CFAbsoluteTimeGetCurrent() - warmupStart

            if stream {
                print("Streaming transcription...")
                let startTime = CFAbsoluteTimeGetCurrent()
                for await partial in model.transcribeStream(audio: audio, sampleRate: 16000) {
                    let tag = partial.isFinal ? "FINAL" : "partial"
                    if partial.isFinal || self.partial {
                        print("[\(tag)] \(partial.text)")
                    }
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let rtf = elapsed / Double(duration)
                print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
            } else {
                print("Transcribing...")
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try model.transcribeAudio(audio, sampleRate: 16000)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let rtf = elapsed / Double(duration)
                print("Result: \(stripContextEcho(result))")
                print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
            }
        }
    }

    private func runOmnilingualTranscription() throws {
        if backend.lowercased() == "mlx" {
            try runOmnilingualMLXTranscription()
        } else {
            try runOmnilingualCoreMLTranscription()
        }
    }

    private func runOmnilingualCoreMLTranscription() throws {
        try runAsync {
            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            let modelId = window == 5
                ? OmnilingualASRModel.shortWindowModelId
                : OmnilingualASRModel.defaultModelId
            print("Loading Omnilingual ASR model (\(window)s window): \(modelId)")
            let model = try await OmnilingualASRModel.fromPretrained(
                modelId: modelId, progressHandler: reportProgress)

            print("Warming up CoreML...")
            let warmupStart = CFAbsoluteTimeGetCurrent()
            try model.warmUp()
            let warmupTime = CFAbsoluteTimeGetCurrent() - warmupStart

            print("Transcribing...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try model.transcribeAudio(audio, sampleRate: 16000)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let rtf = elapsed / Double(duration)

            print("Result: \(stripContextEcho(result))")
            print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
        }
    }

    private func runOmnilingualMLXTranscription() throws {
        try runAsync {
            print("Loading audio: \(audioFile)")
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: 16000)
            let duration = Float(audio.count) / 16000.0
            print("  Loaded \(audio.count) samples (\(String(format: "%.2f", duration))s)")

            let resolved = OmnilingualMLXConfig.Variant(rawValue: variant.uppercased()) ?? .m300
            let modelId = OmnilingualMLXConfig.defaultModelId(variant: resolved, bits: bits)
            print("Loading Omnilingual MLX model (\(resolved.rawValue), \(bits)-bit): \(modelId)")
            let model = try await OmnilingualASRMLXModel.fromPretrained(
                variant: resolved, bits: bits, progressHandler: reportProgress)

            print("Warming up MLX...")
            let warmupStart = CFAbsoluteTimeGetCurrent()
            try model.warmUp()
            let warmupTime = CFAbsoluteTimeGetCurrent() - warmupStart

            print("Transcribing...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try model.transcribeAudio(audio, sampleRate: 16000)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let rtf = elapsed / Double(duration)

            print("Result: \(stripContextEcho(result))")
            print(String(format: "  Time: %.2fs, RTF: %.3f (warmup: %.2fs)", elapsed, rtf, warmupTime))
        }
    }
}

/// Resolve shorthand model specifiers to HuggingFace model IDs.
public func resolveASRModelId(_ specifier: String) -> String {
    switch specifier.lowercased() {
    case "0.6b", "small":
        return ASRModelSize.small.defaultModelId
    case "0.6b-8bit", "small-8bit":
        return "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"
    case "1.7b", "large":
        return ASRModelSize.large.defaultModelId
    case "1.7b-4bit", "large-4bit":
        return "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
    default:
        return specifier
    }
}
