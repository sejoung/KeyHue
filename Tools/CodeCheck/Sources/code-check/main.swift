import CodeCheckCore
import Foundation

// 사용법: code-check <모듈 이름>=<디렉터리> ...
// 클래스 클로저의 강한 self 캡처와 모듈 안 타입 간 의존 순환을 검사한다(ADR 0080).
let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: code-check <Module>=<directory> ...\n".utf8))
    exit(2)
}

var findings: [Finding] = []
for argument in arguments {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
        FileHandle.standardError.write(Data("invalid argument '\(argument)': expected <Module>=<directory>\n".utf8))
        exit(2)
    }
    do {
        let module = try Module.load(name: parts[0], directory: parts[1])
        findings += StrongSelfCaptureCheck.run(on: module)
        findings += TypeDependencyCheck.run(on: module)
    } catch {
        FileHandle.standardError.write(Data("cannot read \(parts[1]): \(error)\n".utf8))
        exit(2)
    }
}

findings.forEach { print($0) }
print(findings.isEmpty ? "code-check: ok" : "code-check: \(findings.count) problem(s)")
exit(findings.isEmpty ? 0 : 1)
