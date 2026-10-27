import AppKit
import SwiftUI
import PDFKit

struct LayoutBlock {
    let id: Int
    var text: String
    var bounds: CGRect
    var lines: [CGRect]
    var fontSize: CGFloat
    var bold: Bool
}
func pageBlocks(_ page: PDFPage, repair: Bool = true) -> [LayoutBlock] {
    guard page.numberOfCharacters > 0 else { return [] }
    let box = page.bounds(for: .cropBox)
    var lines: [(String, CGRect, CGFloat, Bool)] = []
    let source = (page.string ?? "") as NSString
    let attributed = page.attributedString
    struct Glyph { let text: String; let rect: CGRect; let size: CGFloat; let bold: Bool }
    var rows: [[Glyph]] = []
    var oversized: [(CGRect, CGRect)] = []
    for index in 0..<min(page.numberOfCharacters, source.length) {
        let text = source.substring(with: NSRange(location: index, length: 1))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        let raw = (page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page) ?? .null).intersection(box)
        guard !raw.isNull, raw.width > 0, raw.height > 0 else { continue }
        var rect = CGRect(x: raw.minX - box.minX, y: box.maxY - raw.maxY, width: raw.width, height: raw.height)
        let font = index < (attributed?.length ?? 0) ? attributed?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
        if repair && rect.height > 22 {
            let original = rect
            // PDFKit gives every character on a drop-cap line the full initial's height.
            // Anchor to the line top for sorting; retain the original rectangle for masking.
            rect.size.height = min(12, max(8, font?.pointSize ?? 10))
            if rect.height > 12 { rect.size.height = 10 }
            oversized.append((rect, original))
        }
        let glyph = Glyph(text: text, rect: rect, size: min(30, max(5, font?.pointSize ?? rect.height * 0.8)), bold: font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        if let row = rows.indices.first(where: { abs(rows[$0][0].rect.midY - rect.midY) < min(rows[$0][0].rect.height, rect.height) * 0.35 }) { rows[row].append(glyph) }
        else { rows.append([glyph]) }
    }
    let hasColumnGutter = rows.filter { row in
        let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = sorted.first, let last = sorted.last,
              first.rect.minX < box.width / 2 - 100, last.rect.maxX > box.width / 2 + 100 else { return false }
        return zip(sorted, sorted.dropFirst()).contains { a, b in
            a.rect.maxX < box.width / 2 && b.rect.minX > box.width / 2 && b.rect.minX - a.rect.maxX > 12
        }
    }.count >= 5
    for row in rows {
        let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
        var groups: [[Glyph]] = []
        for glyph in sorted {
            if let last = groups.last?.last, glyph.rect.minX - last.rect.maxX <= (repair && hasColumnGutter && ((last.rect.midX < box.width / 2) == (glyph.rect.midX < box.width / 2)) ? max(35, glyph.size * 1.4) : max(12, glyph.size * 1.4)) { groups[groups.count - 1].append(glyph) }
            else { groups.append([glyph]) }
        }
        for group in groups {
            var text = "", bounds = CGRect.null
            for (index, glyph) in group.enumerated() {
                if index > 0 && glyph.rect.minX - group[index - 1].rect.maxX > glyph.size * 0.18 { text += " " }
                text += glyph.text; bounds = bounds.union(glyph.rect)
            }
            let sizes = group.map(\.size).sorted()
            lines.append((text, bounds, sizes[sizes.count / 2], Double(group.filter(\.bold).count) / Double(group.count) > 0.65))
        }
    }
    // Search geometric predecessors, rather than trusting PDF text-stream order.
    // This joins indented/widely spaced paragraphs even when columns interleave.
    lines.sort { abs($0.1.minY - $1.1.minY) > 2 ? $0.1.minY < $1.1.minY : $0.1.minX < $1.1.minX }
    var blocks: [LayoutBlock] = []
    for (text, rect, size, bold) in lines {
        let section = text.range(of: "^(?:Objective|Methods|Results|Conclusion|Keywords|目的|方法|结果|结论|关键词|【摘要】|\\[摘要\\])(?:[ :：]|$)", options: [.regularExpression, .caseInsensitive]) != nil
        let candidates = blocks.indices.filter { index in
            let last = blocks[index], previous = last.lines.last!
            let gap = rect.minY - previous.maxY
            if last.lines.count >= 2 {
                let gaps = zip(last.lines, last.lines.dropFirst()).map { $1.minY - $0.maxY }.sorted()
                let typical = gaps[gaps.count / 2]
                if gap > max(typical * 1.65, typical + size * 0.5) { return false }
            }
            let overlap = max(0, min(rect.maxX, previous.maxX) - max(rect.minX, previous.minX))
            let sameColumn = overlap >= min(rect.width, previous.width) * 0.72
            let leftShift = rect.minX - previous.minX
            let initialLine = repair && oversized.contains { $0.0.intersects(previous) }
            let aligned = leftShift <= max(5, size * (initialLine ? 1.7 : 0.65)) && leftShift >= -size * (repair && oversized.contains(where: { $0.0.intersects(last.bounds) }) ? 4 : 2.5)
            let similarFont = abs(size - last.fontSize) < max(1.6, size * 0.13)
            let continuation = previous.width > rect.width * 0.72
            return gap >= -2 && gap < max(6, size * 1.55) && aligned && sameColumn && similarFont && continuation && !section && bold == last.bold && last.text.count + text.count < 12000
        }
        if let index = candidates.min(by: { rect.minY - blocks[$0].lines.last!.maxY < rect.minY - blocks[$1].lines.last!.maxY }) {
            blocks[index].text += "\n" + text
            blocks[index].bounds = blocks[index].bounds.union(rect)
            blocks[index].lines.append(rect)
        } else {
            blocks.append(LayoutBlock(id: blocks.count, text: text, bounds: rect, lines: [rect], fontSize: size, bold: bold))
        }
    }
    if repair {
        for (line, mask) in oversized {
            if let i = blocks.firstIndex(where: { $0.bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: line.midX, y: line.midY)) }) {
                if !blocks[i].lines.contains(mask) { blocks[i].lines.append(mask) }
            }
        }
    }
    return blocks
}
// Publication identifiers are page furniture, not prose to translate/reflow.
func preservePublicationMetadata(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count < 320 else { return false }
    let patterns = [#"(?i)^doi\s*[:：]"#, #"(?i)^ISSN\s*[:：]"#, #"(?i)^CN\s*[:：]\s*\d"#,
                    #"(?i)^(?:www\.|https?://)\S+"#, #"(?i)^Copyright\s*(?:©|\(c\))"#,
                    #"^©\s*\d{4}"#, #"(?i)^[A-Za-z .,&-]+,\s*\d{4};\s*\d+\s*\("#]
    return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
}
func translationKey(_ page: Int, _ block: Int) -> String { "block-\(page)-\(block)" }

final class PairedCanvas: NSView {
    var pdfPage: PDFPage?
    var blocks: [LayoutBlock] = []
    var translated: [Int: String] = [:]
    var sizes: [Int: CGFloat] = [:]
    var spacing: [Int: CGFloat] = [:]
    var rightBounds: [Int: CGRect] = [:]
    var renderOwner: [Int: Int] = [:]
    var draftIDs: Set<Int> = []
    var readingText: [Int: String] = [:]
    var rightPageHeight: CGFloat = 842
    func readingHeight(_ text: String, width: CGFloat, size: CGFloat, bold: Bool) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: 1000000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textStyle(size, bold: bold, lineSpacing: size * 0.2)).height) + size * 0.7
    }
    var thumbnail: NSImage?
    var pixels: NSBitmapImageRep?
    var highlighted: Int?
    var pointer: CGPoint?
    var pointerOnRight = false
    var zoom: CGFloat = 1
    var onFocus: ((Int?) -> Void)?
    var tracked: NSTrackingArea?
    var pageSize = CGSize(width: 595, height: 842)
    var leftRect = CGRect.zero
    var rightRect = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var scale: CGFloat { leftRect.width / max(1, pageSize.width) }
    func configure(page: PDFPage, blocks: [LayoutBlock], translated: [Int: String]) {
        let needsFit = pdfPage !== page || self.translated != translated
        if pdfPage !== page {
            pdfPage = page; pageSize = page.bounds(for: .cropBox).size
            thumbnail = page.thumbnail(of: CGSize(width: pageSize.width * 2, height: pageSize.height * 2), for: .cropBox)
            pixels = thumbnail?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
            highlighted = nil; pointer = nil
        }
        self.blocks = blocks; self.translated = translated
        if needsFit { reflowParagraphs() }
        needsDisplay = true
    }
    func reflowParagraphs() {
        sizes = [:]; spacing = [:]; readingText = [:]; rightBounds = [:]; renderOwner = [:]
        rightPageHeight = pageSize.height
        guard !translated.isEmpty, !blocks.allSatisfy({ translated[$0.id] == $0.text }) else {
            rightBounds = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.bounds) }); return
        }
        let mid = pageSize.width / 2
        let body = blocks.filter { $0.bounds.minY > pageSize.height * 0.115 && $0.bounds.minY < pageSize.height * 0.94 }
        let left = body.filter { $0.bounds.maxX <= mid + 4 && $0.bounds.width > pageSize.width * 0.25 }
        let right = body.filter { $0.bounds.minX >= mid - 4 && $0.bounds.width > pageSize.width * 0.25 }
        let columns = left.count >= 2 && right.count >= 2
        // Independent column cursors: extra space in one column never pushes the other.
        var lanes: [Int: [LayoutBlock]] = [:]
        for block in blocks {
            if preservePublicationMetadata(block.text) {
                rightBounds[block.id] = block.bounds
                // Keep the original PDF glyphs, italics, baseline and row spacing intact.
                continue
            }
            let text = translated[block.id] ?? block.text
            readingText[block.id] = text.replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let isBody = block.bounds.minY > pageSize.height * 0.115 && block.bounds.minY < pageSize.height * 0.94
            let lane: Int
            if columns && isBody && block.bounds.maxX <= mid + 4 { lane = 0 }
            else if columns && isBody && block.bounds.minX >= mid - 4 { lane = 1 }
            else { lane = 2 }
            lanes[lane, default: []].append(block)
        }
        for lane in [2, 0, 1] {
            guard let unsorted = lanes[lane] else { continue }
            let ordered = unsorted.sorted { abs($0.bounds.minY - $1.bounds.minY) > 2 ? $0.bounds.minY < $1.bounds.minY : $0.bounds.minX < $1.bounds.minX }
            if lane < 2 {
                let broad = ordered.filter { $0.bounds.width > pageSize.width * 0.25 }
                let x = broad.map { $0.bounds.minX }.min() ?? ordered[0].bounds.minX
                let end = broad.map { $0.bounds.maxX }.max() ?? ordered[0].bounds.maxX
                let width = max(100, end - x)
                let headerBottom = (lanes[2] ?? []).filter { $0.bounds.minY <= pageSize.height * 0.115 }.compactMap { rightBounds[$0.id]?.maxY }.max() ?? 0
                var y = max(ordered[0].bounds.minY, headerBottom + 8)
                var runs: [[LayoutBlock]] = []
                for block in ordered {
                    if let last = runs.last, let bottom = last.map({ $0.bounds.maxY }).max(), block.bounds.minY < bottom - 0.5 {
                        runs[runs.count - 1].append(block)
                    } else { runs.append([block]) }
                }
                var previousEnd: CGFloat?
                for run in runs {
                    let block = run[0]
                    if let end = previousEnd, block.bounds.minY - end > 32 { y = max(y + 12, block.bounds.minY) }
                    let size: CGFloat = block.fontSize >= 12 ? min(15, block.fontSize) : 10
                    let combined = run.compactMap { readingText[$0.id] }.joined(separator: " ")
                    readingText[block.id] = combined
                    let h = readingHeight(combined, width: width, size: size, bold: block.bold)
                    let rect = CGRect(x: x, y: y, width: width, height: h)
                    for item in run {
                        renderOwner[item.id] = block.id
                        rightBounds[item.id] = rect; sizes[item.id] = size; spacing[item.id] = size * 0.2
                    }
                    y += h + (block.bold ? 5 : 4)
                    previousEnd = run.map { $0.bounds.maxY }.max()
                }
            } else {
                // Full-width headings, headers and footers keep their horizontal positions.
                // Resolve vertical collisions only where their horizontal ranges overlap.
                var placed: [CGRect] = []
                for block in ordered {
                    let size = min(18, max(7, block.fontSize))
                    sizes[block.id] = size; spacing[block.id] = size * 0.2
                    var rect = block.bounds
                    rect.size.height = readingHeight(readingText[block.id]!, width: rect.width, size: size, bold: block.bold)
                    for prior in placed where min(prior.maxX, rect.maxX) - max(prior.minX, rect.minX) > 2 {
                        if rect.minY < prior.maxY + 3 { rect.origin.y = prior.maxY + 3 }
                    }
                    rightBounds[block.id] = rect; placed.append(rect)
                }
            }
        }
        if columns {
            let bodyBottom = lanes.filter { $0.key < 2 }.flatMap { $0.value }.compactMap { rightBounds[$0.id]?.maxY }.max() ?? 0
            for block in lanes[2] ?? [] where block.bounds.minY >= pageSize.height * 0.94 {
                if var rect = rightBounds[block.id] { rect.origin.y += max(0, bodyBottom + 18 - pageSize.height * 0.94); rightBounds[block.id] = rect }
            }
        }
        rightPageHeight = max(pageSize.height, (rightBounds.values.map { $0.maxY }.max() ?? 0) + 24)
    }
    func resize(available: CGFloat) {
        let pageWidth = max(260, (available - 72) / 2) * zoom
        let height = pageWidth * pageSize.height / max(1, pageSize.width)
        leftRect = CGRect(x: 24, y: 24, width: pageWidth, height: height)
        rightRect = CGRect(x: pageWidth + 48, y: 24, width: pageWidth, height: pageWidth * rightPageHeight / max(1, pageSize.width))
        setFrameSize(CGSize(width: max(available, pageWidth * 2 + 72), height: max(height, rightRect.height) + 48))
        needsDisplay = true
    }
    func map(_ rect: CGRect, right: Bool) -> CGRect {
        let page = right ? rightRect : leftRect
        return CGRect(x: page.minX + rect.minX * scale, y: page.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracked { removeTrackingArea(tracked) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracked = area
    }
    override func mouseMoved(with event: NSEvent) { focus(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); focus(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }
    func focus(at point: CGPoint) {
        let right = rightRect.contains(point)
        guard right || leftRect.contains(point) else { highlighted = nil; pointer = nil; onFocus?(nil); needsDisplay = true; return }
        let rect = right ? rightRect : leftRect
        let local = CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
        let found = blocks.filter { (right ? rightBounds[$0.id] ?? $0.bounds : $0.bounds).insetBy(dx: -2, dy: -2).contains(local) }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        highlighted = found?.id; pointer = found == nil ? nil : local; pointerOnRight = right
        onFocus?(highlighted); needsDisplay = true
    }
    func background(_ rect: CGRect) -> NSColor {
        guard let pixels else { return .white }
        let x = max(0, min(pixels.pixelsWide - 1, Int((rect.minX - 2) / pageSize.width * CGFloat(pixels.pixelsWide))))
        let y = max(0, min(pixels.pixelsHigh - 1, Int((rect.midY) / pageSize.height * CGFloat(pixels.pixelsHigh))))
        let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .white
        // Avoid painting with a foreground pixel accidentally sampled from a rule or figure.
        return color.redComponent + color.greenComponent + color.blueComponent > 2.1 ? color : .white
    }
    func textStyle(_ size: CGFloat, bold: Bool, lineSpacing: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing ?? max(0, size * 0.20)
        paragraph.paragraphSpacing = size * 0.45
        let regular = NSFont(name: "STSong", size: size) ?? NSFont(name: "Songti SC", size: size) ?? NSFont.systemFont(ofSize: size)
        let font = bold ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
        return [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
    }
    func styled(_ text: String, size: CGFloat, bold: Bool, lineSpacing: CGFloat? = nil) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text, attributes: textStyle(size, bold: bold, lineSpacing: lineSpacing))
        return value
    }
    func fittedSize(_ text: String, block: LayoutBlock) -> CGFloat {
        var size = block.fontSize
        let minimum = min(8, block.fontSize)
        while size > minimum {
            let bounds = styled(text, size: size, bold: block.bold).boundingRect(with: CGSize(width: block.bounds.width, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            if bounds.height <= block.bounds.height - (block.lines.count > 1 ? size * 0.55 : 0) && bounds.width <= block.bounds.width + 0.5 { return size }
            size -= 0.25
        }
        return minimum
    }
    func fittedSpacing(_ text: String, block: LayoutBlock, size: CGFloat) -> CGFloat {
        let measured = styled(text, size: size, bold: block.bold, lineSpacing: 0).boundingRect(with: CGSize(width: block.bounds.width, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = max(1, floor(measured.height / (size * 1.2)))
        guard lines > 1 else { return 0 }
        var spacing = min(size * 0.65, max(0, (block.bounds.height - measured.height - (block.lines.count > 1 ? size * 0.55 : 0)) / (lines - 1)))
        while spacing > 0 {
            let box = styled(text, size: size, bold: block.bold, lineSpacing: spacing).boundingRect(with: CGSize(width: block.bounds.width, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            if box.height <= block.bounds.height - (block.lines.count > 1 ? size * 0.55 : 0) { return spacing }
            spacing -= 0.25
        }
        return 0
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); dirtyRect.fill()
        guard let thumbnail else { return }
        NSColor.white.setFill(); leftRect.fill(); rightRect.fill()
        thumbnail.draw(in: leftRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let originalRight = CGRect(x: rightRect.minX, y: rightRect.minY, width: leftRect.width, height: leftRect.height)
        thumbnail.draw(in: originalRight, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        // Never slice the original artwork into bands. Erase source text before column flow.
        for block in blocks where readingText[block.id] != nil {
            for line in block.lines {
                background(line).setFill(); map(line.insetBy(dx: -1, dy: -1.1), right: true).fill()
            }
        }
        for block in blocks {
            guard renderOwner[block.id, default: block.id] == block.id, let text = readingText[block.id], let renderBounds = rightBounds[block.id] else { continue }
            let size = sizes[block.id] ?? block.fontSize
            // Measure and draw in the same PDF-point coordinate system at every zoom level.
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rightRect.minX, yBy: rightRect.minY)
            transform.scale(by: scale); transform.concat()
            (text as NSString).draw(with: renderBounds, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textStyle(size, bold: block.bold, lineSpacing: size * 0.2))
            NSGraphicsContext.restoreGraphicsState()
        }
        for id in Set(draftIDs.map { renderOwner[$0, default: $0] }) {
            guard let rect = rightBounds[id] else { continue }
            let target = map(rect, right: true)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: CGRect(x: target.minX - 7, y: target.minY + 3, width: 4, height: 4)).fill()
        }
        if let id = highlighted, let block = blocks.first(where: { $0.id == id }) {
            for right in [false, true] {
                let owner = renderOwner[block.id, default: block.id]
                let originalGroup = blocks.filter { renderOwner[$0.id, default: $0.id] == owner }.reduce(CGRect.null) { $0.union($1.bounds) }
                let rect = map(right ? rightBounds[block.id] ?? block.bounds : originalGroup, right: right).insetBy(dx: -2, dy: -2)
                NSColor.systemYellow.withAlphaComponent(0.23).setFill(); rect.fill()
                NSColor.systemYellow.withAlphaComponent(0.8).setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 1; outline.stroke()
            }
            if let pointer {
                let opposite = pointerOnRight ? leftRect : rightRect
                let from = pointerOnRight ? rightBounds[block.id] ?? block.bounds : block.bounds
                let to = pointerOnRight ? block.bounds : rightBounds[block.id] ?? block.bounds
                let x = to.minX + (pointer.x - from.minX) / max(1, from.width) * to.width
                let y = to.minY + (pointer.y - from.minY) / max(1, from.height) * to.height
                let point = CGPoint(x: opposite.minX + x * scale, y: opposite.minY + y * scale)
                NSColor.systemTeal.setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)); ring.lineWidth = 2; ring.stroke()
            }
        }
    }
}
final class PairedScrollView: NSScrollView {
    let canvas = PairedCanvas()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); documentView = canvas
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        drawsBackground = true; backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func layout() { super.layout(); canvas.resize(available: contentSize.width) }
}
struct PairedPDFPane: NSViewRepresentable {
    let page: PDFPage
    let blocks: [LayoutBlock]
    let translated: [Int: String]
    let zoom: CGFloat
    var draftIDs: Set<Int> = []
    let onFocus: (Int?) -> Void
    func makeNSView(context: Context) -> PairedScrollView { PairedScrollView(frame: .zero) }
    func updateNSView(_ view: PairedScrollView, context: Context) {
        let changed = view.canvas.pdfPage !== page
        view.canvas.configure(page: page, blocks: blocks, translated: translated)
        view.canvas.draftIDs = draftIDs
        view.canvas.zoom = zoom; view.canvas.onFocus = onFocus
        view.canvas.resize(available: view.contentSize.width)
        if changed { view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView) }
    }
}

func layoutCheck(input: String, output: String) throws {
    let pageIndex = CommandLine.arguments.firstIndex(of: "--page-index").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    guard let doc = PDFDocument(url: URL(fileURLWithPath: input)), let page = doc.page(at: pageIndex) else { throw TranslationError(message: "Test PDF unavailable") }
    let blocks = pageBlocks(page)
    check(!blocks.isEmpty)
    check(Set(blocks.map(\.id)).count == blocks.count)
    let canvas = PairedCanvas(frame: .zero)
    func sampleTranslation(_ source: String) -> String {
        let known: [String: String] = [
            "RESEARCH  /  BILINGUAL READING": "研究 / 双语阅读",
            "PDF": "PDF", "1": "1", "Abstract": "摘要", "Methods": "方法", "Results": "结果",
            "A Study of Document Translation": "文档翻译研究",
            "Preserving layout and linking corresponding paragraphs": "保留页面结构，关联原文与译文段落",
            "Figure 1. Original chart remains in place.": "图 1：原始图表保留在原位置。"
        ]
        if let match = known[source] { return match }
        if source.hasPrefix("This study") { return "本研究探讨双语阅读。原始文档包含标题、文字块和图形。翻译应保留页面结构，并将相关段落同时呈现。" }
        if source.hasPrefix("Readers") { return "读者可以指向任意一侧，使对应段落同时高亮。滚动时，左右两页一起移动。" }
        if source.hasPrefix("We compared") { return "我们比较了不同版式的文档，并提取每个段落及其在页面上的坐标。" }
        if source.hasPrefix("The system") { return "系统独立翻译每个文字块，并保留其页面位置。图形继续显示在原位。" }
        if source.hasPrefix("The paired") { return "对照视图将原文和译文放在相对应的位置，方便逐段阅读与比较。" }
        if source.hasPrefix("Hovering") { return "鼠标悬停在文字块上时，两边同时高亮对应段落。圆环表示另一侧的相对位置。" }
        return "用于验证版式和段落联动的测试译文。"
    }
    var testTranslations = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, sampleTranslation($0.text)) })
    if CommandLine.arguments.contains("--use-reference"), let chinese = doc.page(at: 1)?.string {
        func segment(_ start: String, _ end: String) -> String? {
            guard let a = chinese.range(of: start), let b = chinese.range(of: end, range: a.upperBound..<chinese.endIndex) else { return nil }
            return String(chinese[a.lowerBound..<b.lowerBound]).replacingOccurrences(of: "\n", with: "")
        }
        let pairs = [("Objective", "研究目的", "方法本研究"), ("Methods", "方法本研究", "结果在"), ("Results", "结果在", "结论"), ("Conclusion", "结论", "关键词")]
        testTranslations = [:]
        for block in blocks {
            if let pair = pairs.first(where: { block.text.hasPrefix($0.0) }), let text = segment(pair.1, pair.2) { testTranslations[block.id] = text }
        }
        print("Reference paragraphs mapped:", testTranslations.count)
        check(testTranslations.count == 4)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--cached-layout"), CommandLine.arguments.count > i + 1 {
        let cached = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])))
        testTranslations = Dictionary(uniqueKeysWithValues: blocks.compactMap { block in cached[translationKey(pageIndex, block.id)].map { (block.id, $0) } })
        print("Cached paragraphs:", testTranslations.count)
    }
    if CommandLine.arguments.contains("--dump-blocks") {
        for block in blocks { print(block.id, block.bounds, block.text.prefix(70)) }
    }
    if CommandLine.arguments.contains("--long-layout") {
        testTranslations = [:]
        let block = blocks.first(where: { $0.text.hasPrefix("Methods") }) ?? blocks[0]
        testTranslations[block.id] = String(repeating: "这是一段用于验证完整阅读的较长译文，包含研究方法、病例数据和分析结果，所有文字必须直接显示在页面中。\n", count: 24) + "【全文结束标记】"
    }
    canvas.configure(page: page, blocks: blocks, translated: testTranslations)
    for block in blocks {
        if canvas.renderOwner[block.id, default: block.id] == block.id, let text = canvas.readingText[block.id], let rect = canvas.rightBounds[block.id] {
            check(rect.height >= canvas.readingHeight(text, width: rect.width, size: canvas.sizes[block.id]!, bold: block.bold))
        }
    }
    if CommandLine.arguments.contains("--long-layout") { check(canvas.rightPageHeight > canvas.pageSize.height) }

    let owners = blocks.filter { canvas.renderOwner[$0.id, default: $0.id] == $0.id }
    for (i, block) in owners.enumerated() {
        guard let first = canvas.rightBounds[block.id] else { continue }
        for other in owners.dropFirst(i + 1) {
            guard let second = canvas.rightBounds[other.id] else { continue }
            let overlap = first.intersection(second)
            check(overlap.isNull || overlap.width < 1 || overlap.height < 1)
        }
    }
    print("PASS: translated paragraph rectangles do not overlap")
    canvas.resize(available: 1400)
    let target = blocks.first(where: { $0.text.hasPrefix(CommandLine.arguments.contains("--use-reference") ? "Methods" : "The paired") }) ?? blocks[min(2, blocks.count - 1)]
    for block in blocks {
        for right in [false, true] {
            let rect = canvas.map(right ? canvas.rightBounds[block.id] ?? block.bounds : block.bounds, right: right)
            canvas.focus(at: CGPoint(x: rect.midX, y: rect.midY))
            check(canvas.highlighted == block.id || (right && canvas.renderOwner[canvas.highlighted ?? -1] == canvas.renderOwner[block.id] && canvas.renderOwner[block.id] != nil))
        }
    }
    canvas.zoom = 1.8; canvas.resize(available: 1400)
    let zoomRect = canvas.map(canvas.rightBounds[target.id] ?? target.bounds, right: true)
    canvas.focus(at: CGPoint(x: zoomRect.midX, y: zoomRect.midY))
    check(canvas.highlighted == target.id)
    canvas.zoom = 1; canvas.resize(available: 1400)
    let mapped = canvas.map(target.bounds, right: false)
    canvas.focus(at: CGPoint(x: mapped.midX, y: mapped.midY))
    check(canvas.highlighted == target.id)
    let mappedRight = canvas.map(canvas.rightBounds[target.id] ?? target.bounds, right: true)
    canvas.focus(at: CGPoint(x: mappedRight.midX, y: mappedRight.midY))
    check(canvas.highlighted == target.id); check(canvas.pointerOnRight)
    check(mappedRight.width > 0 && mappedRight.height > 0)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.frame.width), pixelsHigh: Int(canvas.frame.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: canvas.frame.height); context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    canvas.draw(canvas.bounds)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("PASS: \(blocks.count) layout blocks, stable IDs, bidirectional hit testing, paired geometry; rendered \(output)")
}

final class ParagraphRegressionPage: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Songti SC", size: 12) ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        let left = ["医院作为公益事业单位承担患者收治", "任务做好院内卫生消毒管控工作可以", "降低多种疾病感染风险提升管理水平", "同时关注医院卫生管理与感染控制的", "临床实践。"]
        let right = ["研究纳入临床病例并开展持续监测", "比较不同管理方式对于感染风险及", "医疗质量的影响并记录观察结果和", "患者基本信息保证数据完整准确以", "支持临床决策。"]
        for i in 0..<5 {
            (left[i] as NSString).draw(at: CGPoint(x: i == 0 ? 64 : 40, y: 80 + i * 24), withAttributes: attrs)
            (right[i] as NSString).draw(at: CGPoint(x: i == 0 ? 354 : 330, y: 80 + i * 24), withAttributes: attrs)
        }
        ("下一段内容需要独立显示以保证段落对应。" as NSString).draw(at: CGPoint(x: 64, y: 225), withAttributes: attrs)
    }
}
func paragraphRegressionCheck() throws {
    let view = ParagraphRegressionPage(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
    let doc = PDFDocument(data: view.dataWithPDF(inside: view.bounds))!
    let blocks = pageBlocks(doc.page(at: 0)!)
    let left = blocks.first { $0.text.hasPrefix("医院") }!
    let right = blocks.first { $0.text.hasPrefix("研究") }!
    check(left.lines.count == 5); check(right.lines.count == 5)
    check(left.bounds.maxX < right.bounds.minX)
    check(blocks.contains { $0.text.hasPrefix("下") && $0.lines.count == 1 })
    print("PASS: first-line Chinese indent, wide leading, interleaved columns, paragraph separation")
}
