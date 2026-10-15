import AppKit
import ImageIO
import UniformTypeIdentifiers
import BigWaterCore
import BigWaterArt

enum ArtworkError: Error { case cannotEncodeImage, cannotCreateGIF, cannotFinishGIF }

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let bitmap = image.representations.first as? NSBitmapImageRep,
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw ArtworkError.cannotEncodeImage
    }
    try data.write(to: url)
}

func label(_ text: String, at point: CGPoint, size: Double, color: NSColor, serif: Bool = false) {
    let base = NSFont.systemFont(ofSize: size, weight: serif ? .semibold : .regular)
    let font: NSFont
    if serif, let descriptor = base.fontDescriptor.withDesign(.serif) {
        font = NSFont(descriptor: descriptor, size: size) ?? base
    } else {
        font = base
    }
    (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

func appIcon(size: Double) -> NSImage {
    PixelArt.image(size: CGSize(width: size, height: size), backingScale: 1) { context in
        let factor = size / 1_024
        context.scaleBy(x: factor, y: factor)
        // A stepped, cream tile and an oversized mineral-water bottle.
        PixelArt.rect(context, 144, 32, 736, 960, WaterPalette.cream)
        PixelArt.rect(context, 80, 64, 864, 896, WaterPalette.cream)
        PixelArt.rect(context, 48, 112, 928, 800, WaterPalette.cream)
        PixelArt.rect(context, 32, 160, 960, 704, WaterPalette.cream)
        PixelArt.bottle(in: context, at: CGPoint(x: 512, y: 512), scale: 24, angle: .pi / 12)
        PixelArt.rect(context, 756, 168, 24, 88, WaterPalette.clay)
        PixelArt.rect(context, 724, 200, 88, 24, WaterPalette.clay)
        PixelArt.rect(context, 234, 736, 20, 68, WaterPalette.blue)
        PixelArt.rect(context, 210, 760, 68, 20, WaterPalette.blue)
    }
}

func storyboard() -> NSImage {
    PixelArt.image(size: CGSize(width: 960, height: 362), backingScale: 1) { context in
        PixelArt.rect(context, 0, 0, 960, 362, WaterPalette.cream)
        label("Big Water", at: CGPoint(x: 32, y: 20), size: 30, color: WaterPalette.ink, serif: true)
        label("蓝帽子 Claude · 大瓶矿泉水 · 点一下，爬绳收工", at: CGPoint(x: 34, y: 62), size: 13,
              color: WaterPalette.rope)
        let phases: [ReminderPhase] = [.descending, .reminding, .reminding, .ascending]
        let times = [0.6, 0.43, 0.64, 0.24]
        let titles = ["SLIDE", "WIND UP", "THROW!", "CLIMB"]
        let captions = ["沿绳子滑下来", "举起大水，蓄力", "持续扔水，等你点击", "点击后沿绳爬回去"]
        for index in 0..<4 {
            let x = 28.0 + Double(index) * 234
            PixelArt.rect(context, x, 102, 218, 224, .white.withAlphaComponent(0.55))
            context.saveGState()
            context.translateBy(x: x, y: 110)
            let point = CGPoint(x: 112, y: 106)
            PixelArt.rope(in: context, x: 64, from: 0, to: 146)
            PixelArt.claude(in: context, at: point, phase: phases[index], poseTime: times[index])
            if index == 2 {
                PixelArt.bottle(in: context, at: CGPoint(x: 168, y: 142), scale: 2.5, angle: 0.55)
            }
            PixelArt.pixelText(titles[index], in: context,
                              at: CGPoint(x: (218 - Double(titles[index].count) * 12) / 2, y: 166),
                              scale: 2, color: WaterPalette.clay)
            label(captions[index], at: CGPoint(x: index == 2 ? 40 : 50, y: 194), size: 12,
                  color: WaterPalette.rope)
            context.restoreGState()
        }
    }
}

func animationFrame(_ scene: ReminderScene) -> NSImage {
    PixelArt.image(size: scene.viewport, backingScale: 1) { context in
        PixelArt.rect(context, 0, 0, scene.viewport.width, scene.viewport.height, WaterPalette.cream)
        label("Big Water", at: CGPoint(x: 32, y: 32), size: 36, color: WaterPalette.ink, serif: true)
        label("一个有点执着的喝水提醒。", at: CGPoint(x: 34, y: 84), size: 15, color: WaterPalette.rope)
        SceneRenderer.draw(scene, in: context)
        let caption = scene.hasAcknowledged ? "点击后停止扔水，沿绳子爬走" : "蓝帽子上班 · 点击 Claude 收工"
        label(caption, at: CGPoint(x: 34, y: 592), size: 13, color: WaterPalette.rope)
    }
}

func saveAnimation(to url: URL) throws {
    let count = 102
    let fps = 12.0
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                            count, nil) else {
        throw ArtworkError.cannotCreateGIF
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    var scene = ReminderScene(viewport: CGSize(width: 960, height: 640), topInset: 0)
    for frame in 0..<count {
        if frame == 67 { scene.acknowledge() }
        let image = animationFrame(scene)
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let cgImage = bitmap.cgImage else { throw ArtworkError.cannotEncodeImage }
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        scene.advance(by: 1 / fps)
    }
    guard CGImageDestinationFinalize(destination) else { throw ArtworkError.cannotFinishGIF }
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/Artwork", isDirectory: true)
let icons = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try savePNG(appIcon(size: Double(points)), to: icons.appendingPathComponent("icon_\(points)x\(points).png"))
        try savePNG(appIcon(size: Double(points * 2)), to: icons.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    try savePNG(storyboard(), to: output.appendingPathComponent("storyboard.png"))
    try savePNG(PixelArt.settingsBottle(), to: output.appendingPathComponent("bottle.png"))
    try saveAnimation(to: output.appendingPathComponent("animation.gif"))
    print("Artwork: \(output.path)")
} catch {
    fputs("Artwork export failed: \(error)\n", stderr)
    exit(1)
}
