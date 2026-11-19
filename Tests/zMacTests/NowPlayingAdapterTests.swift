import Testing
@testable import zMac

// Đọc luồng JSON của mediaremote-adapter: gộp diff, xoá khoá null, đổi micro giây sang giây.
// Không import Foundation: với Command Line Tools, Testing + Foundation đòi module _Testing_Foundation không có sẵn.

private func apply(_ json: String, _ s: inout [String: Any]) -> Bool {
    NowPlayingAdapter.apply(line: .init(json.utf8), to: &s)
}

private let full = """
{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.brave.Browser","playing":true,"title":"Bài A",\
"artist":"Ca sĩ","album":"","durationMicros":200000000,"elapsedTimeMicros":20000000,\
"timestampEpochMicros":1794885279000000}}
"""

@Test func fullPayloadBecomesTrack() throws {
    var s: [String: Any] = [:]
    #expect(apply(full, &s))
    let t = try #require(NowPlayingAdapter.track(from: s, artwork: nil))
    #expect(t.bundleID == "com.brave.Browser")
    #expect(t.title == "Bài A")
    #expect(t.artist == "Ca sĩ")
    #expect(t.isPlaying)
    #expect(t.duration == 200)
    #expect(t.position == 20)
    #expect(t.updatedAt.timeIntervalSince1970 == 1_794_885_279)
}

@Test func diffMergesAndNullRemoves() throws {
    var s: [String: Any] = [:]
    _ = apply(full, &s)
    #expect(apply(#"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#, &s))
    let t = try #require(NowPlayingAdapter.track(from: s, artwork: nil))
    #expect(t.title == "Bài A")
    #expect(!t.isPlaying)
    #expect(t.artist == "")
}

@Test func nonDiffReplacesEverything() {
    var s: [String: Any] = [:]
    _ = apply(full, &s)
    _ = apply(#"{"type":"data","diff":false,"payload":{"title":"Bài B","playing":true}}"#, &s)
    #expect(s["artist"] == nil)
    #expect(NowPlayingAdapter.track(from: s, artwork: nil)?.title == "Bài B")
}

@Test func emptyPayloadMeansNothingPlaying() {
    var s: [String: Any] = [:]
    _ = apply(full, &s)
    #expect(apply(#"{"type":"data","diff":false,"payload":{}}"#, &s))
    #expect(NowPlayingAdapter.track(from: s, artwork: nil) == nil)
}

@Test func invalidLinesAreIgnored() {
    var s: [String: Any] = [:]
    _ = apply(full, &s)
    #expect(!apply("không phải json", &s))
    #expect(!apply(#"{"type":"error","payload":{}}"#, &s))
    #expect(!apply(#"{"type":"data","diff":true}"#, &s))
    #expect(NowPlayingAdapter.track(from: s, artwork: nil)?.title == "Bài A")
}

@Test func parentAppAndZeroDuration() {
    let s: [String: Any] = [
        "title": "Video", "playing": true, "bundleIdentifier": "com.apple.WebKit.GPU",
        "parentApplicationBundleIdentifier": "com.apple.Safari", "durationMicros": 0,
    ]
    let t = NowPlayingAdapter.track(from: s, artwork: nil)
    #expect(t?.bundleID == "com.apple.Safari")
    #expect(t?.duration == nil)
    #expect(t?.position == nil)
}

// MARK: Chọn bài khi macOS giữ trình phát khác (video Brave tạm dừng, Spotify vẫn phát)

private func adapterTrack(_ bundle: String, _ title: String, playing: Bool) -> NowPlayingTrack? {
    NowPlayingAdapter.track(from: ["bundleIdentifier": bundle, "title": title, "playing": playing], artwork: nil)
}

private func spotify(_ title: String, _ state: String) -> NowPlayingTrack? {
    NowPlayingMonitor.appTrack(["Player State": state, "Name": title, "Artist": "NHA", "Duration": 197_000,
                                "Playback Position": 88.0], bundle: "com.spotify.client")
}

@Test func spotifyNotificationBecomesTrack() throws {
    let t = try #require(spotify("Hai Lần Tan Vỡ", "Playing"))
    #expect(t.isPlaying)
    #expect(t.artist == "NHA")
    #expect(t.duration == 197)
    #expect(t.position == 88)
    #expect(spotify("Hai Lần Tan Vỡ", "Stopped") == nil)
    #expect(spotify("", "Playing") == nil)
}

@Test func playingSpotifyBeatsPausedBrowser() throws {
    let brave = adapterTrack("com.brave.Browser", "Phim", playing: false)
    let song = try #require(spotify("Hai Lần Tan Vỡ", "Playing"))
    let picked = NowPlayingMonitor.pick(adapter: brave, apps: [song], current: brave)
    #expect(picked?.bundleID == "com.spotify.client")
    #expect(picked?.isPlaying == true)
}

@Test func playingBrowserBeatsPausedSpotify() throws {
    let brave = adapterTrack("com.brave.Browser", "Phim", playing: true)
    let song = try #require(spotify("Hai Lần Tan Vỡ", "Paused"))
    #expect(NowPlayingMonitor.pick(adapter: brave, apps: [song], current: nil)?.bundleID == "com.brave.Browser")
}

@Test func pausingSpotifyKeepsSpotifyShown() throws {
    let brave = adapterTrack("com.brave.Browser", "Phim", playing: false)
    let paused = try #require(spotify("Hai Lần Tan Vỡ", "Paused"))
    let shown = spotify("Hai Lần Tan Vỡ", "Playing")
    let picked = NowPlayingMonitor.pick(adapter: brave, apps: [paused], current: shown)
    #expect(picked?.bundleID == "com.spotify.client")
    #expect(picked?.isPlaying == false)
}

@Test func adapterWinsWhenItIsSpotifyToo() throws {
    // Bình thường macOS chọn đúng Spotify: dùng bản của adapter (có ảnh bìa, tua được).
    let viaAdapter = adapterTrack("com.spotify.client", "Hai Lần Tan Vỡ", playing: false)
    let paused = try #require(spotify("Hai Lần Tan Vỡ", "Paused"))
    let picked = NowPlayingMonitor.pick(adapter: viaAdapter, apps: [paused], current: viaAdapter)
    #expect(picked?.position == nil)   // bản adapter (không gửi vị trí trong ca này), không phải bản notification
    #expect(NowPlayingMonitor.pick(adapter: nil, apps: [], current: nil) == nil)
}

@Test func parsesAppleScriptState() throws {
    let sep = "\u{1F}"
    let out = ["playing", "Nỗi Đau Chậm Lại", "NHA", "Album", "165000", "67250"].joined(separator: sep) + "\n"
    let t = try #require(PlayerScript.parseState(out, bundle: "com.spotify.client"))
    #expect(t.isPlaying)
    #expect(t.title == "Nỗi Đau Chậm Lại")
    #expect(t.duration == 165)
    #expect(t.position == 67.25)
    #expect(PlayerScript.parseState("stopped\n", bundle: "com.spotify.client") == nil)
    #expect(PlayerScript.parseState("", bundle: "com.apple.Music") == nil)
}

@Test func spotifyArtworkOnlyFromSpotifyOverHttps() {
    #expect(SpotifyArtwork.allowed(.init(string: "https://i.scdn.co/image/ab67616d0000b273")!) != nil)
    #expect(SpotifyArtwork.allowed(.init(string: "http://i.scdn.co/image/ab67616d0000b273")!) == nil)
    #expect(SpotifyArtwork.allowed(.init(string: "https://evil.example/i.scdn.co.png")!) == nil)
    #expect(SpotifyArtwork.allowed(.init(string: "https://notscdn.co/x")!) == nil)
}
