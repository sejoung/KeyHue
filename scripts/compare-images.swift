// 두 PNG를 비교한다. 크기가 다르거나, 채널 차이가 threshold를 넘는 픽셀 비율이 tolerance를 넘으면 실패.
//
//   swift scripts/compare-images.swift <expected.png> <actual.png> [tolerance=0.005] [diff.png]
//
// 글꼴 안티앨리어싱 같은 미세한 차이는 허용하고, 레이아웃 변화·텍스트 잘림 같은 차이를 잡는다(ADR 0022).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: compare-images.swift <expected> <actual> [tolerance] [diff.png]\n".data(using: .utf8)!)
    exit(64)
}
let tolerance = args.count > 3 ? Double(args[3]) ?? 0.005 : 0.005
let threshold = 24 // 0–255 채널 차이

func pixels(_ path: String) -> (width: Int, height: Int, data: [UInt8])? {
    guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()),
          let image = rep.cgImage else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, data)
}

guard let a = pixels(args[1]) else { print("missing: \(args[1])"); exit(2) }
guard let b = pixels(args[2]) else { print("missing: \(args[2])"); exit(2) }
guard a.width == b.width, a.height == b.height else {
    print("size differs: \(a.width)x\(a.height) → \(b.width)x\(b.height)")
    exit(1)
}

var differing = 0
var diff = [UInt8](repeating: 0, count: a.data.count)
for i in stride(from: 0, to: a.data.count, by: 4) {
    let delta = (0..<3).map { abs(Int(a.data[i + $0]) - Int(b.data[i + $0])) }.max()!
    if delta > threshold {
        differing += 1
        diff[i] = 255; diff[i + 3] = 255 // 다른 픽셀을 빨갛게
    } else {
        diff[i] = a.data[i] / 3; diff[i + 1] = a.data[i + 1] / 3; diff[i + 2] = a.data[i + 2] / 3; diff[i + 3] = 255
    }
}
let ratio = Double(differing) / Double(a.width * a.height)
print(String(format: "%.3f%% pixels differ", ratio * 100))

if args.count > 4, differing > 0 {
    diff.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[4]))
        }
    }
}
exit(ratio > tolerance ? 1 : 0)
