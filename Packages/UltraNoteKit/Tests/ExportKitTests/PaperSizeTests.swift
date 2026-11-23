import ExportKit
import Foundation
import Testing

@Suite("Paper size")
struct PaperSizeTests {
    @Test("US Letter where it is customary", arguments: ["US", "CA", "MX", "CO", "CL", "PH", "us"])
    func letterRegions(region: String) {
        #expect(PaperSize.forRegion(region) == .usLetter)
    }

    @Test("A4 everywhere else", arguments: ["BR", "PT", "DE", "GB", "JP", "AR", "001", ""])
    func a4Regions(region: String) {
        #expect(PaperSize.forRegion(region) == .a4)
    }

    @Test("A4 without a region")
    func noRegion() {
        #expect(PaperSize.forRegion(nil) == .a4)
    }

    @Test("follows the locale's region, not its language")
    func fromLocale() {
        #expect(PaperSize.default(for: Locale(identifier: "pt_BR")) == .a4)
        #expect(PaperSize.default(for: Locale(identifier: "en_US")) == .usLetter)
        #expect(PaperSize.default(for: Locale(identifier: "en_GB")) == .a4)
        #expect(PaperSize.default(for: Locale(identifier: "es_MX")) == .usLetter)
        #expect(PaperSize.default(for: Locale(identifier: "fr_CA")) == .usLetter)
    }

    @Test("sizes are in points")
    func sizes() {
        #expect(PaperSize.a4.width == 595.28 && PaperSize.a4.height == 841.89)
        #expect(PaperSize.usLetter.width == 612 && PaperSize.usLetter.height == 792)
    }

    @Test("export formats have file extensions")
    func fileExtensions() {
        #expect(ExportFormat.allCases.map(\.fileExtension) == ["pdf", "pdf", "png", "txt", "md"])
    }
}
