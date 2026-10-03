-- Opt-in physical-key acceptance in two freshly created fixture documents.
-- Read and close only those documents; never enumerate user document contents.
property workerPath : ""
property logPath : ""
property activeName : ""
property nativeKeyPath : ""
property failedCases : 0
property modeSwitchMethod : "menu"
property latinID : "io.github.sejoung.keyhue.inputmethod.spike.Latin"
property hangulID : "io.github.sejoung.keyhue.inputmethod.spike.Hangul"

on recordResult(message)
    do shell script "/usr/bin/printf '%s\\n' " & quoted form of message & " >> " & quoted form of logPath
end recordResult

on chooseMode(sourceID)
    assertFocus()
    if modeSwitchMethod is "worker" then
        do shell script quoted form of workerPath & " --keyhue-select-input-source " & quoted form of sourceID
        delay 0.1
        assertFocus()
        return
    end if
    set sourceName to do shell script quoted form of nativeKeyPath & " --source-name " & quoted form of sourceID
    set fallbackName to sourceName
    if sourceID is hangulID then set fallbackName to "KeyHue 실험 – 두벌식"
    if sourceID is latinID then set fallbackName to "KeyHue 실험 – 영문"
    -- Select in the focused editor's real input menu, independently of the
    -- short-lived worker used by the outer runner for cleanup.
    tell application "System Events" to tell process "TextInputMenuAgent"
        click menu bar item 1 of menu bar 2
        delay 0.1
        try
            if exists menu item sourceName of menu 1 of menu bar item 1 of menu bar 2 then
                click menu item sourceName of menu 1 of menu bar item 1 of menu bar 2
            else
                -- TIS can expose the English metadata while the menu uses
                -- this bundle's Korean localization.
                click menu item fallbackName of menu 1 of menu bar item 1 of menu bar 2
            end if
        on error message number errorNumber
            key code 53
            error message number errorNumber
        end try
    end tell
    delay 0.1
    assertFocus()
end chooseMode

on assertFocus()
    tell application "System Events"
        set frontProcess to first application process whose frontmost is true
        if bundle identifier of frontProcess is not "com.apple.TextEdit" then error "test lost frontmost app"
        tell process "TextEdit"
            set keyWindow to value of attribute "AXFocusedWindow"
            if name of keyWindow does not contain my activeName then error "test lost focused fixture window"
        end tell
    end tell
end assertFocus

on focusFixture(fixtureName)
    -- The document API includes the extension; window titles may hide it.
    set activeName to text 1 thru -5 of fixtureName
    set fixtureTitle to activeName
    tell application "TextEdit" to activate
    delay 0.1
    -- The scripting document can exist before its accessibility window.
    repeat 40 times
        tell application "System Events" to tell process "TextEdit"
            set windowReady to exists (first window whose name contains fixtureTitle)
        end tell
        if windowReady then exit repeat
        delay 0.05
    end repeat
    if not windowReady then error "fixture accessibility window did not open"
    tell application "System Events" to tell process "TextEdit"
        set fixtureWindow to first window whose name contains fixtureTitle
        perform action "AXRaise" of fixtureWindow
        set {windowX, windowY} to position of fixtureWindow
    end tell
    delay 0.1
    -- AXRaise alone changes stacking; a native click activates the text
    -- context and lets the outgoing editor finish its marked composition.
    tell application "System Events"
        set frontProcess to first application process whose frontmost is true
        if bundle identifier of frontProcess is not "com.apple.TextEdit" then error "test lost frontmost app before click"
        tell process "TextEdit"
            if name of front window does not contain fixtureTitle then error "test lost fixture window before click"
        end tell
        click at {windowX + 100, windowY + 150}
    end tell
    delay 0.1
    assertFocus()
end focusFixture

on sendKeys(keyCodes)
    repeat with code in keyCodes
        assertFocus()
        nativeKey(contents of code, 0)
        delay 0.04
    end repeat
end sendKeys

on nativeKey(code, flags)
    assertFocus()
    tell application "System Events" to set targetPID to unix id of process "TextEdit"
    set eventReport to do shell script quoted form of nativeKeyPath & " " & targetPID & " " & code & " " & flags & " " & quoted form of activeName
    if eventReport is not "" then recordResult(eventReport)
end nativeKey

on checkText(fixtureName, expectedText, label)
    delay 0.1
    tell application "TextEdit" to set receivedText to text of document fixtureName as text
    if receivedText is not expectedText then
        set failedCases to failedCases + 1
        recordResult("FAIL: " & label & ": text mismatch (fixture units=" & (count receivedText) & ", originalPrefixKept=" & (receivedText starts with "안") & ", trailingSpace=" & (receivedText ends with " ") & ")")
        return
    end if
    recordResult("PASS: " & label)
end checkText

on clearFixture(fixtureName)
    focusFixture(fixtureName)
    chooseMode("com.apple.keylayout.ABC")
    delay 0.1
    tell application "TextEdit" to set text of document fixtureName to ""
end clearFixture

on closeFixture(fixtureName)
    if fixtureName is "" then return
    tell application "TextEdit"
        if exists document fixtureName then close document fixtureName saving no
    end tell
end closeFixture

on waitForFixture(fixtureName)
    repeat 40 times
        tell application "TextEdit" to set ready to exists document fixtureName
        if ready then return
        delay 0.05
    end repeat
    error "fixture document did not open"
end waitForFixture

on run arguments
    set workerPath to item 1 of arguments
    set plainPath to item 2 of arguments
    set richPath to item 3 of arguments
    set logPath to item 4 of arguments
    set nativeKeyPath to item 5 of arguments
    set failedCases to 0
    set plainName to ""
    set richName to ""
    set windowsOnly to false
    set testKind to "both"
    set modeSwitchMethod to "menu"
    if (count arguments) > 6 then
        if item 7 of arguments is not "--worker-switch" then error "invalid mode switch method"
        set modeSwitchMethod to "worker"
    end if
    if (count arguments) > 5 then
        set testScope to item 6 of arguments
        if testScope is "--windows-only" then
            set windowsOnly to true
        else if testScope is "--plain-only" then
            set testKind to "plain"
        else if testScope is "--rich-only" then
            set testKind to "rich"
        else if testScope is not "--both" then
            error "invalid TextEdit test scope"
        end if
    end if
    try
        set plainName to do shell script "/usr/bin/basename " & quoted form of plainPath
        set richName to do shell script "/usr/bin/basename " & quoted form of richPath
        -- The runner opens files through Launch Services, which gives the
        -- sandboxed editor access to these exact fixture files.
        recordResult("PROBE: waiting for fixture documents")
        waitForFixture(plainName)
        waitForFixture(richName)
        tell application "TextEdit"
            set appVersion to version
        end tell
        recordResult("TextEdit version: " & appVersion)
        set fixtureNames to {plainName, richName}
        if testKind is "plain" then set fixtureNames to {plainName}
        if testKind is "rich" then set fixtureNames to {richName}
        recordResult("PROBE: fixture kind=" & testKind)
        recordResult("PROBE: mode switch=" & modeSwitchMethod)
        if not windowsOnly then
        repeat with fixtureName in fixtureNames
            set fixtureName to contents of fixtureName
            if fixtureName is plainName then
                set fixtureKind to "plain"
            else
                set fixtureKind to "rich"
            end if
            clearFixture(fixtureName)
            chooseMode(hangulID)
            sendKeys({2, 40, 1, 1, 32, 2, 49})
            checkText(fixtureName, "안녕 ", fixtureKind & " Hangul composition and single Space")

            clearFixture(fixtureName)
            chooseMode(latinID)
            sendKeys({4, 14, 37, 37, 31, 49})
            checkText(fixtureName, "hello ", fixtureKind & " Latin input and boundary")

            clearFixture(fixtureName)
            chooseMode(latinID)
            sendKeys({2, 40, 1, 1, 32, 2, 49})
            delay 0.35
            checkText(fixtureName, "dkssud ", fixtureKind & " correction remains restricted to test bundle")

            clearFixture(fixtureName)
            chooseMode(hangulID)
            sendKeys({15, 4, 40, 15, 17, 51, 49})
            checkText(fixtureName, "곽 ", fixtureKind & " composition Backspace")

            clearFixture(fixtureName)
            chooseMode(hangulID)
            sendKeys({15, 4, 40, 15, 17, 40, 49})
            checkText(fixtureName, "곽사 ", fixtureKind & " compound final consonant moves")

            repeat with boundary in {123, 124, 36, 48}
                clearFixture(fixtureName)
                chooseMode(hangulID)
                sendKeys({2, 40, 1, contents of boundary})
                set expectedText to "안"
                if contents of boundary is 36 then set expectedText to "안" & linefeed
                if contents of boundary is 48 then set expectedText to "안" & tab
                checkText(fixtureName, expectedText, fixtureKind & " commit before boundary code=" & boundary)
            end repeat

            clearFixture(fixtureName)
            repeat 3 times
                chooseMode(hangulID)
                sendKeys({15, 40, 49})
                chooseMode(latinID)
                sendKeys({0, 11, 8, 49})
            end repeat
            checkText(fixtureName, "가 abc 가 abc 가 abc ", fixtureKind & " repeated modes and first key")

            assertFocus()
            nativeKey(0, 1048576)
            chooseMode(hangulID)
            sendKeys({15, 40, 49})
            checkText(fixtureName, "가 ", fixtureKind & " selected text replacement")
        end repeat
        end if

        clearFixture(plainName)
        clearFixture(richName)
        focusFixture(plainName)
        chooseMode(hangulID)
        sendKeys({2, 40, 1})
        focusFixture(richName)
        checkText(plainName, "안", "window switch preserves visible last syllable")
        chooseMode(hangulID)
        sendKeys({15, 40, 49})
        checkText(richName, "가 ", "first key in other document")
        focusFixture(plainName)
        checkText(plainName, "안", "original document preserved on return")
        chooseMode(latinID)
        checkText(plainName, "안", "original document preserved after Latin selection")
        assertFocus()
        -- Establish an insertion caret explicitly; the editor owns the
        -- selection restored when a document window becomes active.
        nativeKey(124, 1048576)
        checkText(plainName, "안", "original document preserved after caret placement")
        sendKeys({0})
        checkText(plainName, "안a", "first Latin key after document round trip")
        sendKeys({49})
        checkText(plainName, "안a ", "input at end after document round trip")
        closeFixture(plainName)
        closeFixture(richName)
        if failedCases > 0 then error (failedCases as text) & " acceptance cases failed"
        if windowsOnly then
            recordResult("PASS: TextEdit window input acceptance")
        else
            recordResult("PASS: TextEdit actual input acceptance kind=" & testKind)
        end if
    on error message number errorNumber
        recordResult("FAIL: " & message & " (" & errorNumber & ")")
        try
            closeFixture(plainName)
            closeFixture(richName)
        end try
        error message number errorNumber
    end try
end run
