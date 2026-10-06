import Foundation
import SwiftParser
import SwiftSyntax

/// 한 모듈(SwiftPM 타깃)의 파싱된 소스 파일들.
public struct Module {
    public struct File {
        public let path: String
        public let tree: SourceFileSyntax
        let converter: SourceLocationConverter

        public init(path: String, source: String) {
            self.path = path
            tree = Parser.parse(source: source)
            converter = SourceLocationConverter(fileName: path, tree: tree)
        }

        func line(of node: some SyntaxProtocol) -> Int {
            node.startLocation(converter: converter).line
        }

        func column(of node: some SyntaxProtocol) -> Int {
            node.startLocation(converter: converter).column
        }
    }

    public let name: String
    public let files: [File]

    public init(name: String, files: [File]) {
        self.name = name
        self.files = files
    }

    /// 디렉터리 아래의 모든 .swift 파일을 읽는다. 순서는 경로순이라 결과가 매번 같다.
    public static func load(name: String, directory: String) throws -> Module {
        let root = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory])
        }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            paths.append(url.path)
        }
        let files = try paths.sorted().map { path in
            File(path: path, source: try String(contentsOfFile: path, encoding: .utf8))
        }
        return Module(name: name, files: files)
    }

    /// 이 모듈에서 선언한 클래스와 액터 이름(중첩 포함). 확장이 참조 타입인지 판단하는 데 쓴다.
    var referenceTypeNames: Set<String> {
        var names: Set<String> = []
        for file in files {
            let collector = ReferenceTypeCollector(viewMode: .sourceAccurate)
            collector.walk(file.tree)
            names.formUnion(collector.names)
        }
        return names
    }
}

/// `path:line:column: error: message` 형식으로 출력되는 검사 결과.
public struct Finding: Equatable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let column: Int
    public let message: String

    public var description: String { "\(path):\(line):\(column): error: \(message)" }
}

private final class ReferenceTypeCollector: SyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}

extension SyntaxProtocol {
    /// 이 노드를 감싼 가장 가까운 타입 선언 또는 확장.
    var enclosingTypeContext: Syntax? {
        var current = parent
        while let node = current {
            if node.is(ClassDeclSyntax.self) || node.is(ActorDeclSyntax.self) || node.is(StructDeclSyntax.self)
                || node.is(EnumDeclSyntax.self) || node.is(ProtocolDeclSyntax.self) || node.is(ExtensionDeclSyntax.self) {
                return node
            }
            current = node.parent
        }
        return nil
    }
}

extension TypeSyntax {
    /// `Foo`, `Foo<Bar>`, `Outer.Inner`의 맨 앞 이름.
    var baseName: String? {
        if let identifier = self.as(IdentifierTypeSyntax.self) { return identifier.name.text }
        if let member = self.as(MemberTypeSyntax.self) { return member.baseType.baseName }
        return nil
    }
}
