import CoreGraphics
import Foundation

struct AutoCapture {
    private var alignedSince: TimeInterval?
    private var lastSubject: CGRect?
    private var fired = false
    private var blockedUntil: TimeInterval = 0

    mutating func update(
        aligned: Bool,
        subject: CGRect?,
        faceReady: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard timestamp >= blockedUntil, aligned, faceReady, let subject else {
            reset()
            return false
        }

        if let lastSubject,
           hypot(subject.midX - lastSubject.midX, subject.midY - lastSubject.midY) > 0.018
        {
            alignedSince = timestamp
            fired = false
        }
        self.lastSubject = subject
        alignedSince = alignedSince ?? timestamp

        guard !fired, timestamp - (alignedSince ?? timestamp) >= 1.2 else { return false }
        fired = true
        return true
    }

    mutating func cancel(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        blockedUntil = now + 3
        reset()
    }

    private mutating func reset() {
        alignedSince = nil
        lastSubject = nil
        fired = false
    }
}
