import AppKit
import CoreImage
import CoreText

/// Drawing a caption line.
///
/// One bitmap per distinct appearance, cached: a line of type is expensive
/// to lay out and a caption holds still for dozens of frames at a time.
/// The word-by-word and typewriter styles change what is drawn as the line
/// plays, so the moment within the line is part of what identifies a
/// bitmap — which is why the cache is larger than the one the cursor and
/// window artwork share.
enum CaptionRenderer {
    private static let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>(); cache.countLimit = 360; return cache
    }()

    /// A laid-out caption: the artwork, and where on the canvas it belongs.
    struct Drawn {
        let image: CIImage
        let box: CGRect
    }

    /// How the line is entering and leaving at this moment.
    struct Motion {
        var opacity: Double = 1
        var scale: Double = 1
        /// Upward travel as a share of the box height.
        var lift: Double = 0
    }

    /// Entrances and exits last this long, at each end of a line.
    static let transition: Double = 0.18

    static func motion(for cue: CaptionCue, at time: Double, animation: CaptionAnimation) -> Motion {
        guard animation != .none, animation != .typewriter else { return Motion() }
        let span = min(transition, cue.duration / 3)
        guard span > 0.001 else { return Motion() }
        let into = min(1, max(0, (time - cue.start) / span))
        let outOf = min(1, max(0, (cue.end - time) / span))
        let eased = MotionCurve.smooth.value(into)
        var motion = Motion(opacity: min(eased, MotionCurve.smooth.value(outOf)))
        switch animation {
        case .pop:
            // A little past full size and back, so it arrives with weight.
            motion.scale = 0.86 + 0.14 * eased + sin(eased * .pi) * 0.045
        case .rise:
            motion.lift = (1 - eased) * -0.55
        default: break
        }
        return motion
    }

    /// Which word is being spoken, as an index into the cue's words.
    static func activeWord(in cue: CaptionCue, at time: Double) -> Int? {
        let words = cue.timedWords
        guard !words.isEmpty else { return nil }
        if let index = words.lastIndex(where: { time >= $0.start }) { return index }
        return 0
    }

    /// How much of the line has been written out, in characters.
    static func revealed(_ text: String, cue: CaptionCue, at time: Double) -> Int {
        // Written at the pace it is spoken, finished a little early so the
        // complete line is readable before it leaves.
        let share = (time - cue.start) / max(0.1, cue.duration * 0.78)
        return max(1, min(text.count, Int((Double(text.count) * share).rounded(.up))))
    }

    /// The caption for a moment, drawn and placed, or nil when there is
    /// nothing to show.
    static func render(cue: CaptionCue, at time: Double, settings: CaptionSettings,
                       accent: CGColor, canvas: CGRect) -> Drawn? {
        let fontSize = max(9, canvas.height * max(0.012, min(0.2, settings.size)))
        var text = settings.casing.apply(cue.text)
        var active: Int?
        if settings.animation == .typewriter {
            text = String(text.prefix(revealed(text, cue: cue, at: time)))
        } else if settings.animation.highlightsWords {
            active = activeWord(in: cue, at: time)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let key = "caption|\(settings.styleKey)|\(text)|\(active.map(String.init) ?? "-")|\(Int(canvas.width))x\(Int(canvas.height))|\(accentKey(accent))" as NSString
        let artwork: CIImage
        if let cached = cache.object(forKey: key) { artwork = cached }
        else if let drawn = bitmap(text: text, activeWord: active, settings: settings,
                                   accent: accent, fontSize: fontSize, canvas: canvas) {
            cache.setObject(drawn, forKey: key); artwork = drawn
        } else { return nil }

        return Drawn(image: artwork, box: box(size: artwork.extent.size, cue: cue, settings: settings, canvas: canvas))
    }

    /// Where the drawn line sits on the canvas.
    ///
    /// Kept apart from the drawing so the handle over the preview can ask
    /// the same question without rendering anything, and so a caption can
    /// be clicked where it actually is.
    static func box(size: CGSize, cue: CaptionCue?, settings: CaptionSettings, canvas: CGRect) -> CGRect {
        let anchor = settings.anchor(for: cue, height: Double(size.height / max(1, canvas.height)))
        // The anchor is measured down the canvas, the way the preview and
        // the camera layer are; Core Image measures up it.
        let centreX = canvas.minX + canvas.width * anchor.x
        let centreY = canvas.minY + canvas.height * (1 - anchor.y)
        let x = min(canvas.maxX - size.width, max(canvas.minX, centreX - size.width / 2))
        let y = min(canvas.maxY - size.height, max(canvas.minY, centreY - size.height / 2))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The size a line would be drawn at, without drawing it. Used by the
    /// preview handle, which needs somewhere to put the outline before any
    /// frame has been rendered.
    static func measure(cue: CaptionCue, settings: CaptionSettings, canvas: CGRect) -> CGSize? {
        let fontSize = max(9, canvas.height * max(0.012, min(0.2, settings.size)))
        let text = settings.casing.apply(cue.text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return bitmap(text: text, activeWord: nil, settings: settings,
                      accent: CGColor(gray: 1, alpha: 1), fontSize: fontSize, canvas: canvas)?.extent.size
    }

    private static func accentKey(_ color: CGColor) -> String {
        let c = color.components ?? []
        return c.prefix(3).map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    private static func color(_ rgb: RGBColor, alpha: Double = 1) -> CGColor {
        CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    private static func font(_ settings: CaptionSettings, size: CGFloat) -> NSFont {
        var font: NSFont
        if settings.fontName.isEmpty {
            font = NSFont.systemFont(ofSize: size, weight: settings.bold ? .heavy : .medium)
        } else if let named = NSFont(name: settings.fontName, size: size) {
            font = named
        } else if let family = NSFontManager.shared.font(withFamily: settings.fontName,
                                                         traits: settings.bold ? .boldFontMask : [],
                                                         weight: settings.bold ? 9 : 5, size: size) {
            font = family
        } else {
            font = NSFont.systemFont(ofSize: size, weight: settings.bold ? .heavy : .medium)
        }
        var traits: NSFontTraitMask = []
        if settings.bold { traits.insert(.boldFontMask) }
        if settings.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        return font
    }

    /// The caption as pixels, with its backdrop, outline, shadow and the
    /// word being spoken picked out. The blurred backdrop is the exception:
    /// it is the picture underneath, so the compositor draws that part.
    private static func bitmap(text: String, activeWord: Int?, settings: CaptionSettings,
                               accent: CGColor, fontSize: CGFloat, canvas: CGRect) -> CIImage? {
        let typeface = font(settings, size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let leading = typeface.ascender - typeface.descender + typeface.leading
        paragraph.lineSpacing = max(0, leading * (settings.lineSpacing - 1))

        var attributes: [NSAttributedString.Key: Any] = [
            .font: typeface,
            .foregroundColor: color(settings.textColor),
            .paragraphStyle: paragraph,
        ]
        if abs(settings.tracking) > 0.0001 { attributes[.kern] = fontSize * settings.tracking }
        let string = NSMutableAttributedString(string: text, attributes: attributes)

        // The outline is its own pass underneath, not a stroke on the same
        // glyphs. Core Text centres a stroke on the glyph's edge, so asking
        // for both at once eats half the letter and leaves it looking thin
        // and grey. Stroked first, filled over it, the letter keeps its
        // weight and gains an edge.
        var outline: NSAttributedString?
        if settings.outlineWidth > 0.0001 {
            var stroked = attributes
            stroked[.strokeWidth] = settings.outlineWidth * 100
            stroked[.strokeColor] = color(settings.outlineColor)
            stroked[.foregroundColor] = CGColor(gray: 0, alpha: 0)
            outline = NSAttributedString(string: text, attributes: stroked)
        }

        let highlight = settings.highlightColor.map { color($0) } ?? accent
        var activeRange: NSRange?
        if let activeWord {
            var at = 0
            for (index, word) in text.split(whereSeparator: \.isWhitespace).map(String.init).enumerated() {
                guard let found = (text as NSString).range(of: word, options: [], range: NSRange(location: at, length: (text as NSString).length - at)).toOptional() else { break }
                if index == activeWord { activeRange = found; break }
                at = found.location + found.length
            }
            if let activeRange, !settings.highlightFill {
                string.addAttribute(.foregroundColor, value: highlight, range: activeRange)
            }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let limit = max(fontSize * 4, canvas.width * max(0.2, min(1, settings.maxWidth)))
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: limit, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
        guard textSize.width > 1, textSize.height > 1 else { return nil }

        let panelled = settings.backdrop != .none
        let padX = panelled ? max(fontSize * 0.2, fontSize * settings.backdropPadding) : fontSize * 0.34
        let padY = panelled ? max(fontSize * 0.14, fontSize * settings.backdropPadding * 0.72) : fontSize * 0.3
        let box = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        guard box.width < 16_384, box.height < 16_384 else { return nil }

        guard let context = CGContext(data: nil, width: Int(ceil(box.width)), height: Int(ceil(box.height)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let panel = CGRect(origin: .zero, size: box)
        let radius = min(box.height / 2, fontSize * settings.backdropRadius)
        let backing = color(settings.backdropColor, alpha: max(0, min(1, settings.backdropOpacity)))
        switch settings.backdrop {
        case .none, .blur: break
        case .block:
            context.setFillColor(backing); context.fill(panel)
        case .pill:
            context.setFillColor(backing)
            context.addPath(CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .fade:
            // Solid behind the words, gone by the ends, so it sits on the
            // picture without drawing a hard edge across it.
            if let space = backing.colorSpace,
               let gradient = CGGradient(colorsSpace: space,
                                         colors: [backing.copy(alpha: 0)!, backing, backing, backing.copy(alpha: 0)!] as CFArray,
                                         locations: [0, 0.22, 0.78, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: panel.midY),
                                           end: CGPoint(x: panel.maxX, y: panel.midY), options: [])
            }
        }

        // Laid out from the origin and moved into place with the context,
        // so the line origins Core Text reports need no adjusting.
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil), nil)
        context.saveGState()
        context.translateBy(x: padX, y: padY)

        if let activeRange, settings.highlightFill,
           let marks = wordRects(in: frame, range: activeRange) {
            context.setFillColor(highlight)
            for mark in marks {
                let padded = mark.insetBy(dx: -fontSize * 0.07, dy: -fontSize * 0.04)
                context.addPath(CGPath(roundedRect: padded, cornerWidth: fontSize * 0.14, cornerHeight: fontSize * 0.14, transform: nil))
            }
            context.fillPath()
        }

        if settings.shadow > 0.001 {
            let strength = min(1, settings.shadow)
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.07 * strength),
                              blur: fontSize * 0.3 * strength,
                              color: CGColor(gray: 0, alpha: 0.8 * strength))
        }
        // One shadow, cast by the line as a whole. Drawn glyph by glyph,
        // each letter's shadow falls across the one before it and the line
        // comes out muddy grey instead of white.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if let outline {
            let edge = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(outline),
                                                CFRange(location: 0, length: 0),
                                                CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil), nil)
            CTFrameDraw(edge, context)
        }
        CTFrameDraw(frame, context)
        context.endTransparencyLayer()
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// Where a stretch of the string ended up, one rectangle per line it
    /// runs across. Used to light up the word being spoken.
    private static func wordRects(in frame: CTFrame, range: NSRange) -> [CGRect]? {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var rects: [CGRect] = []
        for (index, line) in lines.enumerated() {
            let span = CTLineGetStringRange(line)
            let from = max(range.location, span.location)
            let to = min(range.location + range.length, span.location + span.length)
            guard to > from else { continue }
            let left = CTLineGetOffsetForStringIndex(line, from, nil)
            let right = CTLineGetOffsetForStringIndex(line, to, nil)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            guard right > left else { continue }
            rects.append(CGRect(x: origins[index].x + left, y: origins[index].y - descent,
                                width: right - left, height: ascent + descent))
        }
        return rects.isEmpty ? nil : rects
    }
}

private extension NSRange {
    /// `range(of:)` reports `NSNotFound` rather than nothing at all.
    func toOptional() -> NSRange? { location == NSNotFound ? nil : self }
}
