import Foundation
import CommonCrypto
import Crypto
import SwiftASN1

/// Minimal PKCS#12 (PFX) serializer, just capable enough to hand a certificate
/// plus private key to `SecPKCS12Import`.
///
/// Why this exists (docs/adr/0002): SecIdentity is the only currency Network
/// framework accepts for TLS, and on macOS 26 every keychain-write route to a
/// SecIdentity fails for processes without an application identifier
/// (SecItemAdd → errSecMissingEntitlement) — which breaks `swift test` and any
/// unsigned dev tool. SecPKCS12Import, by contrast, mints an in-memory
/// identity for any process. So we serialize a transient PFX and import it.
///
/// The container intentionally replicates the exact shape macOS 26's importer
/// is known to accept (probed 2026-07): certificates in an EncryptedData with
/// pbeWithSHA1And40BitRC2-CBC, the key in a PKCS8ShroudedKeyBag with
/// pbeWithSHA1And3-KeyTripleDES-CBC, and a SHA-1 MAC, 2048 iterations each.
/// Plain (unencrypted) cert bags and 3DES cert bags hang or fail the importer.
/// The legacy ciphers protect nothing at rest: the PFX exists only in memory
/// for the lifetime of one import call; real key custody is the identity
/// store's job.
enum PKCS12Writer {
    static let iterations = 2048

    enum OID {
        static let pkcs7Data: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 7, 1]
        static let pkcs7EncryptedData: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 7, 6]
        static let pbeSHA1And3KeyTripleDESCBC: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 12, 1, 3]
        static let pbeSHA1And40BitRC2CBC: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 12, 1, 6]
        static let pkcs8ShroudedKeyBag: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 12, 10, 1, 2]
        static let certBag: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 12, 10, 1, 3]
        static let x509Certificate: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 9, 22, 1]
        static let localKeyID: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 9, 21]
        static let sha1: ASN1ObjectIdentifier = [1, 3, 14, 3, 2, 26]
    }

    enum WriterError: Error {
        case cipherFailure(Int32)
    }

    // MARK: PKCS#12 KDF (RFC 7292 appendix B.2, SHA-1)

    /// id 1 = encryption key, 2 = IV, 3 = MAC key.
    static func deriveKey(password: String, salt: Data, id: UInt8, count: Int) -> Data {
        let u = 20, v = 64
        // Password as BMPString: UTF-16BE with a trailing zero terminator.
        var passwordBytes = Data()
        for unit in password.utf16 {
            passwordBytes.append(UInt8(unit >> 8))
            passwordBytes.append(UInt8(unit & 0xFF))
        }
        passwordBytes.append(contentsOf: [0, 0])

        func cycled(_ source: Data, to length: Int) -> Data {
            guard !source.isEmpty else { return Data() }
            var out = Data(capacity: length)
            let bytes = [UInt8](source)
            for index in 0..<length {
                out.append(bytes[index % bytes.count])
            }
            return out
        }

        let diversifier = Data(repeating: id, count: v)
        let saltPart = cycled(salt, to: v * ((salt.count + v - 1) / v))
        let passwordPart = cycled(passwordBytes, to: v * ((passwordBytes.count + v - 1) / v))
        var mixer = saltPart + passwordPart

        var derived = Data()
        while derived.count < count {
            var block = Data(Insecure.SHA1.hash(data: diversifier + mixer))
            for _ in 1..<iterations {
                block = Data(Insecure.SHA1.hash(data: block))
            }
            derived.append(block)
            if derived.count >= count { break }

            // I_j = (I_j + B + 1) mod 2^(v*8), per v-byte block of the mixer.
            let addend = [UInt8](cycled(block, to: v))
            var mixerBytes = [UInt8](mixer)
            for blockStart in stride(from: 0, to: mixerBytes.count, by: v) {
                var carry = 1
                for offset in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(mixerBytes[blockStart + offset]) + Int(addend[offset]) + carry
                    mixerBytes[blockStart + offset] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
            mixer = Data(mixerBytes)
        }
        return derived.prefix(count)
    }

    // MARK: Ciphers

    private static func crypt(
        algorithm: CCAlgorithm, key: Data, iv: Data, blockSize: Int, input: Data
    ) throws -> Data {
        var output = Data(count: input.count + blockSize)
        var written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt), algorithm,
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw WriterError.cipherFailure(status) }
        return output.prefix(written)
    }

    static func encrypt3DES(_ input: Data, password: String, salt: Data) throws -> Data {
        let key = deriveKey(password: password, salt: salt, id: 1, count: 24)
        let iv = deriveKey(password: password, salt: salt, id: 2, count: 8)
        return try crypt(algorithm: CCAlgorithm(kCCAlgorithm3DES), key: key, iv: iv, blockSize: 8, input: input)
    }

    static func encryptRC2_40(_ input: Data, password: String, salt: Data) throws -> Data {
        let key = deriveKey(password: password, salt: salt, id: 1, count: 5)
        let iv = deriveKey(password: password, salt: salt, id: 2, count: 8)
        return try crypt(algorithm: CCAlgorithm(kCCAlgorithmRC2), key: key, iv: iv, blockSize: 8, input: input)
    }

    // MARK: DER helpers

    private static func appendPBEAlgorithm(
        _ serializer: inout DER.Serializer, oid: ASN1ObjectIdentifier, salt: Data
    ) throws {
        try serializer.appendConstructedNode(identifier: .sequence) { alg in
            try alg.serialize(oid)
            try alg.appendConstructedNode(identifier: .sequence) { params in
                try params.serialize(ASN1OctetString(contentBytes: ArraySlice(salt)))
                try params.serialize(iterations)
            }
        }
    }

    /// SafeBag attributes: a single localKeyId so the importer pairs the
    /// certificate with its key deterministically.
    private static func appendLocalKeyIDAttribute(_ serializer: inout DER.Serializer, keyID: Data) throws {
        try serializer.appendConstructedNode(identifier: .set) { attrs in
            try attrs.appendConstructedNode(identifier: .sequence) { attr in
                try attr.serialize(OID.localKeyID)
                try attr.appendConstructedNode(identifier: .set) { values in
                    try values.serialize(ASN1OctetString(contentBytes: ArraySlice(keyID)))
                }
            }
        }
    }

    // MARK: Assembly

    static func build(certificateDER: Data, privateKeyPKCS8: Data, passphrase: String) throws -> Data {
        let localKeyID = Data(Insecure.SHA1.hash(data: certificateDER))
        var rng = SystemRandomNumberGenerator()
        func randomSalt() -> Data {
            Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        }

        // --- SafeContents holding the certificate bag (to be encrypted) ---
        var certSafeContents = DER.Serializer()
        try certSafeContents.appendConstructedNode(identifier: .sequence) { contents in
            try contents.appendConstructedNode(identifier: .sequence) { bag in
                try bag.serialize(OID.certBag)
                try bag.appendConstructedNode(
                    identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
                ) { value in
                    try value.appendConstructedNode(identifier: .sequence) { certBag in
                        try certBag.serialize(OID.x509Certificate)
                        try certBag.appendConstructedNode(
                            identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
                        ) { inner in
                            try inner.serialize(ASN1OctetString(contentBytes: ArraySlice(certificateDER)))
                        }
                    }
                }
                try appendLocalKeyIDAttribute(&bag, keyID: localKeyID)
            }
        }
        let certSalt = randomSalt()
        let encryptedCerts = try encryptRC2_40(Data(certSafeContents.serializedBytes), password: passphrase, salt: certSalt)

        // ContentInfo #1: EncryptedData{ EncryptedContentInfo{ data, RC2-40 PBE, ciphertext } }
        var contentInfo1 = DER.Serializer()
        try contentInfo1.appendConstructedNode(identifier: .sequence) { info in
            try info.serialize(OID.pkcs7EncryptedData)
            try info.appendConstructedNode(
                identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
            ) { tagged in
                try tagged.appendConstructedNode(identifier: .sequence) { encryptedData in
                    try encryptedData.serialize(0) // version
                    try encryptedData.appendConstructedNode(identifier: .sequence) { eci in
                        try eci.serialize(OID.pkcs7Data)
                        try appendPBEAlgorithm(&eci, oid: OID.pbeSHA1And40BitRC2CBC, salt: certSalt)
                        eci.appendPrimitiveNode(
                            identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
                        ) { bytes in
                            bytes.append(contentsOf: encryptedCerts)
                        }
                    }
                }
            }
        }

        // --- PKCS8ShroudedKeyBag (3DES) inside a plain-data ContentInfo ---
        let keySalt = randomSalt()
        let encryptedKey = try encrypt3DES(privateKeyPKCS8, password: passphrase, salt: keySalt)

        var keySafeContents = DER.Serializer()
        try keySafeContents.appendConstructedNode(identifier: .sequence) { contents in
            try contents.appendConstructedNode(identifier: .sequence) { bag in
                try bag.serialize(OID.pkcs8ShroudedKeyBag)
                try bag.appendConstructedNode(
                    identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
                ) { value in
                    // EncryptedPrivateKeyInfo ::= SEQUENCE { AlgId, OCTET STRING }
                    try value.appendConstructedNode(identifier: .sequence) { epki in
                        try appendPBEAlgorithm(&epki, oid: OID.pbeSHA1And3KeyTripleDESCBC, salt: keySalt)
                        try epki.serialize(ASN1OctetString(contentBytes: ArraySlice(encryptedKey)))
                    }
                }
                try appendLocalKeyIDAttribute(&bag, keyID: localKeyID)
            }
        }

        var contentInfo2 = DER.Serializer()
        try contentInfo2.appendConstructedNode(identifier: .sequence) { info in
            try info.serialize(OID.pkcs7Data)
            try info.appendConstructedNode(
                identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
            ) { tagged in
                try tagged.serialize(ASN1OctetString(contentBytes: ArraySlice(Data(keySafeContents.serializedBytes))))
            }
        }

        // --- AuthenticatedSafe = SEQUENCE OF ContentInfo (this is what gets MACed) ---
        var authSafe = DER.Serializer()
        try authSafe.appendConstructedNode(identifier: .sequence) { seq in
            seq.serializeRawBytes(ArraySlice(contentInfo1.serializedBytes))
            seq.serializeRawBytes(ArraySlice(contentInfo2.serializedBytes))
        }
        let authSafeBytes = Data(authSafe.serializedBytes)

        // --- MacData: HMAC-SHA1 with the PKCS#12 KDF MAC key ---
        let macSalt = randomSalt()
        let macKey = SymmetricKey(data: deriveKey(password: passphrase, salt: macSalt, id: 3, count: 20))
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: authSafeBytes, using: macKey))

        // --- PFX ---
        var pfx = DER.Serializer()
        try pfx.appendConstructedNode(identifier: .sequence) { root in
            try root.serialize(3) // version
            try root.appendConstructedNode(identifier: .sequence) { authSafeInfo in
                try authSafeInfo.serialize(OID.pkcs7Data)
                try authSafeInfo.appendConstructedNode(
                    identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
                ) { tagged in
                    try tagged.serialize(ASN1OctetString(contentBytes: ArraySlice(authSafeBytes)))
                }
            }
            try root.appendConstructedNode(identifier: .sequence) { macData in
                try macData.appendConstructedNode(identifier: .sequence) { digestInfo in
                    try digestInfo.appendConstructedNode(identifier: .sequence) { alg in
                        try alg.serialize(OID.sha1)
                        alg.appendPrimitiveNode(identifier: .null) { _ in }
                    }
                    try digestInfo.serialize(ASN1OctetString(contentBytes: ArraySlice(mac)))
                }
                try macData.serialize(ASN1OctetString(contentBytes: ArraySlice(macSalt)))
                try macData.serialize(iterations)
            }
        }
        return Data(pfx.serializedBytes)
    }
}
