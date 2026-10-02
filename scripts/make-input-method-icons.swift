// 입력 소스 메뉴용 가/A 아이콘. 불투명한 앱 아이콘과 분리한다.
//   swift scripts/make-input-method-icons.swift <output-dir>
// 메뉴용 16pt 투명 이미지/선택 상태 이미지와 설정 목록용 32pt 배지를 만든다.
// 각 TIFF에는 1x/2x 표현을 함께 넣는다.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-input-method-icons.swift <output-dir>\n".utf8))
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (mode, glyph) in [("Hangul", "가"), ("Latin", "A")] {
    for suffix in ["Template", "Alternate", "Palette"] {
        let isPalette = suffix == "Palette"
        let points = isPalette ? 32 : 16
        let size = NSSize(width: points, height: points)
        let color = suffix == "Template" ? NSColor.black : NSColor.white
        var representations: [NSBitmapImageRep] = []
        for scale in [1, 2] {
            let pixels = points * scale
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                fatalError("cannot create input source icon bitmap")
            }
            // 실제 픽셀 해상도와 TIFF의 논리 크기를 구분한다.
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            if isPalette {
                NSColor(srgbRed: 0.16, green: 0.22, blue: 0.32, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                             xRadius: 6, yRadius: 6).fill()
            }
            let fontSize: CGFloat = isPalette ? 24 : (mode == "Hangul" ? 13 : 15)
            let text = NSAttributedString(string: glyph, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: color
            ])
            let bounds = text.size()
            text.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            representations.append(bitmap)
        }
        guard let data = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:]) else {
            fatalError("cannot encode input source icon")
        }
        let file = "\(mode)\(suffix).tiff"
        try data.write(to: output.appendingPathComponent(file))
        print("\(file): \(points)pt, 1x/2x, \(isPalette ? "settings badge" : "transparent menu icon")")
    }
}
