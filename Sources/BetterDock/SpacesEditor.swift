import AppKit
import BetterDockCore
import SwiftUI
import UniformTypeIdentifiers

/// The "BetterDock" window: one row per macOS desktop in the sidebar, the
/// selected desktop's dock items on the right.
struct SpacesEditor: View {
    static let windowID = "spaces-editor"
    /// Sidebar selection for the "Shared items" row.
    private static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @EnvironmentObject private var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(Array(model.library.spaces.enumerated()), id: \.element.id) { index, space in
                        HStack(spacing: 8) {
                            SpaceBadge(space: space, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(space.name)
                                Text(index < model.desktopCount ? "Desktop \(index + 1)" : "No desktop yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if space.id == model.library.activeSpaceID {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .tag(space.id)
                    }
                    .onMove { model.library.spaces.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Desktops")
                } footer: {
                    Text("Add or remove desktops in Mission Control. Drag to change which dock goes with which desktop.")
                }
                Section {
                    Label("Shared items", systemImage: "star")
                        .tag(Self.sharedID)
                } footer: {
                    Text("In the dock on every desktop.")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if selection == Self.sharedID {
                SharedItemsDetail()
            } else if let id = selection, let space = binding(for: id) {
                SpaceDetail(space: space, canDelete: model.canDelete(space.wrappedValue)) {
                    model.deleteSpace(id: id)
                    selection = model.library.spaces.first?.id
                }
            } else {
                Text("Select a desktop")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selection == nil {
                selection = model.library.activeSpaceID ?? model.library.spaces.first?.id
            }
        }
    }

    /// A binding by id, so deleting a space can't leave a stale index behind.
    private func binding(for id: UUID) -> Binding<Space>? {
        guard let current = model.library.spaces.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.library.spaces.first { $0.id == id } ?? current },
            set: { newValue in
                if let index = model.library.index(of: id) { model.library.spaces[index] = newValue }
            }
        )
    }
}

private struct SpaceDetail: View {
    @EnvironmentObject private var model: AppModel
    @Binding var space: Space
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                DockItemsEditor(title: "In this desktop's dock", items: $space.items)
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            SpaceBadge(space: space, size: 48)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $space.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 280)
                HStack(spacing: 6) {
                    ForEach(Space.palette, id: \.self) { hex in
                        Button {
                            space.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.white, lineWidth: space.colorHex == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(hex)")
                    }
                    Divider().frame(height: 18)
                    Picker("Icon", selection: $space.symbol) {
                        ForEach(Space.symbols, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .disabled(!canDelete)
            .help(canDelete ? "Delete this dock" : "Remove the desktop in Mission Control first")
        }
    }
}

private struct SharedItemsDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shared items").font(.title2.weight(.semibold))
                Text("These stay in the dock on every desktop. Shared apps come first, shared folders and links last.")
                    .foregroundStyle(.secondary)
                DockItemsEditor(title: "On every desktop", items: $model.library.sharedItems)
            }
            .padding(24)
        }
    }
}

/// An ordered, editable list of dock items with add buttons.
private struct DockItemsEditor: View {
    let title: String
    @Binding var items: [DockItem]
    @State private var newLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Add App…") { choose(apps: true) }
                Button("Add Folder or File…") { choose(apps: false) }
            }
            List {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        ItemIcon(item: item, size: 24)
                        Text(item.displayName).frame(width: 160, alignment: .leading)
                        Text(item.location)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(item.kind.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(item.displayName)")
                    }
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 200)
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                TextField("Add a link, e.g. https://github.com", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addLink)
                Button("Add Link", action: addLink)
                    .disabled(URL(string: newLink)?.scheme == nil)
            }
        }
    }

    private func addLink() {
        let trimmed = newLink.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        items.append(.link(url.absoluteString))
        newLink = ""
    }

    private func choose(apps: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if apps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.canChooseDirectories = false
        } else {
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
        }
        guard panel.runModal() == .OK else { return }
        let existing = Set(items.map(\.identityKey))
        for url in panel.urls {
            let item = DockItem(kind: AppModel.kind(of: url), location: url.path)
            if !existing.contains(item.identityKey) { items.append(item) }
        }
    }
}
