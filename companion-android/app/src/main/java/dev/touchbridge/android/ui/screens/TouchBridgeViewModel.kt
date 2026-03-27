package dev.touchbridge.android.ui.screens

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import dev.touchbridge.android.Constants
import dev.touchbridge.android.core.BLEClient
import dev.touchbridge.android.core.ChallengeHandler
import dev.touchbridge.android.core.KeystoreManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class TouchBridgeUiState(
    val isPaired: Boolean = false,
    val isConnected: Boolean = false,
    val isScanning: Boolean = false,
    val statusMessage: String = "Not connected",
    val challengeCount: Int = 0,
    val lastChallenge: String? = null,
    val pairedMacName: String? = null,
    val discoveredDevices: List<String> = emptyList(),
)

class TouchBridgeViewModel(private val context: Context) : ViewModel(), BLEClient.Listener {

    private val _uiState = MutableStateFlow(TouchBridgeUiState())
    val uiState: StateFlow<TouchBridgeUiState> = _uiState.asStateFlow()

    val keystoreManager = KeystoreManager()
    val bleClient = BLEClient(context)
    val challengeHandler = ChallengeHandler(keystoreManager, bleClient)

    init {
        bleClient.listener = this

        // Check if already paired
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        val macId = prefs.getString(Constants.PREF_PAIRED_MAC_ID, null)
        val macName = prefs.getString(Constants.PREF_PAIRED_MAC_NAME, null)

        _uiState.value = _uiState.value.copy(
            isPaired = macId != null,
            pairedMacName = macName
        )

        // Auto-scan if paired
        if (macId != null) {
            startScanning()
        }
    }

    fun startScanning() {
        bleClient.startScanning()
        _uiState.value = _uiState.value.copy(isScanning = true, statusMessage = "Scanning...")
    }

    fun connectTo(address: String) {
        bleClient.connect(address)
        _uiState.value = _uiState.value.copy(statusMessage = "Connecting...")
    }

    fun completePairing(macName: String, macId: String) {
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putString(Constants.PREF_PAIRED_MAC_ID, macId)
            .putString(Constants.PREF_PAIRED_MAC_NAME, macName)
            .apply()

        // Generate signing key if not present
        if (!keystoreManager.hasKey(Constants.SIGNING_KEY_ALIAS)) {
            keystoreManager.generateKeyPair(Constants.SIGNING_KEY_ALIAS)
        }

        _uiState.value = _uiState.value.copy(
            isPaired = true,
            pairedMacName = macName,
            statusMessage = "Paired with $macName"
        )
    }

    fun unpair() {
        bleClient.disconnect()
        keystoreManager.deleteKey(Constants.SIGNING_KEY_ALIAS)

        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().clear().apply()

        _uiState.value = TouchBridgeUiState()
    }

    // MARK: - BLEClient.Listener

    override fun onConnectionChanged(connected: Boolean, deviceAddress: String) {
        _uiState.value = _uiState.value.copy(
            isConnected = connected,
            isScanning = false,
            statusMessage = if (connected) "Connected to Mac" else "Disconnected"
        )

        if (connected) {
            // Initiate ECDH key exchange
            val publicKey = challengeHandler.initiateECDH()
            bleClient.sendSessionKey(publicKey)
        }
    }

    override fun onChallengeReceived(data: ByteArray, deviceAddress: String) {
        // Challenge handling will be done via BiometricPrompt in the UI layer
        _uiState.value = _uiState.value.copy(
            lastChallenge = "Challenge received — authenticate with biometric"
        )
    }

    override fun onSessionKeyReceived(data: ByteArray, deviceAddress: String) {
        challengeHandler.completeECDH(data)
        _uiState.value = _uiState.value.copy(
            statusMessage = "Connected — session encrypted"
        )
    }

    override fun onPairingDataReceived(data: ByteArray, deviceAddress: String) {
        // Parse pairing response from Mac
        try {
            val json = org.json.JSONObject(String(data))
            val accepted = json.optBoolean("accepted", false)
            if (accepted) {
                val macId = json.optString("deviceID", deviceAddress)
                completePairing("Mac", macId)
            }
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(statusMessage = "Pairing failed")
        }
    }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return TouchBridgeViewModel(context) as T
        }
    }
}
