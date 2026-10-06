import SwiftSyntax

/// 클래스·액터 안의 클로저가 `self`를 강하게 잡는지 검사한다(강한 참조 순환 후보).
///
/// 문법만 보므로 클로저가 실제로 저장되는지는 알 수 없다. 대신 저장되지 않거나 곧 끝나는 것이 분명한
/// 호출(`map`, `Task`, `DispatchQueue.async` 등)과 즉시 호출하는 클로저는 넘긴다. 나머지는
/// `[weak self]`/`[unowned self]`를 쓰거나, self보다 오래 살 수 없는 이유를 적어
/// `// code-check:ignore strong-self <이유>`로 표시한다.
public enum StrongSelfCaptureCheck {
    public static let ignoreMarker = "code-check:ignore strong-self"

    /// 클로저를 저장하지 않는(non-escaping) 함수와, 한 번 실행하고 놓는 함수.
    static let allowedCallees: Set<String> = [
        // non-escaping
        "map", "flatMap", "compactMap", "filter", "forEach", "reduce", "contains", "first", "firstIndex",
        "last", "lastIndex", "allSatisfy", "sorted", "sort", "min", "max", "removeAll", "partition",
        "drop", "prefix", "split", "count", "mapValues", "compactMapValues", "merge", "merging",
        "withUnsafeBytes", "withUnsafeMutableBytes", "withUnsafePointer", "withUnsafeMutablePointer",
        "withUnsafeBufferPointer", "withUnsafeMutableBufferPointer", "withCString", "withExtendedLifetime",
        "withLock", "autoreleasepool", "assumeIsolated", "sync", "performAndWait", "run",
        "withCheckedContinuation", "withCheckedThrowingContinuation", "withTaskGroup", "withThrowingTaskGroup",
        "withDiscardingTaskGroup", "withAnimation", "withTransaction",
        // runs once and releases the closure
        "Task", "detached", "async", "asyncAfter", "runAnimationGroup", "addOperation",
        // SwiftUI: the view owns the binding, the model does not keep it
        "Binding"
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
               !capturesSelfWeakly(node),
               !inheritsWeakSelf(node),
               capturesSelf(node),
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

        /// 본문에서 `self`를 쓰거나 `[self]`로 잡는다. 중첩 클로저는 따로 검사하므로 보지 않는다.
        private func capturesSelf(_ node: ClosureExprSyntax) -> Bool {
            if node.signature?.capture?.items.contains(where: { $0.specifier == nil && $0.name.text == "self" }) == true {
                return true
            }
            let finder = SelfReferenceFinder(viewMode: .sourceAccurate)
            finder.walk(node.statements)
            return finder.found
        }

        private func isAllowedContext(_ node: ClosureExprSyntax) -> Bool {
            var argumentHost: Syntax? = node.parent
            if argumentHost?.is(LabeledExprSyntax.self) == true { argumentHost = argumentHost?.parent?.parent }
            else if argumentHost?.is(MultipleTrailingClosureElementSyntax.self) == true { argumentHost = argumentHost?.parent?.parent }
            guard let call = argumentHost?.as(FunctionCallExprSyntax.self) else { return false }
            // 즉시 호출: `{ ... }()`
            if call.calledExpression.is(ClosureExprSyntax.self) { return true }
            guard let callee = Self.calleeName(call.calledExpression) else { return false }
            return StrongSelfCaptureCheck.allowedCallees.contains(callee)
        }

        static func calleeName(_ expression: ExprSyntax) -> String? {
            if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
            if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
            if let specialized = expression.as(GenericSpecializationExprSyntax.self) { return calleeName(specialized.expression) }
            return nil
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
