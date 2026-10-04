import Foundation
import CoreVideo
import CoreMedia
import os

/// A frame queued for the storage pipeline. The pixel buffer is either the
/// camera's own buffer (retained from its pool) or a private copy.
final class FrameSlot {
    let pixelBuffer: CVPixelBuffer
    let ptsNs: Int64
    let outputIndex: Int64        // index of this frame in the written stream (assigned when accepted)
    let isCameraOwned: Bool
    init(pixelBuffer: CVPixelBuffer, ptsNs: Int64, outputIndex: Int64, isCameraOwned: Bool) {
        self.pixelBuffer = pixelBuffer
        self.ptsNs = ptsNs
        self.outputIndex = outputIndex
        self.isCameraOwned = isCameraOwned
    }
}

/// Bounded FIFO of frames with a dynamically adjustable capacity.
///
/// Camera buffers are retained directly while few are outstanding (cheap);
/// once `maxCameraOwned` camera buffers are in flight further frames are
/// copied into buffers from a private pool so the capture pool never starves.
/// When the queue is full the frame is rejected and the caller counts a drop:
/// nothing is ever dropped silently.
final class FrameRingBuffer {
    private var slots: [FrameSlot] = []
    private var head = 0
    private let lock = NSCondition()
    private var closed = false
    private(set) var capacity: Int
    private var cameraOwnedInFlight = 0
    private let maxCameraOwned: Int
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0, poolHeight = 0
    private var poolFormat: OSType = 0
    private(set) var copies: Int64 = 0
    private(set) var peakCount = 0

    init(capacity: Int, maxCameraOwned: Int = 2) {
        self.capacity = max(2, capacity)
        self.maxCameraOwned = maxCameraOwned
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count - head
    }

    func setCapacity(_ newCapacity: Int) {
        lock.lock(); capacity = max(2, newCapacity); lock.unlock()
    }

    /// Returns false (drop) when the buffer is full.
    func push(pixelBuffer: CVPixelBuffer, ptsNs: Int64, outputIndex: Int64) -> Bool {
        lock.lock()
        if closed || slots.count - head >= capacity {
            lock.unlock()
            return false
        }
        let needCopy = cameraOwnedInFlight >= maxCameraOwned
        lock.unlock()

        var slot: FrameSlot
        if needCopy {
            guard let copy = copyFrame(pixelBuffer) else { return false }
            slot = FrameSlot(pixelBuffer: copy, ptsNs: ptsNs, outputIndex: outputIndex, isCameraOwned: false)
        } else {
            slot = FrameSlot(pixelBuffer: pixelBuffer, ptsNs: ptsNs, outputIndex: outputIndex, isCameraOwned: true)
        }

        lock.lock()
        if closed || slots.count - head >= capacity {
            lock.unlock()
            return false
        }
        if slot.isCameraOwned { cameraOwnedInFlight += 1 } else { copies += 1 }
        slots.append(slot)
        peakCount = max(peakCount, slots.count - head)
        lock.signal()
        lock.unlock()
        return true
    }

    /// Blocks until a frame is available or the buffer is closed and drained.
    func pop() -> FrameSlot? {
        lock.lock()
        while slots.count - head == 0 && !closed {
            lock.wait()
        }
        if slots.count - head == 0 {
            lock.unlock()
            return nil
        }
        let slot = slots[head]
        head += 1
        if head > 1024 && head * 2 > slots.count {
            slots.removeFirst(head)
            head = 0
        }
        lock.unlock()
        return slot
    }

    /// Must be called by the consumer when it has finished with a slot.
    func release(_ slot: FrameSlot) {
        if slot.isCameraOwned {
            lock.lock(); cameraOwnedInFlight -= 1; lock.unlock()
        }
    }

    func close() {
        lock.lock(); closed = true; lock.broadcast(); lock.unlock()
    }

    private func copyFrame(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        if pool == nil || poolWidth != w || poolHeight != h || poolFormat != fmt {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: fmt,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolWidth = w; poolHeight = h; poolFormat = fmt
        }
        guard let pool = pool else { return nil }
        var dstOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOpt) == kCVReturnSuccess, let dst = dstOpt else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        let planes = CVPixelBufferGetPlaneCount(src)
        for p in 0..<planes {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p), let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { continue }
            let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, p)
            let dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let rows = CVPixelBufferGetHeightOfPlane(src, p)
            let rowBytes = min(sStride, dStride)
            if sStride == dStride {
                memcpy(d, s, sStride * rows)
            } else {
                for r in 0..<rows { memcpy(d + r * dStride, s + r * sStride, rowBytes) }
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
        // Carry colour attachments over so the copy is indistinguishable downstream.
        if let attachments = CVBufferCopyAttachments(src, .shouldPropagate) {
            CVBufferSetAttachments(dst, attachments, .shouldPropagate)
        }
        return dst
    }
}

/// Memory available to this process, as reported by the kernel.
func availableMemoryBytes() -> Int64 {
    return Int64(os_proc_available_memory())
}
