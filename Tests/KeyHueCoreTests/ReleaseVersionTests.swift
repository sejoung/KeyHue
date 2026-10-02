import Foundation
import Testing
@testable import KeyHueCore

@Suite("Release version and update schedule")
struct ReleaseVersionTests {
    @Test func comparesNumbersRatherThanText() throws {
        #expect(try #require(ReleaseVersion("0.9.9")) < #require(ReleaseVersion("v0.10.0")))
        #expect(try #require(ReleaseVersion("1.0.0")) > #require(ReleaseVersion("0.99.99")))
        #expect(ReleaseVersion("v1.2.3") == ReleaseVersion("1.2.3"))
    }

    @Test(arguments: ["", "1.0", "1.2.3.4", "1.2.3-beta.1", "1.2.3+build", "01.2.3", "-1.2.3", "1..3", "１.2.3", " 1.2.3", "999999999999999999999999999.0.0"])
    func rejectsUnsupportedVersions(_ text: String) { #expect(ReleaseVersion(text) == nil) }

    @Test func checkIsDueOnlyAfterADayAndHandlesClockChanges() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(UpdateCheckPolicy.delay(lastAttempt: nil, now: now) == 0)
        #expect(UpdateCheckPolicy.delay(lastAttempt: now, now: now) == 86_400)
        #expect(UpdateCheckPolicy.delay(lastAttempt: now.addingTimeInterval(-86_399), now: now) == 1)
        #expect(UpdateCheckPolicy.delay(lastAttempt: now.addingTimeInterval(-86_400), now: now) == 0)
        #expect(UpdateCheckPolicy.delay(lastAttempt: now.addingTimeInterval(100), now: now) == 0)
    }
}
