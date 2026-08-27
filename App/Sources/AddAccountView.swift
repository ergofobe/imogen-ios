import ImogenKit
import SwiftUI

/// Adding an account.
///
/// Scanning is the front door and typing an address is the side one, and the screen says
/// so: the pairing button is the one that is filled in. Somebody who has the web interface
/// open — which is nearly everybody, because that is where they made the account — never
/// has to type a hostname on a phone keyboard.
struct AddAccountView: View {
    var canCancel: Bool = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var authenticator = WebAuthenticator()
    @State private var scanning = false
    @State private var typing = false
    @State private var address = ""
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    scanner
                } else {
                    chooser
                }
            }
            .toolbar {
                if canCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            scanning ? (scanning = false) : dismiss()
                        }
                    }
                }
            }
        }
        .onChange(of: model.link) { _, state in
            if state == .linked {
                model.clearLinkState()
                dismiss()
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("ImogenMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)
            Text("imogen").font(.largeTitle.weight(.semibold)).padding(.top, 12)
            Text("Your photo library, on your own server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            if model.link == .working {
                ProgressView()
                Text("Connecting…").font(.subheadline).padding(.top, 12)
            } else if typing {
                serverForm
            } else {
                Button {
                    scanning = true
                } label: {
                    Text("Scan a pairing code").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("In imogen on a computer, open Settings → Devices → Pair a device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                Button("Enter a server address") { typing = true }
                    .padding(.top, 18)
            }

            if case .failed(let message) = model.link {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            }

            Spacer()
        }
        .padding(28)
    }

    private var serverForm: some View {
        VStack(spacing: 12) {
            TextField("photos.example.com", text: $address)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(begin)

            Button(action: begin) {
                Text("Continue in the browser").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Back") { typing = false }
        }
    }

    private func begin() {
        model.beginBrowserSignIn(server: address) { url in
            // The system browser, not a web view of our own: its session and password
            // manager are the whole point, and an app that shows its own login form is an
            // app asking to be phished.
            Task {
                guard let callback = await authenticator.authorize(
                    at: url, callbackScheme: oauthCallbackScheme
                ) else { return }
                model.open(callback)
            }
        }
    }

    private var scanner: some View {
        ZStack {
            QRScannerView(
                onScanned: { code in
                    scanning = false
                    model.pair(code)
                },
                onUnavailable: { cameraUnavailable = true }
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                Text(
                    cameraUnavailable
                        ? "imogen needs the camera to read a pairing code. You can enter "
                            + "the server address instead."
                        : "Point the camera at the code on your computer."
                )
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(20)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(28)
            }
        }
    }
}
