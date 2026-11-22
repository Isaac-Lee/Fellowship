import SwiftUI

struct ShowCardView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = false

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Text(message.translation)
                    .font(.system(size: 160, weight: .semibold))
                    .minimumScaleFactor(0.1)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                Text(message.original).font(.title3).lineLimit(2).foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .rotationEffect(.degrees(flipped ? 180 : 0))

            // 힌트는 나를 위한 것이라 회전하지 않는다
            VStack {
                HStack {
                    Spacer()
                    Button { withAnimation { flipped.toggle() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.title3)
                            .foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("180도 돌리기")
                }
                Spacer()
                Text("아무 곳이나 눌러 닫기").font(.footnote).foregroundStyle(.tertiary).padding(.bottom, 8)
            }
            .padding(8)
        }
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}

#Preview {
    ShowCardView(message: Message(speaker: .me, original: "화장실이 어디예요?", translation: "請問洗手間在哪裡？"))
}

#Preview("가로", traits: .landscapeLeft) {
    ShowCardView(message: Message(speaker: .me, original: "화장실이 어디예요?", translation: "請問洗手間在哪裡？"))
}
