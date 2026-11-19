import Foundation
import Testing
@testable import TubeUIKit

// Feeds, saved playlists, history, notifications, search and comment plumbing.
// All fixtures are static JSON — no test hits the network.

@Test func tubeImageNormalizesProtocolRelativeAndInsecureLinks() {
    #expect(TubeImage.url(nil) == nil)
    #expect(TubeImage.url("") == nil)
    #expect(TubeImage.url("//yt3.ggpht.com/a.jpg")?.absoluteString == "https://yt3.ggpht.com/a.jpg")
    #expect(TubeImage.url("http://i.ytimg.com/vi/x/hq.jpg")?.absoluteString == "https://i.ytimg.com/vi/x/hq.jpg")
    #expect(TubeImage.url("https://yt3.ggpht.com/a.jpg")?.absoluteString == "https://yt3.ggpht.com/a.jpg")
}

@Test func displayCandidatesUpgradeVideoThumbsAndTinyAvatars() {
    let thumb = URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg?sqp=1")!
    let candidates = TubeImage.displayCandidates(thumb)
    #expect(candidates.first?.absoluteString == "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg")
    #expect(candidates.contains(thumb))
    let avatar = URL(string: "https://yt3.ggpht.com/photo=s88-c-k-c0x00ffffff-no-rj")!
    let portraits = TubeImage.displayCandidates(avatar)
    #expect(portraits.first?.absoluteString == "https://yt3.ggpht.com/photo=s800-c-k-c0x00ffffff-no-rj")
    let large = URL(string: "https://yt3.ggpht.com/photo=s800-c")!
    #expect(TubeImage.displayCandidates(large) == [large])
}

@Test func ytThumbnailsDecodeSizesAndBestPicksTheLargestRendition() throws {
    let data = Data(#"""
    {"maxres":{"url":"//yt3.ggpht.com/max.jpg","width":1280},
     "standard":{"url":"http://yt3.ggpht.com/std.jpg","width":640},
     "default":{"url":"//yt3.ggpht.com/def.jpg","width":88}}
    """#.utf8)
    let thumbnails = try JSONDecoder().decode(YTThumbnails.self, from: data)
    #expect(thumbnails.best?.absoluteString == "https://yt3.ggpht.com/max.jpg")
    let empty = try JSONDecoder().decode(YTThumbnails.self, from: Data("{}".utf8))
    #expect(empty.best == nil)
}

@Test func suggestionsDecodeTheGoogleSuggestArray() throws {
    let data = Data(#"""
    ["firefox", ["firefox account", "firefox download", 42], ["a", ["b"]]]
    """#.utf8)
    #expect(try Innertube.parseSuggestions(data) == ["firefox account", "firefox download"])
    #expect(try Innertube.parseSuggestions(Data("[]".utf8)) == [])
}

@Test func streamSelectionHonorsTheQualityCap() {
    func streaming() -> [String: Any] {
        [
            "adaptiveFormats": [
                [
                    "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                    "width": 1920, "height": 1080, "bitrate": 4_000_000,
                    "url": "https://rr1.googlevideo.com/videoplayback?id=fullhd",
                ],
                [
                    "mimeType": "video/mp4; codecs=\"avc1.4d401f\"",
                    "width": 1280, "height": 720, "bitrate": 1_500_000,
                    "url": "https://rr1.googlevideo.com/videoplayback?id=hd720",
                ],
                [
                    "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                    "bitrate": 128_000,
                    "url": "https://rr1.googlevideo.com/videoplayback?id=a",
                ],

                [
                    "mimeType": "video/mp4; codecs=\"avc1.640032\"",
                    "width": 3840, "height": 2160, "bitrate": 16_000_000,
                    "url": "https://rr1.googlevideo.com/videoplayback?id=uhd",
                ],
            ],
            "formats": [
                [
                    "mimeType": "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"",
                    "height": 360, "bitrate": 500_000,
                    "url": "https://rr1.googlevideo.com/videoplayback?id=mux",
                ],
            ],
        ]
    }
    let uncapped = Innertube.selectStreams(streaming: streaming(), userAgent: "ua", duration: 120)
    #expect(uncapped.count == 2)
    #expect(uncapped[0].url.query?.contains("id=fullhd") == true)
    #expect(uncapped.allSatisfy { !$0.url.absoluteString.contains("id=uhd") })

    let capped = Innertube.selectStreams(streaming: streaming(), userAgent: "ua", duration: 120, maxHeight: 720)
    #expect(capped[0].url.query?.contains("id=hd720") == true)
    #expect(capped[0].height == 720)
    #expect(capped[0].url.query?.contains("id=fullhd") != true)
}

@Test func historyPageGroupsDaysAndCarriesTheContinuation() throws {
    let data = Data(#"""
{
 "contents": [
  {
   "itemSectionRenderer": {
    "header": {
     "itemSectionHeaderRenderer": {
      "title": {
       "simpleText": "Today"
      }
     }
    },
    "contents": [
     {
      "videoRenderer": {
       "videoId": "abcdefghijk",
       "title": {
        "runs": [
         {
          "text": "Watched today"
         }
        ]
       }
      }
     }
    ]
   }
  },
  {
   "itemSectionRenderer": {
    "header": {
     "itemSectionHeaderRenderer": {
      "title": {
       "simpleText": "Yesterday"
      }
     }
    },
    "contents": [
     {
      "videoRenderer": {
       "videoId": "lmnopqrstuv",
       "title": {
        "runs": [
         {
          "text": "Watched yesterday"
         }
        ]
       }
      }
     }
    ]
   }
  },
  {
   "continuationItemRenderer": {
    "continuationEndpoint": {
     "continuationCommand": {
      "token": "history-page-token-1234567890"
     }
    }
   }
  }
 ]
}
"""#.utf8)
    let page = try Innertube.historyPage(in: data)
    #expect(page.days.count == 2)
    #expect(page.days[0].label == "Today")
    #expect(page.days[0].videos.first?.id == "abcdefghijk")
    #expect(page.days[1].label == "Yesterday")
    #expect(page.days[1].videos.first?.id == "lmnopqrstuv")
    #expect(page.continuation == "history-page-token-1234567890")
}

@Test func historyPageFallsBackToARecentGroupForUntaggedCards() throws {
    let data = Data(#"""
    {"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Some video"}]}}}]}
    """#.utf8)
    let page = try Innertube.historyPage(in: data)
    #expect(page.days.count == 1)
    #expect(page.days[0].label == "Recent")
    #expect(page.days[0].videos.count == 1)
}

@Test func notificationsParseTheBellMenu() throws {
    let data = Data(#"""
    {"actions":[{"appendContinuationItemsAction":{"continuationItems":[
      {"notificationRenderer":{
        "videoId":"videoABC1234567",
        "title":{"simpleText":"Someone uploaded a video"},
        "sentTimeText":{"simpleText":"2 hours ago"},
        "unread":true,
        "authorThumbnails":[{"url":"//yt3.ggpht.com/av.jpg","width":32}],
        "videoThumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/videoABC1234567/hq.jpg","width":168}]}}},
      {"notificationRenderer":{"title":{"simpleText":"Plain notice"}}}
    ]}}]}
    """#.utf8)
    let items = try Innertube.notifications(in: data)
    #expect(items.count == 2)
    let first = try #require(items.first)
    #expect(first.id == "videoABC1234567")
    #expect(first.title == "Someone uploaded a video")
    #expect(first.time == "2 hours ago")
    #expect(first.unread)
    #expect(first.videoID == "videoABC1234567")
    #expect(first.avatarURL?.host == "yt3.ggpht.com")
    #expect(first.thumbnailURL?.host == "i.ytimg.com")
    #expect(items[1].unread == false)
}

@Test func savedPlaylistPageParsesVideosMetaAndContinuation() throws {
    let data = Data(#"""
    {"header":{"playlistHeaderRenderer":{
        "title":{"simpleText":"Watch Later"},
        "ownerText":{"runs":[{"text":"Me"}]},
        "numVideosText":{"simpleText":"12 videos"},
        "publishedTimeText":"Updated today"}},
     "contents":[
      {"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"First entry"}]},
        "shortBylineText":{"runs":[{"text":"Chan"}]},
        "videoInfo":{"runs":[{"text":"12K views"},{"text":"3 days ago"}]}}},
      {"playlistVideoRenderer":{"videoId":"lmnopqrstuv","title":{"runs":[{"text":"Second entry"}]}}},
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"playlist-page-token-123456789"}}}}
     ]}
    """#.utf8)
    let page = try Innertube.playlistPage(in: data)
    #expect(page.videos.count == 2)
    #expect(page.videos[0].id == "abcdefghijk")
    #expect(page.videos[0].title == "First entry")
    #expect(page.videos[0].views == "12K views")
    let meta = try #require(page.meta)
    #expect(meta.title == "Watch Later")
    #expect(meta.owner == "Me")
    #expect(meta.count == 12)
    #expect(page.continuation == "playlist-page-token-123456789")
}

@Test func searchPageParsesVideosChannelsPlaylistsAndContinuation() throws {
    let data = Data(#"""
    {"contents":[
      {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"A search hit"}]},
        "ownerText":{"runs":[{"text":"Some Channel"}]},
        "publishedTimeText":{"simpleText":"2 days ago"},
        "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg","width":168}]}}},
      {"channelRenderer":{"channelId":"UCabcdefghij1234567890ab","title":{"simpleText":"Some Channel"},
        "navigationEndpoint":{"browseEndpoint":{"canonicalBaseUrl":"/@somechannel"}},
        "thumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/c.jpg","width":88}]}}},
      {"playlistRenderer":{"playlistId":"PLabcdefghij12345678901234","title":{"simpleText":"Some mix"},
        "videoCountText":{"simpleText":"24 videos"}}},
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"search-next-page-token-9876"}}}}
    ]}
    """#.utf8)
    let page = try Innertube.searchPage(in: data)
    #expect(page.videos.first?.id == "abcdefghijk")
    let channel = try #require(page.channels.first)
    #expect(channel.id == "UCabcdefghij1234567890ab")
    #expect(channel.snippet.title == "Some Channel")
    #expect(channel.snippet.customUrl == "@somechannel")
    #expect(channel.snippet.thumbnails?.best?.host == "yt3.ggpht.com")
    let playlist = try #require(page.playlists.first)
    #expect(playlist.id == "PLabcdefghij12345678901234")
    #expect(playlist.contentDetails?.itemCount == 24)
    #expect(page.continuation == "search-next-page-token-9876")
}

@Test func replyTokensComeFromTheThreadReplies() throws {
    let data = Data(#"""
    {"frameworkUpdates":{"entityBatchUpdate":{"mutations":[{"payload":{"commentEntityPayload":{
      "key":"comment-key-1","properties":{"commentId":"UgzTopComment1","content":{"content":"Top comment"}},
      "author":{"displayName":"@poster"},"toolbar":{"replyCount":3}}}}]}},
    "onResponseReceivedEndpoints":[{"reloadContinuationItemsCommand":{"continuationItems":[
      {"commentThreadRenderer":{"commentViewModel":{"commentViewModel":{"commentKey":"comment-key-1"}},
        "replies":{"commentRepliesRenderer":{"contents":[{"continuationItemRenderer":{"button":{"buttonRenderer":{"command":{"continuationCommand":{"token":"reply-continuation-token-1234567"}}}}}}]}}}}
    ]}}]}
    """#.utf8)
    let listing = try Innertube.commentListing(in: data)
    let comment = try #require(listing.comments.first)
    #expect(comment.id == "UgzTopComment1")
    #expect(comment.replyCount == 3)
    #expect(listing.replyTokens["UgzTopComment1"] == "reply-continuation-token-1234567")
}

@Test func repliesParseEntityPayloadsInDocumentOrder() throws {
    let data = Data(#"""
    {"frameworkUpdates":{"entityBatchUpdate":{"mutations":[{"payload":{"commentEntityPayload":{
      "key":"reply-key-1","properties":{"commentId":"UgzReply00001","content":{"content":"First reply"}},
      "author":{"displayName":"@replier"},"toolbar":{}}}},
      {"payload":{"commentEntityPayload":{"key":"reply-key-2",
        "properties":{"commentId":"UgzReply00002","content":{"content":"Second reply"}},"author":{"displayName":"@other"}}}}]}},
    "onResponseReceivedEndpoints":[{"appendContinuationItemsAction":{"continuationItems":[
      {"commentEntityPayload":{"key":"reply-key-1"}},
      {"commentEntityPayload":{"key":"reply-key-2"}}
    ]}}]}
    """#.utf8)
    let replies = try Innertube.replies(in: data)
    #expect(replies.map(\.id) == ["UgzReply00001", "UgzReply00002"])
    #expect(replies[0].text == "First reply")
}

@Test func commentRecencyRankOrdersRelativeDates() {
    #expect(commentRecencyRank("2 hours ago") < commentRecencyRank("3 days ago"))
    #expect(commentRecencyRank("3 days ago") < commentRecencyRank("3 weeks ago"))
    #expect(commentRecencyRank("streamed 2 hours ago") == commentRecencyRank("2 hours ago"))
    #expect(commentRecencyRank("just now") == Int.max)
    #expect(commentRecencyRank(nil) == Int.max)
}
