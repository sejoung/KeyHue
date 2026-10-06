import Testing
@testable import CodeCheckCore

private func module(_ sources: [String: String]) -> Module {
    Module(name: "Sample", files: sources.sorted { $0.key < $1.key }.map { Module.File(path: $0.key, source: $0.value) })
}

@Suite("Strong self capture")
struct StrongSelfCaptureTests {
    private func findings(_ source: String) -> [Finding] {
        StrongSelfCaptureCheck.run(on: module(["A.swift": source]))
    }

    @Test func storedClosureCapturingSelfIsReported() {
        let result = findings("""
        final class Owner {
            var handler: (() -> Void)?
            func start() {
                handler = { self.tick() }
            }
            func tick() {}
        }
        """)
        #expect(result.map(\.line) == [4])
        #expect(result.first?.message.contains("'Owner'") == true)
    }

    @Test func explicitStrongCaptureListIsReported() {
        let result = findings("""
        final class Owner {
            var handler: (() -> Void)?
            func start() { handler = { [self] in tick() } }
            func tick() {}
        }
        """)
        #expect(result.count == 1)
    }

    @Test func weakOrUnownedSelfIsAccepted() {
        let result = findings("""
        final class Owner {
            var a: (() -> Void)?
            var b: (() -> Void)?
            func start() {
                a = { [weak self] in self?.tick() }
                b = { [unowned self] in self.tick() }
            }
            func tick() {}
        }
        """)
        #expect(result.isEmpty)
    }

    @Test func nonEscapingAndOneShotCallsAreAccepted() {
        let result = findings("""
        final class Owner {
            var items: [Int] = []
            func start() {
                _ = items.map { self.double($0) }
                Task { self.tick() }
                DispatchQueue.main.async { self.tick() }
                let value = { self.items.count }()
                _ = value
            }
            func double(_ x: Int) -> Int { x * 2 }
            func tick() {}
        }
        """)
        #expect(result.isEmpty)
    }

    @Test func valueTypesAndStaticMembersAreIgnored() {
        let result = findings("""
        struct Value {
            var handler: (() -> Void)?
            mutating func start() { let copy = self; handler = { _ = copy; _ = self } }
        }
        final class Owner {
            static var make: () -> Owner = { self.init() }
            required init() {}
        }
        """)
        #expect(result.isEmpty)
    }

    @Test func extensionOfAClassIsChecked() {
        let result = StrongSelfCaptureCheck.run(on: module([
            "A.swift": "final class Owner { var handler: (() -> Void)? }",
            "B.swift": "extension Owner { func start() { handler = { self.start() } } }"
        ]))
        #expect(result.map(\.path) == ["B.swift"])
    }

    @Test func nestedClosuresAreJudgedOnTheirOwn() {
        // 바깥 클로저는 [weak self]로 self를 쓰지 않는다. 안쪽 클로저가 따로 self를 강하게 잡는다.
        let result = findings("""
        final class Owner {
            var handler: (() -> Void)?
            func start() {
                register { [weak self] in
                    self?.handler = { self?.start() }
                }
                register {
                    print("no self")
                }
            }
            func register(_ body: @escaping () -> Void) {}
        }
        """)
        #expect(result.isEmpty)
        let inner = findings("""
        final class Owner {
            var handler: (() -> Void)?
            func start() {
                register { [weak self] in
                    guard let self else { return }
                    self.handler = { self.start() }
                }
            }
            func register(_ body: @escaping () -> Void) {}
        }
        """)
        #expect(inner.map(\.line) == [6])
    }

    @Test func markerWithReasonSilencesTheFinding() {
        let result = findings("""
        final class Owner {
            var handler: (() -> Void)?
            func start() {
                // code-check:ignore strong-self the handler is cleared in stop()
                handler = { self.tick() }
            }
            func tick() {}
        }
        """)
        #expect(result.isEmpty)
    }
}

@Suite("Type dependency cycles")
struct TypeDependencyTests {
    @Test func mutualReferenceIsReported() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "struct A { var b: B? }",
            "B.swift": "struct B { func make() -> A { A() } }"
        ]))
        #expect(result.count == 1)
        #expect(result.first?.message.contains("A -> B (A.swift:1)") == true)
        #expect(result.first?.message.contains("B -> A (B.swift:1)") == true)
    }

    @Test func dependingOnAProtocolBreaksTheCycle() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "final class Controller { weak var actions: Actions? }",
            "B.swift": "protocol Actions: AnyObject { func run() }",
            "C.swift": "final class App { let controller = Controller() }\nextension App: Actions { func run() {} }"
        ]))
        #expect(result.isEmpty)
    }

    @Test func nestedTypesAndExtensionsBelongToTheirTopLevelType() {
        // Outer.Inner -> Outer는 같은 타입 안이다. 확장에서 Other를 쓰고 Other가 Outer를 쓰면 순환이다.
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "struct Outer { struct Inner { var outer: Outer? } }",
            "B.swift": "extension Outer { var other: Other? { nil } }",
            "C.swift": "struct Other { var inner: Outer.Inner? }"
        ]))
        #expect(result.count == 1)
    }

    @Test func extendingATypeIsNotAReferenceToIt() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "struct A { var b: B? }",
            "B.swift": "struct B {}\nextension A { func hello() {} }"
        ]))
        #expect(result.isEmpty)
    }

    @Test func markerOnADeclarationSilencesItsCycle() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "// code-check:ignore dependency-cycle generated pair\nstruct A { var b: B? }",
            "B.swift": "struct B { var a: [A] }"
        ]))
        #expect(result.isEmpty)
    }

    @Test func componentsAreFoundWithTarjan() {
        let components = TypeDependencyCheck.stronglyConnectedComponents(
            nodes: ["A", "B", "C", "D"],
            edges: ["A": ["B"], "B": ["C"], "C": ["A"], "D": ["A"]]
        )
        #expect(components == [["A", "B", "C"], ["D"]])
    }
}
