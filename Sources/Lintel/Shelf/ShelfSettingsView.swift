import LintelCore
import SwiftUI

/// Settings › Activities › Shelf.
struct ShelfSettingsView: View {
    let settings: SettingsStore
    @State private var confirmingClear = false

    var body: some View {
        let shelf = ShelfFeature.shared
        let enabled = settings[Keys.shelfEnabled]
        Form {
            Section {
                Toggle("Keep files on the Shelf", isOn: settings.binding(Keys.shelfEnabled))
                Toggle("Show in the island while it has items", isOn: settings.binding(Keys.shelfIndicator))
                    .disabled(!enabled)
            } header: {
                Text("Shelf")
            } footer: {
                Text("Drag files, folders, images, text or links over the island to keep them here, then drag them out to any app or Finder. Click an item to open it; press Space to preview it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker("When you drop files", selection: settings.binding(Keys.shelfStorage)) {
                    ForEach(ShelfStorageMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!enabled)
            } header: {
                Text("Storage")
            } footer: {
                Text(storageFooter)
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let shelf {
                Section {
                    LabeledContent("On the Shelf") {
                        Text(summary(shelf)).monospacedDigit()
                    }
                    if let problem = shelf.problem {
                        Text(problem).font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Show Stored Files") { shelf.revealStorageFolder() }
                        Spacer()
                        Button("Clear Shelf…") { confirmingClear = true }
                            .disabled(shelf.items.isEmpty)
                            .confirmationDialog("Clear the Shelf?", isPresented: $confirmingClear) {
                                Button("Clear \(ShelfNaming.itemsLabel(shelf.items.count))", role: .destructive) { shelf.clearAll() }
                            } message: {
                                Text("Stored copies are deleted. Originals stay where they are.")
                            }
                    }
                } footer: {
                    Text("Files in Desktop, Documents, Downloads and iCloud Drive are protected by macOS. Lintel reads them when you drop them; after Lintel restarts, opening one may ask for access. Storing a copy avoids that.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .onAppear { shelf.refreshStoredSize() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shelf")
    }

    private var storageFooter: String {
        switch settings[Keys.shelfStorage] {
        case .reference:
            return "The Shelf remembers where each file is, and follows it when you move or rename it. Removing an item never touches the file."
        case .copy:
            return "Lintel copies what you drop to ~/Library/Application Support/Lintel/Shelf and deletes the copy when you remove it from the Shelf. The original stays where it is."
        }
    }

    private func summary(_ shelf: ShelfFeature) -> String {
        let count = ShelfNaming.itemsLabel(shelf.items.count)
        guard let bytes = shelf.storedBytes, bytes > 0 else { return count }
        return "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) stored"
    }
}
