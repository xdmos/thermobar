import Foundation
import IOKit

/// The lock serializes every access to the process-local IOKit connection.
/// `@unchecked Sendable` is limited to that synchronized mutable handle.
internal final class SMCClient: SMCReading, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: io_connect_t?

    init() throws {
        guard SMCKeyData.hasKernelCompatibleLayout else {
            throw SMCError.call
        }

        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCError.unavailable
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw SMCError.unavailable
        }
        defer {
            IOObjectRelease(service)
        }

        var openedConnection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == KERN_SUCCESS else {
            throw SMCError.open
        }

        connection = openedConnection
    }

    deinit {
        close()
    }

    func read(key: String) throws -> SMCValue {
        let keyCode = try Self.fourCharacterCode(for: key)

        lock.lock()
        defer {
            lock.unlock()
        }

        guard let connection else {
            throw SMCError.closed
        }

        var keyInfoRequest = SMCKeyData(key: keyCode)
        keyInfoRequest.data8 = SMCReadCommand.readKeyInfo.rawValue
        let keyInfoResponse = try call(connection: connection, input: keyInfoRequest)

        guard keyInfoResponse.result == 0, keyInfoResponse.status == 0 else {
            throw SMCError.keyUnavailable
        }
        guard keyInfoResponse.keyInfo.dataSize > 0, keyInfoResponse.keyInfo.dataSize <= 32 else {
            throw SMCError.invalidSize
        }
        guard let dataType = Self.fourCharacterString(for: keyInfoResponse.keyInfo.dataType) else {
            throw SMCError.invalidDataType
        }

        var bytesRequest = SMCKeyData(key: keyCode)
        bytesRequest.keyInfo.dataSize = keyInfoResponse.keyInfo.dataSize
        bytesRequest.data8 = SMCReadCommand.readBytes.rawValue
        let bytesResponse = try call(connection: connection, input: bytesRequest)

        guard bytesResponse.result == 0, bytesResponse.status == 0 else {
            throw SMCError.keyUnavailable
        }

        let byteCount = Int(keyInfoResponse.keyInfo.dataSize)
        return SMCValue(
            key: key,
            dataType: dataType,
            bytes: Array(bytesResponse.byteArray().prefix(byteCount))
        )
    }

    func close() {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let connection else {
            return
        }

        self.connection = nil
        IOServiceClose(connection)
    }

    private func call(connection: io_connect_t, input: SMCKeyData) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    inputPointer,
                    MemoryLayout<SMCKeyData>.size,
                    outputPointer,
                    &outputSize
                )
            }
        }

        try Self.validateCallResult(result: result, outputSize: outputSize)

        return output
    }

    static func validateCallResult(result: kern_return_t, outputSize: Int) throws {
        guard result == KERN_SUCCESS else {
            throw SMCError.call
        }
        guard outputSize == MemoryLayout<SMCKeyData>.size else {
            throw SMCError.invalidResponse
        }
    }

    private static func fourCharacterCode(for key: String) throws -> UInt32 {
        let bytes = Array(key.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 <= 0x7F }) else {
            throw SMCError.invalidKey
        }

        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    private static func fourCharacterString(for value: UInt32) -> String? {
        String(
            bytes: [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ],
            encoding: .ascii
        )
    }
}
