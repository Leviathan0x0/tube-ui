import Foundation

/// One place every avatar/thumbnail string goes through before it becomes a URL.
/// YouTube serves protocol-relative "//yt3.ggpht.com/…" links that URL(string:) rejects,
/// and insecure "http://" links that trip ATS.
enum TubeImage {
    static func url(_ raw: String?) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") {
            raw = "https:" + raw
        } else if raw.hasPrefix("http://") {
            raw = "https://" + raw.dropFirst("http://".count)
        }
        return URL(string: raw)
    }

    /// Sharper files to try before `url`, best first. Browse payloads usually
    /// carry a 168px `hqdefault`, which looks soft once a card is wider than that.
    static func displayCandidates(_ url: URL?) -> [URL] {
        guard let url else { return [] }
        var ordered: [URL] = []
        if let id = videoID(in: url) {
            for name in ["maxresdefault.jpg", "hq720.jpg", "sddefault.jpg"] {
                if let candidate = URL(string: "https://i.ytimg.com/vi/\(id)/\(name)") {
                    ordered.append(candidate)
                }
            }
        }
        if let portrait = enlargedPortrait(url) {
            ordered.append(portrait)
        }
        ordered.append(url)
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.absoluteString).inserted }
    }

    /// `i.ytimg.com/vi/<id>/…` and the webp twin. Anything else is left alone.
    static func videoID(in url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let marker = parts.firstIndex(where: { $0 == "vi" || $0 == "vi_webp" }),
              parts.indices.contains(marker + 1)
        else { return nil }
        let id = parts[marker + 1]
        guard YTVideo.isVideoID(id) else { return nil }
        return id
    }

    /// Channel photos arrive as `=s88-c-…`. Ask for 800px and keep the crop flags.
    private static func enlargedPortrait(_ url: URL) -> URL? {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("ggpht.com") || host.contains("googleusercontent.com") else { return nil }
        let raw = url.absoluteString
        guard let range = raw.range(of: #"=s\d+"#, options: .regularExpression) else { return nil }
        let digits = raw[range].dropFirst(2)
        guard let size = Int(digits), size < 480 else { return nil }
        return URL(string: raw.replacingCharacters(in: range, with: "=s800"))
    }
}

enum LibrarySection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case home
    case shorts
    case subscriptions
    case history
    case playlists
    case watchLater
    case liked
    case trending
    case yourVideos
    case downloads
    case music
    case movies
    case live
    case gaming
    case podcasts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .shorts: "Shorts"
        case .subscriptions: "Subscriptions"
        case .history: "History"
        case .playlists: "Playlists"
        case .watchLater: "Watch later"
        case .liked: "Liked videos"
        case .trending: "Trending"
        case .yourVideos: "Your videos"
        case .downloads: "Downloads"
        case .music: "Music"
        case .movies: "Movies & TV"
        case .live: "Live"
        case .gaming: "Gaming"
        case .podcasts: "Podcasts"
        }
    }

    var subtitle: String {
        switch self {
        case .home: "Recommended videos"
        case .shorts: "Shorts"
        case .subscriptions: "Channels you subscribe to"
        case .history: "Videos you've watched"
        case .playlists: "Playlists on this channel"
        case .watchLater: "Saved to Watch Later"
        case .liked: "Videos you liked"
        case .trending: "What's being watched right now"
        case .yourVideos: "Uploads from your channel"
        case .downloads: "Videos saved for offline"
        case .music: "Music picks for you"
        case .movies: "Films and shows"
        case .live: "Streams happening now"
        case .gaming: "Gaming picks for you"
        case .podcasts: "Podcast episodes"
        }
    }

    var icon: Reicon {
        switch self {
        case .home: .home
        case .shorts: .videoPlayV
        case .subscriptions: .subscriptions
        case .history: .history
        case .playlists: .playlist
        case .watchLater: .clock
        case .liked: .thumbsUp
        case .trending: .trending
        case .yourVideos: .play
        case .downloads: .download
        case .music: .music
        case .movies: .movie
        case .live: .live
        case .gaming: .gaming
        case .podcasts: .podcast
        }
    }

    /// One SF Symbol per section, drawn at one point size so the sidebar rows match.
    var sfSymbol: String {
        switch self {
        case .home: "house"
        case .shorts: "play.rectangle"
        case .subscriptions: "rectangle.stack"
        case .history: "clock.arrow.circlepath"
        case .playlists: "list.bullet.rectangle"
        case .watchLater: "clock"
        case .liked: "hand.thumbsup"
        case .trending: "chart.line.uptrend.xyaxis"
        case .yourVideos: "play.square.stack"
        case .downloads: "arrow.down.circle"
        case .music: "music.note"
        case .movies: "film"
        case .live: "dot.radiowaves.left.and.right"
        case .gaming: "gamecontroller"
        case .podcasts: "waveform.badge.mic"
        }
    }

    var emptyCopy: String {
        switch self {
        case .subscriptions: "No subscriptions yet."
        case .playlists: "No playlists yet."
        case .watchLater: "Watch Later is empty."
        case .liked: "No liked videos yet."
        case .shorts: "No shorts yet."
        case .history: "No watch history yet."
        case .home: "No recommendations yet."
        case .trending: "Nothing trending right now."
        case .yourVideos: "You haven't uploaded any videos."
        case .downloads: "Nothing downloaded yet."
        case .music: "No music recommendations yet."
        case .movies: "No movies to show."
        case .live: "No live streams right now."
        case .gaming: "No gaming recommendations yet."
        case .podcasts: "No podcasts yet."
        }
    }

    static let watch: [LibrarySection] = [.home, .shorts, .trending]
    static let library: [LibrarySection] = [.subscriptions, .history, .playlists, .yourVideos, .watchLater, .liked, .downloads]
    static let explore: [LibrarySection] = [.music, .movies, .live, .gaming, .podcasts]
}

/// A day grouping of watch history, labelled as YouTube labels it ("Today", "Oct 12").
struct HistoryDay: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var videos: [YTVideo]
}

/// Header facts for Watch Later / Liked ("owner", count, "Updated …").
struct PlaylistMeta: Equatable, Sendable {
    var title: String
    var owner: String?
    var count: Int
    var updated: String?
}

/// One page of the internal browse for a saved playlist (VLWL / VLLL / any VL…).
struct PlaylistBrowse: Sendable {
    var videos: [YTVideo]
    var meta: PlaylistMeta?
    var continuation: String?
    /// UI-facing failure note for an arbitrary opened playlist.
    var note: String? = nil
}

/// One page of watch history: day groups plus the next page token.
struct HistoryPage: Sendable {
    var days: [HistoryDay]
    var continuation: String?
}

struct LibrarySnapshot: Equatable, Sendable {
    var channel: YTChannel?
    var subscriptions: [YTSubscription] = []
    var playlists: [YTPlaylist] = []
    var watchLater: [YTVideo] = []
    var liked: [YTVideo] = []
    var shorts: [YTVideo] = []
    var history: [YTVideo] = []
    /// Recommendation grid for Home. YouTube's home browse is separate from the library shelves.
    var homeFeed: [YTVideo] = []
    var homeFeedNote: String?
    var notes: [LibrarySection: String] = [:]
    var capped: Set<LibrarySection> = []
    var consent: Set<LibrarySection> = []

    /// Lazy-loaded topic feeds (trending, explore topics, your uploads), keyed by section.
    var feeds: [LibrarySection: [YTVideo]] = [:]
    /// Watch history grouped by day, in YouTube's own order.
    var historyDays: [HistoryDay] = []
    var watchLaterMeta: PlaylistMeta?
    var likedMeta: PlaylistMeta?
    /// Load-more tokens for paginated sections (history, watch later, liked).
    var continuations: [LibrarySection: String] = [:]

    /// Ordered Home rows. A Shorts shelf stays between the video runs around it.
    var homeBlocks: [HomeBlock] = []
    var homeChips: [HomeChip] = []
    var homeContinuation: String?

    var isEmpty: Bool {
        channel == nil
            && subscriptions.isEmpty
            && playlists.isEmpty
            && watchLater.isEmpty
            && liked.isEmpty
            && shorts.isEmpty
            && history.isEmpty
            && homeFeed.isEmpty
            && feeds.values.allSatisfy(\.isEmpty)
    }
}

struct HomeChip: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var selected: Bool
    var browseID: String? = nil
    var params: String? = nil
    var continuation: String? = nil
    /// Used when YouTube did not send a chip bar. Searches that topic instead of a protobuf param.
    var query: String? = nil

    static let all = HomeChip(id: "All", title: "All", selected: true, browseID: "FEwhat_to_watch")

    static let fallback: [HomeChip] = fallback()

    /// YouTube's personalized chip set when it does send one; a richer fallback set
    /// (plus recorded search history topics) when it sends none.
    static func fallback(history topics: [String] = []) -> [HomeChip] {
        var chips: [HomeChip] = [
            all,
            HomeChip(id: "Music", title: "Music", selected: false, query: "music"),
            HomeChip(id: "Mixes", title: "Mixes", selected: false, query: "mixes"),
            HomeChip(id: "Gaming", title: "Gaming", selected: false, query: "gaming"),
            HomeChip(id: "Live", title: "Live", selected: false, query: "live"),
            HomeChip(id: "News", title: "News", selected: false, query: "news"),
            HomeChip(id: "Podcasts", title: "Podcasts", selected: false, query: "podcasts"),
            HomeChip(id: "Computer programming", title: "Computer programming", selected: false, query: "computer programming"),
            HomeChip(id: "Football", title: "Football", selected: false, query: "football"),
        ]
        var seen = Set(chips.map(\.id))
        for topic in topics where !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard seen.insert(topic).inserted else { continue }
            chips.append(HomeChip(id: topic, title: topic, selected: false, query: topic))
            if chips.count >= 14 { break }
        }
        return chips
    }
}

enum HomeBlock: Hashable, Sendable {
    case videos([YTVideo])
    case shorts([YTVideo])

    var items: [YTVideo] {
        switch self {
        case .videos(let items), .shorts(let items):
            items
        }
    }

    var isShorts: Bool {
        if case .shorts = self { return true }
        return false
    }
}

struct HomeFeed: Equatable, Sendable {
    var chips: [HomeChip] = []
    var blocks: [HomeBlock] = []
    var continuation: String?
    var capped = false
    var structured = false
    var note: String?

    static let maxRegularVideos = 80
    static let maxShortsPerShelf = 24
    static let synthesizedLead = 8

    var videos: [YTVideo] {
        var seen = Set<String>()
        return blocks.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }

    var regularCount: Int {
        blocks.reduce(0) { count, block in
            guard case .videos(let items) = block else { return count }
            return count + items.filter { !$0.isShort }.count
        }
    }

    /// Flat browse results become two rows of videos, a Shorts shelf, then the rest.
    static func synthesized(from videos: [YTVideo], lead: Int = synthesizedLead) -> HomeFeed {
        var seen = Set<String>()
        let unique = videos.filter { seen.insert($0.id).inserted }
        let regular = unique.filter { !$0.isShort }
        let shorts = Array(unique.filter(\.isShort).prefix(maxShortsPerShelf))
        let head = Array(regular.prefix(max(lead, 0)))
        let tail = Array(regular.dropFirst(head.count).prefix(max(maxRegularVideos - head.count, 0)))
        var blocks: [HomeBlock] = []
        if !head.isEmpty { blocks.append(.videos(head)) }
        if !shorts.isEmpty { blocks.append(.shorts(shorts)) }
        if !tail.isEmpty { blocks.append(.videos(tail)) }
        return HomeFeed(
            blocks: blocks,
            capped: regular.count > head.count + tail.count,
            structured: false
        )
    }

    func appendingContinuation(_ page: HomeFeed) -> HomeFeed {
        var merged = self
        var seen = Set(videos.map(\.id))
        var blocks = merged.blocks
        for block in page.blocks {
            let fresh = block.items.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            switch block {
            case .videos:
                if case .videos(var existing) = blocks.last {
                    existing.append(contentsOf: fresh)
                    blocks[blocks.count - 1] = .videos(existing)
                } else {
                    blocks.append(.videos(fresh))
                }
            case .shorts:
                blocks.append(.shorts(Array(fresh.prefix(Self.maxShortsPerShelf))))
            }
        }
        var regulars = 0
        var kept: [HomeBlock] = []
        var didCap = false
        for block in blocks {
            switch block {
            case .videos(let items):
                var row: [YTVideo] = []
                for item in items {
                    if !item.isShort {
                        if regulars >= Self.maxRegularVideos {
                            didCap = true
                            continue
                        }
                        regulars += 1
                    }
                    row.append(item)
                }
                if !row.isEmpty { kept.append(.videos(row)) }
            case .shorts:
                if regulars >= Self.maxRegularVideos {
                    didCap = true
                    continue
                }
                kept.append(block)
            }
        }
        merged.blocks = kept
        merged.continuation = didCap ? nil : page.continuation
        merged.capped = didCap || capped || page.capped
        merged.structured = structured || page.structured
        if let note = page.note, merged.note == nil { merged.note = note }
        return merged
    }

    /// Leading Shorts shelves move to after the first rows. A shelf already between video runs stays put.
    func placingShortsAfterLead(_ lead: Int = synthesizedLead) -> HomeFeed {
        guard let firstShort = blocks.firstIndex(where: \.isShorts),
              blocks.contains(where: { !$0.isShorts }) else { return self }
        guard !blocks[..<firstShort].contains(where: { !$0.isShorts }) else { return self }
        var index = firstShort
        var leading: [HomeBlock] = []
        while index < blocks.count, blocks[index].isShorts {
            leading.append(blocks[index])
            index += 1
        }
        var rest = Array(blocks[index...])
        guard let videoIndex = rest.firstIndex(where: { !$0.isShorts }),
              case .videos(let items) = rest[videoIndex] else {
            var copy = self
            copy.blocks = Array(blocks[..<firstShort]) + rest + leading
            return copy
        }
        let head = Array(items.prefix(max(lead, 0)))
        let tail = Array(items.dropFirst(head.count))
        var replacement: [HomeBlock] = []
        if !head.isEmpty { replacement.append(.videos(head)) }
        replacement.append(contentsOf: leading)
        if !tail.isEmpty { replacement.append(.videos(tail)) }
        rest.replaceSubrange(videoIndex...videoIndex, with: replacement)
        var copy = self
        copy.blocks = Array(blocks[..<firstShort]) + rest
        return copy
    }
}

struct YTImage: Decodable, Hashable, Sendable {
    var url: String
}

struct YTThumbnails: Decodable, Hashable, Sendable {
    /// Every size YouTube sent, keyed as in the payload ("default", "medium", "high", "standard", "maxres", …).
    var sizes: [String: YTImage] = [:]

    init(sizes: [String: YTImage] = [:]) {
        self.sizes = sizes
    }

    init(url: URL?) {
        if let url {
            sizes = ["high": YTImage(url: url.absoluteString)]
        }
    }

    init(from decoder: Decoder) throws {
        sizes = try decoder.singleValueContainer().decode([String: YTImage].self)
    }

    private static let order = ["maxres", "standard", "high", "medium", "default"]

    /// The largest rendition available, not the fixed default/medium/high order.
    var best: URL? {
        for key in Self.order {
            if let url = TubeImage.url(sizes[key]?.url) {
                return url
            }
        }
        for (_, image) in sizes.sorted(by: { $0.key < $1.key }) {
            if let url = TubeImage.url(image.url) {
                return url
            }
        }
        return nil
    }
}

struct YTChannel: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var snippet: Snippet
    var statistics: Statistics?
    var brandingSettings: Branding?

    struct Snippet: Decodable, Hashable, Sendable {
        var title: String
        var customUrl: String?
        var thumbnails: YTThumbnails?
    }

    struct Statistics: Decodable, Hashable, Sendable {
        var viewCount: String?
        var subscriberCount: String?
        var videoCount: String?
        var hiddenSubscriberCount: Bool?
    }

    struct Branding: Decodable, Hashable, Sendable {
        var image: Banner?

        struct Banner: Decodable, Hashable, Sendable {
            var bannerExternalUrl: String?
        }
    }

    var title: String { snippet.title }
    var avatarURL: URL? { snippet.thumbnails?.best }
    var bannerURL: URL? {
        TubeImage.url(brandingSettings?.image?.bannerExternalUrl)
    }

    var handle: String? {
        guard let custom = snippet.customUrl, !custom.isEmpty else { return nil }
        return custom.hasPrefix("@") ? custom : "@\(custom)"
    }

    var statsLine: String {
        var parts: [String] = []
        if statistics?.hiddenSubscriberCount != true, let subs = TubeFormat.count(statistics?.subscriberCount) {
            parts.append("\(subs) subscribers")
        }
        if let videos = TubeFormat.count(statistics?.videoCount) {
            parts.append("\(videos) videos")
        }
        return parts.joined(separator: " · ")
    }
}

struct YTSubscription: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var snippet: Snippet

    struct Snippet: Decodable, Hashable, Sendable {
        var title: String
        var thumbnails: YTThumbnails?
        var resourceId: Resource?

        struct Resource: Decodable, Hashable, Sendable {
            var channelId: String?
        }
    }

    var title: String { snippet.title }
    var avatarURL: URL? { snippet.thumbnails?.best }
    var channelID: String? { snippet.resourceId?.channelId }
}

struct YTPlaylist: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var snippet: Snippet
    var contentDetails: Details?

    struct Snippet: Decodable, Hashable, Sendable {
        var title: String
        var thumbnails: YTThumbnails?
    }

    struct Details: Decodable, Hashable, Sendable {
        var itemCount: Int?
    }

    var title: String { snippet.title }
    var thumbnail: URL? { snippet.thumbnails?.best }

    var countLabel: String {
        let count = contentDetails?.itemCount ?? 0
        return count == 1 ? "1 video" : "\(count) videos"
    }
}

struct YTPlaylistItem: Decodable, Hashable, Sendable {
    var id: String
    var snippet: Snippet

    struct Snippet: Decodable, Hashable, Sendable {
        var title: String
        var thumbnails: YTThumbnails?
        var videoOwnerChannelTitle: String?
        var videoOwnerChannelId: String?
        var publishedAt: String?
        var resourceId: Resource?

        struct Resource: Decodable, Hashable, Sendable {
            var videoId: String?
        }
    }
}

struct YTVideo: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var channel: String
    var thumbnail: URL?
    var published: String?
    var views: String?
    var length: String?
    var channelAvatar: URL?
    var channelID: String?
    var isShort: Bool = false

    /// Views and age, the line under the channel on a YouTube card.
    var meta: String {
        [views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var subtitle: String {
        [channel, meta].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

/// Watch-page header plus the related column. Loaded from Innertube `next` after the player opens.
struct WatchPage: Sendable {
    var video: YTVideo
    var subscribers: String?
    var description: String?
    /// Channel handle, including the `@`.
    var handle: String?
    var related: [YTVideo]
}

/// A page of comments from the watch-page continuation, not the Data API.
struct CommentListing: Sendable {
    var comments: [YTComment]
    var count: String?
    var disabled = false
    var continuation: String?
    /// Per-comment "view replies" continuation tokens, keyed by comment id.
    var replyTokens: [String: String] = [:]
    /// Sort-menu continuation tokens from the comments panel, keyed by menu title.
    var sortTokens: [String: String] = [:]
}

struct YTComment: Identifiable, Hashable, Sendable {
    var id: String
    var author: String
    var avatar: URL?
    var channelID: String?
    var text: String
    var likes: String?
    var published: String?
    var replyCount: Int = 0
    var replies: [YTComment] = []
}

struct ChannelBrowse: Identifiable, Sendable {
    var id: String
    var title: String
    var channel: YTChannel?
    var videos: [YTVideo] = []
    var note: String?
    var loading = false
}

struct YTPage<Item: Decodable>: Decodable {
    var items: [Item]?
    var nextPageToken: String?
}

struct YTAPIError: Decodable {
    struct Inner: Decodable {
        var code: Int?
        var message: String?
    }

    var error: Inner
}

struct Collected<Item: Sendable>: Sendable {
    var items: [Item]
    var capped: Bool
}

/// One page of a real YouTube search.
struct SearchPage: Sendable {
    var videos: [YTVideo] = []
    var channels: [YTChannel] = []
    var playlists: [YTPlaylist] = []
    var continuation: String? = nil
}

/// One row of the search-field suggestion list.
struct SearchSuggestion: Identifiable, Hashable, Sendable {
    var id: String { text }
    var text: String
    var isHistory = false
    var isPopular = false
}

/// One entry of the bell-icon notification menu.
struct YTNotification: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var channel: String?
    var avatarURL: URL?
    var thumbnailURL: URL?
    var time: String?
    var unread: Bool
    var videoID: String?
}

enum CommentOrder: String, CaseIterable, Identifiable, Sendable {
    case top = "Top comments"
    case newest = "Newest first"

    var id: String { rawValue }
}

/// Relative-date heuristic for client-side comment sorting when YouTube sends no
/// sort tokens: "2 hours ago" < "3 days ago" < "2 weeks ago".
func commentRecencyRank(_ published: String?) -> Int {
    guard var text = published?.lowercased() else { return Int.max }
    if let range = text.range(of: "streamed ") {
        text.removeSubrange(text.startIndex..<range.upperBound)
    }
    let units: [(String, Int)] = [
        ("second", 1), ("minute", 60), ("hour", 3_600),
        ("day", 86_400), ("week", 604_800), ("month", 2_628_000), ("year", 31_536_000),
    ]
    for (word, seconds) in units {
        guard let range = text.range(of: word) else { continue }
        // Digits directly before the unit: "2 hours ago" → 2.
        var index = range.lowerBound
        while index > text.startIndex, !text[text.index(before: index)].isNumber {
            index = text.index(before: index)
        }
        var digitsEnd = index
        while digitsEnd > text.startIndex, text[text.index(before: digitsEnd)].isNumber {
            digitsEnd = text.index(before: digitsEnd)
        }
        let count = Int(text[digitsEnd..<index]) ?? 1
        return count * seconds
    }
    return Int.max
}
