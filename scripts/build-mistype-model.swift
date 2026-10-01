// 한국어 위키백과 덤프(표준 입력, XML)로 음절 bigram 모델을 만든다(ADR 0041). scripts/build-mistype-model.sh가 사용한다.
//
//   bunzip2 -c kowiki-…-pages-articles1.xml-….bz2 | build-mistype-model <출력.tsv> <최소 bigram 횟수>
//
// - 일반 문서(ns 0)의 본문만 쓴다. 틀·표·분류·파일 줄은 건너뛰고, 링크·굵게·태그 같은 위키 문법을 걷어 낸다.
// - 단어는 측정과 같은 규칙(MistypeText.words)으로 뽑는다.
// - 드문 bigram은 버려 앱에 넣을 크기로 줄인다(unigram은 모두 남는다).
import Foundation

func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
}

/// 위키 문법을 걷어 낸다. 순서가 중요하다(안쪽 틀 → 링크 → 태그 → 엔티티).
let replacements: [(NSRegularExpression, String)] = [
    (regex("&lt;ref[^&]*?/&gt;"), " "),
    (regex("&lt;ref.*?&lt;/ref&gt;"), " "),
    (regex("&lt;!--.*?--&gt;"), " "),
    (regex("&lt;[^&]*?&gt;"), " "),
    (regex("\\{\\{[^{}]*\\}\\}"), " "),
    (regex("\\[\\[[^\\]|]*\\|([^\\]]*)\\]\\]"), "$1"),
    (regex("\\[\\[([^\\]]*)\\]\\]"), "$1"),
    (regex("\\[https?://[^ \\]]* ?([^\\]]*)\\]"), "$1"),
    (regex("'{2,}"), ""),
    (regex("&(quot|amp|nbsp|lt|gt);"), " ")
]

func clean(_ line: String) -> String? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    for prefix in ["{{", "|", "!", "{|", "|}", "[[분류:", "[[파일:", "[[File:", "*[[", "&lt;"] where trimmed.hasPrefix(prefix) {
        return nil
    }
    var text = String(trimmed)
    for (pattern, template) in replacements where text.contains(where: { "&[{'".contains($0) }) {
        text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    return text
}

@main
struct BuildMistypeModel {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let minimumBigramCount = Int(arguments[2]) else {
            FileHandle.standardError.write("사용법: build-mistype-model <출력.tsv> <최소 bigram 횟수>\n".data(using: .utf8)!)
            exit(2)
        }

        var model = HangulSyllableModel()
        var isArticle = false
        var inText = false
        var pages = 0
        var words = 0

        while let raw = readLine() {
            if raw.hasPrefix("    <ns>") {
                isArticle = raw == "    <ns>0</ns>"
                continue
            }
            var line = Substring(raw)
            if !inText {
                guard let start = line.range(of: "<text ") else { continue }
                guard let close = line[start.upperBound...].firstIndex(of: ">") else { continue }
                // 빈 문서는 <text … /> 한 줄로 끝난다.
                guard line[..<close].last != "/" else { continue }
                line = line[line.index(after: close)...]
                inText = true
                if isArticle { pages += 1 }
            }
            if let end = line.range(of: "</text>") {
                line = line[..<end.lowerBound]
                inText = false
            }
            guard isArticle else { continue }
            // NSRegularExpression이 만드는 임시 객체를 줄마다 비운다(없으면 메모리가 수 GB까지 쌓인다).
            autoreleasepool {
                guard let text = clean(String(line)) else { return }
                for word in MistypeText.words(in: Substring(text), script: .hangul) {
                    model.train(word: word)
                    words += 1
                }
            }
        }

        let pruned = model.pruned(minimumBigramCount: minimumBigramCount)
        try pruned.serialized().write(toFile: arguments[1], atomically: true, encoding: .utf8)
        print("문서 \(pages)개, 단어 \(words)개, 음절 \(model.trainedTokens)개(경계 포함)")
        print("bigram \(model.bigramCount)개 → \(pruned.bigramCount)개(\(minimumBigramCount)회 이상)")
    }
}
