import AuKPlugin
import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXAuK
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: AuK or AuK-Flash loaded by MLXServeEngine in this process, with the lane
// configuration, the requests and the seeding the worker uses (AuKPlugin). The WAVs are written to --out (speak, edit),
// --out-dir as samples-<i>.wav (design) or <stem>.wav (separate), and one JSON line of timings is printed. Not part of
// the plugin bundle.
//
//   auk-inproc speak --ref <wav> [--ref-text <transcript>] [--text <text>] [--language en] [--target-duration 4] …
//   auk-inproc design --description <text> [--text <sample>] [--language en] [--count 1] [--out-dir <dir>] …
//   auk-inproc edit --take <wav> --edit '<MES edit JSON>' [--transcript <text>] [--target-duration 4] …
//   auk-inproc separate --mixture <wav> [--stems speaker,singing] [--ordinal 1 | --saying <words>] [--out-dir <dir>] …
//   common: [--model auk-flash | auk] [--lane int8 | bf16 | int4] [--seed 42] [--models-root <dir>] [--out <wav>]

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.isEmpty ? "speak" : args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let variant: Variant = option("--model") == "auk" ? .base : .flash
let laneID = option("--lane") ?? "int8"
let seed = UInt64(option("--seed") ?? "") ?? 42
let modelsRoot = URL(fileURLWithPath: option("--models-root") ?? "/Volumes/DEV_VOL1/Models/Models", isDirectory: true)
guard let lane = lanes(variant).first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }
func file(_ path: String?) throws -> Data? { try path.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } }

// The budget Gaea sends a worker on a large Mac.
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: true), licenseEnforcement: .advisory)
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID(variant))
let registration = variant == .flash ? AuKFlashPackage.registration : AuKPackage.registration
_ = try await engine.register(registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
let capability: Capability = mode == "edit" ? .speechEdit : mode == "separate" ? .audioSeparation : .tts
_ = try await engine.prepare(capability, package: id)
var result: [String: Any] = ["model": modelID(variant), "lane": laneID, "seed": seed, "prepare_s": seconds(since: clock)]
func run(_ request: any WireRequest) async throws -> any CapabilityResponse { try await engine.run(request, package: id) }

clock = ContinuousClock.now
switch mode {
case "design":
    let plan = try designPlan(description: option("--description"), text: option("--text"), language: option("--language"),
                              count: Int(option("--count") ?? ""), seed: seed)
    let dir = URL(fileURLWithPath: option("--out-dir") ?? ".", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<plan.count {
        let response = try await run(request(plan, sample: i)) as! TTSResponse
        try wav16(try pcm16(response.audio.data)).write(to: dir.appending(path: "samples-\(i).wav"))
    }
    result["text"] = plan.text
case "edit":
    let edit = try JSONDecoder().decode(JSONValue.self, from: Data((option("--edit") ?? "{}").utf8))
    let plan = try editPlan(edit: edit, transcript: option("--transcript"), targetDuration: option("--target-duration").flatMap(Double.init),
                            lane: laneID, seed: seed)
    let take = try file(option("--take")) ?? { fatalError("edit needs --take") }()
    let response = try await run(request(plan, take: take)) as! SpeechEditResponse
    let pcm = try pcm16(response.audio.data)
    if let out = option("--out") { try wav16(pcm).write(to: URL(fileURLWithPath: out)) }
    result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
    result["transcript"] = newTranscript(plan, response: response) ?? ""
case "separate":
    var params: [String: JSONValue] = [:]
    let asked = (option("--stems") ?? "").split(separator: ",").map(String.init)
    if let n = option("--ordinal").flatMap(Int.init) { params["speaker"] = ["ordinal": .int(Int64(n))] }
    if let words = option("--saying") { params["speaker"] = ["saying": .string(words)] }
    // The stems Gaea's plan names: the request's, else the offer's without speaker, or speaker for a pick (Audio §3.6).
    let made = !asked.isEmpty ? asked : params["speaker"] != nil ? ["speaker"] : stems(variant).filter { $0 != "speaker" }
    params["stems"] = .array(made.map { .string($0) })
    let mixture = try file(option("--mixture")) ?? { fatalError("separate needs --mixture") }()
    let separation = try AudioSeparations.request(mixture: mixture, params: params, metaData: ["seed": .int(Int(seed))])
    let response = try await run(separation) as! AudioSeparationResponse
    let dir = URL(fileURLWithPath: option("--out-dir") ?? ".", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try AudioSeparations.outputs(response, stems: made, mixture: mixture, outputDir: dir)
    result["stems"] = made
default:
    let plan = try speakPlan(text: option("--text") ?? "Gaea speaks. This sentence came from a signed plugin, over its own protocol.",
                             reference: try file(option("--ref")), transcript: option("--ref-text"), language: option("--language"),
                             targetDuration: option("--target-duration").flatMap(Double.init), seed: seed)
    let pcm = try await speak(plan.pieces) { i, words in
        (try await run(request(plan, piece: i, words: words)) as! TTSResponse).audio.data
    }
    if let out = option("--out") { try wav16(pcm).write(to: URL(fileURLWithPath: out)) }
    result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
}
result["run_s"] = seconds(since: clock)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
