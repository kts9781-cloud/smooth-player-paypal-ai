import Foundation

/// Exercises the real HTTP/client/signature/Keychain path against a synthetic
/// loopback provider. A cloud or production configuration is never accepted.
@MainActor
enum MacAccountValidation {
    enum Failure: Error { case check(String) }
    private static var orderID: String?

    private static func origin(_ model: MacPlayerModel) throws -> URL {
        guard CommandLine.arguments.contains("--self-test"),
              CommandLine.arguments.contains("--account-fixture-test"),
              let config = model.account.configuration, config.environment == "test",
              config.origin.absoluteString == "http://127.0.0.1:8874" else {
            throw Failure.check("Account fixture requires the explicit loopback test configuration")
        }
        return config.origin
    }

    private static func request(_ path: String, model: MacPlayerModel,
                                body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try origin(model).appendingPathComponent(path))
        request.timeoutInterval = 15
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token = model.account.session?.token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 65_536,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.check("Synthetic account HTTP operation failed at \(path), status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return reply
    }

    static func signInAndPurchase(_ model: MacPlayerModel) async throws {
        _ = try origin(model)
        await model.account.requestCode(email: "mac-" + UUID().uuidString.lowercased() + "@example.test")
        guard model.account.challengeId != nil else { throw Failure.check("Synthetic email challenge failed") }
        let outbox = try await request("fixture/code", model: model)
        guard let code = outbox["code"] as? String else { throw Failure.check("Synthetic code missing") }
        await model.account.signIn(code: code)
        guard model.account.session != nil, !model.account.hasPaidAccess else {
            throw Failure.check("Synthetic login state incorrect")
        }
        let order = try await request("v1/orders", model: model, body: ["product": "smooth_lifetime"])
        guard let identifier = order["orderId"] as? String, let amount = order["amount"] as? Int else {
            throw Failure.check("Synthetic order missing")
        }
        let confirmation: [String: Any] = ["orderId": identifier, "amount": amount,
                                         "paymentKey": "synthetic-" + UUID().uuidString]
        _ = try await request("v1/payments/confirm", model: model, body: confirmation)
        _ = try await request("v1/payments/confirm", model: model, body: confirmation)
        await model.account.refresh()
        guard model.account.hasPaidAccess,
              let restored = model.restoredValidationAccount(), restored.hasPaidAccess,
              restored.session?.userId == model.account.session?.userId else {
            throw Failure.check("Signed entitlement or Keychain restore failed")
        }
        orderID = identifier
    }

    static func refund(_ model: MacPlayerModel) async throws {
        guard let orderID else { throw Failure.check("No synthetic order to refund") }
        _ = try await request("fixture/refund", model: model, body: ["orderId": orderID])
        await model.account.refresh()
        guard model.account.session != nil, !model.account.hasPaidAccess,
              let restored = model.restoredValidationAccount(), !restored.hasPaidAccess else {
            throw Failure.check("Refunded entitlement remained active")
        }
    }

    static func complimentary(_ model: MacPlayerModel) async throws {
        _ = try origin(model)
        await model.account.redeemComplimentary(code: "incorrect-fixture")
        guard !model.account.hasPaidAccess else { throw Failure.check("Incorrect complimentary code unlocked access") }
        await model.account.redeemComplimentary(code: "fixture-free-code")
        guard model.account.hasPaidAccess,
              let restored = model.restoredValidationAccount(), restored.hasPaidAccess,
              restored.session?.userId == model.account.session?.userId else {
            throw Failure.check("Complimentary signed grant or Keychain restore failed")
        }
        await model.account.redeemComplimentary(code: "fixture-free-code")
        guard model.account.hasPaidAccess else { throw Failure.check("Repeated complimentary registration lost access") }
    }
}
