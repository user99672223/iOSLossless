import Foundation
import UIKit
import Combine

/// Runs stage-2 transcodes (intermediate -> FFV1/FLAC MKV) and verifications
/// one at a time on a background thread, publishing progress for the UI and
/// updating each recording's sidecar JSON.
///
/// The intermediate (.lci) is the only lossless copy until the final MKV has
/// been verified against the capture-time hashes, so it is deleted only after a
/// verification PASS. Jobs pause while a new recording is being captured so the
/// stage-1 workers keep every core.
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
        var paused = false
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var current: Job?
    @Published private(set) var paused = false

    static let recordingUpdated = Notification.Name("LosslessCam.recordingUpdated")

    /// Flag protocol shared with the C side: 0 = run, 1 = cancel, 2 = pause (the C loops sleep while 2).
    private let queue = DispatchQueue(label: "com.losslesscam.stage2", qos: .utility)
    private var cancelFlags: [String: UnsafeMutablePointer<Int32>] = [:]
    private var pauseRequested = false
    private let lock = NSLock()

    private final class ProgressBox {
        let runner: Stage2Runner
        let jobID: String
        var last: Double = 0
        var lastTime: Double = 0
        var lastPersisted: Double = 0
        var sidecarURL: URL?
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
            // Persist progress every ~5% so the Library badge and a resumed job show where things stand.
            if let url = box.sidecarURL, fraction - box.lastPersisted >= 0.05 {
                box.lastPersisted = fraction
                if var rec = try? Recording.load(from: url) {
                    rec.stage2.progress = fraction
                    try? rec.save()
                }
            }
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
        // A kept intermediate (stage 2 done, earlier verification not passed) is removed once the MKV verifies.
        let deleteOnPass = recording.stage2.status == .done
        queue.async { [self] in self.runVerification(recording: recording, jobID: job.id, deleteIntermediateOnPass: deleteOnPass) }
    }

    /// Resume stage 2 for recordings whose intermediate still exists (e.g. after a crash).
    /// Failed transcodes are left for the manual "Run stage 2 now" button so a corrupt
    /// intermediate does not retry forever at every launch.
    func resumePending(recordings: [Recording], ffv1: LCFfv1Params, flacLevel: Int) {
        lock.lock(); let paused = pauseRequested; lock.unlock()
        if paused { return }   // re-run after the recording (the library rescans then)
        let active = ActiveRecording.shared.baseName
        for r in recordings where (r.stage2.status == .pending || r.stage2.status == .running) && r.baseName != active {
            if let lci = r.intermediateURL, FileManager.default.fileExists(atPath: lci.path) {
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

    /// Pauses (true) or resumes (false) the running C loops; used while a recording is in progress.
    func setPaused(_ p: Bool) {
        lock.lock()
        pauseRequested = p
        for (_, f) in cancelFlags where f.pointee != 1 { f.pointee = p ? 2 : 0 }
        lock.unlock()
        DispatchQueue.main.async {
            self.paused = p
            for i in self.jobs.indices where !self.jobs[i].finished { self.jobs[i].paused = p }
            if let c = self.current, let j = self.jobs.first(where: { $0.id == c.id }) { self.current = j }
        }
    }

    func isBusy(baseName: String) -> Bool {
        jobs.contains { $0.baseName == baseName && !$0.finished }
    }

    // MARK: Internals

    private func appendJob(_ job: Job) {
        let apply = {
            self.jobs.removeAll { $0.id == job.id }
            self.jobs.append(job)
        }
        // Synchronous on main so a second resumePending in the same run loop sees the job.
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    fileprivate func update(jobID: String, progress: Double, phase: String, error: String? = nil, finished: Bool = false) {
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                self.jobs[i].progress = progress
                self.jobs[i].phase = phase
                if let e = error { self.jobs[i].error = e }
                self.jobs[i].finished = finished
                self.jobs[i].paused = finished ? false : self.paused
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
        let initial: Int32 = pauseRequested ? 2 : 0
        if let f = cancelFlags[baseName] { f.pointee = initial; return f }
        let f = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        f.pointee = initial
        cancelFlags[baseName] = f
        return f
    }

    /// Background-task identifier shared between the job and its expiration handler.
    private final class TaskBox: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
        var expired = false     // guarded by Stage2Runner.lock
        var finished = false    // guarded by Stage2Runner.lock
    }

    /// Runs `body` with background execution time. iOS kills an app whose background task outlives
    /// its grace period, so on expiry the job is stopped at the next frame boundary (the C side sees
    /// the cancel flag), the task is ended, and the job is marked for resumption when the app is active.
    private func withBackgroundTask<T>(_ name: String, baseName: String, _ body: () -> T) -> (T, Bool) {
        let box = TaskBox()
        let begin = {
            box.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                var interrupted = false
                if let self = self {
                    self.lock.lock()
                    if !box.finished {
                        box.expired = true
                        self.cancelFlags[baseName]?.pointee = 1
                        interrupted = true
                    }
                    self.lock.unlock()
                }
                if interrupted {
                    DiagnosticsLog.shared.log("stage2", "\(name) for \(baseName) interrupted: background time expired; resumes when the app is active")
                }
                if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
            }
        }
        if Thread.isMainThread { begin() } else { DispatchQueue.main.sync(execute: begin) }
        let r = body()
        lock.lock()
        box.finished = true
        let expired = box.expired
        lock.unlock()
        DispatchQueue.main.async { if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid } }
        return (r, expired)
    }

    private func reload(_ recording: Recording) -> Recording {
        (try? Recording.load(from: recording.sidecarURL)) ?? recording
    }

    private func runTranscode(recording input: Recording, ffv1: LCFfv1Params, flacLevel: Int, metadata: [String], jobID: String) {
        var rec = reload(input)
        guard let lci = rec.intermediateURL, FileManager.default.fileExists(atPath: lci.path) else {
            update(jobID: jobID, progress: 1, phase: "No intermediate file", error: "missing .lci", finished: true)
            return
        }
        rec.stage2.status = .running
        rec.stage2.progress = 0
        rec.stage2.error = nil
        try? rec.save()
        notifyUpdated()
        update(jobID: jobID, progress: 0, phase: "Starting FFV1 encode")

        // Write to a temporary name: a failed or cancelled rebuild must not destroy an existing MKV.
        let mkvPath = Recording.documentsDirectory().appendingPathComponent(rec.baseName + ".mkv").path
        let partPath = mkvPath + ".part"
        try? FileManager.default.removeItem(atPath: partPath)
        let box = ProgressBox(runner: self, jobID: jobID)
        box.sidecarURL = rec.sidecarURL
        let flag = cancelFlag(for: rec.baseName)
        var params = ffv1
        var stats = LCTranscodeStats()
        var err = [CChar](repeating: 0, count: 512)
        let start = CACurrentMediaTime()
        let hashPath = rec.hashListURL.path
        let checkpoint = Int32(rec.audio?.sampleRate ?? 48000)
        let (rc, expired): (Int32, Bool) = withBackgroundTask("stage2", baseName: rec.baseName) {
            withCStringArray(metadata) { meta in
                lc_transcode_intermediate(lci.path, partPath, &params, Int32(flacLevel), meta,
                                          hashPath, checkpoint,
                                          progressCallback, Unmanaged.passUnretained(box).toOpaque(), flag, &stats, &err, 512)
            }
        }
        let seconds = CACurrentMediaTime() - start
        rec = reload(rec)
        rec.stage2.seconds = seconds
        rec.stage2.intermediateHashMismatches = stats.intermediate_hash_mismatches
        rec.stage2.recoveredWithoutTrailer = stats.recovered_without_trailer != 0
        var renameError: String? = nil
        // Only a run that actually stopped early counts as interrupted by the background limit.
        let interrupted = expired && rc != 0
        if rc == 0 && rename(partPath, mkvPath) != 0 {
            renameError = "Could not move the new MKV into place: \(String(cString: strerror(errno)))"
        }
        if rc == 0 && renameError == nil {
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
            // The intermediate stays until verification proves the MKV bit-exact.
            try? rec.save()
            notifyUpdated()
            update(jobID: jobID, progress: 1, phase: "FFV1/FLAC MKV written in \(String(format: "%.1f", seconds)) s; verifying", finished: true)
            runVerification(recording: rec, jobID: nil, deleteIntermediateOnPass: true)
        } else {
            let message = renameError ?? (interrupted ? "Interrupted because the app was in the background; resumes when the app is open" : String(cString: err))
            rec.stage2.status = interrupted ? .pending : (flag.pointee == 1 ? .cancelled : .failed)
            rec.stage2.error = message
            try? rec.save()
            notifyUpdated()
            DiagnosticsLog.shared.log("stage2", "\(rec.baseName): \(message)")
            update(jobID: jobID, progress: 1, phase: "Stage 2 failed", error: message, finished: true)
            // Drop the partial output; an MKV from an earlier successful run stays untouched.
            try? FileManager.default.removeItem(atPath: partPath)
        }
    }

    private func runVerification(recording input: Recording, jobID: String?, deleteIntermediateOnPass: Bool) {
        var rec = reload(input)
        let job = Job(baseName: rec.baseName, kind: .verify)
        if jobID == nil || jobID != job.id { appendJob(job) }
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
        let hashPath = rec.hashListURL.path
        let (rc, expired): (Int32, Bool) = withBackgroundTask("verify", baseName: rec.baseName) {
            lc_verify_recording(mkv.path, hashPath, 0, progressCallback, Unmanaged.passUnretained(box).toOpaque(), flag, &result, &err, 512)
        }
        rec = reload(rec)
        if expired && (rc != 0 || result.status == Int32(LC_VERIFY_CANCELLED.rawValue)) {
            rec.verification = Recording.VerificationState()
            rec.verification.message = "Verification was interrupted because the app was in the background; run it again."
            try? rec.save()
            notifyUpdated()
            update(jobID: job.id, progress: 1, phase: "Verification interrupted (app in background)", error: "interrupted", finished: true)
            return
        }
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
        if let lci = rec.intermediateURL, FileManager.default.fileExists(atPath: lci.path) {
            if v.status == .pass && deleteIntermediateOnPass {
                try? FileManager.default.removeItem(at: lci)
                rec.files.intermediate = nil
            } else if v.status != .pass {
                let keep = "Intermediate kept because verification did not pass; use 'Run stage 2 again' to rebuild the MKV."
                if !(rec.stage2.error ?? "").contains(keep) {
                    rec.stage2.error = rec.stage2.error.map { $0 + " · " + keep } ?? keep
                }
            }
        }
        try? rec.save()
        notifyUpdated()
        let label: String
        switch v.status {
        case .pass: label = "Verification PASS (\(v.framesChecked) frames)"
        case .fail: label = "Verification FAIL at frame \(v.firstMismatchFrame)"
        case .cancelled: label = "Verification cancelled"
        default: label = "Verification error: \(msg)"
        }
        if v.status != .pass { DiagnosticsLog.shared.log("verify", "\(rec.baseName): \(label) \(msg)") }
        update(jobID: job.id, progress: 1, phase: label, error: v.status == .pass ? nil : msg, finished: true)
    }

    private func notifyUpdated() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Stage2Runner.recordingUpdated, object: nil) }
    }
}
