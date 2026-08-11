import Testing
@testable import ThermoBarCore

@Test(arguments: [
    ([UInt8](arrayLiteral: 0x00, 0x00, 0x3E, 0x42), 47.5),
    ([UInt8](arrayLiteral: 0x00, 0x00, 0x80, 0x3F), 1.0),
    ([UInt8](arrayLiteral: 0x00, 0x00, 0xE6, 0x42), 115.0)
])
func littleEndianFixturesDecode(input: ([UInt8], Double)) {
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: input.0) == input.1)
}

@Test func swappedAndInvalidFixturesFail() {
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0x42, 0x3E, 0, 0]) == nil)
    #expect(SMCFloatDecoder.decode(type: "ui32", bytes: [0, 0, 0, 0]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0, 0, 0]) == nil)
}

@Test func nonFiniteAndOutOfRangeValuesFail() {
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7F]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0, 0, 0xC0, 0x7F]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0, 0, 0, 0]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0, 0, 0xE8, 0x42]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0x33, 0x33, 0xE6, 0x42]) == nil)
    #expect(SMCFloatDecoder.decode(type: "flt ", bytes: [0xFF, 0xFF, 0x7F, 0x3F]) == nil)
}

@Test func finiteSMCFloatDecoderSupportsTheNonTemperatureRangeUsedByFans() {
    #expect(SMCFloatDecoder.decodeFinite(type: "flt ", bytes: [0, 0, 0, 0]) == 0)
    #expect(SMCFloatDecoder.decodeFinite(type: "flt ", bytes: [0, 0x40, 0x1C, 0x45]) == 2_500)
    #expect(SMCFloatDecoder.decodeFinite(type: "flt ", bytes: [0, 0, 0x80, 0x7F]) == nil)
    #expect(SMCFloatDecoder.decodeFinite(type: "ui32", bytes: [0, 0x40, 0x1C, 0x45]) == nil)
}

@Test func newSMCKeyDataZerosExplicitABIPadding() {
    let bytes = SMCKeyData(key: 0x5467_3055).rawBytes()

    #expect(SMCKeyData.hasKernelCompatibleLayout)
    #expect(bytes.count == 80)
    #expect(bytes[10] == 0)
    #expect(bytes[11] == 0)
    #expect(bytes[43] == 0)
}
