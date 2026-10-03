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

    // MARK: 엣지 케이스

    @Test(arguments: ["v", "vv1.2.3", "v-1.2.3", "v 1.2.3", "1.2.3.", ".1.2.3", ".1.2", "1.2.3 ", "1.2.3\n", "1.2.+3",
                      "1.2.0x3", "1.02.3", "1.2.03", "a.b.c", "9223372036854775808.0.0", "1.2.3v", "v1.2"])
    func rejectsMoreMalformedTags(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func acceptsZerosAndLargeComponents() {
        #expect(ReleaseVersion("0.0.0")?.string == "0.0.0")
        #expect(ReleaseVersion("v0.0.1")?.string == "0.0.1") // 앞의 v는 떼고 기억한다
        #expect(ReleaseVersion("1.0.10")?.string == "1.0.10")
        #expect(ReleaseVersion("9223372036854775807.0.0") != nil)
    }

    @Test func ordersByMajorThenMinorThenPatch() throws {
        let tags = ["1.10.0", "0.9.9", "v1.2.10", "1.2.9", "2.0.0", "0.10.0", "1.2.10", "0.0.1"]
        let versions = try tags.map { try #require(ReleaseVersion($0)) }
        #expect(versions.sorted().map(\.string) == ["0.0.1", "0.9.9", "0.10.0", "1.2.9", "1.2.10", "1.2.10", "1.10.0", "2.0.0"])
    }

    @Test func equalVersionsAreNotNewer() throws {
        let installed = try #require(ReleaseVersion("1.2.3"))
        let latest = try #require(ReleaseVersion("v1.2.3"))
        #expect(!(installed < latest))
        #expect(!(latest < installed))
        #expect(installed == latest)
        #expect(try #require(ReleaseVersion("1.2.3")) < #require(ReleaseVersion("1.2.4")))
        #expect(try #require(ReleaseVersion("1.2.3")) < #require(ReleaseVersion("1.3.0")))
        #expect(try #require(ReleaseVersion("1.99.99")) < #require(ReleaseVersion("2.0.0")))
    }
}
