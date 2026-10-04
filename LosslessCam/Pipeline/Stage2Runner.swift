import Foundation
import UIKit
import Combine

/// Runs stage-2 transcodes (intermediate -> FFV1/FLAC MKV) and verifications
/// one at a time on a background thread, publishing progress for the UI and
/// updating each recording's sidecar JSON.
final class Stage2Runner: ObservableObject {
    static let shared = Stage2Runner()

    struct Job: Identifiable, Equatable {
        enum Kind: String { case transcode, verify }
        var id: String { baseName + "-" + kind.rawValue }
        var baseName: String
        var kind: Kind
        var progress: Double = 0
        var phase: String = "Queued"
        var error: String?
        var finished = false
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var current: Job?

    static let recordingUpdated = Notification.Name("LosslessCam.recordingUpdated")

    private let queue = DispatchQueue(label: "com.losslesscam.stage2", qos: .userInitiated)
    private var cancelFlags: [String: UnsafeMutablePointer<Int32>] = [:]
    private let lock = NSLock()

    private final class ProgressBox {
        let runner: Stage2Runner
        let jobID: String
        var last: Double = 0
        var lastTime: Double = 0
        init(runner: Stage2Runner, jobID: String) { self.runner = runner; self.jobID = jobID }
    }

    private let progressCallback: LCProgressFn = { ctx, fraction, phase in
        guard let ctx = ctx else { return }
        let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
        let now = CACurrentMediaTime()
        if fraction >= 1.0 || fraction - box.last > 0.005 || now - box.lastTime > 0.2 {
            box.last = fraction
            box.lastTime = now
            let text = phase.map { String(cString: $0) } ?? ""
            box.runner.update(jobID: box.jobID, progress: fraction, phase: text)
        }
    }

    // MARK: Public API

    func enqueue(recording: Recording, ffv1: LCFfv1Params, flacLevel: Int, metadata: [String]) {
        let job = Job(baseName: recording.baseName, kind: .transcode)
        appendJob(job)
        queue.async { [self] in
            self.runTranscode(recording: recording, ffv1: ffv1, flacLevel: flacLevel, metadata: metadata, jobID: job.id)
        }
    }

    func enqueueVerification(recording: Recording) {
        let job = Job(baseName: recording.baseName, kind: .verify)
        appendJob(job)
        queue.async { [self] in self.runVerification(recording: recording, jobID: job.id) }
    }

    /// Resume stage 2 for recordings whose intermediate still exists (e.g. after a crash).
    func resumePending(recordings: [Recording], ffv1: LCFfv1Params, flacLevel: Int) {
        for r in recordings where r.stage2.status == .pending || r.stage2.status == .running || r.stage2.status == .failed {
            if let lci = r.intermediateURL, FileManager.default.fileExists(atPath: lci.path), r.files.mkv == nil || r.stage2.status != .done {
                if !jobs.contains(where: { $0.baseName == r.baseName && !$0.finished }) {
                    enqueue(recording: r, ffv1: ffv1, flacLevel: flacLevel, metadata: ["LOSSLESSCAM_STAGE2", "resumed"])
                }
            }
        }
    }

    func cancel(baseName: String) {
        lock.lock()
        cancelFlags[baseName]?.pointee = 1
        lock.unlock()
    }

    func isBusy(baseName: String) -> Bool {
        jobs.contains { $0.baseName == baseName && !$0.finished }
    }

    // MARK: Internals

    private func appendJob(_ job: Job) {
        DispatchQueue.main.async {
            self.jobs.removeAll { $0.id == job.id }
            self.jobs.append(job)
        }
    }

    fileprivate func update(jobID: String, progress: Double, phase: String, error: String? = nil, finished: Bool = false) {
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                self.jobs[i].progress = progress
                self.jobs[i].phase = phase
                if let e = error { self.jobs[i].error = e }
                self.jobs[i].finished = finished
                self.current = finished ? nil : self.jobs[i]
            }
            if finished {
                // Keep the list short.
                let done = self.jobs.filter { $0.finished }
                if done.count > 10, let first = done.first { self.jobs.removeAll { $0.id == first.id } }
            }
        }
    }

    private func cancelFlag(for baseName: String) -> UnsafeMutablePointer<Int32> {
        lock.lock(); defer { lock.unlock() }
        if let f = cancelFlags[baseName] { f.pointee = 0; return f }
        let f = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        f.pointee = 0
        cancelFlags[baseName] = f
        return f
    }

    private func withBackgroundTask<T>(_ name: String, _ body: () -> T) -> T {
        var id: UIBackgroundTaskIdentifier = .invalid
        DispatchQueue.main.sync {
            id = UIApplication.shared.beginBackgroundTask(withName: name) {
                // Expiring: nothing to do, the job continues when the app returns to the foreground
                // (files are consistent at every chunk boundary).
            }
        }
        let r = body()
        DispatchQueue.main.async { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        return r
    }

    private func reload(_ recording: Recording) -> Recording {
        (try? Recording.load(from: recording.sidecarURL)) ?? recording
    }

    private func runTranscode(recording input: Recording, ffv1: LCFfv1Params, flacLevel: Int, metadata: [String], jobID: String) {
        var rec = reload(input)
        guard let lci = rec.intermediateURL else {
            update(jobID: jobID, progress: 1, phase: "No intermediate file", error: "missing .lci", finished: true)
            return
        }
        rec.stage2.status = .running
        try? rec.save()
        notifyUpdated()
        update(jobID: jobID, progress: 0, phase: "Starting FFV1 encode")

        let mkvPath = Recording.documentsDirectory().appendingPathComponent(rec.baseName + ".mkv").path
        let box = ProgressBox(runner: self, jobID: jobID)
        let flag = cancelFlag(for: rec.baseName)
        var params = ffv1
        var stats = LCTranscodeStats()
        var err = [CChar](repeating: 0, count: 512)
        let start = CACurrentMediaTime()
        let rc: Int32 = withBackgroundTask("stage2") {
            withCStringArray(metadata) { meta in
                lc_transcode_intermediate(lci.path, mkvPath, &params, Int32(flacLevel), meta,
                                          rec.hashListURL.path, Int32(rec.audio?.sampleRate ?? 48000),
                                          progressCallback, Unmanaged.passUnretained(box).toOpaque(), flag, &stats, &err, err.count)
            }
        }
        let seconds = CACurrentMediaTime() - start
        rec = reload(rec)
        rec.stage2.seconds = seconds
        rec.stage2.intermediateHashMismatches = stats.intermediate_hash_mismatches
        rec.stage2.recoveredWithoutTrailer = stats.recovered_without_trailer != 0
        if rc == 0 {
            rec.stage2.status = .done
            rec.stage2.progress = 1
            rec.files.mkv = rec.baseName + ".mkv"
            rec.lowBitsNonZero = rec.lowBitsNonZero || stats.low_bits_seen != 0
            if var a = rec.audio {
                a.trimmedFrames = stats.audio_trimmed_frames
                a.discontinuities = Int(stats.audio_discontinuities)
                a.silenceFramesInserted = stats.audio_silence_frames_inserted
                rec.audio = a
            }
            // Intermediate is no longer needed.
            try? FileManager.default.removeItem(at: lci)
            rec.files.intermediate = nil
            try? rec.save()
            notifyUpdated()
            update(jobID: jobID, progress: 1, phase: "FFV1/FLAC MKV written in \(String(format: "%.1f", seconds)) s", finished: true)
            runVerification(recording: rec, jobID: nil)
        } else {
            let message = String(cString: err)
            rec.stage2.status = flag.pointee != 0 ? .cancelled : .failed
            rec.stage2.error = message
            try? rec.save()
            notifyUpdated()
            update(jobID: jobID, progress: 1, phase: "Stage 2 failed", error: message, finished: true)
            // Keep the partial MKV out of the library.
            try? FileManager.default.removeItem(atPath: mkvPath)
        }
    }

    private func runVerification(recording input: Recording, jobID: String?) {
        var rec = reload(input)
        let job: Job
        if let id = jobID, let j = jobs.first(where: { $0.id == id }) { job = j } else {
            job = Job(baseName: rec.baseName, kind: .verify)
            appendJob(job)
        }
        guard let mkv = rec.mkvURL, FileManager.default.fileExists(atPath: mkv.path) else {
            update(jobID: job.id, progress: 1, phase: "No MKV to verify", error: "missing .mkv", finished: true)
            return
        }
        rec.verification.status = .running
        try? rec.save()
        notifyUpdated()
        update(jobID: job.id, progress: 0, phase: "Verifying")

        let box = ProgressBox(runner: self, jobID: job.id)
        let flag = cancelFlag(for: rec.baseName)
        var result = LCVerifyResult()
        var err = [CChar](repeating: 0, count: 512)
        let rc: Int32 = withBackgroundTask("verify") {
            lc_verify_recording(mkv.path, rec.hashListURL.path, 0, progressCallback, Unmanaged.passUnretained(box).toOpaque(), flag, &result, &err, err.count)
        }
        rec = reload(rec)
        var v = Recording.VerificationState()
        func map(_ s: Int32) -> Recording.VerificationStatus {
            switch UInt32(s) {
            case LC_VERIFY_PASS.rawValue: return .pass
            case LC_VERIFY_FAIL.rawValue: return .fail
            case LC_VERIFY_CANCELLED.rawValue: return .cancelled
            default: return .error
            }
        }
        if rc == 0 {
            v.status = map(result.status)
            v.videoStatus = map(result.video_status)
            v.audioStatus = rec.audio == nil ? .pass : map(result.audio_status)
        } else {
            v.status = .error; v.videoStatus = .error; v.audioStatus = .error
        }
        v.framesChecked = result.frames_decoded
        v.framesExpected = result.frames_expected
        v.firstMismatchFrame = result.first_mismatch_frame
        v.audioFramesChecked = result.audio_frames_decoded
        v.audioFirstMismatchFrame = result.audio_first_mismatch_frame
        v.crcErrors = Int(result.crc_errors)
        v.sliceCrcChecked = result.crc_checked != 0
        v.checkedAt = Date()
        v.seconds = result.seconds
        let msg = String(cString: err)
        v.message = msg.isEmpty ? nil : msg
        rec.verification = v
        try? rec.save()
        notifyUpdated()
        let label: String
        switch v.status {
        case .pass: label = "Verification PASS (\(v.framesChecked) frames)"
        case .fail: label = "Verification FAIL at frame \(v.firstMismatchFrame)"
        case .cancelled: label = "Verification cancelled"
        default: label = "Verification error: \(msg)"
        }
        update(jobID: job.id, progress: 1, phase: label, error: v.status == .pass ? nil : msg, finished: true)
    }

    private func notifyUpdated() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Stage2Runner.recordingUpdated, object: nil) }
    }
}
