# gaea-plugin-auk

[AuK and AuK-Flash](https://huggingface.co/tencent/AuK) (Tencent Hunyuan) as a [Gaea](https://github.com/xocialize-code/gaea)
plugin on MES Audio 0.1 (with media-engine-spec v0.10.0's RFC 0006). In English and Chinese it offers:
- speech in a cloned voice, or a voice designed from a description;
- fourteen kinds of speech edit, with no transcript needed;
- voice separation.

It runs [mlx-auk-swift](https://github.com/xocialize/mlx-auk-swift) through MLXEngine, on GaeaPluginKit 0.11.0.

> **Research use only.** AuK's DiT and VAE are MIT, but AuK needs the Qwen2.5-Omni-3B encoder, which is under the
> **Qwen Research License Agreement**: for research and evaluation, not for commercial use. Gaea therefore offers both
> models named-only (a request must name them), off until the operator enables them, and asks every client's user to
> accept the terms (`policy.accepted: ["LicenseRef-Qwen-Research"]`).

Install it with `gaea plugins add https://github.com/xocialize-code/gaea-plugin-auk`, then enable the models you want
with `gaea models enable auk-flash` and `gaea models enable auk`.

## The models

| | `auk-flash` (AuK-Flash) | `auk` (AuK Base) |
|---|---|---|
| Speed | Quick: a 4-step distilled DiT, real-time factor about 0.13 | Slower and steadier, real-time factor about 0.89 |
| Separation | The speaker and the singing | The speaker, the singing, and every voice |

Each has three lanes, the encoder's quant: **int8** (the default, about 9.6 GB resident), **bf16** (about 12.9 GB) and
**int4** (about 8 GB). The 4-bit encoder drops words in Mandarin edits, so a Mandarin edit on int4 is refused: name
`x-gaea.lane: int8` or `bf16`.

## The operations

| Operation | What it does |
|---|---|
| `audio.speak` | A clone of `voice_ref` (up to 30 s). The length comes from `target_duration_s`, else from the clip's transcript (`voice_ref_text`), else it is estimated from the text. At most 30 s. `[pause Ns]` adds silence |
| `audio.design_voice` | A voice from a description, 1–4 samples at seed + i. Keep one as an asset, and clone it with `voice_ref` |
| `audio.edit_speech` | One edit of a take of up to 30 s: `emotion`, `style` (whisper ⇄ normal), `add_cue` and `remove_cue` (breath, laugh, cough, hum: at the start or end only, one kind at a time), `replace_text`, `insert_text`, `remove_text`, `speed`, `pitch` and `volume` (snapped to AuK's trained steps), `timbre`, `de_accent`, `denoise` and `dereverb`. No transcript is needed; one given is returned edited. `target_duration_s` fits a content or speed edit to a cue |
| `audio.separate` | From a mixture of up to 30 s: one speaker (`speaker: {ordinal: n}`, the n-th to start talking, or `{saying: "words"}`), the singing, or, on Base, every voice. Each stem is made again at the mixture's length (`stem_method: regenerated`), so none can be subtracted from it |

Output is 16-bit mono WAV at 24 kHz, which Gaea converts to what the request asks for. A seeded request is
reproducible.

## Building and checking

```
swift test
scripts/build-plugin.sh                 # the worker, manifest.json (validated), the signed bundle and its zip in dist/
scripts/check-plugin.sh                 # drive the bundle over GPP with every .build hidden, plus the metallib control
scripts/golden.sh <out-dir>             # seeded cases of every operation over GPP against auk-inproc, byte for byte
```

The checks read AuK's weights from `CHECK_MODELS_ROOT` (default `/Volumes/DEV_VOL1/Models/Models`) and never download.
The fixtures in `scripts/fixtures` were made with macOS's `say`: `ref-en.wav` is the clip they clone, and
`mix-two.wav` is a two-speaker mixture for separation.

`auk-inproc speak|design|edit|separate …` runs the same package in-process with the worker's requests and seeding.

`Package.swift` names the fleet's mlx-swift fork (`xocialize/mlx-swift`, AB-D-0208). A root line naming ml-explore's URL
would win, and could drop the fix for a leak that kills workers that reload quantized models.

## Releasing

Push a `v<version>` tag matching the manifest's version. CI (`.github/workflows/release.yml`, the `xcode-27` runner)
builds, signs, notarizes and publishes the zip, its sha256 and `manifest.json`.
