import Foundation

extension ScreenerViewModel {

    /// Stored days older than the live data, newest first (what the Changes screen can compare with).
    var changeDayOptions: [String] {
        let live = HistoryStore.dayKey(dataDay(of: table))
        return historyDays.filter { $0 < live }.reversed()
    }

    /// Recomputes every card: live data vs the chosen (or previous) stored day.
    func computeChanges() {
        guard hasData, let label = labelIndex else { changeStatus = "No data imported yet"; return }
        let options = changeDayOptions
        guard let day = changeCompareDay.flatMap({ d in options.contains(d) ? d : nil }) ?? options.first else {
            changeResults = [:]
            changeComparedDay = nil
            changeStatus = "No earlier day stored yet — the app saves one snapshot per trading day. Come back after the next update."
            return
        }
        isComputingChanges = true
        changeStatus = nil
        let current = table
        let cards = settings.changeCards.filter(\.isEnabled)
        let group = settings.filterGroup
        let watch = Set(watchlists.flatMap { $0.items.map { $0.symbol.uppercased() } })
        Task { [weak self] in
            guard let self, let previous = await self.loadAlignedDay(day) else {
                self?.isComputingChanges = false
                self?.changeStatus = "Couldn't read the stored day \(day)"
                return
            }
            var issues: [String] = []
            let pNow = FilterCompiler.compile(group, table: current, issues: &issues)
            let pBefore = FilterCompiler.compile(group, table: previous, issues: &issues)
            let results = await Task.detached(priority: .userInitiated) { () -> [UUID: ChangeResult] in
                let fNow = ChangeEngine.symbols(current, label: label, where: pNow)
                let fBefore = ChangeEngine.symbols(previous, label: label, where: pBefore)
                var out: [UUID: ChangeResult] = [:]
                for card in cards {
                    out[card.id] = ChangeEngine.evaluate(card, current: current, previous: previous, label: label,
                                                         filterNow: fNow, filterBefore: fBefore, watch: watch)
                }
                return out
            }.value
            self.changeResults = results
            self.changeComparedDay = day
            self.isComputingChanges = false
        }
    }
}
