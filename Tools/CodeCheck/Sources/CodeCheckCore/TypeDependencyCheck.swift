import SwiftSyntax

/// 한 모듈 안에서 최상위 타입끼리 서로를 참조하는 순환을 찾는다.
///
/// 중첩 타입과 확장은 최상위 타입에 합친다. 참조는 타입 이름과 대문자로 시작하는 식별자만 본다.
/// 순환을 끊으려면 한쪽이 프로토콜·클로저에 의존하게 하거나(의존성 역전), 공통 부분을 새 타입으로 뺀다.
/// 끊을 수 없는 순환은 관련된 타입 선언 중 하나에 `// code-check:ignore dependency-cycle <이유>`를 단다.
public enum TypeDependencyCheck {
    public static let ignoreMarker = "code-check:ignore dependency-cycle"

    struct Edge {
        let from: String
        let to: String
        let path: String
        let line: Int
    }

    public static func run(on module: Module) -> [Finding] {
        let declarations = topLevelDeclarations(in: module)
        let names = Set(declarations.keys)
        var edges: [String: [String: Edge]] = [:]
        for file in module.files {
            for statement in file.tree.statements {
                guard let (owner, body) = ownerAndBody(of: statement.item), names.contains(owner) else { continue }
                let collector = ReferenceCollector(viewMode: .sourceAccurate)
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
            .filter { component in !component.contains { declarations[$0]?.ignored == true } }
            .map { component in
                let first = component[0]
                let declaration = declarations[first]!
                let path = describeCycle(component, edges: edges)
                return Finding(
                    path: declaration.path,
                    line: declaration.line,
                    column: 1,
                    message: "types depend on each other in '\(module.name)': \(path); "
                        + "make one side depend on a protocol or closure, or move the shared part into its own type"
                )
            }
    }

    struct Declaration {
        let path: String
        let line: Int
        let ignored: Bool
    }

    private static func topLevelDeclarations(in module: Module) -> [String: Declaration] {
        var result: [String: Declaration] = [:]
        for file in module.files {
            for statement in file.tree.statements {
                let item = statement.item
                let name: String?
                if let decl = item.as(ClassDeclSyntax.self) { name = decl.name.text }
                else if let decl = item.as(StructDeclSyntax.self) { name = decl.name.text }
                else if let decl = item.as(EnumDeclSyntax.self) { name = decl.name.text }
                else if let decl = item.as(ActorDeclSyntax.self) { name = decl.name.text }
                else if let decl = item.as(ProtocolDeclSyntax.self) { name = decl.name.text }
                else { name = nil }
                guard let name else { continue }
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
        var references: [Reference] = []

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            references.append(Reference(name: node.name.text, node: Syntax(node)))
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.baseName.text
            if let first = name.first, first.isUppercase {
                references.append(Reference(name: name, node: Syntax(node)))
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
    }
}
