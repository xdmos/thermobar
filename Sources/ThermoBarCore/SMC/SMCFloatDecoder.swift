enum SMCFloatDecoder {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        guard let value = decodeFinite(type: type, bytes: bytes), (1 ... 115).contains(value) else {
            return nil
        }

        return value
    }

    static func decodeFinite(type: String, bytes: [UInt8]) -> Double? {
        guard type == "flt ", bytes.count == 4 else {
            return nil
        }

        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))

        guard value.isFinite else {
            return nil
        }

        return value
    }
}
