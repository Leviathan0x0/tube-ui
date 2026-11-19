import Foundation

enum YouTubeError: LocalizedError, Equatable {
    case api(Int, String)
    case http(Int)
    case insufficientScope
    case decode

    var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            message.isEmpty ? "YouTube returned \(code)." : message
        case .http(let code):
            "YouTube returned HTTP \(code)."
        case .decode:
            "TubeUI couldn't read YouTube's response."
        case .insufficientScope:
            "YouTube needs permission to share this part of your account."
        }
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case .api(401, _) = error as? YouTubeError { return true }
        if case .http(401) = error as? YouTubeError { return true }
        return false
    }
}

struct YouTubeAPI: Sendable {
    var accessToken: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "TubeUI/0.1"]
        return URLSession(configuration: configuration)
    }()

    func myChannel() async throws -> YTChannel? {
        let page: YTPage<YTChannel> = try await get("channels", query: [
            URLQueryItem(name: "part", value: "snippet,statistics"),
            URLQueryItem(name: "mine", value: "true"),
        ])
        return page.items?.first
    }

    func subscriptions(limit: Int) async throws -> Collected<YTSubscription> {
        try await collect(
            YTSubscription.self,
            path: "subscriptions",
            query: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "order", value: "alphabetical"),
            ],
            limit: limit
        )
    }

    func playlists(limit: Int) async throws -> Collected<YTPlaylist> {
        try await collect(
            YTPlaylist.self,
            path: "playlists",
            query: [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
            ],
            limit: limit
        )
    }

    func videos(playlistID: String, limit: Int) async throws -> Collected<YTVideo> {
        let page = try await collect(
            YTPlaylistItem.self,
            path: "playlistItems",
            query: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistID),
            ],
            limit: limit
        )
        let videos = page.items.compactMap { item -> YTVideo? in
            let videoID = item.snippet.resourceId?.videoId ?? ""
            guard YTVideo.isVideoID(videoID) else { return nil }
            return YTVideo(
                id: videoID,
                title: item.snippet.title,
                channel: item.snippet.videoOwnerChannelTitle ?? "",
                thumbnail: item.snippet.thumbnails?.best,
                published: TubeFormat.date(item.snippet.publishedAt),
                channelID: item.snippet.videoOwnerChannelId
            )
        }
        return Collected(items: videos, capped: page.capped)
    }

    /// Uploads playlist for a channel. YouTube derives it by swapping the `UC` prefix for `UU`.
    static func uploadsPlaylistID(channelID: String) -> String? {
        guard channelID.hasPrefix("UC"), channelID.count > 2 else { return nil }
        return "UU" + channelID.dropFirst(2)
    }

    func watchHistory(limit: Int) async throws -> Collected<YTVideo> {
        let page: YTPage<YTChannelContent> = try await get("channels", query: [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "mine", value: "true"),
        ])
        guard let playlist = page.items?.first?.contentDetails?.relatedPlaylists?.watchHistory, !playlist.isEmpty else {
            return Collected(items: [], capped: false)
        }
        return try await videos(playlistID: playlist, limit: limit)
    }

    /// Recent uploads from subscribed channels that are short enough to be Shorts.
    func shorts(from subscriptions: [YTSubscription], limit: Int) async throws -> Collected<YTVideo> {
        let playlists = Array(subscriptions.compactMap { subscription -> String? in
            guard let channelID = subscription.channelID else { return nil }
            return Self.uploadsPlaylistID(channelID: channelID)
        }.prefix(24))
        var stubs: [UploadStub] = []
        let api = self
        await withTaskGroup(of: [UploadStub].self) { group in
            for playlist in playlists {
                group.addTask { await api.uploadStubs(playlistID: playlist, limit: 5) }
            }
            for await batch in group {
                stubs.append(contentsOf: batch)
            }
        }
        var seen: Set<String> = []
        var unique = stubs.filter { seen.insert($0.videoID).inserted }
        unique.sort { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
        let durations = try await durations(for: unique.map(\.videoID))
        let matched = unique.filter { stub in
            guard let duration = durations[stub.videoID] else { return false }
            return TubeFormat.isShort(duration: duration)
        }
        let items = matched.prefix(limit).map { stub in
            YTVideo(
                id: stub.videoID,
                title: stub.title,
                channel: stub.channel,
                thumbnail: stub.thumbnail,
                published: TubeFormat.date(stub.publishedAt)
            )
        }
        return Collected(items: Array(items), capped: subscriptions.count > 24 || matched.count > limit)
    }

    private func uploadStubs(playlistID: String, limit: Int) async -> [UploadStub] {
        do {
            let page = try await collect(
                YTPlaylistItem.self,
                path: "playlistItems",
                query: [
                    URLQueryItem(name: "part", value: "snippet"),
                    URLQueryItem(name: "playlistId", value: playlistID),
                ],
                limit: limit
            )
            return page.items.compactMap { item in
                guard let videoID = item.snippet.resourceId?.videoId, YTVideo.isVideoID(videoID) else { return nil }
                return UploadStub(
                    videoID: videoID,
                    title: item.snippet.title,
                    channel: item.snippet.videoOwnerChannelTitle ?? "",
                    thumbnail: item.snippet.thumbnails?.best,
                    publishedAt: item.snippet.publishedAt
                )
            }
        } catch {
            return []
        }
    }

    private func durations(for ids: [String]) async throws -> [String: String] {
        var map: [String: String] = [:]
        var start = 0
        while start < ids.count {
            let end = min(start + 50, ids.count)
            let slice = ids[start..<end].joined(separator: ",")
            let page: YTPage<YTDurationRow> = try await get("videos", query: [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "id", value: slice),
            ])
            for item in page.items ?? [] {
                if let duration = item.contentDetails?.duration {
                    map[item.id] = duration
                }
            }
            start = end
        }
        return map
    }

    private func collect<Item: Decodable>(
        _ type: Item.Type,
        path: String,
        query: [URLQueryItem],
        limit: Int
    ) async throws -> Collected<Item> {
        var items: [Item] = []
        var pageToken: String?
        var seen: Set<String> = []
        var capped = false
        while items.count < limit {
            if let pageToken, !seen.insert(pageToken).inserted { break }
            var pageQuery = query
            pageQuery.append(URLQueryItem(name: "maxResults", value: "50"))
            if let pageToken {
                pageQuery.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: YTPage<Item> = try await get(path, query: pageQuery)
            let pageItems = page.items ?? []
            let room = limit - items.count
            if pageItems.count > room {
                items.append(contentsOf: pageItems.prefix(room))
                capped = true
                break
            }
            items.append(contentsOf: pageItems)
            guard let next = page.nextPageToken else {
                capped = false
                break
            }
            pageToken = next
            capped = true
        }
        return Collected(items: items, capped: capped)
    }

    func channel(id: String) async throws -> YTChannel? {
        let page: YTPage<YTChannel> = try await get("channels", query: [
            URLQueryItem(name: "part", value: "snippet,statistics,brandingSettings"),
            URLQueryItem(name: "id", value: id),
        ])
        return page.items?.first
    }

    func engagement(for videoID: String) async throws -> (likes: String?, comments: String?) {
        let page: YTPage<YTStatRow> = try await get("videos", query: [
            URLQueryItem(name: "part", value: "statistics"),
            URLQueryItem(name: "id", value: videoID),
        ])
        let stats = page.items?.first?.statistics
        return (stats?.likeCount, stats?.commentCount)
    }

    func rating(for videoID: String) async throws -> String {
        let page: YTRatingPage = try await get("videos/getRating", query: [
            URLQueryItem(name: "id", value: videoID),
        ])
        return page.items?.first?.rating ?? "none"
    }

    func setRating(videoID: String, rating: String) async throws {
        try await send("videos/rate", method: "POST", query: [
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "rating", value: rating),
        ], body: nil)
    }

    func comments(videoID: String, limit: Int) async throws -> [YTComment] {
        let page: YTPage<YTCommentThread> = try await get("commentThreads", query: [
            URLQueryItem(name: "part", value: "snippet,replies"),
            URLQueryItem(name: "videoId", value: videoID),
            URLQueryItem(name: "order", value: "relevance"),
            URLQueryItem(name: "textFormat", value: "plainText"),
            URLQueryItem(name: "maxResults", value: String(min(limit, 20))),
        ])
        return (page.items ?? []).map { $0.comment }
    }

    func postComment(videoID: String, text: String) async throws {
        let payload: [String: Any] = [
            "snippet": [
                "videoId": videoID,
                "topLevelComment": [
                    "snippet": ["textOriginal": text],
                ],
            ],
        ]
        try await send(
            "commentThreads",
            method: "POST",
            query: [URLQueryItem(name: "part", value: "snippet")],
            body: try JSONSerialization.data(withJSONObject: payload)
        )
    }

    func subscribe(channelID: String) async throws -> String {
        let payload: [String: Any] = [
            "snippet": [
                "resourceId": [
                    "kind": "youtube#channel",
                    "channelId": channelID,
                ],
            ],
        ]
        let data = try await send(
            "subscriptions",
            method: "POST",
            query: [URLQueryItem(name: "part", value: "snippet")],
            body: try JSONSerialization.data(withJSONObject: payload)
        )
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String {
            return id
        }
        return channelID
    }

    func unsubscribe(subscriptionID: String) async throws {
        try await send("subscriptions", method: "DELETE", query: [
            URLQueryItem(name: "id", value: subscriptionID),
        ], body: nil)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, data: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YouTubeError.decode
        }
    }

    @discardableResult
    private func send(_ path: String, method: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = 30
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, data: data)
        }
        return data
    }

    private static func failure(status: Int, data: Data) -> YouTubeError {
        if Innertube.rejectsForScope(data) { return .insufficientScope }
        if let parsed = try? JSONDecoder().decode(YTAPIError.self, from: data) {
            let message = parsed.error.message ?? ""
            let lower = message.lowercased()
            if lower.contains("insufficient") && lower.contains("scope") {
                return .insufficientScope
            }
            return .api(parsed.error.code ?? status, message)
        }
        return .http(status)
    }
}

private struct UploadStub: Sendable {
    var videoID: String
    var title: String
    var channel: String
    var thumbnail: URL?
    var publishedAt: String?
}

private struct YTChannelContent: Decodable {
    var contentDetails: Content?

    struct Content: Decodable {
        var relatedPlaylists: Playlists?

        struct Playlists: Decodable {
            var watchHistory: String?
        }
    }
}

private struct YTStatRow: Decodable {
    var id: String
    var statistics: Stats?

    struct Stats: Decodable {
        var likeCount: String?
        var commentCount: String?
    }
}

private struct YTRatingPage: Decodable {
    var items: [Item]?

    struct Item: Decodable {
        var rating: String?
    }
}

private struct YTCommentThread: Decodable {
    var snippet: Snippet
    var replies: Replies?

    struct Snippet: Decodable {
        var totalReplyCount: Int?
        var topLevelComment: YTCommentItem
    }

    struct Replies: Decodable {
        var comments: [YTCommentItem]?
    }

    var comment: YTComment {
        var value = snippet.topLevelComment.comment
        value.replyCount = snippet.totalReplyCount ?? 0
        value.replies = (replies?.comments ?? []).map(\.comment)
        return value
    }
}

private struct YTCommentItem: Decodable {
    var id: String?
    var snippet: Snippet

    struct Snippet: Decodable {
        var authorDisplayName: String?
        var authorProfileImageUrl: String?
        var authorChannelId: Author?
        var textOriginal: String?
        var textDisplay: String?
        var likeCount: Int?
        var publishedAt: String?

        struct Author: Decodable {
            var value: String?
        }
    }

    var comment: YTComment {
        YTComment(
            id: id ?? UUID().uuidString,
            author: snippet.authorDisplayName ?? "YouTube",
            avatar: TubeImage.url(snippet.authorProfileImageUrl),
            channelID: snippet.authorChannelId?.value,
            text: snippet.textOriginal ?? snippet.textDisplay ?? "",
            likes: snippet.likeCount.map { TubeFormat.count(String($0)) ?? String($0) },
            published: TubeFormat.date(snippet.publishedAt)
        )
    }
}

private struct YTDurationRow: Decodable {
    var id: String
    var contentDetails: Content?

    struct Content: Decodable {
        var duration: String?
    }
}

/// A saved playlist (Watch Later / Liked) page: videos plus header facts.
private struct SavedPlaylistPage: Sendable {
    var videos: [YTVideo]
    var meta: PlaylistMeta?
    var continuation: String?
    var capped: Bool
}

enum LibraryLoader {
    static func load(_ api: YouTubeAPI) async throws -> LibrarySnapshot {
        async let channelResult = capture { try await api.myChannel() }
        async let subscriptionResult = capture { try await api.subscriptions(limit: 200) }
        async let playlistResult = capture { try await api.playlists(limit: 300) }
        async let shortsFeedResult = capture { try await Innertube.browse(id: "FEshorts", accessToken: api.accessToken) }
        async let homeFeedResult = capture { try await Innertube.home(accessToken: api.accessToken) }
        async let historyResult = capture { try await Innertube.history(accessToken: api.accessToken) }
        async let watchLaterResult = savedPlaylist(browseID: "VLWL", fallbackID: "WL", api: api)
        async let likedResult = savedPlaylist(browseID: "VLLL", fallbackID: "LL", api: api)

        let channel = await channelResult
        let subscriptions = await subscriptionResult
        let playlists = await playlistResult
        let shortsFeed = await shortsFeedResult
        let homeFeed = await homeFeedResult
        let historyPage = await historyResult
        let watchLater = await watchLaterResult
        let liked = await likedResult

        if case .failure(let error) = channel, YouTubeError.isUnauthorized(error) {
            throw error
        }

        var snapshot = LibrarySnapshot()
        switch channel {
        case .success(let value):
            snapshot.channel = value
            // Your videos: uploads of the signed-in channel, one small page.
            if let channel = value, let playlist = YouTubeAPI.uploadsPlaylistID(channelID: channel.id) {
                switch await capture({ try await api.videos(playlistID: playlist, limit: 48) }) {
                case .success(let collected):
                    snapshot.feeds[.yourVideos] = collected.items
                case .failure(let error):
                    snapshot.notes[.yourVideos] = message(error)
                }
            }
        case .failure(let error):
            snapshot.notes[.home] = message(error)
        }
        switch subscriptions {
        case .success(let collected):
            snapshot.subscriptions = collected.items
            if collected.capped { snapshot.capped.insert(.subscriptions) }
        case .failure(let error):
            snapshot.notes[.subscriptions] = message(error)
        }
        switch playlists {
        case .success(let collected):
            snapshot.playlists = collected.items
            if collected.capped { snapshot.capped.insert(.playlists) }
        case .failure(let error):
            snapshot.notes[.playlists] = message(error)
        }
        switch watchLater {
        case .success(let page):
            snapshot.watchLater = page.videos
            snapshot.watchLaterMeta = page.meta
            if let token = page.continuation, page.videos.count < 200 { snapshot.continuations[.watchLater] = token }
            if page.capped || page.videos.count >= 200 { snapshot.capped.insert(.watchLater) }
        case .failure(let error):
            snapshot.notes[.watchLater] = message(error)
        }
        switch liked {
        case .success(let page):
            snapshot.liked = page.videos
            snapshot.likedMeta = page.meta
            if let token = page.continuation, page.videos.count < 200 { snapshot.continuations[.liked] = token }
            if page.capped || page.videos.count >= 200 { snapshot.capped.insert(.liked) }
        case .failure(let error):
            snapshot.notes[.liked] = message(error)
        }

        let subscriptionShorts: Result<Collected<YTVideo>, Error>
        if case .success(let videos) = shortsFeed, !videos.isEmpty {
            subscriptionShorts = .success(Collected(items: [], capped: false))
        } else if case .success(let collected) = subscriptions {
            subscriptionShorts = await capture { try await api.shorts(from: collected.items, limit: 48) }
        } else if case .failure(let error) = subscriptions {
            subscriptionShorts = .failure(error)
        } else {
            subscriptionShorts = .success(Collected(items: [], capped: false))
        }
        let shorts = resolve(primary: shortsFeed, secondary: subscriptionShorts)
        snapshot.shorts = shorts.items
        if shorts.capped { snapshot.capped.insert(.shorts) }
        if let note = shorts.note { snapshot.notes[.shorts] = note }
        if shorts.consent { snapshot.consent.insert(.shorts) }

        // History: day groups from the internal browse, flat list is the concat. The
        // Data API watch-history playlist is the fallback when the browse shows nothing.
        switch historyPage {
        case .success(let page) where !page.days.isEmpty:
            snapshot.historyDays = page.days
            snapshot.history = page.days.flatMap(\.videos)
            if let token = page.continuation { snapshot.continuations[.history] = token }
        case .success:
            switch await capture({ try await api.watchHistory(limit: 200) }) {
            case .success(let collected):
                snapshot.history = collected.items
                if collected.capped { snapshot.capped.insert(.history) }
            case .failure(let error):
                if (error as? YouTubeError) == .insufficientScope { snapshot.consent.insert(.history) }
                snapshot.notes[.history] = message(error)
            }
        case .failure(let error):
            if YouTubeError.isUnauthorized(error) { throw error }
            if (error as? YouTubeError) == .insufficientScope { snapshot.consent.insert(.history) }
            snapshot.notes[.history] = message(error)
        }

        switch homeFeed {
        case .success(let feed):
            let placed = placedHome(
                feed,
                shorts: snapshot.shorts,
                history: UserDefaults.standard.stringArray(forKey: "tubeui.searchHistory") ?? []
            )
            snapshot.homeBlocks = placed.blocks
            snapshot.homeChips = placed.chips
            snapshot.homeFeed = placed.videos
            snapshot.homeContinuation = placed.continuation
            if placed.capped { snapshot.capped.insert(.home) }
            if placed.videos.isEmpty, let note = placed.note {
                snapshot.homeFeedNote = note
            }
        case .failure(let error):
            snapshot.homeFeedNote = message(error)
            if (error as? YouTubeError) == .insufficientScope {
                snapshot.consent.insert(.home)
            }
        }
        return snapshot
    }

    /// Watch Later and Liked via the internal browse of the special playlists
    /// (VLWL / VLLL); the Data API often returns nothing for them and stays as fallback.
    private static func savedPlaylist(browseID: String, fallbackID: String, api: YouTubeAPI) async -> Result<SavedPlaylistPage, Error> {
        var browseError: Error?
        do {
            let page = try await Innertube.playlist(browseID: browseID, accessToken: api.accessToken)
            if !page.videos.isEmpty {
                return .success(SavedPlaylistPage(
                    videos: page.videos,
                    meta: page.meta,
                    continuation: page.continuation,
                    capped: page.videos.count >= 200
                ))
            }
        } catch {
            browseError = error
            if YouTubeError.isUnauthorized(error) { return .failure(error) }
        }
        do {
            let collected = try await api.videos(playlistID: fallbackID, limit: 200)
            return .success(SavedPlaylistPage(videos: collected.items, meta: nil, continuation: nil, capped: collected.capped))
        } catch {
            return .failure(browseError ?? error)
        }
    }

    private static func resolve(
        primary: Result<[YTVideo], Error>,
        secondary: Result<Collected<YTVideo>, Error>
    ) -> (items: [YTVideo], capped: Bool, note: String?, consent: Bool) {
        if case .success(let items) = primary, !items.isEmpty {
            return (items, items.count >= 80, nil, false)
        }
        if case .success(let collected) = secondary, !collected.items.isEmpty {
            return (collected.items, collected.capped, nil, false)
        }
        if case .failure(let error) = primary {
            return ([], false, message(error), error is YouTubeError && error as? YouTubeError == .insufficientScope)
        }
        if case .failure(let error) = secondary {
            return ([], false, message(error), error is YouTubeError && error as? YouTubeError == .insufficientScope)
        }
        if case .success(let collected) = secondary {
            return (collected.items, collected.capped, nil, false)
        }
        return ([], false, nil, false)
    }

    /// Keeps a Shorts shelf that the home browse already placed. Otherwise inserts the Shorts tab after the first rows.
    static func placedHome(_ feed: HomeFeed, shorts: [YTVideo], history: [String] = []) -> HomeFeed {
        if feed.blocks.contains(where: \.isShorts) {
            var placed = feed.placingShortsAfterLead()
            if placed.chips.isEmpty { placed.chips = HomeChip.fallback(history: history) }
            return placed
        }
        var seen = Set(feed.videos.filter { !$0.isShort }.map(\.id))
        var mixed = feed.videos.filter { !$0.isShort }
        for var item in feed.videos.filter(\.isShort) + shorts {
            guard seen.insert(item.id).inserted else { continue }
            item.isShort = true
            mixed.append(item)
        }
        var placed = HomeFeed.synthesized(from: mixed)
        placed.chips = feed.chips.isEmpty ? HomeChip.fallback(history: history) : feed.chips
        placed.continuation = feed.continuation
        placed.capped = feed.capped || placed.capped
        placed.note = feed.note
        return placed
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }
}
