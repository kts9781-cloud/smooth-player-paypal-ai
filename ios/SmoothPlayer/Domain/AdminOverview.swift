import Foundation

struct AdminOverview: Decodable, Sendable {
    struct Metric: Decodable, Identifiable, Sendable {
        let id: String; let title: String; let value: Int64; let format: String
    }
    struct Section: Decodable, Identifiable, Sendable {
        let id: String; let title: String; let metrics: [Metric]
    }
    struct Order: Decodable, Identifiable, Sendable {
        let id: String; let member: String; let product: String; let amount: Int64; let status: String; let createdAt: Double
    }
    struct Subscription: Decodable, Identifiable, Sendable {
        let id: String; let member: String; let provider: String; let product: String; let status: String
        let expiresAt: Double?; let checkedAt: Double
    }
    let generatedAt: Double; let timezone: String; let sections: [Section]
    let recentOrders: [Order]; let recentSubscriptions: [Subscription]; let notice: String

    static func productTitle(_ id: String) -> String {
        switch id { case "smooth_monthly": return "월 구독"; case "smooth_yearly": return "연 구독"; case "smooth_lifetime": return "평생 이용권"; default: return id }
    }
}
