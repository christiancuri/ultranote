import Foundation

/// Runs `operation` on the main actor and throws `timeoutError` if it has not finished
/// within `limit`.
///
/// Built on a continuation rather than a task group: the operations it guards (WebKit
/// calls) do not react to cancellation, and a task group would wait for them anyway. An
/// operation that outlives its timeout keeps running; its late result is dropped.
@MainActor
func withTimeout<T: Sendable>(
    _ limit: Duration,
    timeoutError: any Error,
    operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    let gate = ResumeGate()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: limit) } catch { return }
            if gate.claim() { continuation.resume(throwing: timeoutError) }
        }
        Task { @MainActor in
            let result: Result<T, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            timer.cancel()
            if gate.claim() { continuation.resume(with: result) }
        }
    }
}

/// Lets exactly one of two racing main-actor tasks resume a continuation.
@MainActor
private final class ResumeGate {
    private var isClaimed = false

    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
