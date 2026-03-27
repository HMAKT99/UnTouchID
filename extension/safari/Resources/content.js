/**
 * TouchBridge Safari Extension — Content Script
 *
 * Intercepts credential autofill prompts and WebAuthn requests,
 * routing them through TouchBridge for biometric confirmation.
 */

(function () {
    "use strict";

    // Observe password fields for autofill interception
    const observer = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    checkForPasswordFields(node);
                }
            }
        }
    });

    observer.observe(document.body, { childList: true, subtree: true });

    // Check existing password fields on load
    checkForPasswordFields(document.body);

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
        // When a password field is focused and autofill is available,
        // show a TouchBridge banner instead of the default autofill
        showTouchBridgeBanner(event.target);
    }

    function showTouchBridgeBanner(field) {
        // Check if TouchBridge is available
        browser.runtime.sendMessage({ type: "touchbridge_status" }).then((status) => {
            if (!status || !status.connected) return;

            // Create banner
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
                browser.runtime
                    .sendMessage({
                        type: "touchbridge_auth_request",
                        surface: "browser_autofill",
                    })
                    .then((result) => {
                        banner.remove();
                        if (result.success) {
                            // Autofill would proceed here
                            field.dispatchEvent(new Event("touchbridge-autofill-approved"));
                        }
                    });
            };

            document.body.appendChild(banner);

            // Auto-remove after 10 seconds
            setTimeout(() => banner.remove(), 10000);
        });
    }

    // Intercept WebAuthn credentials.get()
    if (window.PublicKeyCredential) {
        const originalGet = navigator.credentials.get.bind(navigator.credentials);
        navigator.credentials.get = async function (options) {
            if (options && options.publicKey) {
                // Route through TouchBridge
                const result = await browser.runtime.sendMessage({
                    type: "touchbridge_auth_request",
                    surface: "browser_webauthn",
                });

                if (!result || !result.success) {
                    throw new DOMException("User denied", "NotAllowedError");
                }
            }
            return originalGet(options);
        };
    }
})();
