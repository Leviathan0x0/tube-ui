import Testing
@testable import TubeUIKit

@Test func streamSelectionPrefersDesktop1080OverTheMuxedFile() {
    let streaming: [String: Any] = [
        "adaptiveFormats": [
            [
                "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                "width": 1920, "height": 1080, "bitrate": 4_000_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=v",
            ],
            [
                "mimeType": "video/mp4; codecs=\"avc1.640032\"",
                "width": 3840, "height": 2160, "bitrate": 16_000_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=4k",
            ],
            [
                "mimeType": "video/mp4; codecs=\"av01.0.08M.08\"",
                "width": 1920, "height": 1080, "bitrate": 8_000_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=av1",
            ],
            [
                "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                "width": 1920, "height": 1080, "bitrate": 9_000_000,
                "signatureCipher": "s=hidden",
                "url": "https://rr1.googlevideo.com/videoplayback?id=cipher",
            ],
            [
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "bitrate": 128_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=a",
            ],
            [
                "mimeType": "audio/webm; codecs=\"opus\"",
                "bitrate": 160_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=opus",
            ],
        ],
        "formats": [
            [
                "mimeType": "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"",
                "height": 360, "bitrate": 500_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=mux",
            ],
        ],
        "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_playlist/x",
        "serverAbrStreamingUrl": "https://rr1.googlevideo.com/videoplayback?id=sabr",
    ]
    let streams = Innertube.selectStreams(streaming: streaming, userAgent: "ua", duration: 213)
    #expect(streams.count == 3)
    #expect(streams[0].url.query?.contains("id=v") == true)
    #expect(streams[0].height == 1080)
    #expect(streams[0].audioURL?.query?.contains("id=a") == true)
    #expect(streams[0].duration == 213)
    #expect(streams[1].audioURL == nil)
    #expect(streams[1].url.query?.contains("id=mux") == true)
    #expect(streams[2].url.absoluteString.contains("hls_playlist"))
    #expect(streams.allSatisfy { !$0.url.absoluteString.contains("id=4k") && !$0.url.absoluteString.contains("id=sabr") })
}

@Test func portraitShortUsesTheTallH264Rendition() {
    let streaming: [String: Any] = [
        "adaptiveFormats": [
            [
                "mimeType": "video/mp4; codecs=\"avc1.4d401f\"",
                "width": 1080, "height": 1920, "bitrate": 3_000_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=short",
            ],
            [
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "bitrate": 128_000,
                "url": "https://rr1.googlevideo.com/videoplayback?id=a",
            ],
        ],
    ]
    let streams = Innertube.selectStreams(streaming: streaming, userAgent: "ua", duration: 20)
    #expect(streams.count == 1)
    #expect(streams[0].url.query?.contains("id=short") == true)
    #expect(streams[0].height == 1080)
    #expect(streams[0].audioURL != nil)
}

@Test func qualityCapPicksTheTallestRenditionUnderTheCap() {
    #expect(Innertube.preferredPlayableIndex([360, 1080, 720], cap: 720) == 2)
    #expect(Innertube.preferredPlayableIndex([360, 2160, 1080], cap: 0) == 2)
    #expect(Innertube.preferredPlayableIndex([360, 1080], cap: 360) == 0)
    #expect(Innertube.preferredPlayableIndex([2160, nil], cap: 1080) == 1)
    #expect(Innertube.preferredPlayableIndex([1080, 360, nil], cap: 0) == 2)
    #expect(Innertube.preferredPlayableIndex([1080, 360, nil], cap: 360) == 2)
}
