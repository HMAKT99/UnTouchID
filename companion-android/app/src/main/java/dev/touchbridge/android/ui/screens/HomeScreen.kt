package dev.touchbridge.android.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun HomeScreen(
    viewModel: TouchBridgeViewModel,
    uiState: TouchBridgeUiState,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(modifier = Modifier.height(32.dp))

        // Status indicator
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(120.dp)
                .clip(CircleShape)
        ) {
            Surface(
                color = if (uiState.isConnected)
                    Color(0xFF30D158).copy(alpha = 0.15f)
                else
                    Color.Gray.copy(alpha = 0.1f),
                shape = CircleShape,
                modifier = Modifier.fillMaxSize()
            ) {}

            Text(
                text = "🔐",
                fontSize = 48.sp,
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Connection status
        Row(verticalAlignment = Alignment.CenterVertically) {
            Surface(
                color = if (uiState.isConnected) Color(0xFF30D158) else Color(0xFFFF9500),
                shape = CircleShape,
                modifier = Modifier.size(8.dp)
            ) {}
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = uiState.statusMessage,
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        uiState.pairedMacName?.let { name ->
            Text(
                text = name,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        Spacer(modifier = Modifier.height(32.dp))

        // Stats
        if (uiState.challengeCount > 0) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                StatCard("Authenticated", "${uiState.challengeCount}")
                uiState.lastChallenge?.let { last ->
                    StatCard("Last", last)
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        // Reconnect button
        if (!uiState.isConnected) {
            Button(
                onClick = { viewModel.startScanning() },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
            ) {
                Text("Reconnect")
            }
        }

        // Unpair button
        TextButton(
            onClick = { viewModel.unpair() },
            colors = ButtonDefaults.textButtonColors(
                contentColor = MaterialTheme.colorScheme.error
            )
        ) {
            Text("Unpair")
        }
    }
}

@Composable
fun StatCard(title: String, value: String) {
    Card(
        modifier = Modifier
            .width(150.dp)
            .padding(4.dp)
    ) {
        Column(
            modifier = Modifier
                .padding(16.dp)
                .fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(value, fontWeight = FontWeight.Bold, fontSize = 16.sp)
            Text(title, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
