import SwiftUI

struct LibraryShell: View {
    private static let homeInset: CGFloat = 24
    private var model: TubeModel { TubeModel.shared }
    private var section: LibrarySection { model.section }
    private var query: String { model.query }
    @State private var showAccountSwitcher = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 280)
        } detail: {
            detail
                .navigationTitle("")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                TubeSearchField(text: Binding(get: { model.query }, set: { model.query = $0 }))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                NotificationBell()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                TubeIconButton(icon: .refresh, help: "Reload", showsProgress: model.isLoading) {
                    Task { await model.reload() }
                }
                .disabled(model.isLoading)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarVisibility(model.playerFullscreen ? .hidden : .visible, for: .windowToolbar)
        .overlay {
            if model.playerFullscreen, let video = model.watching {
                FullscreenStage(video: video, short: model.watchingShort)
                    .ignoresSafeArea()
            }
        }
        .background {
            EscapeMonitor {
                if model.searchResults != nil {
                    model.clearSearch()
                } else {
                    model.dismiss()
                }
                return true
            }
        }
        .confirmationDialog(
            "Sign out of YouTube?",
            isPresented: Binding(get: { model.confirmSignOut }, set: { model.confirmSignOut = $0 }),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }

    private var signOutMessage: String {
        if let title = model.library.channel?.title {
            return "Signed in as \(title). TubeUI returns to the account chooser. This account stays on this Mac until you remove it there."
        }
        return "TubeUI returns to the account chooser. Accounts stay on this Mac until you remove them there."
    }

    private var accountMenu: some View {
        HStack(spacing: 8) {
            Button {
                showAccountSwitcher = true
            } label: {
                HStack(spacing: 8) {
                    Avatar(
                        url: model.library.channel?.avatarURL,
                        name: model.library.channel?.title ?? "Account",
                        size: 28
                    )
                    Text(model.library.channel?.title ?? "Account")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Switch account")
            .popover(isPresented: $showAccountSwitcher, arrowEdge: .bottom) {
                AccountSwitcherView()
                    .frame(width: 360)
            }
            Menu {
                Button("Reload") { Task { await model.reload() } }
                Divider()
                Button("Sign Out") { model.confirmSignOut = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .accessibilityLabel("Account menu")
        }
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.library.channel?.title ?? "Account")
    }

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                sidebarHeading("Watch")
                ForEach(watchSections) { sidebarButton($0) }
                sidebarHeading("Library")
                    .padding(.top, 14)
                ForEach(LibrarySection.library) { sidebarButton($0) }
                sidebarHeading("Explore", small: true)
                    .padding(.top, 14)
                ForEach(LibrarySection.explore) { sidebarButton($0) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accountMenu
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }

    /// Watch group: Home, Shorts, Trending (Subscriptions lives in the Library group, per YouTube).
    private var watchSections: [LibrarySection] {
        LibrarySection.watch
    }

    private func sidebarHeading(_ title: String, small: Bool = false) -> some View {
        Text(title)
            .font(small ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func sidebarButton(_ item: LibrarySection) -> some View {
        SidebarRow(
            item: item,
            selected: section == item
        ) {
            model.leavePlayback()
            model.clearSearch()
            model.section = item
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let authError = model.authError {
                TubeNotice(message: authError)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
            if let libraryError = model.libraryError {
                HStack(alignment: .center, spacing: 12) {
                    TubeNotice(message: libraryError)
                    Spacer(minLength: 8)
                    Button("Try Again") { Task { await model.reload() } }
                        .buttonStyle(.bordered)
                        .tint(TubeColor.red)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: TubeMetrics.banner, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            Group {
                if let video = model.watching, model.watchingShort {
                    ShortsStage(video: video, hostsPlayer: !model.playerFullscreen)
                } else if let video = model.watching {
                    WatchView(video: video, hostsPlayer: !model.playerFullscreen)
                } else if let browse = model.channelBrowse {
                    ChannelView(browse: browse)
                } else if model.searchResults != nil {
                    SearchResultsPageView()
                } else if model.playlistBrowse != nil {
                    PlaylistDetailView(section: nil)
                } else if waitsForData {
                    ProgressView("Loading your library")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch section {
                    case .home:
                        home
                    case .shorts:
                        shortsPage
                    case .history:
                        HistoryPageView()
                    case .subscriptions:
                        subscriptionList
                    case .playlists:
                        PlaylistsPageView()
                    case .watchLater:
                        PlaylistDetailView(section: .watchLater)
                    case .liked:
                        PlaylistDetailView(section: .liked)
                    case .downloads:
                        DownloadsPageView()
                    default:
                        ExplorePageView(section: section)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var waitsForData: Bool {
        model.isLoading && model.library.isEmpty
    }

    private var homeChips: [HomeChip] {
        let parsed = model.library.homeChips
        return parsed.isEmpty ? HomeChip.fallback : parsed
    }

    private var homeBlocks: [HomeBlock] {
        let source = model.library.homeBlocks
        let blocks = source.isEmpty && !model.library.homeFeed.isEmpty
            ? HomeFeed.synthesized(from: model.library.homeFeed).blocks
            : source
        let ordered = HomeFeed(blocks: blocks).placingShortsAfterLead().blocks
        return ordered.compactMap { block in
            let rows = filtered(block.items)
            guard !rows.isEmpty else { return nil }
            switch block {
            case .videos:
                return .videos(rows)
            case .shorts:
                return .shorts(rows)
            }
        }
    }

    private var home: some View {
        Group {
            if model.homeLoading && homeBlocks.isEmpty {
                ProgressView("Loading \(model.homeChipID)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if homeBlocks.isEmpty {
                homeEmpty
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(homeBlocks.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .videos(let items):
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)],
                                    spacing: 22
                                ) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, video in
                                        HomeCard(video: video)
                                            .hoverLift()
                                            .springIn(delay: tubeStagger(index))
                                    }
                                }
                            case .shorts(let items):
                                shortsShelf(items)
                            }
                        }
                        if model.library.capped.contains(.home) {
                            let regulars = homeBlocks.reduce(0) { count, block in
                                guard case .videos(let items) = block else { return count }
                                return count + items.count
                            }
                            Text("Showing the first \(regulars).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Self.homeInset)
                    .padding(.top, 8)
                    .padding(.bottom, Self.homeInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .top, spacing: 0) {
            homeChipBar
        }
        .refreshable { await model.reload() }
    }

    private var homeChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(homeChips) { chip in
                    let selected = chip.id == model.homeChipID
                    Button {
                        model.selectHomeChip(chip)
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(selected ? TubeColor.chipSelected : TubeColor.chip, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .hoverLift(scale: 1.03, shadow: 0)
                    .focusEffectDisabled()
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if model.homeLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Self.homeInset)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var homeEmpty: some View {
        if model.library.consent.contains(.home) {
            consentPage(.home)
        } else if let note = model.library.homeFeedNote {
            unavailable(section: .home, message: note)
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TubeEmptyState(section: .home, title: LibrarySection.home.emptyCopy, message: LibrarySection.home.subtitle) {
                EmptyView()
            }
        }
    }

    private var subscriptionList: some View {
        collection(filteredSubscriptions, section: .subscriptions) { item in
            HStack(spacing: 8) {
                Button {
                    guard let id = item.channelID else { return }
                    model.openChannel(id: id, name: item.title)
                } label: {
                    HStack(spacing: 8) {
                        ChannelRow(title: item.title, avatar: item.avatarURL)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(item.channelID == nil)
                if let channelID = item.channelID {
                    SubscribeButton(channelID: channelID, compact: true, subscribedTitle: "Unsubscribe")
                }
            }
        }
    }

    private func shortsShelf(_ items: [YTVideo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LibrarySection.shorts.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("See all") { model.section = .shorts }
                    .buttonStyle(.plain)
                    .foregroundStyle(TubeColor.red)
                    .focusEffectDisabled()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.open(item, short: true)
                        } label: {
                            ShortCard(title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail)
                                .frame(width: 148)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .hoverLift(scale: 1.03)
                        .springIn(delay: min(Double(index) * 0.02, 0.2))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortsPage: some View {
        let items = filtered(model.library.shorts)
        return Group {
            if model.library.consent.contains(.shorts), items.isEmpty {
                consentPage(.shorts)
            } else if let note = model.library.notes[.shorts], items.isEmpty {
                unavailable(section: .shorts, message: note)
            } else if items.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                TubeEmptyState(section: .shorts, title: LibrarySection.shorts.emptyCopy, message: LibrarySection.shorts.subtitle) {
                    EmptyView()
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)], spacing: 20) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                model.open(item, short: true)
                            } label: {
                                ShortCard(title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail)
                            }
                            .buttonStyle(.plain)
                            .hoverLift(scale: 1.03)
                            .springIn(delay: tubeStagger(index))
                        }
                    }
                    .padding(24)
                    if model.library.capped.contains(.shorts) {
                        Text("Showing the first \(items.count).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.reload() }
            }
        }
    }

    private func consentCopy(_ section: LibrarySection) -> String {
        switch section {
        case .home:
            "YouTube won't share your home feed until you allow account access."
        case .history:
            "YouTube won't share watch history until you allow account access."
        case .shorts:
            "YouTube won't share Shorts until you allow account access."
        default:
            "YouTube needs permission to share this."
        }
    }

    private func consentPage(_ section: LibrarySection) -> some View {
        TubeEmptyState(section: section, title: section.title, message: consentCopy(section)) {
            Button(model.isAuthorizing ? "Waiting for Google…" : "Allow access") {
                model.signIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(TubeColor.red)
            .disabled(model.isAuthorizing)
        }
    }

    private func unavailable(section: LibrarySection, message: String) -> some View {
        TubeEmptyState(section: section, title: section.title, message: message) {
            Button("Try Again") { Task { await model.reload() } }
                .buttonStyle(.borderedProminent)
                .tint(TubeColor.red)
        }
    }

    private func collection<Item: Identifiable, Row: View>(
        _ items: [Item],
        section: LibrarySection,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        Group {
            if model.library.consent.contains(section), items.isEmpty {
                consentPage(section)
            } else if let note = model.library.notes[section], items.isEmpty {
                unavailable(section: section, message: note)
            } else if items.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                TubeEmptyState(section: section, title: section.emptyCopy, message: section.subtitle) {
                    EmptyView()
                }
            } else {
                List(items) { item in
                    row(item)
                }
                .listStyle(.inset)
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    if model.library.capped.contains(section) {
                        Text("Showing the first \(items.count).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .refreshable { await model.reload() }
    }

    private var filteredSubscriptions: [YTSubscription] {
        model.library.subscriptions.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    private func filtered(_ items: [YTVideo]) -> [YTVideo] {
        items.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.channel.localizedStandardContains(query)
        }
    }
}

/// One sidebar row: selection capsule plus a quiet hover wash.
private struct SidebarRow: View {
    var item: LibrarySection
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                sectionStateIcon(item, size: 16, weight: selected ? .semibold : .regular, scale: 1)
                    .foregroundStyle(selected ? TubeColor.red : Color.secondary)
                Text(item.title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? TubeColor.selection : hovered ? Color.primary.opacity(0.06) : Color.clear)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
