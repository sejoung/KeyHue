import AppKit
import ApplicationServices
import KeyHueCore
import os

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
    private static let log = Logger(subsystem: "KeyHue", category: "Accessibility")

    /// AX 요청 응답 대기 시간(초). 기본값(실측: 멈춘 앱에 요청 한 번당 약 1.5초, 붙을 때는 여러 번 이어진다) 대신
    /// 짧게 두고, 늦으면 그 판단은 건너뛴다. 실측: 0.25초로 두면 0.27초에 끊긴다.
    static let messagingTimeout: Float = 0.25

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var use = AccessibilityUse(textFocus: false, windowSwitches: false)
    private var subscribed: [String] = []
    private var wasTextInput = false
    private var windows = WindowSwitchTracker<AXWindowID>()
    private let retrier: AttachRetrier<AttachTarget>

    private struct AttachTarget: Equatable {
        let pid: pid_t
        let use: AccessibilityUse
    }

    /// (wasTextInput, isTextInput)
    var onFocusChanged: ((Bool, Bool) -> Void)?
    /// 같은 앱 안에서 다른 창(탭)으로 옮겼다. (떠난 창, 옮겨 간 창)
    var onWindowSwitched: ((AXWindowID?, AXWindowID) -> Void)?

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

    /// 이 프로세스의 모든 AX 요청에 응답 대기 시간을 건다(시스템 전체 요소에 설정하면 전역 기본값이 된다).
    @discardableResult
    static func applyMessagingTimeout() -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    init(scheduler: Scheduling = MainQueueScheduler()) {
        retrier = AttachRetrier(scheduler: scheduler)
        Self.applyMessagingTimeout()
    }

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
        guard Self.isTrusted, !use.isEmpty else {
            detach()
            return
        }
        guard pid != self.pid || use != self.use || observer == nil else { return }
        let target = AttachTarget(pid: pid, use: use)
        guard retrier.pendingTarget != target else { return }
        detach()
        retrier.start(target) { [weak self] target in
            self?.subscribe(to: target.pid, for: target.use) ?? true
        }
    }

    /// 알림을 등록하고 기준값을 읽는다. 앱이 아직 답하지 못하면(실행 중) 등록을 되돌리고 false.
    private func subscribe(to pid: pid_t, for use: AccessibilityUse) -> Bool {
        var created: AXObserver?
        guard AXObserverCreate(pid, accessibilityFocusCallback, &created) == .success, let created else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var names: [String] = []
        for name in Self.notifications(for: use) {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            if result == .cannotComplete {
                // 실측: 활성화 알림 직후(실행 중)에는 -25204, 100 ms 뒤에는 성공한다.
                for added in names {
                    AXObserverRemoveNotification(created, app, added as CFString)
                }
                Self.log.debug("pid \(pid) not ready for AX notifications; will retry")
                return false
            }
            if result == .success {
                names.append(name)
            }
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
        Self.log.debug("attached to pid \(pid) (main window known: \(self.windows.currentWindow != nil))")
        return true
    }

    func detach() {
        retrier.cancel()
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
