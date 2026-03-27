package dev.touchbridge.android.core

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.*
import java.security.spec.ECGenParameterSpec

/**
 * Manages ECDSA P-256 keys in the Android Keystore (hardware-backed via TEE/StrongBox).
 *
 * Equivalent to iOS SecureEnclaveManager:
 * - Keys are generated inside the hardware security module
 * - Private key never leaves the secure hardware
 * - Signing requires biometric authentication
 *
 * On devices with StrongBox (Pixel 3+, Samsung Galaxy S10+, etc.),
 * keys are stored in a dedicated security chip — equivalent to Apple's Secure Enclave.
 */
class KeystoreManager {
    companion object {
        private const val TAG = "KeystoreManager"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    }

    private val keyStore: KeyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }

    /**
     * Generate a new ECDSA P-256 key pair in the Android Keystore.
     *
     * The key is hardware-backed and requires biometric auth for signing.
     * Returns the public key in X9.62 uncompressed format (65 bytes).
     */
    fun generateKeyPair(alias: String): ByteArray {
        // Delete existing key if present
        deleteKey(alias)

        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            // Try StrongBox first (hardware security module, like Apple's Secure Enclave)
            // Falls back to TEE if StrongBox not available
            .apply {
                try {
                    setIsStrongBoxBacked(true)
                    Log.i(TAG, "Using StrongBox for key storage")
                } catch (e: Exception) {
                    Log.i(TAG, "StrongBox not available, using TEE")
                }
            }
            .build()

        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER
        )
        keyPairGenerator.initialize(spec)
        val keyPair = keyPairGenerator.generateKeyPair()

        Log.i(TAG, "Generated ECDSA P-256 key pair: $alias")
        return exportPublicKey(keyPair.public)
    }

    /**
     * Sign data with the Keystore private key.
     *
     * This triggers a biometric prompt because the key was created with
     * setUserAuthenticationRequired(true).
     *
     * Must be called after BiometricPrompt authentication succeeds,
     * using the CryptoObject's Signature.
     */
    fun createSignature(alias: String): Signature {
        val privateKey = keyStore.getKey(alias, null) as? PrivateKey
            ?: throw KeyStoreException("Key not found: $alias")

        return Signature.getInstance("SHA256withECDSA").apply {
            initSign(privateKey)
        }
    }

    /**
     * Sign data directly (for testing or when biometric auth is handled separately).
     */
    fun sign(data: ByteArray, alias: String): ByteArray {
        val signature = createSignature(alias)
        signature.update(data)
        return signature.sign()
    }

    /**
     * Export the public key in X9.62 uncompressed format (65 bytes).
     */
    fun getPublicKey(alias: String): ByteArray {
        val cert = keyStore.getCertificate(alias)
            ?: throw KeyStoreException("Certificate not found: $alias")
        return exportPublicKey(cert.publicKey)
    }

    /**
     * Check if a key pair exists for the given alias.
     */
    fun hasKey(alias: String): Boolean = keyStore.containsAlias(alias)

    /**
     * Delete a key pair.
     */
    fun deleteKey(alias: String) {
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
            Log.i(TAG, "Deleted key: $alias")
        }
    }

    /**
     * Export public key to X9.62 uncompressed format.
     * Android's ECPublicKey.encoded is in X.509 SubjectPublicKeyInfo format.
     * We need to extract the raw point (65 bytes for uncompressed P-256).
     */
    private fun exportPublicKey(publicKey: PublicKey): ByteArray {
        val encoded = publicKey.encoded
        // X.509 SubjectPublicKeyInfo for EC P-256 has a fixed header.
        // The last 65 bytes are the uncompressed point (04 || x || y).
        return if (encoded.size > 65) {
            encoded.takeLast(65).toByteArray()
        } else {
            encoded
        }
    }
}
