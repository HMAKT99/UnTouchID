/*
 * pam_touchbridge.c — TouchBridge PAM module
 *
 * Connects to the TouchBridge daemon via a Unix domain socket and
 * requests biometric authentication on the user's paired iOS device.
 *
 * PAM config line:
 *   auth  sufficient  pam_touchbridge.so [timeout=15]
 *
 * If "sufficient", a successful TouchBridge auth skips the password prompt.
 * If TouchBridge fails (timeout, no device, etc.), PAM falls through to
 * the next module (typically password).
 *
 * Security notes:
 * - Never logs nonces, keys, or passwords
 * - Socket path derived from target user's home directory (not env vars)
 * - Fixed-size buffers prevent overflow
 * - All socket fds closed on all code paths
 */

#include "pam_touchbridge.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <errno.h>
#include <syslog.h>

/* Maximum sizes */
#define MAX_SOCK_PATH  256
#define MAX_REQUEST    512
#define MAX_RESPONSE   512
#define DEFAULT_TIMEOUT 15

/*
 * Build the socket path for the target user.
 * Path: <homedir>/Library/Application Support/TouchBridge/daemon.sock
 */
static int build_socket_path(const char *username, char *path, size_t pathlen)
{
    struct passwd *pw = getpwnam(username);
    if (pw == NULL) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: getpwnam failed for user %s", username);
        return -1;
    }

    int ret = snprintf(path, pathlen,
        "%s/Library/Application Support/TouchBridge/daemon.sock",
        pw->pw_dir);

    if (ret < 0 || (size_t)ret >= pathlen) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket path too long");
        return -1;
    }

    return 0;
}

/*
 * Parse the timeout=N argument from PAM module arguments.
 * Returns the timeout in seconds, or DEFAULT_TIMEOUT if not specified.
 */
static int parse_timeout(int argc, const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= 300) {
                return t;
            }
        }
    }
    return DEFAULT_TIMEOUT;
}

/*
 * Connect to the daemon's Unix domain socket.
 * Returns the socket fd on success, -1 on failure.
 */
static int connect_to_daemon(const char *sock_path, int timeout_sec)
{
    int fd = -1;
    struct sockaddr_un addr;
    struct timeval tv;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket() failed: %s", strerror(errno));
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket path too long");
        close(fd);
        return -1;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        syslog(LOG_AUTH | LOG_WARNING,
            "pam_touchbridge: connect failed: %s (daemon may not be running)",
            strerror(errno));
        close(fd);
        return -1;
    }

    /* Set receive timeout */
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    return fd;
}

/*
 * pam_sm_authenticate — main authentication entry point.
 *
 * Connects to the TouchBridge daemon socket, sends an auth request,
 * and waits for the daemon to verify the user via their companion device.
 */
PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    const char *user = NULL;
    const char *service = NULL;
    char sock_path[MAX_SOCK_PATH];
    char request[MAX_REQUEST];
    char response[MAX_RESPONSE];
    int fd = -1;
    int ret = PAM_AUTH_ERR;
    int timeout_sec;
    ssize_t bytes;

    (void)flags; /* unused */

    /* Get the target username */
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: failed to get username");
        return PAM_AUTH_ERR;
    }

    /* Get the PAM service name */
    if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS
        || service == NULL) {
        service = "unknown";
    }

    /* Parse timeout from module arguments */
    timeout_sec = parse_timeout(argc, argv);

    syslog(LOG_AUTH | LOG_INFO,
        "pam_touchbridge: auth request for user=%s service=%s timeout=%d",
        user, service, timeout_sec);

    /* Build socket path from the target user's home directory */
    if (build_socket_path(user, sock_path, sizeof(sock_path)) != 0) {
        goto cleanup;
    }

    /* Connect to daemon */
    fd = connect_to_daemon(sock_path, timeout_sec);
    if (fd < 0) {
        goto cleanup;
    }

    /* Build JSON request — simple snprintf, no JSON library needed */
    bytes = snprintf(request, sizeof(request),
        "{\"action\":\"authenticate\",\"user\":\"%s\",\"service\":\"%s\",\"pid\":%d}\n",
        user, service, getpid());

    if (bytes < 0 || (size_t)bytes >= sizeof(request)) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: request too large");
        goto cleanup;
    }

    /* Send request */
    if (send(fd, request, (size_t)bytes, 0) != bytes) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: send failed: %s", strerror(errno));
        goto cleanup;
    }

    /* Receive response */
    memset(response, 0, sizeof(response));
    bytes = recv(fd, response, sizeof(response) - 1, 0);

    if (bytes <= 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            syslog(LOG_AUTH | LOG_WARNING,
                "pam_touchbridge: timeout waiting for companion device");
        } else {
            syslog(LOG_AUTH | LOG_ERR,
                "pam_touchbridge: recv failed: %s", strerror(errno));
        }
        goto cleanup;
    }

    response[bytes] = '\0';

    /* Check for success — simple string search, no JSON parser needed */
    if (strstr(response, "\"result\":\"success\"") != NULL) {
        syslog(LOG_AUTH | LOG_INFO,
            "pam_touchbridge: authentication succeeded for user=%s", user);
        ret = PAM_SUCCESS;
    } else {
        syslog(LOG_AUTH | LOG_INFO,
            "pam_touchbridge: authentication failed for user=%s", user);
        ret = PAM_AUTH_ERR;
    }

cleanup:
    if (fd >= 0) {
        close(fd);
    }
    return ret;
}

/*
 * pam_sm_setcred — credential management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

/*
 * pam_sm_acct_mgmt — account management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
