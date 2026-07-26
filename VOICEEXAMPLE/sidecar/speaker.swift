// speaker-sidecar: a persistent text-to-speech service supervised by
// lowlevel-lab via fx.spawn.
//
// Job channel: fx.spawn's stdin is write-once, so jobs arrive as spool
// files the app writes into --jobs-dir (job-<id>.json, {"id":N,"text":
// "..."}). The sidecar polls the directory, picks jobs up in id order,
// DELETES the file on pickup, and speaks the text straight to the
// output device through AVSpeechSynthesizer — no audio file is ever
// created anywhere in this pipeline.
//
// Status streams back as NDJSON on stdout (one event per line, flushed):
//
//   {"event":"ready","fake":false}
//   {"event":"job","id":42,"status":"speaking"}
//   {"event":"job","id":42,"status":"done","duration_ms":1450}
//   {"event":"job","id":42,"status":"skipped","duration_ms":300}
//   {"event":"job","id":42,"status":"failed","message":"..."}
//
// Job files may carry "rate" (AVSpeechUtterance rate, ~0.4 slow to
// ~0.6 fast; default 0.5). A sentinel file named `skip` in the jobs
// dir stops the CURRENT utterance immediately (the app writes it, we
// delete it) — the same trick the app uses because fx.cancel would be
// SIGKILL.
//
// --fake skips synthesis and simulates duration (50ms/char, clamped
// 300ms..10s) for headless verification; skip works there too.
//
// Usage: speaker-sidecar --jobs-dir <dir> [--fake] [--poll-hz 10]

import AVFoundation
import Foundation

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
    var jobsDir = ""
    var fake = false
    var pollHz = 10.0
}

func parseArgs() -> Args {
    var args = Args()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--jobs-dir": args.jobsDir = iterator.next() ?? ""
        case "--fake": args.fake = true
        case "--poll-hz": args.pollHz = Double(iterator.next() ?? "") ?? args.pollHz
        default:
            emit(["event": "error", "code": "bad_arg", "message": "unknown argument \(arg)"])
            exit(2)
        }
    }
    if args.jobsDir.isEmpty {
        emit(["event": "error", "code": "bad_arg", "message": "--jobs-dir is required"])
        exit(2)
    }
    return args
}

struct Job {
    let id: UInt64
    let text: String
    let rate: Float
    let voice: String
}

func skipFilePath(_ jobsDir: String) -> String {
    (jobsDir as NSString).appendingPathComponent("skip")
}

/// True (and consumes the sentinel) when the app asked to skip the
/// current utterance.
func takeSkipRequest(_ jobsDir: String) -> Bool {
    let path = skipFilePath(jobsDir)
    guard FileManager.default.fileExists(atPath: path) else { return false }
    try? FileManager.default.removeItem(atPath: path)
    return true
}

/// The pause/resume channel: the app writes "pause" or "resume" into a
/// `transport` sentinel; we consume it and apply it to the current
/// utterance (fx has no delete-file effect, so content-carrying
/// sentinels beat exists/absent flags).
func takeTransportRequest(_ jobsDir: String) -> String? {
    let path = (jobsDir as NSString).appendingPathComponent("transport")
    guard let data = FileManager.default.contents(atPath: path),
        let command = String(data: data, encoding: .utf8)
    else { return nil }
    try? FileManager.default.removeItem(atPath: path)
    return command.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Spool files in id order. Filenames are job-<id>.json; anything else
/// in the directory is ignored.
func pendingJobFiles(_ dir: String) -> [(id: UInt64, path: String)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var jobs: [(UInt64, String)] = []
    for name in names {
        guard name.hasPrefix("job-"), name.hasSuffix(".json") else { continue }
        let idText = name.dropFirst(4).dropLast(5)
        guard let id = UInt64(idText) else { continue }
        jobs.append((id, (dir as NSString).appendingPathComponent(name)))
    }
    return jobs.sorted { $0.0 < $1.0 }
}

/// Read and DELETE the spool file — pickup is consumption, so a
/// respawned sidecar never double-speaks and nothing lingers on disk.
func takeJob(id: UInt64, path: String) -> Job? {
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let data = FileManager.default.contents(atPath: path),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let text = object["text"] as? String, !text.isEmpty
    else {
        emit(["event": "job", "id": id, "status": "failed", "message": "unreadable job file"])
        return nil
    }
    let rate = Float((object["rate"] as? Double) ?? 0.5)
    let voice = (object["voice"] as? String) ?? ""
    return Job(id: id, text: text, rate: min(max(rate, 0.1), 0.9), voice: voice)
}

let synthesizer = AVSpeechSynthesizer()

/// Speak and block until playback finishes (or the skip sentinel
/// appears). CLI processes have no running main loop, so spin it while
/// the synthesizer works. Returns the terminal status to report:
/// "done", "skipped", or "failed" (synthesis never started — broken
/// audio route/voice; reporting that as done would let a silent queue
/// masquerade as played).
func speak(_ id: UInt64, _ text: String, rate: Float, voice: String, jobsDir: String) -> String {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = rate
    // Voice by display name (the design's picker); silently keeps the
    // system default when the name is not installed.
    if !voice.isEmpty, let match = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voice }) {
        utterance.voice = match
    }
    let start = Date()
    var pausedTotal = 0.0
    var pausedSince: Date? = nil
    var lastProgress = Date()
    synthesizer.speak(utterance)
    // isSpeaking flips true asynchronously (voice loading can take a
    // while on a cold start). Trust a false reading only AFTER speech
    // was observed running — reporting done early would let the app
    // dispatch the next job while this one's audio is still playing,
    // and the queue's state would run ahead of what the user hears.
    var sawSpeaking = false
    while !gStop && Date().timeIntervalSince(start) < 300 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if synthesizer.isSpeaking && !synthesizer.isPaused { sawSpeaking = true }
        if takeSkipRequest(jobsDir) {
            synthesizer.stopSpeaking(at: .immediate)
            return "skipped"
        }
        if let transport = takeTransportRequest(jobsDir) {
            if transport == "pause" && !synthesizer.isPaused {
                synthesizer.pauseSpeaking(at: .word)
                pausedSince = Date()
                emit(["event": "job", "id": id, "status": "paused"])
            } else if transport == "resume" && synthesizer.isPaused {
                synthesizer.continueSpeaking()
                if let since = pausedSince { pausedTotal += Date().timeIntervalSince(since) }
                pausedSince = nil
                emit(["event": "job", "id": id, "status": "resumed"])
            }
        }
        // ~2Hz elapsed reports (paused time excluded) for the Now
        // Playing strip.
        if Date().timeIntervalSince(lastProgress) >= 0.5 {
            lastProgress = Date()
            let paused = pausedTotal + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
            emit([
                "event": "progress", "id": id,
                "elapsed_ms": Int((Date().timeIntervalSince(start) - paused) * 1000),
            ])
        }
        if sawSpeaking && !synthesizer.isSpeaking && !synthesizer.isPaused { break }
        if !sawSpeaking && Date().timeIntervalSince(start) > 10 { return "failed" }  // never started
    }
    return "done"
}

let args = parseArgs()
try? FileManager.default.createDirectory(atPath: args.jobsDir, withIntermediateDirectories: true)
emit(["event": "ready", "fake": args.fake])

/// The fake path mirrors the real transport surface: skip, pause/
/// resume, and ~2Hz progress — just without audio.
func fakeSpeak(_ id: UInt64, _ text: String, jobsDir: String) -> String {
    let total = min(max(Double(text.count) * 0.05, 0.3), 10.0)
    var elapsed = 0.0
    var paused = false
    var lastProgress = Date()
    while !gStop && elapsed < total {
        Thread.sleep(forTimeInterval: 0.05)
        if !paused { elapsed += 0.05 }
        if takeSkipRequest(jobsDir) { return "skipped" }
        if let transport = takeTransportRequest(jobsDir) {
            if transport == "pause" && !paused {
                paused = true
                emit(["event": "job", "id": id, "status": "paused"])
            } else if transport == "resume" && paused {
                paused = false
                emit(["event": "job", "id": id, "status": "resumed"])
            }
        }
        if Date().timeIntervalSince(lastProgress) >= 0.5 {
            lastProgress = Date()
            emit(["event": "progress", "id": id, "elapsed_ms": Int(elapsed * 1000)])
        }
    }
    return "done"
}

let tick = 1.0 / args.pollHz
while !gStop {
    // Stale requests with nothing speaking must not affect a future
    // utterance — consume them.
    _ = takeSkipRequest(args.jobsDir)
    _ = takeTransportRequest(args.jobsDir)
    for entry in pendingJobFiles(args.jobsDir) {
        if gStop { break }
        guard let job = takeJob(id: entry.id, path: entry.path) else { continue }
        emit(["event": "job", "id": job.id, "status": "speaking"])
        let start = Date()
        let status =
            args.fake
            ? fakeSpeak(job.id, job.text, jobsDir: args.jobsDir)
            : speak(job.id, job.text, rate: job.rate, voice: job.voice, jobsDir: args.jobsDir)
        emit([
            "event": "job", "id": job.id, "status": status,
            "duration_ms": Int(Date().timeIntervalSince(start) * 1000),
        ])
    }
    Thread.sleep(forTimeInterval: tick)
}
