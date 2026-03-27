package dev.touchbridge.wear

import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.*
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject

class MainActivity : ComponentActivity() {

    private lateinit var messageClient: MessageClient
    private lateinit var vibrator: Vibrator

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        messageClient = Wearable.getMessageClient(this)
        vibrator = getSystemService(Vibrator::class.java)

        setContent {
            var pendingChallenge by remember { mutableStateOf<ChallengeListenerService.PendingChallenge?>(null) }
            var lastResult by remember { mutableStateOf<String?>(null) }
            var challengeCount by remember { mutableIntStateOf(0) }

            // Listen for incoming challenges
            LaunchedEffect(Unit) {
                ChallengeListenerService.onChallengeReceived = { challenge ->
                    pendingChallenge = challenge
                    // Vibrate to alert
                    vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
                }

                // Check if there's already a pending challenge
                ChallengeListenerService.pendingChallenge?.let {
                    pendingChallenge = it
                }
            }

            MaterialTheme {
                if (pendingChallenge != null) {
                    AuthRequestScreen(
                        challenge = pendingChallenge!!,
                        onApprove = {
                            sendResponse(pendingChallenge!!, approved = true)
                            challengeCount++
                            lastResult = "Approved"
                            pendingChallenge = null
                            ChallengeListenerService.pendingChallenge = null
                            vibrator.vibrate(VibrationEffect.createOneShot(100, VibrationEffect.DEFAULT_AMPLITUDE))
                        },
                        onDeny = {
                            sendResponse(pendingChallenge!!, approved = false)
                            lastResult = "Denied"
                            pendingChallenge = null
                            ChallengeListenerService.pendingChallenge = null
                            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 50, 50, 50), -1))
                        }
                    )
                } else {
                    StatusScreen(
                        challengeCount = challengeCount,
                        lastResult = lastResult
                    )
                }
            }
        }
    }

    private fun sendResponse(challenge: ChallengeListenerService.PendingChallenge, approved: Boolean) {
        val json = JSONObject().apply {
            put("challengeID", challenge.challengeID)
            put("approved", approved)
        }

        messageClient.sendMessage(
            challenge.sourceNodeId,
            ChallengeListenerService.RESPONSE_PATH,
            json.toString().toByteArray()
        )
    }
}

@Composable
fun AuthRequestScreen(
    challenge: ChallengeListenerService.PendingChallenge,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
) {
    ScalingLazyColumn(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        item {
            Text(
                text = "🔐",
                fontSize = 32.sp,
                modifier = Modifier.padding(bottom = 8.dp)
            )
        }

        item {
            Text(
                text = "Auth Request",
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
                color = Color.White,
            )
        }

        item {
            Text(
                text = challenge.reason,
                fontSize = 13.sp,
                color = Color.LightGray,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )
        }

        item {
            Text(
                text = challenge.macName,
                fontSize = 12.sp,
                color = Color.Gray,
            )
        }

        item { Spacer(modifier = Modifier.height(12.dp)) }

        // Approve
        item {
            Chip(
                onClick = onApprove,
                label = { Text("Approve", fontWeight = FontWeight.SemiBold) },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF30D158)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }

        // Deny
        item {
            Chip(
                onClick = onDeny,
                label = { Text("Deny") },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF48484A)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }
    }
}

@Composable
fun StatusScreen(challengeCount: Int, lastResult: String?) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text = "🔐", fontSize = 28.sp)

        Text(
            text = "TouchBridge",
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp,
            color = Color.White,
            modifier = Modifier.padding(top = 4.dp)
        )

        Text(
            text = "Waiting...",
            fontSize = 12.sp,
            color = Color.Gray,
            modifier = Modifier.padding(top = 2.dp)
        )

        if (challengeCount > 0) {
            Text(
                text = "$challengeCount approved",
                fontSize = 11.sp,
                color = Color(0xFF30D158),
                modifier = Modifier.padding(top = 8.dp)
            )
        }

        lastResult?.let {
            Text(
                text = it,
                fontSize = 11.sp,
                color = if (it == "Approved") Color(0xFF30D158) else Color(0xFFFF453A),
            )
        }
    }
}
