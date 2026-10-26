// The Library page: the nxnative game apps found on this Mac (a grid, with the selected game's details in the inspector) and the history of every
// conversion (a table), switched by tabs in a bar under the toolbar; the history notice, the empty states and the page's toolbar
import ConverterCore
import SwiftUI

struct LibraryPage: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    @AppStorage(LibraryTab.storageKey) private var tab = LibraryTab.games
    @AppStorage("libraryInspector") private var showsInspector = true

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) { bar }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            // Switching to History hides the inspector without forgetting that it was open
            .inspector(isPresented: Binding(get: { showsInspector && showsGames }, set: { if showsGames { showsInspector = $0 } })) {
                inspector.inspectorColumnWidth(min: 260, ideal: 280, max: 340)
            }
            .toolbar { toolbar }
    }

    /// No game apps and no conversions: the page shows only how to begin
    private var isEmpty: Bool { model.library.isEmpty && model.records.isEmpty }

    private var showsGames: Bool { tab == .games && !isEmpty }

    private var selectedEntry: LibraryEntry? { window.selectedApp.flatMap { id in model.library.first { $0.id == id } } }

    @ViewBuilder private var content: some View {
        @Bindable var window = window
        if isEmpty {
            ContentUnavailableView {
                Label("Your converted games live here", systemImage: "square.grid.2x2.fill")
            } description: {
                Text("Each one remembers the nxnative version that built it, so you can rebuild it when nxnative improves.")
            } actions: {
                Button("Convert a Game…") { model.chooseGameFolders() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            switch tab {
            case .games:
                if model.library.isEmpty {
                    ContentUnavailableView {
                        Label("No Game Apps Found", systemImage: "square.grid.2x2")
                    } description: {
                        Text("No game apps were found in your install folders. History has every conversion.")
                    } actions: {
                        Button("Show History") { tab = .history }
                    }
                } else {
                    LibraryGrid(entries: model.library, selection: $window.selectedApp)
                }
            case .history:
                if model.records.isEmpty {
                    ContentUnavailableView {
                        Label("No Conversions Yet", systemImage: "clock")
                    } description: {
                        Text("Every conversion is listed here, with the nxnative version that ran it.")
                    }
                } else {
                    HistoryTable(records: model.records.reversed(), selection: $window.selectedRecords)
                }
            }
        }
    }

    /// The tabs and the history notice, under the toolbar: the grid and the table scroll beneath them
    @ViewBuilder private var bar: some View {
        if !isEmpty || model.libraryNotice != nil {
            VStack(spacing: Space.m) {
                if !isEmpty {
                    Picker("Library Section", selection: $tab) {
                        Text("Games").tag(LibraryTab.games)
                        Text("History").tag(LibraryTab.history)
                    }
                    .pickerStyle(.tabs)
                    .labelsHidden()
                    .fixedSize()
                }
                if let notice = model.libraryNotice {
                    Notice(.warning, title: "Some of the conversion history could not be read", message: notice) {
                        Button("Dismiss") { model.libraryNotice = nil }
                            .help("Hide this notice")
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let entry = selectedEntry {
            LibraryInspector(entry: entry)
        } else {
            ContentUnavailableView("No Game Selected", systemImage: "square.grid.2x2", description: Text("Select a game to see its details."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await window.refreshLibrary(model) } }
                .help("Look for game apps again")
                .disabled(window.refreshingLibrary)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(LibraryAction.play.title) { if let entry = selectedEntry { LibraryAction.play.perform(on: entry, in: model) } }
                .buttonStyle(.glassProminent)
                .help(selectedEntry.map { LibraryAction.play.help(for: $0, files: window.libraryFiles) } ?? "Open the selected game")
                .disabled(selectedEntry == nil)
        }
        .visibilityPriority(.high)
        .hidden(!showsGames)
        // Hidden with Play, so History does not show two gaps between Refresh and Game Details
        ToolbarSpacer(.fixed)
            .hidden(!showsGames)
        ToolbarItem {
            Button("Game Details", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help("Show or hide game details")
                .disabled(!showsGames)
        }
    }

    private var subtitle: String {
        guard !isEmpty else { return "" }
        switch tab {
        case .games:
            let games = model.library.count
            let rebuildable = model.library.filter { entry in entry.record != nil && (entry.commit.flatMap { model.commitsBehind[$0] } ?? 0) > 0 }.count
            return "\(games) game\(games == 1 ? "" : "s")" + (rebuildable > 0 ? " · \(rebuildable) can be rebuilt" : "")
        case .history:
            let conversions = model.records.count
            return "\(conversions) conversion\(conversions == 1 ? "" : "s")"
        }
    }
}
