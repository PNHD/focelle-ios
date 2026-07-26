import SwiftUI

struct GuidanceOverlay: View {
    let guidance: Guidance

    var body: some View {
        GeometryReader { geometry in
            let target = CGPoint(
                x: guidance.target.x * geometry.size.width,
                y: guidance.target.y * geometry.size.height
            )

            ZStack {
                if let rect = guidance.subjectRect {
                    let current = CGPoint(
                        x: rect.midX * geometry.size.width,
                        y: rect.midY * geometry.size.height
                    )

                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            guidance.aligned ? .green : .white.opacity(0.7),
                            lineWidth: 1.5
                        )
                        .frame(
                            width: rect.width * geometry.size.width,
                            height: rect.height * geometry.size.height
                        )
                        .position(current)

                    if guidance.direction.usesAimRing {
                        Path { path in
                            path.move(to: current)
                            path.addLine(to: target)
                        }
                        .stroke(
                            .white.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])
                        )

                        ZStack {
                            Circle().fill(.black.opacity(0.55))
                            Circle().stroke(.white, lineWidth: 2)
                            Circle().fill(.cyan).frame(width: 6, height: 6)
                        }
                        .frame(width: 22, height: 22)
                        .position(current)

                        Circle()
                            .stroke(
                                guidance.aligned
                                    ? AnyShapeStyle(.green)
                                    : AnyShapeStyle(
                                        AngularGradient(
                                            colors: [.cyan, .orange, .pink, .cyan],
                                            center: .center
                                        )
                                    ),
                                style: StrokeStyle(lineWidth: 3, dash: [7, 4])
                            )
                            .frame(
                                width: guidance.aligned ? 34 : 52,
                                height: guidance.aligned ? 34 : 52
                            )
                            .shadow(color: guidance.aligned ? .green : .cyan, radius: 4)
                            .position(target)
                    }

                    if guidance.direction.usesTargetFrame,
                        let targetRect = guidance.targetRect
                    {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                AngularGradient(
                                    colors: [.cyan, .orange, .pink, .cyan],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 3, dash: [10, 5])
                            )
                            .frame(
                                width: targetRect.width * geometry.size.width,
                                height: targetRect.height * geometry.size.height
                            )
                            .position(
                                x: targetRect.midX * geometry.size.width,
                                y: targetRect.midY * geometry.size.height
                            )
                            .shadow(color: .cyan, radius: 4)
                    }
                }

                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.title2.bold())
                    Group {
                        if let instruction = guidance.instruction {
                            Text(instruction)
                        } else {
                            Text(LocalizedStringKey(guidance.instructionKey))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    if guidance.direction.usesAimRing, !guidance.aligned,
                        guidance.subjectRect != nil
                    {
                        Text("guidance.aimAtRing")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
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
