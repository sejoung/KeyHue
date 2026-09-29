// 앱 전환 직후 입력 소스 전환의 경쟁 상태와 지연을 잰다(ADR 0007, 0031). Tests/perf/app-switch-latency.sh가 사용한다.
//
//   app-switch window                      측정용 앱(창 하나). KeyHuePerfA/B.app 번들로 실행되면 자동으로 이 모드다.
//   app-switch race <A.app> <B.app> <회수> <지연ms...>
//       KeyHue 없이 직접 재현: 한국어 상태에서 다른 측정용 앱을 활성화하고, 활성화 알림 뒤 <지연ms>에 ABC로 바꾼다.
//       0.6초 동안 입력 소스 알림을 모아, 시스템이 되돌렸는지(덮어씀)와 마지막 상태를 센다.
//   app-switch e2e <A.app> <B.app> <회수>
//       실행 중인 KeyHue("앱을 바꿀 때 › ABC로 전환")가 전환하는 데 걸린 시간과 깜빡임을 잰다.
import AppKit
import Carbon

let korean = "com.apple.inputmethod.Korean.2SetKorean"
let abc = "com.apple.keylayout.ABC"

func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
func source(_ id: String) -> TISInputSource {
    (TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource])[0]
}
func currentID() -> String {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(current, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}
func spin(_ ms: Double) { RunLoop.current.run(until: Date().addingTimeInterval(ms / 1000)) }

final class Recorder: NSObject {
    var activations: [(at: Double, bundleID: String)] = []
    var changes: [(at: Double, id: String)] = []
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    @objc func sourceChanged() { changes.append((now(), currentID())) }
    @objc func activated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        activations.append((now(), app?.bundleIdentifier ?? "-"))
    }
}

let arguments = CommandLine.arguments
// KeyHuePerfA/B.app 번들로 실행되면 인자 없이도 측정용 앱(창)으로 동작한다.
let isPerfApp = Bundle.main.bundleIdentifier?.hasPrefix("io.github.sejoung.keyhue.perf.") == true
if isPerfApp || arguments.dropFirst().first == "window" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = Bundle.main.bundleIdentifier ?? "KeyHuePerf"
    window.makeKeyAndOrderFront(nil)
    app.run()
}

guard arguments.count >= 5 else { exit(64) }
let apps = [URL(fileURLWithPath: arguments[2]), URL(fileURLWithPath: arguments[3])]
let trials = Int(arguments[4]) ?? 8
let recorder = Recorder()
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)

func activate(_ url: URL) -> String {
    let bundleID = Bundle(url: url)?.bundleIdentifier ?? "-"
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    return bundleID
}

/// 활성화 알림을 기다려 그 시각을 돌려준다.
func waitForActivation(of bundleID: String, since start: Double) -> Double? {
    let deadline = now() + 3000
    while now() < deadline {
        if let hit = recorder.activations.last(where: { $0.bundleID == bundleID && $0.at >= start }) { return hit.at }
        spin(1)
    }
    return nil
}

/// 준비: 앞 앱을 정하고 한국어로 둔다.
func prepare(front: URL) {
    let bundleID = activate(front)
    _ = waitForActivation(of: bundleID, since: now() - 5000)
    spin(400)
    TISSelectInputSource(source(korean))
    spin(400)
}

// 두 앱을 띄워 둔다.
for url in apps { _ = activate(url); spin(1200) }

switch arguments[1] {
case "race":
    let delays = arguments.dropFirst(5).compactMap(Double.init)
    print("delay_ms  trials  overridden  ended_korean  override_after_activation_ms")
    for delay in delays {
        var overridden = 0, endedKorean = 0
        var overrideTimes: [Double] = []
        for trial in 0..<trials {
            let target = apps[trial % 2], other = apps[(trial + 1) % 2]
            prepare(front: other)
            let start = now()
            let bundleID = activate(target)
            guard let activatedAt = waitForActivation(of: bundleID, since: start) else { print("activation timeout"); continue }
            let fireAt = activatedAt + delay
            while now() < fireAt { spin(0.5) }
            let selectedAt = now()
            TISSelectInputSource(source(abc))
            spin(600)
            // ABC로 바꾼 뒤 한국어로 되돌아간 알림 = 시스템이 덮어씀
            if let back = recorder.changes.first(where: { $0.at > selectedAt && $0.id == korean }) {
                overridden += 1
                overrideTimes.append(back.at - activatedAt)
            }
            if currentID() == korean { endedKorean += 1 }
        }
        let times = overrideTimes.map { String(format: "%.0f", $0) }.joined(separator: ",")
        print(String(format: "%8.0f  %6d  %10d  %12d  %@", delay, trials, overridden, endedKorean, times.isEmpty ? "-" : times))
    }
case "e2e":
    var latencies: [Double] = []
    var flickers = 0, failures = 0
    for trial in 0..<trials {
        let target = apps[trial % 2], other = apps[(trial + 1) % 2]
        prepare(front: other)
        let start = now()
        let bundleID = activate(target)
        guard let activatedAt = waitForActivation(of: bundleID, since: start) else { print("activation timeout"); continue }
        spin(900)
        let after = recorder.changes.filter { $0.at >= activatedAt }
        guard let firstABC = after.first(where: { $0.id == abc }), currentID() == abc else {
            failures += 1
            let trace = after.map { String(format: "%+.0fms %@", $0.at - activatedAt, $0.id == abc ? "ABC" : $0.id == korean ? "KO" : $0.id) }
            print("FAIL trial \(trial): now=\(currentID() == abc ? "ABC" : currentID()) changes=[\(trace.joined(separator: ", "))]")
            continue
        }
        // 마지막으로 ABC가 된 시각까지를 지연으로 본다(덮어써져 재시도한 경우 포함)
        let lastABC = after.last(where: { $0.id == abc })!.at
        if after.contains(where: { $0.id == korean && $0.at > firstABC.at }) { flickers += 1 }
        latencies.append(lastABC - activatedAt)
    }
    latencies.sort()
    func pct(_ p: Double) -> Double { latencies.isEmpty ? .nan : latencies[min(latencies.count - 1, Int(Double(latencies.count) * p))] }
    print(String(format: "trials=%d ok=%d failures=%d flickers=%d  median=%.0fms p90=%.0fms max=%.0fms",
                 trials, latencies.count, failures, flickers, pct(0.5), pct(0.9), latencies.last ?? .nan))
    print("all_ms=" + latencies.map { String(format: "%.0f", $0) }.joined(separator: ","))
default:
    exit(64)
}
for url in apps {
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: url)?.bundleIdentifier ?? "").forEach { $0.terminate() }
}
