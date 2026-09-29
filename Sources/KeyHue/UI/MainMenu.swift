import AppKit

/// Dock에 보이는 일반 앱일 때 화면 상단에 나타나는 앱 메뉴(KeyHue / 편집 / 윈도우).
/// 메뉴바 아이콘의 메뉴(StatusBarController)와 별개다. 언어를 바꾸면 다시 만든다.
@MainActor
enum MainMenu {
    static func make(target: AnyObject, showSettings: Selector, showAbout: Selector) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "KeyHue")
        app.addItem(item(L("About KeyHue"), showAbout, target: target))
        app.addItem(.separator())
        app.addItem(item(L("Settings…"), showSettings, key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item(L("Hide KeyHue"), #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(L("Quit KeyHue"), #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu(app))

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(item(L("Cut"), #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item(L("Copy"), #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item(L("Paste"), #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item(L("Select All"), #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenu(edit))

        let window = NSMenu(title: L("Window"))
        window.addItem(item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item(L("Close"), #selector(NSWindow.performClose(_:)), key: "w"))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
