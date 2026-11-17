// Ký bản cập nhật zMac bằng Ed25519 (CryptoKit, có sẵn trong macOS, không cần thư viện ngoài).
//
//   swift scripts/update-sign.swift genkey            tạo khoá bí mật ở ~/.zmac/update-key (0600),
//                                                      ghi khoá công khai vào Resources/update-public-key.txt
//   swift scripts/update-sign.swift sign FILE         in chữ ký base64 của FILE
//   swift scripts/update-sign.swift verify FILE SIG   kiểm chữ ký bằng Resources/update-public-key.txt
//
// Khoá bí mật KHÔNG nằm trong repo. Mất nó thì các bản đã cài không nhận bản cập nhật ký bằng khoá mới:
// hãy sao lưu ~/.zmac/update-key. Đổi chỗ khác bằng biến ZMAC_UPDATE_KEY (và ZMAC_UPDATE_PUBKEY cho khoá công khai).

import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let keyPath = env["ZMAC_UPDATE_KEY"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".zmac/update-key")
let publicKeyPath = env["ZMAC_UPDATE_PUBKEY"] ?? "Resources/update-public-key.txt"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("Không đọc được khoá bí mật ở \(keyPath). Tạo bằng: swift scripts/update-sign.swift genkey")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "genkey":
    let fm = FileManager.default
    guard !fm.fileExists(atPath: keyPath) else {
        fail("Đã có khoá ở \(keyPath). Không ghi đè: mất khoá cũ thì bản đã cài không nhận cập nhật nữa.")
    }
    try? fm.createDirectory(atPath: (keyPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    guard fm.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                        attributes: [.posixPermissions: 0o600]) else { fail("Không ghi được \(keyPath)") }
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    do {
        try (pub + "\n").write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
    } catch {
        fail("Không ghi được \(publicKeyPath)")
    }
    print("Khoá bí mật: \(keyPath) (sao lưu nó, đừng commit)")
    print("Khoá công khai: \(publicKeyPath) = \(pub)")

case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else {
        fail("Dùng: swift scripts/update-sign.swift sign FILE")
    }
    guard let sig = try? readPrivateKey().signature(for: data) else { fail("Ký thất bại") }
    print(sig.base64EncodedString())

case "verify":
    guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pubText = try? String(contentsOfFile: publicKeyPath, encoding: .utf8),
          let raw = Data(base64Encoded: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("Dùng: swift scripts/update-sign.swift verify FILE SIGFILE (cần \(publicKeyPath))")
    }
    guard pub.isValidSignature(sig, for: data) else { fail("SAI chữ ký") }
    print("Chữ ký đúng")

default:
    fail("Dùng: swift scripts/update-sign.swift genkey | sign FILE | verify FILE SIGFILE")
}
