import SwiftUI

struct AdminOverviewView: View {
    let account: AccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var overview: AdminOverview?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(SPText("관리자 현황")).font(.title2.bold())
                        Label(SPText("관리자 · 전체 기능 무료"), systemImage: "checkmark.shield").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await reload() } } label: { Label(SPText("새로고침"), systemImage: "arrow.clockwise") }
                        .disabled(loading || !account.isAdmin).accessibilityIdentifier("adminRefresh")
                }
                if !account.isAdmin {
                    Text(SPText("관리자 계정만 현황을 확인할 수 있습니다."))
                } else {
                    if loading { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("adminError") }
                    if let overview {
                        Text(SPText("마지막 확인") + " · " + date(overview.generatedAt)).font(.footnote).foregroundStyle(.secondary)
                        ForEach(overview.sections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(SPServerText(section.title)).font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 12) {
                                    ForEach(section.metrics) { metric in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(SPServerText(metric.title)).font(.subheadline).foregroundStyle(.secondary)
                                            Text(metric.format == "krw" ? metric.value.formatted(.currency(code: "KRW").precision(.fractionLength(0))) : metric.value.formatted())
                                                .font(.title2.weight(.semibold)).monospacedDigit()
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                            .accessibilityElement(children: .combine).accessibilityIdentifier("adminMetric_" + section.id + "_" + metric.id)
                                    }
                                }
                            }
                        }
                        Divider()
                        Text(SPText("최근 토스 결제 주문 · 최대 20건")).font(.headline)
                        if overview.recentOrders.isEmpty { Text(SPText("아직 결제 내역이 없습니다.")).foregroundStyle(.secondary) }
                        ForEach(overview.recentOrders) { order in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(SPServerText(AdminOverview.productTitle(order.product))); Spacer(); Text(order.amount.formatted(.currency(code: "KRW").precision(.fractionLength(0)))) }
                                Text(order.member + " · " + SPServerText(order.status)).font(.subheadline)
                                Text(SPText("주문일") + " · " + date(order.createdAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                        Text(SPText("최근 이용권·구독 확인 · 최대 20건")).font(.headline)
                        if overview.recentSubscriptions.isEmpty { Text(SPText("아직 연결된 이용권이 없습니다.")).foregroundStyle(.secondary) }
                        ForEach(overview.recentSubscriptions) { subscription in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider(subscription.provider) + " · " + SPServerText(AdminOverview.productTitle(subscription.product))).font(.subheadline.bold())
                                Text(subscription.member + " · " + SPServerText(subscription.status)).font(.subheadline)
                                if let expires = subscription.expiresAt { Text(SPText("이용 기간 종료") + " · " + date(expires)).font(.caption) }
                                Text(SPText("마지막 확인") + " · " + date(subscription.checkedAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                        Text(SPServerText(overview.notice)).font(.footnote).foregroundStyle(.secondary)
                        Text(SPText("화면을 보는 동안 30초마다 갱신합니다. 오늘 가입은 한국 시간 기준입니다.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(SPText("관리자 현황"))
        .task(id: account.session?.userId) {
            overview = nil
            while !Task.isCancelled && account.isAdmin {
                if scenePhase == .active { await reload() }
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
        .onChange(of: account.isAdmin) { _, allowed in if !allowed { overview = nil; error = nil } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
    }

    private func reload() async {
        guard !loading, account.isAdmin else { return }
        loading = true; defer { loading = false }
        do {
            let value = try await account.adminOverview()
            guard !Task.isCancelled, account.isAdmin else { return }
            overview = value; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            if !account.isAdmin { overview = nil }
        }
    }
    private func date(_ timestamp: Double) -> String { Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened) }
    private func provider(_ id: String) -> String { ["apple": "App Store", "google": "Google Play", "toss": "Toss" ][id] ?? id }
}
