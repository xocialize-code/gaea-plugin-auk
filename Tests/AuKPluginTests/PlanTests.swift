@testable import AuKPlugin
import Foundation
import GaeaProtocol
import MLXToolKit
import Testing

/// A 16-bit mono WAV of `seconds` of silence.
func clip(_ seconds: Double, rate: Int = 16000) -> Data {
    var out = Data()
    let pcm = Data(count: Int(seconds * Double(rate)) * 2)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

@Suite("Requests")
struct PlanTests {
    @Test func speakNeedsAReferenceAndALength() throws {
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", reference: nil, transcript: nil, language: nil, targetDuration: nil, seed: 1) }
        let estimated = try speakPlan(text: "Hello there, friend.", reference: clip(3), transcript: nil, language: nil, targetDuration: nil, seed: 1)
        #expect(estimated.lengths?.count == 1 && estimated.effective["x-auk.length"] == .string("estimated"))
        let transcribed = try speakPlan(text: "Hello.", reference: clip(3), transcript: "The clip's words.", language: nil, targetDuration: nil, seed: 1)
        #expect(transcribed.lengths == nil && request(transcribed, piece: 0, words: "Hello.").referenceTranscript == "The clip's words.")
        let fitted = try speakPlan(text: "One two three. [pause 1s] Four.", reference: clip(3), transcript: nil, language: nil, targetDuration: 5, seed: 1)
        #expect(abs((fitted.lengths ?? []).reduce(0, +) - 4) < 1e-9 && request(fitted, piece: 1, words: "Four.").targetDuration != nil)
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", reference: clip(3), transcript: nil, language: nil, targetDuration: 31, seed: 1) }
        #expect(throws: GPPError.self) { try speakPlan(text: String(repeating: "word ", count: 110), reference: clip(3), transcript: nil, language: nil, targetDuration: nil, seed: 1) }
        #expect(try speakPlan(text: "你好", reference: clip(3), transcript: nil, language: nil, targetDuration: nil, seed: 1).effective["language"] == .string("zh"))
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", reference: clip(3), transcript: nil, language: "fr", targetDuration: nil, seed: 1) }
    }

    @Test func designIsInstructTTSAtSeedPlusI() throws {
        let d = try designPlan(description: "a bright young voice", text: nil, language: "zh", count: 2, seed: 4)
        #expect(d.text == designSamples["zh"])
        let r = request(d, sample: 1)
        #expect(r.voice.selection == .auto && r.emotion == .textDescription("a bright young voice") && r.metaData["seed"] == .int(5))
        #expect(throws: GPPError.self) { try designPlan(description: "x", text: nil, language: nil, count: 5, seed: 1) }
    }

    @Test func editsMapThroughTheKitWithAuKsLabels() throws {
        let afraid = try editPlan(edit: ["kind": "emotion", "emotion": "afraid"], transcript: nil, targetDuration: nil, lane: "int8", seed: 1)
        #expect(afraid.operation == .emotion("fearful"))
        let hum = try editPlan(edit: ["kind": "add_cue", "cue": "hum", "at": "end"], transcript: "Hello there.", targetDuration: nil, lane: "int8", seed: 1)
        #expect(hum.operation == .addNonverbal(sound: "humming", atEnd: true) && hum.newTranscript == "Hello there. [hum]")
        #expect(try editPlan(edit: ["kind": "dereverb"], transcript: nil, targetDuration: nil, lane: "int8", seed: 1).operation == .dereverberate)
        let fast = try editPlan(edit: ["kind": "speed", "factor": 1.3], transcript: nil, targetDuration: 3, lane: "int8", seed: 1)
        #expect(fast.operation == .speed(factor: 1.25) && fast.warnings.map(\.code) == ["param_adjusted"])
        #expect(request(fast, take: clip(2)).targetDuration == 3 && request(fast, take: clip(2)).seed == 1)
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "trim_silence"], transcript: nil, targetDuration: nil, lane: "int8", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "add_cue", "cue": "laugh", "text": "Hi [laugh]"], transcript: nil, targetDuration: nil, lane: "int8", seed: 1) }
    }

    @Test func mandarinEditsAreRefusedOnTheFourBitEncoder() throws {
        let zh: JSONValue = ["kind": "replace_text", "text": "今天", "with": "明天"]
        #expect(throws: GPPError.self) { try editPlan(edit: zh, transcript: nil, targetDuration: nil, lane: "int4", seed: 1) }
        #expect(try editPlan(edit: zh, transcript: nil, targetDuration: nil, lane: "int8", seed: 1).chinese)
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "de_accent"], transcript: "我们今天去公园。", targetDuration: nil, lane: "int4", seed: 1) }
        #expect(try editPlan(edit: ["kind": "de_accent"], transcript: "We went to the park.", targetDuration: nil, lane: "int4", seed: 1).chinese == false)
    }

    @Test func modelsLanesAndOffers() throws {
        #expect(lanes(.flash).map(\.id) == ["int8", "bf16", "int4"] && lanes(.base).filter(\.isDefault).map(\.id) == ["int8"])
        #expect(stems(.flash) == ["speaker", "singing"] && stems(.base) == ["speaker", "singing", "voices"])
        let manifest = try aukPlugin.manifest()
        #expect(manifest.offers.count == 8)
        for offer in manifest.offers {
            #expect(offer.model["named_only"] == true && offer.model["license"]?["commercial_use"] == false)
            #expect(offer.model["license"]?["user_accept_required"] == true && offer.model["license"]?["accepted_required"] == true)
        }
    }
}
