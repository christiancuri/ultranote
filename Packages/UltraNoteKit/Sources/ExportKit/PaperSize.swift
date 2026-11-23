import Foundation

/// A paper size in points (1/72 inch), portrait.
public struct PaperSize: Equatable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    public init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    public static let a4 = PaperSize(name: "A4", width: 595.28, height: 841.89)
    public static let usLetter = PaperSize(name: "Letter", width: 612, height: 792)

    /// The locale's customary paper: US Letter in the regions listed by CLDR, A4 elsewhere.
    public static func `default`(for locale: Locale = .current) -> PaperSize {
        forRegion(locale.region?.identifier)
    }

    public static func forRegion(_ regionCode: String?) -> PaperSize {
        guard let regionCode, letterRegions.contains(regionCode.uppercased()) else { return .a4 }
        return .usLetter
    }

    /// CLDR supplemental data, `measurementData/paperSize[@type="US-Letter"]`.
    private static let letterRegions: Set<String> = [
        "BZ", "CA", "CL", "CO", "CR", "GT", "MX", "NI", "PA", "PH", "PR", "SV", "US", "VE",
    ]
}
