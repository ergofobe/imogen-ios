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

                if let failure = model.accounts.lastSaveFailure {
                    SaveFailureRow(failure: failure) {
                        model.accounts.dismissSaveFailure()
                    }
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

    private var failureCount: Int {
        backupState.resting.values.reduce(0) { $0 + $1.failures }
    }

    private func restingSummary(for accountId: String) -> String {
        guard let state = backupState.resting[accountId] else { return "Nothing backed up yet" }
        var parts: [String] = []
        parts.append(state.backedUp == 0 ? "Nothing backed up yet" : "\(state.backedUp) backed up")
        if let at = state.lastCompletedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: Date(timeIntervalSince1970: at), relativeTo: Date()))
        }
        if state.failures > 0 { parts.append("\(state.failures) failed") }
        return parts.joined(separator: " · ")
    }

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
                            // Always something, per destination. A row that goes blank
                            // between passes cannot tell a finished backup from a
                            // stalled one, which is the whole complaint.
                            Text(restingSummary(for: account.id))
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

            if failureCount > 0 {
                Section {
                    NavigationLink {
                        FailedUploadsView()
                    } label: {
                        // Given-up files are named first: they are the ones nothing else
                        // will ever mention again.
                        Text("\(failureCount) couldn't be backed up")
                    }
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
        .task {
            // The numbers only move when a pass runs, so this is read on arrival rather
            // than polled.
            await PhotoBackup.shared.refreshResting(model.accounts.book.backingUpTo)
        }
    }
}

/// The accounts could not be written to the keychain.
///
/// In the accounts section rather than a banner: it is a warning about what is on disk,
/// not about anything the person is doing right now, and the screen it belongs to is the
/// one that shows the accounts it is about.
private struct SaveFailureRow: View {
    let failure: AccountSaveFailure
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.consequence, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)

            Text(failure.reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Dismiss", action: dismiss)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
