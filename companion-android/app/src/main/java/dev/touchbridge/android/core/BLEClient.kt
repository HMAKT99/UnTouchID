package dev.touchbridge.android.core

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import dev.touchbridge.android.Constants

/**
 * BLE GATT client for Android.
 *
 * Connects to the Mac daemon's GATT peripheral and handles:
 * - Service/characteristic discovery
 * - ECDH session key exchange
 * - Challenge reception (via notifications)
 * - Signed response transmission
 * - Pairing data exchange
 *
 * Equivalent to iOS BLEClient (CBCentralManager).
 */
@SuppressLint("MissingPermission") // Permissions checked in UI layer
class BLEClient(private val context: Context) {

    companion object {
        private const val TAG = "BLEClient"
    }

    interface Listener {
        fun onConnectionChanged(connected: Boolean, deviceAddress: String)
        fun onChallengeReceived(data: ByteArray, deviceAddress: String)
        fun onSessionKeyReceived(data: ByteArray, deviceAddress: String)
        fun onPairingDataReceived(data: ByteArray, deviceAddress: String)
    }

    var listener: Listener? = null

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null
    private var isScanning = false

    // Discovered characteristics
    private var sessionKeyChar: BluetoothGattCharacteristic? = null
    private var challengeChar: BluetoothGattCharacteristic? = null
    private var responseChar: BluetoothGattCharacteristic? = null
    private var pairingChar: BluetoothGattCharacteristic? = null

    // Discovered devices
    private val discoveredDevices = mutableMapOf<String, BluetoothDevice>()

    val isConnected: Boolean get() = gatt != null
    val discoveredDeviceAddresses: List<String> get() = discoveredDevices.keys.toList()

    // MARK: - Scanning

    fun startScanning() {
        if (isScanning) return
        scanner = bluetoothAdapter?.bluetoothLeScanner ?: return

        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(Constants.SERVICE_UUID))
                .build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner?.startScan(filters, settings, scanCallback)
        isScanning = true
        Log.i(TAG, "Started scanning for TouchBridge Mac")
    }

    fun stopScanning() {
        if (!isScanning) return
        scanner?.stopScan(scanCallback)
        isScanning = false
        Log.i(TAG, "Stopped scanning")
    }

    // MARK: - Connection

    fun connect(deviceAddress: String) {
        val device = discoveredDevices[deviceAddress] ?: return
        stopScanning()
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        Log.i(TAG, "Connecting to $deviceAddress")
    }

    fun disconnect() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        sessionKeyChar = null
        challengeChar = null
        responseChar = null
        pairingChar = null
    }

    // MARK: - Write Operations

    fun sendResponse(data: ByteArray): Boolean {
        val char = responseChar ?: return false
        val g = gatt ?: return false
        char.value = data
        return g.writeCharacteristic(char)
    }

    fun sendSessionKey(data: ByteArray): Boolean {
        val char = sessionKeyChar ?: return false
        val g = gatt ?: return false
        char.value = data
        return g.writeCharacteristic(char)
    }

    fun sendPairingData(data: ByteArray): Boolean {
        val char = pairingChar ?: return false
        val g = gatt ?: return false
        char.value = data
        return g.writeCharacteristic(char)
    }

    // MARK: - Scan Callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val address = device.address
            if (!discoveredDevices.containsKey(address)) {
                discoveredDevices[address] = device
                Log.i(TAG, "Discovered TouchBridge Mac: $address (RSSI: ${result.rssi})")
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            isScanning = false
        }
    }

    // MARK: - GATT Callback

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to Mac")
                    gatt.discoverServices()
                    listener?.onConnectionChanged(true, gatt.device.address)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from Mac")
                    this@BLEClient.gatt = null
                    listener?.onConnectionChanged(false, gatt.device.address)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: $status")
                return
            }

            val service = gatt.getService(Constants.SERVICE_UUID)
            if (service == null) {
                Log.e(TAG, "TouchBridge service not found")
                return
            }

            sessionKeyChar = service.getCharacteristic(Constants.SESSION_KEY_CHAR_UUID)
            challengeChar = service.getCharacteristic(Constants.CHALLENGE_CHAR_UUID)
            responseChar = service.getCharacteristic(Constants.RESPONSE_CHAR_UUID)
            pairingChar = service.getCharacteristic(Constants.PAIRING_CHAR_UUID)

            Log.i(TAG, "Characteristics discovered")

            // Subscribe to notifications on challenge and session key chars
            enableNotifications(gatt, challengeChar)
            enableNotifications(gatt, sessionKeyChar)
            enableNotifications(gatt, pairingChar)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            val data = characteristic.value ?: return
            val address = gatt.device.address

            when (characteristic.uuid) {
                Constants.CHALLENGE_CHAR_UUID -> {
                    Log.i(TAG, "Challenge received (${data.size} bytes)")
                    listener?.onChallengeReceived(data, address)
                }
                Constants.SESSION_KEY_CHAR_UUID -> {
                    Log.i(TAG, "Session key received (${data.size} bytes)")
                    listener?.onSessionKeyReceived(data, address)
                }
                Constants.PAIRING_CHAR_UUID -> {
                    Log.i(TAG, "Pairing data received (${data.size} bytes)")
                    listener?.onPairingDataReceived(data, address)
                }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Write failed for ${characteristic.uuid}: $status")
            }
        }
    }

    private fun enableNotifications(gatt: BluetoothGatt, char: BluetoothGattCharacteristic?) {
        char ?: return
        gatt.setCharacteristicNotification(char, true)
        val descriptor = char.getDescriptor(Constants.CCCD_UUID)
        if (descriptor != null) {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
        }
    }
}
