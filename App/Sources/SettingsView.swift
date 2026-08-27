import ImogenKit
import SwiftUI

/// Accounts and backup, in that order, because they are the same decision seen twice:
/// which servers this phone talks to, and which of them get a copy of what it photographs.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var addingAccount = false
    @State private var signingOut: Account?

    var body: some View {
        List {
            Section("Accounts") {
                ForEach(model.accounts.accounts) { account in
                    Button {
                        model.switchTo(account.id)
                    } label: {
                        HStack {
                            Image(
                                systemName: account.id == model.active?.id
                                    ? "largecircle.fill.circle" : "circle"
                            )
                            .foregroundStyle(.tint)

                            VStack(alignment: .leading) {
                                Text(account.name).foregroundStyle(.primary)
                                Text("\(account.email) · \(account.serverLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Sign out", role: .destructive) { signingOut = account }
                    }
                }

                Button {
                    addingAccount = true
                } label: {
                    Label("Add an account", systemImage: "plus")
                }
            }

            Section("Backup") {
                NavigationLink {
                    BackupView()
                } label: {
                    VStack(alignment: .leading) {
                        Text("Photo backup")
                        Text(backupSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text(
                    "imogen for iOS is a client for your own imogen server. Administration — "
                        + "accounts, the processing queue, what is shared publicly — stays in "
                        + "the web interface, where a signed-in browser session is what "
                        + "unlocks it."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                LabeledContent("Licence", value: "AGPL-3.0-or-later")
                Link(
                    "github.com/ergofobe/imogen-ios",
                    destination: URL(string: "https://github.com/ergofobe/imogen-ios")!
                )
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $addingAccount) {
            AddAccountView(canCancel: true)
        }
        .alert(
            "Sign out of \(signingOut?.serverLabel ?? "")?",
            isPresented: .init(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                if let account = signingOut { model.signOut(account) }
                signingOut = nil
            }
        } message: {
            Text(
                "The photographs stay on the server. Anything waiting to be backed up to "
                    + "this account will not be sent."
            )
        }
    }

    private var backupSummary: String {
        let chosen = model.accounts.book.backingUpTo
        return switch chosen.count {
        case 0: "Not backing up"
        case 1: "Backing up to \(chosen[0].serverLabel)"
        default: "Backing up to \(chosen.count) accounts"
        }
    }
}

/// What gets copied, and where to.
///
/// The account list is the interesting part: choosing three means three copies, which is
/// the answer to "my family server and my own", and the screen says so rather than leaving
/// somebody to guess whether the toggles are exclusive.
struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var backupState = PhotoBackup.shared

    var body: some View {
        @Bindable var settings = model.backup

        List {
            Section {
                Toggle("Back up my photos", isOn: $settings.enabled)
                    .onChange(of: settings.enabled) { _, on in
                        PhotoBackup.shared.scheduleBackgroundTask(model)
                        if on { PhotoBackup.shared.runSoon(model) }
                    }
            } footer: {
                Text("New photographs and videos are copied to the accounts below.")
            }

            if let progress = backupState.progress {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(progress.total, 1))
                        )
                        Text(
                            "\(progress.completed) of \(progress.total)"
                                + (progress.filename.map { " · \($0)" } ?? "")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }

            Section {
                ForEach(model.accounts.accounts) { account in
                    Toggle(isOn: .init(
                        get: { account.backupEnabled },
                        set: { model.setBackupEnabled(account, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(account.serverLabel)
                            Text("\(account.name) · \(account.email)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settings.enabled)
                }
            } header: {
                Text("Copy to")
            } footer: {
                Text("Every account you choose gets its own copy.")
            }

            Section {
                Toggle("Wi-Fi only", isOn: $settings.wifiOnly)
                Toggle("Include videos", isOn: $settings.includeVideos)
                Toggle("Camera only", isOn: $settings.cameraOnly)
            } header: {
                Text("What and when")
            } footer: {
                Text(
                    "iOS decides when a background upload may run; it usually chooses "
                        + "overnight, on a charger. A pass also runs whenever imogen is open."
                )
            }

            if let error = backupState.lastError {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Button("Back up now") { PhotoBackup.shared.runSoon(model) }
                    .disabled(!settings.enabled || model.accounts.book.backingUpTo.isEmpty)
                if backupState.isRunning {
                    Button("Stop", role: .destructive) { PhotoBackup.shared.cancel() }
                }
            }
        }
        .navigationTitle("Photo backup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
