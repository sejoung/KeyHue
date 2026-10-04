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

on recordResult(message)
    do shell script "/usr/bin/printf '%s\\n' " & quoted form of message & " >> " & quoted form of logPath
end recordResult

on chooseMode(sourceID)
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

-- ADR 0064: real words judged by the detector, in TextEdit with real keys.
on checkCorrection(plainName)
    set annyeong to {2, 40, 1, 1, 32, 2, 5, 40, 17, 35, 2, 16} -- dkssudgktpdy → 안녕하세요
    set hangeul to {5, 40, 1, 15, 46, 3} -- gksrmf → 한글
    set hello to {4, 14, 37, 37, 31}
    set ipryeokgi to {2, 37, 12, 3, 32, 15, 15, 37} -- dlqfurrl → 입력기
    if correctionMode is "manual" then
        typeLatin(plainName, annyeong & {49})
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, "안녕하세요 ", "manual: word finished with Space is corrected on the switch")
        sendKeys({51})
        delay 0.3
        checkText(plainName, "dkssudgktpdy ", "manual: immediate Delete restores the word")
        checkMode(hangulID, "manual: undo keeps the chosen Korean mode")
        -- ADR 0065: an undone word is not corrected again; later cases use other words.
        typeLatin(plainName, annyeong & {49})
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, "dkssudgktpdy ", "manual: the undone word is not corrected again")
        typeLatin(plainName, hangeul)
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, "한글", "manual: word being typed is corrected on the switch")
        typeLatin(plainName, hello & {49})
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, "hello ", "manual: English word is kept")
        typeLatin(plainName, hello & {49} & ipryeokgi)
        chooseMode(hangulID)
        delay 0.3
        checkText(plainName, "hello 입력기", "manual: only the last word is corrected")
    else
        typeLatin(plainName, annyeong & {49})
        delay 0.4
        checkText(plainName, "안녕하세요 ", "automatic: corrected at Space")
        checkMode(hangulID, "automatic: Korean selected after the correction")
        sendKeys({51})
        delay 0.4
        checkText(plainName, "dkssudgktpdy", "automatic: immediate Delete restores the word without its Space")
        checkMode(latinID, "automatic: undo restores English")
        sendKeys({49})
        delay 0.4
        checkText(plainName, "dkssudgktpdy ", "automatic: the undone word is not corrected again")
        typeLatin(plainName, hello & {49})
        delay 0.4
        checkText(plainName, "hello ", "automatic: English word is kept")
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
            checkText(fixtureName, "hello ", fixtureKind & " Latin input and boundary")

            clearFixture(fixtureName)
            chooseMode(latinID)
            sendKeys({2, 40, 1, 1, 32, 2, 49})
            delay 0.35
            checkText(fixtureName, "dkssud ", fixtureKind & " Latin word unchanged while correction is off")

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
