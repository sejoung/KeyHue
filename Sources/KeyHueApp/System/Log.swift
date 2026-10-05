import Foundation
import KeyHueCore
import os

/// KeyHue 로그(ADR 0036). 문제가 난 **뒤에** 무슨 일이 있었는지 확인할 수 있게 남긴다.
///
/// - `notice`, `error`: 통합 로그(subsystem "KeyHue", 디스크에 남음)와 로그 파일(`~/Library/Logs/KeyHue/KeyHue.log`)에 함께 쓴다.
///   앱 활성화, 창 전환, 입력 소스 변경, 자동 전환 결과, 권한·설정 변경처럼 원인을 좇을 때 필요한 것.
/// - `debug`: 통합 로그에만. 자주 일어나는 세부 사항이라 `log stream --level debug`로 볼 때만 보인다.
///
/// 남기지 않는 것: 입력한 글자, ESC 외의 키, 창 제목, 텍스트 내용. 앱 번들 ID와 입력 소스 ID는 남는다.
struct Log {
    static let subsystem = "KeyHue"

    static let app = Log("App")
    static let state = Log("State")
    static let accessibility = Log("Accessibility")
    static let keyboard = Log("Keyboard")
    static let inputSource = Log("InputSource")
    static let loginItem = Log("LoginItem")

    /// ~/Library/Logs는 콘솔 앱의 "로그 보고서"에도 보인다.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KeyHue", isDirectory: true)
        .appendingPathComponent("KeyHue.log")

    /// 설치된 앱으로 실행될 때만 파일에 쓴다. 테스트·스크린샷 렌더링이 사용자 로그를 채우지 않게 한다.
    // Short-lived workers use unified logging; two independent writers must not
    // rotate/write the utility's file concurrently. Their result is logged by it.
    static let file: RotatingLogFile? = writesFile(bundleID: Bundle.main.bundleIdentifier,
                                                   arguments: Array(CommandLine.arguments.dropFirst()))
        ? RotatingLogFile(url: fileURL)
        : nil

    /// 설치된 앱 본체만 파일에 쓴다. 테스트 실행기·내부 작업 프로세스는 쓰지 않는다.
    static func writesFile(bundleID: String?, arguments: [String]) -> Bool {
        bundleID == "io.github.sejoung.keyhue" && !WorkerCommand.isWorker(arguments)
    }

    let category: String
    private let logger: Logger

    private init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        Self.file?.write(message, level: "notice", category: category)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Self.file?.write(message, level: "error", category: category)
    }
}
