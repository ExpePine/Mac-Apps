import SwiftUI
import AppKit
import QuartzCore

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
    /// Double right-click on a row (the right-click menu waits a moment so a second click can be noticed).
    var onDoubleRightClickRow: ((SheetRow) -> Void)? = nil
    /// Two small dots next to the first column: rest the pointer on one (or click it) → (row, 0 = Chart 1 / 1 = Chart 2).
    var onHoverChart: ((SheetRow, Int) -> Void)? = nil
    /// Column (index into headers) the dots sit after — normally the symbol; nil = the first column.
    var chartDotsAfter: Int? = nil
    /// Previous day's text when this cell's value changed since then (cell gets a shaded border), else nil.
    var changedCell: ((SheetRow, Int) -> String?)? = nil
    var changedVersion = 0
    /// When set, each header shows a small ▼ that opens this panel for the column.
    var columnMenu: ((Int) -> AnyView)? = nil
    /// Columns that have conditions or colors (their ▼ is highlighted).
    var markedColumns: Set<Int> = []
    /// When set, an "E" column is shown first: its color per row, and the panel it opens when clicked.
    var eColor: ((SheetRow) -> NSColor)? = nil
    var ePanel: ((SheetRow) -> AnyView)? = nil
    /// Cells to flash briefly ("what changed since the previous day").
    var flash: FlashSpec? = nil
    /// When set, an "S" (screenshots) column follows E: its color per row, and what a click does.
    var sColor: ((SheetRow) -> NSColor)? = nil
    var onSClick: ((SheetRow) -> Void)? = nil
    /// When set, a "P" (my pick) column: its colour per row, and what a click does.
    var pColor: ((SheetRow) -> NSColor)? = nil
    var onPClick: ((SheetRow) -> Void)? = nil
    /// Find (⌘F): cells containing this text are outlined; `findCurrent` (row index, column) is focused.
    var findQuery = ""
    var findCurrent: FindMatch? = nil
    /// All selected rows (⌘-click / ⇧-click select several).
    var onSelectRows: (([SheetRow]) -> Void)? = nil
    /// Right-click menu for a row: (title, action) pairs; title "-" adds a separator.
    var rowMenu: ((SheetRow) -> [(String, () -> Void)])? = nil
    /// Drag column headers to reorder: called with the new order of sheet columns (frozen ones first).
    var onColumnOrder: (([Int]) -> Void)? = nil
    /// Right-click a header: hide it / show a hidden one / open the column chooser.
    var onHideColumn: ((Int) -> Void)? = nil
    var hiddenColumns: [Int] = []
    var onShowColumn: ((Int) -> Void)? = nil
    var onChooseColumns: (() -> Void)? = nil

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
        let signature = "E\(eColor != nil)S\(sColor != nil)P\(pColor != nil)C\(onHoverChart != nil)|\(frozen)|\(scrolling)|" + visible.map { headers[$0] }.joined(separator: "|")
            + "#" + originalHeaders.joined(separator: "|")
        if signature != c.columnSignature, c.expectedOrder == visible {
            c.columnSignature = signature        // the user just dragged a column: the tables already look like this
            c.expectedOrder = nil
        }
        c.expectedOrder = nil
        for t in [left, right] { t.allowsColumnReordering = onColumnOrder != nil }
        if signature != c.columnSignature {
            c.columnSignature = signature
            c.setColumns(frozen, on: left, parent: self)
            c.setColumns(scrolling, on: right, parent: self)
            if pColor != nil {
                c.addBadgeColumn(Coordinator.pID, title: "P",
                                 tip: "P — My pick. Grey: not my pick · Green: my pick · Orange: OK selection. Click to change.",
                                 to: frozen.isEmpty ? right : left)
            }
            if sColor != nil {
                c.addBadgeColumn(Coordinator.sID, title: "S",
                                 tip: "S — Screenshots of this stock. Grey: none · Orange: saved · Green: newest is under 7 days old",
                                 to: frozen.isEmpty ? right : left)
            }
            if eColor != nil {
                c.addEColumn(to: frozen.isEmpty ? right : left)
            }
            if onHoverChart != nil {
                let after = chartDotsAfter
                let target = after.map { a in left.tableColumns.contains { Coordinator.columnIndex($0) == a } ? left : right } ?? (frozen.isEmpty ? right : left)
                c.addChartDotsColumn(to: target, after: after)
            }
            c.updateLeftWidth()
        }

        // Header titles (with sort arrow and trigger-column emphasis).
        for table in [left, right] {
            for column in table.tableColumns {
                guard let index = Coordinator.columnIndex(column) else { continue }
                var title = index < headers.count ? headers[index] : ""
                if index == sortColumn { title += sortDescending ? "  ▼" : "  ▲" }
                column.title = title
                if let cell = column.headerCell as? MenuHeaderCell {
                    cell.showsMenu = columnMenu != nil
                    cell.isMarked = markedColumns.contains(index)
                }
                (table.headerView as? MenuHeaderView)?.menuEnabled = columnMenu != nil
                let font: NSFont = index == emphasizedColumn || table === left
                    ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                    : .systemFont(ofSize: NSFont.smallSystemFontSize)
                column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: font])
            }
        }

        left.headerView?.needsDisplay = true
        right.headerView?.needsDisplay = true

        let flashToken = flash?.token ?? 0
        let findKey = findQuery + "|\(findCurrent?.row ?? -1),\(findCurrent?.column ?? -1)"
        if version &+ changedVersion &* 7919 != c.renderedVersion || rows.count != right.numberOfRows || flashToken != c.flashToken || findKey != c.findKey {
            c.flashToken = flashToken
            c.renderedVersion = version &+ changedVersion &* 7919
            c.findKey = findKey
            left.reloadData()
            right.reloadData()
        }
        if let m = findCurrent, m != c.scrolledMatch, m.row < rows.count {
            c.scrolledMatch = m
            right.scrollRowToVisible(m.row)
            left.scrollRowToVisible(m.row)
            if let col = right.tableColumns.firstIndex(where: { Coordinator.columnIndex($0) == m.column }) {
                right.scrollColumnToVisible(col)
            }
        } else if findCurrent == nil {
            c.scrolledMatch = nil
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: SheetTableView?
        weak var leftTable: NSTableView?
        weak var rightTable: NSTableView?
        weak var leftScroll: NSScrollView?
        weak var rightScroll: NSScrollView?
        var leftWidth: NSLayoutConstraint?
        var columnSignature = ""
        var expectedOrder: [Int]?
        var renderedVersion = -1
        var flashToken = 0
        var findKey = ""
        var scrolledMatch: FindMatch?
        private var syncing = false
        private var observers: [NSObjectProtocol] = []
        private let cellID = NSUserInterfaceItemIdentifier("SheetCell")

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func makeTable() -> NSTableView {
            let table = PeekTableView()
            table.onDoubleRight = { [weak self] row in
                guard let p = self?.parent, let f = p.onDoubleRightClickRow, row >= 0, row < p.rows.count else { return }
                f(p.rows[row])
            }
            table.wantsDoubleRight = { [weak self] in self?.parent?.onDoubleRightClickRow != nil }
            table.style = .plain
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.allowsColumnReordering = false
            table.allowsColumnResizing = true
            table.allowsMultipleSelection = true
            let menu = NSMenu()
            menu.delegate = self
            table.menu = menu
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.rowHeight = 22
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
            let header = MenuHeaderView()
            header.onMenuClick = { [weak self, weak table] column, rect in
                guard let self, let table else { return }
                self.showColumnMenu(table: table, column: column, rect: rect)
            }
            header.onContextMenu = { [weak self, weak table] column in
                guard let self, let table else { return nil }
                return self.headerMenu(table: table, column: column)
            }
            table.headerView = header
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.action = #selector(clicked(_:))
            table.doubleAction = #selector(doubleClicked(_:))
            return table
        }

        func setColumns(_ indices: [Int], on table: NSTableView, parent: SheetTableView) {
            for col in table.tableColumns.reversed() { table.removeTableColumn(col) }
            for index in indices {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.headerCell = MenuHeaderCell(textCell: "")
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

        private var popover: NSPopover?

        func showColumnMenu(table: NSTableView, column: Int, rect: NSRect) {
            guard let parent, let build = parent.columnMenu, column >= 0, column < table.tableColumns.count,
                  let index = Self.columnIndex(table.tableColumns[column]), let header = table.headerView else { return }
            popover?.close()
            let hosting = NSHostingController(rootView: build(index))
            hosting.sizingOptions = [.preferredContentSize]
            let pop = NSPopover()
            pop.contentViewController = hosting
            pop.behavior = .transient
            pop.animates = true
            pop.show(relativeTo: rect, of: header, preferredEdge: .maxY)
            popover = pop
        }

        /// Right-click on a column header.
        func headerMenu(table: NSTableView, column: Int) -> NSMenu? {
            guard let parent, parent.onHideColumn != nil || parent.onChooseColumns != nil else { return nil }
            let menu = NSMenu()
            if column >= 0, column < table.tableColumns.count, let index = Self.columnIndex(table.tableColumns[column]),
               index < parent.headers.count, let hide = parent.onHideColumn {
                menu.addItem(ClosureMenuItem(title: "Hide “\(parent.headers[index])”") { hide(index) })
            }
            if let show = parent.onShowColumn, !parent.hiddenColumns.isEmpty {
                let item = NSMenuItem(title: "Show column", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for i in parent.hiddenColumns where i < parent.headers.count {
                    sub.addItem(ClosureMenuItem(title: parent.headers[i]) { show(i) })
                }
                item.submenu = sub
                menu.addItem(item)
            }
            if let choose = parent.onChooseColumns {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Choose & order columns…") { choose() })
            }
            if parent.onColumnOrder != nil {
                let tip = NSMenuItem(title: "Tip: drag a header to move the column", action: nil, keyEquivalent: "")
                tip.isEnabled = false
                menu.addItem(tip)
            }
            return menu
        }

        /// A header was dragged to a new place: report the new order of sheet columns.
        func tableViewColumnDidMove(_ notification: Notification) {
            guard let parent, let report = parent.onColumnOrder, let left = leftTable, let right = rightTable else { return }
            let order = (left.tableColumns + right.tableColumns).compactMap { Self.columnIndex($0) }.filter { $0 < parent.headers.count }
            guard order != parent.columns.filter({ $0 < parent.headers.count }) else { return }   // e.g. badge columns being placed
            expectedOrder = order
            DispatchQueue.main.async { report(order) }
        }

        static func columnIndex(_ column: NSTableColumn) -> Int? {
            Int(column.identifier.rawValue.dropFirst())
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        static let eID = NSUserInterfaceItemIdentifier("E")
        static let sID = NSUserInterfaceItemIdentifier("S")
        static let pID = NSUserInterfaceItemIdentifier("P")
        static let cID = NSUserInterfaceItemIdentifier("C")
        private let cCellID = NSUserInterfaceItemIdentifier("CCell")

        /// The ①② column, placed right after the first data column (the symbol).
        func addChartDotsColumn(to table: NSTableView, after: Int? = nil) {
            let column = NSTableColumn(identifier: Self.cID)
            column.width = 34; column.minWidth = 34; column.maxWidth = 34
            column.title = ""
            column.headerToolTip = "Rest the pointer on the blue dot = Chart 1, orange dot = Chart 2 (or click a dot)"
            table.addTableColumn(column)
            let firstData = (after.flatMap { a in table.tableColumns.firstIndex { Self.columnIndex($0) == a } })
                ?? table.tableColumns.firstIndex { Self.columnIndex($0) != nil } ?? 0
            table.moveColumn(table.numberOfColumns - 1, toColumn: min(table.numberOfColumns - 1, firstData + 1))
            updateLeftWidth()
        }
        private let pCellID = NSUserInterfaceItemIdentifier("PCell")
        private let sCellID = NSUserInterfaceItemIdentifier("SCell")

        func addBadgeColumn(_ id: NSUserInterfaceItemIdentifier, title: String, tip: String, to table: NSTableView) {
            let column = NSTableColumn(identifier: id)
            column.width = 30; column.minWidth = 30; column.maxWidth = 30
            column.title = title
            column.headerToolTip = tip
            column.headerCell.alignment = .center
            table.addTableColumn(column)
            table.moveColumn(table.numberOfColumns - 1, toColumn: 0)
            updateLeftWidth()
        }

        // Right-click menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let parent, let build = parent.rowMenu,
                  let table = [leftTable, rightTable].compactMap({ $0 }).first(where: { $0.menu === menu }) else { return }
            let row = table.clickedRow
            guard row >= 0, row < parent.rows.count else { return }
            for (title, action) in build(parent.rows[row]) {
                if title == "-" { menu.addItem(.separator()); continue }
                menu.addItem(ClosureMenuItem(title: title, action: action))
            }
        }
        private let eCellID = NSUserInterfaceItemIdentifier("ECell")

        func addEColumn(to table: NSTableView) {
            let column = NSTableColumn(identifier: Self.eID)
            column.width = 30
            column.minWidth = 30
            column.maxWidth = 30
            column.title = "E"
            column.headerToolTip = "E — Email / Alert rules for this stock. Grey: none · Orange: rule set · Green: condition met"
            column.headerCell.alignment = .center
            table.addTableColumn(column)
            table.moveColumn(table.numberOfColumns - 1, toColumn: 0)
            updateLeftWidth()
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow, col = sender.clickedColumn
            if let parent, row >= 0, row < parent.rows.count, col >= 0, col < sender.tableColumns.count,
               sender.tableColumns[col].identifier == Self.sID {
                parent.onSClick?(parent.rows[row])
                return
            }
            if let parent, row >= 0, row < parent.rows.count, col >= 0, col < sender.tableColumns.count,
               sender.tableColumns[col].identifier == Self.pID {
                parent.onPClick?(parent.rows[row])
                sender.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
                return
            }
            guard let parent, let build = parent.ePanel, row >= 0, row < parent.rows.count,
                  col >= 0, col < sender.tableColumns.count,
                  sender.tableColumns[col].identifier == Self.eID else { return }
            popover?.close()
            let hosting = NSHostingController(rootView: build(parent.rows[row]))
            hosting.sizingOptions = [.preferredContentSize]
            let pop = NSPopover()
            pop.contentViewController = hosting
            pop.behavior = .transient
            pop.show(relativeTo: sender.frameOfCell(atColumn: col, row: row), of: sender, preferredEdge: .maxX)
            popover = pop
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let tableColumn, tableColumn.identifier == Self.eID, let parent, row < parent.rows.count {
                let cell = (tableView.makeView(withIdentifier: eCellID, owner: nil) as? ECellView) ?? {
                    let v = ECellView()
                    v.identifier = eCellID
                    return v
                }()
                cell.configure(color: parent.eColor?(parent.rows[row]) ?? .clear)
                return cell
            }
            if let tableColumn, tableColumn.identifier == Self.pID, let parent, row < parent.rows.count {
                let cell = (tableView.makeView(withIdentifier: pCellID, owner: nil) as? ECellView) ?? {
                    let v = ECellView(letter: "P", tip: "Click: not my pick → my pick (green) → OK (orange)")
                    v.identifier = pCellID
                    return v
                }()
                cell.configure(color: parent.pColor?(parent.rows[row]) ?? .clear)
                return cell
            }
            if let tableColumn, tableColumn.identifier == Self.cID, let parent, row < parent.rows.count {
                let cell = (tableView.makeView(withIdentifier: cCellID, owner: nil) as? ChartDotsCell) ?? {
                    let v = ChartDotsCell()
                    v.identifier = cCellID
                    return v
                }()
                let data = parent.rows[row]
                let fire = parent.onHoverChart
                cell.onFire = { chart in fire?(data, chart) }
                return cell
            }
            if let tableColumn, tableColumn.identifier == Self.sID, let parent, row < parent.rows.count {
                let cell = (tableView.makeView(withIdentifier: sCellID, owner: nil) as? ECellView) ?? {
                    let v = ECellView(letter: "S", tip: "Click to open this stock's screenshots")
                    v.identifier = sCellID
                    return v
                }()
                cell.configure(color: parent.sColor?(parent.rows[row]) ?? .clear)
                return cell
            }
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
            cell.setChanged(parent.changedCell?(data, index))
            let q = parent.findQuery
            if !q.isEmpty, text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                cell.setFindHighlight(parent.findCurrent == FindMatch(row: row, column: index) ? .current : .match)
            } else {
                cell.setFindHighlight(.none)
            }
            if let flash = parent.flash, flash.isActive, let kind = flash.kind(row: data.id, column: index) {
                let remaining = flash.duration - Date().timeIntervalSince(flash.started)
                cell.flash(FlashSpec.color(kind), duration: remaining)
            } else {
                cell.clearFlash()
            }
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
            if let parent {
                parent.onSelectRows?(source.selectedRowIndexes.filter { $0 < parent.rows.count }.map { parent.rows[$0] })
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

    private var flashLayer: CALayer?
    private var changeLayer: CALayer?

    /// Shaded border when the value changed since the previous day (tooltip = yesterday's value).
    func setChanged(_ previous: String?) {
        guard let layer else { return }
        if let previous {
            let l = changeLayer ?? {
                let l = CALayer(); l.cornerRadius = 3; l.borderWidth = 1.5
                layer.addSublayer(l); changeLayer = l; return l
            }()
            l.borderColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
            l.frame = bounds.insetBy(dx: 1, dy: 1)
            l.isHidden = false
            toolTip = "Changed since the previous day — was: \(previous.isEmpty ? "(blank)" : previous)"
        } else {
            changeLayer?.isHidden = true
            toolTip = nil
        }
    }

    /// Glows `color` and fades out over `duration` seconds.
    func flash(_ color: NSColor, duration: Double) {
        guard duration > 0.05, let layer else { return }
        let glow = flashLayer ?? {
            let l = CALayer()
            l.cornerRadius = 3
            layer.addSublayer(l)
            flashLayer = l
            return l
        }()
        glow.frame = bounds.insetBy(dx: 1, dy: 1)
        glow.backgroundColor = color.withAlphaComponent(0.75).cgColor
        glow.borderColor = color.cgColor
        glow.borderWidth = 1.5
        glow.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        glow.opacity = 0
        glow.add(fade, forKey: "fade")
    }

    enum FindHighlight { case none, match, current }
    private var findLayer: CALayer?

    func setFindHighlight(_ h: FindHighlight) {
        guard let layer else { return }
        if h == .none { findLayer?.isHidden = true; return }
        let l = findLayer ?? {
            let l = CALayer()
            l.cornerRadius = 3
            layer.addSublayer(l)
            findLayer = l
            return l
        }()
        l.isHidden = false
        l.frame = bounds.insetBy(dx: 1, dy: 1)
        l.borderWidth = h == .current ? 2.5 : 1.5
        l.borderColor = (h == .current ? NSColor.systemOrange : NSColor.systemYellow).cgColor
        l.backgroundColor = (h == .current ? NSColor.systemOrange : NSColor.systemYellow).withAlphaComponent(0.25).cgColor
    }

    func clearFlash() {
        flashLayer?.removeAllAnimations()
        flashLayer?.opacity = 0
    }

    override func layout() {
        super.layout()
        flashLayer?.frame = bounds.insetBy(dx: 1, dy: 1)
        findLayer?.frame = bounds.insetBy(dx: 1, dy: 1)
        changeLayer?.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    func configure(text: String, alignRight: Bool, bold: Bool, background: NSColor?) {
        label.stringValue = text
        label.alignment = alignRight ? .right : .left
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: bold ? .semibold : .regular)
        toolTip = text.count > 14 ? text : nil
        layer?.backgroundColor = background?.cgColor
    }
}

// MARK: - Header with a small ▼ menu button

/// Clicking the right edge of a header (where ▼ is drawn) opens the column panel;
/// clicking anywhere else behaves normally (sort).
final class MenuHeaderView: NSTableHeaderView {
    var menuEnabled = false
    var onMenuClick: ((Int, NSRect) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let column = self.column(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(column) ?? super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if menuEnabled, column >= 0 {
            let rect = headerRect(ofColumn: column)
            if point.x >= rect.maxX - MenuHeaderCell.buttonWidth {
                onMenuClick?(column, rect)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

final class MenuHeaderCell: NSTableHeaderCell {
    static let buttonWidth: CGFloat = 20
    var showsMenu = false
    var isMarked = false

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var textFrame = cellFrame
        if showsMenu { textFrame.size.width -= Self.buttonWidth }
        super.drawInterior(withFrame: textFrame, in: controlView)
        guard showsMenu else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isMarked ? 10 : 8, weight: isMarked ? .bold : .regular),
            .foregroundColor: isMarked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ]
        let arrow = NSAttributedString(string: "▼", attributes: attrs)
        let size = arrow.size()
        arrow.draw(at: NSPoint(x: cellFrame.maxX - Self.buttonWidth + (Self.buttonWidth - size.width) / 2,
                               y: cellFrame.midY - size.height / 2))
    }
}

/// The small "E" / "S" badge in the E and S columns.
final class ECellView: NSTableCellView {
    private let badge: NSTextField

    convenience init(letter: String, tip: String) {
        self.init(frame: .zero, letter: letter)
        toolTip = tip
    }

    override convenience init(frame: NSRect) { self.init(frame: frame, letter: "E") }

    init(frame: NSRect, letter: String) {
        badge = NSTextField(labelWithString: letter)
        super.init(frame: frame)
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
        toolTip = "Click to set Email / Alert rules for this stock"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: NSColor) {
        badge.layer?.backgroundColor = color.cgColor
        let strong = color == .systemGreen || color == .systemOrange
        badge.textColor = strong ? .white : .secondaryLabelColor
    }
}

/// Position of a find match: row index in the shown rows, and sheet column index.
struct FindMatch: Equatable {
    let row: Int
    let column: Int
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}


/// Table that tells a double right-click from a single one: the context menu opens after the double-click
/// interval unless a second right-click on the same row arrives first.
final class PeekTableView: NSTableView {
    var onDoubleRight: ((Int) -> Void)?
    var wantsDoubleRight: (() -> Bool)?
    private var pending: DispatchWorkItem?
    private var pendingRow = -1

    override func rightMouseDown(with event: NSEvent) {
        guard wantsDoubleRight?() ?? false else { super.rightMouseDown(with: event); return }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if let p = pending, row == pendingRow {
            p.cancel(); pending = nil
            onDoubleRight?(row)
            return
        }
        pending?.cancel()
        pendingRow = row
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.openMenu(event)
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
    }

    private func openMenu(_ event: NSEvent) { super.rightMouseDown(with: event) }
}


/// Two small dots (blue = Chart 1, orange = Chart 2). Resting the pointer on one for the hover delay — or
/// clicking it — calls onFire(0 / 1). The dot fills in while the delay runs.
final class ChartDotsCell: NSTableCellView {
    var onFire: ((Int) -> Void)?
    private var hover: Int?
    private var work: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    private static let r: CGFloat = 5

    static var delay: Double {
        let v = UserDefaults.standard.double(forKey: "peek.hoverDelay")
        return UserDefaults.standard.object(forKey: "peek.hoverDelay") == nil ? 1.0 : max(0.2, v)
    }

    override init(frame: NSRect) { super.init(frame: frame); toolTip = "Rest on blue = Chart 1 · orange = Chart 2" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func centers() -> [CGPoint] {
        let y = bounds.midY
        return [CGPoint(x: bounds.midX - 7, y: y), CGPoint(x: bounds.midX + 7, y: y)]
    }
    private func dot(at p: CGPoint) -> Int? {
        for (i, c) in centers().enumerated() where hypot(p.x - c.x, p.y - c.y) <= Self.r + 3 { return i }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemBlue, .systemOrange]
        for (i, c) in centers().enumerated() {
            let rect = NSRect(x: c.x - Self.r, y: c.y - Self.r, width: Self.r * 2, height: Self.r * 2)
            let path = NSBezierPath(ovalIn: rect)
            colors[i].withAlphaComponent(hover == i ? 1 : 0.35).setFill()
            path.fill()
            colors[i].setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func set(_ d: Int?) {
        guard d != hover else { return }
        hover = d
        needsDisplay = true
        work?.cancel(); work = nil
        guard let d else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.hover == d else { return }
            self.onFire?(d)
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: w)
    }

    override func mouseMoved(with event: NSEvent) { set(dot(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { set(dot(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { set(nil) }
    override func mouseDown(with event: NSEvent) {
        if let d = dot(at: convert(event.locationInWindow, from: nil)) { work?.cancel(); onFire?(d) } else { super.mouseDown(with: event) }
    }
    override func prepareForReuse() { super.prepareForReuse(); work?.cancel(); hover = nil; needsDisplay = true }
}
