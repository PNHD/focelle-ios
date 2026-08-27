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
                ForEach(guidance.people, id: \.id) { person in
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            person.isSelected ? Color.orange : .white.opacity(0.38),
                            lineWidth: person.isSelected ? 2.5 : 1
                        )
                        .frame(
                            width: person.frame.width * geometry.size.width,
                            height: person.frame.height * geometry.size.height
                        )
                        .position(
                            x: person.frame.midX * geometry.size.width,
                            y: person.frame.midY * geometry.size.height
                        )

                    if let face = person.faceFrame {
                        Circle()
                            .stroke(.white.opacity(0.55), lineWidth: 1)
                            .frame(
                                width: face.width * geometry.size.width,
                                height: face.height * geometry.size.height
                            )
                            .position(
                                x: face.midX * geometry.size.width,
                                y: face.midY * geometry.size.height
                            )
                    }
                }

                if let horizon = guidance.horizonAngle, abs(horizon) > 0.001 {
                    Path { path in
                        let rise = CGFloat(horizon) * geometry.size.width
                        path.move(to: CGPoint(x: 0, y: geometry.size.height * 0.5 + rise))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.5 - rise))
                    }
                    .stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }

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

                    if let movement = Self.aimRingPath(guidance) {
                        Path { drawing in
                            drawing.move(
                                to: CGPoint(
                                    x: movement.start.x * geometry.size.width,
                                    y: movement.start.y * geometry.size.height
                                )
                            )
                            drawing.addLine(
                                to: CGPoint(
                                    x: movement.end.x * geometry.size.width,
                                    y: movement.end.y * geometry.size.height
                                )
                            )
                        }
                        .stroke(
                            .white.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])
                        )

                        ZStack {
                            Circle().fill(.black.opacity(0.55))
                            Circle().stroke(.white, lineWidth: 2)
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                        .frame(width: 22, height: 22)
                            .position(current)

                        Circle()
                            .stroke(
                                guidance.aligned
                                    ? AnyShapeStyle(.green)
                                    : AnyShapeStyle(Color.orange),
                                style: StrokeStyle(lineWidth: 3, dash: [7, 4])
                            )
                            .frame(
                                width: guidance.aligned ? 34 : 52,
                                height: guidance.aligned ? 34 : 52
                            )
                            .shadow(color: guidance.aligned ? .green : .orange, radius: 4)
                            .position(target)
                    }

                    if guidance.direction.usesTargetFrame,
                        let targetRect = guidance.targetRect
                    {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                Color.orange,
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
                            .shadow(color: .orange, radius: 4)
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
                    if Self.showsAimRingHint(guidance) {
                        Text("guidance.aimAtRing")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .foregroundStyle(.white)
                // Sit above the subject normally, but drop below it when the
                // subject reaches into the band the instruction would occupy.
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height * (Self.instructionSitsHigh(guidance) ? 0.16 : 0.84)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    static func instructionSitsHigh(_ guidance: Guidance) -> Bool {
        guard let rect = guidance.subjectRect else { return true }
        return rect.minY > 0.26
    }

    // One production truth for the aim ring. The dashed movement line, the
    // movement marker and the dashed target circle are drawn exactly when this
    // returns a path, and the "aim at the ring" hint is gated on the same
    // call, so the hint can never name geometry that is not on screen.
    static func aimRingPath(_ guidance: Guidance) -> GuidancePath? {
        guard guidance.subjectRect != nil else { return nil }
        return guidance.movementPath
    }

    static func showsAimRingHint(_ guidance: Guidance) -> Bool {
        aimRingPath(guidance) != nil && !guidance.aligned
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
