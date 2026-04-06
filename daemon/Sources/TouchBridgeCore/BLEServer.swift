import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

// MARK: - Delegate Protocol

/// Events emitted by the BLE GATT server to the daemon coordinator.
public protocol BLEServerDelegate: AnyObject {
    /// A companion device connected.
    func bleServer(_ server: BLEServer, centralDidConnect centralID: UUID)

    /// A companion device disconnected.
    func bleServer(_ server: BLEServer, centralDidDisconnect centralID: UUID)

    /// ECDH session key received from companion; returns our public key bytes to send back.
    func bleServer(_ server: BLEServer, didReceiveSessionKey data: Data, from centralID: UUID) -> Data?

    /// Pairing data received from companion.
    func bleServer(_ server: BLEServer, didReceivePairingData data: Data, from centralID: UUID)

    /// Signed challenge response received from companion.
    func bleServer(_ server: BLEServer, didReceiveResponse data: Data, from centralID: UUID)
}

// MARK: - Connected Central Tracking

/// Tracks per-central connection state.
struct ConnectedCentral {
    let central: CBCentral
    var subscribedToChallenge: Bool = false
    var subscribedToSession: Bool = false
    var subscribedToPairing: Bool = false
    var rssiReadings: [Int] = []

    /// Rolling average RSSI over last 5 readings.
    var averageRSSI: Int? {
        guard !rssiReadings.isEmpty else { return nil }
        let recent = Array(rssiReadings.suffix(5))
        return recent.reduce(0, +) / recent.count
    }

    mutating func addRSSI(_ rssi: Int) {
        rssiReadings.append(rssi)
        if rssiReadings.count > 10 {
            rssiReadings.removeFirst(rssiReadings.count - 10)
        }
    }
}

// MARK: - BLE Server

/// macOS BLE GATT peripheral server.
///
/// Advertises the TouchBridge service and manages characteristics for:
/// - Session key exchange (ECDH)
/// - Challenge delivery (Mac → iPhone via notify)
/// - Response reception (iPhone → Mac via write)
/// - Pairing flow (bidirectional)
public class BLEServer: NSObject {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "BLEServer")

    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?

    // Characteristics
    private var sessionKeyChar: CBMutableCharacteristic?
    private var challengeChar: CBMutableCharacteristic?
    private var responseChar: CBMutableCharacteristic?
    private var pairingChar: CBMutableCharacteristic?

    // Connected centrals
    private var connectedCentrals: [UUID: ConnectedCentral] = [:]

    // RSSI proximity gate
    private let rssiThreshold: Int

    // Per-Mac unique service UUID
    private let serviceUUID: String

    public weak var delegate: BLEServerDelegate?

    /// Whether the peripheral manager is powered on and ready.
    public private(set) var isReady: Bool = false

    /// Whether we are currently advertising.
    public private(set) var isAdvertising: Bool = false

    public init(
        rssiThreshold: Int = TouchBridgeConstants.defaultRSSIThreshold,
        serviceUUID: String = TouchBridgeConstants.serviceUUID
    ) {
        self.rssiThreshold = rssiThreshold
        self.serviceUUID = serviceUUID
        super.init()
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    /// Start advertising the TouchBridge BLE service.
    public func startAdvertising() {
        guard isReady, !isAdvertising else {
            logger.warning("Cannot start advertising: ready=\(self.isReady), advertising=\(self.isAdvertising)")
            return
        }

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: serviceUUID)],
            CBAdvertisementDataLocalNameKey: "TouchBridge",
        ])
        isAdvertising = true
        logger.info("Started advertising TouchBridge service")
    }

    /// Stop advertising.
    public func stopAdvertising() {
        guard isAdvertising else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        logger.info("Stopped advertising")
    }

    /// Send an encrypted challenge to a specific connected central.
    public func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        guard let info = connectedCentrals[centralID],
              info.subscribedToChallenge,
              let char = challengeChar else {
            logger.warning("Cannot send challenge: central \(centralID) not subscribed")
            return false
        }

        let sent = peripheralManager.updateValue(
            data,
            for: char,
            onSubscribedCentrals: [info.central]
        )

        if !sent {
            logger.warning("Challenge notification queued (transmit queue full)")
        }
        return sent
    }

    /// Send pairing data to a specific connected central.
    public func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        guard let info = connectedCentrals[centralID],
              info.subscribedToPairing,
              let char = pairingChar else {
            logger.warning("Cannot send pairing data: central \(centralID) not subscribed")
            return false
        }

        return peripheralManager.updateValue(
            data,
            for: char,
            onSubscribedCentrals: [info.central]
        )
    }

    /// Send session key data to a specific connected central.
    public func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool {
        guard let info = connectedCentrals[centralID],
              info.subscribedToSession,
              let char = sessionKeyChar else {
            logger.warning("Cannot send session key: central \(centralID) not subscribed")
            return false
        }

        return peripheralManager.updateValue(
            data,
            for: char,
            onSubscribedCentrals: [info.central]
        )
    }

    /// Get the list of connected central UUIDs.
    public var connectedCentralIDs: [UUID] {
        Array(connectedCentrals.keys)
    }

    /// Get the average RSSI for a connected central.
    public func averageRSSI(for centralID: UUID) -> Int? {
        connectedCentrals[centralID]?.averageRSSI
    }

    // MARK: - Private

    private func buildService() {
        let serviceUUID = CBUUID(string: self.serviceUUID)

        // Session key exchange: writable by central + notifiable
        sessionKeyChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID),
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        // Challenge: Mac notifies iPhone (read-only from central perspective)
        challengeChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.challengeCharUUID),
            properties: [.notify],
            value: nil,
            permissions: []
        )

        // Response: iPhone writes signed response
        responseChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.responseCharUUID),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        // Pairing: bidirectional
        pairingChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.pairingCharUUID),
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        let svc = CBMutableService(type: serviceUUID, primary: true)
        svc.characteristics = [sessionKeyChar!, challengeChar!, responseChar!, pairingChar!]
        service = svc

        peripheralManager.add(svc)
        logger.info("TouchBridge GATT service registered")
    }

    private func routeWrite(for characteristicUUID: CBUUID, data: Data, centralID: UUID) {
        let sessionUUID = CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID)
        let responseUUID = CBUUID(string: TouchBridgeConstants.responseCharUUID)
        let pairingUUID = CBUUID(string: TouchBridgeConstants.pairingCharUUID)

        if characteristicUUID == sessionUUID {
            if let responseData = delegate?.bleServer(self, didReceiveSessionKey: data, from: centralID) {
                // Send our session key back via notify
                _ = sendSessionKey(responseData, to: centralID)
            }
        } else if characteristicUUID == responseUUID {
            delegate?.bleServer(self, didReceiveResponse: data, from: centralID)
        } else if characteristicUUID == pairingUUID {
            delegate?.bleServer(self, didReceivePairingData: data, from: centralID)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEServer: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            logger.info("Bluetooth powered on")
            isReady = true
            buildService()
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            isReady = false
            isAdvertising = false
        case .unauthorized:
            logger.error("Bluetooth unauthorized — check Info.plist NSBluetoothAlwaysUsageDescription")
            isReady = false
        case .unsupported:
            logger.error("Bluetooth not supported on this hardware")
            isReady = false
        default:
            logger.info("Bluetooth state: \(String(describing: peripheral.state.rawValue))")
            isReady = false
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error {
            logger.error("Failed to add service: \(error.localizedDescription)")
        } else {
            logger.info("Service added successfully")
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            isAdvertising = false
        } else {
            logger.info("Advertising started")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let centralID = central.identifier
        logger.info("Central \(centralID) subscribed to \(characteristic.uuid)")

        if connectedCentrals[centralID] == nil {
            connectedCentrals[centralID] = ConnectedCentral(central: central)
            delegate?.bleServer(self, centralDidConnect: centralID)
        }

        let charUUID = characteristic.uuid
        if charUUID == CBUUID(string: TouchBridgeConstants.challengeCharUUID) {
            connectedCentrals[centralID]?.subscribedToChallenge = true
        } else if charUUID == CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID) {
            connectedCentrals[centralID]?.subscribedToSession = true
        } else if charUUID == CBUUID(string: TouchBridgeConstants.pairingCharUUID) {
            connectedCentrals[centralID]?.subscribedToPairing = true
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let centralID = central.identifier
        logger.info("Central \(centralID) unsubscribed from \(characteristic.uuid)")

        let charUUID = characteristic.uuid
        if charUUID == CBUUID(string: TouchBridgeConstants.challengeCharUUID) {
            connectedCentrals[centralID]?.subscribedToChallenge = false
        } else if charUUID == CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID) {
            connectedCentrals[centralID]?.subscribedToSession = false
        } else if charUUID == CBUUID(string: TouchBridgeConstants.pairingCharUUID) {
            connectedCentrals[centralID]?.subscribedToPairing = false
        }

        // If no subscriptions remain, treat as disconnected
        if let info = connectedCentrals[centralID],
           !info.subscribedToChallenge && !info.subscribedToSession && !info.subscribedToPairing {
            connectedCentrals.removeValue(forKey: centralID)
            delegate?.bleServer(self, centralDidDisconnect: centralID)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            // Enforce max message size
            guard data.count <= TouchBridgeConstants.maxMessageSize else {
                logger.warning("Rejecting oversized write: \(data.count) bytes")
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            let centralID = request.central.identifier

            // Track the central if not yet tracked
            if connectedCentrals[centralID] == nil {
                connectedCentrals[centralID] = ConnectedCentral(central: request.central)
                delegate?.bleServer(self, centralDidConnect: centralID)
            }

            routeWrite(
                for: request.characteristic.uuid,
                data: data,
                centralID: centralID
            )

            peripheral.respond(to: request, withResult: .success)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Called when the transmit queue has space again after a failed updateValue.
        // In a production implementation, we'd retry queued notifications here.
        logger.info("Transmit queue ready for more notifications")
    }
}
