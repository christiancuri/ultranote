import Foundation

/// File names that follow a note's title: `<sanitized title>.md`, `<title> 2.md` on collision.
public enum NoteFileName {
    public static let fileExtension = "md"
    /// Marks the copy written on a save conflict: `<name> (conflict).md`.
    public static let conflictMarker = " (conflict)"
    static let maxBaseLength = 100

    /// The title as a safe file name base: no path separators, colons or control characters,
    /// no leading dots, collapsed whitespace, at most 100 characters. `Untitled` when empty.
    public static func base(for title: String) -> String {
        let replaced = title.unicodeScalars.map { scalar -> String in
            if "/\\:".unicodeScalars.contains(scalar) { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        var base = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(maxBaseLength)).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? NoteText.untitled : base
    }

    /// The base a note's file should have for `title`. A conflict copy keeps its marker, so
    /// renaming it after its title still says it is a conflict copy.
    public static func base(for title: String, currentFileName: String) -> String {
        let base = base(for: title)
        let stem = currentFileName.lowercased()
        return stem.contains(conflictMarker) ? base + conflictMarker : base
    }

    /// Whether `fileName` already follows `base`: `base.md` or `base <n>.md` (case-insensitive),
    /// so a note that got a suffix on collision is not renamed back and forth.
    public static func fileName(_ fileName: String, follows base: String) -> Bool {
        let name = fileName.lowercased()
        let lowered = base.lowercased()
        let suffix = "." + fileExtension
        guard name.hasSuffix(suffix) else { return false }
        let stem = String(name.dropLast(suffix.count))
        if stem == lowered { return true }
        guard stem.hasPrefix(lowered + " ") else { return false }
        let number = stem.dropFirst(lowered.count + 1)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && Int(number).map { $0 >= 2 } == true
    }

    /// `base.md`, or the first `base <n>.md` (n ≥ 2) not in `taken`. `taken` holds lowercased
    /// file names (the default volume is case-insensitive).
    public static func unique(base: String, taken: Set<String>) -> String {
        let first = "\(base).\(fileExtension)"
        if !taken.contains(first.lowercased()) { return first }
        var number = 2
        while taken.contains("\(base) \(number).\(fileExtension)".lowercased()) {
            number += 1
        }
        return "\(base) \(number).\(fileExtension)"
    }
}
