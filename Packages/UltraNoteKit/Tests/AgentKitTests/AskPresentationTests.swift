@testable import AgentKit
import Testing

@Suite("Ask error and model presentation")
struct AskPresentationTests {
    @Test func errorCodesMatchTheCaseNames() {
        let all: [AskError] = [
            .notInstalled, .notLoggedIn, .usageLimit(resetsAt: nil), .modelUnavailable, .timedOut,
            .processExited, .emptyAnswer, .busy, .other("x"),
        ]
        #expect(all.map(\.code) == [
            "notInstalled", "notLoggedIn", "usageLimit", "modelUnavailable", "timedOut",
            "processExited", "emptyAnswer", "busy", "other",
        ])
        #expect(all.map(\.code) == all.map(\.logLabel))
        #expect(all.filter(\.canOpenSettings) == [.notInstalled, .notLoggedIn, .modelUnavailable])
    }

    @Test func effortKeepingFallsBack() {
        let model = AskModel(id: "m", displayName: "M", efforts: [.low, .medium, .high], defaultEffort: .medium)
        #expect(model.effort(keeping: .high) == .high)
        #expect(model.effort(keeping: .max) == .medium, "unsupported → the model default")
        #expect(model.effort(keeping: nil) == .medium)
        let noDefault = AskModel(id: "m", displayName: "M", efforts: [.low, .high], defaultEffort: .max)
        #expect(noDefault.effort(keeping: .xhigh) == .low, "default not offered → lowest")
        #expect(AskModel(id: "m", displayName: "M").effort(keeping: .high) == nil)
    }
}
