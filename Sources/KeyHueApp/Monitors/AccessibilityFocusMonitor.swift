import AppKit
import ApplicationServices
import KeyHueCore

/// 활성 앱의 포커스 변화를 Accessibility API로 관찰한다(옵션을 켰을 때만, 손쉬운 사용 권한 필요).
///
/// - 텍스트 필드 이탈(실험적, ADR 0009): focused UI element의 role/subrole/편집 가능 여부만 읽는다.
/// - 창 전환(ADR 0027): **메인 창**이 다른 창으로 바뀌었는지만 본다. 창 제목·내용은 읽지 않는다.
/// 값(텍스트 내용)은 절대 읽지 않는다.
@MainActor
final class AccessibilityFocusMonitor {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var wasTextInput = false
    private var windows = WindowSwitchTracker<AXWindowID>()

    /// (wasTextInput, isTextInput)
    var onFocusChanged: ((Bool, Bool) -> Void)?
    /// 같은 앱 안에서 다른 창(탭)으로 옮겼다.
    var onWindowSwitched: (() -> Void)?

    static let notifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXMainWindowChangedNotification
    ]

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 시스템 Accessibility 권한 안내 대화상자를 띄운다.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    var isAttached: Bool { observer != nil }

    func attach(to pid: pid_t) {
        guard Self.isTrusted else {
            detach()
            return
        }
        guard pid != self.pid || observer == nil else { return }
        detach()

        var created: AXObserver?
        guard AXObserverCreate(pid, accessibilityFocusCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        appElement = app
        self.pid = pid
        wasTextInput = element(app, kAXFocusedUIElementAttribute).map(Self.isTextInput) ?? false
        // 앱 전환은 별도 옵션이 맡으므로, 새 앱의 현재 메인 창을 기준으로 잡고 시작한다.
        windows.reset(to: element(app, kAXMainWindowAttribute).map(AXWindowID.init))
    }

    func detach() {
        if let observer, let appElement {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = 0
        wasTextInput = false
        windows.reset(to: nil)
    }

    fileprivate func focusChanged(isTextInput isText: Bool) {
        let was = wasTextInput
        wasTextInput = isText
        onFocusChanged?(was, isText)
    }

    fileprivate func mainWindowChanged(to window: AXWindowID) {
        if windows.mainWindowChanged(to: window) {
            onWindowSwitched?()
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

/// AX 창 요소의 동일성(CFEqual). 창 제목 등 내용은 담지 않는다.
struct AXWindowID: Equatable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXWindowID, rhs: AXWindowID) -> Bool {
        CFEqual(lhs.element, rhs.element)
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
