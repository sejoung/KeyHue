import Foundation
import KeyHueCore

/// Executes a correction decided elsewhere (`CorrectionPolicy`, ADR 0064) as staged
/// edits with verification. The IMK adapter enables this for the isolated test
/// client's bundle ID, never for normal applications. No language detection here.
public final class CorrectionProbe {
    public enum Outcome: Equatable {
        case passThrough, pending, corrected, undone, restoredOriginal, unsafeFailure

        /// Once a replacement occurred, do not also deliver Space/Backspace.
        public var handled: Bool { self != .passThrough }
    }

    private struct Edit {
        let identity: String
        let original: String
        let corrected: String
        let location: Int
        var inputHasBoundary = false
        var originalRange: NSRange { NSRange(location: location, length: original.utf16.count) }
        var correctedRange: NSRange { NSRange(location: location, length: corrected.utf16.count) }
        var inputText: String { original + (inputHasBoundary ? " " : "") }
        var inputRange: NSRange { NSRange(location: location, length: inputText.utf16.count) }
    }
    private var undoEdit: Edit?
    private var rejected: Edit?
    private var generation = 0
    private var busy = false
    private enum Phase { case correctionText, correctionMode, undoText, undoMode, restoreLatin, restoreHangul }
    private struct Pending { let edit: Edit; let phase: Phase }
    private var pending: Pending?
    public var hasPendingEdit: Bool { pending != nil }
    /// Only these callbacks belong to a mode effect this transaction requested.
    /// A user mode selection can arrive before TIS publishes the new source.
    public var pendingModeRequest: ProbeSession.Mode? {
        switch pending?.phase {
        case .correctionMode: return .hangul
        case .undoMode: return .latin
        default: return nil
        }
    }
    /// Changes only when a new remote effect is requested, not while observing.
    public private(set) var effectSequence = 0
    /// Why the last correction or undo failed in the client (ADR 0065). Cleared when
    /// a new one starts. Cancellations by the user's next key are not failures.
    public private(set) var lastFailure: CorrectionFailure?

    public init() {}

    /// Additional input, navigation, mouse, external mode change or session end.
    public func invalidate() {
        generation &+= 1
        undoEdit = nil
        rejected = nil
        pending = nil
    }

    private func matches(_ text: String, at range: NSRange, mode: ProbeSession.Mode,
                         identity: String, client: any CorrectionProbeClient) -> Bool {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= Int.max - range.length,
              client.identity == identity, client.mode == mode, !client.hasMarkedText,
              client.selection == NSRange(location: range.location + range.length, length: 0),
              let observed = client.text(in: range), observed.utf16.count == range.length else { return false }
        return observed == text
    }

    private func originalIsOwned(_ edit: Edit, client: any CorrectionProbeClient) -> Bool {
        let end = edit.location + edit.inputRange.length
        guard client.identity == edit.identity, client.mode == .latin,
              Self.typingCaret(selection: client.selection, markedRange: client.markedRange) == end,
              client.text(in: edit.inputRange) == edit.inputText else { return false }
        return !client.hasMarkedText || (!edit.inputHasBoundary && client.markedRange == NSRange(location: end - 1, length: 1))
    }

    /// The real IMK bridge applies edits after the key callback returns. Its
    /// cached ranges cannot confirm a write in that same callback. These staged
    /// entry points use later main-loop observations, with generation checks for
    /// input callbacks that can reenter a synchronous client query.
    /// - Parameters:
    ///   - original: the Latin word as typed; `corrected`: its Hangul, both without the Space.
    public func beginCorrection(original: String, corrected: String, at location: Int, boundaryAlreadyCommitted: Bool = false,
                                client: any CorrectionProbeClient) -> Outcome {
        guard !busy, pending == nil, !original.isEmpty, !corrected.isEmpty, location >= 0,
              location < Int.max - original.utf16.count - 1 else { return .passThrough }
        let version = generation
        let edit = Edit(identity: client.identity, original: original, corrected: corrected + " ", location: location,
                        inputHasBoundary: boundaryAlreadyCommitted)
        if let rejected, rejected.identity == edit.identity, rejected.location == location,
           matches(edit.inputText, at: edit.inputRange, mode: .latin, identity: edit.identity, client: client) {
            self.rejected = nil
            return .passThrough
        }
        guard originalIsOwned(edit, client: client), generation == version else { return .passThrough }
        undoEdit = nil
        lastFailure = nil
        busy = true
        defer { busy = false }
        pending = Pending(edit: edit, phase: .correctionText)
        effectSequence &+= 1
        client.replace(edit.inputRange, with: edit.corrected)
        return generation == version && pending != nil ? .pending : .unsafeFailure
    }

    public func beginUndo(client: any CorrectionProbeClient) -> Outcome {
        guard !busy, pending == nil, let edit = undoEdit else { return .passThrough }
        let version = generation
        undoEdit = nil
        guard matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client), generation == version else {
            return .passThrough
        }
        lastFailure = nil
        busy = true
        defer { busy = false }
        pending = Pending(edit: edit, phase: .undoText)
        effectSequence &+= 1
        client.replace(edit.correctedRange, with: edit.original)
        return generation == version && pending != nil ? .pending : .unsafeFailure
    }

    public func confirmPending(client: any CorrectionProbeClient, waitForEffects: Bool = false) -> Outcome {
        guard !busy, let current = pending else { return .passThrough }
        busy = true
        defer { busy = false }
        let edit = current.edit
        let version = generation
        func schedule(_ phase: Phase, _ effect: () -> Void) -> Outcome {
            guard generation == version else { return .unsafeFailure }
            pending = Pending(edit: edit, phase: phase)
            effectSequence &+= 1
            effect()
            return generation == version && pending != nil ? .pending : .unsafeFailure
        }
        func restoreLatin() -> Outcome {
            schedule(.restoreLatin) { client.replace(edit.correctedRange, with: edit.original + " ") }
        }
        switch current.phase {
        case .correctionText:
            if matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                return schedule(.correctionMode) { client.select(.hangul) }
            }
            if originalIsOwned(edit, client: client) {
                guard generation == version else { return .unsafeFailure }
                if waitForEffects { return .pending }
                lastFailure = .replacementIgnored
                if edit.inputHasBoundary { pending = nil; return .restoredOriginal }
                // The initial edit was rejected. Still deliver the consumed Space once.
                return schedule(.restoreLatin) { client.replace(edit.originalRange, with: edit.original + " ") }
            }
        case .correctionMode:
            if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                pending = nil; undoEdit = edit
                return .corrected
            }
            if matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                if waitForEffects { return .pending }
                lastFailure = .modeNotApplied
                return restoreLatin()
            }
        case .undoText:
            if matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                return schedule(.undoMode) { client.select(.latin) }
            }
            if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                if waitForEffects { return .pending }
                pending = nil
                lastFailure = .replacementIgnored
                return .restoredOriginal // Rejected undo; do not delete another character.
            }
        case .undoMode:
            if matches(edit.original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                pending = nil; rejected = edit
                return .undone
            }
            if matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                if waitForEffects { return .pending }
                lastFailure = .modeNotApplied
                return schedule(.restoreHangul) { client.replace(edit.originalRange, with: edit.corrected) }
            }
        case .restoreLatin:
            let range = NSRange(location: edit.location, length: edit.original.utf16.count + 1)
            if matches(edit.original + " ", at: range, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                pending = nil
                return .restoredOriginal
            }
            if waitForEffects, matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) {
                return .pending
            }
        case .restoreHangul:
            if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                pending = nil
                return .restoredOriginal
            }
            if waitForEffects, matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) {
                return .pending
            }
        }
        guard generation == version else { return .unsafeFailure }
        pending = nil
        lastFailure = lastFailure ?? .unexpectedResult
        return .unsafeFailure
    }

    /// A new key must never be queued behind this experiment. Keep an already
    /// confirmed result, or restore only an exact intermediate edit we own.
    /// Cancellation prevents subsequent observations from issuing any effects.
    public func interruptPending(client: any CorrectionProbeClient) -> Outcome {
        guard let current = pending else { return .passThrough }
        // A client query can reenter with a real key. Supersede the old
        // generation; it must not issue effects or clear a newer transaction.
        invalidate()
        busy = true
        defer { busy = false }
        let edit = current.edit
        let version = generation
        switch current.phase {
        case .correctionText, .correctionMode, .restoreLatin:
            if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                undoEdit = edit
                return .corrected
            }
            if matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                client.replace(edit.correctedRange, with: edit.original + " ")
                guard generation == version else { return .unsafeFailure }
                // Supersede a still arriving mode request before processing the key.
                if current.phase == .correctionMode { client.select(.latin) }
                return generation == version ? .restoredOriginal : .unsafeFailure
            }
            let range = NSRange(location: edit.location, length: edit.original.utf16.count + 1)
            if matches(edit.original + " ", at: range, mode: .latin, identity: edit.identity, client: client) {
                return .restoredOriginal
            }
        case .undoText, .undoMode, .restoreHangul:
            if matches(edit.original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                rejected = edit
                return .undone
            }
            if matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) {
                guard generation == version else { return .unsafeFailure }
                client.replace(edit.originalRange, with: edit.corrected)
                guard generation == version else { return .unsafeFailure }
                if current.phase == .undoMode { client.select(.hangul) }
                return generation == version ? .restoredOriginal : .unsafeFailure
            }
            if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
                return .restoredOriginal
            }
        }
        return .unsafeFailure
    }

    /// A word at a captured word start, as decided by the policy. Text and the
    /// boundary are replaced together; mode selection is verified separately
    /// because IMK provides no atomic text + mode transaction.
    public func correct(original: String, corrected: String, at location: Int, client: any CorrectionProbeClient) -> Outcome {
        guard !busy, pending == nil, !original.isEmpty, !corrected.isEmpty, location >= 0,
              location < Int.max - original.utf16.count else { return .passThrough }
        let edit = Edit(identity: client.identity, original: original, corrected: corrected + " ", location: location)
        undoEdit = nil
        if let rejected, rejected.identity == edit.identity, rejected.location == location,
           matches(original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) {
            self.rejected = nil
            return .passThrough
        }
        guard matches(original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) else {
            return .passThrough
        }
        busy = true
        defer { busy = false }
        let version = generation
        client.replace(edit.originalRange, with: edit.corrected)
        // A client rejecting the edit without changing anything can still handle Space.
        if matches(original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) {
            return .passThrough
        }
        guard generation == version,
              matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) else {
            return .unsafeFailure
        }
        client.select(.hangul)
        if generation == version,
           matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
            undoEdit = edit
            return .corrected
        }
        // Roll back only the exact edit we still own; never overwrite an external edit.
        guard generation == version, client.mode == .latin,
              matches(edit.corrected, at: edit.correctedRange, mode: .latin, identity: edit.identity, client: client) else {
            return .unsafeFailure
        }
        client.replace(edit.correctedRange, with: original + " ")
        let range = NSRange(location: location, length: original.utf16.count + 1)
        return generation == version && matches(original + " ", at: range, mode: .latin, identity: edit.identity, client: client)
            ? .restoredOriginal : .unsafeFailure
    }

    public func undo(client: any CorrectionProbeClient) -> Outcome {
        guard !busy, pending == nil, let edit = undoEdit else { return .passThrough }
        undoEdit = nil
        guard matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) else {
            return .passThrough
        }
        busy = true
        defer { busy = false }
        let version = generation
        client.replace(edit.correctedRange, with: edit.original)
        if matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client) {
            return .passThrough
        }
        guard generation == version,
              matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) else {
            return .unsafeFailure
        }
        client.select(.latin)
        if generation == version,
           matches(edit.original, at: edit.originalRange, mode: .latin, identity: edit.identity, client: client) {
            rejected = edit
            return .undone
        }
        guard generation == version, client.mode == .hangul,
              matches(edit.original, at: edit.originalRange, mode: .hangul, identity: edit.identity, client: client) else {
            return .unsafeFailure
        }
        client.replace(edit.originalRange, with: edit.corrected)
        return generation == version && matches(edit.corrected, at: edit.correctedRange, mode: .hangul, identity: edit.identity, client: client)
            ? .restoredOriginal : .unsafeFailure
    }
}
