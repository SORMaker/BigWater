import AppKit
import ImageIO
import UniformTypeIdentifiers
import BigWaterCore
import BigWaterArt

// Renders the app icon and the pictures in `docs/` with the same scene and
// painter the app uses, so the documentation cannot drift from the product.
//
//     swift run BigWaterArtwork [output directory]

enum ArtworkError: Error { case cannotEncode, cannotWriteGIF }

func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
    guard let bitmap = image.representations.first as? NSBitmapImageRep else { throw ArtworkError.cannotEncode }
    return bitmap
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let data = try bitmap(image).representation(using: .png, properties: [:]) else {
        throw ArtworkError.cannotEncode
    }
    try data.write(to: url)
}

/// A looping GIF at 12 frames a second.
func saveGIF(frames: Int, to url: URL, frame: (Int) throws -> NSImage) throws {
    guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)
    else { throw ArtworkError.cannotWriteGIF }
    CGImageDestinationSetProperties(file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for index in 0..<frames {
        guard let image = try bitmap(frame(index)).cgImage else { throw ArtworkError.cannotEncode }
        CGImageDestinationAddImage(file, image, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: 1.0 / 12]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(file) else { throw ArtworkError.cannotWriteGIF }
}

func label(_ text: String, at point: CGPoint, size: Double, color: NSColor, serif: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: serif ? .semibold : .regular)
    if serif, let descriptor = font.fontDescriptor.withDesign(.serif) {
        font = NSFont(descriptor: descriptor, size: size) ?? font
    }
    (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

func fill(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NSColor, in context: CGContext) {
    Painter.fill(CGRect(x: x, y: y, width: width, height: height), color, in: context)
}

/// A stepped cream tile with an oversized bottle, drawn on a 1024 grid.
func appIcon(size: Double) -> NSImage {
    Painter.image(size: CGSize(width: size, height: size), scale: 1) { context in
        context.scaleBy(x: size / 1_024, y: size / 1_024)
        fill(144, 32, 736, 960, Palette.cream, in: context)
        fill(80, 64, 864, 896, Palette.cream, in: context)
        fill(48, 112, 928, 800, Palette.cream, in: context)
        fill(32, 160, 960, 704, Palette.cream, in: context)
        Painter.bottle(at: CGPoint(x: 512, y: 512), scale: 24, angle: .pi / 12, in: context)
        // Two sparkles.
        fill(756, 168, 24, 88, Palette.clay, in: context)
        fill(724, 200, 88, 24, Palette.clay, in: context)
        let blue = Palette.accent(.blue).base
        fill(234, 736, 20, 68, blue, in: context)
        fill(210, 760, 68, 20, blue, in: context)
    }
}

/// Four moments of a reminder from the top edge, side by side.
func storyboard() -> NSImage {
    let panels: [(phase: ReminderScene.Phase, time: Double, title: String, caption: String)] = [
        (.entering, 0.6, "SLIDE", "沿绳子滑下来"),
        (.asking, 0.64, "THROW!", "持续扔水，等你点击"),
        (.drinking, 0.8, "DRINK", "点击后陪你喝 20 秒"),
        (.leaving, 0.24, "CLIMB", "喝完记录，沿绳爬回去")
    ]
    return Painter.image(size: CGSize(width: 960, height: 362), scale: 1) { context in
        fill(0, 0, 960, 362, Palette.cream, in: context)
        label("Big Water", at: CGPoint(x: 32, y: 20), size: 30, color: Palette.ink, serif: true)
        label("蓝帽子 Claude · 大瓶矿泉水 · 点一下，陪你喝完再收工", at: CGPoint(x: 34, y: 62), size: 13,
              color: Palette.rope)
        for (index, panel) in panels.enumerated() {
            let x = 28.0 + Double(index) * 234
            fill(x, 102, 218, 224, .white.withAlphaComponent(0.55), in: context)
            context.saveGState()
            context.translateBy(x: x, y: 110)
            Painter.rope(x: 64, from: 0, to: 146, in: context)
            Painter.mascot(.claude, pose: Pose(phase: panel.phase, time: panel.time), at: CGPoint(x: 112, y: 108),
                           in: context)
            if panel.phase == .asking {
                Painter.bottle(at: CGPoint(x: 168, y: 142), scale: 2.5, angle: 0.55, in: context)
            }
            context.saveGState()
            context.translateBy(x: (218 - Sprite.textWidth(panel.title, scale: 2)) / 2, y: 166)
            Painter.blocks(Sprite.text(panel.title, scale: 2, ink: .clay), theme: .blue, in: context)
            context.restoreGState()
            label(panel.caption, at: CGPoint(x: index == 0 ? 73 : 49, y: 194), size: 12, color: Palette.rope)
            context.restoreGState()
        }
    }
}

/// Every mascot waiting, drinking and done, side by side.
func lineup() -> NSImage {
    let rows: [(title: String, pose: Pose)] = [
        ("等你喝水", Pose(phase: .asking, time: 0.5, usesRope: false)),
        ("陪你喝", Pose(phase: .drinking, time: 0.5, usesRope: false)),
        ("喝完收工", Pose(phase: .cheering, time: 0.05, usesRope: false))
    ]
    let column = 184.0, rowHeight = 168.0, left = 96.0, top = 64.0
    let size = CGSize(width: left + column * Double(Mascot.allCases.count) + 16, height: top + rowHeight * 3 + 16)
    return Painter.image(size: size, scale: 1) { context in
        fill(0, 0, size.width, size.height, Palette.cream, in: context)
        for (index, mascot) in Mascot.allCases.enumerated() {
            label(mascot.name, at: CGPoint(x: left + Double(index) * column + 70, y: 24), size: 15, color: Palette.ink)
        }
        for (row, item) in rows.enumerated() {
            let y = top + Double(row) * rowHeight
            label(item.title, at: CGPoint(x: 20, y: y + rowHeight / 2 - 10), size: 13, color: Palette.rope)
            for (index, mascot) in Mascot.allCases.enumerated() {
                let x = left + Double(index) * column
                fill(x + 4, y + 4, column - 8, rowHeight - 8, .white.withAlphaComponent(0.55), in: context)
                context.saveGState()
                context.clip(to: CGRect(x: x + 4, y: y + 4, width: column - 8, height: rowHeight - 8))
                Painter.mascot(mascot, pose: item.pose, at: CGPoint(x: x + 76, y: y + 96), in: context)
                context.restoreGState()
            }
        }
    }
}

/// A real 20-second drink would not fit a loop of under ten seconds.
let shortDrink = 2.4
let frameCount = 108
/// The frame at which the person "clicks".
let clickFrame = 46

func heroFrame(_ scene: ReminderScene) -> NSImage {
    Painter.image(size: scene.screen.size, scale: 1) { context in
        fill(0, 0, scene.screen.size.width, scene.screen.size.height, Palette.cream, in: context)
        label("Big Water", at: CGPoint(x: 32, y: 32), size: 36, color: Palette.ink, serif: true)
        label("一个有点执着的喝水提醒。", at: CGPoint(x: 34, y: 84), size: 15, color: Palette.rope)
        Painter.scene(scene, in: context)
        let caption = scene.hasFinishedDrink ? "喝完记一次，沿绳子爬走"
            : (scene.phase == .drinking ? "点击后停止扔水，陪你喝一会儿" : "蓝帽子上班 · 点击 Claude 一起喝水")
        label(caption, at: CGPoint(x: 34, y: 592), size: 13, color: Palette.rope)
    }
}

/// The four entrances at once, as they look on the desktop.
func entrancesFrame(_ scenes: [ReminderScene]) -> NSImage {
    let titles = ["TOP · 顶部沿绳滑下", "BOTTOM · 底部升起", "LEFT · 左侧滑入", "RIGHT · 右侧滑入"]
    return Painter.image(size: CGSize(width: 1_280, height: 840), scale: 1) { context in
        for (index, scene) in scenes.enumerated() {
            context.saveGState()
            context.translateBy(x: Double(index % 2) * 640, y: Double(index / 2) * 420)
            context.clip(to: CGRect(origin: .zero, size: scene.screen.size))
            fill(0, 0, 640, 420, Palette.cream, in: context)
            fill(0, 0, 640, 2, Palette.ropeLight, in: context)
            fill(0, 0, 2, 420, Palette.ropeLight, in: context)
            label(titles[index], at: CGPoint(x: 24, y: 18), size: 16, color: Palette.ink)
            Painter.scene(scene, in: context)
            context.restoreGState()
        }
    }
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
    try savePNG(Painter.panelBottle(), to: output.appendingPathComponent("bottle.png"))
    try savePNG(lineup(), to: output.appendingPathComponent("mascots.png"))

    // Fixed seeds, so the pictures only change when the motion does.
    var hero = ReminderScene(screen: ScreenSpace(size: CGSize(width: 960, height: 640), topInset: 0),
                             drinkTime: shortDrink, seed: 7)
    try saveGIF(frames: frameCount, to: output.appendingPathComponent("animation.gif")) { frame in
        if frame == clickFrame { hero.beginDrinking() }
        defer { hero.advance(by: 1.0 / 12) }
        return heroFrame(hero)
    }

    var entrances = Edge.allCases.map {
        ReminderScene(screen: ScreenSpace(size: CGSize(width: 640, height: 420), topInset: 44),
                      entrance: Entrance(edge: $0, position: 0.5), drinkTime: shortDrink, seed: 11)
    }
    try saveGIF(frames: frameCount, to: output.appendingPathComponent("entrances.gif")) { frame in
        if frame == clickFrame { for index in entrances.indices { entrances[index].beginDrinking() } }
        defer { for index in entrances.indices { entrances[index].advance(by: 1.0 / 12) } }
        let image = entrancesFrame(entrances)
        if frame == 30 { try savePNG(image, to: output.appendingPathComponent("entrances.png")) }
        return image
    }
    print("Artwork: \(output.path)")
} catch {
    fputs("Artwork export failed: \(error)\n", stderr)
    exit(1)
}
