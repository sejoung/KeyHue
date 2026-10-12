import SwiftSyntax

/// 한 모듈 안에서 최상위 타입끼리 서로를 참조하는 순환을 찾는다.
///
/// 중첩 타입과 확장은 최상위 타입에 합친다. `#if` 안의 선언도 최상위로 본다(모든 분기).
/// 참조는 타입 이름과 대문자로 시작하는 식별자만 본다. 이름만 비교하므로, 그 자리에서 다른 것을 가리키는
/// 이름은 뺀다: 감싼 선언의 제네릭 인자, 참조하는 타입 안(확장 포함)에 선언된 중첩 타입·`typealias`·
/// `associatedtype`, `Foo.Bar`·`.Bar`의 멤버 이름.
/// 순환을 끊으려면 한쪽이 프로토콜·클로저에 의존하게 하거나(의존성 역전), 공통 부분을 새 타입으로 뺀다.
///
/// 끊을 수 없는 순환은 순환에 든 타입 선언 **모두**에 `// code-check:ignore dependency-cycle <이유>`를 단다.
/// 표시는 그 타입이 순환에 드는 것을 받아들인다는 뜻이다. 표시가 없는 타입이 하나라도 순환에 들면
/// (나중에 다른 타입이 순환에 합류한 경우 포함) 다시 보고하고, 표시가 없는 타입을 알려 준다.
/// 표시한 타입끼리만 이룬 순환은 넘긴다. 따로 받아들인 두 순환이 서로 이어져 하나가 되는 것은 잡지 못한다.
public enum TypeDependencyCheck {
    public static let ignoreMarker = "code-check:ignore dependency-cycle"

    struct Edge {
        let from: String
        let to: String
        let path: String
        let line: Int
    }

    public static func run(on module: Module) -> [Finding] {
        let files = module.files.map { ($0, topLevelItems(in: $0.tree.statements)) }
        let declarations = topLevelDeclarations(in: files)
        let names = Set(declarations.keys)
        let shadowed = locallyDeclaredNames(in: files, owners: names)
        var edges: [String: [String: Edge]] = [:]
        for (file, items) in files {
            for item in items {
                guard let (owner, body) = ownerAndBody(of: item), names.contains(owner) else { continue }
                let collector = ReferenceCollector(shadowed: shadowed[owner] ?? [])
                collector.walk(body)
                for reference in collector.references where reference.name != owner && names.contains(reference.name) {
                    if edges[owner, default: [:]][reference.name] == nil {
                        edges[owner, default: [:]][reference.name] = Edge(
                            from: owner, to: reference.name, path: file.path, line: file.line(of: reference.node)
                        )
                    }
                }
            }
        }

        return stronglyConnectedComponents(nodes: names.sorted(), edges: edges.mapValues { Array($0.keys).sorted() })
            .filter { $0.count > 1 }
            .compactMap { component in
                let unmarked = component.filter { declarations[$0]?.ignored != true }
                guard let first = unmarked.first, let declaration = declarations[first] else { return nil }
                let path = describeCycle(component, edges: edges)
                let partial = unmarked.count < component.count
                    ? "; not marked '// \(ignoreMarker)': \(unmarked.joined(separator: ", "))"
                    : ""
                return Finding(
                    path: declaration.path,
                    line: declaration.line,
                    column: 1,
                    message: "types depend on each other in '\(module.name)': \(path); "
                        + "make one side depend on a protocol or closure, or move the shared part into its own type"
                        + partial
                )
            }
    }

    struct Declaration {
        let path: String
        let line: Int
        let ignored: Bool
    }

    /// 파일의 최상위 항목. `#if` 블록은 모든 분기의 항목을 펼친다.
    static func topLevelItems(in statements: CodeBlockItemListSyntax) -> [CodeBlockItemSyntax.Item] {
        statements.flatMap { statement -> [CodeBlockItemSyntax.Item] in
            guard let ifConfig = statement.item.as(IfConfigDeclSyntax.self) else { return [statement.item] }
            return ifConfig.clauses.flatMap { clause -> [CodeBlockItemSyntax.Item] in
                guard case .statements(let inner)? = clause.elements else { return [] }
                return topLevelItems(in: inner)
            }
        }
    }

    private static func topLevelDeclarations(in files: [(Module.File, [CodeBlockItemSyntax.Item])]) -> [String: Declaration] {
        var result: [String: Declaration] = [:]
        for (file, items) in files {
            for item in items {
                guard let (name, _) = ownerAndBody(of: item), !item.is(ExtensionDeclSyntax.self) else { continue }
                let ignored = item.leadingTrivia.description.contains(ignoreMarker)
                    || (result[name]?.ignored ?? false)
                result[name] = Declaration(path: result[name]?.path ?? file.path, line: result[name]?.line ?? file.line(of: item), ignored: ignored)
            }
        }
        return result
    }

    /// 최상위 타입 선언이나 확장이면 (타입 이름, 살펴볼 노드).
    private static func ownerAndBody(of item: CodeBlockItemSyntax.Item) -> (String, Syntax)? {
        if let decl = item.as(ClassDeclSyntax.self) { return (decl.name.text, Syntax(decl)) }
        if let decl = item.as(StructDeclSyntax.self) { return (decl.name.text, Syntax(decl)) }
        if let decl = item.as(EnumDeclSyntax.self) { return (decl.name.text, Syntax(decl)) }
        if let decl = item.as(ActorDeclSyntax.self) { return (decl.name.text, Syntax(decl)) }
        if let decl = item.as(ProtocolDeclSyntax.self) { return (decl.name.text, Syntax(decl)) }
        // 확장한 타입 이름은 ReferenceCollector가 참조로 세지 않는다.
        if let decl = item.as(ExtensionDeclSyntax.self), let name = decl.extendedType.baseName { return (name, Syntax(decl)) }
        return nil
    }

    /// 최상위 타입마다, 그 안(확장 포함)에서는 다른 것을 가리키는 이름: 타입의 제네릭 인자와
    /// 안에 선언한 타입·`typealias`·`associatedtype`. 단순하게 하려고 중첩 타입 안의 타입이나 함수 안의
    /// 지역 타입도 최상위 타입 전체에서 가린다. 그래서 놓치는 참조가 있을 수 있지만 거짓 순환은 만들지 않는다.
    private static func locallyDeclaredNames(
        in files: [(Module.File, [CodeBlockItemSyntax.Item])], owners: Set<String>
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (_, items) in files {
            for item in items {
                guard let (owner, body) = ownerAndBody(of: item), owners.contains(owner),
                      let group = body.asProtocol(DeclGroupSyntax.self) else { continue }
                let collector = NestedDeclarationCollector(viewMode: .sourceAccurate)
                collector.walk(group.memberBlock)
                result[owner, default: []].formUnion(collector.names)
                if let generic = body.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause {
                    result[owner, default: []].formUnion(generic.parameters.map(\.name.text))
                }
                if let primary = body.as(ProtocolDeclSyntax.self)?.primaryAssociatedTypeClause {
                    result[owner, default: []].formUnion(primary.primaryAssociatedTypes.map(\.name.text))
                }
            }
        }
        return result
    }

    private static func describeCycle(_ component: [String], edges: [String: [String: Edge]]) -> String {
        // 순환 하나를 보여 준다: 첫 타입에서 출발해 구성 요소 안의 간선만 따라 처음으로 돌아온다.
        let members = Set(component)
        let start = component[0]
        var path: [Edge] = []
        var visited: Set<String> = []
        func search(_ node: String) -> Bool {
            for next in (edges[node] ?? [:]).keys.sorted() where members.contains(next) {
                let edge = edges[node]![next]!
                if next == start { path.append(edge); return true }
                guard !visited.contains(next) else { continue }
                visited.insert(next)
                path.append(edge)
                if search(next) { return true }
                path.removeLast()
            }
            return false
        }
        _ = search(start)
        let steps = path.map { "\($0.from) -> \($0.to) (\(shortPath($0.path)):\($0.line))" }
        let extra = component.count > path.count ? " [cycle group: \(component.joined(separator: ", "))]" : ""
        return steps.joined(separator: ", ") + extra
    }

    private static func shortPath(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Tarjan. 결과는 각 구성 요소 안에서 이름순, 구성 요소끼리는 첫 이름순.
    static func stronglyConnectedComponents(nodes: [String], edges: [String: [String]]) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var onStack: Set<String> = []
        var result: [[String]] = []

        func connect(_ node: String) {
            indices[node] = index
            lowLinks[node] = index
            index += 1
            stack.append(node)
            onStack.insert(node)
            for next in edges[node] ?? [] {
                if indices[next] == nil {
                    connect(next)
                    lowLinks[node] = min(lowLinks[node]!, lowLinks[next]!)
                } else if onStack.contains(next) {
                    lowLinks[node] = min(lowLinks[node]!, indices[next]!)
                }
            }
            if lowLinks[node] == indices[node] {
                var component: [String] = []
                while let top = stack.popLast() {
                    onStack.remove(top)
                    component.append(top)
                    if top == node { break }
                }
                result.append(component.sorted())
            }
        }

        for node in nodes where indices[node] == nil { connect(node) }
        return result.sorted { $0[0] < $1[0] }
    }

    private struct Reference {
        let name: String
        let node: Syntax
    }

    private final class ReferenceCollector: SyntaxVisitor {
        let shadowed: Set<String>
        var references: [Reference] = []

        init(shadowed: Set<String>) {
            self.shadowed = shadowed
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            record(node.name.text, at: Syntax(node))
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            // `Foo.Bar`, `.Bar`의 `Bar`는 멤버 이름이다.
            if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
                return .visitChildren
            }
            let name = node.baseName.text
            if let first = name.first, first.isUppercase {
                record(name, at: Syntax(node))
            }
            return .visitChildren
        }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            // 확장한 타입 이름은 참조로 세지 않는다.
            if let inheritance = node.inheritanceClause { walk(inheritance) }
            if let generic = node.genericWhereClause { walk(generic) }
            walk(node.memberBlock)
            return .skipChildren
        }

        private func record(_ name: String, at node: Syntax) {
            guard !shadowed.contains(name), !isGenericParameter(name, at: node) else { return }
            references.append(Reference(name: name, node: node))
        }

        /// 감싼 함수·생성자·서브스크립트·타입의 제네릭 인자 이름이다.
        private func isGenericParameter(_ name: String, at node: Syntax) -> Bool {
            var current = node.parent
            while let ancestor = current {
                if let clause = ancestor.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause,
                   clause.parameters.contains(where: { $0.name.text == name }) {
                    return true
                }
                current = ancestor.parent
            }
            return false
        }
    }

    /// 타입 안에 선언한 타입·`typealias`·`associatedtype` 이름.
    private final class NestedDeclarationCollector: SyntaxVisitor {
        var names: Set<String> = []

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }
        override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind { insert(node.name) }

        private func insert(_ name: TokenSyntax) -> SyntaxVisitorContinueKind {
            names.insert(name.text)
            return .visitChildren
        }
    }
}
