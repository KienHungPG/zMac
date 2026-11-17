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
