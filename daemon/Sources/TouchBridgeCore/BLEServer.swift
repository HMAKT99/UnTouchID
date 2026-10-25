import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

// MARK: - BLE Server Interface

/// Abstraction over the BLE peripheral server.
///
/// Extracted as a protocol so tests can inject a `MockBLEServer` without
/// requiring CoreBluetooth or real Bluetooth hardware.
public protocol BLEServerInterface: AnyObject {
    /// The delegate that receives BLE events.
    var delegate: BLEServerDelegate? { get set }

    func startAdvertising()
    func stopAdvertising()

    /// Send an encrypted challenge to a connected companion. Returns true if sent.
    @discardableResult func sendChallenge(_ data: Data, to centralID: UUID) -> Bool

    /// Send pairing data to a connected companion. Returns true if sent.
    @discardableResult func sendPairingData(_ data: Data, to centralID: UUID) -> Bool

    /// Send session key data to a connected companion. Returns true if sent.
    @discardableResult func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool

    /// UUIDs of currently connected centrals.
    var connectedCentralIDs: [UUID] { get }

    /// Rolling-average RSSI for a connected central, or nil if unavailable.
    func averageRSSI(for centralID: UUID) -> Int?
}

// MARK: - Delegate Protocol

/// Events emitted by the BLE GATT server to the daemon coordinator.
public protocol BLEServerDelegate: AnyObject {
    /// A companion device connected.
    func bleServer(_ server: any BLEServerInterface, centralDidConnect centralID: UUID)

    /// A companion device disconnected.
    func bleServer(_ server: any BLEServerInterface, centralDidDisconnect centralID: UUID)

    /// ECDH session key received from companion; returns our public key bytes to send back.
    func bleServer(_ server: any BLEServerInterface, didReceiveSessionKey data: Data, from centralID: UUID) -> Data?

    /// Pairing data received from companion.
    func bleServer(_ server: any BLEServerInterface, didReceivePairingData data: Data, from centralID: UUID)

    /// Signed challenge response received from companion.
    func bleServer(_ server: any BLEServerInterface, didReceiveResponse data: Data, from centralID: UUID)
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
public class BLEServer: NSObject, BLEServerInterface {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "BLEServer")

    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?
    private var isServiceRegistered = false
    private var wantsAdvertising = false

    // Characteristics
    private var sessionKeyChar: CBMutableCharacteristic?
    private var challengeChar: CBMutableCharacteristic?
    private var responseChar: CBMutableCharacteristic?
    private var pairingChar: CBMutableCharacteristic?

    // Connected centrals
    private var connectedCentrals: [UUID: ConnectedCentral] = [:]

    private struct QueuedFrame { let central: CBCentral; let characteristic: CBMutableCharacteristic; let data: Data }
    private var outbound: [QueuedFrame] = []
    private var assemblers: [String: BLEReassembler] = [:]

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
        wantsAdvertising = true
        startAdvertisingIfReady()
    }

    private func startAdvertisingIfReady() {
        guard isReady, isServiceRegistered, !isAdvertising else {
            logger.info("Deferring advertising: ready=\(self.isReady), serviceRegistered=\(self.isServiceRegistered), advertising=\(self.isAdvertising)")
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
        wantsAdvertising = false
        guard isAdvertising else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        logger.info("Stopped advertising")
    }

    /// Send an encrypted challenge to a specific connected central.
    public func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.sendChallenge(data, to: centralID) } }
        guard let info = connectedCentrals[centralID],
              info.subscribedToChallenge,
              let char = challengeChar else {
            logger.warning("Cannot send challenge: central \(centralID) not subscribed")
            return false
        }

        return sendFramed(data, characteristic: char, central: info.central)
    }
    public func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.sendPairingData(data, to: centralID) } }
        guard let info = connectedCentrals[centralID], info.subscribedToPairing, let char = pairingChar else { return false }
        return sendFramed(data, characteristic: char, central: info.central)
    }
    public func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.sendSessionKey(data, to: centralID) } }
        guard let info = connectedCentrals[centralID], info.subscribedToSession, let char = sessionKeyChar else { return false }
        return sendFramed(data, characteristic: char, central: info.central)
    }
    private func sendFramed(_ data: Data, characteristic: CBMutableCharacteristic, central: CBCentral) -> Bool {
        // CoreBluetooth is created on the main queue; all its operations stay there.
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.sendFramed(data, characteristic: characteristic, central: central) } }
        guard let frames = try? BLEFraming.fragment(data, mtu: central.maximumUpdateValueLength), outbound.count + frames.count <= 2048, outbound.reduce(0, { $0 + $1.data.count }) + frames.reduce(0, { $0 + $1.count }) <= 65536 else { return false }
        outbound.append(contentsOf: frames.map { QueuedFrame(central: central, characteristic: characteristic, data: $0) })
        flushOutbound(); return true
    }
    private func flushOutbound() {
        while let next = outbound.first {
            guard connectedCentrals[next.central.identifier] != nil else { outbound.removeFirst(); continue }
            guard peripheralManager.updateValue(next.data, for: next.characteristic, onSubscribedCentrals: [next.central]) else { return }
            outbound.removeFirst()
        }
    }

    /// Get the list of connected central UUIDs.
    public var connectedCentralIDs: [UUID] {
        Array(connectedCentrals.keys)
    }

    /// Get the average RSSI for a connected central.
    public func averageRSSI(for centralID: UUID) -> Int? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.averageRSSI(for: centralID) } }
        return connectedCentrals[centralID]?.averageRSSI
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
        let key = centralID.uuidString + characteristicUUID.uuidString
        var assembler = assemblers[key] ?? BLEReassembler()
        let complete: Data?
        do { complete = try assembler.accept(data); assemblers[key] = assembler } catch { assemblers.removeValue(forKey: key); return }
        guard let data = complete else { return }
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
        if peripheral.state != .poweredOn {
            let disconnected = Array(connectedCentrals.keys)
            connectedCentrals.removeAll(); assemblers.removeAll(); outbound.removeAll()
            for id in disconnected { delegate?.bleServer(self, centralDidDisconnect: id) }
        }
        switch peripheral.state {
        case .poweredOn:
            logger.info("Bluetooth powered on")
            isReady = true
            buildService()
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            isReady = false
            isAdvertising = false
            isServiceRegistered = false
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
            isServiceRegistered = true
            if wantsAdvertising {
                startAdvertisingIfReady()
            }
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
            guard connectedCentrals.count < 32 else { return }
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
            assemblers = assemblers.filter { !$0.key.hasPrefix(centralID.uuidString) }
            outbound.removeAll { $0.central.identifier == centralID }
            delegate?.bleServer(self, centralDidDisconnect: centralID)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.offset == 0, let data = request.value else {
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
                guard connectedCentrals.count < 32 else { peripheral.respond(to: request, withResult: .insufficientResources); continue }
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
        flushOutbound()
    }
}
