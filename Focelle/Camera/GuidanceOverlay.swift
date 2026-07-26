import SwiftUI

struct GuidanceOverlay: View {
    let guidance: Guidance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let rect = guidance.subjectRect {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(guidance.aligned ? .green : .orange, lineWidth: 2)
                        .frame(
                            width: rect.width * geometry.size.width,
                            height: rect.height * geometry.size.height
                        )
                        .position(
                            x: rect.midX * geometry.size.width,
                            y: rect.midY * geometry.size.height
                        )
                }

                Circle()
                    .strokeBorder(
                        guidance.aligned ? .green : .white,
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                    )
                    .frame(width: 48, height: 48)
                    .position(
                        x: guidance.target.x * geometry.size.width,
                        y: guidance.target.y * geometry.size.height
                    )

                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.title2.bold())
                    if let instruction = guidance.instruction {
                        Text(instruction)
                    } else {
                        Text(LocalizedStringKey(guidance.instructionKey))
                    }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .foregroundStyle(.white)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.16)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch guidance.direction {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .closer: "arrow.up.left.and.arrow.down.right"
        case .farther: "arrow.down.right.and.arrow.up.left"
        case .level: "level"
        case .brighten: "sun.max"
        case .darken: "sun.min"
        case .none: guidance.aligned ? "checkmark" : "viewfinder"
        }
    }

    private var accessibilityLabel: Text {
        if let instruction = guidance.instruction {
            Text(verbatim: instruction)
        } else {
            Text(LocalizedStringKey(guidance.instructionKey))
        }
    }
}
