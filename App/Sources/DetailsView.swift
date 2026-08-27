import ImogenKit
import ImogenSDK
import SwiftUI

/// Everything the server knows about one photograph.
///
/// The description is editable here rather than on a screen of its own, because it is the
/// one piece of this that is a person's rather than the camera's — and because search
/// reads it, so a sentence typed here is how the photograph gets found again.
struct DetailsView: View {
    let asset: Asset
    let onDescriptionChanged: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var description: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text(asset.originalFilename)
                } footer: {
                    Text(
                        fullDate(asset.capturedAt)
                            + (asset.capturedAtIsExact ? "" : " (estimated)")
                    )
                }

                Section("File") {
                    Fact("Size", formatBytes(asset.sizeBytes))
                    if let width = asset.width, let height = asset.height {
                        Fact("Dimensions", "\(width) × \(height)")
                    }
                    if let duration = asset.duration {
                        Fact("Length", formatDuration(duration))
                    }
                    Fact("Type", asset.mimeType)
                    // The checksum is what makes an upload idempotent, so it is worth
                    // showing: it answers "did this arrive, and is it the same file".
                    Fact("Checksum", String(asset.checksum.prefix(16)) + "…")
                }

                if let exif = asset.exif, hasSomething(exif) {
                    Section("Camera") {
                        let camera = [exif.make, exif.model].compactMap { $0 }.joined(separator: " ")
                        if !camera.isEmpty { Fact("Camera", camera) }
                        if let lens = exif.lens { Fact("Lens", lens) }
                        if let aperture = exif.fNumber { Fact("Aperture", "ƒ/\(aperture)") }
                        if let exposure = exif.exposureTime {
                            Fact("Shutter", formatShutter(exposure))
                        }
                        if let iso = exif.iso { Fact("ISO", "\(iso)") }
                        if let focal = exif.focalLength {
                            Fact("Focal length", "\(Int(focal.rounded())) mm")
                        }
                    }
                }

                if let place = asset.location {
                    Section("Where") {
                        Fact(
                            "Place",
                            place.place
                                ?? String(format: "%.5f, %.5f", place.latitude, place.longitude)
                        )
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onDescriptionChanged(description)
                        dismiss()
                    }
                    .disabled(description == (asset.description ?? ""))
                }
            }
        }
        .onAppear { description = asset.description ?? "" }
    }

    private func hasSomething(_ exif: ExifData) -> Bool {
        exif.make != nil || exif.model != nil || exif.lens != nil || exif.fNumber != nil
            || exif.exposureTime != nil || exif.iso != nil || exif.focalLength != nil
    }
}

struct Fact: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
