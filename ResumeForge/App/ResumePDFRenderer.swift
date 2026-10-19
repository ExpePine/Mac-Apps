import AppKit
import CoreGraphics

/// Renders a ResumeDoc to an A4 PDF in the reference layout:
/// centred bold name, centred contact line, bold CAPS section headings with a rule underneath,
/// company/location and title/dates on split left–right lines, justified bullets,
/// bold labels for achievements and additional details. Serif type throughout.
enum ResumePDFRenderer {
    static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4 in points
    static let margin: CGFloat = 46

    static func render(_ doc: ResumeDoc) -> Data {
        let layout = Layout()
        layout.build(doc)
        return layout.output(pageSize: pageSize, margin: margin)
    }
}

private final class Layout {
    struct Block {
        var height: (CGFloat) -> CGFloat
        var draw: (CGRect) -> Void
        var keepWithNext = false
        var spacingAfter: CGFloat = 0
    }

    private var blocks: [Block] = []
    private let bodySize: CGFloat = 10.5

    // MARK: Fonts & text

    static func serif(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont(name: "Times New Roman", size: size)
            ?? NSFont(name: "Georgia", size: size)
            ?? NSFont.systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    private func style(_ align: NSTextAlignment, spacing: CGFloat = 1) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineSpacing = spacing
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private func attr(_ s: String, size: CGFloat, bold: Bool = false, align: NSTextAlignment = .left) -> NSMutableAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [
            .font: Self.serif(size, bold: bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style(align)
        ])
        highlightVerify(a)
        return a
    }

    /// Bold "Label: " followed by regular text (achievements, additional details).
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
        ceil(a.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private func draw(_ a: NSAttributedString, _ r: CGRect) {
        a.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: Block builders

    private func text(_ a: NSAttributedString, after: CGFloat = 0, keep: Bool = false, indent: CGFloat = 0) {
        blocks.append(Block(
            height: { [unowned self] w in self.measure(a, w - indent) },
            draw: { [unowned self] r in self.draw(a, CGRect(x: r.minX + indent, y: r.minY, width: r.width - indent, height: r.height + 2)) },
            keepWithNext: keep, spacingAfter: after))
    }

    private func split(_ left: NSAttributedString, _ right: NSAttributedString, after: CGFloat = 0, keep: Bool = true) {
        blocks.append(Block(
            height: { [unowned self] w in max(self.measure(left, w * 0.66), self.measure(right, w * 0.34)) },
            draw: { [unowned self] r in
                self.draw(left, CGRect(x: r.minX, y: r.minY, width: r.width * 0.66, height: r.height + 2))
                self.draw(right, CGRect(x: r.minX + r.width * 0.34, y: r.minY, width: r.width * 0.66, height: r.height + 2))
            },
            keepWithNext: keep, spacingAfter: after))
    }

    private func section(_ title: String) {
        let a = attr(title.uppercased(), size: 12.5, bold: true)
        blocks.append(Block(
            height: { [unowned self] w in self.measure(a, w) + 4 },
            draw: { [unowned self] r in
                self.draw(a, CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
                let y = r.maxY - 1
                let path = NSBezierPath()
                path.move(to: CGPoint(x: r.minX, y: y))
                path.line(to: CGPoint(x: r.maxX, y: y))
                path.lineWidth = 0.8
                NSColor.black.setStroke()
                path.stroke()
            },
            keepWithNext: true, spacingAfter: 5))
    }

    private func bullet(_ a: NSAttributedString, level: Int = 0, after: CGFloat = 2.5) {
        let indent: CGFloat = level == 0 ? 0 : 26
        let gap: CGFloat = 14
        let dot = attr(level == 0 ? "●" : "•", size: level == 0 ? 7 : bodySize)
        blocks.append(Block(
            height: { [unowned self] w in self.measure(a, w - indent - gap) },
            draw: { [unowned self] r in
                let dotY = level == 0 ? r.minY + 3 : r.minY
                self.draw(dot, CGRect(x: r.minX + indent + 2, y: dotY, width: gap, height: 14))
                self.draw(a, CGRect(x: r.minX + indent + gap, y: r.minY, width: r.width - indent - gap, height: r.height + 2))
            },
            keepWithNext: false, spacingAfter: after))
    }

    // MARK: Document

    func build(_ d: ResumeDoc) {
        text(attr(d.name.uppercased(), size: 20, bold: true, align: .center), after: 3)
        if !d.contactLine.isEmpty { text(attr(d.contactLine, size: 12, align: .center), after: 12) }

        if !d.summary.isEmpty {
            section("Summary")
            text(attr(d.summary, size: bodySize, align: .justified), after: 12)
        }

        if !d.experience.isEmpty {
            section("Work Experience")
            for (i, role) in d.experience.enumerated() {
                split(attr(role.company.uppercased(), size: 11, bold: true),
                      attr(role.location, size: 11, align: .right))
                split(attr(role.title, size: 11), attr(role.dates, size: 11, align: .right), after: 3)
                for b in role.bullets where !b.text.isEmpty {
                    bullet(attr(b.text, size: bodySize, align: .justified))
                }
                if i < d.experience.count - 1 { blocks[blocks.count - 1].spacingAfter = 8 }
            }
            blocks[blocks.count - 1].spacingAfter = 12
        }

        if !d.achievements.isEmpty {
            section("Key Achievements")
            for a in d.achievements {
                bullet(labeled(a.label, a.text, size: bodySize))
                for s in a.subItems where !s.isEmpty {
                    bullet(attr(s, size: bodySize, align: .left), level: 1, after: 1.5)
                }
            }
            blocks[blocks.count - 1].spacingAfter = 12
        }

        if !d.education.isEmpty {
            section("Education")
            for e in d.education {
                split(attr(e.qualification.uppercased(), size: 11, bold: true), attr(e.location, size: 11, align: .right))
                split(attr(e.institution, size: 11), attr(e.year, size: 11, align: .right), after: 6, keep: false)
            }
            blocks[blocks.count - 1].spacingAfter = 12
        }

        if !d.additional.isEmpty {
            section("Additional Details")
            for l in d.additional where !l.value.isEmpty {
                text(labeled(l.label, l.value, size: bodySize, align: .left), after: 5)
            }
        }
    }

    // MARK: Pagination & PDF output

    func output(pageSize: CGSize, margin: CGFloat) -> Data {
        let pdf = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }

        let width = pageSize.width - 2 * margin
        let bottom = pageSize.height - margin
        var y = margin

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            y = margin
        }
        func endPage() {
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        let heights = blocks.map { $0.height(width) }
        beginPage()
        for (i, b) in blocks.enumerated() {
            var needed = heights[i]
            // Keep headings/role headers with the first line of what follows.
            var j = i
            while blocks[j].keepWithNext, j + 1 < blocks.count {
                needed += blocks[j].spacingAfter + heights[j + 1]
                j += 1
            }
            if y + needed > bottom, y > margin + 1 {
                endPage()
                beginPage()
            }
            b.draw(CGRect(x: margin, y: y, width: width, height: heights[i]))
            y += heights[i] + b.spacingAfter
        }
        endPage()
        ctx.closePDF()
        return pdf as Data
    }
}
