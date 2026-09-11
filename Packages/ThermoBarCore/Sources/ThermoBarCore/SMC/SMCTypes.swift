import Foundation

internal enum SMCReadCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

internal protocol SMCReading: Sendable {
    func read(key: String) throws -> SMCValue
    func close()
}

public struct SMCValue: Equatable, Sendable {
    public let key: String
    public let dataType: String
    public let bytes: [UInt8]

    public init(key: String, dataType: String, bytes: [UInt8]) {
        self.key = key
        self.dataType = dataType
        self.bytes = bytes
    }
}

public enum SMCError: Error, Equatable, Sendable {
    case unavailable
    case open
    case call
    case invalidKey
    case invalidSize
    case keyUnavailable
    case invalidDataType
    case invalidResponse
    case closed
}

internal struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

internal struct SMCPowerLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

internal struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    private var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

internal typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

internal struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    private var versionToPowerLimitPadding: UInt16 = 0
    var powerLimit = SMCPowerLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    private var data8ToData32Padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    init(key: UInt32 = 0) {
        self.key = key
        version = SMCVersion()
        versionToPowerLimitPadding = 0
        powerLimit = SMCPowerLimitData()
        keyInfo = SMCKeyInfo()
        result = 0
        status = 0
        data8 = 0
        data8ToData32Padding = 0
        data32 = 0
        bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    static var hasKernelCompatibleLayout: Bool {
        MemoryLayout<SMCVersion>.size == 6
            && MemoryLayout<SMCPowerLimitData>.size == 16
            && MemoryLayout<SMCKeyInfo>.size == 12
            && MemoryLayout<SMCBytes>.size == 32
            && MemoryLayout<SMCKeyData>.size == 80
            && MemoryLayout<SMCKeyData>.alignment == 4
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.key) == 0
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.version) == 4
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.versionToPowerLimitPadding) == 10
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.powerLimit) == 12
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.keyInfo) == 28
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.result) == 40
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.status) == 41
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data8) == 42
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data8ToData32Padding) == 43
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data32) == 44
            && MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.bytes) == 48
    }

    func byteArray() -> [UInt8] {
        var bytes = bytes
        return withUnsafeBytes(of: &bytes, Array.init)
    }

    func rawBytes() -> [UInt8] {
        var value = self
        return withUnsafeBytes(of: &value, Array.init)
    }
}
