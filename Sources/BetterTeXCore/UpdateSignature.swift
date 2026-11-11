import Foundation
import CryptoKit

/// The publisher key ships with the installed app, independently of GitHub Release metadata.
public enum UpdateSignature {
    public static func verify(archive: URL, signature: URL) throws {
        try verify(archive: archive, signature: Data(contentsOf: signature), publicKey: trustedPublicKey())
    }

    static func trustedPublicKey() throws -> Data {
        try Data(contentsOf: AppResources.requiredURL("UpdateSigningPublicKey", fileExtension: "txt"))
    }

    static func verify(archive: URL, signature: Data, publicKey: Data) throws {
        guard let keyBytes = decode(publicKey), let signatureBytes = decode(signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              signatureBytes.count == 64, key.isValidSignature(signatureBytes, for: try message(for: archive)) else {
            throw BetterTeXError.message(L10n.tr("无法验证更新的发布者签名，已停止安装。"))
        }
    }

    static func message(for archive: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: archive); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        // Domain separation avoids treating signatures for other protocols as update authorization.
        return Data("BetterTeX update archive v1\nsha256:\(hex)\n".utf8)
    }

    private static func decode(_ data: Data) -> Data? {
        guard data.count <= 1024, let string = String(data: data, encoding: .utf8) else { return nil }
        return Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
