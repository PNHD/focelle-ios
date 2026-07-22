@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    @StateObject private var camera = CameraSession()

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            if camera.state != .running {
                statusView
            }

            VStack {
                HStack {
                    Text("app.name").font(.headline)
                    Spacer()
                    Text("beta.badge")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }

                Spacer()

                if let notice = camera.notice {
                    Text(LocalizedStringKey(notice))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.7), in: Capsule())
                }

                HStack {
                    Button(action: camera.switchCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel(Text("camera.switch"))
                    .disabled(camera.state != .running)

                    Spacer()

                    Button(action: camera.capture) {
                        Circle()
                            .fill(Color(red: 0.96, green: 0.94, blue: 0.88))
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 5).padding(-7))
                    }
                    .accessibilityLabel(Text("camera.shutter"))
                    .disabled(camera.state != .running)

                    Spacer()

                    Color.clear.frame(width: 52, height: 52)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .onAppear(perform: camera.start)
        .onDisappear(perform: camera.stop)
    }

    @ViewBuilder
    private var statusView: some View {
        Color.black.ignoresSafeArea()
        VStack(spacing: 14) {
            Image(systemName: camera.state == .permissionDenied ? "camera.fill" : "viewfinder")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.orange)
            Text(statusKey).font(.title3.weight(.semibold))
            if camera.state == .permissionDenied {
                Button("camera.openSettings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .foregroundStyle(.white)
    }

    private var statusKey: LocalizedStringKey {
        switch camera.state {
        case .starting: "camera.starting"
        case .permissionDenied: "camera.permissionDenied"
        case .unavailable: "camera.unavailable"
        case .running: ""
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

#Preview {
    CameraView()
}
