package dev.touchbridge.wear

import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/**
 * Listens for auth challenge messages from the Android phone companion app.
 *
 * When the phone receives a BLE challenge from the Mac daemon, it forwards
 * the challenge to the Watch via the Wearable Data Layer API.
 * This service receives it and triggers the approval UI.
 *
 * Message path: /touchbridge/challenge
 * Response path: /touchbridge/response
 */
class ChallengeListenerService : WearableListenerService() {

    companion object {
        const val CHALLENGE_PATH = "/touchbridge/challenge"
        const val RESPONSE_PATH = "/touchbridge/response"

        // Shared state — the pending challenge for the UI to display
        var pendingChallenge: PendingChallenge? = null
        var onChallengeReceived: ((PendingChallenge) -> Unit)? = null
    }

    data class PendingChallenge(
        val challengeID: String,
        val reason: String,
        val macName: String,
        val user: String,
        val sourceNodeId: String,
    )

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path == CHALLENGE_PATH) {
            val json = JSONObject(String(messageEvent.data))

            val challenge = PendingChallenge(
                challengeID = json.optString("challengeID", ""),
                reason = json.optString("reason", "Authentication"),
                macName = json.optString("macName", "Mac"),
                user = json.optString("user", ""),
                sourceNodeId = messageEvent.sourceNodeId,
            )

            pendingChallenge = challenge
            onChallengeReceived?.invoke(challenge)
        }
    }
}
