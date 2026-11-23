import CoreServices
import Foundation
import os

/// Watches a folder with FSEvents (file-level events) and yields once per batch of changes.
/// Events are coalesced: consumers re-read the folder rather than act on each path.
public final class FolderWatcher: Sendable {
    public let folder: URL
    /// One element per batch of changes. Finishes when the watcher stops.
    public let changes: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "dev.christiancuri.ultranote.folder-watcher")
    private let stream = OSAllocatedUnfairLock<FSEventStreamRef?>(uncheckedState: nil)

    public init(folder: URL, latency: TimeInterval = 0.15) {
        self.folder = folder
        self.latency = latency
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        stop()
    }

    /// Starts watching. Returns false when the stream could not be created.
    @discardableResult
    public func start() -> Bool {
        stream.withLockUnchecked { stream in
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().continuation.yield()
            }
            let path = folder.resolvingSymlinksInPath().path(percentEncoded: false)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(
                nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    /// Stops watching and finishes ``changes``.
    public func stop() {
        stream.withLockUnchecked { stream in
            if let current = stream {
                FSEventStreamStop(current)
                FSEventStreamInvalidate(current)
                FSEventStreamRelease(current)
                stream = nil
            }
        }
        // Drain a callback already queued, so none runs after this object is gone.
        queue.sync {}
        continuation.finish()
    }
}
