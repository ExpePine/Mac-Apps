import SwiftUI
import AppKit

/// A native macOS table (NSTableView). It only creates views for the rows and columns on screen
/// and reuses them while scrolling, so thousands of rows stay smooth.
///
/// Frozen columns: the first `frozenColumns` columns live in a second table on the left that scrolls
/// vertically in sync with the main table but never sideways. The header row is always fixed.
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
    var frozenColumns = 0
    var onHeaderClick: ((Int) -> Void)? = nil
    var onSelectRow: ((SheetRow?) -> Void)? = nil
    var onDoubleClickRow: ((SheetRow) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        let container = NSView()

        let left = c.makeTable()
        let right = c.makeTable()
        let leftScroll = Self.scrollView(for: left, horizontal: false)
        let rightScroll = Self.scrollView(for: right, horizontal: true)

        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        rightScroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftScroll)
        container.addSubview(rightScroll)

        let leftWidth = leftScroll.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            leftScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftScroll.topAnchor.constraint(equalTo: container.topAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftWidth,
            rightScroll.leadingAnchor.constraint(equalTo: leftScroll.trailingAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightScroll.topAnchor.constraint(equalTo: container.topAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        c.leftTable = left
        c.rightTable = right
        c.leftScroll = leftScroll
        c.rightScroll = rightScroll
        c.leftWidth = leftWidth
        c.startSyncing()
        return container
    }

    private static func scrollView(for table: NSTableView, horizontal: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = horizontal          // only the right side shows scrollers
        scroll.hasHorizontalScroller = horizontal
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay                  // keeps both sides the same height
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let left = c.leftTable, let right = c.rightTable else { return }

        let visible = columns.filter { $0 < headers.count }
        let frozenCount = max(0, min(frozenColumns, visible.count - 1))
        let frozen = Array(visible.prefix(frozenCount))
        let scrolling = Array(visible.dropFirst(frozenCount))

        // Rebuild columns only when the column set changes.
        let signature = "\(frozen)|\(scrolling)|" + visible.map { headers[$0] }.joined(separator: "|")
            + "#" + originalHeaders.joined(separator: "|")
        if signature != c.columnSignature {
            c.columnSignature = signature
            c.setColumns(frozen, on: left, parent: self)
            c.setColumns(scrolling, on: right, parent: self)
            c.updateLeftWidth()
        }

        // Header titles (with sort arrow and trigger-column emphasis).
        for table in [left, right] {
            for column in table.tableColumns {
                guard let index = Coordinator.columnIndex(column) else { continue }
                var title = index < headers.count ? headers[index] : ""
                if index == sortColumn { title += sortDescending ? "  ▼" : "  ▲" }
                column.title = title
                let font: NSFont = index == emphasizedColumn || table === left
                    ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                    : .systemFont(ofSize: NSFont.smallSystemFontSize)
                column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: font])
            }
        }

        if version != c.renderedVersion || rows.count != right.numberOfRows {
            c.renderedVersion = version
            left.reloadData()
            right.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SheetTableView?
        weak var leftTable: NSTableView?
        weak var rightTable: NSTableView?
        weak var leftScroll: NSScrollView?
        weak var rightScroll: NSScrollView?
        var leftWidth: NSLayoutConstraint?
        var columnSignature = ""
        var renderedVersion = -1
        private var syncing = false
        private var observers: [NSObjectProtocol] = []
        private let cellID = NSUserInterfaceItemIdentifier("SheetCell")

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func makeTable() -> NSTableView {
            let table = NSTableView()
            table.style = .plain
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.allowsColumnReordering = false
            table.allowsColumnResizing = true
            table.allowsMultipleSelection = false
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.rowHeight = 22
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
            table.headerView = NSTableHeaderView()
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.doubleAction = #selector(doubleClicked(_:))
            return table
        }

        func setColumns(_ indices: [Int], on table: NSTableView, parent: SheetTableView) {
            for col in table.tableColumns.reversed() { table.removeTableColumn(col) }
            for index in indices {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.width = index == 0 || table === leftTable ? 150 : 110
                column.minWidth = 40
                let name = parent.headers[index]
                let original = index < parent.originalHeaders.count ? parent.originalHeaders[index] : name
                column.headerToolTip = original == name ? name : "\(name)  (sheet column: \(original))"
                table.addTableColumn(column)
            }
        }

        func updateLeftWidth() {
            guard let left = leftTable else { return }
            let width = left.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
            leftWidth?.constant = width == 0 ? 0 : width + 1
        }

        /// Keep vertical scrolling, selection and column widths of both tables in step.
        func startSyncing() {
            guard let leftClip = leftScroll?.contentView, let rightClip = rightScroll?.contentView else { return }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: leftClip, queue: .main) { [weak self] _ in
                self?.syncScroll(from: leftClip, to: rightClip)
            })
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: rightClip, queue: .main) { [weak self] _ in
                self?.syncScroll(from: rightClip, to: leftClip)
            })
            if let left = leftTable {
                observers.append(nc.addObserver(forName: NSTableView.columnDidResizeNotification, object: left, queue: .main) { [weak self] _ in
                    self?.updateLeftWidth()
                })
            }
        }

        private func syncScroll(from source: NSClipView, to target: NSClipView) {
            guard !syncing else { return }
            syncing = true
            var origin = target.bounds.origin
            origin.y = source.bounds.origin.y
            target.scroll(to: origin)
            (target.superview as? NSScrollView)?.reflectScrolledClipView(target)
            syncing = false
        }

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
                           bold: index == parent.emphasizedColumn || tableView === leftTable,
                           background: parent.painter?.color(for: data, column: index))
            return cell
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let index = Self.columnIndex(tableColumn) else { return }
            parent?.onHeaderClick?(index)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let source = notification.object as? NSTableView else { return }
            syncing = true
            let other = source === leftTable ? rightTable : leftTable
            other?.selectRowIndexes(source.selectedRowIndexes, byExtendingSelection: false)
            syncing = false
            let row = source.selectedRow
            if let parent, row >= 0, row < parent.rows.count {
                parent.onSelectRow?(parent.rows[row])
            } else {
                parent?.onSelectRow?(nil)
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard let parent, row >= 0, row < parent.rows.count else { return }
            parent.onDoubleClickRow?(parent.rows[row])
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
