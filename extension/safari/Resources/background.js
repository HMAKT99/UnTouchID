/**
 * TouchBridge Safari Extension — Background Script
 *
 * Communicates with the native messaging host (touchbridge-nmh) to
 * route browser autofill and WebAuthn requests through the TouchBridge daemon.
 */

const NMH_NAME = "dev.touchbridge.nmh";

// Listen for messages from content scripts
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "touchbridge_auth_request") {
        handleAuthRequest(message, sender.tab)
            .then(result => sendResponse(result))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true; // async response
    }

    if (message.type === "touchbridge_status") {
        checkDaemonStatus()
            .then(status => sendResponse(status))
            .catch(() => sendResponse({ connected: false }));
        return true;
    }
});

/**
 * Send an authentication request to the native messaging host.
 */
async function handleAuthRequest(message, tab) {
    const request = {
        action: "authenticate",
        surface: message.surface || "browser_autofill",
        url: tab ? tab.url : "",
        title: tab ? tab.title : "",
    };

    try {
        const response = await browser.runtime.sendNativeMessage(NMH_NAME, request);
        if (response && response.result === "success") {
            return { success: true };
        }
        return { success: false, reason: response?.reason || "denied" };
    } catch (err) {
        console.error("TouchBridge NMH error:", err);
        return { success: false, reason: "nmh_unavailable" };
    }
}

/**
 * Check if the daemon is running and a companion is connected.
 */
async function checkDaemonStatus() {
    try {
        const response = await browser.runtime.sendNativeMessage(NMH_NAME, {
            action: "status",
        });
        return { connected: response?.connected || false };
    } catch {
        return { connected: false };
    }
}
