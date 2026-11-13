# Project notes for Claude

Internal test demo for Slovak speech-to-text: a Flutter app (iOS + Android) that compares offline (on-device, sherpa-onnx) and online (cloud, through a proxy) models. The README has the full documentation, results and known gaps; read it before changing anything substantial. This file is the working context that the README does not carry.

## Where things stand (2026-11-13)

- **Chosen offline model: `kinit-parakeet-tdt-v3-sk-thirdparty`** (KInIT's Slovak Parakeet fine-tune, CC-BY-4.0, commercial use accepted by the owner). 7.8 % WER on FLEURS sk, RTF 0.06 on a laptop CPU, no hallucination on silence. Fallback: `kinit-whisper-small-sk`.
- **The app has never been run**, on any device or emulator. It analyzes cleanly, 46 unit tests pass and the Android debug APK builds. Everything at runtime is untested: microphone, VAD, on-device inference in the background isolate, model download, the screens.
- **iOS has never been built.** Expect the first build to fail and need fixes.
- **No cloud provider has been called for real**; there are no API keys yet. The proxy is tested against fakes only.

## Next goal

Get the app running on the owner's iPhone 17 from a Mac, then do a first real offline transcription with the Parakeet model and read the speed (RTF) and memory numbers the app records. Steps are in the README under "Running on an iPhone (needs a Mac)". Offline testing needs no proxy: that model downloads from Hugging Face inside the app.

Once it runs, the first things worth checking on the phone: recording and VAD chunking work, the model downloads and loads, transcription returns text, RTF and peak memory are plausible.

## Two machines

- **Mac**: building, running and fixing the app on the iPhone.
- **Windows laptop**: benchmarks, model conversion, proxy work. It holds what is not in git: `models_out/` (converted models), `testsets/`, `results/`, and the Python environments.
- Sync through git only. Pull before starting, push when done. Commit fixes to `app/ios/` and `app/android/`; they are tracked on purpose.
- Do not commit a personal Apple team ID or a personal bundle identifier unless the owner asks.

## Rules from the owner

- Verify model repo names, API endpoints and package versions against current documentation before using them.
- If something is blocked, document it in the README and continue with the rest; never skip silently.
- Ask before adding any paid service beyond the listed providers (Soniox, ElevenLabs, Speechmatics, OpenAI, optionally Gemini and Deepgram). An Apple Developer Program membership or a paid cloud build service counts.
- API keys never go into the app binary or into git. They live in `proxy/.env`, which is git-ignored.
- Language is always forced to Slovak (`sk`); never auto-detect.
- Report what was actually run and what was not. Do not describe untested code as working.

## Things that are easy to get wrong

- **Whisper needs silence appended to each chunk** (`kWhisperSilencePad` in `app/lib/engines/offline_worker.dart`, mirrored in `tools/eval/evaluate.py`). sherpa-onnx caps Whisper at 6 tokens per second of input audio, which truncates dense VAD chunks mid-word. Keep both sides in sync. Parakeet is unaffected.
- **Whisper drops audio past 30 s per call**, hence the 28 s window and the 25 s VAD chunk cap.
- **Normalization rules have one source**: `shared/normalization/sk_rules.json`. After editing it, run `python tools/common/gen_dart_rules.py` to regenerate `app/lib/core/normalization_rules.g.dart`; a Python test fails if the Dart file is stale.
- **The model catalog is `app/assets/models.json`**; the app, the attributions screen and `evaluate.py` all read it. Adding a sherpa-onnx model is a catalog entry, not a code change.
- **Speed numbers only mean something in release builds** (`flutter run --release`).
- The 9 `flutter analyze` infos about `package:flutter/material.dart` being deprecated are known and left alone.

## Checks

```bash
cd app && flutter analyze && flutter test        # 0 errors/warnings, 46 tests
cd proxy && node --test                          # 13 tests, Node 22+
python -m unittest discover -s tools/tests -t tools   # 8 tests, needs tools/eval/requirements.txt
```

## Open items

- The Whisper "VAD on" numbers in the README predate the padding fix; the full set has not been re-run with it (only a 66-clip sample for KInIT small).
- Own conversion of the KInIT Parakeet model (NeMo needs Linux; Docker on the Windows machine is the planned route). The files in use are a third-party export.
- KInIT lists FLEURS in its training data, so the FLEURS score for its models may be optimistic. A test on the owner's own recordings would settle it.
- Realtime streaming, Opus upload compression and Common Voice are not done; see "Known gaps" in the README.
