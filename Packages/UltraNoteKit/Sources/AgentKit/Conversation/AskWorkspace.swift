import Foundation

/// The dedicated working directory of the CLI children. It stays empty, so a model confined to
/// its cwd can read nothing.
public struct AskWorkspace: Sendable, Equatable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/UltraNote/AIWorkspace/`.
    public static var standard: AskWorkspace {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return AskWorkspace(directory: support.appending(path: "UltraNote/AIWorkspace", directoryHint: .isDirectory))
    }

    /// Creates the directory if needed.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
