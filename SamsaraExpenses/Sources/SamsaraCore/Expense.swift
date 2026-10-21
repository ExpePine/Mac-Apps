import Foundation

/// One row of the Samsara "Download table as CSV" export.
/// Columns: ID, Product, Price, Category, Platform/Vendor, Saved By, Quantity, Date
public struct Expense: Identifiable, Hashable, Codable {
    public var id: String
    public var product: String
    /// Amount paid for the whole line (Samsara's Price is the line total, e.g. "4 x 200 ml" milk = ₹68).
    public var amount: Double
    public var category: String
    /// Empty when Samsara has no vendor for the row.
    public var vendor: String
    public var savedBy: String
    public var quantity: String
    /// nil when the export has no real date ("0000-00-00 00:00:00").
    public var date: Date?
    /// The Price cell exactly as exported.
    public var rawPrice: String

    public init(id: String, product: String, amount: Double, category: String, vendor: String,
                savedBy: String, quantity: String, date: Date?, rawPrice: String) {
        self.id = id
        self.product = product
        self.amount = amount
        self.category = category
        self.vendor = vendor
        self.savedBy = savedBy
        self.quantity = quantity
        self.date = date
        self.rawPrice = rawPrice
    }

    /// Non-optional date for sorting tables (undated rows sort first/last).
    public var sortDate: Date { date ?? .distantPast }
    public var vendorLabel: String { vendor.isEmpty ? "Not set" : vendor }
    public var personLabel: String { savedBy.isEmpty ? "Unknown" : savedBy }
}
