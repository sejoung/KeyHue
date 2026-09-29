import AppKit
import Carbon

// Tests/perf/input-latency.sh가 쓰는 도구(ADR 0023).
// ABC ↔ 2-Set Korean을 N번 토글하며 (1) 전환 호출 시각 (2) 기준 수신기(deliverImmediately)가 알림을 받은 시각을 출력한다.
// 출력: "HH:mm:ss.SSS ABC|KO  ref=<ms>ms". 짝수 번 토글하면 ABC로 끝난다.
let n = Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
func source(_ id: String) -> TISInputSource {
    (TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource])[0]
}
let ids = ["com.apple.inputmethod.Korean.2SetKorean", "com.apple.keylayout.ABC"]
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
var received: [Date] = []
class Obs: NSObject { @objc func note(_ n: Notification) { received.append(Date()) } }
let obs = Obs()
DistributedNotificationCenter.default().addObserver(obs, selector: #selector(Obs.note(_:)),
    name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, suspensionBehavior: .deliverImmediately)
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
for i in 0..<n {
    let before = received.count
    let t0 = Date()
    TISSelectInputSource(source(ids[i % 2]))
    while received.count == before && Date().timeIntervalSince(t0) < 2 { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    let t1 = received.count > before ? received[before] : Date.distantFuture
    print("\(fmt.string(from: t0)) \(ids[i % 2].hasSuffix("ABC") ? "ABC" : "KO ") ref=\(Int(t1.timeIntervalSince(t0) * 1000))ms")
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
}
