import AppKit

let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.09, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
let eye = NSBezierPath()
eye.move(to: NSPoint(x: 215, y: 512))
eye.curve(to: NSPoint(x: 809, y: 512), controlPoint1: NSPoint(x: 370, y: 745), controlPoint2: NSPoint(x: 655, y: 745))
eye.curve(to: NSPoint(x: 215, y: 512), controlPoint1: NSPoint(x: 655, y: 279), controlPoint2: NSPoint(x: 370, y: 279))
eye.close()
NSColor(calibratedRed: 0.78, green: 0.9, blue: 0.67, alpha: 1).setStroke()
eye.lineWidth = 26
eye.stroke()
let iris = NSBezierPath(ovalIn: NSRect(x: 436, y: 436, width: 152, height: 152))
NSColor(calibratedRed: 0.78, green: 0.9, blue: 0.67, alpha: 1).setFill()
iris.fill()
image.unlockFocus()
let iconDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hawkeye2-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconDirectory) }
for pixels in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let width = pixels * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: width))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconDirectory.appendingPathComponent("icon_\(pixels)x\(pixels)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconDirectory.path, "-o", destination]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
