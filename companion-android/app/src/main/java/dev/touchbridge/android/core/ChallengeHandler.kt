package dev.touchbridge.android.core

import android.util.Log
import dev.touchbridge.android.Constants
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Handles the challenge-response flow on the Android side.
 *
 * Equivalent to iOS ChallengeHandler:
 * 1. Receive encrypted challenge from Mac
 * 2. Decrypt with ECDH session key
 * 3. Prompt biometric via BiometricPrompt
 * 4. Sign nonce with Android Keystore key
 * 5. Send signed response back via BLE
 *
 * The ECDH session and AES-GCM encryption use standard JCA/JCE APIs,
 * producing output compatible with Apple's CryptoKit (same algorithms).
 */
class ChallengeHandler(
    private val keystoreManager: KeystoreManager,
    private val bleClient: BLEClient,
) {
    companion object {
        private const val TAG = "ChallengeHandler"
    }

    // ECDH session state
    private var sessionKey: SecretKeySpec? = null
    private var localECDHPrivateKey: java.security.PrivateKey? = null

    /**
     * Perform ECDH key exchange — generate ephemeral key pair and send public key to Mac.
     */
    fun initiateECDH(): ByteArray {
        val keyPairGen = KeyPairGenerator.getInstance("EC")
        keyPairGen.initialize(ECGenParameterSpec("secp256r1"))
        val keyPair = keyPairGen.generateKeyPair()

        localECDHPrivateKey = keyPair.private

        // Export public key in X9.62 uncompressed format
        val encoded = keyPair.public.encoded
        val publicKeyBytes = if (encoded.size > 65) encoded.takeLast(65).toByteArray() else encoded

        Log.i(TAG, "Generated ECDH ephemeral key pair (${publicKeyBytes.size} bytes)")
        return publicKeyBytes
    }

    /**
     * Complete ECDH — derive shared secret from Mac's public key.
     */
    fun completeECDH(macPublicKeyBytes: ByteArray) {
        val privKey = localECDHPrivateKey ?: throw IllegalStateException("ECDH not initiated")

        // Reconstruct Mac's public key from X9.62 bytes
        // Build X.509 SubjectPublicKeyInfo wrapper for EC P-256
        val header = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86.toByte(),
            0x48, 0xCE.toByte(), 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        )
        val x509Encoded = header + macPublicKeyBytes

        val keyFactory = KeyFactory.getInstance("EC")
        val macPublicKey = keyFactory.generatePublic(
            java.security.spec.X509EncodedKeySpec(x509Encoded)
        )

        // ECDH key agreement
        val keyAgreement = KeyAgreement.getInstance("ECDH")
        keyAgreement.init(privKey)
        keyAgreement.doPhase(macPublicKey, true)
        val sharedSecret = keyAgreement.generateSecret()

        // HKDF-SHA256 to derive AES-256 key (matching Apple's CryptoKit derivation)
        val derivedKey = hkdfSHA256(
            ikm = sharedSecret,
            salt = byteArrayOf(),
            info = "TouchBridge-v1".toByteArray(),
            length = 32
        )

        sessionKey = SecretKeySpec(derivedKey, "AES")
        Log.i(TAG, "ECDH session established")
    }

    /**
     * Decrypt data with the session key (AES-256-GCM).
     */
    fun decrypt(ciphertext: ByteArray): ByteArray {
        val key = sessionKey ?: throw IllegalStateException("No session key")

        // AES-GCM format: nonce (12 bytes) + ciphertext + tag (16 bytes)
        val nonce = ciphertext.copyOfRange(0, 12)
        val encrypted = ciphertext.copyOfRange(12, ciphertext.size)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
        return cipher.doFinal(encrypted)
    }

    /**
     * Encrypt data with the session key (AES-256-GCM).
     */
    fun encrypt(plaintext: ByteArray): ByteArray {
        val key = sessionKey ?: throw IllegalStateException("No session key")

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)

        val nonce = cipher.iv // 12 bytes, auto-generated
        val encrypted = cipher.doFinal(plaintext)

        // Return: nonce + ciphertext+tag (matching CryptoKit's combined format)
        return nonce + encrypted
    }

    /**
     * Parse a challenge message from decrypted JSON payload.
     */
    fun parseChallenge(payload: ByteArray): ChallengeData {
        val json = JSONObject(String(payload))
        return ChallengeData(
            challengeID = json.getString("challengeID"),
            encryptedNonce = android.util.Base64.decode(
                json.getString("encryptedNonce"), android.util.Base64.DEFAULT
            ),
            reason = json.getString("reason"),
            expiryUnix = json.getLong("expiryUnix")
        )
    }

    /**
     * Build the signed response JSON.
     */
    fun buildResponse(challengeID: String, signature: ByteArray, deviceID: String): ByteArray {
        val json = JSONObject().apply {
            put("challengeID", challengeID)
            put("signature", android.util.Base64.encodeToString(signature, android.util.Base64.NO_WRAP))
            put("deviceID", deviceID)
        }
        return json.toString().toByteArray()
    }

    val isSessionReady: Boolean get() = sessionKey != null

    /**
     * HKDF-SHA256 key derivation (RFC 5869).
     * Must match Apple CryptoKit's HKDF implementation for interoperability.
     */
    private fun hkdfSHA256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")

        // Extract
        val actualSalt = if (salt.isEmpty()) ByteArray(32) else salt
        mac.init(SecretKeySpec(actualSalt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)

        // Expand
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val result = ByteArray(length)
        var t = byteArrayOf()
        var offset = 0
        var counter: Byte = 1

        while (offset < length) {
            mac.update(t)
            mac.update(info)
            mac.update(counter)
            t = mac.doFinal()
            val toCopy = minOf(t.size, length - offset)
            System.arraycopy(t, 0, result, offset, toCopy)
            offset += toCopy
            counter++
        }

        return result
    }
}

data class ChallengeData(
    val challengeID: String,
    val encryptedNonce: ByteArray,
    val reason: String,
    val expiryUnix: Long
)
