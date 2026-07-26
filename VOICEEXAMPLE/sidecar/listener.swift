// listener-sidecar: an EPHEMERAL speech-to-text service, spawned fresh
// by lowlevel-lab for exactly one reply attempt (unlike speaker.swift,
// which is persistent and supervised) — a failed or denied attempt
// just lets the user tap the mic again, so there's no backoff/respawn
// machinery here.
//
// Streaming, no audio file ever: an AVAudioEngine input tap feeds
// SFSpeechAudioBufferRecognitionRequest directly (the same "no audio
// file is ever created" invariant the TTS side already holds — there
// is no intermediate .m4a/.wav at any point, unlike a record-then-
// transcribe design).
//
// Control is the same sentinel-file trick speaker.swift uses for
// skip/transport, since fx.cancel is SIGKILL-only: the app writes a
// stop file, we poll for it (~10Hz), stop the tap, finish the
// recognition request, and report whatever it produced.
//
// Status streams back as NDJSON on stdout (one event per line, flushed):
//
//   {"event":"ready"}
//   {"event":"transcript","text":"..."}
//   {"event":"error","detail":"mic_denied"|"speech_denied"|"transcription_failed"}
//
// --fake skips real audio/recognition entirely (driven by the app's
// shared test_mode setting — one coherent headless switch, not a
// second independent one) and returns a canned transcript on the same
// stop-file signal, so the whole record -> transcribing -> populated-
// field flow is exercisable without touching a microphone.
//
// Usage: listener-sidecar --stop-file <path> [--fake] [--fake-transcript "..."]

import AVFoundation
import Foundation
import Speech

var gStop = false
signal(SIGTERM) { _ in gStop = true }
signal(SIGINT) { _ in gStop = true }

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
        let line = String(data: data, encoding: .utf8)
    else { return }
    print(line)
    fflush(stdout)
}

struct Args {
    var stopFile = ""
    var fake = false
    var fakeTranscript = "This is a simulated voice reply."
}

func parseArgs() -> Args {
    var args = Args()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--stop-file": args.stopFile = iterator.next() ?? ""
        case "--fake": args.fake = true
        case "--fake-transcript": args.fakeTranscript = iterator.next() ?? args.fakeTranscript
        default:
            emit(["event": "error", "detail": "bad_arg"])
            exit(2)
        }
    }
    if args.stopFile.isEmpty {
        emit(["event": "error", "detail": "bad_arg"])
        exit(2)
    }
    return args
}

/// True (and consumes the sentinel) when the app asked to stop
/// recording. Existence-based, like speaker.swift's skip file — there's
/// only one signal to carry, unlike transport's pause/resume verbs.
func takeStopRequest(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    try? FileManager.default.removeItem(atPath: path)
    return true
}

/// Blocks on an async permission callback — this CLI has no running
/// main loop of its own yet, so a semaphore is the simplest bridge.
/// BOUNDED: a bare, unbundled binary may never get a TCC callback at
/// all (observed directly: no dialog, no callback, hangs forever) —
/// a timeout turns that into an honest denial instead of a wedged
/// process with no visible symptom.
let permissionTimeoutSeconds: Double = 15

func requestMicPermission() -> Bool {
    var granted = false
    let semaphore = DispatchSemaphore(value: 0)
    if #available(macOS 14.0, *) {
        AVAudioApplication.requestRecordPermission { ok in
            granted = ok
            semaphore.signal()
        }
    } else {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
    }
    if semaphore.wait(timeout: .now() + permissionTimeoutSeconds) == .timedOut { return false }
    return granted
}

func requestSpeechPermission() -> Bool {
    var authorized = false
    let semaphore = DispatchSemaphore(value: 0)
    SFSpeechRecognizer.requestAuthorization { status in
        authorized = (status == .authorized)
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + permissionTimeoutSeconds) == .timedOut { return false }
    return authorized
}

/// Streams mic input straight into on-device recognition until the app
/// signals stop, then waits briefly for the recognizer's final result.
/// Never writes an audio file at any point.
func listenAndTranscribe(stopFile: String) -> String? {
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
        emit(["event": "error", "detail": "speech_unavailable"])
        return nil
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false

    var finalText: String? = nil
    var recognitionFailed = false
    var finished = false
    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result = result, result.isFinal {
            finalText = result.bestTranscription.formattedString
            finished = true
        }
        if error != nil {
            recognitionFailed = true
            finished = true
        }
    }

    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
    }
    audioEngine.prepare()
    guard (try? audioEngine.start()) != nil else {
        inputNode.removeTap(onBus: 0)
        task.cancel()
        emit(["event": "error", "detail": "mic_unavailable"])
        return nil
    }

    while !gStop && !takeStopRequest(stopFile) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    audioEngine.stop()
    inputNode.removeTap(onBus: 0)
    request.endAudio()

    // The final result callback lands shortly after endAudio(), not
    // synchronously — give it a bounded window.
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    task.cancel()

    if recognitionFailed { return nil }
    guard let text = finalText, !text.isEmpty else { return nil }
    return text
}

/// The fake path mirrors the real control surface (poll for the same
/// stop file) without ever touching a microphone.
func fakeListen(stopFile: String, transcript: String) -> String {
    while !gStop && !takeStopRequest(stopFile) {
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.2)  // a beat, so "transcribing" is visibly exercised
    return transcript
}

let args = parseArgs()
_ = takeStopRequest(args.stopFile)  // a stale request from a prior attempt must not end this one early

if args.fake {
    emit(["event": "ready"])
    let text = fakeListen(stopFile: args.stopFile, transcript: args.fakeTranscript)
    emit(["event": "transcript", "text": text])
    exit(0)
}

guard requestMicPermission() else {
    emit(["event": "error", "detail": "mic_denied"])
    exit(0)
}
guard requestSpeechPermission() else {
    emit(["event": "error", "detail": "speech_denied"])
    exit(0)
}
emit(["event": "ready"])

if let text = listenAndTranscribe(stopFile: args.stopFile) {
    emit(["event": "transcript", "text": text])
} else {
    emit(["event": "error", "detail": "transcription_failed"])
}
exit(0)
