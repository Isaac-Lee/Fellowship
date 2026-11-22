import SwiftUI

struct ShowCardView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 24) {
                Text(message.translation)
                    .font(.system(size: 160, weight: .bold))
                    .minimumScaleFactor(0.1)
                    .multilineTextAlignment(.center)
                Text(message.original).font(.title3).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .rotationEffect(.degrees(flipped ? 180 : 0))
            .background(Color(.systemBackground))
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            Button { withAnimation { flipped.toggle() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.title).padding(16)
            }
            .accessibilityLabel("180도 돌리기")
        }
    }
}

#Preview {
    ShowCardView(message: Message(speaker: .me, original: "화장실이 어디예요?", translation: "請問洗手間在哪裡？"))
}
