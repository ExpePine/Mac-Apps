import SwiftUI
import AppKit
import SamsaraCore

/// `--screenshots`: renders the main screens with made-up sample data to PNGs (used by CI).
@MainActor
enum Screenshots {
    static func capture() {
        let store = Store(persist: false)
        store.load(sample: SampleData.csv(endingOn: Date()), period: store.analyzer.period(containing: Date()))

        let dir = Store.dataDirectory.appendingPathComponent("screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("SCREENSHOTS_DIR \(dir.path)")

        render(DashboardContent().environmentObject(store), name: "dashboard", width: 1180, dir: dir)
        render(InsightsContent().environmentObject(store), name: "insights", width: 900, dir: dir)
        render(VendorsContent().environmentObject(store), name: "vendors", width: 1100, dir: dir)
        if let top = store.analyzer.byCategory(store.current).first {
            render(CategoryDetail(category: top.key).environmentObject(store), name: "category", width: 900, dir: dir)
        }
        render(WelcomeView().environmentObject(Store(persist: false)), name: "welcome", width: 800, dir: dir)
    }

    private static func render<V: View>(_ view: V, name: String, width: CGFloat, dir: URL) {
        let content = view
            .frame(width: width)
            .padding(24)
            .background(Theme.pageBackground)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("SHOT FAILED \(name)")
            return
        }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("SHOT \(name) \(Int(image.size.width))x\(Int(image.size.height))")
        } catch {
            print("SHOT FAILED \(name): \(error.localizedDescription)")
        }
    }
}

/// `--probe-fetch`: runs the real auto-download once and prints only counts and the header,
/// never the rows (CI logs are public).
@MainActor
enum Probe {
    static func run(url: URL) async {
        let fetcher = SamsaraFetcher()
        let started = Date()
        do {
            let text = try await fetcher.fetch(url: url)
            let rows = CSV.parse(text)
            let parsed = try? ExpenseParser.parse(text: text)
            print("PROBE ok rows=\(max(0, rows.count - 1)) parsed=\(parsed?.expenses.count ?? -1) seconds=\(Int(Date().timeIntervalSince(started)))")
            print("PROBE header=\(rows.first?.joined(separator: "|") ?? "")")
        } catch {
            print("PROBE failed seconds=\(Int(Date().timeIntervalSince(started))) error=\(error.localizedDescription)")
        }
    }
}
