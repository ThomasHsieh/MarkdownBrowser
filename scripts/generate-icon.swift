#!/usr/bin/env swift
// 將書本母圖封裝為有透明留白的 macOS 圖示，外輪廓由向量路徑控制。
import AppKit
import CoreImage

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/icons")
let fm = FileManager.default
let source = output.appendingPathComponent("AppIcon-v4.png")
guard let loaded = NSBitmapImageRep(data: try Data(contentsOf: source)),
      loaded.pixelsWide == loaded.pixelsHigh,
      loaded.pixelsWide >= 1024,
      let cg = loaded.cgImage else {
    fatalError("母圖必須是至少 1024 px 的正方形 PNG")
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: colorSpace])
// 母圖的背景接近 #202020，書本本體最亮色頻遠高於背景。
// 統一 RGBA 後去除深色底與外部陰影；直接保留原書本像素，不重新生成書頁。
let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: loaded.pixelsWide,
    pixelsHigh: loaded.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: loaded.pixelsWide, height: loaded.pixelsHigh))
NSGraphicsContext.restoreGraphicsState()
let pixels = rgba.bitmapData!
for y in 0..<rgba.pixelsHigh {
    for x in 0..<rgba.pixelsWide {
        let i = y * rgba.bytesPerRow + x * 4
        let peak = Double(max(pixels[i], max(pixels[i+1], pixels[i+2])))
        let alpha = min(1, max(0, (peak - 40) / 50))
        if alpha == 0 {
            pixels[i] = 0; pixels[i+1] = 0; pixels[i+2] = 0; pixels[i+3] = 0
        } else if alpha < 1 {
            // 去掉抗鋸齒邊緣混入的深灰底色，避免深色毛邊。
            for channel in 0..<3 {
                let c = (Double(pixels[i+channel]) - 32 * (1-alpha)) / alpha
                pixels[i+channel] = UInt8((min(255, max(0, c)) * alpha).rounded())
            }
            pixels[i+3] = UInt8((alpha * 255).rounded())
        }
    }
}
let original = CIImage(bitmapImageRep: rgba)!
let foreground = original.applyingFilter("CILanczosScaleTransform", parameters: [
    kCIInputScaleKey: 1024.0 / Double(loaded.pixelsWide), kCIInputAspectRatioKey: 1.0
])
guard let foregroundCG = context.createCGImage(foreground, from: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                                               format: .RGBA8, colorSpace: colorSpace),
      let foregroundPNG = NSBitmapImageRep(cgImage: foregroundCG).representation(using: .png, properties: [:]) else {
    fatalError("透明書本圖層輸出失敗")
}
try foregroundPNG.write(to: output.appendingPathComponent("AppIcon.icon/Assets/Book.png"), options: .atomic)
let background = CIImage(color: CIColor(red: 27.0/255, green: 27.0/255, blue: 27.0/255))
let artwork = original.composited(over: background).cropped(to: original.extent)

// 1024 畫布中使用 824 px 本體，保留系統圖示的透明安全邊界。
// 五次超橢圓讓直邊平順地接入圓角，避免一般圓角矩形的接點。
let plate = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: plate)
let outline = NSBezierPath()
for step in 0...2048 {
    let angle = Double(step) * 2 * .pi / 2048
    let c = cos(angle), s = sin(angle)
    let x = 512 + 412 * (c < 0 ? -1 : 1) * pow(abs(c), 0.4)
    let y = 512 + 412 * (s < 0 ? -1 : 1) * pow(abs(s), 0.4)
    if step == 0 { outline.move(to: NSPoint(x: x, y: y)) }
    else { outline.line(to: NSPoint(x: x, y: y)) }
}
outline.close()
outline.addClip()
NSColor(srgbRed: 32.0/255, green: 32.0/255, blue: 32.0/255, alpha: 1).setFill()
outline.fill()
let insetArt = artwork.transformed(by: CGAffineTransform(scaleX: 824.0 / Double(loaded.pixelsWide),
                                                        y: 824.0 / Double(loaded.pixelsHigh)))
guard let book = context.createCGImage(insetArt, from: CGRect(x: 0, y: 0, width: 824, height: 824),
                                      format: .RGBA8, colorSpace: colorSpace) else {
    fatalError("母圖縮放失敗")
}
NSGraphicsContext.current!.cgContext.draw(book, in: CGRect(x: 100, y: 100, width: 824, height: 824))
// 僅有細微的實線邊界，不畫高光、模糊陰影或外圈光暈。
NSColor(srgbRed: 48.0/255, green: 48.0/255, blue: 48.0/255, alpha: 1).setStroke()
outline.lineWidth = 3
outline.stroke()
NSGraphicsContext.restoreGraphicsState()
let master = CIImage(bitmapImageRep: plate)!

func render(_ size: Int) throws -> Data {
    // 先延伸邊緣，避免縮圖濾鏡在畫布外取樣到透明黑；不加 unsharp 光暈。
    let scale = Double(size) / 1024.0
    let image = master.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
    ])
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    guard let result = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace),
          let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
        fatalError("\(size) px 算圖失敗")
    }
    return png
}

let temporary = fm.temporaryDirectory.appendingPathComponent("MarkdownBrowser-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try render(points * factor).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let packed = temporary.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", packed.path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失敗（\(task.terminationStatus)）\n".utf8))
    exit(1)
}
try Data(contentsOf: packed).write(to: output.appendingPathComponent("AppIcon.icns"), options: .atomic)
try render(1024).write(to: output.appendingPathComponent("AppIcon.png"), options: .atomic)
print("由 AppIcon-v4.png 產生 AppIcon.png 與 AppIcon.icns（16–1024 px）")
