import Testing
@testable import TouchBridgeProtocol

@Test func protocolPackageCompiles() {
    #expect(TouchBridgeConstants.protocolVersion == 0x01)
}
