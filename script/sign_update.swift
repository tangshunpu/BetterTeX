#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

struct SigningError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func fail(_ message: String) throws -> Never { throw SigningError(message: message) }
func decode(_ path: String) throws -> Data {
    guard let data = Data(base64Encoded: try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else { try fail("Invalid base64 key or signature: \(path)") }
    return data
}
func message(_ path: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return Data("BetterTeX update archive v1\nsha256:\(hex)\n".utf8)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "generate" where args.count == 3:
        let privateURL = URL(fileURLWithPath: args[1]), publicURL = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: privateURL.path), !FileManager.default.fileExists(atPath: publicURL.path) else { try fail("Refusing to overwrite an existing signing key.") }
        umask(0o077)
        try FileManager.default.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: privateURL, options: .withoutOverwriting)
        try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: publicURL, options: .withoutOverwriting)
        print("Created publisher key. Back up the private key offline; never upload it to GitHub.")
    case "sign" where args.count == 4:
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: decode(args[2]))
        guard key.publicKey.rawRepresentation == (try decode(args[3])) else { try fail("Private key does not match the public key pinned in the app.") }
        let signature = try key.signature(for: message(args[1]))
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: args[1] + ".sig"), options: .atomic)
        print("Signed \(URL(fileURLWithPath: args[1]).lastPathComponent).sig")
    case "verify" where args.count == 4:
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: decode(args[3]))
        guard try key.isValidSignature(decode(args[2]), for: message(args[1])) else { try fail("Publisher signature verification failed.") }
        print("Publisher signature verified.")
    default:
        try fail("Usage: sign_update.swift generate PRIVATE_KEY PUBLIC_KEY | sign ZIP PRIVATE_KEY PUBLIC_KEY | verify ZIP SIGNATURE PUBLIC_KEY")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
