/**
 * TouchBridge Chrome Extension — Content Script
 *
 * Same functionality as Safari version — intercepts autofill and WebAuthn.
 */

(function () {
    "use strict";

    const observer = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    checkForPasswordFields(node);
                }
            }
        }
    });

    if (document.body) {
        observer.observe(document.body, { childList: true, subtree: true });
        checkForPasswordFields(document.body);
    }

    function checkForPasswordFields(root) {
        const fields = root.querySelectorAll
            ? root.querySelectorAll('input[type="password"]')
            : [];

        for (const field of fields) {
            if (!field.dataset.touchbridge) {
                field.dataset.touchbridge = "monitored";
                field.addEventListener("focus", onPasswordFieldFocus);
            }
        }
    }

    function onPasswordFieldFocus(event) {
        chrome.runtime.sendMessage({ type: "touchbridge_status" }, (status) => {
            if (status && status.connected) {
                showTouchBridgeBanner(event.target);
            }
        });
    }

    function showTouchBridgeBanner(field) {
        if (document.getElementById("touchbridge-banner")) return;

        const banner = document.createElement("div");
        banner.id = "touchbridge-banner";
        banner.style.cssText = `
            position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
            background: #1a1a2e; color: white; padding: 12px 24px;
            border-radius: 12px; font-family: -apple-system, system-ui;
            font-size: 14px; z-index: 999999; display: flex;
            align-items: center; gap: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.3);
            cursor: pointer;
        `;
        banner.textContent = "TouchBridge — confirm on iPhone";
        banner.onclick = () => {
            chrome.runtime.sendMessage(
                { type: "touchbridge_auth_request", surface: "browser_autofill" },
                (result) => {
                    banner.remove();
                    if (result && result.success) {
                        field.dispatchEvent(new Event("touchbridge-autofill-approved"));
                    }
                }
            );
        };

        document.body.appendChild(banner);
        setTimeout(() => banner.remove(), 10000);
    }

    // WebAuthn interception
    if (window.PublicKeyCredential) {
        const originalGet = navigator.credentials.get.bind(navigator.credentials);
        navigator.credentials.get = async function (options) {
            if (options && options.publicKey) {
                const result = await new Promise((resolve) => {
                    chrome.runtime.sendMessage(
                        { type: "touchbridge_auth_request", surface: "browser_webauthn" },
                        resolve
                    );
                });

                if (!result || !result.success) {
                    throw new DOMException("User denied", "NotAllowedError");
                }
            }
            return originalGet(options);
        };
    }
})();
