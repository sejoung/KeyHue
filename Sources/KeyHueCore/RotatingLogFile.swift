import Foundation

/// 진단 로그 파일(ADR 0036). 문제가 난 뒤에 무슨 일이 있었는지 확인하려고 남긴다.
///
/// - 한 줄 형식: `2026-09-30 10:12:03.123 notice [State] 메시지`
/// - 크기가 `maxBytes`를 넘으면 `KeyHue.log` → `KeyHue.1.log` → `KeyHue.2.log`로 밀어내고 최근 `keep`개만 남긴다.
/// - 쓰기는 전용 직렬 큐에서 한다. 입력 소스 전환 같은 메인 스레드 흐름을 파일 I/O로 막지 않는다.
public final class RotatingLogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "KeyHue.RotatingLogFile", qos: .utility)
    // 아래는 queue에서만 만진다.
    private var handle: FileHandle?
    private var size = 0
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// - Parameters:
    ///   - maxBytes: 파일 하나의 최대 크기. 넘으면 다음 줄부터 새 파일에 쓴다.
    ///   - keep: 현재 파일을 포함해 남길 파일 수.
    public init(url: URL, maxBytes: Int = 1_000_000, keep: Int = 3) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
    }

    deinit {
        try? handle?.close()
    }

    public func write(_ message: String, level: String, category: String, date: Date = Date()) {
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) \(level) [\(category)] \(message)\n"
            append(Data(line.utf8))
        }
    }

    /// 지금까지 요청한 쓰기가 끝날 때까지 기다린다(테스트, 종료 직전).
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// 돌려 쓴 파일까지 포함한 경로. 오래된 것이 뒤에 온다.
    public var allFiles: [URL] {
        (0..<keep).map(fileURL(index:))
    }

    // MARK: queue 전용

    private func append(_ data: Data) {
        if handle == nil {
            open()
        }
        if size > 0, size + data.count > maxBytes {
            rotate()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            // 디스크가 가득 찼거나 파일이 지워졌다. 다음 쓰기에서 다시 연다.
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: fileURL(index: keep - 1))
        if keep > 1 {
            for index in stride(from: keep - 2, through: 0, by: -1) {
                try? manager.moveItem(at: fileURL(index: index), to: fileURL(index: index + 1))
            }
        }
        open()
    }

    /// 0 = 현재 파일(KeyHue.log), 1 = KeyHue.1.log …
    private func fileURL(index: Int) -> URL {
        guard index > 0 else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(index).\(url.pathExtension)")
    }
}
