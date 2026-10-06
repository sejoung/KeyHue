import AppKit
import KeyHueCore

/// 문제를 볼 때 "그때 어떤 버전·설정·권한이었나"를 알 수 있게 실행 시점의 상태를 남긴다(ADR 0036).
@MainActor
enum LaunchDiagnostics {
    static func log(settings: KeyHueSettings, ignoredKeys: [String], frontBundleID: String?, sourceID: String?,
                    inputMethod: InputMethodInstallationStatus) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.app.notice("launch KeyHue \(version) (\(build)) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(osBuild))")
        let changed = settings.nonDefaultDescriptions
        Log.app.notice("settings: \(changed.isEmpty ? "all default" : changed.joined(separator: ", "))")
        if !ignoredKeys.isEmpty {
            // 형식이 깨진 값은 기본값으로 읽고 지웠다(ADR 0043). 키 이름만 남긴다.
            Log.app.error("settings: ignored corrupt values for \(ignoredKeys.joined(separator: ", "))")
        }
        // Only asked when a feature uses it: on macOS 26 the check itself lists KeyHue
        // as denied for Accessibility, which then refuses Input Monitoring silently (ADR 0075).
        let accessibility = settings.usesAccessibility ? String(AccessibilityFocusMonitor.isTrusted) : "unused"
        Log.app.notice(
            "permissions: inputMonitoring=\(KeyboardMonitor.hasPermission) accessibility=\(accessibility)"
                + " macOSIndicatorHidden=\(SystemInputIndicator().isHidden)"
        )
        // 실행 직후에는 KeyHue 자신이 맨 앞인 경우가 많다(Dock 표시). 그때는 다음 앱 활성화부터 관찰한다.
        let front = frontBundleID ?? "KeyHue itself (observing starts at the next app activation)"
        Log.app.notice("front app: \(front) source: \(sourceID ?? "-")")
        if inputMethod.isInstalled || inputMethod.hasRegisteredSources {
            let snapshot = InputSourceController.freshSnapshot()
            Log.app.notice("input method launch state installed=\(inputMethod.isInstalled) needsUpdate=\(inputMethod.needsUpdate) \(snapshot?.logDescription ?? "diagnostic unavailable")")
        }
    }

    /// macOS 빌드 번호(예: 25G83). 현지화되지 않은 값.
    private static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
