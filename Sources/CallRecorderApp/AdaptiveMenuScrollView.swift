import SwiftUI

struct AdaptiveMenuScrollView<Content: View>: View {
    private let maximumHeight: CGFloat
    private let content: Content

    @State private var measuredContentHeight: CGFloat?

    init(
        maximumHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.maximumHeight = maximumHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MenuContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
        }
        .frame(height: displayedHeight)
        .scrollDisabled(!contentRequiresScrolling)
        .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            if let measuredContentHeight,
               abs(measuredContentHeight - height) < 0.5 {
                return
            }
            measuredContentHeight = height
        }
    }

    private var displayedHeight: CGFloat {
        min(measuredContentHeight ?? maximumHeight, maximumHeight)
    }

    private var contentRequiresScrolling: Bool {
        guard let measuredContentHeight else { return false }
        return measuredContentHeight > maximumHeight
    }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
