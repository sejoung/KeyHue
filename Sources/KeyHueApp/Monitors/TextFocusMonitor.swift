import AppKit
import ApplicationServices
import KeyHueCore

/// (Phase 2, 실험적) 활성 앱의 focused UI element 변경을 Accessibility API로 관찰한다.
///
/// focus된 요소의 role/subrole/편집 가능 여부만 읽고, 값(텍스트 내용)은 절대 읽지 않는다.
/// Accessibility 권한이 필요하므로 옵션을 켰을 때만 동작한다.
@MainActor
final class TextFocusMonitor {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var wasTextInput = false

    /// (wasTextInput, isTextInput)
    var onFocusChanged: ((Bool, Bool) -> Void)?

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
        guard AXObserverCreate(pid, textFocusCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon) == .success else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        appElement = app
        self.pid = pid
        wasTextInput = focusedElement(of: app).map(Self.isTextInput) ?? false
    }

    func detach() {
        if let observer, let appElement {
            AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = 0
        wasTextInput = false
    }

    fileprivate func focusChanged(isTextInput isText: Bool) {
        let was = wasTextInput
        wasTextInput = isText
        onFocusChanged?(was, isText)
    }

    private func focusedElement(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
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

private func textFocusCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<TextFocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let isText = TextFocusMonitor.isTextInput(element)
    // observer의 run loop source는 main run loop에 등록되어 있다.
    MainActor.assumeIsolated {
        monitor.focusChanged(isTextInput: isText)
    }
}
