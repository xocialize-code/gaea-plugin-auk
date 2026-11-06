import AuKCore
import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXAuK
import MLXToolKit

// gaea-plugin-auk: Tencent Hunyuan's AuK on MES Audio 0.1 (Gaea G5 order 5, AB-T-0455). Two models, each on four
// operations, so each checkpoint loads once:
//
// - `auk-flash` (AuK-Flash, a 4-step distilled DiT, RTF about 0.13) and `auk` (the Base model, RTF about 0.89, the only
//   one that separates every voice).
// - audio.speak: a clone of `voice_ref` (AuK has no voices of its own). Its length comes from `target_duration_s`;
//   else from the clip's transcript (`voice_ref_text`); else from the text, as AuK's instruct path estimates it.
// - audio.design_voice: a voice from a description (AuK's instruct TTS), read back as `count` samples at seed + i.
// - audio.edit_speech: 14 kinds through GaeaPluginKit's SpeechEdits (MES 0.10, RFC 0006). Cues go at the take's edges
//   only (`cue_placement: [edge]`), one kind is removed at a time (`remove_all_cues: false`), and speed, pitch and
//   volume snap to AuK's trained steps. No transcript is needed; one given is returned edited.
// - audio.separate: one speaker (the n-th to start talking, or the one who says given words), the singing, or (Base)
//   every voice. Each stem is regenerated, not masked (`stem_method: regenerated`).
//
// Three lanes, the encoder's quant: int8 (the default), bf16 and int4. The 4-bit encoder drops words in Mandarin edits
// (AB-D-0202), so a Mandarin edit on int4 is refused, never run there (G-30, AB-D-0212). Mandarin is told from the
// transcript or the edit's own text.
//
// Research use only (G-27, AB-D-0209): the required Qwen2.5-Omni-3B encoder is under the Qwen Research licence. Every
// offer is named-only, off until the operator enables it and accepts the terms, and asks each client's user to accept
// them too (`user_accept_required`). 24 kHz, at most 30 s.

public enum Variant: String, Sendable { case flash, base }

public func modelID(_ v: Variant) -> String { v == .flash ? "auk-flash" : "auk" }
public func title(_ v: Variant) -> String { v == .flash ? "AuK-Flash" : "AuK" }
public let maxTextChars = 600, maxDescriptionChars = 400, maxSamples = 4

public func configuration(_ v: Variant, _ quant: Quant) -> AuKConfiguration {
    AuKConfiguration(variant: v == .flash ? .flash : .base, quant: quant)
}

public func lanes(_ v: Variant) -> [LaneDefinition] {
    [("int8", Quant.int8), ("bf16", .bf16), ("int4", .int4)].map { id, quant in
        LaneDefinition(id: id, default: id == "int8", configuration: configuration(v, quant))
    }
}

// MARK: - speak

/// What a speak job asks of the package, validated.
public struct SpeakPlan: Sendable {
    public var pieces: [Piece]
    public var reference: Data
    public var transcript: String?
    /// Each word piece's length, when the plugin sets it (a target, or no transcript to estimate from).
    public var lengths: [Double]?
    public var seed: UInt64
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

public func speakPlan(text: String?, reference wav: Data?, transcript: String?, language tag: String?, targetDuration: Double?,
                      seed: UInt64) throws -> SpeakPlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "AuK speaks at most \(maxTextChars) characters at a time.",
                       detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    guard let wav else {
        throw GPPError(.invalidRequest, "AuK speaks only in a cloned voice: send voice_ref, or design one.", detail: ["param": "voice_ref"])
    }
    let (clip, seconds, warnings) = try reference(wav)
    let pieces = try plan(text)
    let lang = try language(tag) ?? (isChinese(text) ? "zh" : "en")
    let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
    let script = said?.isEmpty == false ? said : nil
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "language": .string(lang),
                                          "x-auk.voice_ref_s": .double((seconds * 100).rounded() / 100)]
    var lengths: [Double]?
    if let targetDuration {
        guard targetDuration > 0, targetDuration <= maxSeconds else {
            throw GPPError(.invalidRequest, "target_duration_s is above 0 and at most \(Int(maxSeconds)) s for AuK.",
                           detail: ["param": "target_duration_s", "mes_code": "out_of_limits"])
        }
        guard let shares = pieceTargets(pieces, target: targetDuration) else {
            throw GPPError(.invalidRequest, String(format: "%g s leaves too little time for the words once the pauses are kept.", targetDuration),
                           detail: ["param": "target_duration_s", "mes_code": "out_of_limits"])
        }
        lengths = shares
        effective["target_duration_s"] = .double(targetDuration)
    } else if script == nil {
        // Without a transcript the package can't estimate the length from the clip: the plugin does, from the text.
        lengths = pieces.compactMap { if case .words(let w) = $0 { estimatedSeconds(w) } else { nil } }
        effective["x-auk.length"] = "estimated"
    }
    if let lengths, lengths.contains(where: { $0 > maxSeconds }) || lengths.reduce(0, +) > maxSeconds {
        throw GPPError(.invalidRequest, "That would be more than \(Int(maxSeconds)) s of speech: AuK makes at most \(Int(maxSeconds)) s at a time.",
                       detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    return SpeakPlan(pieces: pieces, reference: clip, transcript: script, lengths: lengths, seed: seed, warnings: warnings,
                     effective: effective)
}

/// The engine request for word piece `i` of a speak plan.
public func request(_ plan: SpeakPlan, piece i: Int, words: String) -> TTSRequest {
    TTSRequest(text: words, voice: VoiceSelector(.referenceAudio(Audio(format: .wav, data: plan.reference, sampleRate: nil, channels: 1))),
               referenceTranscript: plan.transcript, targetDuration: plan.lengths?[i], metaData: ["seed": .int(Int(plan.seed))])
}

func speakOperation(_ v: Variant) -> EngineOperation {
    EngineOperation("audio.speak") { job, session in
        let plan = try speakPlan(text: try job.text("text"), reference: try job.input("voice_ref").map { try Data(contentsOf: $0) },
                                 transcript: try job.text("voice_ref_text"), language: job.param("language")?.stringValue,
                                 targetDuration: job.param("target_duration_s")?.doubleValue, seed: seed(job))
        let pcm = try await speak(plan.pieces) { i, words in
            guard let response = try await session.run(request(plan, piece: i, words: words)) as? TTSResponse else {
                throw GPPError(.modelError, "AuK returned no audio.")
            }
            return response.audio.data
        }
        let url = session.outputDir.appending(path: "audio-0.wav")
        try wav16(pcm).write(to: url)
        return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: plan.effective, warnings: plan.warnings)
    }
}

// MARK: - design_voice

public struct DesignPlan: Sendable {
    public var description: String
    public var text: String
    public var language: String
    public var count: Int
    public var seed: UInt64
}

public func designPlan(description: String?, text: String?, language tag: String?, count: Int?, seed: UInt64) throws -> DesignPlan {
    guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
        throw GPPError(.invalidRequest, "audio.design_voice needs a description.", detail: ["param": "description"])
    }
    guard description.count <= maxDescriptionChars else {
        throw GPPError(.invalidRequest, "A description is at most \(maxDescriptionChars) characters.",
                       detail: ["param": "description", "mes_code": "out_of_limits"])
    }
    let lang = try language(tag) ?? "en"
    let count = count ?? 1
    guard (1...maxSamples).contains(count) else {
        throw GPPError(.invalidRequest, "AuK designs 1–\(maxSamples) samples at a time.", detail: ["param": "count", "mes_code": "out_of_limits"])
    }
    let sentence = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sample = sentence?.isEmpty == false ? sentence! : designSamples[lang]!
    guard estimatedSeconds(sample) <= maxSeconds, sample.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "The sample text is longer than AuK's \(Int(maxSeconds)) s.", detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    return DesignPlan(description: description, text: sample, language: lang, count: count, seed: seed)
}

/// The engine request for sample `i` of a design: AuK's instruct TTS, at seed + i.
public func request(_ plan: DesignPlan, sample i: Int) -> TTSRequest {
    TTSRequest(text: plan.text, voice: VoiceSelector(.auto), emotion: .textDescription(plan.description),
               metaData: ["seed": .int(Int(plan.seed) + i)])
}

func designOperation(_ v: Variant) -> EngineOperation {
    EngineOperation("audio.design_voice") { job, session in
        let plan = try designPlan(description: try job.text("description"), text: try job.text("text"),
                                  language: job.param("language")?.stringValue, count: job.param("count")?.intValue, seed: seed(job))
        var warnings: [Warning] = []
        if job.param("prompt_enhance")?.stringValue == "on" {
            warnings.append(Warning(code: "prompt_enhance_ignored", message: "AuK reads the description as written.", param: "prompt_enhance"))
        }
        var outputs: [Output] = []
        for i in 0..<plan.count {
            guard let response = try await session.run(request(plan, sample: i)) as? TTSResponse else {
                throw GPPError(.modelError, "AuK returned no audio.")
            }
            let url = session.outputDir.appending(path: "samples-\(i).wav")
            try wav16(try pcm16(response.audio.data)).write(to: url)
            outputs.append(.file("samples", url, mediaType: "audio/wav"))
        }
        return RunResult(outputs: outputs, effective: ["seed": .int(Int64(plan.seed)), "text": .string(plan.text),
                                                       "language": .string(plan.language), "count": .int(Int64(plan.count))],
                         warnings: warnings)
    }
}

// MARK: - edit_speech

/// The MES labels as AuK names them, and its trained grids.
public let vocabulary = SpeechEditVocabulary(
    emotions: ["happy": "happy", "angry": "angry", "sad": "sad", "afraid": "fearful", "surprised": "surprised",
               "disgusted": "disgusted", "calm": "calm", "excited": "excited"],
    styles: ["whisper": "whisper", "normal": "normal"],
    sounds: ["breath": "breath", "laugh": "laugh", "cough": "cough", "hum": "humming"],
    speedFactors: AukInstruction.speedFactors, pitchSemitones: AukInstruction.pitchSteps, volumeDecibels: AukInstruction.volumeSteps)
public let editKinds = ["emotion", "style", "add_cue", "remove_cue", "replace_text", "insert_text", "remove_text", "speed",
                        "pitch", "volume", "timbre", "de_accent", "denoise", "dereverb"]

/// What an edit job asks of the package, validated.
public struct EditPlan: Sendable {
    public var operation: SpeechEditOperation
    public var transcript: String?
    public var newTranscript: String?
    public var chinese: Bool
    public var targetDuration: Double?
    public var seed: UInt64
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

public func editPlan(edit: JSONValue?, transcript: String?, targetDuration: Double?, lane: String, seed: UInt64) throws -> EditPlan {
    let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
    let script = said?.isEmpty == false ? said : nil
    let mapped = try SpeechEdits.operation(edit, vocabulary: vocabulary, transcript: script)
    let kind = edit?["kind"]?.stringValue ?? ""
    guard editKinds.contains(kind) else { throw SpeechEdits.refusal("AuK doesn't make \(kind) edits.", mesCode: "unsupported_parameter") }
    // Mandarin is told from what the job says: its transcript, or the edit's own words.
    let words = [script] + ["text", "with", "anchor", "description"].map { edit?[$0]?.stringValue }
    let chinese = words.compactMap(\.self).contains(where: isChinese)
    if chinese, lane == "int4" {
        throw GPPError(.invalidRequest, "AuK's 4-bit encoder drops words in Mandarin edits: run this edit on the int8 or bf16 lane (x-gaea.lane).",
                       detail: ["param": "x-gaea.lane", "mes_code": "unsupported_parameter"])
    }
    if let targetDuration {
        guard targetDuration > 0, targetDuration <= maxSeconds else {
            throw GPPError(.invalidRequest, "target_duration_s is above 0 and at most \(Int(maxSeconds)) s for AuK.",
                           detail: ["param": "target_duration_s", "mes_code": "out_of_limits"])
        }
    }
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "edit": edit ?? .null]
    if let targetDuration { effective["target_duration_s"] = .double(targetDuration) }
    return EditPlan(operation: mapped.operation, transcript: script, newTranscript: mapped.newTranscript, chinese: chinese,
                    targetDuration: targetDuration, seed: seed, warnings: mapped.warnings, effective: effective)
}

/// The engine request for an edit plan.
public func request(_ plan: EditPlan, take: Data) -> SpeechEditRequest {
    SpeechEditRequest(audio: Audio(format: .wav, data: take, sampleRate: nil, channels: nil), transcript: plan.transcript ?? "",
                      edit: plan.operation, targetDuration: plan.targetDuration, seed: plan.seed)
}

/// The take's new transcript, when the edit changes its words or cues and the job gave one (Audio §3.3): AuK's own for
/// content edits, the kit's for an added cue, and the transcript without the removed cue.
public func newTranscript(_ plan: EditPlan, response: SpeechEditResponse) -> String? {
    guard let said = plan.transcript else { return nil }
    switch plan.operation {
    case .replaceWords, .insertWords, .removeWords:
        return response.transcript.isEmpty ? nil : response.transcript
    case .addNonverbal:
        return plan.newTranscript
    case .removeNonverbal(let sound):
        let cue = vocabulary.sounds.first { $0.value == sound }?.key ?? sound ?? ""
        let removed = said.replacingOccurrences(of: "[\(cue)]", with: "").split(separator: " ").joined(separator: " ")
        return removed == said ? nil : removed
    default:
        return nil
    }
}

func editOperation(_ v: Variant) -> EngineOperation {
    EngineOperation("audio.edit_speech") { job, session in
        guard let takeURL = job.input("audio") else { throw SpeechEdits.refusal("audio.edit_speech needs the take.", param: "audio") }
        let take = try Data(contentsOf: takeURL)
        let plan = try editPlan(edit: job.param("edit"), transcript: try job.text("transcript"),
                                targetDuration: job.param("target_duration_s")?.doubleValue, lane: job.lane, seed: seed(job))
        guard let response = try await session.run(request(plan, take: take)) as? SpeechEditResponse else {
            throw GPPError(.modelError, "AuK returned no take.")
        }
        let url = session.outputDir.appending(path: "audio-0.wav")
        try wav16(try pcm16(response.audio.data)).write(to: url)
        var outputs: [Output] = [.file("audio", url, mediaType: "audio/wav")]
        if let text = newTranscript(plan, response: response) { outputs.append(.value("transcript", ["text": .string(text)])) }
        return RunResult(outputs: outputs, effective: plan.effective, warnings: plan.warnings)
    }
}

// MARK: - separate

public func stems(_ v: Variant) -> [String] { v == .flash ? ["speaker", "singing"] : ["speaker", "singing", "voices"] }

func separateOperation(_ v: Variant) -> EngineOperation {
    EngineOperation("audio.separate") { job, session in
        guard let mixtureURL = job.input("audio") else { throw SpeechEdits.refusal("audio.separate needs the mixture.", param: "audio") }
        let seed = seed(job)
        let asked = job.param("stems")?.arrayValue?.compactMap(\.stringValue) ?? []
        for stem in asked where !stems(v).contains(stem) {
            throw SpeechEdits.refusal("\(title(v)) doesn't make the \(stem) stem.", param: "stems", mesCode: "unsupported_parameter")
        }
        let separation = try AudioSeparations.request(mixture: try Data(contentsOf: mixtureURL), params: job.params,
                                                      metaData: ["seed": .int(Int(seed))])
        guard let response = try await session.run(separation) as? AudioSeparationResponse else {
            throw GPPError(.modelError, "AuK returned no stems.")
        }
        let made = separation.stems.map(\.rawValue)
        let outputs = try AudioSeparations.outputs(response, stems: made, outputDir: session.outputDir)
        var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "stems": .array(made.map { .string($0) })]
        if let speaker = job.param("speaker") { effective["speaker"] = speaker }
        return RunResult(outputs: outputs, effective: effective)
    }
}

// MARK: - The plugin

public let licenseNotice = "AuK needs the Qwen2.5-Omni-3B encoder, which is under the Qwen Research License Agreement: "
    + "for research and evaluation only, not for any commercial use. AuK's own DiT and VAE are MIT. By using it you accept "
    + "the Qwen Research licence's terms."

let license: JSONValue = ["spdx": "LicenseRef-Qwen-Research", "commercial_use": false, "accepted_required": true,
                          "user_accept_required": true, "terms_url": "https://huggingface.co/Qwen/Qwen2.5-Omni-3B/blob/main/LICENSE",
                          "notice": .string(licenseNotice)]

func model(_ v: Variant) -> ModelDefinition {
    v == .flash
        ? .engine(AuKFlashPackage.self, id: modelID(v), title: title(v), lanes: lanes(v),
                  operations: [speakOperation(v), designOperation(v), editOperation(v), separateOperation(v)])
        : .engine(AuKPackage.self, id: modelID(v), title: title(v), lanes: lanes(v),
                  operations: [speakOperation(v), designOperation(v), editOperation(v), separateOperation(v)])
}

func offerModel(_ v: Variant, notes: String, supports: [String: JSONValue], limits: [String: JSONValue]) -> JSONValue {
    ["id": .string(modelID(v)), "title": .string(title(v)), "license": license, "named_only": true,
     "memory_class": "medium", "speed_class": .string(v == .flash ? "fast" : "standard"), "quality_tiers": ["standard"],
     "notes": .string(notes + " Research use only (Qwen Research licence)."),
     "supports": .object(supports.merging(["sample_rate": .int(Int64(sampleRate)), "channels": 1]) { a, _ in a }),
     "limits": .object(limits)]
}

func offers(_ v: Variant) -> [PluginManifest.Offer] {
    let langs: JSONValue = .array(languageTags.map { .string($0) })
    let pace = v == .flash ? "AuK-Flash, quick" : "AuK Base, slower and steadier"
    return [
        PluginManifest.Offer(operation: "audio.speak", profile: "audio", model: offerModel(
            v, notes: "\(pace): speech in the voice of a reference clip (up to 30 s), in English or Chinese, at most 30 s. Give the clip's transcript (voice_ref_text) or a target_duration_s for the best length; without either the length is estimated from the text. [pause 1s] adds silence.",
            supports: ["voice_ref": true, "voice_ref_text": "optional", "target_duration": true, "languages": langs, "cues": ["pause"]],
            limits: ["max_text_chars": .int(Int64(maxTextChars)), "max_voice_ref_s": .double(maxVoiceRefSeconds),
                     "max_duration_s": .double(maxSeconds)])),
        PluginManifest.Offer(operation: "audio.design_voice", profile: "audio", model: offerModel(
            v, notes: "\(pace): a voice designed from a description, in English or Chinese. Keep the sample you like as an asset and clone it with voice_ref.",
            supports: ["languages": langs],
            limits: ["max_text_chars": .int(Int64(maxDescriptionChars)), "max_count": .int(Int64(maxSamples))])),
        PluginManifest.Offer(operation: "audio.edit_speech", profile: "audio", model: offerModel(
            v, notes: "\(pace): one edit of a take of up to 30 s, in the same voice, with no transcript needed: words replaced, inserted or removed; faster or slower, higher or lower, louder or quieter on AuK's trained steps; a new emotion, timbre or accent; to or from a whisper; denoised or dereverberated; a breath, laugh, cough or hum added at the start or end, or removed. Content and speed edits change the length: give target_duration_s to fit a cue. Mandarin edits need the int8 or bf16 lane.",
            supports: ["edits": .array(editKinds.map { .string($0) }),
                       "emotions": ["happy", "angry", "sad", "afraid", "surprised", "disgusted", "calm", "excited"],
                       "styles": ["whisper", "normal"], "cues": ["breath", "laugh", "cough", "hum"], "cue_placement": ["edge"],
                       "remove_all_cues": false, "transcript": "optional", "target_duration": true, "keeps_length": false,
                       "languages": langs],
            limits: ["max_duration_s": .double(maxSeconds)])),
        PluginManifest.Offer(operation: "audio.separate", profile: "audio", model: offerModel(
            v, notes: "\(pace): from a mixture of up to 30 s, one speaker (the n-th to start talking, or the one who says given words), the singing" + (v == .base ? ", or every voice." : ". Picking a later speaker by order is unreliable on Flash: name words they say instead.") + " Each stem is made again, at the mixture's length, so none can be subtracted from it.",
            supports: ["stems": .array(stems(v).map { .string($0) }), "speaker_selection": ["ordinal", "saying"],
                       "stem_method": "regenerated"],
            limits: ["max_duration_s": .double(maxSeconds)])),
    ]
}

public let aukPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.auk", version: "0.1.0", minGaea: "1.1.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-auk", title: "AuK",
    summary: "AuK and AuK-Flash (Tencent Hunyuan): cloned and designed speech, 14 kinds of speech edit with no transcript needed, and voice separation, in English and Chinese. Research use only.",
    license: "Apache-2.0", executable: "gaea-auk-worker",
    models: [model(.flash), model(.base)], offers: offers(.flash) + offers(.base))
