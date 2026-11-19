import Testing
@testable import zMac

// Tự cập nhật: so phiên bản, đọc JSON của GitHub Releases, kiểm chữ ký Ed25519 (file hoặc chữ ký bị sửa thì từ chối).
// Không import Foundation (xem NowPlayingAdapterTests).

@Test func versionOrdering() {
    #expect(UpdateVersion.isNewer("0.1.1", than: "0.1.0"))
    #expect(UpdateVersion.isNewer("v0.1.10", than: "0.1.9"))
    #expect(UpdateVersion.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateVersion.isNewer("0.1.0", than: "0.1.0"))
    #expect(!UpdateVersion.isNewer("0.1", than: "0.1.0"))
    #expect(!UpdateVersion.isNewer("0.0.9", than: "0.1.0"))
    #expect(!UpdateVersion.isNewer("bản mới", than: "0.1.0"))
    #expect(UpdateVersion.parts("v1.2.3-beta") == [1, 2, 3])
}

private let releaseJSON = """
{"tag_name":"v0.2.0","body":"Sửa lỗi ⌥⇥","assets":[
 {"name":"zMac.dmg","size":3000000,"browser_download_url":"https://github.com/KienHungPG/zMac/releases/download/v0.2.0/zMac.dmg"},
 {"name":"zMac-0.2.0.zip.sig","size":89,"browser_download_url":"https://github.com/KienHungPG/zMac/releases/download/v0.2.0/zMac-0.2.0.zip.sig"},
 {"name":"zMac-0.2.0.zip","size":2900000,"browser_download_url":"https://github.com/KienHungPG/zMac/releases/download/v0.2.0/zMac-0.2.0.zip"}]}
"""

@Test func parsesRelease() throws {
    let r = try #require(UpdateRelease.parse(Array(releaseJSON.utf8)))
    #expect(r.version == "0.2.0")
    #expect(r.notes == "Sửa lỗi ⌥⇥")
    #expect(r.zipURL.hasSuffix("/zMac-0.2.0.zip"))
    #expect(r.sigURL.hasSuffix("/zMac-0.2.0.zip.sig"))
    #expect(r.size == 2900000)
}

@Test func releaseWithoutSignatureIsRejected() {
    let noSig = #"{"tag_name":"v0.2.0","assets":[{"name":"zMac-0.2.0.zip","browser_download_url":"https://x/zMac-0.2.0.zip"}]}"#
    #expect(UpdateRelease.parse(Array(noSig.utf8)) == nil)
    let plainHTTP = #"{"tag_name":"v0.2.0","assets":[{"name":"zMac.zip","browser_download_url":"http://x/zMac.zip"},{"name":"zMac.zip.sig","browser_download_url":"http://x/zMac.zip.sig"}]}"#
    #expect(UpdateRelease.parse(Array(plainHTTP.utf8)) == nil)
}

@Test func signatureMustMatch() throws {
    let file: [UInt8] = Array("nội dung zip giả".utf8) + [0, 1, 2, 255]
    let (priv, pub) = UpdateSignature.makeKeyPair()
    let sig = try #require(UpdateSignature.sign(bytes: file, privateKey: priv))
    #expect(UpdateSignature.verify(bytes: file, signature: sig, publicKey: pub))
    #expect(UpdateSignature.verify(bytes: file, signature: sig + "\n", publicKey: pub))   // dòng thừa trong file .sig

    var tampered = file
    tampered[0] ^= 1
    #expect(!UpdateSignature.verify(bytes: tampered, signature: sig, publicKey: pub))     // file bị sửa
    let (_, otherPub) = UpdateSignature.makeKeyPair()
    #expect(!UpdateSignature.verify(bytes: file, signature: sig, publicKey: otherPub))    // khoá khác
    #expect(!UpdateSignature.verify(bytes: file, signature: "rác", publicKey: pub))
    #expect(!UpdateSignature.verify(bytes: file, signature: sig, publicKey: "rác"))
}

@Test func olderReleaseWithoutSignedZipCountsAsUpToDate() throws {
    // v0.2.0 chỉ có DMG (phát hành trước khi có khoá ký).
    let dmgOnly = #"{"tag_name":"v0.2.0","assets":[{"name":"zMac.dmg","browser_download_url":"https://x/zMac.dmg"}]}"#
    #expect(UpdateRelease.decide(Array(dmgOnly.utf8), current: "0.2.0") == .upToDate)
    #expect(UpdateRelease.decide(Array(dmgOnly.utf8), current: "0.1.9") == .missingAssets)
    // Bản mới hơn có đủ zip + chữ ký.
    let r = try #require(UpdateRelease.parse(Array(releaseJSON.utf8)))
    #expect(UpdateRelease.decide(Array(releaseJSON.utf8), current: "0.1.0") == .available(r))
    #expect(UpdateRelease.decide(Array(releaseJSON.utf8), current: "0.2.0") == .upToDate)
    #expect(UpdateRelease.decide(Array("không phải json".utf8), current: "0.2.0") == nil)
}
