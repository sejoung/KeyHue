import AppKit
import ApplicationServices
import KeyHueCore

/// 활성 앱의 포커스 변화를 Accessibility API로 관찰한다(옵션을 켰을 때만, 손쉬운 사용 권한 필요).
///
/// - 텍스트 필드 이탈(실험적, ADR 0009): focused UI element의 role/subrole/편집 가능 여부만 읽는다.
/// - 창 전환(ADR 0027), 창별 기억(ADR 0028): **메인 창**이 다른 창으로 바뀌었는지만 본다. 창 제목·내용은 읽지 않는다.
/// 값(텍스트 내용)은 절대 읽지 않는다.
///
/// 성능: AX 조회는 대상 앱과의 동기 IPC라, 대상 앱이 멈춰 있으면 메인 스레드가 막힌다.
/// - 응답 대기 시간을 `messagingTimeout`으로 줄여, 멈춘 앱 때문에 KeyHue가 멈추지 않게 한다.
/// - 켜진 옵션에 필요한 알림만 구독하고, 필요한 속성만 조회한다(`AccessibilityUse`).
///
/// 막 실행된 앱은 활성화 알림 시점에 아직 AX 요청에 답하지 못한다. 그때는 붙지 않은 것으로 두고 잠시 뒤 다시 붙는다(ADR 0033).
@MainActor
final class AccessibilityFocusMonitor {
    /// AX 요청 응답 대기 시간(초). 기본값(실측: 멈춘 앱에 요청 한 번당 약 1.5초, 붙을 때는 여러 번 이어진다) 대신
    /// 짧게 두고, 늦으면 그 판단은 건너뛴다. 실측: 0.25초로 두면 0.27초에 끊긴다.
    static let messagingTimeout: Float = 0.25

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var use = AccessibilityUse(textFocus: false, windowSwitches: false)
    private var subscribed: [String] = []
    private var unsupportedTarget: AttachTarget?
    private var wasTextInput = false
    private var windows = WindowSwitchTracker<AXWindowID>()
    private let retrier: AttachRetrier<AttachTarget>

    struct AttachTarget: Equatable {
        let pid: pid_t
        let use: AccessibilityUse
    }

    /// (wasTextInput, isTextInput)
    var onFocusChanged: ((Bool, Bool) -> Void)?
    /// 같은 앱 안에서 다른 창(탭)으로 옮겼다. (떠난 창, 옮겨 간 창)
    var onWindowSwitched: ((AXWindowID?, AXWindowID) -> Void)?

    /// 붙기를 끝내 포기한 앱. 사용자에게 "이 앱의 창 전환을 감지하지 못한다"고 알리는 데 쓴다(ADR 0038).
    private(set) var stalledPID: pid_t?

    /// 활성 앱의 지금 메인 창. 붙어 있지 않으면 nil.
    var currentWindow: AXWindowID? { windows.currentWindow }

    /// 켜진 옵션에 필요한 알림만. 탭 전환은 "포커스 창 변경"이 오지 않고 "메인 창 변경"만 온다(ADR 0027).
    static func notifications(for use: AccessibilityUse) -> [String] {
        var names: [String] = []
        if use.textFocus { names.append(kAXFocusedUIElementChangedNotification) }
        if use.windowSwitches { names.append(kAXMainWindowChangedNotification) }
        return names
    }

    /// 붙을 때 한 번 읽는 앱 속성. 알림을 받기 전의 기준값이다.
    static func initialAttributes(for use: AccessibilityUse) -> [String] {
        var names: [String] = []
        if use.textFocus { names.append(kAXFocusedUIElementAttribute) }
        if use.windowSwitches { names.append(kAXMainWindowAttribute) }
        return names
    }

    enum NotificationRegistrationDisposition: Equatable {
        case added
        case retry
        case unsupported
        case failed
    }

    static func registrationDisposition(for error: AXError) -> NotificationRegistrationDisposition {
        switch error {
        case .success: return .added
        case .cannotComplete: return .retry
        case .notificationUnsupported: return .unsupported
        default: return .failed
        }
    }

    /// 이 프로세스의 모든 AX 요청에 응답 대기 시간을 건다(시스템 전체 요소에 설정하면 전역 기본값이 된다).
    @discardableResult
    static func applyMessagingTimeout() -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// The timeout is set on first use, not here: AX use (even the trust check) before
    /// Accessibility is granted makes macOS list KeyHue as denied, and on macOS 26 that
    /// record then refuses the Input Monitoring request without asking (ADR 0075).
    init(scheduler: Scheduling = MainQueueScheduler()) {
        retrier = AttachRetrier(scheduler: scheduler)
    }

    private var appliedMessagingTimeout = false

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 시스템 Accessibility 권한 안내 대화상자를 띄운다.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    var isAttached: Bool { observer != nil }

    /// 활성 앱에 붙는다. 같은 앱·같은 용도로 이미 붙어 있거나 다시 붙으려고 기다리는 중이면 아무것도 하지 않는다.
    func attach(to pid: pid_t, for use: AccessibilityUse) {
        // The trust check only for a feature that uses it (ADR 0075).
        guard !use.isEmpty, Self.isTrusted else {
            detach()
            return
        }
        if !appliedMessagingTimeout {
            appliedMessagingTimeout = Self.applyMessagingTimeout() == .success
        }
        let target = AttachTarget(pid: pid, use: use)
        if let unsupportedTarget {
            guard unsupportedTarget != target else { return }
            self.unsupportedTarget = nil
            if stalledPID == unsupportedTarget.pid { stalledPID = nil }
        }
        guard Self.needsAttach(
            to: target,
            attached: observer == nil ? nil : AttachTarget(pid: self.pid, use: self.use),
            pending: retrier.pendingTarget,
            stalledPID: stalledPID
        ) else { return }
        detach()
        retrier.start(target, attempt: { [weak self] target in
            self?.subscribe(to: target.pid, for: target.use) ?? true
        }, onGiveUp: { [weak self] target in
            self?.stalledPID = target.pid
            Log.accessibility.error("gave up attaching to pid \(target.pid): AX notification registration failed")
        })
    }

    /// 새로 붙어야 하는가.
    /// - 같은 앱·같은 용도로 이미 붙어 있거나, 붙으려고 다시 시도하는 중이면 아니다.
    /// - 이 앱에 붙기를 포기했으면 아니다. 메뉴·설정 창을 열 때마다 다시 시도하면 "응답 없는 앱" 안내가 지워지고
    ///   (ADR 0038), 멈춘 앱에 몇 초씩 다시 매달린다. 다른 앱에 갔다 오면 그때 다시 시도한다.
    static func needsAttach(to target: AttachTarget, attached: AttachTarget?, pending: AttachTarget?, stalledPID: pid_t?) -> Bool {
        if attached == target || pending == target { return false }
        if stalledPID == target.pid, attached == nil, pending == nil { return false }
        return true
    }

    /// 등록 결과를 모아 붙을지 정한다.
    /// - 앱이 아직 답하지 못한 알림이 있으면(실행 중) 전부 되돌리고 다시 시도한다.
    /// - 그 밖의 실패는 그 알림만 빼고, 등록된 알림으로 붙는다.
    /// - 하나도 등록하지 못했으면: 지원하지 않는 알림뿐이면 그만두고, 아니면 다시 시도한다.
    static func registrationOutcome(_ dispositions: [NotificationRegistrationDisposition]) -> RegistrationOutcome {
        if dispositions.contains(.retry) { return .retry }
        if dispositions.contains(.added) || dispositions.isEmpty { return .attach }
        if dispositions.contains(.failed) { return .retry }
        return .unsupported
    }

    enum RegistrationOutcome: Equatable {
        case attach
        case retry
        case unsupported
    }

    /// 알림을 등록하고 기준값을 읽는다. 앱이 아직 답하지 못하면(실행 중) 등록을 되돌리고 false.
    private func subscribe(to pid: pid_t, for use: AccessibilityUse) -> Bool {
        var created: AXObserver?
        guard AXObserverCreate(pid, accessibilityFocusCallback, &created) == .success, let created else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var names: [String] = []
        var dispositions: [NotificationRegistrationDisposition] = []
        for name in Self.notifications(for: use) {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            let disposition = Self.registrationDisposition(for: result)
            dispositions.append(disposition)
            switch disposition {
            case .added:
                names.append(name)
            case .retry:
                // 실측: 활성화 알림 직후(실행 중)에는 -25204, 100 ms 뒤에는 성공한다.
                Log.accessibility.notice("pid \(pid) not ready for AX notification \(name); will retry (error \(result.rawValue))")
            case .unsupported:
                Log.accessibility.error("pid \(pid) does not support AX notification \(name) (error \(result.rawValue)); skipping it")
            case .failed:
                Log.accessibility.error("AX notification registration failed for pid \(pid), notification \(name), error \(result.rawValue); skipping it")
            }
            if disposition == .retry { break }
        }
        let outcome = Self.registrationOutcome(dispositions)
        if outcome == .retry {
            for added in names {
                AXObserverRemoveNotification(created, app, added as CFString)
            }
            return false
        }
        // 창 전환 알림을 받지 못하면 메뉴에 "이 앱의 창 전환을 감지하지 못한다"고 알린다(ADR 0038).
        if use.windowSwitches, !names.contains(kAXMainWindowChangedNotification) {
            stalledPID = pid
        }
        if outcome == .unsupported {
            unsupportedTarget = AttachTarget(pid: pid, use: use)
            return true
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        appElement = app
        self.pid = pid
        self.use = use
        subscribed = names
        if use.textFocus {
            wasTextInput = element(app, kAXFocusedUIElementAttribute).map(Self.isTextInput) ?? false
        }
        if use.windowSwitches {
            // 앱 전환은 별도 옵션이 맡으므로, 새 앱의 현재 메인 창을 기준으로 잡고 시작한다.
            windows.reset(to: element(app, kAXMainWindowAttribute).map(AXWindowID.init))
        }
        Log.accessibility.notice("attached to pid \(pid) (\(names.joined(separator: ", ")); main window known: \(windows.currentWindow != nil))")
        return true
    }

    func detach() {
        retrier.cancel()
        stalledPID = nil
        unsupportedTarget = nil
        if let observer, let appElement {
            for name in subscribed {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = 0
        use = AccessibilityUse(textFocus: false, windowSwitches: false)
        subscribed = []
        wasTextInput = false
        windows.reset(to: nil)
    }

    fileprivate func focusChanged(isTextInput isText: Bool) {
        let was = wasTextInput
        wasTextInput = isText
        onFocusChanged?(was, isText)
    }

    fileprivate func mainWindowChanged(to window: AXWindowID) {
        let previous = windows.currentWindow
        if windows.mainWindowChanged(to: window) {
            onWindowSwitched?(previous, window)
        }
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    nonisolated static func isTextInput(_ element: AXUIElement) -> Bool {
        TextInputRole.isTextInput(
            role: stringAttribute(element, kAXRoleAttribute),
            subrole: stringAttribute(element, kAXSubroleAttribute),
            isEditable: boolAttribute(element, "AXEditable")
        )
    }

    nonisolated private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

/// AX 창 요소의 동일성(CFEqual/CFHash). 창 제목 등 내용은 담지 않는다.
/// 앱을 다시 실행하면 같은 창으로 알아볼 수 없으므로 저장하지 않는다(ADR 0028).
struct AXWindowID: Hashable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXWindowID, rhs: AXWindowID) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

private func accessibilityFocusCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<AccessibilityFocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // observer의 run loop source는 main run loop에 등록되어 있다.
    if (notification as String) == kAXMainWindowChangedNotification {
        let window = AXWindowID(element: element)
        MainActor.assumeIsolated { monitor.mainWindowChanged(to: window) }
    } else {
        let isText = AccessibilityFocusMonitor.isTextInput(element)
        MainActor.assumeIsolated { monitor.focusChanged(isTextInput: isText) }
    }
}
