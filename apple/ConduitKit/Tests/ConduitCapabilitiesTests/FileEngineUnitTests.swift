import Foundation
import CryptoKit
import Testing
@testable import ConduitCapabilities
import ConduitProtocol

@Suite struct FileEngineUnitTests {
    @Test func sha256AndSizeMatchKnownVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-hash-\(UUID().uuidString).bin")
        let payload = Data("conduit hash vector".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (hash, size) = try FileSendEngine.sha256AndSize(of: url)
        #expect(size == UInt64(payload.count))
        #expect(hash == Data(SHA256.hash(data: payload)).hexString)
    }

    @Test func sha256OfEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-empty-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let (hash, size) = try FileSendEngine.sha256AndSize(of: url)
        #expect(size == 0)
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func mimeTypesResolveFromExtension() {
        #expect(FileSendEngine.mimeType(for: URL(fileURLWithPath: "/tmp/photo.png")) == "image/png")
        #expect(FileSendEngine.mimeType(for: URL(fileURLWithPath: "/tmp/blob.conduitunknown")) == "application/octet-stream")
    }
}
