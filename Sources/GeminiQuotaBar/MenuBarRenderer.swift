import AppKit

enum MenuBarRenderer {
    /// Renders a subtle provider icon (Gemini 4-point sparkle / ChatGPT ring)
    /// + 2 stacked horizontal progress bars (top: 5h, bottom: weekly).
    /// The 5h percentage text is rendered natively via `statusItem.button.attributedTitle`.
    static func renderBarsImage(provider: AIProvider, fiveHour: Double?, weekly: Double?) -> NSImage {
        let iconSize: CGFloat = 11
        let iconGap: CGFloat = 4
        let barWidth: CGFloat = 34
        let barHeight: CGFloat = 4.5
        let barGap: CGFloat = 3.0
        let leftPadding: CGFloat = 2
        let rightPadding: CGFloat = 2
        let canvasHeight: CGFloat = 22

        let totalWidth = leftPadding + iconSize + iconGap + barWidth + rightPadding
        let size = NSSize(width: totalWidth, height: canvasHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            // 1. Provider micro-icon on the left
            let iconRect = NSRect(
                x: leftPadding,
                y: (canvasHeight - iconSize) / 2.0,
                width: iconSize,
                height: iconSize
            )
            drawProviderIcon(provider, in: iconRect)

            // 2. Stacked 2 progress bars (top: 5h, bottom: weekly)
            let barsX = leftPadding + iconSize + iconGap
            let totalBarsHeight = barHeight * 2 + barGap
            let bottomBarY = (canvasHeight - totalBarsHeight) / 2.0
            let topBarY = bottomBarY + barHeight + barGap

            let topRect = NSRect(x: barsX, y: topBarY, width: barWidth, height: barHeight)
            let bottomRect = NSRect(x: barsX, y: bottomBarY, width: barWidth, height: barHeight)

            drawBar(
                in: topRect,
                fraction: fiveHour,
                fillColor: colorForFiveHour(fiveHour)
            )
            drawBar(
                in: bottomRect,
                fraction: weekly,
                fillColor: colorForWeekly(weekly)
            )

            return true
        }

        image.isTemplate = false
        return image
    }

    private static func drawProviderIcon(_ provider: AIProvider, in rect: NSRect) {
        let cx = rect.midX
        let cy = rect.midY
        let r = rect.width / 2.0

        switch provider {
        case .gemini:
            // Crisp 4-point Gemini sparkle
            let path = NSBezierPath()
            let inner = r * 0.28
            path.move(to: NSPoint(x: cx, y: cy + r))
            path.curve(to: NSPoint(x: cx + r, y: cy),
                       controlPoint1: NSPoint(x: cx + inner * 0.4, y: cy + inner),
                       controlPoint2: NSPoint(x: cx + inner, y: cy + inner * 0.4))
            path.curve(to: NSPoint(x: cx, y: cy - r),
                       controlPoint1: NSPoint(x: cx + inner, y: cy - inner * 0.4),
                       controlPoint2: NSPoint(x: cx + inner * 0.4, y: cy - inner))
            path.curve(to: NSPoint(x: cx - r, y: cy),
                       controlPoint1: NSPoint(x: cx - inner * 0.4, y: cy - inner),
                       controlPoint2: NSPoint(x: cx - inner, y: cy - inner * 0.4))
            path.curve(to: NSPoint(x: cx, y: cy + r),
                       controlPoint1: NSPoint(x: cx - inner, y: cy + inner * 0.4),
                       controlPoint2: NSPoint(x: cx - inner * 0.4, y: cy + inner))
            path.close()
            NSColor.systemBlue.setFill()
            path.fill()

        case .chatgpt:
            // Clean OpenAI-inspired ring + center dot
            let ringRect = rect.insetBy(dx: 1.2, dy: 1.2)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.6
            NSColor.systemTeal.setStroke()
            ring.stroke()

            let dotRect = NSRect(x: cx - 1.6, y: cy - 1.6, width: 3.2, height: 3.2)
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor.systemTeal.setFill()
            dot.fill()
        }
    }

    private static func drawBar(in rect: NSRect, fraction: Double?, fillColor: NSColor) {
        let radius = rect.height / 2.0

        // Background track
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.24).setFill()
        trackPath.fill()

        guard let fraction else { return }
        let clamped = min(max(fraction, 0.0), 1.0)
        guard clamped > 0.005 else { return }

        let fillWidth = max(rect.height, rect.width * CGFloat(clamped))
        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: min(fillWidth, rect.width),
            height: rect.height
        )

        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        fillPath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func colorForFiveHour(_ fraction: Double?) -> NSColor {
        guard let f = fraction else { return NSColor.tertiaryLabelColor }
        if f > 0.50 {
            return NSColor.systemGreen
        } else if f > 0.20 {
            return NSColor.systemOrange
        } else {
            return NSColor.systemRed
        }
    }

    private static func colorForWeekly(_ fraction: Double?) -> NSColor {
        guard let f = fraction else { return NSColor.tertiaryLabelColor }
        if f > 0.50 {
            return NSColor.systemBlue
        } else if f > 0.20 {
            return NSColor.systemOrange
        } else {
            return NSColor.systemRed
        }
    }
}
