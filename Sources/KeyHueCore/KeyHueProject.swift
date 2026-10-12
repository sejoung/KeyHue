import Foundation

/// Where KeyHue lives: its identity, the public repository and this Mac's versions.
/// One place for the names the app, the input method and their logs use.
public enum KeyHueProject {
    /// The utility's bundle ID, also its preferences domain.
    public static let appBundleID = "io.github.sejoung.keyhue"
    /// `owner/name` on GitHub.
    public static let repository = "sejoung/KeyHue"
    public static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    /// The website with the download page and the manual.
    public static let siteURL = URL(string: "https://sejoung.github.io/KeyHue/")!
    public static let newIssueURL = URL(string: "https://github.com/\(repository)/issues/new")!
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    public static func releaseURL(version: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")
    }

    /// `CFBundleShortVersionString` of a bundle; nil for an unbundled build.
    public static func version(of bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `26.0.1`.
    public static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
