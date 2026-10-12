import SwiftSyntax

/// 클래스·액터 안의 클로저가 `self`를 강하게 잡는지 검사한다(강한 참조 순환 후보).
///
/// 문법만 보므로 클로저가 실제로 저장되는지는 알 수 없다. 대신 저장되지 않거나 곧 끝나는 것이 분명한
/// 호출(`map`, `Task`, `DispatchQueue.async` 등)과 즉시 호출하는 클로저는 넘긴다. 호출은 이름과 함께
/// 받는 쪽(`queue.async`, `MainActor.run`)과 클로저 인자 레이블도 본다. 괄호·`try`·`await`·`as`로 감싼
/// 클로저 인자도 같게 본다. `[self]`·`[me = self]`처럼 캡처 목록에서 강하게 잡는 것도 self 캡처다.
/// 나머지는 `[weak self]`/`[unowned self]`를 쓰거나, self보다 오래 살 수 없는 이유를 적어
/// `// code-check:ignore strong-self <이유>`로 표시한다.
public enum StrongSelfCaptureCheck {
    public static let ignoreMarker = "code-check:ignore strong-self"

    /// 넘기는 호출이 받는 쪽(receiver)으로 무엇을 요구하는지. 이름만 같은 다른 함수를 넘기지 않도록 좁힌다.
    enum Receiver {
        /// 받는 쪽과 상관없다(`items.map`, `withUnsafePointer`).
        case any
        /// 받는 쪽 없이 부른다(`Task { }`, `Binding(get:set:)`).
        case noReceiver
        /// 큐: `DispatchQueue.main`·`DispatchQueue.global()`·`OperationQueue.main`처럼 큐 타입에서 시작하거나,
        /// `queue`·`self.workQueue`처럼 마지막 이름이 queue로 끝난다.
        case queue
        /// 이 타입에 직접 부른다(`MainActor.run`, `Task.detached`).
        case type(String)
    }

    /// 클로저를 저장하지 않는(non-escaping) 함수와, 한 번 실행하고 놓는 함수.
    static let allowedCallees: [String: Receiver] = {
        var table: [String: Receiver] = [:]
        // non-escaping
        for name in [
            "map", "flatMap", "compactMap", "filter", "forEach", "reduce", "contains", "first", "firstIndex",
            "last", "lastIndex", "allSatisfy", "sorted", "sort", "min", "max", "removeAll", "partition",
            "drop", "prefix", "split", "count", "mapValues", "compactMapValues", "merge", "merging",
            "withUnsafeBytes", "withUnsafeMutableBytes", "withUnsafePointer", "withUnsafeMutablePointer",
            "withUnsafeBufferPointer", "withUnsafeMutableBufferPointer", "withCString", "withExtendedLifetime",
            "withLock", "autoreleasepool", "assumeIsolated", "performAndWait",
            "withCheckedContinuation", "withCheckedThrowingContinuation", "withTaskGroup", "withThrowingTaskGroup",
            "withDiscardingTaskGroup", "withAnimation", "withTransaction"
        ] {
            table[name] = .any
        }
        // DispatchQueue.sync는 non-escaping, 나머지는 한 번 실행하고 놓는다.
        for name in ["sync", "async", "asyncAfter", "addOperation"] { table[name] = .queue }
        table["run"] = .type("MainActor")
        table["detached"] = .type("Task")
        table["runAnimationGroup"] = .type("NSAnimationContext")
        table["Task"] = .noReceiver
        // SwiftUI: the view owns the binding, the model does not keep it
        table["Binding"] = .noReceiver
        return table
    }()

    /// 위 함수들이 클로저 인자에 붙이는 레이블. 다른 레이블(`first(handler:)`)로 넘긴 클로저는 이름만 같은
    /// 다른 함수로 보고 넘기지 않는다. 레이블 없는 인자와 첫 후행 클로저는 볼 수 없으니 넘긴다.
    static let closureLabels: Set<String> = [
        "where", "by", "while", "whereSeparator", "uniquingKeysWith", "body", "operation", "execute",
        "get", "set", "invoking", "completionHandler"
    ]

    public static func run(on module: Module) -> [Finding] {
        let referenceTypes = module.referenceTypeNames
        return module.files.flatMap { file in
            let visitor = Visitor(file: file, referenceTypes: referenceTypes)
            visitor.walk(file.tree)
            return visitor.findings
        }
    }

    private final class Visitor: SyntaxVisitor {
        let file: Module.File
        let referenceTypes: Set<String>
        let lines: [Substring]
        var findings: [Finding] = []

        init(file: Module.File, referenceTypes: Set<String>) {
            self.file = file
            self.referenceTypes = referenceTypes
            lines = file.tree.description.split(separator: "\n", omittingEmptySubsequences: false)
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            if let owner = referenceTypeOwner(of: node),
               !isInStaticMember(node),
               capturesSelfStrongly(node) || (!capturesSelfWeakly(node) && !inheritsWeakSelf(node) && usesSelf(node)),
               !isAllowedContext(node),
               !isIgnored(node) {
                findings.append(Finding(
                    path: file.path,
                    line: file.line(of: node),
                    column: file.column(of: node),
                    message: "closure in '\(owner)' captures self strongly; use [weak self] or [unowned self], "
                        + "or mark it '// \(StrongSelfCaptureCheck.ignoreMarker) <reason>' if it cannot outlive self"
                ))
            }
            return .visitChildren
        }

        /// 클로저가 클래스·액터(또는 그 확장)에 속하면 그 이름.
        private func referenceTypeOwner(of node: ClosureExprSyntax) -> String? {
            guard let context = node.enclosingTypeContext else { return nil }
            if let decl = context.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = context.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = context.as(ExtensionDeclSyntax.self),
               let name = decl.extendedType.baseName, referenceTypes.contains(name) {
                return name
            }
            return nil
        }

        /// `static`·`class` 멤버의 self는 타입(메타타입)이라 순환이 생기지 않는다.
        private func isInStaticMember(_ node: ClosureExprSyntax) -> Bool {
            let context = node.enclosingTypeContext
            var current = node.parent
            while let parent = current, parent != context {
                let modifiers: DeclModifierListSyntax?
                if let function = parent.as(FunctionDeclSyntax.self) {
                    modifiers = function.modifiers
                } else if let variable = parent.as(VariableDeclSyntax.self) {
                    modifiers = variable.modifiers
                } else if let subscriptDecl = parent.as(SubscriptDeclSyntax.self) {
                    modifiers = subscriptDecl.modifiers
                } else {
                    modifiers = nil
                }
                if modifiers?.contains(where: { ["static", "class"].contains($0.name.text) }) == true { return true }
                current = parent.parent
            }
            return false
        }

        private func capturesSelfWeakly(_ node: ClosureExprSyntax) -> Bool {
            guard let items = node.signature?.capture?.items else { return false }
            return items.contains { item in
                guard let specifier = item.specifier?.specifier.text, ["weak", "unowned"].contains(specifier) else {
                    return false
                }
                return item.name.text == "self" || item.initializer?.value.trimmedDescription == "self"
            }
        }

        /// 바깥 클로저가 `[weak self]`·`[unowned self]`로 잡았고 `let self`로 다시 묶지 않았으면,
        /// 안쪽 클로저의 `self`는 그 약한 참조다.
        private func inheritsWeakSelf(_ node: ClosureExprSyntax) -> Bool {
            var current = node.parent
            while let parent = current {
                if let closure = parent.as(ClosureExprSyntax.self), capturesSelfWeakly(closure) {
                    let binder = SelfRebindingFinder(viewMode: .sourceAccurate)
                    binder.walk(closure.statements)
                    return !binder.found
                }
                current = parent.parent
            }
            return false
        }

        /// 캡처 목록이 `[self]`나 `[me = self]`로 self를 강하게 잡는다. 바깥 클로저가 약하게 잡았어도
        /// 그 값을 다시 강하게 잡으므로 강한 참조다.
        private func capturesSelfStrongly(_ node: ClosureExprSyntax) -> Bool {
            guard let items = node.signature?.capture?.items else { return false }
            return items.contains { item in
                guard item.specifier == nil else { return false }
                if let initializer = item.initializer { return initializer.value.trimmedDescription == "self" }
                return item.name.text == "self"
            }
        }

        /// 본문에서 `self`를 쓴다. 중첩 클로저는 따로 검사하므로 보지 않는다.
        private func usesSelf(_ node: ClosureExprSyntax) -> Bool {
            let finder = SelfReferenceFinder(viewMode: .sourceAccurate)
            finder.walk(node.statements)
            return finder.found
        }

        private func isAllowedContext(_ node: ClosureExprSyntax) -> Bool {
            let argument = Self.outermostWrapper(of: Syntax(node))
            var label: String?
            var argumentHost = argument.parent
            if let labeled = argumentHost?.as(LabeledExprSyntax.self) {
                label = labeled.label?.text
                argumentHost = argumentHost?.parent?.parent
            } else if let trailing = argumentHost?.as(MultipleTrailingClosureElementSyntax.self) {
                label = trailing.label.text
                argumentHost = argumentHost?.parent?.parent
            }
            guard let call = argumentHost?.as(FunctionCallExprSyntax.self) else { return false }
            // 즉시 호출: `{ ... }()`, `({ ... })()`
            if call.calledExpression.id == argument.id { return true }
            if let label, !StrongSelfCaptureCheck.closureLabels.contains(label) { return false }
            guard let callee = Self.calleeName(call.calledExpression),
                  let receiver = StrongSelfCaptureCheck.allowedCallees[callee] else { return false }
            return Self.accepts(receiver, call.calledExpression)
        }

        /// 클로저를 감싼 괄호·`try`·`await`·`as`를 벗어난 바깥 식.
        static func outermostWrapper(of node: Syntax) -> Syntax {
            var current = node
            while let parent = current.parent {
                if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) || parent.is(AsExprSyntax.self) {
                    current = parent
                } else if let list = parent.as(ExprListSyntax.self), let sequence = list.parent?.as(SequenceExprSyntax.self),
                          list.count == 3, list.first?.id == current.id,
                          list.dropFirst().first?.is(UnresolvedAsExprSyntax.self) == true {
                    // 접지 않은 `{ ... } as T`
                    current = Syntax(sequence)
                } else if let element = parent.as(LabeledExprSyntax.self), element.label == nil,
                          let list = element.parent?.as(LabeledExprListSyntax.self), list.count == 1,
                          let tuple = list.parent?.as(TupleExprSyntax.self) {
                    current = Syntax(tuple)
                } else {
                    break
                }
            }
            return current
        }

        static func calleeName(_ expression: ExprSyntax) -> String? {
            if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
            if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
            if let specialized = expression.as(GenericSpecializationExprSyntax.self) { return calleeName(specialized.expression) }
            return nil
        }

        static func accepts(_ receiver: Receiver, _ callee: ExprSyntax) -> Bool {
            let unspecialized = callee.as(GenericSpecializationExprSyntax.self)?.expression ?? callee
            let base = unspecialized.as(MemberAccessExprSyntax.self)?.base.map(receiverPath)
            switch receiver {
            case .any:
                return true
            case .noReceiver:
                return unspecialized.is(DeclReferenceExprSyntax.self)
            case .queue:
                guard let path = base else { return false }
                return ["DispatchQueue", "OperationQueue"].contains(path.first ?? "")
                    || path.last?.lowercased().hasSuffix("queue") == true
            case .type(let name):
                return base == [name]
            }
        }

        /// `DispatchQueue.global()`, `self.queue?`의 이름들(`["DispatchQueue", "global"]`, `["self", "queue"]`).
        /// 알 수 없는 식은 빈 배열.
        static func receiverPath(_ expression: ExprSyntax) -> [String] {
            if let reference = expression.as(DeclReferenceExprSyntax.self) { return [reference.baseName.text] }
            if let member = expression.as(MemberAccessExprSyntax.self) {
                return (member.base.map(receiverPath) ?? []) + [member.declName.baseName.text]
            }
            if let optional = expression.as(OptionalChainingExprSyntax.self) { return receiverPath(optional.expression) }
            if let unwrap = expression.as(ForceUnwrapExprSyntax.self) { return receiverPath(unwrap.expression) }
            if let specialized = expression.as(GenericSpecializationExprSyntax.self) { return receiverPath(specialized.expression) }
            if let call = expression.as(FunctionCallExprSyntax.self) { return receiverPath(call.calledExpression) }
            return []
        }

        /// 클로저가 시작하는 줄이나 바로 윗줄에 표시가 있다.
        private func isIgnored(_ node: ClosureExprSyntax) -> Bool {
            let line = file.line(of: node)
            return [line - 1, line - 2].contains { index in
                lines.indices.contains(index) && lines[index].contains(StrongSelfCaptureCheck.ignoreMarker)
            }
        }
    }

    /// `guard let self`, `if let self`, `let self = self`.
    private final class SelfRebindingFinder: SyntaxVisitor {
        var found = false

        override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
            if node.pattern.as(IdentifierPatternSyntax.self)?.identifier.tokenKind == .keyword(.self) { found = true }
            return .skipChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }
    }

    private final class SelfReferenceFinder: SyntaxVisitor {
        var found = false

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if node.baseName.tokenKind == .keyword(.self) { found = true }
            return found ? .skipChildren : .visitChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }
    }
}
