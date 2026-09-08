import ImogenKit
import SwiftUI

/// The photographs that did not make it, and a way to ask again.
///
/// The retry matters more than the list. A file that spends its attempts is folded into
/// `settled` and skipped by every later pass, so when the reason was a bug in this app
/// rather than anything about the file, this is the only route back into the backup.
struct FailedUploadsView: View {
    @Environment(AppModel.self) private var model
    @State private var failures: [(account: Account, record: UploadRecord)] = []

    var body: some View {
        List {
            if failures.isEmpty {
                Section {
                    Text("Nothing has failed")
                    Text(
                        "Every photograph the app has tried to back up has either arrived "
                            + "or is still waiting its turn."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                let summary = summarise(failures.map(\.record))

                Section {
                    Text(
                        summary.givenUp > 0
                            ? "\(summary.givenUp) given up on, \(summary.willRetry) still to be tried"
                            : "\(summary.willRetry) still to be tried"
                    )
                    if summary.givenUp > 0 {
                        Text(
                            "Anything given up on is skipped by every future backup until "
                                + "you ask for it again."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button("Try all of them again") {
                            Task {
                                await PhotoBackup.shared.retryAll(model)
                                await reload()
                            }
                        }
                    }
                }

                ForEach(failures, id: \.record.localId) { failure in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.record.name).lineLimit(1)
                            Text(caption(for: failure))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = failure.record.lastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        if failure.record.failureState == .givenUp {
                            Button("Try again") {
                                Task {
                                    await PhotoBackup.shared.retry(
                                        failure.record.localId,
                                        for: failure.account.id,
                                        model: model
                                    )
                                    await reload()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Couldn't be backed up")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func caption(for failure: (account: Account, record: UploadRecord)) -> String {
        let state =
            failure.record.failureState == .givenUp
            ? "given up after \(failure.record.attempts) tries"
            : "tried \(failure.record.attempts), will try again"
        return "\(failure.account.serverLabel) · \(state)"
    }

    private func reload() async {
        failures = await PhotoBackup.shared.failures(model)
    }
}
