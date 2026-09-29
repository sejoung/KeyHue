// docs/icon.png(흰 배경 위 라운드 사각형 일러스트)를 macOS 앱 아이콘 규격의 .iconset으로 변환한다.
//
//   swift scripts/make-icon.swift <source.png> <output.iconset>
//
// 1. 어두운 라운드 사각형의 경계를 자동 탐지해 흰 배경을 잘라낸다.
// 2. 라운드 사각형 마스크로 모서리를 투명하게 만든다.
// 3. Apple 아이콘 그리드(1024 캔버스, 824 본체, 100 여백)에 맞춰 배치한다.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-icon.swift <source.png> <output.iconset>\n".data(using: .utf8)!)
    exit(64)
}

guard let data = FileManager.default.contents(atPath: args[1]),
      let rep = NSBitmapImageRep(data: data),
      let source = rep.cgImage else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(66)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh

func luminance(_ x: Int, _ y: Int) -> Double {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
}

/// 흰 배경에서 안쪽으로 스캔하며 처음 어두워지는 지점(라운드 사각형 가장자리).
func edge(_ points: [(Int, Int)]) -> Int? {
    for (i, p) in points.enumerated() where luminance(p.0, p.1) < 0.6 {
        return i
    }
    return nil
}

func median(_ values: [Int]) -> Int {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

let rows = [0.3, 0.5, 0.7].map { Int(Double(height) * $0) }
let cols = [0.3, 0.5, 0.7].map { Int(Double(width) * $0) }
let left = median(rows.compactMap { y in edge((0..<width / 2).map { ($0, y) }) })
let right = width - 1 - median(rows.compactMap { y in edge((0..<width / 2).map { (width - 1 - $0, y) }) })
let top = median(cols.compactMap { x in edge((0..<height / 2).map { (x, $0) }) })
let bottom = height - 1 - median(cols.compactMap { x in edge((0..<height / 2).map { (x, height - 1 - $0) }) })

// 가장자리 anti-aliasing의 흰 테두리를 피하려고 살짝 안쪽으로 자른다.
let inset = 3
let crop = CGRect(x: left + inset, y: top + inset, width: right - left - inset * 2, height: bottom - top - inset * 2)
guard let cropped = source.cropping(to: crop) else { exit(70) }

let canvas: CGFloat = 1024
let body: CGFloat = 824
let bodyRect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2, width: body, height: body)
let radius = body * 0.225

guard let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(70) }
ctx.interpolationQuality = .high

let shape = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(shape)
ctx.clip()
ctx.draw(cropped, in: bodyRect)

guard let master = ctx.makeImage() else { exit(70) }

let output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let small = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { exit(70) }
        small.interpolationQuality = .high
        small.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = small.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(70) }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try png.write(to: output.appendingPathComponent(name))
    }
}
print("iconset: crop=\(crop.integral) → \(output.path)")
