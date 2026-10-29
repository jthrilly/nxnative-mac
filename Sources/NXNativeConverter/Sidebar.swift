// The sidebar: the five pages in one list, with the Convert queue's games and the ports nested under their pages, each row with its status in a
// fixed slot; the badges of what waits (queued games, incoming commits, failed checks); the rows' context menus and the Delete key. A row keeps one shape
// for its identity: a page that gains or loses its nested rows is a new row (the outline view draws a leaf turned group, or a group turned leaf, over its
// neighbours), and a port keeps its row from the agent preparing it to its record
import ConverterCore
import SwiftUI

/// What the sidebar selects: a page, or a game or a port on its page. It maps onto the model's page and its selected job and port
private enum SidebarItem: Hashable {
    case page(Page), job(UUID), port(String)
}

/// A page's row, and whether it is a group with rows nested under it
private struct PageRow: Hashable {
    let page: Page
    let grouped: Bool
}

/// A port's row: its record, the agent run on it, or both (an agent preparing a new port has no record yet)
private struct PortSidebarEntry: Identifiable {
    let port: PortRecord?
    let run: PortRun?
    var id: String { port?.titleID ?? run?.titleID ?? "" }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebar.convertExpanded") private var convertExpanded = true
    @SceneStorage("sidebar.portsExpanded") private var portsExpanded = true

    var body: some View {
        List(selection: Binding(get: { current }, set: select)) {
            ForEach(pageRows, id: \.self) { row($0) }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: delete)
    }

    private var pageRows: [PageRow] {
        Page.allCases.map { page in
            switch page {
            case .convert: PageRow(page: page, grouped: !model.jobs.isEmpty)
            case .ports: PageRow(page: page, grouped: !portEntries.isEmpty)
            default: PageRow(page: page, grouped: false)
            }
        }
    }

    @ViewBuilder private func row(_ row: PageRow) -> some View {
        let page = row.page
        switch page {
        case .convert where row.grouped:
            DisclosureGroup(isExpanded: $convertExpanded) {
                ForEach(model.jobs) { job in
                    JobSidebarRow(job: job)
                        .tag(SidebarItem.job(job.id))
                        .contextMenu { JobActionMenuItems(JobAction.contextMenu, job: job) }
                }
            } label: {
                pageLabel(page)
            }
        case .ports where row.grouped:
            DisclosureGroup(isExpanded: $portsExpanded) {
                ForEach(portEntries) { entry in
                    PortSidebarRow(entry: entry)
                        .tag(SidebarItem.port(entry.id))
                        .contextMenu { if let port = entry.port { PortActionMenuItems(port: port) } }
                }
            } label: {
                pageLabel(page)
            }
        default:
            pageLabel(page)
        }
    }

    private func pageLabel(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol)
            .badge(badge(for: page))
            .badgeProminence(page == .setup ? .increased : .standard)
            .tag(SidebarItem.page(page))
    }

    private func badge(for page: Page) -> Int {
        switch page {
        case .convert: model.queuedCount
        case .repository: model.incomingCount
        case .setup: model.failedRequiredChecks
        case .library, .ports: 0
        }
    }

    /// The ports, newest first: the agents preparing ports that have no record yet, then the records (a new record is the newest, so its row stays put)
    private var portEntries: [PortSidebarEntry] {
        let preparing = model.activePortRuns.reversed().filter { model.port($0.titleID) == nil }.map { PortSidebarEntry(port: nil, run: $0) }
        return preparing + model.ports.reversed().map { PortSidebarEntry(port: $0, run: model.activeRun($0.titleID)) }
    }

    // A collapsed group shows its page as selected, as in Finder and Xcode
    private var current: SidebarItem? {
        switch model.shownPage {
        case .convert:
            if convertExpanded, let job = model.shownJob { return .job(job.id) }
            return .page(.convert)
        case .ports:
            if portsExpanded, let id = model.shownPortID { return .port(id) }
            return .page(.ports)
        case let page:
            return .page(page)
        }
    }

    private func select(_ item: SidebarItem?) {
        switch item {
        case nil: break   // the page stays: a list deselects with a ⌘-click
        case .page(.convert)?:
            model.page = .convert
            model.selectedJobID = model.shownJob?.id
        case .page(.ports)?:
            model.page = .ports
            model.selectedPortID = model.shownPortID
        case let .page(page)?:
            model.page = page
        case let .job(id)?:
            model.page = .convert
            model.selectedJobID = id
        case let .port(id)?:
            model.page = .ports
            if id != model.selectedPortID { model.selectedRunID = nil }
            model.selectedPortID = id
        }
    }

    private func delete() {
        switch current {
        case let .job(id)?:
            if let job = model.jobs.first(where: { $0.id == id }), !job.state.isActive { model.remove(job) }
        case let .port(id)?:
            if let port = model.port(id), model.canOperateOnPort(port) { model.portToRemove = port }
        default:
            break
        }
    }
}

private struct JobSidebarRow: View {
    let job: ConversionJob

    var body: some View {
        HStack(spacing: Space.xs) {
            Label {
                RowLines(title: job.name, detail: job.statusText)
            } icon: {
                GameArtwork(job.artwork, name: job.name, size: 24, shape: job.isMacApp ? .app : .game)
                    .saturation(job.isUnplugged ? 0.35 : 1)
                    .brightness(job.isUnplugged ? -0.05 : 0)
            }
            Spacer(minLength: 0)
            RowAccessory { JobAccessory(job: job) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(job.name)
        .accessibilityValue(job.statusText)
    }
}

private struct JobAccessory: View {
    let job: ConversionJob
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        if job.cannotConvert {
            symbol("xmark.circle.fill", .red, "Cannot convert")
        } else {
            switch job.state {
            case .queued: symbol("clock", .secondary, "Waiting")
            case .preparing, .installing: ProgressView().controlSize(.small).accessibilityLabel("Running")
            case .running:
                ProgressView(value: job.progressFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .opacity(appearsActive ? 1 : 0.5)
                    .saturation(appearsActive ? 1 : 0)
                    .accessibilityLabel("Running")
            case .succeeded where job.options.surveyOnly: symbol("doc.text.magnifyingglass", .secondary, "Survey written")
            case .succeeded: symbol("checkmark.circle.fill", .green, "Succeeded")
            case .failed: symbol("xmark.octagon.fill", .red, "Failed")
            case .cancelled: symbol("stop.circle", .secondary, "Cancelled")
            }
        }
    }

    private func symbol(_ name: String, _ color: Color, _ label: String) -> some View {
        StatusSymbol(name: name, color: color, label: label)
    }
}

private struct PortSidebarRow: View {
    let entry: PortSidebarEntry

    var body: some View {
        HStack(spacing: Space.xs) {
            Label {
                RowLines(title: name, detail: detail)
            } icon: {
                GameArtwork(.gameFolder(entry.port?.folderURL ?? entry.run?.folder ?? URL(fileURLWithPath: "/"), titleID: entry.id), name: name, size: 24)
            }
            Spacer(minLength: 0)
            RowAccessory {
                if entry.run != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Agent running")
                } else if let run = entry.port?.runs.last {
                    StatusSymbol(name: run.status.symbol, color: run.status.tone.glyph, label: run.status.title)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(spokenValue)
    }

    private var name: String { entry.port?.gameName ?? entry.run?.gameName ?? entry.id }

    private var spokenValue: String {
        if entry.run != nil { return "Agent running, " + detail }
        guard let run = entry.port?.runs.last else { return detail }
        return run.status.title + ", " + detail
    }

    private var detail: String {
        if let run = entry.run { return run.phase }
        let parts = [entry.port?.runs.last?.kind.displayName, entry.port?.latestReport?.milestone.title].compactMap { $0 }
        return parts.isEmpty ? entry.id : parts.joined(separator: " · ")
    }
}

private struct RowLines: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The 16-point trailing slot of a row, so every state lines up
private struct RowAccessory<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.frame(width: 16, height: 16)
    }
}

/// A state symbol in a row; it dims with an inactive window (the system's spinners and badges dim by themselves)
private struct StatusSymbol: View {
    let name: String
    let color: Color
    let label: String
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .opacity(appearsActive ? 1 : 0.5)
            .saturation(appearsActive ? 1 : 0)
            .accessibilityLabel(label)
    }
}
