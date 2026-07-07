import Foundation

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString.lowercased())
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue
            else { return nil }
            bytes.append(UInt8(high << 4 | low))
        }
        self.init(bytes)
    }
}
