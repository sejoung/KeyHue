// docs/icon.png에서 카멜레온 실루엣만 추출해 메뉴바 아이콘(alpha mask)을 만든다.
//
//   swift scripts/make-menubar-icon.swift <source.png> <output-dir> [높이pt=18] [이름=MenuBarIcon]
//   → <output-dir>/<이름>.png (1x), <이름>@2x.png (2x)
//   메뉴바 아이콘(18pt)과 전환 HUD(64pt, HUDIcon)가 같은 실루엣을 쓴다.
//
// 1. 채도·명도가 높은 픽셀(카멜레온 몸통)만 남긴다. 남색 배경(어두움)과 흰 키캡/눈(무채색)은 빠진다.
// 2. 가장 큰 덩어리(몸통)와 그 영역에 걸친 덩어리(손발)만 남기고 테두리 광택·하단 무지개 바를 버린다.
// 3. 작은 구멍(비늘 반사)은 메우고 눈·꼬리 말림처럼 큰 구멍은 살린다.
// 4. 여백 없이 잘라 메뉴바 높이(18pt)로 축소한다. 색은 앱에서 입힌다(상태색 또는 template).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make-menubar-icon.swift <source.png> <output-dir> [height-pt] [name]\n".data(using: .utf8)!)
    exit(64)
}

guard let data = FileManager.default.contents(atPath: args[1]),
      let source = NSBitmapImageRep(data: data)?.cgImage else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(66)
}

let width = source.width
let height = source.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// 1. 채도/명도 threshold
var mask = [Bool](repeating: false, count: width * height)
for i in 0..<(width * height) {
    let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
    let maxValue = max(r, g, b), minValue = min(r, g, b)
    let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
    mask[i] = saturation > 0.45 && maxValue / 255 > 0.45
}

struct Component {
    var pixels: [Int] = []
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    var touchesEdge = false
    var bounds: CGRect { CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) }
}

/// value와 같은 값을 가진 4-연결 덩어리들.
func components(of mask: [Bool], value: Bool) -> [Component] {
    var visited = [Bool](repeating: false, count: mask.count)
    var result: [Component] = []
    var stack: [Int] = []
    for start in 0..<mask.count where mask[start] == value && !visited[start] {
        var component = Component()
        visited[start] = true
        stack.append(start)
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            component.pixels.append(index)
            component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
            if x == 0 || y == 0 || x == width - 1 || y == height - 1 { component.touchesEdge = true }
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let next = ny * width + nx
                if mask[next] == value && !visited[next] {
                    visited[next] = true
                    stack.append(next)
                }
            }
        }
        result.append(component)
    }
    return result
}

// 2. 몸통 + 몸통 영역에 걸친 손발
let foreground = components(of: mask, value: true).sorted { $0.pixels.count > $1.pixels.count }
guard let body = foreground.first else { exit(70) }
let bodyArea = body.bounds.insetBy(dx: -CGFloat(width) * 0.02, dy: -CGFloat(height) * 0.02)
var kept = [Bool](repeating: false, count: mask.count)
for component in foreground
where component.pixels.count >= body.pixels.count / 100 && bodyArea.contains(component.bounds) {
    component.pixels.forEach { kept[$0] = true }
}

/// 가로·세로 box 확장(separable). value 픽셀을 radius만큼 넓힌다.
func dilate(_ mask: [Bool], radius: Int, value: Bool) -> [Bool] {
    func pass(_ input: [Bool], horizontal: Bool) -> [Bool] {
        var output = input
        let lines = horizontal ? height : width
        let length = horizontal ? width : height
        for line in 0..<lines {
            func index(_ i: Int) -> Int { horizontal ? line * width + i : i * width + line }
            var count = 0 // 창 안의 value 픽셀 수
            for i in 0..<min(radius, length) where input[index(i)] == value { count += 1 }
            for i in 0..<length {
                let enter = i + radius, leave = i - radius - 1
                if enter < length, input[index(enter)] == value { count += 1 }
                if leave >= 0, input[index(leave)] == value { count -= 1 }
                output[index(i)] = count > 0 ? value : !value
            }
        }
        return output
    }
    return pass(pass(mask, horizontal: true), horizontal: false)
}

// 머리-몸통 경계의 얇은 음영 틈을 닫는다(closing = 확장 후 수축).
let closeRadius = max(1, width / 400)
kept = dilate(dilate(kept, radius: closeRadius, value: true), radius: closeRadius, value: false)

// 3. 작은 구멍 메우기 (가장자리에 닿지 않는 배경 덩어리 중 작은 것)
let holeLimit = body.pixels.count / 150
for hole in components(of: kept, value: false) where !hole.touchesEdge && hole.pixels.count < holeLimit {
    hole.pixels.forEach { kept[$0] = true }
}

// 4. 잘라내고 축소
var minX = width, minY = height, maxX = 0, maxY = 0
for i in 0..<kept.count where kept[i] {
    let x = i % width, y = i / width
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}
let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1

var alpha = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
for y in 0..<cropHeight {
    for x in 0..<cropWidth where kept[(y + minY) * width + (x + minX)] {
        let o = (y * cropWidth + x) * 4
        alpha[o] = 0; alpha[o + 1] = 0; alpha[o + 2] = 0; alpha[o + 3] = 255
    }
}
let cropped = alpha.withUnsafeMutableBytes { buffer in
    CGContext(
        data: buffer.baseAddress, width: cropWidth, height: cropHeight, bitsPerComponent: 8, bytesPerRow: cropWidth * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!
}

let pointHeight = args.count > 3 ? Double(args[3]) ?? 18 : 18
let name = args.count > 4 ? args[4] : "MenuBarIcon"
let pointWidth = (pointHeight * Double(cropWidth) / Double(cropHeight)).rounded()
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for scale in [1, 2] {
    let w = Int(pointWidth) * scale, h = Int(pointHeight) * scale
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent(scale == 1 ? "\(name).png" : "\(name)@2x.png"))
}
print("\(name): crop=\(minX),\(minY) \(cropWidth)x\(cropHeight) → \(Int(pointWidth))x\(Int(pointHeight))pt")
