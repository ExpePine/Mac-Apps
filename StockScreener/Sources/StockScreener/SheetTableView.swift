import SwiftUI
import AppKit

/// A native macOS table (NSTableView). It only creates views for the rows and columns on screen
/// and reuses them while scrolling, so thousands of rows stay smooth.
struct SheetTableView: NSViewRepresentable {
    let headers: [String]
    var originalHeaders: [String] = []
    let columns: [Int]                      // which sheet columns to show, in order
    let rows: [SheetRow]
    let version: Int                        // bump to force a reload
    var emphasizedColumn: Int? = nil
    var sortColumn: Int? = nil
    var sortDescending = false
    var painter: CellPainter? = nil
    var onHeaderClick: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 22
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        table.headerView = NSTableHeaderView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }

        // Rebuild columns only when the column set changes.
        let signature = columns.map { "\($0):\($0 < headers.count ? headers[$0] : "")" }.joined(separator: "|")
            + "#" + originalHeaders.joined(separator: "|")
        if signature != c.columnSignature {
            c.columnSignature = signature
            for col in table.tableColumns.reversed() { table.removeTableColumn(col) }
            for index in columns where index < headers.count {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.width = index == 0 ? 150 : 110
                column.minWidth = 40
                let original = index < originalHeaders.count ? originalHeaders[index] : headers[index]
                column.headerToolTip = original == headers[index]
                    ? headers[index] : "\(headers[index])  (sheet column: \(original))"
                table.addTableColumn(column)
            }
        }

        // Header titles (with sort arrow and trigger-column emphasis).
        for column in table.tableColumns {
            guard let index = Coordinator.columnIndex(column) else { continue }
            var title = index < headers.count ? headers[index] : ""
            if index == sortColumn { title += sortDescending ? "  ▼" : "  ▲" }
            column.title = title
            let font: NSFont = index == emphasizedColumn
                ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: font])
        }

        if version != c.renderedVersion || rows.count != table.numberOfRows {
            c.renderedVersion = version
            table.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SheetTableView?
        weak var table: NSTableView?
        var columnSignature = ""
        var renderedVersion = -1
        private let cellID = NSUserInterfaceItemIdentifier("SheetCell")

        static func columnIndex(_ column: NSTableColumn) -> Int? {
            Int(column.identifier.rawValue.dropFirst())
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn, let index = Self.columnIndex(tableColumn),
                  row < parent.rows.count else { return nil }
            let data = parent.rows[row]

            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? SheetCellView) ?? {
                let v = SheetCellView()
                v.identifier = cellID
                return v
            }()
            let text = data.text(index)
            let isNumber = data.number(index) != nil
            cell.configure(text: text,
                           alignRight: isNumber,
                           bold: index == parent.emphasizedColumn,
                           background: parent.painter?.color(for: data, column: index))
            return cell
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let index = Self.columnIndex(tableColumn) else { return }
            parent?.onHeaderClick?(index)
        }
    }
}

/// One table cell: a label on an optional colored background.
final class SheetCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, alignRight: Bool, bold: Bool, background: NSColor?) {
        label.stringValue = text
        label.alignment = alignRight ? .right : .left
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: bold ? .semibold : .regular)
        toolTip = text.count > 14 ? text : nil
        layer?.backgroundColor = background?.cgColor
    }
}
