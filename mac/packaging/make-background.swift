// Draws the disk image's window background: the drag-to-Applications arrow and
// the three first-run steps. Writes background.png and background@2x.png.
//   swift mac/packaging/make-background.swift <out-dir>
// Positions match mac/packaging/dmg-settings.py.
import AppKit

// Bigger than the window: Finder's window size shifts with its title and tab
// bar, and must never run past the picture. Content sits in the top 660 x 500.
let width = 760.0, height = 720.0
let ink = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
let soft = NSColor(srgbRed: 0.38, green: 0.40, blue: 0.45, alpha: 1)
let accent = NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1)

/// Draws text with its top at y (from the top of the window); **bold** spans allowed.
@discardableResult
func text(_ s: String, x: Double, y: Double, width w: Double, size: CGFloat, color: NSColor = ink) -> Double {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.25
    let out = NSMutableAttributedString()
    for (i, part) in s.components(separatedBy: "**").enumerated() {
        out.append(NSAttributedString(string: part, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: i % 2 == 1 ? .semibold : .regular),
            .foregroundColor: color, .paragraphStyle: style]))
    }
    let h = ceil(out.boundingRect(with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin]).height)
    out.draw(with: NSRect(x: x, y: height - y - h, width: w, height: h), options: [.usesLineFragmentOrigin])
    return y + h
}

func step(_ n: Int, x: Double, y: Double) {
    let r = 11.0
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: height - y - 2 * r, width: 2 * r, height: 2 * r)).fill()
    let label = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                                .foregroundColor: NSColor.white])
    let size = label.size()
    label.draw(at: NSPoint(x: x + r - size.width / 2, y: height - y - r - size.height / 2))
}

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Arrow from the app (x 170) to Applications (x 490), icons centred at y 100.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: height - 100))
    arrow.line(to: NSPoint(x: 390, y: height - 100))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    soft.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 378, y: height - 90))
    head.line(to: NSPoint(x: 392, y: height - 100))
    head.line(to: NSPoint(x: 378, y: height - 110))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Steps.
    let left = 70.0, textX = 104.0, textW = 500.0
    NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1).setFill()
    NSRect(x: 40, y: height - 185, width: 580, height: 1).fill()
    step(1, x: left, y: 203)
    text("**Drag MirAIe AC to Applications.**", x: textX, y: 205, width: textW, size: 13)
    step(2, x: left, y: 238)
    var y = text("**Open it from Applications.** macOS says it can't check the developer, because the app isn't "
                 + "signed with a paid Apple certificate. Click **Done**, open **Privacy & Security** (below), and "
                 + "click **Open Anyway**.", x: textX, y: 240, width: textW, size: 12.5)
    step(3, x: left, y: y + 14)
    y = text("**Click the snowflake in the menu bar** and sign in with your MirAIe phone number and password.",
             x: textX, y: y + 16, width: textW, size: 12.5)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! draw(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! draw(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
