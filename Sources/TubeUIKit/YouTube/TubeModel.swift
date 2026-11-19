import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class TubeModel {
    var clientID: String
    var clientSecret: String
    public var isSignedIn: Bool { tokens != nil }
    var tokens: StoredAuth?
    var accounts: [SavedAccount] = []
    var pendingRemoval: String?
    var library = LibrarySnapshot()
    var isAuthorizing = false
    public var isLoading = false
    var authError: String?
    var libraryError: String?
    var credentialError: String?
    public var confirmSignOut = false
    var section: LibrarySection = .home
    var query = ""
    var accessibilityTick = 0
    var watching: YTVideo?
    var watchingShort = false
    var watchPage: WatchPage?
    var descriptionExpanded = false
    var channelBrowse: ChannelBrowse?
    var comments: [YTComment] = []
    var commentsNote: String?
    var commentsNeedAccess = false
    var commentsLoading = false
    var commentsLoadingMore = false
    var commentContinuation: String?
    var commentsOpen = false
    var commentDraft = ""
    var commentPosting = false
    var likeCount: String?
    var commentCount: String?
    var myRating = "none"
    var actionError: String?
    var playerError: String?
    var homeChipID = HomeChip.all.id
    var homeLoading = false
    private var homeGeneration = 0
    var savedVideoIDs: Set<String> = []
    var joinedChannelIDs: Set<String> = []
    var leftChannelIDs: Set<String> = []
    var subscriptionIDs: [String: String] = [:]
    var subscriptionBusy = false
    var playerFullscreen = false
    var playerPlaying = false
    var playerTime = 0.0
    var playerDuration = 0.0
    var playerScrubbing = false
    var playerVolume = 100.0
    var playerMuted = false
    var playerCommand = 0
    var playerAction = ""
    var playerActionValue = 0.0
    var shortsQueue: [YTVideo] = []
    var shortsIndex = 0

    // Search
    var searchResults: SearchPage?
    var isSearching = false
    var searchError: String?

    // Comments
    var commentOrder: CommentOrder = .top
    var replyTokens: [String: String] = [:]
    private var topOrderedComments: [YTComment] = []
    private var commentSortTokens: [String: String] = [:]

    // Notifications
    var notifications: [YTNotification] = []
    var notificationsLoading = false
    var notificationsError: String?
    private var notificationsLoaded = false

    // Player quality cap: 0 = auto, else 360/480/720/1080.
    var playerQuality: Int {
        didSet { UserDefaults.standard.set(playerQuality, forKey: Self.qualityKey) }
    }
    /// Height of the rendition actually playing, reported by the player host.
    var playingHeight = 0

    var feedsLoading: Set<LibrarySection> = []

    static let searchHistoryKey = "tubeui.searchHistory"
    static let qualityKey = "tubeui.quality"

    private var authTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var engagementTask: Task<Void, Never>?
    private var advancedFrom: String?
    private var didPlayCurrent = false
    private var didRestore = false
    private var accessibilityObserver: NSObjectProtocol?

    public static let shared = TubeModel()

    static let clientIDKey = "tubeui.clientID"
    static let activeAccountKey = "tubeui.activeAccount"
    static let secretAccount = "client-secret"
    static let tokenAccount = "tokens"
    static let accountsAccount = "accounts"

    var hasClient: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        playerQuality = UserDefaults.standard.integer(forKey: Self.qualityKey)
        if BundledOAuthClient.isConfigured {
            clientID = BundledOAuthClient.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            clientSecret = BundledOAuthClient.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
            if let data = KeychainStore.get(account: Self.secretAccount) {
                clientSecret = String(data: data, encoding: .utf8) ?? ""
            } else {
                clientSecret = ""
            }
        }
        accounts = Self.loadAccounts()
        if let activeID = UserDefaults.standard.string(forKey: Self.activeAccountKey),
           let active = accounts.first(where: { $0.id == activeID }) {
            tokens = active.auth
        } else if accounts.count == 1, KeychainStore.get(account: Self.tokenAccount) != nil {
            tokens = accounts[0].auth
            UserDefaults.standard.set(accounts[0].id, forKey: Self.activeAccountKey)
        }
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TubeModel.shared.accessibilityTick &+= 1
            }
        }
    }

    func persistCredentials() {
        guard !BundledOAuthClient.isConfigured else { return }
        clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: Self.clientIDKey)
        do {
            if clientSecret.isEmpty {
                KeychainStore.delete(account: Self.secretAccount)
            } else {
                try KeychainStore.set(Data(clientSecret.utf8), account: Self.secretAccount)
            }
            credentialError = nil
        } catch {
            credentialError = "Couldn't save the client secret in the Keychain."
        }
    }

    private static func loadAccounts() -> [SavedAccount] {
        if let saved = KeychainStore.get([SavedAccount].self, account: accountsAccount) {
            return saved
        }
        if let legacy = KeychainStore.get(StoredAuth.self, account: tokenAccount) {
            return [SavedAccount(id: "legacy", title: "YouTube account", handle: nil, avatarURL: nil, auth: legacy)]
        }
        return []
    }

    private func persistAccounts() {
        do {
            try KeychainStore.set(JSONEncoder().encode(accounts), account: Self.accountsAccount)
            KeychainStore.delete(account: Self.tokenAccount)
        } catch {
            authError = "TubeUI couldn't keep this account in the Keychain."
        }
    }

    private func store(_ auth: StoredAuth) {
        tokens = auth
        if let index = accounts.firstIndex(where: { $0.auth.refreshToken == auth.refreshToken }) {
            accounts[index].auth = auth
        }
        persistAccounts()
    }

    func select(_ account: SavedAccount) {
        authError = nil
        tokens = account.auth
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        Task { await reload() }
    }

    func remove(_ account: SavedAccount) {
        let wasActive = tokens?.refreshToken == account.auth.refreshToken
        accounts.removeAll { $0.id == account.id }
        pendingRemoval = nil
        persistAccounts()
        if wasActive {
            signOut()
        }
    }

    private func remember(_ channel: YTChannel, auth: StoredAuth) {
        let saved = SavedAccount(
            id: channel.id,
            title: channel.title,
            handle: channel.handle,
            avatarURL: channel.avatarURL?.absoluteString,
            auth: auth
        )
        accounts.removeAll { $0.id == channel.id || $0.id == "legacy" || $0.auth.refreshToken == auth.refreshToken }
        accounts.append(saved)
        accounts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        UserDefaults.standard.set(channel.id, forKey: Self.activeAccountKey)
        persistAccounts()
    }

    func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true
        guard tokens != nil else { return }
        await reload()
    }

    func signIn() {
        persistCredentials()
        authError = nil
        guard hasClient else {
            authError = "This build has no Google client yet. Add the Desktop client in BundledOAuthClient.swift and rebuild. People who install that build sign in without this step."
            return
        }
        isAuthorizing = true
        authTask?.cancel()
        let clientID = clientID
        let clientSecret = clientSecret
        authTask = Task {
            do {
                let auth = try await OAuthFlow.signIn(clientID: clientID, clientSecret: clientSecret)
                try Task.checkCancellation()
                let pendingID = "pending-\(auth.refreshToken.prefix(12))"
                accounts.removeAll { $0.auth.refreshToken == auth.refreshToken }
                accounts.append(SavedAccount(id: pendingID, title: "YouTube account", handle: nil, avatarURL: nil, auth: auth))
                tokens = auth
                UserDefaults.standard.set(pendingID, forKey: Self.activeAccountKey)
                persistAccounts()
                isAuthorizing = false
                NSApp.requestUserAttention(.informationalRequest)
                engagementTask?.cancel()
                engagementTask = nil
                await reload()
                if let id = watching?.id {
                    engagementTask = Task { await loadEngagement(id) }
                }
            } catch is CancellationError {
                isAuthorizing = false
            } catch {
                isAuthorizing = false
                authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        authTask?.cancel()
        isAuthorizing = false
    }

    func open(_ video: YTVideo, short: Bool = false, keepQueue: Bool = false) {
        guard YTVideo.isVideoID(video.id) else { return }
        let asShort = short || video.isShort
        if asShort, !keepQueue {
            shortsQueue = shortQueue(around: video)
            shortsIndex = shortsQueue.firstIndex(where: { $0.id == video.id }) ?? 0
        }
        watchingShort = asShort
        watching = video
        watchPage = nil
        descriptionExpanded = false
        comments = []
        commentsNote = nil
        commentsNeedAccess = false
        commentContinuation = nil
        commentsLoadingMore = false
        commentDraft = ""
        replyTokens = [:]
        topOrderedComments = []
        commentSortTokens = [:]
        likeCount = nil
        commentCount = nil
        myRating = "none"
        actionError = nil
        playerError = nil
        commentsLoading = true
        playerTime = 0
        playerDuration = 0
        playerPlaying = false
        advancedFrom = nil
        didPlayCurrent = false
        let id = video.id
        watchTask?.cancel()
        engagementTask?.cancel()
        watchTask = Task { await loadWatch(id) }
        engagementTask = Task { await loadEngagement(id) }
    }

    func closeWatch() {
        watchTask?.cancel()
        watchTask = nil
        engagementTask?.cancel()
        engagementTask = nil
        watching = nil
        watchingShort = false
        watchPage = nil
        descriptionExpanded = false
        comments = []
        commentsOpen = false
        commentsNote = nil
        commentsNeedAccess = false
        commentContinuation = nil
        commentsLoadingMore = false
        replyTokens = [:]
        topOrderedComments = []
        commentSortTokens = [:]
        playerPlaying = false
        playerError = nil
        TubePlayerHost.stopIfNeeded()
    }

    /// One step back: fullscreen, then the video, then the channel or playlist.
    func dismiss() {
        if playerFullscreen {
            setFullscreen(false)
        } else if watching != nil {
            closeWatch()
        } else if channelBrowse != nil {
            closeChannel()
        } else if playlistBrowse != nil {
            closePlaylist()
        }
    }

    /// Leave the player and any channel or playlist page. Sidebar changes use this.
    func leavePlayback() {
        if playerFullscreen { setFullscreen(false) }
        closeWatch()
        closeChannel()
        closePlaylist()
    }

    func stepShort(_ delta: Int) {
        let next = shortsIndex + delta
        guard shortsQueue.indices.contains(next) else { return }
        shortsIndex = next
        open(shortsQueue[next], short: true, keepQueue: true)
    }

    func openChannel(id: String, name: String) {
        guard id.hasPrefix("UC") else { return }
        if playerFullscreen { setFullscreen(false) }
        closeWatch()
        channelBrowse = ChannelBrowse(id: id, title: name, loading: true)
        let channelID = id
        Task { await loadChannel(channelID) }
    }

    func closeChannel() {
        channelBrowse = nil
    }

    // MARK: Playlist browse (opening one playlist, task 5)

    var playlistBrowse: PlaylistBrowse?
    var playlistBrowseLoading = false
    private var playlistBrowseID: String?

    /// Opens an arbitrary playlist's detail page. The Innertube saved-playlist
    /// parser takes any "VL<id>" browse id, so it serves search and library lists alike.
    func openPlaylist(_ playlist: YTPlaylist) {
        leavePlayback()
        let browseID = playlist.id.hasPrefix("VL") ? playlist.id : "VL" + playlist.id
        playlistBrowseID = browseID
        playlistBrowse = PlaylistBrowse(
            videos: [],
            meta: PlaylistMeta(
                title: playlist.title,
                owner: library.channel?.title,
                count: playlist.contentDetails?.itemCount ?? 0,
                updated: nil
            ),
            continuation: nil
        )
        Task { await fetchPlaylistBrowse(continuation: nil) }
    }

    func loadMorePlaylistBrowse() async {
        guard let token = playlistBrowse?.continuation else { return }
        await fetchPlaylistBrowse(continuation: token)
    }

    func closePlaylist() {
        playlistBrowse = nil
        playlistBrowseID = nil
        playlistBrowseLoading = false
    }

    private func fetchPlaylistBrowse(continuation: String?) async {
        guard var auth = tokens, !playlistBrowseLoading else { return }
        let browseID = playlistBrowseID ?? ""
        guard !browseID.isEmpty else { return }
        playlistBrowseLoading = true
        defer { playlistBrowseLoading = false }
        do {
            auth = try await fresh(auth)
            let page = try await Innertube.playlist(
                browseID: browseID,
                accessToken: auth.accessToken,
                continuation: continuation
            )
            guard playlistBrowseID == browseID else { return }
            if var browse = playlistBrowse {
                var seen = Set(browse.videos.map(\.id))
                browse.videos.append(contentsOf: page.videos.filter { seen.insert($0.id).inserted })
                if browse.meta == nil { browse.meta = page.meta }
                if let count = page.meta?.count, count > 0 { browse.meta?.count = count }
                browse.continuation = page.continuation
                browse.note = nil
                playlistBrowse = browse
            }
        } catch {
            guard playlistBrowseID == browseID else { return }
            playlistBrowse?.note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setFullscreen(_ on: Bool) {
        playerFullscreen = on
        guard let window = Self.playerWindow else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on != isFull {
            window.toggleFullScreen(nil)
        }
    }

    private static var playerWindow: NSWindow? {
        let ours = NSApp.windows.filter { $0.isVisible && !$0.isSheet && $0.level == .normal }
        return NSApp.keyWindow ?? NSApp.mainWindow ?? ours.first
    }

    var hasNext: Bool {
        if watchingShort { return shortsQueue.indices.contains(shortsIndex + 1) }
        guard let current = watching else { return false }
        return watchPage?.related.contains { $0.id != current.id && YTVideo.isVideoID($0.id) } ?? false
    }

    var hasPrevious: Bool {
        watchingShort && shortsIndex > 0
    }

    func playNext() {
        if watchingShort {
            stepShort(1)
            return
        }
        guard let current = watching,
              let next = watchPage?.related.first(where: { $0.id != current.id && YTVideo.isVideoID($0.id) })
        else { return }
        open(next, short: next.isShort)
    }

    func playPrevious() {
        guard watchingShort else { return }
        stepShort(-1)
    }

    func togglePlay() {
        playerPlaying.toggle()
        playerDo(playerPlaying ? "play" : "pause")
    }

    func playerDo(_ name: String, _ value: Double = 0) {
        playerAction = name
        playerActionValue = value
        playerCommand &+= 1
    }

    func applyPlayer(current: Double, duration: Double, state: Int) {
        if duration > 0 { playerDuration = duration }
        if !playerScrubbing { playerTime = current }
        if state == 1 {
            playerPlaying = true
            didPlayCurrent = true
        }
        if state == 2 || state == 0 || state == 5 { playerPlaying = false }
        let ended = state == 0 && didPlayCurrent && playerDuration > 1 && current >= playerDuration - 0.75
        if ended, watchingShort, let id = watching?.id, advancedFrom != id {
            advancedFrom = id
            stepShort(1)
        }
    }

    func finishScrub() {
        playerScrubbing = false
        playerDo("seek", playerTime)
    }

    func toggleMute() {
        playerMuted.toggle()
        playerDo(playerMuted ? "mute" : "unmute")
        if !playerMuted { playerDo("volume", playerVolume) }
    }

    func commitVolume() {
        playerMuted = playerVolume == 0
        playerDo(playerMuted ? "mute" : "volume", playerVolume)
    }

    func rate(_ rating: String) async {
        guard let id = watching?.id, var auth = tokens else { return }
        let previous = myRating
        let next = myRating == rating ? "none" : rating
        myRating = next
        do {
            auth = try await fresh(auth)
            try await YouTubeAPI(accessToken: auth.accessToken).setRating(videoID: id, rating: next)
            actionError = nil
        } catch {
            myRating = previous
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func saveWatching() async {
        guard let video = watching, var auth = tokens, !isSaved(video.id) else { return }
        savedVideoIDs.insert(video.id)
        do {
            auth = try await fresh(auth)
            try await Innertube.addToWatchLater(videoID: video.id, accessToken: auth.accessToken)
            if !library.watchLater.contains(where: { $0.id == video.id }) {
                library.watchLater.insert(video, at: 0)
            }
            actionError = nil
        } catch {
            savedVideoIDs.remove(video.id)
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func isSaved(_ id: String) -> Bool {
        savedVideoIDs.contains(id) || library.watchLater.contains { $0.id == id }
    }

    func isSubscribed(_ channelID: String) -> Bool {
        if leftChannelIDs.contains(channelID) { return false }
        if joinedChannelIDs.contains(channelID) { return true }
        return library.subscriptions.contains { $0.channelID == channelID }
    }

    func toggleSubscription(_ channelID: String) async {
        guard var auth = tokens, !subscriptionBusy else { return }
        subscriptionBusy = true
        defer { subscriptionBusy = false }
        let was = isSubscribed(channelID)
        if was {
            leftChannelIDs.insert(channelID)
            joinedChannelIDs.remove(channelID)
        } else {
            joinedChannelIDs.insert(channelID)
            leftChannelIDs.remove(channelID)
        }
        do {
            auth = try await fresh(auth)
            let api = YouTubeAPI(accessToken: auth.accessToken)
            if was {
                let subscriptionID = library.subscriptions.first { $0.channelID == channelID }?.id ?? subscriptionIDs[channelID]
                guard let subscriptionID else {
                    leftChannelIDs.remove(channelID)
                    actionError = "Reload subscriptions, then unsubscribe."
                    return
                }
                try await api.unsubscribe(subscriptionID: subscriptionID)
                // Keep the row visible with the unsubscribed pill; the next reload drops it.
            } else {
                let newID = try await api.subscribe(channelID: channelID)
                if newID != channelID {
                    subscriptionIDs[channelID] = newID
                }
            }
            actionError = nil
        } catch {
            if was {
                leftChannelIDs.remove(channelID)
            } else {
                joinedChannelIDs.remove(channelID)
            }
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func postComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = watching?.id, var auth = tokens, !text.isEmpty, !commentPosting else { return }
        commentPosting = true
        defer { commentPosting = false }
        do {
            auth = try await fresh(auth)
            try await YouTubeAPI(accessToken: auth.accessToken).postComment(videoID: id, text: text)
            commentDraft = ""
            actionError = nil
            engagementTask?.cancel()
            engagementTask = Task { await loadEngagement(id) }
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reloadComments() {
        guard let id = watching?.id else { return }
        engagementTask?.cancel()
        engagementTask = Task { await loadEngagement(id) }
    }

    func loadMoreComments() async {
        guard let token = commentContinuation, let id = watching?.id, !commentsLoadingMore else { return }
        commentsLoadingMore = true
        defer { commentsLoadingMore = false }
        do {
            let page = try await Innertube.moreComments(continuation: token, accessToken: tokens?.accessToken)
            guard watching?.id == id else { return }
            var seen = Set(topOrderedComments.map(\.id))
            for comment in page.comments where seen.insert(comment.id).inserted {
                comments.append(comment)
                topOrderedComments.append(comment)
            }
            replyTokens.merge(page.replyTokens) { _, new in new }
            commentContinuation = page.continuation
        } catch {
            guard watching?.id == id else { return }
            commentsNote = Self.commentNote(for: error)
        }
    }

    // MARK: Search

    func submitSearch(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        isSearching = true
        searchError = nil
        // Empty page is the loading state; the UI reads isSearching alongside it.
        searchResults = SearchPage()
        defer { isSearching = false }
        do {
            let page = try await Innertube.search(query: query, accessToken: tokens?.accessToken)
            searchResults = page
            recordSearchHistory(query)
        } catch {
            searchResults = nil
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearSearch() {
        searchResults = nil
        searchError = nil
        isSearching = false
    }

    func loadMoreSearchResults() async {
        guard !isSearching, let token = searchResults?.continuation, var merged = searchResults else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await Innertube.searchMore(continuation: token, accessToken: tokens?.accessToken)
            var videoSeen = Set(merged.videos.map(\.id))
            merged.videos += page.videos.filter { videoSeen.insert($0.id).inserted }
            var channelSeen = Set(merged.channels.map(\.id))
            merged.channels += page.channels.filter { channelSeen.insert($0.id).inserted }
            var playlistSeen = Set(merged.playlists.map(\.id))
            merged.playlists += page.playlists.filter { playlistSeen.insert($0.id).inserted }
            merged.continuation = page.continuation
            searchResults = merged
        } catch {
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// History rows first, then popular completions, deduped and capped.
    func suggest(for prefix: String) async -> [SearchSuggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [SearchSuggestion] = []
        var seen = Set<String>()
        for query in searchHistory where trimmed.isEmpty || query.localizedCaseInsensitiveContains(trimmed) {
            if seen.insert(query.lowercased()).inserted {
                out.append(SearchSuggestion(text: query, isHistory: true))
            }
        }
        if !trimmed.isEmpty {
            for text in await Innertube.suggestions(for: trimmed) {
                guard seen.insert(text.lowercased()).inserted else { continue }
                out.append(SearchSuggestion(text: text, isPopular: true))
            }
        }
        return Array(out.prefix(12))
    }

    var searchHistory: [String] {
        UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
    }

    private func recordSearchHistory(_ query: String) {
        var history = searchHistory
        history.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        history.insert(query, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
    }

    // MARK: Comment replies and order

    func loadReplies(for commentID: String) async {
        guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return }
        guard comments[index].replies.count < comments[index].replyCount else { return }
        guard let token = replyTokens[commentID] else { return }
        let videoID = watching?.id
        do {
            let replies = try await Innertube.commentReplies(continuation: token, accessToken: tokens?.accessToken)
            guard watching?.id == videoID,
                  let index = comments.firstIndex(where: { $0.id == commentID })
            else { return }
            var merged = comments[index].replies
            var seen = Set(merged.map(\.id))
            for reply in replies where seen.insert(reply.id).inserted { merged.append(reply) }
            comments[index].replies = merged
            actionError = nil
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setCommentOrder(_ order: CommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        let videoID = watching?.id
        // YouTube's own sort tokens from the panel menu, when the site sent them.
        if let token = commentSortTokens.first(where: {
            $0.key.compare(order.rawValue, options: .caseInsensitive) == .orderedSame
        })?.value {
            do {
                let page = try await Innertube.moreComments(continuation: token, accessToken: tokens?.accessToken)
                guard watching?.id == videoID else { return }
                comments = page.comments
                topOrderedComments = page.comments
                commentContinuation = page.continuation
                replyTokens.merge(page.replyTokens) { _, new in new }
                actionError = nil
                return
            } catch {
                // Fall through to the client-side sort.
            }
        }
        if order == .top {
            comments = topOrderedComments
        } else {
            comments = topOrderedComments.sorted {
                commentRecencyRank($0.published) < commentRecencyRank($1.published)
            }
        }
    }

    // MARK: Notifications

    func loadNotifications() async {
        guard tokens != nil, !notificationsLoading else { return }
        guard var auth = tokens else { return }
        notificationsLoading = true
        defer { notificationsLoading = false }
        do {
            auth = try await fresh(auth)
            let items = try await Innertube.notifications(accessToken: auth.accessToken)
            notifications = items
            notificationsLoaded = true
            notificationsError = nil
        } catch {
            notificationsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Topic feeds and pagination

    func ensureFeed(_ section: LibrarySection) async {
        guard var auth = tokens else { return }
        if let existing = library.feeds[section], !existing.isEmpty { return }
        guard !feedsLoading.contains(section) else { return }
        feedsLoading.insert(section)
        defer { feedsLoading.remove(section) }
        do {
            auth = try await fresh(auth)
            let videos: [YTVideo]
            switch section {
            case .trending:
                // YouTube retired FEtrending ("Request contains an invalid argument").
                videos = try await feedWithFallback(browseID: "FEtrending", searchQuery: "trending", accessToken: auth.accessToken)
            case .music:
                videos = try await feedWithFallback(browseID: "FEmusic_home", searchQuery: "music", accessToken: auth.accessToken)
            case .gaming:
                // FEGaming precondition-fails on the TV client; search carries the page.
                videos = try await feedWithFallback(browseID: "FEGaming", searchQuery: "gaming", accessToken: auth.accessToken)
            case .live:
                videos = try await feedWithFallback(browseID: "FElive", searchQuery: "live now", accessToken: auth.accessToken)
            case .movies:
                videos = try await feedWithFallback(browseID: "FEmovies", searchQuery: "movies", accessToken: auth.accessToken)
            case .podcasts:
                videos = try await feedWithFallback(browseID: "FEpodcasts_destination", searchQuery: "podcasts", accessToken: auth.accessToken)
            case .yourVideos:
                guard let channelID = library.channel?.id,
                      let playlist = YouTubeAPI.uploadsPlaylistID(channelID: channelID)
                else { return }
                videos = try await YouTubeAPI(accessToken: auth.accessToken).videos(playlistID: playlist, limit: 48).items
            default:
                return
            }
            // Only the first successful load wins; a parallel caller may have filled it.
            if library.feeds[section]?.isEmpty ?? true {
                library.feeds[section] = videos
            }
            library.notes[section] = nil
        } catch {
            library.notes[section] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Browse a feed, falling back to search when the browse throws or comes
    /// back empty. Dead ids such as FEtrending throw instead of returning [].
    private func feedWithFallback(
        browseID: String,
        searchQuery: String,
        accessToken: String
    ) async throws -> [YTVideo] {
        do {
            let browse = try await Innertube.browse(id: browseID, accessToken: accessToken)
            if !browse.isEmpty { return browse }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The browse feed is dead or preconditioned out; the search below carries the page.
        }
        return try await Innertube.searchVideos(query: searchQuery, accessToken: accessToken)
    }

    /// Load-more for the paginated sections: home feed, history, watch later, liked.
    func loadMore(_ section: LibrarySection) async {
        switch section {
        case .home: await loadMoreHome()
        case .history: await loadMoreHistory()
        case .watchLater, .liked: await loadMoreSaved(section)
        default: break
        }
    }

    private func loadMoreHome() async {
        guard !homeLoading, let token = library.homeContinuation, var auth = tokens else { return }
        do {
            auth = try await fresh(auth)
            let page = try await Innertube.home(accessToken: auth.accessToken, continuation: token, deep: false)
            var current = HomeFeed(blocks: library.homeBlocks, continuation: token, structured: true)
            current = current.appendingContinuation(page)
            library.homeBlocks = current.blocks
            library.homeFeed = current.videos
            library.homeContinuation = current.continuation
        } catch {
            library.homeContinuation = nil
        }
    }

    private func loadMoreHistory() async {
        guard var auth = tokens, let token = library.continuations[.history] else { return }
        do {
            auth = try await fresh(auth)
            let page = try await Innertube.history(accessToken: auth.accessToken, continuation: token)
            var seen = Set(library.history.map(\.id))
            for day in page.days {
                let freshVideos = day.videos.filter { seen.insert($0.id).inserted }
                guard !freshVideos.isEmpty else { continue }
                if let index = library.historyDays.firstIndex(where: { $0.label == day.label }) {
                    library.historyDays[index].videos.append(contentsOf: freshVideos)
                } else {
                    library.historyDays.append(HistoryDay(id: day.id, label: day.label, videos: freshVideos))
                }
                library.history.append(contentsOf: freshVideos)
            }
            library.continuations[.history] = page.continuation
        } catch {
            library.continuations[.history] = nil
        }
    }

    private func loadMoreSaved(_ section: LibrarySection) async {
        guard var auth = tokens, let token = library.continuations[section] else { return }
        do {
            auth = try await fresh(auth)
            let page = try await Innertube.playlist(browseID: "VLWL", accessToken: auth.accessToken, continuation: token)
            let existing = section == .watchLater ? library.watchLater : library.liked
            var seen = Set(existing.map(\.id))
            let freshVideos = page.videos.filter { seen.insert($0.id).inserted }
            if section == .watchLater {
                library.watchLater += freshVideos
            } else {
                library.liked += freshVideos
            }
            if existing.count + freshVideos.count >= 200 {
                library.continuations[section] = nil
                library.capped.insert(section)
            } else {
                library.continuations[section] = page.continuation
            }
        } catch {
            library.continuations[section] = nil
        }
    }

    func watchURL(for video: YTVideo, short: Bool) -> URL? {
        let path = short ? "shorts/\(video.id)" : "watch?v=\(video.id)"
        return URL(string: "https://www.youtube.com/\(path)")
    }

    func selectHomeChip(_ chip: HomeChip) {
        guard chip.id != homeChipID || homeLoading else { return }
        let previousBlocks = library.homeBlocks
        let previousChips = library.homeChips
        let previousFeed = library.homeFeed
        let previousContinuation = library.homeContinuation
        let previousID = homeChipID
        homeChipID = chip.id
        homeGeneration &+= 1
        let generation = homeGeneration
        homeLoading = true
        Task {
            await loadHomeChip(
                chip,
                generation: generation,
                previousID: previousID,
                previousBlocks: previousBlocks,
                previousChips: previousChips,
                previousFeed: previousFeed,
                previousContinuation: previousContinuation
            )
        }
    }

    private func loadHomeChip(
        _ chip: HomeChip,
        generation: Int,
        previousID: String,
        previousBlocks: [HomeBlock],
        previousChips: [HomeChip],
        previousFeed: [YTVideo],
        previousContinuation: String?
    ) async {
        defer {
            if generation == homeGeneration { homeLoading = false }
        }
        guard var auth = tokens else { return }
        do {
            if auth.expiry <= Date() {
                auth = try await YouTubeOAuth.refresh(auth, clientSecret: clientSecret)
                store(auth)
            }
            let feed: HomeFeed
            if let query = chip.query, !query.isEmpty {
                let videos = try await Innertube.searchVideos(query: query, accessToken: auth.accessToken)
                feed = HomeFeed(chips: previousChips, blocks: videos.isEmpty ? [] : [.videos(videos)], structured: true)
            } else if let continuation = chip.continuation {
                feed = try await Innertube.home(accessToken: auth.accessToken, continuation: continuation, deep: false)
            } else {
                feed = try await Innertube.home(
                    accessToken: auth.accessToken,
                    browseID: chip.browseID ?? "FEwhat_to_watch",
                    params: chip.params,
                    deep: chip.id == HomeChip.all.id
                )
            }
            guard generation == homeGeneration else { return }
            let placed = chip.query == nil ? LibraryLoader.placedHome(feed, shorts: library.shorts, history: searchHistory) : feed
            library.homeBlocks = placed.blocks
            library.homeFeed = placed.videos
            library.homeContinuation = placed.continuation
            if !placed.chips.isEmpty {
                library.homeChips = placed.chips.map { item in
                    var item = item
                    item.selected = item.id == chip.id
                    return item
                }
            } else {
                library.homeChips = previousChips.map { item in
                    var item = item
                    item.selected = item.id == chip.id
                    return item
                }
            }
            if placed.videos.isEmpty {
                library.homeFeedNote = placed.note ?? "Nothing in \(chip.title) right now."
            } else {
                library.homeFeedNote = nil
            }
        } catch {
            guard generation == homeGeneration else { return }
            homeChipID = previousID
            library.homeBlocks = previousBlocks
            library.homeChips = previousChips
            library.homeFeed = previousFeed
            library.homeContinuation = previousContinuation
            library.homeFeedNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func shortQueue(around video: YTVideo) -> [YTVideo] {
        var seen = Set<String>()
        var pool: [YTVideo] = []
        if let shelf = library.homeBlocks.first(where: { block in
            guard case .shorts(let items) = block else { return false }
            return items.contains { $0.id == video.id }
        }) {
            pool.append(contentsOf: shelf.items)
        }
        for block in library.homeBlocks where block.isShorts {
            pool.append(contentsOf: block.items)
        }
        pool.append(contentsOf: library.shorts)
        pool.append(contentsOf: library.homeFeed.filter(\.isShort))
        var rows = pool.filter { YTVideo.isVideoID($0.id) && seen.insert($0.id).inserted }
        if !rows.contains(where: { $0.id == video.id }) {
            rows.insert(video, at: 0)
        }
        return rows
    }

    private func fresh(_ auth: StoredAuth) async throws -> StoredAuth {
        guard auth.expiry <= Date() else { return auth }
        let renewed = try await YouTubeOAuth.refresh(auth, clientSecret: clientSecret)
        store(renewed)
        return renewed
    }

    private func loadChannel(_ id: String) async {
        guard var auth = tokens else { return }
        do {
            auth = try await fresh(auth)
            let api = YouTubeAPI(accessToken: auth.accessToken)
            let channel = try await api.channel(id: id)
            var videos: [YTVideo] = []
            if let playlist = YouTubeAPI.uploadsPlaylistID(channelID: id) {
                videos = try await api.videos(playlistID: playlist, limit: 24).items
            }
            guard channelBrowse?.id == id else { return }
            channelBrowse?.channel = channel
            channelBrowse?.videos = videos
            channelBrowse?.title = channel?.title ?? channelBrowse?.title ?? "Channel"
            channelBrowse?.loading = false
            channelBrowse?.note = videos.isEmpty ? "No public videos on this channel." : nil
        } catch {
            guard channelBrowse?.id == id else { return }
            channelBrowse?.loading = false
            channelBrowse?.note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadEngagement(_ id: String) async {
        guard var auth = tokens else { return }
        commentsLoading = true
        defer { commentsLoading = false }
        do {
            auth = try await fresh(auth)
            try Task.checkCancellation()
            let api = YouTubeAPI(accessToken: auth.accessToken)
            let accessToken = auth.accessToken
            async let statsTask = capture { try await api.engagement(for: id) }
            async let ratingTask = capture { try await api.rating(for: id) }
            async let commentsTask = capture { try await Innertube.comments(videoID: id, accessToken: accessToken) }
            let statsResult = await statsTask
            let ratingResult = await ratingTask
            let commentsResult = await commentsTask
            try Task.checkCancellation()
            guard watching?.id == id else { return }
            if case .success(let stats) = statsResult {
                likeCount = TubeFormat.count(stats.likes) ?? stats.likes
                commentCount = TubeFormat.count(stats.comments) ?? stats.comments
            }
            if case .success(let rating) = ratingResult {
                myRating = rating
            }
            switch commentsResult {
            case .success(let listing):
                comments = listing.comments
                commentContinuation = listing.continuation
                replyTokens = listing.replyTokens
                topOrderedComments = listing.comments
                commentSortTokens = listing.sortTokens
                commentsNeedAccess = false
                if commentCount == nil, let count = listing.count, !count.isEmpty {
                    commentCount = count
                }
                if listing.disabled {
                    commentsNote = "Comments are turned off for this video."
                } else {
                    commentsNote = listing.comments.isEmpty ? "No comments yet." : nil
                }
            case .failure(let error):
                comments = []
                commentContinuation = nil
                replyTokens = [:]
                topOrderedComments = []
                commentSortTokens = [:]
                commentsNeedAccess = false
                commentsNote = Self.commentNote(for: error)
            }
        } catch is CancellationError {
            return
        } catch {
            guard watching?.id == id else { return }
            comments = []
            commentContinuation = nil
            commentsNeedAccess = false
            commentsNote = Self.commentNote(for: error)
        }
    }

    private static func commentNote(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("disabled") || lower.contains("commentsdisabled") || (lower.contains("forbidden") && lower.contains("comment")) {
            return "Comments are turned off for this video."
        }
        return text
    }

    /// Player metadata and the related column. Playback starts on its own; this fills in around it.
    private func loadWatch(_ id: String) async {
        guard var auth = tokens else { return }
        do {
            if auth.expiry <= Date() {
                auth = try await YouTubeOAuth.refresh(auth, clientSecret: clientSecret)
                try Task.checkCancellation()
                store(auth)
            }
            let page = try await Innertube.watch(videoID: id, accessToken: auth.accessToken)
            try Task.checkCancellation()
            guard watching?.id == id else { return }
            watchPage = page
            guard var current = watching else { return }
            let richer = page.video
            if !richer.title.isEmpty { current.title = richer.title }
            if !richer.channel.isEmpty { current.channel = richer.channel }
            if richer.views != nil { current.views = richer.views }
            if richer.published != nil { current.published = richer.published }
            if richer.channelAvatar != nil { current.channelAvatar = richer.channelAvatar }
            if current.channelID == nil { current.channelID = richer.channelID }
            if current.thumbnail == nil { current.thumbnail = richer.thumbnail }
            if current.length == nil { current.length = richer.length }
            watching = current
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    func openInBrowser(_ video: YTVideo, short: Bool) {
        guard YTVideo.isVideoID(video.id) else { return }
        let path = short ? "shorts/\(video.id)" : "watch?v=\(video.id)"
        guard let url = URL(string: "https://www.youtube.com/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    public func reload() async {
        guard var auth = tokens else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if auth.expiry <= Date() {
                auth = try await YouTubeOAuth.refresh(auth, clientSecret: clientSecret)
                store(auth)
            }
            let snapshot = try await LibraryLoader.load(YouTubeAPI(accessToken: auth.accessToken))
            homeGeneration &+= 1
            homeChipID = snapshot.homeChips.first(where: \.selected)?.id ?? HomeChip.all.id
            homeLoading = false
            library = snapshot
            libraryError = nil
            if let channel = snapshot.channel {
                remember(channel, auth: auth)
            }
        } catch is CancellationError {
            return
        } catch {
            if YouTubeError.isUnauthorized(error) || error is OAuthError {
                let message = (error as? LocalizedError)?.errorDescription ?? "Sign-in expired. Sign in again."
                signOut()
                authError = message
                return
            }
            libraryError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut() {
        authTask?.cancel()
        authTask = nil
        if playerFullscreen { setFullscreen(false) }
        closeWatch()
        closeChannel()
        joinedChannelIDs = []
        leftChannelIDs = []
        savedVideoIDs = []
        subscriptionIDs = [:]
        commentDraft = ""
        actionError = nil
        playerError = nil
        homeChipID = HomeChip.all.id
        homeLoading = false
        homeGeneration &+= 1
        searchResults = nil
        isSearching = false
        searchError = nil
        playlistBrowse = nil
        playlistBrowseID = nil
        playlistBrowseLoading = false
        commentOrder = .top
        replyTokens = [:]
        topOrderedComments = []
        commentSortTokens = [:]
        notifications = []
        notificationsLoading = false
        notificationsError = nil
        notificationsLoaded = false
        feedsLoading = []
        isAuthorizing = false
        isLoading = false
        tokens = nil
        library = LibrarySnapshot()
        authError = nil
        libraryError = nil
        confirmSignOut = false
        section = .home
        query = ""
        UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
    }
}

private func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}
