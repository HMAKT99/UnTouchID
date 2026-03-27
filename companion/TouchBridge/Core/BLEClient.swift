import Foundation
import CoreBluetooth
import os.log

// MARK: - Delegate Protocol

/// Events emitted by the BLE client to the companion app coordinator.
public protocol BLEClientDelegate: AnyObject {
    /// Connection state changed.
    func bleClient(_ client: BLEClient, connectionStateChanged connected: Bool, peripheralID: UUID)

    /// Encrypted challenge received from Mac.
    func bleClient(_ client: BLEClient, didReceiveChallenge data: Data, from peripheralID: UUID)

    /// Session key data received from Mac (ECDH public key).
    func bleClient(_ client: BLEClient, didReceiveSessionKey data: Data, from peripheralID: UUID)

    /// Pairing data received from Mac.
    func bleClient(_ client: BLEClient, didReceivePairingData data: Data, from peripheralID: UUID)
}

// MARK: - Discovered Peripheral Tracking

/// Tracks a discovered Mac peripheral.
struct DiscoveredPeripheral {
    let peripheral: CBPeripheral
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

// MARK: - BLE Client

/// iOS BLE GATT central client.
///
/// Discovers and connects to the Mac daemon's GATT service.
/// Handles characteristic subscriptions (notify) and writes.
/// Supports background BLE restoration via `CBCentralManagerOptionRestoreIdentifierKey`.
public class BLEClient: NSObject {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "BLEClient")

    /// Restoration identifier for background BLE.
    private static let restoreIdentifier = "dev.touchbridge.companion.central"

    private var centralManager: CBCentralManager!

    /// Currently connected peripheral (one at a time for Phase 0).
    private var connectedPeripheral: CBPeripheral?

    /// Discovered peripherals keyed by UUID.
    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]

    // Discovered characteristics
    private var sessionKeyChar: CBCharacteristic?
    private var challengeChar: CBCharacteristic?
    private var responseChar: CBCharacteristic?
    private var pairingChar: CBCharacteristic?

    public weak var delegate: BLEClientDelegate?

    /// Whether the central manager is powered on.
    public private(set) var isReady: Bool = false

    /// Whether we are currently scanning.
    public private(set) var isScanning: Bool = false

    /// Whether we are connected to a peripheral.
    public var isConnected: Bool { connectedPeripheral != nil }

    /// The connected peripheral's UUID, if any.
    public var connectedPeripheralID: UUID? { connectedPeripheral?.identifier }

    public override init() {
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier
            ]
        )
    }

    // MARK: - Public API

    /// Start scanning for TouchBridge Mac peripherals.
    public func startScanning() {
        guard isReady, !isScanning else {
            logger.warning("Cannot scan: ready=\(self.isReady), scanning=\(self.isScanning)")
            return
        }

        let serviceUUID = CBUUID(string: TouchBridgeConstants.serviceUUID)
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        logger.info("Started scanning for TouchBridge peripherals")
    }

    /// Stop scanning.
    public func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        logger.info("Stopped scanning")
    }

    /// Connect to a discovered peripheral.
    public func connect(to peripheralID: UUID) {
        guard let info = discoveredPeripherals[peripheralID] else {
            logger.warning("Cannot connect: peripheral \(peripheralID) not discovered")
            return
        }

        stopScanning()
        centralManager.connect(info.peripheral, options: nil)
        logger.info("Connecting to peripheral \(peripheralID)")
    }

    /// Disconnect from the currently connected peripheral.
    public func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Send signed challenge response to the Mac.
    public func sendResponse(_ data: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let char = responseChar else {
            logger.warning("Cannot send response: not connected or characteristic not found")
            return false
        }

        // Use writeWithResponse for reliability
        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }

    /// Send ECDH session key to the Mac.
    public func sendSessionKey(_ data: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let char = sessionKeyChar else {
            logger.warning("Cannot send session key: not connected or characteristic not found")
            return false
        }

        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }

    /// Send pairing data to the Mac.
    public func sendPairingData(_ data: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let char = pairingChar else {
            logger.warning("Cannot send pairing data: not connected or characteristic not found")
            return false
        }

        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }

    /// Get average RSSI for a discovered peripheral.
    public func averageRSSI(for peripheralID: UUID) -> Int? {
        discoveredPeripherals[peripheralID]?.averageRSSI
    }

    /// List discovered peripheral UUIDs.
    public var discoveredPeripheralIDs: [UUID] {
        Array(discoveredPeripherals.keys)
    }

    // MARK: - Private

    private func discoverServices(for peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: TouchBridgeConstants.serviceUUID)])
    }

    private func subscribeToNotifications(for peripheral: CBPeripheral) {
        if let char = challengeChar {
            peripheral.setNotifyValue(true, for: char)
        }
        if let char = sessionKeyChar, char.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: char)
        }
        if let char = pairingChar, char.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: char)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEClient: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.info("Bluetooth powered on")
            isReady = true
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            isReady = false
            isScanning = false
        case .unauthorized:
            logger.error("Bluetooth unauthorized — check Info.plist NSBluetoothAlwaysUsageDescription")
            isReady = false
        case .unsupported:
            logger.error("Bluetooth not supported")
            isReady = false
        default:
            isReady = false
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Background restoration — reconnect to any previously connected peripherals
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                logger.info("Restoring peripheral: \(peripheral.identifier)")
                discoveredPeripherals[peripheral.identifier] = DiscoveredPeripheral(peripheral: peripheral)
                if peripheral.state == .connected {
                    connectedPeripheral = peripheral
                    discoverServices(for: peripheral)
                }
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let rssiValue = RSSI.intValue

        if discoveredPeripherals[id] == nil {
            discoveredPeripherals[id] = DiscoveredPeripheral(peripheral: peripheral)
            logger.info("Discovered TouchBridge peripheral: \(id), RSSI: \(rssiValue)")
        }
        discoveredPeripherals[id]?.addRSSI(rssiValue)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let id = peripheral.identifier
        logger.info("Connected to peripheral: \(id)")
        connectedPeripheral = peripheral
        discoverServices(for: peripheral)
        delegate?.bleClient(self, connectionStateChanged: true, peripheralID: id)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
        }
        delegate?.bleClient(self, connectionStateChanged: false, peripheralID: peripheral.identifier)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        logger.info("Disconnected from peripheral: \(id)")
        if connectedPeripheral?.identifier == id {
            connectedPeripheral = nil
            sessionKeyChar = nil
            challengeChar = nil
            responseChar = nil
            pairingChar = nil
        }
        delegate?.bleClient(self, connectionStateChanged: false, peripheralID: id)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEClient: CBPeripheralDelegate {

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }
        let targetUUID = CBUUID(string: TouchBridgeConstants.serviceUUID)

        for service in services where service.uuid == targetUUID {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        let sessionUUID = CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID)
        let challengeUUID = CBUUID(string: TouchBridgeConstants.challengeCharUUID)
        let responseUUID = CBUUID(string: TouchBridgeConstants.responseCharUUID)
        let pairingUUID = CBUUID(string: TouchBridgeConstants.pairingCharUUID)

        for char in characteristics {
            switch char.uuid {
            case sessionUUID:
                sessionKeyChar = char
                logger.info("Found session key characteristic")
            case challengeUUID:
                challengeChar = char
                logger.info("Found challenge characteristic")
            case responseUUID:
                responseChar = char
                logger.info("Found response characteristic")
            case pairingUUID:
                pairingChar = char
                logger.info("Found pairing characteristic")
            default:
                break
            }
        }

        // Subscribe to notify characteristics
        subscribeToNotifications(for: peripheral)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.error("Characteristic update error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        let peripheralID = peripheral.identifier

        let challengeUUID = CBUUID(string: TouchBridgeConstants.challengeCharUUID)
        let sessionUUID = CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID)
        let pairingUUID = CBUUID(string: TouchBridgeConstants.pairingCharUUID)

        switch characteristic.uuid {
        case challengeUUID:
            delegate?.bleClient(self, didReceiveChallenge: data, from: peripheralID)
        case sessionUUID:
            delegate?.bleClient(self, didReceiveSessionKey: data, from: peripheralID)
        case pairingUUID:
            delegate?.bleClient(self, didReceivePairingData: data, from: peripheralID)
        default:
            break
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.error("Write failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.error("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
        }
    }
}
