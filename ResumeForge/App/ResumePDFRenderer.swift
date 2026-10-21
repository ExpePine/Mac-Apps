import AppKit
import CoreGraphics

/// Renders a ResumeDoc to an A4 PDF using a TemplateSpec.
/// "Classic" is the original reference layout: centred bold name, centred contact line, bold CAPS headings with a rule,
/// company/location and title/dates split left–right, justified bullets, bold labels. Other templates vary fonts,
/// colours, heading style, section order and can use a sidebar column.
enum ResumePDFRenderer {
    static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4 in points

    static func render(_ doc: ResumeDoc, template: TemplateSpec = .classic) -> Data {
        let layout = Layout(spec: template)
        layout.build(doc)
        return layout.output(pageSize: pageSize)
    }
}

private final class Layout {
    struct Block {
        var height: (CGFloat) -> CGFloat
        var draw: (CGRect) -> Void
        var keepWithNext = false
        var spacingAfter: CGFloat = 0
    }

    let spec: TemplateSpec
    private var header: [Block] = []
    private var main: [Block] = []
    private var side: [Block] = []

    init(spec: TemplateSpec) { self.spec = spec }

    private var body: CGFloat { CGFloat(spec.baseSize) }
    private var accent: NSColor { NSColor(hex: spec.accentColor) }
    private var hasSidebar: Bool { spec.layout == "sidebar" }

    // MARK: Fonts & text

    private func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        var base: NSFont?
        if !spec.fontName.isEmpty { base = NSFont(name: spec.fontName, size: size) }
        if base == nil {
            let names = spec.font == "sans"
                ? ["Helvetica Neue", "Helvetica", "Avenir Next", "Arial"]
                : ["Times New Roman", "Georgia", "Baskerville"]
            base = names.lazy.compactMap { NSFont(name: $0, size: size) }.first
        }
        let f = base ?? NSFont.systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
    }

    private func style(_ align: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineSpacing = CGFloat(spec.lineSpacing)
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private func attr(_ s: String, size: CGFloat, bold: Bool = false, align: NSTextAlignment = .left,
                      color: NSColor = .black) -> NSMutableAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [
            .font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: style(align)
        ])
        highlightVerify(a)
        return a
    }

    private func labeled(_ label: String, _ text: String, size: CGFloat, align: NSTextAlignment = .justified) -> NSMutableAttributedString {
        let a = NSMutableAttributedString()
        if !label.isEmpty { a.append(attr(label + ": ", size: size, bold: true, align: align)) }
        a.append(attr(text, size: size, align: align))
        return a
    }

    /// Placeholders stand out in orange so they can't slip into a sent resume unnoticed.
    private func highlightVerify(_ a: NSMutableAttributedString) {
        let ns = a.string as NSString
        guard let re = try? NSRegularExpression(pattern: "\\[VERIFY\\]|\\[[A-Z]{1,3}\\]") else { return }
        for m in re.matches(in: a.string, range: NSRange(location: 0, length: ns.length)) {
            a.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m.range)
        }
    }

    private func measure(_ a: NSAttributedString, _ w: CGFloat) -> CGFloat {
        ceil(a.boundingRect(with: CGSize(width: max(10, w), height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private func draw(_ a: NSAttributedString, _ r: CGRect) {
        a.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: Block builders (append to a column)

    private func text(_ a: NSAttributedString, into col: inout [Block], after: CGFloat = 0, keep: Bool = false, indent: CGFloat = 0) {
        col.append(Block(
            height: { [unowned self] w in self.measure(a, w - indent) },
            draw: { [unowned self] r in self.draw(a, CGRect(x: r.minX + indent, y: r.minY, width: r.width - indent, height: r.height + 2)) },
            keepWithNext: keep, spacingAfter: after))
    }

    private func split(_ left: NSAttributedString, _ right: NSAttributedString, into col: inout [Block], after: CGFloat = 0, keep: Bool = true) {
        col.append(Block(
            height: { [unowned self] w in max(self.measure(left, w * 0.66), self.measure(right, w * 0.34)) },
            draw: { [unowned self] r in
                self.draw(left, CGRect(x: r.minX, y: r.minY, width: r.width * 0.66, height: r.height + 2))
                self.draw(right, CGRect(x: r.minX + r.width * 0.34, y: r.minY, width: r.width * 0.66, height: r.height + 2))
            },
            keepWithNext: keep, spacingAfter: after))
    }

    private func heading(_ title: String, into col: inout [Block]) {
        let s = spec.headingCaps ? title.uppercased() : title
        let size = CGFloat(spec.headingSize)
        let style = spec.headingStyle
        let textColor: NSColor = style == "band" ? .white : NSColor(hex: spec.headingColor)
        let a = attr(s, size: size, bold: true, color: textColor)
        let accent = self.accent
        col.append(Block(
            height: { [unowned self] w in self.measure(a, w - (style == "bar" ? 10 : 0)) + (style == "band" ? 8 : 4) },
            draw: { [unowned self] r in
                switch style {
                case "band":
                    accent.setFill()
                    NSBezierPath(rect: r).fill()
                    self.draw(a, CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: r.height))
                case "bar":
                    accent.setFill()
                    NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + 2, width: 4, height: r.height - 6)).fill()
                    self.draw(a, CGRect(x: r.minX + 10, y: r.minY, width: r.width - 10, height: r.height))
                case "none":
                    self.draw(a, CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
                default:
                    self.draw(a, CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: r.minX, y: r.maxY - 1))
                    path.line(to: CGPoint(x: r.maxX, y: r.maxY - 1))
                    path.lineWidth = 0.8
                    accent.setStroke()
                    path.stroke()
                }
            },
            keepWithNext: true, spacingAfter: 5))
    }

    private func bullet(_ a: NSAttributedString, into col: inout [Block], level: Int = 0, after: CGFloat = 2.5) {
        let indent: CGFloat = level == 0 ? 0 : 22
        let gap: CGFloat = 13
        let char = level == 0 ? spec.bullet : "•"
        let small = char == "●" || char == "■" || char == "▪"
        let dot = attr(char, size: small ? body * 0.67 : body, color: level == 0 ? accent : .black)
        col.append(Block(
            height: { [unowned self] w in self.measure(a, w - indent - gap) },
            draw: { [unowned self] r in
                self.draw(dot, CGRect(x: r.minX + indent + 1, y: r.minY + (small ? 3 : 0), width: gap, height: 14))
                self.draw(a, CGRect(x: r.minX + indent + gap, y: r.minY, width: r.width - indent - gap, height: r.height + 2))
            },
            keepWithNext: false, spacingAfter: after))
    }

    private func setLastSpacing(_ col: inout [Block], _ v: CGFloat) {
        if !col.isEmpty { col[col.count - 1].spacingAfter = v }
    }

    // MARK: Document

    func build(_ d: ResumeDoc) {
        // Header (full width)
        let align: NSTextAlignment = spec.nameAlign == "left" ? .left : (spec.nameAlign == "right" ? .right : .center)
        let onBand = spec.headerBand
        let nameColor = onBand ? NSColor.white : NSColor(hex: spec.nameColor)
        let contactColor = onBand ? NSColor.white : NSColor.black
        text(attr(spec.nameCaps ? d.name.uppercased() : d.name, size: CGFloat(spec.nameSize), bold: true, align: align, color: nameColor),
             into: &header, after: 3)
        if !d.contactLine.isEmpty {
            text(attr(d.contactLine, size: CGFloat(spec.contactSize), align: align, color: contactColor), into: &header, after: 0)
        }

        let sideSet = hasSidebar ? Set(spec.sidebarSections) : []
        for section in spec.sectionOrder {
            let inSide = sideSet.contains(section)
            if inSide { add(section, d, into: &side, narrow: true) } else { add(section, d, into: &main, narrow: false) }
        }
    }

    private func add(_ section: String, _ d: ResumeDoc, into col: inout [Block], narrow: Bool) {
        let title = spec.title(for: section)
        switch section {
        case "summary" where !d.summary.isEmpty:
            heading(title, into: &col)
            text(attr(d.summary, size: body, align: narrow ? .left : .justified), into: &col, after: 12)

        case "experience" where !d.experience.isEmpty:
            heading(title, into: &col)
            for (i, role) in d.experience.enumerated() {
                let company = spec.companyCaps ? role.company.uppercased() : role.company
                if narrow || spec.datesAlign == "inline" {
                    text(attr(company, size: body + 0.5, bold: true), into: &col, keep: true)
                    let line = [role.title, role.dates, role.location].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                    text(attr(line, size: body, color: NSColor(hex: "#444444")), into: &col, after: 3, keep: true)
                } else {
                    split(attr(company, size: body + 0.5, bold: true), attr(role.location, size: body + 0.5, align: .right), into: &col)
                    split(attr(role.title, size: body + 0.5), attr(role.dates, size: body + 0.5, align: .right), into: &col, after: 3)
                }
                for b in role.bullets where !b.text.isEmpty {
                    bullet(attr(b.text, size: body, align: narrow ? .left : .justified), into: &col)
                }
                if i < d.experience.count - 1 { setLastSpacing(&col, 8) }
            }
            setLastSpacing(&col, 12)

        case "achievements" where !d.achievements.isEmpty:
            heading(title, into: &col)
            for a in d.achievements {
                bullet(labeled(a.label, a.text, size: body, align: narrow ? .left : .justified), into: &col)
                for s in a.subItems where !s.isEmpty {
                    bullet(attr(s, size: body, align: .left), into: &col, level: 1, after: 1.5)
                }
            }
            setLastSpacing(&col, 12)

        case "education" where !d.education.isEmpty:
            heading(title, into: &col)
            for e in d.education {
                if narrow {
                    text(attr(e.qualification, size: body, bold: true), into: &col, keep: true)
                    text(attr([e.institution, e.location, e.year].filter { !$0.isEmpty }.joined(separator: ", "), size: body - 0.5),
                         into: &col, after: 6)
                } else {
                    split(attr(e.qualification.uppercased(), size: body + 0.5, bold: true), attr(e.location, size: body + 0.5, align: .right), into: &col)
                    split(attr(e.institution, size: body + 0.5), attr(e.year, size: body + 0.5, align: .right), into: &col, after: 6, keep: false)
                }
            }
            setLastSpacing(&col, 12)

        case "additional" where !d.additional.isEmpty:
            heading(title, into: &col)
            for l in d.additional where !l.value.isEmpty {
                if narrow {
                    text(attr(l.label, size: body, bold: true), into: &col, keep: true)
                    text(attr(l.value, size: body - 0.5), into: &col, after: 6)
                } else {
                    text(labeled(l.label, l.value, size: body, align: .left), into: &col, after: 5)
                }
            }
            setLastSpacing(&col, 12)

        default:
            break
        }
    }

    // MARK: Pagination & PDF output

    private struct Placed { let block: Block; let rect: CGRect }

    private func paginate(_ blocks: [Block], x: CGFloat, width: CGFloat, firstTop: CGFloat, top: CGFloat, bottom: CGFloat) -> [[Placed]] {
        var pages: [[Placed]] = [[]]
        var y = firstTop
        let heights = blocks.map { $0.height(width) }
        for (i, b) in blocks.enumerated() {
            var needed = heights[i]
            var j = i
            while blocks[j].keepWithNext, j + 1 < blocks.count {
                needed += blocks[j].spacingAfter + heights[j + 1]
                j += 1
            }
            let pageTop = pages.count == 1 ? firstTop : top
            if y + needed > bottom, y > pageTop + 1 {
                pages.append([])
                y = top
            }
            pages[pages.count - 1].append(Placed(block: b, rect: CGRect(x: x, y: y, width: width, height: heights[i])))
            y += heights[i] + b.spacingAfter
        }
        return pages
    }

    func output(pageSize: CGSize) -> Data {
        let pdf = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }

        let margin = CGFloat(spec.margin)
        let fullWidth = pageSize.width - 2 * margin
        let bottom = pageSize.height - margin

        // Header height (+ band)
        let headerHeights = header.map { $0.height(fullWidth) }
        let headerHeight = headerHeights.enumerated().reduce(CGFloat(0)) { $0 + $1.element + header[$1.offset].spacingAfter }
        let bandPad: CGFloat = spec.headerBand ? 16 : 0
        let headerTop = margin + bandPad
        let bodyTop = headerTop + headerHeight + bandPad + 14

        // Columns
        let gutter: CGFloat = 18
        let sideW = hasSidebar ? (fullWidth * CGFloat(spec.sidebarWidth)).rounded() : 0
        let mainW = hasSidebar ? fullWidth - sideW - gutter : fullWidth
        let sideOnLeft = spec.sidebarSide != "right"
        let mainX = hasSidebar && sideOnLeft ? margin + sideW + gutter : margin
        let sideX = sideOnLeft ? margin : margin + mainW + gutter

        let mainPages = paginate(main, x: mainX, width: mainW, firstTop: bodyTop, top: margin, bottom: bottom)
        let sidePages = hasSidebar ? paginate(side, x: sideX, width: sideW, firstTop: bodyTop, top: margin, bottom: bottom) : []
        let pageCount = max(mainPages.count, sidePages.count, 1)

        for p in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

            if hasSidebar {
                let bg = NSColor(hex: spec.sidebarBackground)
                if spec.sidebarBackground.uppercased() != "#FFFFFF" {
                    bg.setFill()
                    let top = p == 0 ? (spec.headerBand ? headerTop + headerHeight + bandPad : bodyTop - 8) : 0
                    let x = sideOnLeft ? 0 : sideX - gutter / 2
                    let w = sideOnLeft ? sideX + sideW + gutter / 2 : pageSize.width - x
                    NSBezierPath(rect: CGRect(x: x, y: top, width: w, height: pageSize.height - top)).fill()
                }
            }

            if p == 0 {
                if spec.headerBand {
                    NSColor(hex: spec.headerBandColor).setFill()
                    NSBezierPath(rect: CGRect(x: 0, y: 0, width: pageSize.width, height: headerTop + headerHeight + bandPad)).fill()
                }
                var y = headerTop
                for (i, b) in header.enumerated() {
                    b.draw(CGRect(x: margin, y: y, width: fullWidth, height: headerHeights[i]))
                    y += headerHeights[i] + b.spacingAfter
                }
            }

            if p < mainPages.count { for item in mainPages[p] { item.block.draw(item.rect) } }
            if p < sidePages.count { for item in sidePages[p] { item.block.draw(item.rect) } }

            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return pdf as Data
    }
}
