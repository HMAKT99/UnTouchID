/**
 * TouchBridge Chrome Extension — Background Service Worker
 *
 * Communicates with the native messaging host (touchbridge-nmh) to
 * route browser autofill and WebAuthn requests through the TouchBridge daemon.
 */

const NMH_NAME = "dev.touchbridge.nmh";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "touchbridge_auth_request") {
        handleAuthRequest(message, sender.tab)
            .then(result => sendResponse(result))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true;
    }

    if (message.type === "touchbridge_status") {
        checkDaemonStatus()
            .then(status => sendResponse(status))
            .catch(() => sendResponse({ connected: false }));
        return true;
    }
});

async function handleAuthRequest(message, tab) {
    return new Promise((resolve) => {
        const port = chrome.runtime.connectNative(NMH_NAME);
        const request = {
            action: "authenticate",
            surface: message.surface || "browser_autofill",
            url: tab ? tab.url : "",
            title: tab ? tab.title : "",
        };

        port.onMessage.addListener((response) => {
            port.disconnect();
            if (response && response.result === "success") {
                resolve({ success: true });
            } else {
                resolve({ success: false, reason: response?.reason || "denied" });
            }
        });

        port.onDisconnect.addListener(() => {
            resolve({ success: false, reason: "nmh_disconnected" });
        });

        port.postMessage(request);
    });
}

async function checkDaemonStatus() {
    return new Promise((resolve) => {
        try {
            const port = chrome.runtime.connectNative(NMH_NAME);
            port.onMessage.addListener((response) => {
                port.disconnect();
                resolve({ connected: response?.connected || false });
            });
            port.onDisconnect.addListener(() => {
                resolve({ connected: false });
            });
            port.postMessage({ action: "status" });
        } catch {
            resolve({ connected: false });
        }
    });
}
