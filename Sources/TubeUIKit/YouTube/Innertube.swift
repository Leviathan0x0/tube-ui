import Foundation

/// Signed-in YouTube browse feeds. The Data API does not return the Shorts shelf or watch history.
enum Innertube {
    static func browse(id: String, accessToken: String) async throws -> [YTVideo] {
        // The TV client on the Google API host is the one that accepts this
        // desktop sign-in. The web and Android clients answer 400.
        let data = try await request(path: "browse", payload: ["browseId": id], accessToken: accessToken)
        return try videos(in: data)
    }

    /// Watch-page metadata and the related column. `next` is the call YouTube's player makes.
    static func watch(videoID: String, accessToken: String) async throws -> WatchPage {
        let data = try await request(path: "next", payload: ["videoId": videoID], accessToken: accessToken)
        return try watchPage(in: data, videoID: videoID)
    }

    static func watchPage(in data: Data, videoID: String) throws -> WatchPage {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        let meta = watchMeta(in: root)
        let related = collect(root).filter { $0.id != videoID }
        return WatchPage(
            video: YTVideo(
                id: videoID,
                title: meta.title,
                channel: meta.channel,
                thumbnail: nil,
                published: meta.published,
                views: meta.views,
                channelAvatar: meta.avatar,
                channelID: meta.channelID
            ),
            subscribers: meta.subscribers,
            description: meta.description,
            handle: meta.handle,
            related: related
        )
    }

    static func rejectsForScope(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("insufficientPermissions") || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
    }

    static func videos(in data: Data) throws -> [YTVideo] {
        let root = try JSONSerialization.jsonObject(with: data)
        return collect(JSONValue(any: root))
    }

    private enum Client {
        case web(String)
        case android
        case tv

        var name: String {
            switch self {
            case .web: "WEB"
            case .android: "ANDROID"
            case .tv: "TVHTML5"
            }
        }

        var version: String {
            switch self {
            case .web(let version): version
            case .android: "19.35.36"
            case .tv: "7.20250319.19.00"
            }
        }

        var headerName: String {
            switch self {
            case .web: "1"
            case .android: "3"
            case .tv: "7"
            }
        }

        var userAgent: String {
            switch self {
            case .web:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
            case .android:
                "com.google.android.youtube/19.35.36 (Linux; U; Android 13) gzip"
            case .tv:
                "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
            }
        }

        var context: [String: Any] {
            var client: [String: Any] = [
                "hl": "en",
                "gl": "US",
                "clientName": name,
                "clientVersion": version,
            ]
            switch self {
            case .android:
                client["androidSdkVersion"] = 30
                client["osName"] = "Android"
                client["osVersion"] = "13"
                client["platform"] = "MOBILE"
            case .web, .tv:
                break
            }
            return client
        }

        /// First-party Innertube keys. A desktop OAuth token is rejected without the matching key.
        var apiKey: String {
            switch self {
            case .android: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
            case .web, .tv: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
            }
        }

        var endpoints: [URL] {
            let google = "https://youtubei.googleapis.com/youtubei/v1/browse?key=\(apiKey)"
            let web = "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)"
            switch self {
            case .android, .tv:
                return [URL(string: google)!, URL(string: web)!]
            case .web:
                return [URL(string: web)!]
            }
        }
    }

    private static func request(path: String, payload: [String: Any], accessToken: String) async throws -> Data {
        try await perform(path: path, payload: payload, accessToken: accessToken, client: .tv)
    }

    /// WEB comments are public. A desktop bearer on this client often 400s, so callers retry without it.
    private static var webCommentsClient: Client { .web("2.20251020.01.00") }

    private static func perform(
        path: String,
        payload: [String: Any],
        accessToken: String?,
        client: Client
    ) async throws -> Data {
        guard let endpoint = client.endpoints.first,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw YouTubeError.http(-1) }
        components.path = "/youtubei/v1/\(path)"
        components.query = "key=\(client.apiKey)"
        guard let url = components.url else { throw YouTubeError.http(-1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue(client.headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        var body: [String: Any] = ["context": ["client": client.context]]
        for (key, value) in payload { body[key] = value }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw failure(status: status, data: data)
        }
        return data
    }

    private static func failure(status: Int, data: Data) -> YouTubeError {
        if rejectsForScope(data) { return .insufficientScope }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return .http(status) }
        let message = error["message"] as? String ?? ""
        let statusName = error["status"] as? String ?? ""
        let reason = (error["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? ""
        let lowered = (message + " " + statusName + " " + reason).lowercased()
        if lowered.contains("insufficient") || lowered.contains("permission") {
            return .insufficientScope
        }
        if !message.isEmpty { return .api(status, message) }
        return .http(status)
    }

    struct PlaylistEdit: Equatable, Sendable {
        var playlistID: String
        var action: String
        var videoID: String
    }

    /// Watch Later is playlist `WL`. The Data API rejects inserts into it, so this is the player edit.
    static func watchLaterEdit(videoID: String) -> PlaylistEdit {
        PlaylistEdit(playlistID: "WL", action: "ACTION_ADD_VIDEO", videoID: videoID)
    }

    static func addToWatchLater(videoID: String, accessToken: String) async throws {
        let edit = watchLaterEdit(videoID: videoID)
        let data: Data
        do {
            data = try await request(
                path: "browse/edit_playlist",
                payload: [
                    "playlistId": edit.playlistID,
                    "actions": [[
                        "action": edit.action,
                        "addedVideoId": edit.videoID,
                    ]],
                ],
                accessToken: accessToken
            )
        } catch let error as YouTubeError {
            throw savedVideoError(error)
        }
        if let message = playlistEditError(in: data) {
            throw YouTubeError.api(400, message)
        }
    }

    /// The Data API's "can't insert into this playlist" sentence never reaches the UI.
    static func savedVideoError(_ error: YouTubeError) -> YouTubeError {
        switch error {
        case .insufficientScope:
            return .api(403, "Couldn't save this video to Watch Later.")
        case .api(_, let message):
            let lower = message.lowercased()
            if lower.contains("playlist") || lower.contains("insert") || lower.contains("authorized") || lower.contains("permission") {
                return .api(400, "Couldn't save this video to Watch Later.")
            }
            return error
        default:
            return error
        }
    }

    static func playlistEditError(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["error"] != nil {
            return "Couldn't save this video to Watch Later."
        }
        if let status = object["status"] as? String {
            let upper = status.uppercased()
            if upper.contains("FAIL") || upper.contains("ERROR") {
                return "Couldn't save this video to Watch Later."
            }
        }
        return nil
    }

    /// Public comments from the WEB watch page. No second OAuth grant.
    static func comments(videoID: String, accessToken: String?) async throws -> CommentListing {
        do {
            return try await loadComments(videoID: videoID, accessToken: nil)
        } catch {
            guard let accessToken, !accessToken.isEmpty else { throw error }
            return try await loadComments(videoID: videoID, accessToken: accessToken)
        }
    }

    static func moreComments(continuation: String, accessToken: String?) async throws -> CommentListing {
        do {
            return try await fetchCommentContinuation(continuation, accessToken: nil)
        } catch {
            guard let accessToken, !accessToken.isEmpty else { throw error }
            return try await fetchCommentContinuation(continuation, accessToken: accessToken)
        }
    }

    static func commentListing(in data: Data) throws -> CommentListing {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        return assembledComments(in: root)
    }

    static func commentPanelContinuation(in data: Data) throws -> String? {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        return commentPanelContinuation(in: root)
    }

    static func commentHeaderCount(in data: Data) throws -> String? {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        return commentHeaderCount(in: root)
    }

    private static func loadComments(videoID: String, accessToken: String?) async throws -> CommentListing {
        let first = try await perform(
            path: "next",
            payload: ["videoId": videoID],
            accessToken: accessToken,
            client: webCommentsClient
        )
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: first))
        let count = commentHeaderCount(in: root)
        let disabled = commentsPanel(in: root).map(commentsLookDisabled) ?? false
        if let token = commentPanelContinuation(in: root) {
            var listing = try await fetchCommentContinuation(token, accessToken: accessToken)
            if listing.count == nil { listing.count = count }
            if disabled { listing.disabled = true }
            listing.sortTokens = commentSortTokens(in: root)
            return listing
        }
        var listing = assembledComments(in: root)
        if listing.count == nil { listing.count = count }
        if disabled { listing.disabled = true }
        listing.sortTokens = commentSortTokens(in: root)
        return listing
    }

    /// "Top comments" / "Newest first" continuation tokens from the panel's sort menu.
    private static func commentSortTokens(in root: JSONValue) -> [String: String] {
        guard let menu = firstObject(root, key: "sortFilterSubMenuRenderer"),
              case .array(let items) = menu["subMenuItems"]
        else { return [:] }
        var tokens: [String: String] = [:]
        for item in items {
            guard case .object(let fields) = item,
                  let title = text(fields["title"]),
                  let token = commandToken(in: .object(fields))
            else { continue }
            tokens[title] = token
        }
        return tokens
    }

    private static func fetchCommentContinuation(_ token: String, accessToken: String?) async throws -> CommentListing {
        let page = try await perform(
            path: "next",
            payload: ["continuation": token],
            accessToken: accessToken,
            client: webCommentsClient
        )
        return try commentListing(in: page)
    }

    private static func assembledComments(in root: JSONValue) -> CommentListing {
        var entities: [String: JSONValue] = [:]
        indexCommentEntities(root, into: &entities)
        var comments: [YTComment] = []
        var seen = Set<String>()
        var replyTokens: [String: String] = [:]
        appendThreads(root, entities: entities, into: &comments, seen: &seen, replyTokens: &replyTokens)
        return CommentListing(
            comments: comments,
            count: nil,
            disabled: false,
            continuation: nextCommentContinuation(in: root),
            replyTokens: replyTokens
        )
    }

    private static func commentsPanel(in root: JSONValue) -> JSONValue? {
        var panels: [JSONValue] = []
        collectValues(root, key: "engagementPanelSectionListRenderer", into: &panels)
        for panel in panels {
            guard case .object(let fields) = panel else { continue }
            let ident = text(fields["panelIdentifier"]) ?? ""
            if ident.contains("comment") { return panel }
        }
        return nil
    }

    private static func commentPanelContinuation(in root: JSONValue) -> String? {
        guard let panel = commentsPanel(in: root),
              case .object(let fields) = panel,
              let content = fields["content"]
        else { return nil }
        return continuationToken(in: content)
    }

    private static func commentHeaderCount(in root: JSONValue) -> String? {
        guard let panel = commentsPanel(in: root),
              case .object(let fields) = panel,
              let header = fields["header"]
        else { return nil }
        if let contextual = firstValue(header, key: "contextualInfo") {
            return text(contextual)
        }
        return nil
    }

    private static func commentsLookDisabled(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string):
            let lower = string.lowercased()
            return lower.contains("turned off") || lower.contains("comments are disabled")
        case .object(let fields):
            return fields.values.contains { commentsLookDisabled($0) }
        case .array(let items):
            return items.contains { commentsLookDisabled($0) }
        default:
            return false
        }
    }

    private static func continuationToken(in value: JSONValue) -> String? {
        if case .object(let fields) = value,
           case .object(let command) = fields["continuationCommand"],
           case .string(let token) = command["token"],
           token.count > 20 {
            return token
        }
        switch value {
        case .object(let fields):
            for child in fields.values {
                if let token = continuationToken(in: child) { return token }
            }
        case .array(let items):
            for item in items {
                if let token = continuationToken(in: item) { return token }
            }
        default:
            break
        }
        return nil
    }

    /// The next page token sits beside the threads. Reply buttons keep their own tokens inside a thread.
    private static func nextCommentContinuation(in value: JSONValue) -> String? {
        switch value {
        case .object(let fields):
            if fields["commentThreadRenderer"] != nil || fields["commentEntityPayload"] != nil {
                return nil
            }
            if case .object(let command) = fields["continuationCommand"],
               case .string(let token) = command["token"],
               token.count > 20 {
                return token
            }
            for child in fields.values {
                if let token = nextCommentContinuation(in: child) { return token }
            }
        case .array(let items):
            for item in items {
                if let token = nextCommentContinuation(in: item) { return token }
            }
        default:
            break
        }
        return nil
    }

    private static func collectValues(_ value: JSONValue, key: String, into found: inout [JSONValue]) {
        switch value {
        case .object(let fields):
            if let child = fields[key] { found.append(child) }
            for child in fields.values { collectValues(child, key: key, into: &found) }
        case .array(let items):
            for item in items { collectValues(item, key: key, into: &found) }
        default:
            break
        }
    }

    private static func indexCommentEntities(_ value: JSONValue, into index: inout [String: JSONValue]) {
        switch value {
        case .object(let fields):
            if let payload = fields["commentEntityPayload"] {
                rememberComment(payload, into: &index)
            }
            for child in fields.values { indexCommentEntities(child, into: &index) }
        case .array(let items):
            for item in items { indexCommentEntities(item, into: &index) }
        default:
            break
        }
    }

    private static func rememberComment(_ payload: JSONValue, into index: inout [String: JSONValue]) {
        guard case .object(let fields) = payload else { return }
        if let key = text(fields["key"]) { index[key] = payload }
        if case .object(let properties) = fields["properties"], let id = text(properties["commentId"]) {
            index[id] = payload
        }
    }

    private static func appendThreads(
        _ value: JSONValue,
        entities: [String: JSONValue],
        into comments: inout [YTComment],
        seen: inout Set<String>,
        replyTokens: inout [String: String]
    ) {
        switch value {
        case .object(let fields):
            if case .object(let thread) = fields["commentThreadRenderer"],
               let comment = makeComment(thread: thread, entities: entities),
               seen.insert(comment.id).inserted {
                comments.append(comment)
                // "View replies" keeps its own continuation inside the thread.
                if case .object(let replies) = thread["replies"],
                   let token = continuationToken(in: .object(replies)) {
                    replyTokens[comment.id] = token
                }
            }
            for child in fields.values {
                appendThreads(child, entities: entities, into: &comments, seen: &seen, replyTokens: &replyTokens)
            }
        case .array(let items):
            for item in items {
                appendThreads(item, entities: entities, into: &comments, seen: &seen, replyTokens: &replyTokens)
            }
        default:
            break
        }
    }

    private static func makeComment(thread: [String: JSONValue], entities: [String: JSONValue]) -> YTComment? {
        let root = JSONValue.object(thread)
        let key = firstString(root, key: "commentKey")
        let fallbackID = firstString(root, key: "commentId")
        if let entity = key.flatMap({ entities[$0] }) ?? fallbackID.flatMap({ entities[$0] }),
           let comment = comment(fromEntity: entity) {
            return comment
        }
        if let renderer = firstObject(root, key: "commentRenderer") {
            return comment(fromRenderer: renderer)
        }
        return nil
    }

    private static func comment(fromEntity entity: JSONValue) -> YTComment? {
        guard case .object(let fields) = entity else { return nil }
        guard case .object(let properties) = fields["properties"] else { return nil }
        let id = text(properties["commentId"]) ?? text(fields["key"])
        let body = text(properties["content"]) ?? ""
        guard let id, !body.isEmpty else { return nil }
        let authorFields: [String: JSONValue]
        if case .object(let author) = fields["author"] {
            authorFields = author
        } else {
            authorFields = [:]
        }
        let toolbar: [String: JSONValue]
        if case .object(let bar) = fields["toolbar"] {
            toolbar = bar
        } else {
            toolbar = [:]
        }
        let name = text(authorFields["displayName"]) ?? "YouTube"
        let channelID = text(authorFields["channelId"])
        let avatar = TubeImage.url(text(authorFields["avatarThumbnailUrl"]))
        return YTComment(
            id: id,
            author: name,
            avatar: avatar,
            channelID: channelID,
            text: body,
            likes: stringish(toolbar["likeCountNotliked"]),
            published: text(properties["publishedTime"]),
            replyCount: wholeNumber(toolbar["replyCount"])
        )
    }

    private static func comment(fromRenderer fields: [String: JSONValue]) -> YTComment? {
        guard let id = text(fields["commentId"]) else { return nil }
        let body = text(fields["contentText"]) ?? ""
        guard !body.isEmpty else { return nil }
        var replies: [YTComment] = []
        if let replyBlock = firstObject(.object(fields), key: "commentRepliesRenderer")
            ?? nestedReplies(in: fields) {
            var seen = Set<String>()
            appendRendererReplies(JSONValue.object(replyBlock), into: &replies, seen: &seen)
        }
        return YTComment(
            id: id,
            author: text(fields["authorText"]) ?? "YouTube",
            avatar: thumbnail(in: fields),
            channelID: firstChannelID(in: fields["authorEndpoint"]),
            text: body,
            likes: text(fields["voteCount"]),
            published: text(fields["publishedTimeText"]),
            replyCount: wholeNumber(fields["replyCount"]),
            replies: replies
        )
    }

    private static func nestedReplies(in fields: [String: JSONValue]) -> [String: JSONValue]? {
        guard case .object(let replies) = fields["replies"] else { return nil }
        return replies
    }

    private static func appendRendererReplies(_ value: JSONValue, into replies: inout [YTComment], seen: inout Set<String>) {
        switch value {
        case .object(let fields):
            if let renderer = fields["commentRenderer"], case .object(let commentFields) = renderer,
               let comment = comment(fromRenderer: commentFields), seen.insert(comment.id).inserted {
                replies.append(comment)
            }
            for (key, child) in fields where key != "commentRenderer" {
                appendRendererReplies(child, into: &replies, seen: &seen)
            }
        case .array(let items):
            for item in items { appendRendererReplies(item, into: &replies, seen: &seen) }
        default:
            break
        }
    }

    private static func firstString(_ value: JSONValue, key: String) -> String? {
        guard let found = firstValue(value, key: key) else { return nil }
        return text(found)
    }

    private static func stringish(_ value: JSONValue?) -> String? {
        if let text = text(value) { return text }
        if case .number(let number) = value {
            if number.rounded() == number { return String(Int(number)) }
            return String(number)
        }
        return nil
    }

    private static func wholeNumber(_ value: JSONValue?) -> Int {
        switch value {
        case .number(let number):
            return Int(number)
        case .string(let string):
            return Int(string) ?? 0
        case .object:
            if let string = text(value), let number = Int(string) { return number }
            return 0
        default:
            return 0
        }
    }

    private static func collect(_ value: JSONValue) -> [YTVideo] {
        var ordered: [YTVideo] = []
        var index: [String: Int] = [:]
        walk(value, into: &ordered, index: &index)
        return ordered
    }

    private static func walk(_ value: JSONValue, into ordered: inout [YTVideo], index: inout [String: Int]) {
        guard case .object(let object) = value else {
            if case .array(let items) = value {
                for item in items { walk(item, into: &ordered, index: &index) }
            }
            return
        }
        if let video = video(from: object) {
            consider(video, into: &ordered, index: &index)
        }
        let skipped: Set<String> = ["adSlotRenderer", "adBreakServiceRenderer", "playerAds", "adPlacements"]
        for (key, child) in object where !skipped.contains(key) {
            walk(child, into: &ordered, index: &index)
        }
    }

    private static func consider(_ video: YTVideo, into ordered: inout [YTVideo], index: inout [String: Int]) {
        if let existing = index[video.id] {
            if ordered[existing].title == "Video", video.title != "Video" {
                ordered[existing].title = video.title
            }
            if ordered[existing].channel.isEmpty {
                ordered[existing].channel = video.channel
            }
            if ordered[existing].thumbnail == nil {
                ordered[existing].thumbnail = video.thumbnail
            }
            if ordered[existing].published == nil {
                ordered[existing].published = video.published
            }
            if ordered[existing].views == nil {
                ordered[existing].views = video.views
            }
            if ordered[existing].length == nil {
                ordered[existing].length = video.length
            }
            if ordered[existing].channelAvatar == nil {
                ordered[existing].channelAvatar = video.channelAvatar
            }
            if ordered[existing].channelID == nil {
                ordered[existing].channelID = video.channelID
            }
            if video.isShort {
                ordered[existing].isShort = true
            }
            return
        }
        guard ordered.count < 80 else { return }
        index[video.id] = ordered.count
        ordered.append(video)
    }

    private static func video(from object: [String: JSONValue]) -> YTVideo? {
        if let kind = text(object["contentType"])?.uppercased(), kind.contains("PLAYLIST") || kind.contains("MIX") {
            return nil
        }
        guard let id = videoID(in: object) else { return nil }
        let looksLikeCard = object["metadata"] != nil || object["videoId"] != nil || object["contentId"] != nil || object["entityId"] != nil || object["headline"] != nil || object["overlayMetadata"] != nil
        guard looksLikeCard else { return nil }
        let lockup = lockupMeta(in: object)
        let title = text(object["title"])
            ?? text(dig(object, ["metadata", "tileMetadataRenderer", "title"]))
            ?? text(dig(object, ["metadata", "lockupMetadataViewModel", "title"]))
            ?? text(object["headline"])
            ?? text(dig(object, ["overlayMetadata", "primaryText"]))
            ?? ""
        // A bare endpoint has an id and no title. The TV shelf keeps the title on the tile.
        guard !title.isEmpty else { return nil }
        let lines = tileMeta(in: object)
        let channel = text(object["ownerText"])
            ?? text(object["longBylineText"])
            ?? text(object["shortBylineText"])
            ?? text(dig(object, ["overlayMetadata", "secondaryText"]))
            ?? text(dig(object, ["owner", "videoOwnerRenderer", "title"]))
            ?? lines.channel
            ?? lockup.channel
            ?? ""
        let published = text(object["publishedTimeText"]) ?? text(object["publishedTime"]) ?? lines.published ?? lockup.published
        let views = text(object["shortViewCountText"]) ?? text(object["viewCountText"]) ?? lines.views ?? lockup.views
        let thumbnail = thumbnail(in: object) ?? tileThumbnail(in: object)
        return YTVideo(
            id: id,
            title: title,
            channel: channel,
            thumbnail: thumbnail,
            published: published,
            views: views,
            length: lengthText(in: object),
            channelAvatar: channelAvatar(in: object),
            channelID: channelID(in: object),
            isShort: marksShort(object)
        )
    }

    private static func videoID(in object: [String: JSONValue]) -> String? {
        if let id = text(object["videoId"]), YTVideo.isVideoID(id) { return id }
        if let id = text(object["contentId"]), YTVideo.isVideoID(id) { return id }
        let paths = [
            ["reelWatchEndpoint", "videoId"],
            ["watchEndpoint", "videoId"],
            ["navigationEndpoint", "watchEndpoint", "videoId"],
            ["navigationEndpoint", "reelWatchEndpoint", "videoId"],
            ["onSelectCommand", "watchEndpoint", "videoId"],
            ["onSelectCommand", "reelWatchEndpoint", "videoId"],
            ["onTap", "innertubeCommand", "reelWatchEndpoint", "videoId"],
            ["onTap", "innertubeCommand", "watchEndpoint", "videoId"],
        ]
        for path in paths {
            if let id = text(dig(object, path)), YTVideo.isVideoID(id) { return id }
        }
        if let entity = text(object["entityId"]), entity.hasPrefix("shorts-shelf-item-") {
            let suffix = String(entity.dropFirst("shorts-shelf-item-".count))
            if YTVideo.isVideoID(suffix) { return suffix }
        }
        return nil
    }

    /// A TV tile puts the channel on the first line and "views • time" on the next.
    private struct TileMeta {
        var channel: String?
        var views: String?
        var published: String?
    }

    private static func tileMeta(in object: [String: JSONValue]) -> TileMeta {
        guard case .array(let lines) = dig(object, ["metadata", "tileMetadataRenderer", "lines"]) else {
            return TileMeta()
        }
        var texts: [String] = []
        for line in lines {
            texts.append(contentsOf: lineTexts(line))
        }
        var meta = TileMeta()
        for (offset, item) in texts.enumerated() where !isSeparator(item) {
            if isViewCount(item) {
                if meta.views == nil { meta.views = item }
            } else if isPublished(item) {
                if meta.published == nil { meta.published = item }
            } else if meta.channel == nil, offset == 0 || meta.views == nil {
                meta.channel = item
            } else if meta.published == nil {
                meta.published = item
            }
        }
        return meta
    }

    private struct LockupMeta {
        var channel: String?
        var views: String?
        var published: String?
    }

    private static func lockupMeta(in object: [String: JSONValue]) -> LockupMeta {
        guard case .array(let rows) = dig(object, ["metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows"]) else {
            return LockupMeta()
        }
        var meta = LockupMeta()
        for row in rows {
            guard case .object(let rowObject) = row, case .array(let parts) = rowObject["metadataParts"] else { continue }
            for part in parts {
                guard case .object(let fields) = part, let value = text(fields["text"]) else { continue }
                if isViewCount(value) {
                    if meta.views == nil { meta.views = value }
                } else if isPublished(value) {
                    if meta.published == nil { meta.published = value }
                } else if meta.channel == nil {
                    meta.channel = value
                }
            }
        }
        return meta
    }

    private static func lineTexts(_ value: JSONValue) -> [String] {
        guard case .object(let lineObject) = value,
              case .object(let renderer) = lineObject["lineRenderer"],
              case .array(let items) = renderer["items"]
        else { return [] }
        var found: [String] = []
        for item in items {
            guard case .object(let fields) = item,
                  case .object(let lineItem) = fields["lineItemRenderer"],
                  let text = text(lineItem["text"])
            else { continue }
            found.append(text)
        }
        return found
    }

    private static func isSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.allSatisfy { "•·|/-–—".contains($0) }
    }

    private static func isViewCount(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("views") || lower.hasSuffix(" view") || lower == "view"
    }

    private static func isPublished(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("ago") || lower == "today" || lower == "yesterday" { return true }
        if lower.hasPrefix("streamed") || lower.hasPrefix("premier") || lower.hasPrefix("scheduled") { return true }
        return false
    }

    private static func lengthText(in object: [String: JSONValue]) -> String? {
        if let direct = cleanLength(text(object["lengthText"])) { return direct }
        if let badge = overlayLength(object["thumbnailOverlays"]) { return badge }
        if case .object(let header) = dig(object, ["header", "tileHeaderRenderer"]) {
            if let badge = overlayLength(header["thumbnailOverlays"]) ?? overlayLength(header["overlays"]) {
                return badge
            }
        }
        if let badge = overlayLength(object["contentImage"]) { return badge }
        return nil
    }

    /// Duration badges are timestamps or LIVE. Mix and Shorts labels are not lengths.
    private static func cleanLength(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.compare("LIVE", options: .caseInsensitive) == .orderedSame { return "LIVE" }
        let parts = raw.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy(\.isNumber) }) else { return nil }
        return raw
    }

    private static func overlayLength(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .array(let items):
            for item in items {
                if let found = overlayLength(item) { return found }
            }
            return nil
        case .object(let fields):
            if case .object(let renderer) = fields["thumbnailOverlayTimeStatusRenderer"],
               let length = cleanLength(text(renderer["text"])) {
                return length
            }
            if case .object(let badge) = fields["thumbnailBadgeViewModel"],
               let length = cleanLength(text(badge["text"])) {
                return length
            }
            for child in fields.values {
                if let found = overlayLength(child) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private static func marksShort(_ object: [String: JSONValue]) -> Bool {
        if dig(object, ["reelWatchEndpoint"]) != nil { return true }
        if dig(object, ["navigationEndpoint", "reelWatchEndpoint"]) != nil { return true }
        if dig(object, ["onSelectCommand", "reelWatchEndpoint"]) != nil { return true }
        if dig(object, ["onTap", "innertubeCommand", "reelWatchEndpoint"]) != nil { return true }
        if overlayIsShort(object["thumbnailOverlays"]) { return true }
        if case .object(let header) = dig(object, ["header", "tileHeaderRenderer"]),
           overlayIsShort(header["thumbnailOverlays"]) {
            return true
        }
        if let kind = text(object["contentType"])?.uppercased(), kind.contains("SHORT") { return true }
        if let entity = text(object["entityId"]), entity.hasPrefix("shorts-shelf-item-") { return true }
        return false
    }

    private static func overlayIsShort(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .array(let items):
            return items.contains { overlayIsShort($0) }
        case .object(let fields):
            if case .object(let renderer) = fields["thumbnailOverlayTimeStatusRenderer"],
               text(renderer["style"])?.caseInsensitiveCompare("SHORTS") == .orderedSame {
                return true
            }
            return fields.values.contains { overlayIsShort($0) }
        default:
            return false
        }
    }

    private static func channelAvatar(in object: [String: JSONValue]) -> URL? {
        if case .object(let owner) = dig(object, ["owner", "videoOwnerRenderer"]),
           let url = thumbnail(in: owner) {
            return url
        }
        let nodes: [JSONValue?] = [
            dig(object, ["channelThumbnailSupportedRenderers", "channelThumbnailWithLinkRenderer"]),
            object["avatar"],
            dig(object, ["metadata", "lockupMetadataViewModel", "image"]),
        ]
        for node in nodes {
            guard case .object(let fields) = node else { continue }
            if let url = thumbnail(in: fields) ?? thumbnail(in: ["thumbnail": node ?? .null]) {
                return url
            }
        }
        return nil
    }

    private static func channelID(in object: [String: JSONValue]) -> String? {
        let nodes: [JSONValue?] = [
            object["shortBylineText"],
            object["longBylineText"],
            object["ownerText"],
            object["owner"],
            object["navigationEndpoint"],
            object["metadata"],
            object["header"],
        ]
        for node in nodes {
            if let id = firstChannelID(in: node) { return id }
        }
        return nil
    }

    private static func firstChannelID(in value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .object(let fields):
            if let id = text(dig(fields, ["browseEndpoint", "browseId"])), id.hasPrefix("UC") { return id }
            if let id = text(fields["channelId"]), id.hasPrefix("UC") { return id }
            if let id = text(fields["browseId"]), id.hasPrefix("UC") { return id }
            for child in fields.values {
                if let found = firstChannelID(in: child) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = firstChannelID(in: item) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private struct WatchMeta {
        var title = ""
        var channel = ""
        var channelID: String?
        var published: String?
        var views: String?
        var subscribers: String?
        var description: String?
        var handle: String?
        var avatar: URL?
    }

    private static func watchMeta(in value: JSONValue) -> WatchMeta {
        var meta = WatchMeta()
        func walk(_ value: JSONValue) {
            switch value {
            case .array(let items):
                for item in items { walk(item) }
            case .object(let object):
                if case .object(let fields) = object["videoMetadataRenderer"] {
                    if let title = text(fields["title"]), !title.isEmpty { meta.title = title }
                    if let published = text(fields["dateText"]) ?? text(fields["publishedTimeText"]) {
                        meta.published = published
                    }
                    if case .object(let ownerWrap) = fields["owner"],
                       case .object(let owner) = ownerWrap["videoOwnerRenderer"] {
                        if let channel = text(owner["title"]), !channel.isEmpty { meta.channel = channel }
                        if let subscribers = text(owner["subscriberCountText"]) { meta.subscribers = subscribers }
                        if let avatar = thumbnail(in: owner) { meta.avatar = avatar }
                        if let channelID = firstChannelID(in: .object(owner)) { meta.channelID = channelID }
                        if meta.handle == nil { meta.handle = channelHandle(in: .object(owner)) }
                    }
                }
                if case .object(let fields) = object["videoDescriptionHeaderRenderer"] {
                    if meta.views == nil, let views = text(fields["views"]) { meta.views = views }
                    if meta.channel.isEmpty, let channel = text(fields["channel"]), !channel.isEmpty {
                        meta.channel = channel
                    }
                    if meta.handle == nil { meta.handle = channelHandle(in: fields["channelNavigationEndpoint"] ?? .null) }
                    if meta.published == nil, let published = text(fields["publishDate"]) {
                        meta.published = published
                    }
                }
                if case .object(let fields) = object["videoViewCountRenderer"] {
                    if let views = text(fields["shortViewCount"]) ?? text(fields["viewCount"]) {
                        meta.views = views
                    }
                }
                if case .object(let fields) = object["expandableVideoDescriptionBodyRenderer"] {
                    let description = text(fields["attributedDescriptionBodyText"]) ?? text(fields["descriptionBodyText"])
                    if let description, !description.isEmpty {
                        meta.description = description
                    }
                }
                for child in object.values { walk(child) }
            default:
                break
            }
        }
        walk(value)
        return meta
    }

    private static func tileThumbnail(in object: [String: JSONValue]) -> URL? {
        guard case .object(let header) = dig(object, ["header", "tileHeaderRenderer"]) else { return nil }
        return thumbnail(in: header)
    }

    private static func dig(_ object: [String: JSONValue], _ path: [String]) -> JSONValue? {
        var current = JSONValue.object(object)
        for key in path {
            guard case .object(let next) = current, let child = next[key] else { return nil }
            current = child
        }
        return current
    }

    private static func channelHandle(in value: JSONValue) -> String? {
        if let raw = text(firstValue(value, key: "canonicalBaseUrl")), let handle = normalizedHandle(raw) {
            return handle
        }
        return handleURL(in: value)
    }

    private static func handleURL(in value: JSONValue) -> String? {
        switch value {
        case .object(let fields):
            if let raw = text(fields["url"]), let handle = normalizedHandle(raw) { return handle }
            for child in fields.values {
                if let found = handleURL(in: child) { return found }
            }
        case .array(let items):
            for item in items {
                if let found = handleURL(in: item) { return found }
            }
        default:
            break
        }
        return nil
    }

    private static func normalizedHandle(_ raw: String) -> String? {
        guard let at = raw.firstIndex(of: "@") else { return nil }
        var end = raw.index(after: at)
        while end < raw.endIndex {
            let character = raw[end]
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                end = raw.index(after: end)
            } else {
                break
            }
        }
        guard raw.distance(from: at, to: end) > 1 else { return nil }
        return String(raw[at..<end])
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let object):
            if let simple = text(object["simpleText"]) { return simple }
            if let content = text(object["content"]) { return content }
            if case .array(let runs) = object["runs"] {
                let joined = runs.compactMap { run -> String? in
                    guard case .object(let fields) = run else { return nil }
                    return text(fields["text"])
                }.joined()
                return joined.isEmpty ? nil : joined
            }
            return nil
        default:
            return nil
        }
    }

    private static func thumbnail(in object: [String: JSONValue]) -> URL? {
        var best: (url: URL, width: Double)?
        func consider(_ value: JSONValue) {
            switch value {
            case .object(let fields):
                if let url = TubeImage.url(text(fields["url"])) {
                    let width: Double
                    if case .number(let number) = fields["width"] ?? .null {
                        width = number
                    } else {
                        width = 0
                    }
                    if best == nil || width >= (best?.width ?? 0) { best = (url, width) }
                }
                for key in ["thumbnails", "sources", "image", "thumbnailViewModel", "contentImage"] {
                    if let child = fields[key] { consider(child) }
                }
            case .array(let items):
                for item in items { consider(item) }
            default:
                break
            }
        }
        for key in ["thumbnail", "thumbnailViewModel", "contentImage"] {
            if let value = object[key] { consider(value) }
        }
        return best?.url
    }

    /// Direct media for AVPlayer. No embed page and no signature decipher.
    /// ANDROID 20.10.38 returns a 1080p H.264 track plus an AAC track, both as plain
    /// googlevideo files. The muxed 360p file is the fallback. SABR is never returned.
    struct PlayableMedia: Sendable {
        var url: URL
        var audioURL: URL? = nil
        var userAgent: String
        /// Authoritative length from the player response. Split tracks report a
        /// container duration about twice this long; the picture itself is aligned
        /// to this clock, so the player clamps to it.
        var duration: TimeInterval? = nil
        /// Quality tier: the short side, in pixels (1080 for both 1920×1080 and
        /// a 1080×1920 Short). The quality menu compares against this, not the
        /// raw container height.
        var height: Int? = nil
    }

    static func playables(videoID: String, accessToken: String?) async -> [PlayableMedia] {
        guard YTVideo.isVideoID(videoID) else { return [] }
        // The persisted quality cap: 0 = auto. Written by TubeModel.playerQuality.
        let quality = UserDefaults.standard.integer(forKey: "tubeui.quality")
        let maxHeight = quality > 0 ? quality : nil
        let open = await collect(videoID: videoID, accessToken: nil, maxHeight: maxHeight)
        if !open.isEmpty || accessToken == nil { return open }
        return await collect(videoID: videoID, accessToken: accessToken, maxHeight: maxHeight)
    }

    private enum PlaybackKind: Sendable {
        case android
        case vision
        case vr
        case ios
    }

    private static func collect(videoID: String, accessToken: String?, maxHeight: Int?) async -> [PlayableMedia] {
        async let android = playback(videoID: videoID, kind: .android, accessToken: accessToken, maxHeight: maxHeight)
        async let vision = playback(videoID: videoID, kind: .vision, accessToken: accessToken, maxHeight: maxHeight)
        async let vr = playback(videoID: videoID, kind: .vr, accessToken: accessToken, maxHeight: maxHeight)
        async let ios = playback(videoID: videoID, kind: .ios, accessToken: accessToken, maxHeight: maxHeight)
        return await android + vision + vr + ios
    }

    private static func playback(videoID: String, kind: PlaybackKind, accessToken: String?, maxHeight: Int?) async -> [PlayableMedia] {
        let webKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        let androidKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
        let iosKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
        let headerName: String
        let version: String
        let userAgent: String
        let apiKey: String
        let fields: [String: Any]
        switch kind {
        case .android:
            // 20.10.38 still returns plain googlevideo URLs: a muxed 360p file and
            // separate H.264 / AAC tracks up to 4K. Newer clients answer with SABR.
            headerName = "3"
            version = "20.10.38"
            userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
            apiKey = androidKey
            fields = [
                "clientName": "ANDROID",
                "clientVersion": version,
                "androidSdkVersion": 34,
                "osName": "Android",
                "osVersion": "14",
                "hl": "en",
                "gl": "US",
            ]
        case .vision:
            headerName = "101"
            version = "1.02"
            userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            apiKey = webKey
            fields = [
                "clientName": "VISIONOS",
                "clientVersion": version,
                "deviceMake": "Apple",
                "deviceModel": "RealityDevice17,1",
                "osName": "visionOS",
                "osVersion": "26.5.23O471",
                "hl": "en",
                "gl": "US",
            ]
        case .vr:
            headerName = "28"
            version = "1.62.27"
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
            apiKey = androidKey
            fields = [
                "clientName": "ANDROID_VR",
                "clientVersion": version,
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
                "hl": "en",
                "gl": "US",
            ]
        case .ios:
            headerName = "5"
            version = "21.26.4"
            userAgent = "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
            apiKey = iosKey
            fields = [
                "clientName": "IOS",
                "clientVersion": version,
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82",
                "hl": "en",
                "gl": "US",
            ]
        }
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false") else {
            return []
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "context": ["client": fields],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = payload
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streaming = root["streamingData"] as? [String: Any]
        else { return [] }
        return selectStreams(streaming: streaming, userAgent: userAgent, duration: lengthSeconds(in: root), maxHeight: maxHeight)
    }

    /// Adaptive H.264 + AAC when a pair fits the cap (tallest first), then the muxed
    /// file, then HLS. Never a video-only URL on its own.
    static func selectStreams(
        streaming: [String: Any],
        userAgent: String,
        duration: TimeInterval?,
        maxHeight: Int? = nil
    ) -> [PlayableMedia] {
        var results: [PlayableMedia] = []
        if let video = adaptiveVideoURL(in: streaming, maxHeight: maxHeight), let audio = adaptiveAudioURL(in: streaming) {
            results.append(PlayableMedia(url: video.url, audioURL: audio, userAgent: userAgent, duration: duration, height: video.height))
        }
        if let progressive = progressiveURL(in: streaming) {
            results.append(PlayableMedia(url: progressive.url, audioURL: nil, userAgent: userAgent, duration: duration, height: progressive.height))
        }
        if let manifest = manifestURL(in: streaming) {
            results.append(PlayableMedia(url: manifest, audioURL: nil, userAgent: userAgent, duration: duration))
        }
        return results
    }

    /// Index of the stream to start with. A height-less entry is an HLS manifest:
    /// it includes audio and the ladder up to 1080, which AVPlayer can cap.
    /// The direct files are the fallback — the only muxed one is usually 360p.
    /// When no manifest exists, this is the tallest file at or under the cap.
    /// `cap == 0` is Auto and still stops at 1080.
    static func preferredPlayableIndex(_ heights: [Int?], cap: Int) -> Int {
        if let manifest = heights.firstIndex(where: { $0 == nil }) {
            return manifest
        }
        let limit = cap > 0 ? cap : 1080
        var bestIndex: Int?
        var bestHeight = 0
        for (index, height) in heights.enumerated() {
            guard let height, height > 0, height <= limit, height > bestHeight else { continue }
            bestHeight = height
            bestIndex = index
        }
        if let bestIndex { return bestIndex }
        return 0
    }

    private static func lengthSeconds(in root: [String: Any]) -> TimeInterval? {
        guard let details = root["videoDetails"] as? [String: Any] else { return nil }
        let raw: String?
        if let text = details["lengthSeconds"] as? String {
            raw = text
        } else if let number = details["lengthSeconds"] as? NSNumber {
            raw = number.stringValue
        } else {
            raw = nil
        }
        guard let raw, let value = TimeInterval(raw), value > 0, value < 86_400 else { return nil }
        return value
    }

    private static func manifestURL(in streaming: [String: Any]) -> URL? {
        guard let raw = streaming["hlsManifestUrl"] as? String else { return nil }
        return streamURL(raw)
    }

    /// Progressive files already contain picture and audio. Adaptive itags are one or the other.
    private static func progressiveURL(in streaming: [String: Any]) -> (url: URL, height: Int)? {
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        var best: (height: Int, bitrate: Int, url: URL)?
        for format in formats {
            guard let mime = (format["mimeType"] as? String)?.lowercased(), mime.contains("video/") else { continue }
            guard mime.contains("mp4a") || mime.contains("opus") || mime.contains("vorbis") else { continue }
            guard format["signatureCipher"] == nil, format["cipher"] == nil else { continue }
            guard let raw = format["url"] as? String, let url = streamURL(raw) else { continue }
            let height = (format["height"] as? NSNumber)?.intValue ?? 0
            let bitrate = (format["bitrate"] as? NSNumber)?.intValue ?? 0
            if best == nil || height > best!.height || (height == best!.height && bitrate > best!.bitrate) {
                best = (height, bitrate, url)
            }
        }
        guard let best else { return nil }
        return (best.url, best.height > 0 ? best.height : 0)
    }

    /// Tallest H.264 rendition under the cap, including portrait Shorts. The quality
    /// tier is the short side (1080 for both 1920x1080 and 1080x1920).
    private static func adaptiveVideoURL(in streaming: [String: Any], maxHeight: Int?) -> (url: URL, height: Int)? {
        let formats = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let cap = (maxHeight ?? 0) > 0 ? maxHeight! : 1080
        var best: (shortSide: Int, bitrate: Int, url: URL, height: Int)?
        for format in formats {
            guard let mime = (format["mimeType"] as? String)?.lowercased(), mime.contains("video/mp4"), mime.contains("avc1") else { continue }
            guard format["signatureCipher"] == nil, format["cipher"] == nil else { continue }
            guard let raw = format["url"] as? String, let url = streamURL(raw) else { continue }
            let width = (format["width"] as? NSNumber)?.intValue ?? 0
            let height = (format["height"] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0 else { continue }
            let longSide = max(width, height)
            let shortSide = min(width, height)
            guard longSide <= 1920, shortSide <= cap else { continue }
            let bitrate = (format["bitrate"] as? NSNumber)?.intValue ?? 0
            if best == nil || shortSide > best!.shortSide || (shortSide == best!.shortSide && bitrate > best!.bitrate) {
                best = (shortSide, bitrate, url, height)
            }
        }
        guard let best else { return nil }
        return (best.url, best.shortSide)
    }

    /// AAC, not Opus. AVPlayer can attach this beside the H.264 track.
    private static func adaptiveAudioURL(in streaming: [String: Any]) -> URL? {
        let formats = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        var best: (bitrate: Int, url: URL)?
        for format in formats {
            guard let mime = (format["mimeType"] as? String)?.lowercased() else { continue }
            guard mime.contains("mp4a"), mime.contains("audio/") else { continue }
            guard format["signatureCipher"] == nil, format["cipher"] == nil else { continue }
            guard let raw = format["url"] as? String, let url = streamURL(raw) else { continue }
            let bitrate = (format["bitrate"] as? NSNumber)?.intValue ?? 0
            if best == nil || bitrate > best!.bitrate {
                best = (bitrate, url)
            }
        }
        return best?.url
    }

    private static func streamURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        guard host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return nil }
        return url
    }

    /// Signed-in Home. One browse, then continuation pages while `deep`.
    /// Chip loads pass `deep: false` so switching tags costs one request.
    static func home(
        accessToken: String,
        browseID: String = "FEwhat_to_watch",
        params: String? = nil,
        continuation: String? = nil,
        deep: Bool = true
    ) async throws -> HomeFeed {
        let payload: [String: Any]
        if let continuation {
            payload = ["continuation": continuation]
        } else {
            var body: [String: Any] = ["browseId": browseID]
            if let params, !params.isEmpty { body["params"] = params }
            payload = body
        }
        let data = try await request(path: "browse", payload: payload, accessToken: accessToken)
        var feed = try home(in: data)
        var pages = 0
        while deep, let token = feed.continuation, feed.regularCount < HomeFeed.maxRegularVideos, pages < 4 {
            pages += 1
            let before = feed.regularCount
            do {
                let moreData = try await request(path: "browse", payload: ["continuation": token], accessToken: accessToken)
                feed = feed.appendingContinuation(try home(in: moreData))
            } catch {
                feed.capped = true
                feed.continuation = nil
                break
            }
            if feed.regularCount <= before {
                break
            }
        }
        return feed
    }

    static func searchVideos(query: String, accessToken: String) async throws -> [YTVideo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await request(
            path: "search",
            payload: ["query": trimmed, "params": "EgIQAQ=="],
            accessToken: accessToken
        )
        return try videos(in: data)
    }

    /// Real YouTube search: videos plus channels and playlists.
    static func search(query: String, accessToken: String?) async throws -> SearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchPage() }
        let data = try await request(path: "search", payload: ["query": trimmed], accessToken: accessToken ?? "")
        return try searchPage(in: data)
    }

    static func searchMore(continuation: String, accessToken: String?) async throws -> SearchPage {
        let data = try await request(path: "search", payload: ["continuation": continuation], accessToken: accessToken ?? "")
        return try searchPage(in: data)
    }

    static func searchPage(in data: Data) throws -> SearchPage {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        return SearchPage(
            videos: collect(root),
            channels: searchChannels(in: root),
            playlists: searchPlaylists(in: root),
            continuation: feedContinuation(in: root)
        )
    }

    private static func searchChannels(in root: JSONValue) -> [YTChannel] {
        var renderers: [JSONValue] = []
        collectValues(root, key: "channelRenderer", into: &renderers)
        var channels: [YTChannel] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard case .object(let fields) = renderer else { continue }
            guard let id = text(fields["channelId"]) ?? text(dig(fields, ["navigationEndpoint", "browseEndpoint", "browseId"])),
                  id.hasPrefix("UC"),
                  seen.insert(id).inserted,
                  let title = text(fields["title"]) ?? text(fields["displayName"])
            else { continue }
            var custom = text(dig(fields, ["navigationEndpoint", "browseEndpoint", "canonicalBaseUrl"]))
            if let base = custom, base.hasPrefix("/") { custom = String(base.dropFirst()) }
            let image = thumbnail(in: fields).map { YTImage(url: $0.absoluteString) }
            channels.append(YTChannel(
                id: id,
                snippet: .init(title: title, customUrl: custom, thumbnails: image.map { YTThumbnails(url: URL(string: $0.url)) }),
                statistics: nil,
                brandingSettings: nil
            ))
        }
        return channels
    }

    private static func searchPlaylists(in root: JSONValue) -> [YTPlaylist] {
        var renderers: [JSONValue] = []
        collectValues(root, key: "playlistRenderer", into: &renderers)
        collectValues(root, key: "lockupViewModel", into: &renderers)
        var playlists: [YTPlaylist] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard case .object(let fields) = renderer else { continue }
            let isLockup = text(fields["contentType"])?.uppercased().contains("PLAYLIST") ?? false
            guard isLockup || fields["playlistId"] != nil else { continue }
            guard let id = text(fields["playlistId"]) ?? text(fields["contentId"]),
                  id.hasPrefix("PL") || id.hasPrefix("OL") || id.hasPrefix("WL"),
                  seen.insert(id).inserted,
                  let title = text(fields["title"]) ?? text(dig(fields, ["metadata", "lockupMetadataViewModel", "title"]))
            else { continue }
            let image = thumbnail(in: fields).map { YTImage(url: $0.absoluteString) }
            let countText = text(fields["videoCountText"]) ?? lockupCountText(fields)
            playlists.append(YTPlaylist(
                id: id,
                snippet: .init(title: title, thumbnails: image.map { YTThumbnails(url: URL(string: $0.url)) }),
                contentDetails: .init(itemCount: leadingNumber(countText))
            ))
        }
        return playlists
    }

    /// The "50 videos" line of a lockup playlist card, if YouTube sent one.
    private static func lockupCountText(_ fields: [String: JSONValue]) -> String? {
        guard case .array(let rows) = dig(fields, ["metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows"]) else {
            return nil
        }
        for row in rows {
            guard case .object(let rowObject) = row, case .array(let parts) = rowObject["metadataParts"] else { continue }
            for part in parts {
                guard case .object(let partFields) = part,
                      let value = text(partFields["text"]),
                      value.lowercased().contains("video")
                else { continue }
                return value
            }
        }
        return nil
    }

    /// First integer in a display string like "50 videos" or "Last updated on 50 videos".
    private static func leadingNumber(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// The page-load-more token that trails a feed list.
    private static func feedContinuation(in root: JSONValue) -> String? {
        guard let renderer = firstValue(root, key: "continuationItemRenderer") else { return nil }
        return commandToken(in: renderer)
    }

    /// Remaining replies for one comment thread, keyed by the thread's reply continuation.
    static func commentReplies(continuation: String, accessToken: String?) async throws -> [YTComment] {
        do {
            return try await fetchReplies(continuation, accessToken: nil)
        } catch {
            guard let accessToken, !accessToken.isEmpty else { throw error }
            return try await fetchReplies(continuation, accessToken: accessToken)
        }
    }

    private static func fetchReplies(_ token: String, accessToken: String?) async throws -> [YTComment] {
        let data = try await perform(
            path: "next",
            payload: ["continuation": token],
            accessToken: accessToken,
            client: webCommentsClient
        )
        return try replies(in: data)
    }

    static func replies(in data: Data) throws -> [YTComment] {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        var payloads: [JSONValue] = []
        collectValues(root, key: "commentEntityPayload", into: &payloads)
        var comments: [YTComment] = []
        var seen = Set<String>()
        for payload in payloads {
            guard let comment = comment(fromEntity: payload), seen.insert(comment.id).inserted else { continue }
            comments.append(comment)
        }
        if comments.isEmpty {
            comments = assembledComments(in: root).comments
        }
        return comments
    }

    /// A saved playlist through the internal browse API, which does return Watch Later and Liked.
    static func playlist(browseID: String, accessToken: String, continuation: String? = nil) async throws -> PlaylistBrowse {
        let payload: [String: Any] = continuation.map { ["continuation": $0] } ?? ["browseId": browseID]
        let data = try await request(path: "browse", payload: payload, accessToken: accessToken)
        return try playlistPage(in: data)
    }

    static func playlistPage(in data: Data) throws -> PlaylistBrowse {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        var browse = PlaylistBrowse(
            videos: playlistVideos(in: root),
            meta: playlistMeta(in: root),
            continuation: feedContinuation(in: root)
        )
        if browse.videos.isEmpty {
            // Some clients draw saved playlists as ordinary cards; the generic walker reads those.
            browse.videos = collect(root)
        }
        return browse
    }

    private static func playlistVideos(in root: JSONValue) -> [YTVideo] {
        var renderers: [JSONValue] = []
        collectValues(root, key: "playlistVideoRenderer", into: &renderers)
        var videos: [YTVideo] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard case .object(let fields) = renderer,
                  let id = text(fields["videoId"]),
                  YTVideo.isVideoID(id),
                  seen.insert(id).inserted
            else { continue }
            let title = text(fields["title"]) ?? ""
            guard !title.isEmpty else { continue }
            var views: String?
            var published: String?
            if case .array(let runs) = dig(fields, ["videoInfo", "runs"]) {
                for run in runs {
                    guard case .object(let runFields) = run, let line = text(runFields["text"]) else { continue }
                    if views == nil, isViewCount(line) { views = line }
                    if published == nil, isPublished(line) { published = line }
                }
            }
            videos.append(YTVideo(
                id: id,
                title: title,
                channel: text(fields["authorText"]) ?? text(dig(fields, ["shortBylineText"])) ?? "",
                thumbnail: thumbnail(in: fields),
                published: published,
                views: views,
                channelID: firstChannelID(in: fields["shortBylineText"])
            ))
        }
        return videos
    }

    private static func playlistMeta(in root: JSONValue) -> PlaylistMeta? {
        if let header = firstObject(root, key: "playlistHeaderRenderer") {
            let title = text(header["title"]) ?? ""
            let owner = text(header["ownerText"]) ?? text(dig(header, ["owner", "videoOwnerRenderer", "title"]))
            let count = leadingNumber(text(header["numVideosText"]))
            let updated = text(header["publishedTimeText"]) ?? text(header["updatedTimeText"])
            guard !title.isEmpty || owner != nil || count != nil || updated != nil else { return nil }
            return PlaylistMeta(title: title, owner: owner, count: count ?? 0, updated: updated)
        }
        if let header = firstObject(root, key: "pageHeaderRenderer") {
            let title = text(header["pageTitle"]) ?? text(dig(header, ["metadata", "pageHeaderViewModel", "title"]))
            var owner: String?
            var updated: String?
            var count: Int?
            if case .array(let rows) = dig(header, ["metadata", "pageHeaderViewModel", "metadata", "contentMetadataViewModel", "metadataRows"]) {
                for row in rows {
                    guard case .object(let rowObject) = row, case .array(let parts) = rowObject["metadataParts"] else { continue }
                    for part in parts {
                        guard case .object(let fields) = part, let value = text(fields["text"]) else { continue }
                        let lower = value.lowercased()
                        if count == nil, lower.contains("video"), let parsed = leadingNumber(value) { count = parsed }
                        if updated == nil, lower.contains("updated") || isPublished(value) { updated = value }
                        if owner == nil, !lower.contains("video"), !lower.contains("updated"), !isViewCount(value), !isPublished(value) {
                            owner = value
                        }
                    }
                }
            }
            guard title != nil || owner != nil || count != nil || updated != nil else { return nil }
            return PlaylistMeta(title: title ?? "", owner: owner, count: count ?? 0, updated: updated)
        }
        return nil
    }

    /// Watch history grouped by day. Groups carry the labels YouTube sent; the walker
    /// takes the smallest node that has both a header title and video cards.
    static func history(accessToken: String, continuation: String? = nil) async throws -> HistoryPage {
        let payload: [String: Any] = continuation.map { ["continuation": $0] } ?? ["browseId": "FEhistory"]
        let data = try await request(path: "browse", payload: payload, accessToken: accessToken)
        return try historyPage(in: data)
    }

    static func historyPage(in data: Data) throws -> HistoryPage {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        var days: [HistoryDay] = []
        collectHistoryDays(root, into: &days)
        if days.isEmpty {
            let videos = collect(root)
            if !videos.isEmpty {
                days = [HistoryDay(id: "recent", label: "Recent", videos: videos)]
            }
        }
        return HistoryPage(days: days, continuation: feedContinuation(in: root))
    }

    private static func collectHistoryDays(_ value: JSONValue, into days: inout [HistoryDay]) {
        switch value {
        case .object(let fields):
            if case .array(let items) = fields["contents"],
               let label = dayHeaderTitle(fields["header"]),
               items.contains(where: looksLikeVideoCard) {
                // A group owns its videos; don't double-count them by walking deeper.
                let videos = collect(.object(fields))
                if !videos.isEmpty {
                    days.append(HistoryDay(id: "\(days.count)-\(label)", label: label, videos: videos))
                    return
                }
            }
            for child in fields.values { collectHistoryDays(child, into: &days) }
        case .array(let items):
            for item in items { collectHistoryDays(item, into: &days) }
        default:
            break
        }
    }

    private static func dayHeaderTitle(_ header: JSONValue?) -> String? {
        guard let title = firstValue(header ?? .null, key: "title"), let label = text(title), !label.isEmpty else { return nil }
        // Day labels are short; a masthead title like the channel name is not one.
        guard label.count < 40 else { return nil }
        return label
    }

    private static func looksLikeVideoCard(_ node: JSONValue) -> Bool {
        switch node {
        case .object(let fields):
            let names = [
                "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "lockupViewModel",
                "reelItemRenderer", "shortsLockupViewModel", "tileRenderer",
            ]
            if fields.keys.contains(where: { names.contains($0) }) { return true }
            return fields.values.contains { looksLikeVideoCard($0) }
        case .array(let items):
            return items.contains { looksLikeVideoCard($0) }
        default:
            return false
        }
    }

    /// The bell menu. Desktop OAuth is rejected there ("Request contains an invalid argument"
    /// on WEB, "Precondition check failed" on TV), so a failed menu falls back to the
    /// subscription shelf, which this sign-in can read.
    static func notifications(accessToken: String) async throws -> [YTNotification] {
        do {
            return try await notificationMenu(accessToken: accessToken)
        } catch {
            // The menu endpoint rejects this desktop sign-in. The subscription shelf does not.
        }
        let videos = try await browse(id: "FEsubscriptions", accessToken: accessToken)
        return videos.prefix(40).map { video in
            YTNotification(
                id: video.id,
                title: video.title,
                channel: video.channel.isEmpty ? nil : video.channel,
                avatarURL: video.channelAvatar,
                thumbnailURL: video.thumbnail,
                time: video.published,
                unread: false,
                videoID: YTVideo.isVideoID(video.id) ? video.id : nil
            )
        }
    }

    private static func notificationMenu(accessToken: String) async throws -> [YTNotification] {
        let data = try await perform(
            path: "notification/get_notification_menu",
            payload: ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"],
            accessToken: accessToken,
            client: webCommentsClient
        )
        return try notifications(in: data)
    }

    static func notifications(in data: Data) throws -> [YTNotification] {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        var renderers: [JSONValue] = []
        collectValues(root, key: "notificationRenderer", into: &renderers)
        var items: [YTNotification] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard case .object(let fields) = renderer else { continue }
            let videoID = text(fields["videoId"]) ?? text(dig(fields, ["navigationEndpoint", "watchEndpoint", "videoId"]))
            let title = text(fields["title"]) ?? text(fields["shortMessage"]) ?? ""
            guard let id = videoID ?? (title.isEmpty ? nil : title), seen.insert(id).inserted else { continue }
            items.append(YTNotification(
                id: id,
                title: title,
                channel: text(fields["author"]),
                avatarURL: thumbnailHolder(fields, keys: ["authorThumbnails", "authorPhoto", "authorThumbnail"]),
                thumbnailURL: thumbnailHolder(fields, keys: ["videoThumbnail", "thumbnail", "thumbnailDetails"]),
                time: text(fields["sentTimeText"]) ?? text(fields["publishedTimeText"]),
                unread: isUnread(fields),
                videoID: videoID
            ))
        }
        return items
    }

    /// A bare thumbnail source list under any of `keys`; `thumbnail(in:)` only looks for named keys.
    private static func thumbnailHolder(_ fields: [String: JSONValue], keys: [String]) -> URL? {
        for key in keys {
            guard let value = fields[key] else { continue }
            if let url = thumbnail(in: [key: value]) {
                return url
            }
            if let url = thumbnail(in: ["thumbnail": value]) {
                return url
            }
        }
        return nil
    }

    /// Popular completions from the public suggest endpoint. History rows are merged in TubeModel.
    static func suggestions(for prefix: String) async -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: trimmed),
        ]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return (try? parseSuggestions(data)) ?? []
        } catch {
            return []
        }
    }

    /// Firefox shape: `["prefix", ["suggestion one", "suggestion two"]]`. The endpoint
    /// answers latin-1, so a failed UTF-8 parse is retried after a re-encode.
    static func parseSuggestions(_ data: Data) throws -> [String] {
        func suggestions(in payload: Data) throws -> [String]? {
            guard let array = try JSONSerialization.jsonObject(with: payload) as? [Any],
                  array.count >= 2,
                  let items = array[1] as? [Any]
            else { return nil }
            return items.compactMap { $0 as? String }
        }
        if let found = try? suggestions(in: data) {
            return found
        }
        let latin = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        return try suggestions(in: Data(latin.utf8)) ?? []
    }

    static func home(in data: Data) throws -> HomeFeed {
        let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
        let chips = homeChips(in: root)
        guard let container = feedContainer(in: root) else {
            var feed = HomeFeed.synthesized(from: collect(root))
            feed.chips = chips
            feed.note = nudgeNote(in: root)
            return feed
        }
        var raw: [HomeRaw] = []
        var continuation = container.continuation
        var note = nudgeNote(in: root)
        func consume(_ item: JSONValue) {
            if let token = continuationItemToken(item) {
                continuation = token
                return
            }
            if isSkippedHomeItem(item) { return }
            if let shelf = shelfEntry(item) {
                raw.append(.shelf(shorts: shelf.shorts, videos: shelf.videos))
                return
            }
            if case .object(let object) = item,
               case .object(let section) = object["itemSectionRenderer"],
               case .array(let contents) = section["contents"] {
                for child in contents { consume(child) }
                return
            }
            if case .object(let object) = item,
               case .object(let grid) = object["gridRenderer"],
               case .array(let items) = grid["items"] {
                for child in items { consume(child) }
                return
            }
            if let video = oneHomeVideo(item) {
                raw.append(.video(video))
            }
        }
        for item in container.items { consume(item) }
        let sawShelf = raw.contains {
            if case .shelf = $0 { return true }
            return false
        }
        if !sawShelf {
            let videos = raw.compactMap { entry -> YTVideo? in
                if case .video(let video) = entry { return video }
                return nil
            }
            var feed = HomeFeed.synthesized(from: videos)
            feed.chips = chips
            feed.continuation = continuation
            feed.note = videos.isEmpty ? note : nil
            return feed
        }
        var blocks: [HomeBlock] = []
        var run: [YTVideo] = []
        var seen = Set<String>()
        var regulars = 0
        var capped = false
        func flush() {
            if !run.isEmpty {
                blocks.append(.videos(run))
                run = []
            }
        }
        for entry in raw {
            switch entry {
            case .video(let video):
                guard seen.insert(video.id).inserted else { continue }
                if video.isShort {
                    flush()
                    blocks.append(.shorts([video]))
                } else if regulars >= HomeFeed.maxRegularVideos {
                    capped = true
                } else {
                    regulars += 1
                    run.append(video)
                }
            case .shelf(let shorts, let videos):
                if shorts {
                    var shelf: [YTVideo] = []
                    for var video in videos {
                        guard seen.insert(video.id).inserted else { continue }
                        video.isShort = true
                        shelf.append(video)
                        if shelf.count == HomeFeed.maxShortsPerShelf { break }
                    }
                    guard !shelf.isEmpty else { continue }
                    flush()
                    blocks.append(.shorts(shelf))
                } else {
                    for video in videos where !video.isShort {
                        guard seen.insert(video.id).inserted else { continue }
                        if regulars >= HomeFeed.maxRegularVideos {
                            capped = true
                            break
                        }
                        regulars += 1
                        run.append(video)
                    }
                }
            }
        }
        flush()
        if blocks.isEmpty {
            note = note ?? nudgeNote(in: root)
        } else {
            note = nil
        }
        return HomeFeed(
            chips: chips,
            blocks: blocks,
            continuation: capped ? nil : continuation,
            capped: capped,
            structured: true,
            note: note
        )
    }

    private enum HomeRaw {
        case video(YTVideo)
        case shelf(shorts: Bool, videos: [YTVideo])
    }

    private struct FeedContainer {
        var items: [JSONValue]
        var continuation: String?
    }

    private static func feedContainer(in root: JSONValue) -> FeedContainer? {
        if let items = actionItems(in: root, name: "reloadContinuationItemsCommand") {
            return FeedContainer(items: items, continuation: nil)
        }
        if let items = actionItems(in: root, name: "appendContinuationItemsAction") {
            return FeedContainer(items: items, continuation: nil)
        }
        if let grid = firstObject(root, key: "richGridRenderer"), case .array(let items) = grid["contents"] {
            return FeedContainer(items: items, continuation: listContinuation(grid["continuations"]))
        }
        let tvPath = [
            "contents", "tvBrowseRenderer", "content", "tvSurfaceContentRenderer", "content", "sectionListRenderer",
        ]
        if let section = object(root, path: tvPath), case .array(let items) = section["contents"] {
            return FeedContainer(items: items, continuation: listContinuation(section["continuations"]))
        }
        if let section = bestSectionList(in: root) {
            return section
        }
        return nil
    }

    private static func actionItems(in root: JSONValue, name: String) -> [JSONValue]? {
        guard case .array(let actions) = firstValue(root, key: "onResponseReceivedActions") else { return nil }
        for action in actions {
            guard case .object(let fields) = action, let command = fields[name] else { continue }
            if case .object(let body) = command, case .array(let items) = body["continuationItems"] {
                return items
            }
        }
        return nil
    }

    private static func bestSectionList(in root: JSONValue) -> FeedContainer? {
        var best: FeedContainer?
        var bestScore = 0
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let object):
                if case .array(let items) = object["contents"], object["targetId"] != nil || object["trackingParams"] != nil {
                    let score = items.reduce(0) { partial, item in
                        guard case .object(let fields) = item else { return partial }
                        let interesting = ["shelfRenderer", "itemSectionRenderer", "richSectionRenderer", "reelShelfRenderer"]
                        return partial + (fields.keys.contains(where: { interesting.contains($0) }) ? 1 : 0)
                    }
                    if score > bestScore {
                        bestScore = score
                        best = FeedContainer(items: items, continuation: listContinuation(object["continuations"]))
                    }
                }
                for child in object.values { walk(child) }
            case .array(let items):
                for item in items { walk(item) }
            default:
                break
            }
        }
        walk(root)
        return bestScore > 0 ? best : nil
    }

    private static func shelfEntry(_ item: JSONValue) -> (shorts: Bool, videos: [YTVideo])? {
        guard case .object(let object) = item else { return nil }
        let shelf: [String: JSONValue]?
        if case .object(let section) = object["richSectionRenderer"],
           case .object(let content) = section["content"] {
            if case .object(let rich) = content["richShelfRenderer"] {
                shelf = rich
            } else if case .object(let reel) = content["reelShelfRenderer"] {
                shelf = reel
            } else {
                shelf = nil
            }
        } else if case .object(let rich) = object["shelfRenderer"] {
            shelf = rich
        } else if case .object(let reel) = object["reelShelfRenderer"] {
            shelf = reel
        } else {
            shelf = nil
        }
        guard let shelf else { return nil }
        let videos = videosInShelf(shelf)
        guard !videos.isEmpty else { return nil }
        return (shelfIsShorts(shelf, videos: videos), videos)
    }

    private static func videosInShelf(_ shelf: [String: JSONValue]) -> [YTVideo] {
        var items: [JSONValue] = []
        if case .array(let contents) = shelf["contents"] { items.append(contentsOf: contents) }
        if case .object(let list) = dig(shelf, ["content", "horizontalListRenderer"]),
           case .array(let rows) = list["items"] {
            items.append(contentsOf: rows)
        }
        if case .object(let expanded) = dig(shelf, ["content", "expandedShelfContentsRenderer"]),
           case .array(let rows) = expanded["items"] {
            items.append(contentsOf: rows)
        }
        return items.compactMap { oneHomeVideo($0) }
    }

    private static func shelfIsShorts(_ shelf: [String: JSONValue], videos: [YTVideo]) -> Bool {
        if let icon = text(dig(shelf, ["icon", "iconType"]))?.uppercased(), icon.contains("SHORT") { return true }
        if text(shelf["title"])?.compare("Shorts", options: .caseInsensitive) == .orderedSame { return true }
        if videos.count >= 2, videos.allSatisfy(\.isShort) { return true }
        return false
    }

    private static func oneHomeVideo(_ item: JSONValue) -> YTVideo? {
        guard case .object(let object) = item else { return nil }
        let keys = [
            "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "tileRenderer",
            "lockupViewModel", "reelItemRenderer", "shortsLockupViewModel",
        ]
        if case .object(let rich) = object["richItemRenderer"] {
            if case .object(let content) = rich["content"] {
                for key in keys {
                    if case .object(let inner) = content[key], var video = video(from: inner) {
                        if key == "reelItemRenderer" || key == "shortsLockupViewModel" { video.isShort = true }
                        return video
                    }
                }
                if var video = video(from: content) {
                    if marksShort(content) { video.isShort = true }
                    return video
                }
            }
            if let video = video(from: rich) { return video }
        }
        for key in keys {
            if case .object(let inner) = object[key], var video = video(from: inner) {
                if key == "reelItemRenderer" || key == "shortsLockupViewModel" { video.isShort = true }
                return video
            }
        }
        guard var video = video(from: object) else { return nil }
        if object["reelItemRenderer"] != nil || object["shortsLockupViewModel"] != nil { video.isShort = true }
        return video
    }

    private static func isSkippedHomeItem(_ item: JSONValue) -> Bool {
        guard case .object(let object) = item else { return false }
        let names = [
            "feedNudgeRenderer", "searchBarRenderer", "adSlotRenderer", "adBreakServiceRenderer",
            "playerAds", "adPlacements", "statementBannerRenderer", "promotedVideoRenderer",
            "displayAdRenderer", "inFeedAdLayoutRenderer",
        ]
        return object.keys.contains(where: { names.contains($0) })
    }

    private static func nudgeNote(in value: JSONValue) -> String? {
        guard let nudge = firstObject(value, key: "feedNudgeRenderer") else { return nil }
        return text(nudge["title"]) ?? text(nudge["subtitle"])
    }

    private static func continuationItemToken(_ item: JSONValue) -> String? {
        guard case .object(let object) = item, let renderer = object["continuationItemRenderer"] else { return nil }
        return commandToken(in: renderer)
    }

    private static func listContinuation(_ value: JSONValue?) -> String? {
        guard let value, case .array(let items) = value else { return nil }
        for item in items {
            if let token = commandToken(in: item) { return token }
        }
        return nil
    }

    private static func commandToken(in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for key in ["continuationCommand", "nextContinuationData", "continuation"] {
                if case .object(let fields) = object[key] {
                    if let token = text(fields["token"]) ?? text(fields["continuation"]), token.count > 8 {
                        return token
                    }
                }
            }
            for key in ["continuationEndpoint", "commandExecutorCommand", "commands"] {
                if let child = object[key], let token = commandToken(in: child) { return token }
            }
            return nil
        case .array(let items):
            for item in items {
                if let token = commandToken(in: item) { return token }
            }
            return nil
        default:
            return nil
        }
    }

    private static func homeChips(in root: JSONValue) -> [HomeChip] {
        var bars: [[JSONValue]] = []
        collectChipArrays(in: root, into: &bars)
        var chips: [HomeChip] = []
        var seen = Set<String>()
        for bar in bars {
            for item in bar {
                guard case .object(let wrapper) = item,
                      case .object(let chip) = wrapper["chipCloudChipRenderer"],
                      let title = text(chip["text"]) ?? text(dig(chip, ["accessibility", "accessibilityData", "label"])),
                      !title.isEmpty,
                      seen.insert(title).inserted
                else { continue }
                var browseID: String?
                var params: String?
                var continuation: String?
                if case .object(let endpoint) = dig(chip, ["navigationEndpoint", "browseEndpoint"]) {
                    browseID = text(endpoint["browseId"])
                    params = text(endpoint["params"])
                    if browseID == nil, params != nil { browseID = "FEwhat_to_watch" }
                }
                if let endpoint = chip["navigationEndpoint"] {
                    continuation = commandToken(in: endpoint)
                }
                chips.append(HomeChip(
                    id: title,
                    title: title,
                    selected: isTruthy(chip["isSelected"]),
                    browseID: browseID,
                    params: params,
                    continuation: continuation
                ))
            }
        }
        guard !chips.isEmpty else { return [] }
        if !chips.contains(where: \.selected) {
            if let index = chips.firstIndex(where: { $0.continuation == nil && $0.params == nil && $0.browseID == nil }) {
                chips[index].selected = true
            } else {
                chips[0].selected = true
            }
        }
        return chips
    }

    /// Every chip bar in the response. TV shelves can repeat the bar per tab;
    /// merging keeps the whole personalized chip set.
    private static func collectChipArrays(in value: JSONValue, into bars: inout [[JSONValue]]) {
        switch value {
        case .object(let object):
            if object["feedFilterChipBarRenderer"] != nil || object["chipCloudRenderer"] != nil {
                let bar = object["feedFilterChipBarRenderer"] ?? object["chipCloudRenderer"]
                if case .object(let fields) = bar {
                    var items: [JSONValue] = []
                    if case .array(let contents) = fields["contents"] { items.append(contentsOf: contents) }
                    if case .array(let chips) = fields["chips"] { items.append(contentsOf: chips) }
                    if items.contains(where: { item in
                        guard case .object(let inner) = item else { return false }
                        return inner["chipCloudChipRenderer"] != nil
                    }) {
                        bars.append(items)
                    }
                }
            }
            for child in object.values { collectChipArrays(in: child, into: &bars) }
        case .array(let items):
            for item in items { collectChipArrays(in: item, into: &bars) }
        default:
            break
        }
    }

    private static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag):
            flag
        case .number(let number):
            number != 0
        default:
            false
        }
    }

    /// The bell marks an item unread. Newer menus send `read: false` instead of `unread`.
    private static func isUnread(_ fields: [String: JSONValue]) -> Bool {
        if isTruthy(fields["unread"]) || isTruthy(fields["notificationUnread"]) { return true }
        if case .bool(let read) = fields["read"] ?? .null { return !read }
        return false
    }

    private static func firstObject(_ value: JSONValue, key: String) -> [String: JSONValue]? {
        guard let found = firstValue(value, key: key), case .object(let object) = found else { return nil }
        return object
    }

    private static func firstValue(_ value: JSONValue, key: String) -> JSONValue? {
        switch value {
        case .object(let object):
            if let child = object[key] { return child }
            for child in object.values {
                if let found = firstValue(child, key: key) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = firstValue(item, key: key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private static func object(_ value: JSONValue, path: [String]) -> [String: JSONValue]? {
        var current = value
        for key in path {
            guard case .object(let fields) = current, let next = fields[key] else { return nil }
            current = next
        }
        guard case .object(let fields) = current else { return nil }
        return fields
    }
}

private enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(any: Any) {
        switch any {
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(any: $0) })
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        default:
            self = .null
        }
    }
}
