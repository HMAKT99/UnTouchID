package dev.touchbridge.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import dev.touchbridge.android.ui.screens.*
import dev.touchbridge.android.ui.theme.TouchBridgeTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            TouchBridgeTheme {
                val viewModel: TouchBridgeViewModel = viewModel(
                    factory = TouchBridgeViewModel.Factory(applicationContext)
                )
                val uiState by viewModel.uiState.collectAsState()

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    if (uiState.isPaired) {
                        MainScreen(viewModel = viewModel, uiState = uiState)
                    } else {
                        OnboardingScreen(viewModel = viewModel)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: TouchBridgeViewModel, uiState: TouchBridgeUiState) {
    val navController = rememberNavController()

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = true,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_lock_idle_lock), "Home") },
                    label = { Text("Home") }
                )
                NavigationBarItem(
                    selected = false,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_recent_history), "Activity") },
                    label = { Text("Activity") }
                )
                NavigationBarItem(
                    selected = false,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_preferences), "Settings") },
                    label = { Text("Settings") }
                )
            }
        }
    ) { padding ->
        HomeScreen(
            viewModel = viewModel,
            uiState = uiState,
            modifier = Modifier.padding(padding)
        )
    }
}

@Composable
fun OnboardingScreen(viewModel: TouchBridgeViewModel) {
    var showPairing by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Spacer(modifier = Modifier.weight(1f))

        // Icon
        Text(
            text = "🔐",
            fontSize = 72.sp,
            modifier = Modifier.padding(bottom = 16.dp)
        )

        Text(
            text = "TouchBridge",
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )

        Text(
            text = "Use your fingerprint or face to\nauthenticate on your Mac.",
            fontSize = 16.sp,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp, bottom = 32.dp)
        )

        // Features
        FeatureItem(icon = "🔒", title = "Secure", desc = "Keys stored in hardware security module")
        FeatureItem(icon = "📡", title = "Wireless", desc = "Connects via Bluetooth LE")
        FeatureItem(icon = "👆", title = "Biometric", desc = "Fingerprint or face — no passwords")

        Spacer(modifier = Modifier.weight(1f))

        if (showPairing) {
            PairingScreen(viewModel = viewModel)
        } else {
            Button(
                onClick = { showPairing = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
            ) {
                Text("Get Started", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
fun FeatureItem(icon: String, title: String, desc: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(icon, fontSize = 24.sp, modifier = Modifier.padding(end = 16.dp))
        Column {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(desc, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
