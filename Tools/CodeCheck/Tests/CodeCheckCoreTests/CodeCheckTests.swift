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

    @Test func strongAliasInCaptureListIsReported() {
        let result = findings("""
        final class Owner {
            var a: (() -> Void)?
            var b: (() -> Void)?
            var c: (() -> Void)?
            func start() {
                a = { [me = self] in me.tick() }
                b = { [weak me = self] in me?.tick() }
                register { [weak self] in
                    self?.c = { [self] in self?.tick() }
                }
            }
            func tick() {}
            func register(_ body: @escaping () -> Void) {}
        }
        """)
        // `[weak self]` 안에서도 `[self]`는 그 값을 강하게 잡는다.
        #expect(result.map(\.line) == [6, 9])
    }

    @Test func allowedCallsAreJudgedByReceiverAndLabel() {
        let accepted = findings("""
        final class Owner {
            let queue = DispatchQueue(label: "q")
            let workQueue = OperationQueue()
            func start() async {
                queue.async { [self] in tick() }
                queue.sync { self.tick() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()) { self.tick() }
                workQueue.addOperation { self.tick() }
                await MainActor.run { self.tick() }
                Task.detached { await self.tick() }
                _ = [1].first(where: { _ in self.ready })
            }
            var ready: Bool { true }
            func tick() {}
        }
        """)
        #expect(accepted.isEmpty)
        let rejected = findings("""
        final class Owner {
            let scheduler = Scheduler()
            let worker = Worker()
            func start() {
                scheduler.async { self.tick() }
                self.sync { self.tick() }
                worker.run { self.tick() }
                worker.Task { self.tick() }
                _ = worker.first(handler: { self.tick() })
            }
            func tick() {}
        }
        """)
        #expect(rejected.map(\.line) == [5, 6, 7, 8, 9])
    }

    @Test func wrappedClosureArgumentsAreSeenThrough() {
        let result = findings("""
        final class Owner {
            var items: [Int] = []
            var handler: (() -> Void)?
            func start() async throws {
                _ = items.map(({ self.double($0) }))
                DispatchQueue.main.async(execute: { self.tick() } as @convention(block) () -> Void)
                let value = ({ self.items.count })()
                _ = value
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.tick()
                    continuation.resume()
                }
                _ = try items.map(try { try self.risky($0) })
                handler = ({ self.tick() })
            }
            func double(_ x: Int) -> Int { x * 2 }
            func risky(_ x: Int) throws -> Int { x }
            func tick() {}
        }
        """)
        #expect(result.map(\.line) == [14])
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

    @Test func markerOnEveryDeclarationSilencesItsCycle() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "// code-check:ignore dependency-cycle generated pair\nstruct A { var b: B? }",
            "B.swift": "// code-check:ignore dependency-cycle generated pair\nstruct B { var a: [A] }"
        ]))
        #expect(result.isEmpty)
    }

    @Test func markerOnOneDeclarationDoesNotSilenceTheCycle() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "// code-check:ignore dependency-cycle generated pair\nstruct A { var b: B? }",
            "B.swift": "struct B { var a: [A] }"
        ]))
        #expect(result.map(\.path) == ["B.swift"])
        #expect(result.first?.message.contains("not marked '// code-check:ignore dependency-cycle': B") == true)
    }

    @Test func typeJoiningAnAcceptedCycleIsReported() {
        // A·B 순환은 받아들였다. 나중에 C가 B -> C -> A로 순환에 들어오면 C를 알려 준다.
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "// code-check:ignore dependency-cycle generated pair\nstruct A { var b: B? }",
            "B.swift": "// code-check:ignore dependency-cycle generated pair\nstruct B { var a: [A]; var c: C? }",
            "C.swift": "struct C { var a: A? }"
        ]))
        #expect(result.map(\.path) == ["C.swift"])
        #expect(result.first?.message.contains("[cycle group: A, B, C]") == true
            || result.first?.message.contains("C -> A") == true)
        #expect(result.first?.message.hasSuffix("not marked '// code-check:ignore dependency-cycle': C") == true)
    }

    @Test func declarationsInsideIfConfigAreSeen() {
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": "#if DEBUG\nstruct A { var b: B? }\n#else\n#if os(macOS)\nextension B { var a: A? { nil } }\n#endif\n#endif",
            "B.swift": "struct B {}"
        ]))
        #expect(result.count == 1)
        #expect(result.first?.message.contains("A -> B (A.swift:2)") == true)
        #expect(result.first?.message.contains("B -> A (A.swift:5)") == true)
    }

    @Test func genericParametersAndNestedNamesAreNotReferences() {
        // B를 참조하는 것처럼 보이지만 모두 A 안의 다른 B다: 제네릭 인자, 중첩 타입, typealias, 멤버 이름.
        let result = TypeDependencyCheck.run(on: module([
            "A.swift": """
            struct Box<B> { var value: B }
            struct Maker { func make<B>(_ value: B) -> B { value } }
            struct Holder { enum B { case one } var b: B = .one }
            struct Alias { typealias B = Int; var b: B = 0 }
            extension Holder { func again() -> B { .one } }
            protocol Store { associatedtype B; var b: B { get } }
            enum Member { static func make() -> Int { Other.B + 1 } }
            """,
            "B.swift": """
            struct B { var all: (Box<Int>, Maker, Holder, Alias, Member)? }
            enum Other { static let B = 1 }
            """,
            "C.swift": "extension B: Store { var b: Int { 0 } }"
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
