import Foundation
import Testing
@testable import TubeUIKit

@Test func pkceChallengeMatchesTheRFC7636Vector() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(YouTubeOAuth.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func authorizationURLCarriesPKCEAndTheAccountScope() throws {
    let url = YouTubeOAuth.authorizationURL(
        clientID: "client",
        redirectURI: "http://127.0.0.1:9/callback",
        state: "state",
        challenge: "challenge"
    )
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? {
        items.first { $0.name == name }?.value
    }
    #expect(url.host == "accounts.google.com")
    #expect(value("code_challenge_method") == "S256")
    #expect(value("code_challenge") == "challenge")
    #expect(value("response_type") == "code")
    #expect(value("access_type") == "offline")
    #expect(value("prompt") == "select_account consent")
    #expect(value("scope") == YouTubeOAuth.scope)
    #expect(value("redirect_uri") == "http://127.0.0.1:9/callback")
}

@Test func formBodyPercentEncodesTheRedirect() {
    let body = String(decoding: YouTubeOAuth.formBody([
        URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:9/callback"),
    ]), as: UTF8.self)
    #expect(body.contains("redirect_uri="))
    #expect(!body.contains(" "))
}

@Test func compactCounts() {
    #expect(TubeFormat.count("20") == "20")
    #expect(TubeFormat.count("1400") == "1.4K")
    #expect(TubeFormat.count("1000") == "1K")
    #expect(TubeFormat.count("12000000") == "12M")
    #expect(TubeFormat.count(nil) == nil)
}

@Test func svgPathsCoverLinesCurvesAndRelativeMoves() throws {
    let rectangle = try SVGPathParser.parse("M1 1H5V4H1Z")
    #expect(rectangle.boundingRect.width == 4)
    #expect(rectangle.boundingRect.height == 3)
    let shifted = try SVGPathParser.parse("M0 0h10v2")
    #expect(shifted.boundingRect.width == 10)
    #expect(shifted.boundingRect.height == 2)
    _ = try SVGPathParser.parse("M0 0C1 2 3 4 5 0")
}

@Test func durationMarksShortsUpToThreeMinutes() {
    #expect(TubeFormat.durationSeconds("PT45S") == 45)
    #expect(TubeFormat.durationSeconds("PT1M5S") == 65)
    #expect(TubeFormat.durationSeconds("PT3M") == 180)
    #expect(TubeFormat.durationSeconds("PT3M1S") == 181)
    #expect(TubeFormat.durationSeconds("PT1H2M3S") == 3723)
    #expect(TubeFormat.durationSeconds("PT0S") == 0)
    #expect(TubeFormat.durationSeconds("P1D") == nil)
    #expect(TubeFormat.isShort(duration: "PT45S"))
    #expect(TubeFormat.isShort(duration: "PT3M"))
    #expect(!TubeFormat.isShort(duration: "PT3M1S"))
    #expect(!TubeFormat.isShort(duration: "PT0S"))
}

@Test func scopeRejectionIsRecognizedFromTheGoogleBody() {
    let denied = Data(#"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)
    let other = Data(#"{"error":{"code":404}}"#.utf8)
    #expect(Innertube.rejectsForScope(denied))
    #expect(Innertube.rejectsForScope(Data("ACCESS_TOKEN_SCOPE_INSUFFICIENT".utf8)))
    #expect(!Innertube.rejectsForScope(other))
}

@Test func uploadsPlaylistSwapsTheChannelPrefix() {
    #expect(YouTubeAPI.uploadsPlaylistID(channelID: "UCabcdefghijklmnopqrstuv") == "UUabcdefghijklmnopqrstuv")
    #expect(YouTubeAPI.uploadsPlaylistID(channelID: "XX123") == nil)
    #expect(YouTubeAPI.uploadsPlaylistID(channelID: "UC") == nil)
}

@Test func browseFeedReadsHistoryAndShorts() throws {
    let data = Data(#"""
    {"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
      {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"A watched video"}]},"ownerText":{"runs":[{"text":"Some Channel"}]},"publishedTimeText":{"simpleText":"2 days ago"},"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg","width":168}]}}},
      {"shortsLockupViewModel":{"onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"shortvideo1"}}},"overlayMetadata":{"primaryText":{"content":"A short"},"secondaryText":{"content":"A channel"}},"thumbnail":{"sources":[{"url":"https://i.ytimg.com/vi/shortvideo1/frame0.jpg","width":180}]}}},
      {"watchEndpoint":{"videoId":"abcdefghijk"}}
    ]}}]}}}}]}}}
    """#.utf8)
    let videos = try Innertube.videos(in: data)
    #expect(videos.map(\.id) == ["abcdefghijk", "shortvideo1"])
    #expect(videos[0].title == "A watched video")
    #expect(videos[0].channel == "Some Channel")
    #expect(videos[0].published == "2 days ago")
    #expect(videos[1].title == "A short")
    #expect(videos[1].channel == "A channel")
    #expect(videos[1].isShort)
    #expect(!videos[0].isShort)
}

@Test func browseFeedReadsAHomeTile() throws {
    let data = Data(#"""
    {"tileRenderer":{
      "contentId":"tilevideo01",
      "metadata":{"tileMetadataRenderer":{
        "title":{"simpleText":"A home video"},
        "lines":[
          {"lineRenderer":{"items":[{"lineItemRenderer":{"text":{"simpleText":"Home Channel"}}}]}},
          {"lineRenderer":{"items":[
            {"lineItemRenderer":{"text":{"simpleText":"900K views"}}},
            {"lineItemRenderer":{"text":{"simpleText":"•"}}},
            {"lineItemRenderer":{"text":{"simpleText":"3 days ago"}}}
          ]}}
        ]
      }},
      "header":{"tileHeaderRenderer":{
        "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/tilevideo01/hqdefault.jpg","width":320}]},
        "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"text":{"simpleText":"8:01"},"style":"DEFAULT"}}]
      }}
    }}
    """#.utf8)
    let videos = try Innertube.videos(in: data)
    let video = try #require(videos.first)
    #expect(videos.map(\.id) == ["tilevideo01"])
    #expect(video.title == "A home video")
    #expect(video.channel == "Home Channel")
    #expect(video.views == "900K views")
    #expect(video.published == "3 days ago")
    #expect(video.length == "8:01")
    #expect(video.meta == "900K views · 3 days ago")
    #expect(!video.isShort)
}

@Test func watchPageReadsThePlayerHeader() throws {
    let data = Data(#"""
    {"contents":{
      "videoMetadataRenderer":{
        "title":{"simpleText":"A watch title"},
        "dateText":{"simpleText":"1 year ago"},
        "videoId":"abcdefghijk",
        "owner":{"videoOwnerRenderer":{
          "title":{"simpleText":"Owner"},
          "subscriberCountText":{"simpleText":"10K subscribers"},
          "thumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/a.jpg","width":88}]}
        }}
      },
      "videoViewCountRenderer":{"shortViewCount":{"simpleText":"10K views"}},
      "expandableVideoDescriptionBodyRenderer":{"descriptionBodyText":{"simpleText":"Hello description"}},
      "tileRenderer":{
        "contentId":"relatedvid1",
        "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Related"}}},
        "onSelectCommand":{"watchEndpoint":{"videoId":"relatedvid1"}}
      }
    }}
    """#.utf8)
    let page = try Innertube.watchPage(in: data, videoID: "abcdefghijk")
    #expect(page.video.title == "A watch title")
    #expect(page.video.channel == "Owner")
    #expect(page.video.views == "10K views")
    #expect(page.video.published == "1 year ago")
    #expect(page.video.channelAvatar?.absoluteString == "https://yt3.ggpht.com/a.jpg")
    #expect(page.subscribers == "10K subscribers")
    #expect(page.description == "Hello description")
    #expect(page.related.map(\.id) == ["relatedvid1"])
    #expect(page.related[0].title == "Related")
}

@Test func homeFeedPreservesShortsBetweenVideoRuns() throws {
    let data = Data(#"{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"richGridRenderer":{"header":{"feedFilterChipBarRenderer":{"contents":[{"chipCloudChipRenderer":{"text":{"simpleText":"All"},"isSelected":true}},{"chipCloudChipRenderer":{"text":{"simpleText":"Music"},"navigationEndpoint":{"browseEndpoint":{"browseId":"FEwhat_to_watch","params":"MUSIC"}}}}]}},"contents":[{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"video000001","title":{"simpleText":"One"},"ownerText":{"runs":[{"text":"Chan"}]}}}}},{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"video000002","title":{"simpleText":"Two"}}}}},{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"video000003","title":{"simpleText":"Three"}}}}},{"richSectionRenderer":{"content":{"richShelfRenderer":{"title":{"simpleText":"Shorts"},"icon":{"iconType":"SHORTS"},"contents":[{"richItemRenderer":{"content":{"reelItemRenderer":{"videoId":"short000001","headline":{"simpleText":"Short one"},"navigationEndpoint":{"reelWatchEndpoint":{"videoId":"short000001"}}}}}},{"richItemRenderer":{"content":{"shortsLockupViewModel":{"entityId":"shorts-shelf-item-short000002","overlayMetadata":{"primaryText":{"content":"Short two"}},"onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"short000002"}}}}}}}]}}}},{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"video000004","title":{"simpleText":"Four"}}}}},{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"video000005","title":{"simpleText":"Five"}}}}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXTPAGE01"}}}}]}}}}]}}}"#.utf8)
    let feed = try Innertube.home(in: data)
    #expect(feed.structured)
    #expect(feed.chips.map(\.title) == ["All", "Music"])
    #expect(feed.chips[0].selected)
    #expect(feed.chips[1].params == "MUSIC")
    #expect(feed.continuation == "NEXTPAGE01")
    #expect(feed.blocks.count == 3)
    guard case .videos(let lead) = feed.blocks[0] else { Issue.record("lead is not videos"); return }
    guard case .shorts(let shorts) = feed.blocks[1] else { Issue.record("shelf is not shorts"); return }
    guard case .videos(let tail) = feed.blocks[2] else { Issue.record("tail is not videos"); return }
    #expect(lead.map(\.id) == ["video000001", "video000002", "video000003"])
    #expect(lead.allSatisfy { !$0.isShort })
    #expect(lead[0].channel == "Chan")
    #expect(shorts.map(\.id) == ["short000001", "short000002"])
    #expect(shorts.allSatisfy { $0.isShort })
    #expect(shorts[1].title == "Short two")
    #expect(tail.map(\.id) == ["video000004", "video000005"])
}

@Test func flatHomePutsShortsAfterTheFirstRows() {
    let videos = (1...10).map { index in
        YTVideo(id: String(format: "video%07d", index), title: "Video \(index)", channel: "Channel")
    }
    let shorts = [
        YTVideo(id: "short000001", title: "A short", channel: "Channel", isShort: true),
    ]
    let feed = HomeFeed.synthesized(from: videos + shorts)
    #expect(feed.blocks.count == 3)
    guard case .videos(let lead) = feed.blocks[0],
          case .shorts(let shelf) = feed.blocks[1],
          case .videos(let tail) = feed.blocks[2] else {
        Issue.record("unexpected blocks")
        return
    }
    #expect(lead.count == 8)
    #expect(shelf.map(\.id) == ["short000001"])
    #expect(tail.count == 2)
}

@Test func homeFeedMovesLeadingShortsAfterTheFirstRows() {
    let videos = (1...10).map { index in
        YTVideo(id: String(format: "video%07d", index), title: "Video \(index)", channel: "Channel")
    }
    let feed = HomeFeed(blocks: [
        .shorts([YTVideo(id: "short000001", title: "A short", channel: "Channel", isShort: true)]),
        .shorts([YTVideo(id: "short000002", title: "Another", channel: "Channel", isShort: true)]),
        .videos(videos),
    ]).placingShortsAfterLead()
    #expect(feed.blocks.count == 4)
    guard case .videos(let lead) = feed.blocks[0],
          case .shorts(let first) = feed.blocks[1],
          case .shorts(let second) = feed.blocks[2],
          case .videos(let tail) = feed.blocks[3] else {
        Issue.record("unexpected blocks")
        return
    }
    #expect(lead.count == 8)
    #expect(first.map(\.id) == ["short000001"])
    #expect(second.map(\.id) == ["short000002"])
    #expect(tail.count == 2)
}

@Test func homeFeedKeepsShortsAlreadyBetweenVideoRuns() {
    let feed = HomeFeed(blocks: [
        .videos((1...3).map { YTVideo(id: String(format: "video%07d", $0), title: "Video", channel: "Channel") }),
        .shorts([YTVideo(id: "short000001", title: "A short", channel: "Channel", isShort: true)]),
        .videos((4...6).map { YTVideo(id: String(format: "video%07d", $0), title: "Video", channel: "Channel") }),
    ]).placingShortsAfterLead()
    #expect(feed.blocks.count == 3)
    guard case .videos(let lead) = feed.blocks[0],
          case .shorts(let shelf) = feed.blocks[1],
          case .videos(let tail) = feed.blocks[2] else {
        Issue.record("unexpected blocks")
        return
    }
    #expect(lead.map(\.id) == ["video0000001", "video0000002", "video0000003"])
    #expect(shelf.map(\.id) == ["short000001"])
    #expect(tail.map(\.id) == ["video0000004", "video0000005", "video0000006"])
}

@Test func lockupViewModelReadsTitleChannelAndLength() throws {
    let data = Data(#"""
    {"lockupViewModel":{
      "contentId":"lockupvid01",
      "contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
      "metadata":{"lockupMetadataViewModel":{
        "title":{"content":"A lockup title"},
        "metadata":{"contentMetadataViewModel":{"metadataRows":[
          {"metadataParts":[{"text":{"content":"Lockup Channel"}}]},
          {"metadataParts":[{"text":{"content":"321K views"}},{"text":{"content":"8 hours ago"}}]}
        ]}}
      }},
      "contentImage":{"thumbnailViewModel":{
        "image":{"sources":[{"url":"https://i.ytimg.com/vi/lockupvid01/hqdefault.jpg","width":320}]},
        "overlays":[{"thumbnailBottomOverlayViewModel":{"badges":[{"thumbnailBadgeViewModel":{"text":"2:39"}}]}}]
      }}
    }}
    """#.utf8)
    let videos = try Innertube.videos(in: data)
    let video = try #require(videos.first)
    #expect(video.id == "lockupvid01")
    #expect(video.title == "A lockup title")
    #expect(video.channel == "Lockup Channel")
    #expect(video.views == "321K views")
    #expect(video.published == "8 hours ago")
    #expect(video.length == "2:39")
    #expect(video.thumbnail?.absoluteString.contains("lockupvid01") == true)
}

@Test func everyReiconParsesToInk() throws {
    for icon in Reicon.allCases {
        for weight in [ReiconWeight.outline, .filled] {
            let layers = ReiconCatalog.layers(icon, weight)
            #expect(!layers.isEmpty)
            for layer in layers {
                let path = try SVGPathParser.parse(layer.commands)
                #expect(path.boundingRect.width > 0.5)
                #expect(path.boundingRect.height > 0.5)
            }
        }
    }
}

@Test func loopbackCapturesTheAuthorizationCode() async throws {
    let server = LoopbackServer()
    let port = try server.bind()
    defer { server.stop() }
    let waiter = Task.detached {
        try server.waitForCode(expectedState: "state-1")
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=state-1"))
    let (data, response) = try await URLSession.shared.data(from: url)
    let code = try await waiter.value
    #expect(code == "abc123")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("TubeUI"))
}

@Test func descriptionCardKeepsTheShortViewsRelativeDateAndHandle() throws {
    let data = Data(#"""
    {"contents":{
      "videoMetadataRenderer":{
        "title":{"simpleText":"Look Out"},
        "dateText":{"simpleText":"2 years ago"},
        "owner":{"videoOwnerRenderer":{
          "title":{"simpleText":"Jxggi"},
          "subscriberCountText":{"simpleText":"402K subscribers"},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"UCjxggi000000000000001","canonicalBaseUrl":"/@jxggi_official"}}
        }}
      },
      "videoViewCountRenderer":{"shortViewCount":{"simpleText":"6.9M views"},"viewCount":{"simpleText":"6,900,000 views"}},
      "videoDescriptionHeaderRenderer":{
        "channel":{"simpleText":"Jxggi"},
        "views":{"simpleText":"6,900,000 views"},
        "publishDate":{"simpleText":"Oct 12, 2024"},
        "channelNavigationEndpoint":{"browseEndpoint":{"browseId":"UCjxggi000000000000001","canonicalBaseUrl":"/@jxggi_official"}}
      },
      "expandableVideoDescriptionBodyRenderer":{
        "attributedDescriptionBodyText":{"content":"#lookout #jxggi #hxrmxn\nStay connected with us for latest songs"}
      }
    }}
    """#.utf8)
    let page = try Innertube.watchPage(in: data, videoID: "abcdefghijk")
    #expect(page.video.views == "6.9M views")
    #expect(page.video.published == "2 years ago")
    #expect(page.handle == "@jxggi_official")
    #expect(page.video.channel == "Jxggi")
    #expect(page.subscribers == "402K subscribers")
    #expect(page.description == "#lookout #jxggi #hxrmxn\nStay connected with us for latest songs")
    #expect(TubeFormat.hashtags(in: page.description ?? "") == ["#lookout", "#jxggi", "#hxrmxn"])
    #expect(TubeFormat.descriptionPreview(page.description ?? "") == "Stay connected with us for latest songs")
}

@Test func watchLaterSaveDoesNotInsertThroughTheDataAPI() {
    let edit = Innertube.watchLaterEdit(videoID: "abcdefghijk")
    #expect(edit.playlistID == "WL")
    #expect(edit.action == "ACTION_ADD_VIDEO")
    #expect(edit.videoID == "abcdefghijk")
    let denied = Data(#"{"error":{"message":"The API does not allow inserting into this playlist."}}"#.utf8)
    #expect(Innertube.playlistEditError(in: denied) == "Couldn't save this video to Watch Later.")
    #expect(Innertube.playlistEditError(in: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8)) == nil)
    let raw = YouTubeError.api(403, "The API does not allow inserting into playlist WL.")
    #expect(Innertube.savedVideoError(raw).errorDescription == "Couldn't save this video to Watch Later.")
}

@Test func commentListingJoinsTheEntityByCommentKey() throws {
    let data = Data(#"""
    {"frameworkUpdates":{"entityBatchUpdate":{"mutations":[{"payload":{"commentEntityPayload":{
      "key":"comment-key-1",
      "properties":{"commentId":"UgzComment0001","content":{"content":"Hello from the comments"},"publishedTime":"2 years ago"},
      "author":{"channelId":"UCabcdefghij1234567890ab","displayName":"@listener","avatarThumbnailUrl":"https://yt3.ggpht.com/a.jpg"},
      "toolbar":{"likeCountNotliked":"12","replyCount":3}
    }}}]}},
    "onResponseReceivedEndpoints":[{"reloadContinuationItemsCommand":{"continuationItems":[
      {"commentThreadRenderer":{"commentViewModel":{"commentViewModel":{"commentKey":"comment-key-1","commentId":"UgzComment0001"}}}},
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"next-comment-page-token-001"}}}}
    ]}}]}
    """#.utf8)
    let listing = try Innertube.commentListing(in: data)
    let comment = try #require(listing.comments.first)
    #expect(listing.comments.count == 1)
    #expect(comment.id == "UgzComment0001")
    #expect(comment.author == "@listener")
    #expect(comment.text == "Hello from the comments")
    #expect(comment.published == "2 years ago")
    #expect(comment.likes == "12")
    #expect(comment.replyCount == 3)
    #expect(comment.channelID == "UCabcdefghij1234567890ab")
    #expect(comment.avatar?.host == "yt3.ggpht.com")
    #expect(listing.continuation == "next-comment-page-token-001")
}

@Test func commentContinuationComesFromTheCommentsPanel() throws {
    let data = Data(#"""
    {"engagementPanels":[
      {"engagementPanelSectionListRenderer":{"panelIdentifier":"engagement-panel-searchable-transcript","content":{"sectionListRenderer":{"contents":[{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"not-the-comments-token-xxxxx"}}}}]}}}},
      {"engagementPanelSectionListRenderer":{"panelIdentifier":"engagement-panel-comments-section","header":{"engagementPanelTitleHeaderRenderer":{"title":{"simpleText":"Comments"},"contextualInfo":{"simpleText":"2.4M"}}},"content":{"sectionListRenderer":{"contents":[{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"comments-continuation-token"}}}}]}}}}
    ]}
    """#.utf8)
    #expect(try Innertube.commentPanelContinuation(in: data) == "comments-continuation-token")
    #expect(try Innertube.commentHeaderCount(in: data) == "2.4M")
}
