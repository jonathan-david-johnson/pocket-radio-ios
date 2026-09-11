import PocketCastsDataModel
import SwiftUI

/// Settings screen for the configurable tab bar. Pushed from
/// `SettingsViewController` in a `UIHostingController`.
///
/// One ordered list with a fixed **More** row in it: above that row is the tab
/// bar, below it is the More tab. Dragging across the row promotes or demotes,
/// so reorder, promote and demote are a single gesture rather than three
/// different interactions. The More row is structure, not a preview of the bar
/// — the milestone rules a live preview out of v1.
///
/// File location deviation from the milestone as written
/// (`podcasts/Settings/TabBarSettingsView.swift`): that directory does not
/// exist in this project. This file lives in `podcasts/Main/TabLayout/`
/// alongside the rest of the feature, because that directory is a
/// `PBXFileSystemSynchronizedRootGroup` and registers with the build
/// automatically — a new directory would force a `project.pbxproj` edit.
///
/// Every editing rule lives in `TabLayoutEditor`, not here. This view renders
/// its state and forwards gestures to it.
struct TabBarSettingsView: View {
    @EnvironmentObject private var theme: Theme
    @StateObject private var editor: TabLayoutEditor
    @State private var isShowingAddSheet = false

    /// The layout as it was when the screen opened, so Save can be offered only
    /// when something actually changed.
    private let initialSlots: [TabSlot]

    init(layout: TabLayout = TabLayoutStore.shared.load(),
         capacity: Int = TabLayout.capacity(for: UITraitCollection())) {
        initialSlots = layout.slots
        _editor = StateObject(wrappedValue: TabLayoutEditor(layout: layout, capacity: capacity))
    }

    private var hasChanges: Bool {
        editor.currentLayout.slots != initialSlots
    }

    var body: some View {
        List {
            Section {
                ForEach(editor.rows) { row in
                    view(for: row)
                        .moveDisabled(row == .more)
                        .deleteDisabled(!editor.canDelete(row))
                }
                .onMove { source, destination in
                    editor.move(fromRows: source, toRow: destination)
                }
                .onDelete { offsets in
                    editor.delete(atRows: offsets)
                }
            } footer: {
                footer
            }
        }
        .listStyle(.insetGrouped)
        // Always-on edit mode: dragging is the primary interaction here, so the
        // handles should not be behind an Edit button.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Bar")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a tab")

                Button("Save") {
                    TabLayoutApplier.apply(editor.currentLayout, source: .settings)
                }
                .disabled(!hasChanges)
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddTabSheet(existing: Set(editor.bar + editor.extras)) { destination in
                editor.add(destination)
            }
            .environmentObject(theme)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.needsMoreRow {
                Text("More takes a slot of its own, so the bar holds \(editor.barCapacity) of your tabs while it is shown. Drag an item above More to put it in the bar.")
            } else {
                Text("Drag to reorder. Adding a \(editor.capacity + 1)th tab creates a More tab for whatever does not fit.")
            }

            Text("Your tab bar layout syncs across your devices when you're signed in.")
        }
        .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
    }

    @ViewBuilder
    private func view(for row: TabSettingsRow) -> some View {
        switch row {
        case .destination(let destination):
            destinationRow(destination)
        case .more:
            moreRow
        }
    }

    @ViewBuilder
    private func destinationRow(_ destination: TabDestination) -> some View {
        HStack(spacing: 16) {
            icon(destination.icon())

            if isDeletedPlaylist(destination) {
                // The slot is kept rather than dropped (design §6), so say so
                // plainly instead of rendering it as a generic playlist row.
                Text("Deleted playlist")
                    .italic()
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
            } else {
                Text(destination.title())
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            }
        }
    }

    private func isDeletedPlaylist(_ destination: TabDestination) -> Bool {
        guard case .playlist = destination else { return false }
        return destination.playlist == nil
    }

    /// The boundary. Deliberately reads as a divider rather than a tab: it is
    /// the one row you cannot drag, and it explains what the rows under it are.
    @ViewBuilder
    private var moreRow: some View {
        HStack(spacing: 16) {
            icon(UIImage(systemName: "ellipsis"))

            VStack(alignment: .leading, spacing: 2) {
                Text("More")
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                Text("Everything below is inside this tab")
                    .font(.footnote)
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
            }
        }
        .listRowBackground(AppTheme.color(for: .primaryUi04, theme: theme))
    }

    @ViewBuilder
    private func icon(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundColor(AppTheme.color(for: .primaryIcon01, theme: theme))
        } else {
            Color.clear.frame(width: 24, height: 24)
        }
    }
}

/// "Add a tab": the destinations that are not already in the list. Core
/// destinations never appear, because they are always in the list somewhere.
private struct AddTabSheet: View {
    @EnvironmentObject private var theme: Theme
    @Environment(\.dismiss) private var dismiss

    let existing: Set<TabDestination>
    let onSelect: (TabDestination) -> Void

    private var playlists: [EpisodeFilter] {
        DataManager.sharedManager.allPlaylists(includeDeleted: false)
            .filter { !existing.contains(.playlist(uuid: $0.uuid)) }
    }

    private var showsUpNext: Bool {
        !existing.contains(.upNext)
    }

    var body: some View {
        NavigationView {
            List {
                if showsUpNext {
                    Section {
                        row(title: TabDestination.upNext.title()) {
                            onSelect(.upNext)
                        }
                    }
                }

                Section {
                    if playlists.isEmpty {
                        Text("Every playlist is already in the list.")
                            .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                    } else {
                        ForEach(playlists, id: \.uuid) { playlist in
                            row(title: playlist.playlistName) {
                                onSelect(.playlist(uuid: playlist.uuid))
                            }
                        }
                    }
                } header: {
                    Text("Playlists")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add a Tab")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Text(title)
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
        }
    }
}
