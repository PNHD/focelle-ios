import SwiftUI

struct CameraPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Text("app.name")
                        .font(.headline)
                    Spacer()
                    Text("beta.badge")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }

                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(.orange)
                            Text("camera.placeholder.title")
                                .font(.title3.weight(.semibold))
                            Text("camera.placeholder.subtitle")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    }
                    .aspectRatio(3 / 4, contentMode: .fit)

                Circle()
                    .fill(.ivory)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 5).padding(-7))
                    .accessibilityLabel(Text("camera.shutter"))
            }
            .foregroundStyle(.ivory)
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}
private extension ShapeStyle where Self == Color {
    static var ivory: Color { Color(red: 0.96, green: 0.94, blue: 0.88) }
}

#Preview {
    CameraPlaceholderView()
}
