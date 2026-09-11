#!/usr/bin/env swift
// 從 Resources/icons/AppIcon-v2.png 產生 AppIcon.png（1024 母圖）與 AppIcon.icns。
//
//   swift scripts/generate-icon.swift [輸出資料夾]
//
// 兩件事要做對，剩下交給系統工具：
//
// 1. 幾何。母圖是 1254 px、圓角方塊佔畫布 86.9%，但 macOS 的慣例是
//    1024 畫布裡圓角方塊約 824 px（80.5%），四周留白給陰影。照原樣打包
//    會比 Dock 上其他圖示大一圈。所以先用 alpha 量出方塊實際範圍，
//    再等比縮放置中到標準比例。
//
// 2. 縮圖品質。母圖是 1254 px 的立體算圖，縮到 32–64 px 時 AppKit 的
//    .high 內插明顯偏軟，在 LaunchBar 那種小圖清單裡看起來就糊。
//    改用 CoreImage 的 Lanczos，小尺寸再補一點點 unsharp。
//
// 3. 打包交給 iconutil。手刻 ICNS 容器時 16／32 px 會掛在 icp4／icp5 上，
//    而那兩個 OSType 塞 PNG 是不可靠的 —— macOS 有解碼路徑會當成原始點陣
//    資料，解出來是一片彩色雜訊。

import AppKit
import CoreImage

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/icons")
let fm = FileManager.default
let source = output.appendingPathComponent("AppIcon-v2.png")

guard let data = try? Data(contentsOf: source),
      let masterRep = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("讀不到 \(source.path)\n".data(using: .utf8)!)
    exit(1)
}

/// macOS 圖示的標準比例：1024 的畫布，圓角方塊 824，四周各留 100 給陰影。
let canvas = 1024.0

/// 小尺寸的留白比例比大尺寸小 —— Apple 自己的圖示格線就是這樣，
/// 16 pt 的方塊是 14/16，大尺寸才收到 824/1024。這台是非 Retina 的
/// 3840×1080，1× 素材真的會被用到，多擠出來的那幾個像素有差。
func tileRatio(for size: Int) -> Double { size <= 32 ? 14.0 / 16.0 : 824.0 / 1024.0 }

/// 用 alpha 量出圓角方塊的實際範圍。母圖的陰影很貼邊，所以門檻取高一點，
/// 量到的是不透明的本體而不是陰影。
func solidBounds(_ rep: NSBitmapImageRep) -> NSRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.78 else { continue }
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = solidBounds(masterRep)
let masterW = Double(masterRep.pixelsWide)
let masterH = Double(masterRep.pixelsHigh)

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let masterCI = CIImage(bitmapImageRep: masterRep)!

func render(_ size: Int) -> Data {
    let target = Double(size) * tileRatio(for: size)
    let k = target / max(bounds.width, bounds.height)

    // Lanczos 而不是 AppKit 的 .high —— 後者在 32–64 px 這個區間明顯偏軟。
    let lanczos = CIFilter(name: "CILanczosScaleTransform")!
    lanczos.setValue(masterCI, forKey: kCIInputImageKey)
    lanczos.setValue(k, forKey: kCIInputScaleKey)
    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
    var image = lanczos.outputImage!

    // 只有真正小的尺寸需要補銳度。強度壓在 0.35：再上去圓角方塊的邊緣
    // 就會浮出一圈黑色光暈，比糊還醜。
    if size <= 64 {
        let sharpen = CIFilter(name: "CIUnsharpMask")!
        sharpen.setValue(image, forKey: kCIInputImageKey)
        sharpen.setValue(0.9, forKey: kCIInputRadiusKey)
        sharpen.setValue(0.35, forKey: kCIInputIntensityKey)
        image = sharpen.outputImage!
    }

    // 把圓角方塊的中心對到畫布中心，而不是把整張母圖置中 —— 母圖的陰影不對稱，
    // 整張置中會讓方塊看起來偏上。bounds 的 y 由上往下數（點陣座標），
    // CoreImage 由下往上，所以要翻一次。
    let dx = Double(size) / 2 - bounds.midX * k
    let dy = Double(size) / 2 - (masterH - bounds.midY) * k
    image = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    guard let cg = ciContext.createCGImage(image, from: rect, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
        FileHandle.standardError.write("\(size) px 算圖失敗\n".data(using: .utf8)!)
        exit(1)
    }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
}

let iconset = output.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try render(points * factor)
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(Int(canvas)).write(to: output.appendingPathComponent("AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path,
                  "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失敗（\(task.terminationStatus)）\n".data(using: .utf8)!)
    exit(1)
}
try fm.removeItem(at: iconset)

print("由 AppIcon-v2.png 產生 AppIcon.png 與 AppIcon.icns（16–1024 px）")
