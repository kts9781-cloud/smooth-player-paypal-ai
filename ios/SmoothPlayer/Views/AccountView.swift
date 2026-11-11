import SwiftUI
import AuthenticationServices

/// The same account entry appears on the first screen and at the top of settings.
struct AccountEntryLabel: View {
    var account: AccountStore
    var localPurchaseActive = false
    var compact = false
    private let accent = Color(red: 214 / 255, green: 179 / 255, blue: 95 / 255)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(compact ? .title2 : .largeTitle).foregroundStyle(accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.session == nil ? SPText("로그인 · 이용권 연결") : SPText("계정 · 이용권"))
                    .font(compact ? .subheadline.bold() : .headline).foregroundStyle(accent)
                if let session = account.session {
                    Text(session.email).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(account.isAdmin ? SPText("관리자 · 전체 기능 무료") : account.hasPaidAccess ? SPText("이용권 사용 중") : localPurchaseActive ? SPText("이 기기에서 이용권 사용 중 · 계정 연결 대기") : SPText("연결된 이용권 없음"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(SPText("다른 기기에서도 같은 이용권을 사용하세요."))
                        .font(compact ? .caption : .subheadline).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(accent)
                .accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading).padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.45), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
struct AccountEntryLink: View {
    @Environment(AccountStore.self) private var account
    @Environment(PurchaseStore.self) private var purchases

    var body: some View {
        NavigationLink {
            VStack(spacing: 0) {
                AccountView(account: account, linkExistingPurchase: { await purchases.linkExistingPurchases() },
                            localPurchaseActive: !purchases.verifiedProductIDs.isEmpty,
                            refreshPurchases: { await purchases.refreshEntitlements() })
                if let message = purchases.message { Text(message).font(.footnote).padding() }
                if let message = purchases.accountLinkMessage { Text(message).font(.footnote).padding() }
            }
        } label: {
            AccountEntryLabel(account: account, localPurchaseActive: !purchases.verifiedProductIDs.isEmpty)
        }.buttonStyle(.plain)
            .accessibilityLabel(account.session == nil ? SPText("로그인 · 이용권 연결") : SPText("계정 · 이용권"))
            .accessibilityValue(account.session?.email ?? SPText("다른 기기에서도 같은 이용권을 사용하세요."))
            .accessibilityIdentifier("openAccount")
    }
}
#endif

struct AccountView: View {
    @Bindable var account: AccountStore
    var linkExistingPurchase: (() async -> Void)? = nil
    var localPurchaseActive = false
    var refreshPurchases: (() async -> Void)? = nil
    @State private var email = ""
    @State private var code = ""
    @State private var deleting = false
    @State private var linking = false
    @State private var showingAdmin = false
    @State private var authentication = AccountBrowserAuthentication()
    #if os(macOS)
    @State private var complimentaryCode = ""
    #endif
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(SPText("계정 · 이용권")).font(.title2.bold())
                Text(SPText("같은 이메일 계정으로 로그인하면 연결된 이용권을 다른 기기에서도 사용할 수 있습니다."))
                    .foregroundStyle(.secondary)
                if !account.isConfigured {
                    Text(SPText("계정 서비스를 준비하고 있습니다. 기존 기기의 구매·복원 기능은 계속 사용할 수 있습니다."))
                } else if let session = account.session {
                    Label(session.email, systemImage: "person.crop.circle")
                    if account.isAdmin {
                        Label(SPText("관리자 · 전체 기능 무료"), systemImage: "checkmark.shield")
                        Button(SPText("관리자 현황 · 가입자·구독·결제")) { showingAdmin = true }
                            .accessibilityIdentifier("openAdminOverview")
                    }
                    Label(account.hasPaidAccess ? SPText("이용권 사용 중") : localPurchaseActive ? SPText("이 기기에서 이용권 사용 중 · 계정 연결 대기") : SPText("연결된 이용권 없음"), systemImage: account.hasPaidAccess || localPurchaseActive ? "checkmark.seal" : "ticket")
                    Text(SPText("로그인 방식 연결")).font(.headline)
                    socialButtons
                    Text(SPText("이 계정에 연결하면 Google·Apple로 로그인해도 같은 이용권과 NAS 정보를 사용합니다.")).font(.footnote).foregroundStyle(.secondary)
                    Button(SPText("이용권 다시 확인")) { Task { await account.refresh(); await refreshPurchases?() } }
                    if let sync = account.nasSync {
                        Divider()
                        Text(SPText("NAS 동기화")).font(.headline)
                        Text(SPText("서버 주소·아이디·비밀번호와 NAS 최근 목록·이어보기 위치를 이 계정으로 동기화합니다. 접속 정보는 암호화해 저장합니다. 로컬 파일·로컬 목록은 제외됩니다.")).font(.footnote).foregroundStyle(.secondary)
                        Text(sync.message).font(.footnote)
                        Button(sync.busy ? SPText("동기화 중…") : SPText("지금 동기화")) { Task { await sync.synchronize() } }.disabled(sync.busy)
                        if sync.conflictCount > 0 { Button(SPText("보관한 이 기기 변경 다시 적용")) { sync.restoreConflicts(); Task { await sync.synchronize() } } }
                    }
                    if let linkExistingPurchase {
                        Button(linking ? SPText("구매 연결 중…") : SPText("기존 구매를 이 계정에 연결")) {
                            linking = true
                            Task { await linkExistingPurchase(); linking = false }
                        }.disabled(linking)
                        Text(SPText("로그인 전 구매한 이용권은 처음 로그인한 스무스플레이어 계정에 자동 연결됩니다. 연결 후 다른 계정으로 이전되지 않습니다."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    if !account.isAdmin {
                    Divider()
                    Text(SPText("무료 이용 코드")).font(.headline)
                    SecureField(SPText("전달받은 코드"), text: $complimentaryCode).textFieldStyle(.roundedBorder)
                    Button(SPText("무료 이용권 등록")) {
                        Task { await account.redeemComplimentary(code: complimentaryCode); complimentaryCode = "" }
                    }.disabled(complimentaryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(SPText("등록하면 토스 자동 갱신은 중단됩니다. 이미 결제한 금액은 자동 환불되지 않습니다. Apple·Google 구독은 해당 스토어에서 별도로 해지해 주세요."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let url = account.purchaseURL {
                        Button(account.hasPaidAccess ? SPText("웹에서 이용권 관리") : SPText("이용권 구매")) { openURL(url) }
                        Text(SPText("브라우저에서 같은 이메일로 로그인해 주세요. 결제 후 ‘이용권 다시 확인’을 누르면 반영됩니다."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    }
                    #endif
                    Button(SPText("로그아웃")) { Task { await account.signOut() } }
                    Button(SPText("회원 탈퇴"), role: .destructive) { deleting = true }
                } else {
                    socialButtons
                    Text(SPText("기존 이메일 계정이 있다면 아래에서 먼저 로그인한 뒤 Google·Apple을 연결해 주세요.")).font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    Text(SPText("이메일로 로그인")).font(.headline)
                    TextField(SPText("이메일"), text: $email).textContentType(.emailAddress).textFieldStyle(.roundedBorder)
                    Button(SPText("인증 코드 받기")) { Task { await account.requestCode(email: email) } }
                    if account.challengeId != nil {
                        TextField(SPText("이메일로 받은 8자리 코드"), text: $code).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder)
                        Button(SPText("로그인")) { Task { await account.signIn(code: code); code = "" } }
                    }
                }
                if account.busy { ProgressView().controlSize(.small) }
                if let message = account.message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("accountMessage") }
                Text(SPText("로그인하면 이 기기의 NAS 연결·비밀번호·재생 기록이 계정에 연결됩니다. 영상·자막 원본과 로컬 재생목록은 업로드하지 않습니다.")).font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 560, alignment: .leading).disabled(account.busy)
        }
        .task { await account.refresh(); await account.loadLoginProviders() }
        .sheet(isPresented: $showingAdmin) {
            NavigationStack {
                AdminOverviewView(account: account)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(SPText("닫기")) { showingAdmin = false } } }
            }
            #if os(macOS)
            .frame(width: 760, height: 680)
            #endif
        }
        .confirmationDialog(SPText("회원 계정을 삭제할까요?"), isPresented: $deleting, titleVisibility: .visible) {
            Button(SPText("회원 탈퇴"), role: .destructive) { Task { await account.deleteAccount() } }
        } message: {
            Text(SPText("토스 자동 갱신은 중단됩니다. Apple·Google 구독은 해당 스토어에서 별도로 해지해야 합니다. 구매 연결 기록은 정산과 중복 연결 방지를 위해 보관됩니다."))
        }
    }

    private var socialButtons: some View {
        VStack(spacing: 10) {
            ForEach(account.loginProviders) { provider in
                Button {
                    Task { await account.signInSocial(provider: provider.id) { try await authentication.open($0) } }
                } label: {
                    HStack(spacing: 10) {
                        if provider.id == "apple" { Image(systemName: "apple.logo").font(.title3) }
                        else { Image("GoogleLogin").resizable().frame(width: 20, height: 20) }
                        Text(provider.title + (provider.linked ? SPText(" 연결됨") : account.session == nil ? SPText("로 로그인") : SPText(" 연결")))
                        if provider.linked { Image(systemName: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!provider.enabled || provider.linked)
                .accessibilityIdentifier("accountSocial_" + provider.id)
            }
            if account.loginProviders.contains(where: { !$0.enabled }) {
                Text(SPText("비활성화된 로그인 방식은 준비 중입니다. 이메일 로그인을 이용할 수 있습니다."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private final class AccountBrowserAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private struct BrowserError: LocalizedError {
        var errorDescription: String? { SPText("로그인이 취소되었거나 브라우저를 열지 못했습니다.") }
    }
    func open(_ url: URL) async throws -> URL {
        guard session == nil else { throw BrowserError() }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "smoothplayer-auth") { [weak self] callback, _ in
                Task { @MainActor in
                    self?.session = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: BrowserError()) }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { self.session = nil; continuation.resume(throwing: BrowserError()) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
}
