import SwiftUI

/// Public app information only; never include the user's account or media in a share.
enum AppPromotion {
    static let appStoreReview = URL(string: "https://apps.apple.com/app/id6826789106?action=write-review")!
    static let googlePlay = URL(string: "https://play.google.com/store/apps/details?id=com.nodelabs.smoothplayer")!
    static var introduction: String {
        SPText("내 기기와 NAS의 동영상을 한곳에서. 부드러운 재생, 자막, 사운드 보정을 지원하는 Smooth Player를 만나보세요.")
    }
    static var website: URL {
        let language = AppLanguage.shared.code
        let path = language == "ko" ? "" : language == "zh-Hans" ? "zh/" : "\(language)/"
        return URL(string: "https://smoothplayer.kr/\(path)")!
    }
    static var shareText: String { introduction + "\n\n" + website.absoluteString }
}

struct AppPromotionActions: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                Text(AppPromotion.introduction).font(.subheadline).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 12) { actions }
            }.buttonStyle(.bordered)
            #if os(macOS)
            if !compact {
                Text(SPText("Mac 버전은 홈페이지에서 배포합니다. 별점은 설치한 모바일 앱의 스토어에서 남겨 주세요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
    }

    @ViewBuilder private var actions: some View {
        ShareLink(item: AppPromotion.shareText, subject: Text("Smooth Player")) {
            Label(SPText("앱 공유"), systemImage: "square.and.arrow.up")
        }.accessibilityLabel(SPText("앱 공유"))
            .accessibilityIdentifier("shareSmoothPlayer")
        #if os(macOS)
        Menu {
            Link("App Store · iPhone/iPad", destination: AppPromotion.appStoreReview)
            Link("Google Play · Android", destination: AppPromotion.googlePlay)
        } label: {
            Label(SPText("별점·리뷰"), systemImage: "star")
        }.accessibilityIdentifier("rateSmoothPlayer")
        #else
        Link(destination: AppPromotion.appStoreReview) {
            Label(SPText("별점·리뷰"), systemImage: "star")
        }.accessibilityIdentifier("rateSmoothPlayer")
        #endif
    }
}
