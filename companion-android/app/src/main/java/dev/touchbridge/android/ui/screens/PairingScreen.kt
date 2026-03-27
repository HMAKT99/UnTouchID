package dev.touchbridge.android.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun PairingScreen(viewModel: TouchBridgeViewModel) {
    var manualInput by remember { mutableStateOf("") }
    var pairingState by remember { mutableStateOf("idle") } // idle, scanning, connecting, paired, error

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "Pair with your Mac",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 8.dp)
        )

        Text(
            text = "Run 'touchbridge-test pair' on your Mac,\nthen paste the JSON below.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(bottom = 16.dp)
        )

        when (pairingState) {
            "idle" -> {
                OutlinedTextField(
                    value = manualInput,
                    onValueChange = { manualInput = it },
                    label = { Text("Pairing JSON") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    maxLines = 6,
                )

                Spacer(modifier = Modifier.height(12.dp))

                Button(
                    onClick = {
                        pairingState = "connecting"
                        try {
                            val json = org.json.JSONObject(manualInput)
                            val macName = json.optString("macName", "Mac")
                            val serviceUUID = json.optString("serviceUUID", "")
                            viewModel.completePairing(macName, serviceUUID)
                            viewModel.startScanning()
                            pairingState = "paired"
                        } catch (e: Exception) {
                            pairingState = "error"
                        }
                    },
                    enabled = manualInput.isNotBlank(),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Pair")
                }

                Spacer(modifier = Modifier.height(8.dp))

                OutlinedButton(
                    onClick = {
                        pairingState = "scanning"
                        viewModel.startScanning()
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Scan for Nearby Mac")
                }
            }

            "scanning" -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Scanning for Mac...")
            }

            "connecting" -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Connecting...")
            }

            "paired" -> {
                Text(
                    text = "✅ Paired!",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            }

            "error" -> {
                Text(
                    text = "❌ Failed to parse pairing data",
                    color = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.height(8.dp))
                TextButton(onClick = { pairingState = "idle" }) {
                    Text("Try Again")
                }
            }
        }
    }
}
