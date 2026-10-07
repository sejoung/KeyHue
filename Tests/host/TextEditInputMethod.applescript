-- Opt-in physical-key acceptance in two freshly created fixture documents.
-- Read and close only those documents; never enumerate user document contents.
property workerPath : ""
property logPath : ""
property activeName : ""
property nativeKeyPath : ""
property failedCases : 0
property modeSwitchMethod : "menu"
property exitSourceID : "io.github.sejoung.keyhue.inputmethod.spike.Latin"
property preparationMethod : "menu"
property entryOnly : false
property coldStart : false
property freshClient : false
property correctionMode : ""
property sourceRequestCount : 0
property latinID : "io.github.sejoung.keyhue.inputmethod.spike.Latin"
property hangulID : "io.github.sejoung.keyhue.inputmethod.spike.Hangul"
-- What the runner was doing when focus was checked, for focus diagnostics.
property focusStep : "start"
-- macOS "Capitalize words automatically" as TextEdit applies it (ADR 0081).
property autoCapitalization : false

on recordResult(message)
    do shell script "/usr/bin/printf '%s\\n' " & quoted form of message & " >> " & quoted form of logPath
end recordResult

on chooseMode(sourceID)
    set focusStep to "choose " & sourceID & " via " & modeSwitchMethod
    assertFocus()
    if modeSwitchMethod is "app" then
        tell application "System Events" to set targetPID to unix id of process "TextEdit"
        set senderDirectory to do shell script "/usr/bin/dirname " & quoted form of logPath
        if sourceRequestCount is 0 then
            do shell script "/usr/bin/open -gj -n " & quoted form of (nativeKeyPath & ".app") & " --args " & quoted form of senderDirectory & " " & targetPID & " " & quoted form of activeName
            set senderReadyPath to senderDirectory & "/source-sender-0.log"
            repeat 80 times
                set ready to do shell script "if test -f " & quoted form of senderReadyPath & "; then echo ready; else echo waiting; fi"
                if ready is "ready" then exit repeat
                delay 0.025
            end repeat
            if ready is not "ready" then error "live source sender did not start"
            recordResult(do shell script "/bin/cat " & quoted form of senderReadyPath)
        end if
        set sourceRequestCount to sourceRequestCount + 1
        set senderReportPath to senderDirectory & "/source-sender-" & sourceRequestCount & ".log"
        do shell script quoted form of nativeKeyPath & " " & targetPID & " --request-source " & quoted form of (sourceID & ":" & sourceRequestCount) & " " & quoted form of activeName
        repeat 80 times
            set ready to do shell script "if test -f " & quoted form of senderReportPath & "; then echo ready; else echo waiting; fi"
            if ready is "ready" then exit repeat
            delay 0.025
        end repeat
        if ready is not "ready" then error "live source sender did not report selection"
        set senderReport to do shell script "/bin/cat " & quoted form of senderReportPath
        recordResult(senderReport)
        if senderReport does not end with "status=0" then error "live source sender selection failed"
        delay 0.1
        assertFocus()
        return
    end if
    if modeSwitchMethod is "shortcut" then
        tell application "System Events" to set targetPID to unix id of process "TextEdit"
        set shortcutReport to do shell script quoted form of nativeKeyPath & " " & targetPID & " --input-source-shortcut 60 " & quoted form of activeName
        repeat with reportLine in paragraphs of shortcutReport
            recordResult(contents of reportLine)
        end repeat
        delay 0.1
        assertFocus()
        set selectedID to do shell script quoted form of workerPath & " --keyhue-input-source-status | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[\"currentID\"])'"
        recordResult("PROBE: shortcut requested=" & sourceID & " observed=" & selectedID)
        if selectedID is not sourceID then error "configured shortcut did not select the requested fixture source"
        return
    end if
    if modeSwitchMethod is "repair" then
        -- The product's session repair (ADR 0062) in a worker: KeyHue modes only.
        if sourceID is hangulID or sourceID is latinID then
            recordResult("PROBE: " & (do shell script quoted form of workerPath & " --keyhue-select-input-source-repairing " & quoted form of sourceID))
        else
            do shell script quoted form of workerPath & " --keyhue-select-input-source " & quoted form of sourceID
        end if
        delay 0.1
        assertFocus()
        return
    end if
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

on prepareMode(sourceID)
    set savedSwitchMethod to modeSwitchMethod
    set modeSwitchMethod to preparationMethod
    chooseMode(sourceID)
    set modeSwitchMethod to savedSwitchMethod
end prepareMode

-- Keys are sent only while the fixture window is focused. Focus can leave it for
-- a moment inside TextEdit right after the input menu closes (2026-10-07: three
-- runs stopped at different cases, the fourth passed). Wait up to 1 s for it to
-- return and record where it went, so a later failure says what took focus.
-- Another app in front means someone is using the Mac: stop at once.
on assertFocus()
    set state to my focusState()
    if fixtureFocused of state then return
    set firstSeen to detail of state
    if not (editorFront of state) then error "test lost frontmost app step=" & focusStep & " " & firstSeen
    repeat with attempt from 1 to 10
        delay 0.1
        set state to my focusState()
        if fixtureFocused of state then
            recordResult("PROBE: focus left the fixture and returned after " & (attempt * 100) & "ms step=" & focusStep & " moved=" & firstSeen)
            return
        end if
        if not (editorFront of state) then exit repeat
    end repeat
    error "test lost focused fixture window step=" & focusStep & " first=" & firstSeen & " last=" & (detail of state)
end assertFocus

-- Where keyboard focus is, without reading documents: test fixture titles are
-- generated names and are reported; any other window only by title length.
-- Records are built outside System Events blocks so their keys stay plain names.
on focusState()
    set frontID to ""
    set inputMenuOpen to false
    set windowList to ""
    set keyTitle to missing value
    set keySubrole to ""
    set focusedRole to ""
    tell application "System Events"
        set frontID to bundle identifier of (first application process whose frontmost is true)
        if frontID is "com.apple.TextEdit" then
            try
                tell process "TextInputMenuAgent" to set inputMenuOpen to exists menu 1 of menu bar item 1 of menu bar 2
            end try
            tell process "TextEdit"
                set keyWindow to missing value
                try
                    set keyWindow to value of attribute "AXFocusedWindow"
                end try
                repeat with candidate in windows
                    set windowList to windowList & my windowLabel(name of candidate as text) & ","
                end repeat
                if keyWindow is not missing value then
                    set keyTitle to name of keyWindow as text
                    try
                        set keySubrole to value of attribute "AXSubrole" of keyWindow
                    end try
                    try
                        set focusedRole to value of attribute "AXRole" of (value of attribute "AXFocusedUIElement")
                    end try
                end if
            end tell
        end if
    end tell
    if frontID is not "com.apple.TextEdit" then return {fixtureFocused:false, editorFront:false, detail:"front=" & frontID}
    if keyTitle is missing value then
        return {fixtureFocused:false, editorFront:true, detail:"focused=none windows=[" & windowList & "] inputMenuOpen=" & inputMenuOpen}
    end if
    if keyTitle contains activeName then return {fixtureFocused:true, editorFront:true, detail:""}
    return {fixtureFocused:false, editorFront:true, detail:"focused=" & windowLabel(keyTitle) & " subrole=" & keySubrole & " element=" & focusedRole & " windows=[" & windowList & "] inputMenuOpen=" & inputMenuOpen}
end focusState

on windowLabel(title)
    if title starts with "KeyHueIMK-" then return title
    return "other(titleLength=" & (length of title) & ")"
end windowLabel

-- A window title is the document name, optionally followed by its extension
-- or a suffix such as " — Edited". A plain substring would let "plain" match "plain-2".
on titleMatches(windowTitle, baseName)
    if windowTitle is baseName then return true
    if windowTitle starts with (baseName & ".") then return true
    if windowTitle starts with (baseName & " ") then return true
    return false
end titleMatches

on focusFixture(fixtureName)
    -- The document API includes the extension; window titles may hide it.
    set activeName to text 1 thru -5 of fixtureName
    set focusStep to "focus " & fixtureName
    set fixtureTitle to activeName
    -- Keep an already focused editor's input context. Raising and clicking it
    -- again is unnecessary and can move focus away during document relayout.
    -- Skip only when that exact window is focused and the text view, not a sheet
    -- or the toolbar, holds keyboard focus.
    tell application "System Events"
        set frontProcess to first application process whose frontmost is true
        if bundle identifier of frontProcess is "com.apple.TextEdit" then
            tell process "TextEdit"
                set focusedTitle to name of (value of attribute "AXFocusedWindow")
                set focusedRole to ""
                try
                    set focusedRole to value of attribute "AXRole" of (value of attribute "AXFocusedUIElement")
                end try
            end tell
            if my titleMatches(focusedTitle, fixtureTitle) and focusedRole is "AXTextArea" then
                my assertFocus()
                return
            end if
        end if
    end tell
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
        set value of attribute "AXMain" of fixtureWindow to true
        perform action "AXRaise" of fixtureWindow
        set {windowX, windowY} to position of fixtureWindow
    end tell
    delay 0.1
    -- AXRaise alone changes stacking; a native click activates the text
    -- context and lets the outgoing editor finish its marked composition.
    tell application "System Events"
        set frontProcess to first application process whose frontmost is true
        if bundle identifier of frontProcess is not "com.apple.TextEdit" then error "test lost frontmost app before click front=" & (bundle identifier of frontProcess)
        tell process "TextEdit"
            -- The window array can retain an old order after editing even when
            -- AXMainWindow and AXFocusedWindow both identify this fixture.
            -- Use the actual main window; assertFocus checks focus after clicking.
            if name of (value of attribute "AXMainWindow") does not contain fixtureTitle then error "test lost main fixture window before click"
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
    set focusStep to "key " & code & " flags=" & flags
    assertFocus()
    tell application "System Events" to set targetPID to unix id of process "TextEdit"
    set eventReport to do shell script quoted form of nativeKeyPath & " " & targetPID & " " & code & " " & flags & " " & quoted form of activeName
    if eventReport is not "" then recordResult(eventReport)
end nativeKey

on checkText(fixtureName, expectedText, label)
    delay 0.1
    tell application "TextEdit" to set receivedText to text of document fixtureName as text
    -- AppleScript ignores case unless told: Dkssud and dkssud must differ (ADR 0081).
    considering case
        set matched to receivedText is expectedText
    end considering
    if not matched then
        set failedCases to failedCases + 1
        -- The fixture holds only what this test typed, so its text is safe to log:
        -- it shows what the app or the input method changed (2026-10-07: macOS
        -- capitalized the first word before the correction read it).
        recordResult("FAIL: " & label & ": text mismatch (fixture units=" & (count receivedText) & ", originalPrefixKept=" & (receivedText starts with "안") & ", trailingSpace=" & (receivedText ends with " ") & ") expected=\"" & expectedText & "\" received=\"" & receivedText & "\"")
        return
    end if
    recordResult("PASS: " & label)
end checkText

-- TextEdit's own setting first, then the global one; macOS turns it on by default.
on readAutoCapitalization()
    set value to do shell script "/usr/bin/defaults read com.apple.TextEdit NSAutomaticCapitalizationEnabled 2>/dev/null || /usr/bin/defaults read -g NSAutomaticCapitalizationEnabled 2>/dev/null || echo 1"
    return value is "1"
end readAutoCapitalization

-- A word typed at the start of the document, followed by Space: macOS capitalizes
-- its first letter when automatic capitalization is on (ADR 0081).
on sentenceStart(expectedText)
    if not autoCapitalization or expectedText is "" then return expectedText
    set lower to "abcdefghijklmnopqrstuvwxyz"
    set upper to "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    set firstCharacter to character 1 of expectedText
    considering case
        if lower does not contain firstCharacter then return expectedText
        set firstCharacter to character (offset of firstCharacter in lower) of upper
    end considering
    if (length of expectedText) is 1 then return firstCharacter
    return firstCharacter & (text 2 thru -1 of expectedText)
end sentenceStart

on clearFixture(fixtureName)
    focusFixture(fixtureName)
    -- Reset independently of the path under test: a missed deactivation in
    -- one case must not leave the old server buffer in the next fixture.
    prepareMode("com.apple.keylayout.ABC")
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

on requireText(fixtureName, expectedText, label)
    set failuresBefore to failedCases
    checkText(fixtureName, expectedText, label)
    if failedCases > failuresBefore then
        if expectedText is "ㅇ" then
            tell application "TextEdit" to set rawFirstKey to (text of document fixtureName as text) is "d"
            recordResult("PROBE: entry first key passed through as raw ASCII=" & rawFirstKey)
        end if
        error "entry acceptance failed; later entry checks omitted"
    end if
end requireText

on checkMode(sourceID, label)
    set currentID to do shell script quoted form of workerPath & " --keyhue-input-source-status | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[\"currentID\"])'"
    if currentID is sourceID then
        recordResult("PASS: " & label)
    else
        set failedCases to failedCases + 1
        recordResult("FAIL: " & label & ": mode mismatch")
    end if
end checkMode

on typeLatin(fixtureName, keyCodes)
    clearFixture(fixtureName)
    chooseMode(latinID)
    sendKeys(keyCodes)
end typeLatin

-- ADR 0068: the default correction shortcut, ⌥↩.
on fixKey()
    nativeKey(36, 524288)
    delay 0.4
end fixKey

on typeHangul(fixtureName, keyCodes)
    clearFixture(fixtureName)
    chooseMode(hangulID)
    sendKeys(keyCodes)
end typeHangul

-- ADR 0064: real words judged by the detector, in TextEdit with real keys.
on checkCorrection(plainName)
    set annyeong to {2, 40, 1, 1, 32, 2, 5, 40, 17, 35, 2, 16} -- dkssudgktpdy → 안녕하세요
    set hangeul to {5, 40, 1, 15, 46, 3} -- gksrmf → 한글
    set hello to {4, 14, 37, 37, 31}
    set ipryeokgi to {2, 37, 12, 3, 32, 15, 15, 37} -- dlqfurrl → 입력기
    if correctionMode is "manual" then
        -- ADR 0068: the shortcut fixes the selection or the word before the caret, either way.
        set keyboard to {40, 14, 16, 11, 31, 0, 15, 2} -- keyboard → ㅏ됴ㅠㅐㅁㄱㅇ
        set annyeongShort to {2, 40, 1, 1, 32, 2} -- dkssud → 안녕
        typeLatin(plainName, annyeong)
        fixKey()
        checkText(plainName, "안녕하세요", "shortcut: Latin-mode word is fixed")
        checkMode(hangulID, "shortcut: Korean is selected after the fix")
        fixKey()
        checkText(plainName, "dkssudgktpdy", "shortcut: pressing again right away restores the word")
        checkMode(latinID, "shortcut: English is selected again")
        typeLatin(plainName, hangeul & {49})
        fixKey()
        checkText(plainName, "한글 ", "shortcut: a word finished with Space keeps its Space")
        typeLatin(plainName, hello & {49})
        fixKey()
        checkText(plainName, "ㅗ디ㅣㅐ ", "shortcut: asked, even real English is converted")
        typeHangul(plainName, hello)
        fixKey()
        checkText(plainName, "hello", "shortcut: Korean-mode word is fixed")
        checkMode(latinID, "shortcut: English is selected after the fix")
        typeHangul(plainName, {0, 1, 2}) -- asd → ㅁㄴㅇ: each jamo is committed by the next key
        fixKey()
        checkText(plainName, "asd", "shortcut: single jamo are fixed as one word")
        typeHangul(plainName, {0, 1, 2, 49})
        fixKey()
        checkText(plainName, "asd ", "shortcut: single jamo finished with Space are fixed")
        typeHangul(plainName, keyboard & {49})
        fixKey()
        checkText(plainName, "keyboard ", "shortcut: Korean-mode word finished with Space is fixed")
        typeLatin(plainName, hello & {49} & ipryeokgi)
        fixKey()
        checkText(plainName, sentenceStart("hello 입력기"), "shortcut: only the word before the caret is fixed")
        typeLatin(plainName, annyeongShort & {49} & hangeul)
        nativeKey(0, 1048576) -- select all
        delay 0.2
        fixKey()
        checkText(plainName, "안녕 한글", "shortcut: the selection is fixed")
        clearFixture(plainName)
        chooseMode(latinID)
        fixKey()
        checkText(plainName, "", "shortcut: nothing to fix leaves the document alone")
        -- ADR 0068: switching modes is never a fix request.
        typeLatin(plainName, annyeong & {49})
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, sentenceStart("dkssudgktpdy "), "switching modes does not fix the word")
    else
        typeLatin(plainName, annyeong & {49})
        delay 0.4
        checkText(plainName, "안녕하세요 ", "automatic: corrected at Space")
        checkMode(hangulID, "automatic: Korean selected after the correction")
        sendKeys({51})
        delay 0.4
        -- Undo restores what was shown: capitalized by macOS when that is on.
        checkText(plainName, sentenceStart("dkssudgktpdy"), "automatic: immediate Delete restores the word without its Space")
        checkMode(latinID, "automatic: undo restores English")
        sendKeys({49})
        delay 0.4
        checkText(plainName, sentenceStart("dkssudgktpdy "), "automatic: the undone word is not corrected again")
        typeLatin(plainName, hello & {49})
        delay 0.4
        checkText(plainName, sentenceStart("hello "), "automatic: English word is kept")
        typeLatin(plainName, hangeul & {49})
        delay 0.4
        checkText(plainName, "한글 ", "automatic: another word is corrected")
    end if
end checkCorrection

on checkEntry(plainName)
    clearFixture(plainName)
    set entryRounds to {1, 2, 3}
    -- A fresh editor has a session to the service only until its first round.
    if freshClient then set entryRounds to {1}
    repeat with entryRound in entryRounds
        -- Prime only the native shortcut's previous-source pair. This is
        -- explicit setup, never a recovery between selection and first key.
        -- A fresh client is never primed: priming opens the session under test.
        if (modeSwitchMethod is "shortcut" or coldStart) and not freshClient then
            set savedPreparation to preparationMethod
            set preparationMethod to "menu"
            prepareMode(hangulID)
            prepareMode("com.apple.keylayout.ABC")
            set preparationMethod to savedPreparation
        end if
        if coldStart then
            assertFocus()
            tell application "System Events" to set targetPID to unix id of process "TextEdit"
            set servicePath to (POSIX path of (path to home folder)) & "Library/Input Methods/KeyHueInputMethodSpike.app"
            set stopOperation to " --stop-service "
            if freshClient then set stopOperation to " --stop-service-if-running "
            set stopReport to do shell script quoted form of nativeKeyPath & " " & targetPID & stopOperation & quoted form of servicePath & " " & quoted form of activeName
            recordResult(stopReport)
        end if
        recordResult("PROBE: entry round=" & entryRound & " coldStart=" & coldStart & " freshClient=" & freshClient)
        chooseMode(hangulID)
        -- A selected source ID is not a connected service. Record both, and
        -- read callbacks only from the tested window of the server log.
        tell application "System Events" to set targetPID to unix id of process "TextEdit"
        recordResult(do shell script quoted form of nativeKeyPath & " " & targetPID & " --service-state - " & quoted form of activeName)
        sendKeys({2})
        requireText(plainName, "ㅇ", "entry first Hangul key round=" & entryRound)
        sendKeys({40, 1})
        requireText(plainName, "안", "entry first Hangul syllable round=" & entryRound)
        if modeSwitchMethod is "shortcut" then
            chooseMode("com.apple.keylayout.ABC")
        else
            chooseMode(latinID)
        end if
        sendKeys({0, 49})
        requireText(plainName, "안a ", "entry switch preserves composition and first ASCII key round=" & entryRound)
        if modeSwitchMethod is not "shortcut" then chooseMode("com.apple.keylayout.ABC")
        assertFocus()
        tell application "TextEdit" to set text of document plainName to ""
    end repeat
end checkEntry

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
    set exitSourceID to latinID
    set preparationMethod to "menu"
    set entryOnly to false
    set coldStart to false
    set freshClient to false
    set correctionMode to ""
    set sourceRequestCount to 0
    set autoCapitalization to readAutoCapitalization()
    recordResult("PROBE: autoCapitalization=" & autoCapitalization)
    if (count arguments) > 6 then
        if item 7 of arguments is "--worker-switch" then
            set modeSwitchMethod to "worker"
        else if item 7 of arguments is "--shortcut-switch" then
            set modeSwitchMethod to "shortcut"
        else if item 7 of arguments is "--app-switch" then
            set modeSwitchMethod to "app"
        else if item 7 of arguments is "--repair-switch" then
            set modeSwitchMethod to "repair"
        else if item 7 of arguments is not "--menu-switch" then
            error "invalid mode switch method"
        end if
    end if
    if (count arguments) > 7 then
        if item 8 of arguments is "--exit-abc" then
            set exitSourceID to "com.apple.keylayout.ABC"
        else if item 8 of arguments is not "--exit-latin" then
            error "invalid exit source"
        end if
    end if
    if (count arguments) > 8 then
        if item 9 of arguments is "--prepare-worker" then
            set preparationMethod to "worker"
        else if item 9 of arguments is "--prepare-menu" then
            set preparationMethod to "menu"
        else
            error "invalid preparation method"
        end if
    end if
    if (count arguments) > 9 then
        if item 10 of arguments is not "--cold-start" then error "invalid entry lifecycle"
        set coldStart to true
    end if
    if (count arguments) > 10 then
        if item 11 of arguments is not "--fresh-client" then error "invalid entry client"
        set freshClient to true
    end if
    if (count arguments) > 5 then
        set testScope to item 6 of arguments
        if testScope is "--windows-only" then
            set windowsOnly to true
        else if testScope is "--entry-only" then
            set entryOnly to true
        else if testScope is "--correction-manual" then
            set correctionMode to "manual"
        else if testScope is "--correction-automatic" then
            set correctionMode to "automatic"
        else if testScope is "--plain-only" then
            set testKind to "plain"
        else if testScope is "--rich-only" then
            set testKind to "rich"
        else if testScope is not "--both" then
            error "invalid TextEdit test scope"
        end if
    end if
    if (count arguments) > 11 then error "unexpected fixture arguments"
    if coldStart and not entryOnly then error "cold start requires entry-only scope"
    if (modeSwitchMethod is "shortcut" or modeSwitchMethod is "app" or modeSwitchMethod is "repair") and not entryOnly then error "this switching method requires entry-only scope"
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
        recordResult("PROBE: window exit source=" & exitSourceID)
        recordResult("PROBE: fixture preparation=" & preparationMethod)
        if correctionMode is not "" then
            focusFixture(plainName)
            checkCorrection(plainName)
            closeFixture(plainName)
            closeFixture(richName)
            if failedCases > 0 then error "correction acceptance failed"
            recordResult("PASS: TextEdit correction acceptance mode=" & correctionMode)
            return
        end if
        if entryOnly then
            checkEntry(plainName)
            closeFixture(plainName)
            closeFixture(richName)
            recordResult("PASS: TextEdit entry input acceptance")
            return
        end if
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
            checkText(fixtureName, sentenceStart("hello "), fixtureKind & " Latin input and boundary")

            clearFixture(fixtureName)
            chooseMode(latinID)
            sendKeys({2, 40, 1, 1, 32, 2, 49})
            delay 0.35
            checkText(fixtureName, sentenceStart("dkssud "), fixtureKind & " Latin word unchanged while correction is off")

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

        -- Keep focus fixed so no window callback can finish this composition
        -- for the input-source notification fallback.
        clearFixture(plainName)
        prepareMode(hangulID)
        recordResult("PROBE: pending composition prepared with " & preparationMethod)
        set failuresBeforePendingCase to failedCases
        sendKeys({2, 40, 1})
        checkText(plainName, "안", "pending composition before external source switch")
        if failedCases > failuresBeforePendingCase then error "initial composing context unavailable; source-switch checks omitted"
        chooseMode(exitSourceID)
        sendKeys({0, 49})
        checkText(plainName, "안a ", "pending composition preserved without a window callback")
        if failedCases > failuresBeforePendingCase then error "pending composition source switch failed; later fixture checks omitted"

        clearFixture(plainName)
        clearFixture(richName)
        focusFixture(plainName)
        -- Prepare a real composing context independently of the programmatic
        -- entry path. This case isolates switching *away* from that context.
        prepareMode(hangulID)
        recordResult("PROBE: window composition prepared with " & preparationMethod)
        sendKeys({2, 40, 1})
        focusFixture(richName)
        checkText(plainName, "안", "window switch preserves visible last syllable")
        chooseMode(hangulID)
        sendKeys({15, 40, 49})
        checkText(richName, "가 ", "first key in other document")
        focusFixture(plainName)
        checkText(plainName, "안", "original document preserved on return")
        chooseMode(exitSourceID)
        checkText(plainName, "안", "original document preserved after ASCII selection")
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
