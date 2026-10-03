-- Bounded cleanup, including a watchdog-terminated test. Names are unique
-- generated fixture paths supplied by the runner, never user document names.
on run arguments
    with timeout of 3 seconds
        repeat with fixturePath in arguments
            set fixtureName to do shell script "/usr/bin/basename " & quoted form of (contents of fixturePath)
            if fixtureName starts with "KeyHueIMK-" then
                tell application "TextEdit"
                    if exists document fixtureName then close document fixtureName saving no
                end tell
            end if
        end repeat
    end timeout
end run
