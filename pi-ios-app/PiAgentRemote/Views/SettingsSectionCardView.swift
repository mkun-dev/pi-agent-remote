import SwiftUI

struct SettingsSectionCardView<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(PiDesignSystem.Font.headline)
                .foregroundStyle(PiDesignSystem.Color.primary)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .piCard(color: PiDesignSystem.Color.surface, radius: 18)
        }
    }
}
