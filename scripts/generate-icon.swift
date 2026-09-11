#!/usr/bin/env swift
// 從 Resources/icons/AppIcon-v2.png 產生 AppIcon.png（1024 母圖）與 AppIcon.icns。
//
//   swift scripts/generate-icon.swift [輸出資料夾]
//
// 兩件事要做對，剩下交給系統工具：
//
// 1. 幾何要滿版，而且要是「方的」。
//
//    傳統 macOS 圖示是 1024 畫布裡圓角方塊 824 px（80.5%），四周留白給陰影。
//    但 macOS 26 的 Dock 會把這種舊格式圖示墊到系統自己的底板上再套遮罩：
//    留白版會變成「板中板」（淺灰底板中間一個縮小的深色方塊）；就算撐滿畫布，
//    只要美術稿自己的圓角比系統遮罩圓，四個角就會露出底板的灰邊，
//    看起來像一圈模糊的光暈。
//
//    所以把母圖的圓角補成直角（逐列沿用邊緣像素的顏色往外延伸，
//    才不會跟深灰的漸層對不上），圓角完全交給系統遮罩切。
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
      let loaded = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("讀不到 \(source.path)\n".data(using: .utf8)!)
    exit(1)
}

let canvas = 1024.0

/// 把來源統一成 RGBA8，後面才能直接讀寫像素。
/// 用預乘沒關係：只讀 alpha > 199 的像素，而輸出每個像素的 alpha 都是 255。
func normalise(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

let master = normalise(loaded)
let mw = master.pixelsWide, mh = master.pixelsHigh
let mRow = master.bytesPerRow
let mPix = master.bitmapData!

@inline(__always) func alphaAt(_ x: Int, _ y: Int) -> UInt8 { mPix[y * mRow + x * 4 + 3] }

/// 用 alpha 量出圓角方塊的實際範圍。門檻取高一點，量到的是不透明的本體。
var minX = mw, minY = mh, maxX = 0, maxY = 0
for y in 0..<mh {
    for x in 0..<mw where alphaAt(x, y) > 199 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
let bw = maxX - minX + 1, bh = maxY - minY + 1

/// 裁到方塊範圍，並把圓角補成直角：每一列從最外側的不透明像素往外把顏色延伸出去。
/// 用整片單色填會跟深灰的垂直漸層對不上，上下兩端會看得出色差。
let squared = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bw, pixelsHigh: bh,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let sRow = squared.bytesPerRow
let sPix = squared.bitmapData!

for y in 0..<bh {
    let my = y + minY
    var first = -1, last = -1
    for x in 0..<bw where alphaAt(x + minX, my) > 199 {
        if first < 0 { first = x }
        last = x
    }
    guard first >= 0 else { continue }   // 整列都是空的，理論上不會發生
    for x in 0..<bw {
        let srcX = min(max(x, first), last) + minX     // 夾在兩端之間 = 邊緣延伸
        let s = my * mRow + srcX * 4
        let d = y * sRow + x * 4
        sPix[d] = mPix[s]; sPix[d + 1] = mPix[s + 1]; sPix[d + 2] = mPix[s + 2]
        sPix[d + 3] = 255                              // 一律不透明，圓角交給系統
    }
}

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let masterCI = CIImage(bitmapImageRep: squared)!

func render(_ size: Int) -> Data {
    // 滿版：方塊要剛好填滿畫布。母圖的方塊是 1090×1075 不是正方，
    // 等比縮放再置中會在上下留兩條透明帶，所以直接用 Lanczos 的 aspectRatio
    // 分別拉到寬高都等於 size。1.4% 的形變肉眼看不出來。
    let scaleY = Double(size) / Double(bh)
    let aspect = Double(bh) / Double(bw)

    // Lanczos 而不是 AppKit 的 .high —— 後者在 32–64 px 這個區間明顯偏軟。
    let lanczos = CIFilter(name: "CILanczosScaleTransform")!
    lanczos.setValue(masterCI, forKey: kCIInputImageKey)
    lanczos.setValue(scaleY, forKey: kCIInputScaleKey)
    lanczos.setValue(aspect, forKey: kCIInputAspectRatioKey)
    var image = lanczos.outputImage!

    // 只有真正小的尺寸需要補銳度。強度壓在 0.35：再上去邊緣就會浮出光暈。
    if size <= 64 {
        let sharpen = CIFilter(name: "CIUnsharpMask")!
        sharpen.setValue(image, forKey: kCIInputImageKey)
        sharpen.setValue(0.9, forKey: kCIInputRadiusKey)
        sharpen.setValue(0.35, forKey: kCIInputIntensityKey)
        image = sharpen.outputImage!
    }

    // 捨入誤差可能在邊上留一條透明細縫，用邊緣像素往外夾住補掉。
    image = image.clampedToExtent()

    // Lanczos 與 unsharp 會在 alpha 上留下 252 這種尾數。差 3/255 就足以
    // 讓系統底板從邊緣透出來一點，索性把 alpha 一律壓成 1。
    let opaque = CIFilter(name: "CIColorMatrix")!
    opaque.setValue(image, forKey: kCIInputImageKey)
    opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
    opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
    image = opaque.outputImage!

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
