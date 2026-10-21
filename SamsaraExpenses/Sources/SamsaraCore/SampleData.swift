import Foundation

/// Made-up data in the Samsara export format, for screenshots and tests.
/// (The repository is public, so real expense data never goes in it.)
public enum SampleData {

    private struct Item {
        let name: String
        let category: String
        let price: ClosedRange<Int>
        let vendors: [String]
        let qty: String
        let weight: Int
    }

    private static let items: [Item] = [
        Item(name: "Toned Milk 500 ml", category: "Dairy", price: 27...29, vendors: ["Zepto", "Blinkit"], qty: "1 x 500 ml", weight: 10),
        Item(name: "Curd Cup 400 g", category: "Dairy", price: 35...45, vendors: ["Zepto"], qty: "1 x 400 g", weight: 4),
        Item(name: "Paneer 200 g", category: "Dairy", price: 80...95, vendors: ["BigBasket"], qty: "1 x 200 g", weight: 3),
        Item(name: "Tomato", category: "Vegetables", price: 18...40, vendors: ["Flipkart Minutes", "Zepto"], qty: "1 x 500 g", weight: 8),
        Item(name: "Onion", category: "Vegetables", price: 25...45, vendors: ["Flipkart Minutes"], qty: "1 kg", weight: 6),
        Item(name: "Ginger", category: "Vegetables", price: 9...15, vendors: ["Zepto"], qty: "1 x 100 g", weight: 4),
        Item(name: "Banana Robusta", category: "Fruits", price: 45...70, vendors: ["Blinkit"], qty: "6 pcs", weight: 4),
        Item(name: "Whole Wheat Bread", category: "Bakery", price: 45...55, vendors: ["Zepto"], qty: "1 x 400 g", weight: 4),
        Item(name: "Basmati Rice 5 kg", category: "Groceries", price: 520...640, vendors: ["BigBasket", "JioMart"], qty: "1 x 5 kg", weight: 1),
        Item(name: "Toor Dal 1 kg", category: "Groceries", price: 150...185, vendors: ["BigBasket"], qty: "1 x 1 kg", weight: 2),
        Item(name: "Instant Noodles Pack", category: "Groceries", price: 14...15, vendors: ["Flipkart Minutes"], qty: "1 x 70 g", weight: 4),
        Item(name: "Instant Coffee Jar", category: "Beverages", price: 120...180, vendors: ["Zepto"], qty: "1 pc (50 g)", weight: 2),
        Item(name: "Masala Peanuts", category: "Snack", price: 40...65, vendors: ["Zepto", "Blinkit"], qty: "1 pack", weight: 4),
        Item(name: "Dishwash Liquid", category: "Household", price: 99...199, vendors: ["Blinkit"], qty: "1 x 750 ml", weight: 2),
        Item(name: "Toothpaste", category: "Personal Care", price: 95...140, vendors: ["Zepto"], qty: "1 x 150 g", weight: 1),
        Item(name: "Veg Biryani", category: "Eat-Out", price: 160...260, vendors: ["Swiggy", ""], qty: "1", weight: 3),
        Item(name: "Zomato order", category: "Zomato/Food-Delivery", price: 180...450, vendors: ["Zomato"], qty: "1", weight: 3),
        Item(name: "Bike petrol", category: "FUEL", price: 300...800, vendors: [""], qty: "1", weight: 2),
        Item(name: "Rapido ride", category: "UBER/RAPIDO", price: 45...160, vendors: [""], qty: "1", weight: 3),
        Item(name: "Ironing", category: "Istri", price: 60...120, vendors: [""], qty: "1", weight: 1),
        Item(name: "Assorted items", category: "Uncategorized", price: 30...120, vendors: [""], qty: "", weight: 2),
    ]

    /// About 90 days of entries ending on `end`, oldest last (like the real export).
    public static func csv(endingOn end: Date = Date(), days: Int = 92, timeZone: TimeZone = .current) -> String {
        var rng = SeededGenerator(seed: 20261021)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let pool = items.flatMap { Array(repeating: $0, count: $0.weight) }
        var rows: [[String]] = []
        var id = 1
        let endDay = cal.startOfDay(for: end)
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: endDay) else { continue }
            let entries = Int.random(in: 0...6, using: &rng)
            for _ in 0..<entries {
                let item = pool[Int.random(in: 0..<pool.count, using: &rng)]
                let price = Int.random(in: item.price, using: &rng)
                let seconds = Int.random(in: 8 * 3600...23 * 3600, using: &rng)
                let date = day.addingTimeInterval(TimeInterval(seconds))
                let vendor = item.vendors[Int.random(in: 0..<item.vendors.count, using: &rng)]
                let priceText = vendor.isEmpty ? String(price) : "₹\(price)"
                let person = Int.random(in: 0..<4, using: &rng) == 0 ? "Raja" : "Dona"
                rows.append([String(id), item.name, priceText, item.category, vendor, person, item.qty, f.string(from: date)])
                id += 1
            }
        }
        rows.reverse()   // newest first, like Samsara
        rows.append([String(id), "Mineral Water", "20.00", "Beverages", "Swiggy", "Dona", "1", "0000-00-00 00:00:00"])
        return ([ExpenseParser.exportHeader] + rows).map(CSV.line).joined(separator: "\n") + "\n"
    }
}

/// Deterministic generator so screenshots and tests are stable.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
