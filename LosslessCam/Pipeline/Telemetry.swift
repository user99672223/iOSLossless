import Foundation

/// Live recording telemetry published to the UI a few times per second.
struct Telemetry: Equatable {
    var isRecording = false
    var elapsedSeconds: Double = 0
    var framesIngested: Int64 = 0
    var framesWritten: Int64 = 0
    var droppedFrames: Int64 = 0          // rejected by the ring buffer (pipeline too slow)
    var sourceDroppedFrames: Int64 = 0    // dropped by AVFoundation before delivery
    var achievedFps: Double = 0           // frames written per second (recent window)
    var ingestFps: Double = 0             // frames delivered per second (recent window)
    var bufferFill: Double = 0            // 0...1
    var bufferCount: Int = 0
    var bufferCapacity: Int = 0
    var writeMBps: Double = 0
    var bytesWritten: Int64 = 0
    var rawBytes: Int64 = 0
    var compressionRatio: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var freeStorageBytes: Int64 = 0
    var estimatedRemainingSeconds: Double = 0
    var memoryWarnings: Int = 0
    var availableMemoryBytes: Int64 = 0
    var audioBuffers: Int64 = 0
    var audioFrames: Int64 = 0
    var audioFormat: String = ""
    var audioInexactSamples: Int64 = 0
    var workerCount: Int = 0
    var stage1Codec: String = ""
    var notes: [String] = []

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

/// Sliding-window rate estimator (events per second over the last `window` seconds).
struct RateMeter {
    private var samples: [(time: Double, value: Double)] = []
    let window: Double
    init(window: Double = 2.0) { self.window = window }

    mutating func add(_ value: Double, at time: Double) {
        samples.append((time, value))
        let cutoff = time - window
        while let first = samples.first, first.time < cutoff { samples.removeFirst() }
    }

    func rate(at time: Double) -> Double {
        guard let first = samples.first else { return 0 }
        let span = max(time - first.time, 0.25)
        let total = samples.reduce(0.0) { $0 + $1.value }
        return total / span
    }

    mutating func reset() { samples.removeAll() }
}

func freeStorageBytes() -> Int64 {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let cap = values.volumeAvailableCapacityForImportantUsage {
        return cap
    }
    return 0
}
