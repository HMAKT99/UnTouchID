/* TouchBridge PAM: the user daemon is an untrusted evidence transport. */
#include "pam_touchbridge.h"
#include "evidence.h"
#include <errno.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

static void notify(pam_handle_t *pamh, const char *message)
{
    const struct pam_conv *conv = NULL;
    struct pam_message msg = { PAM_TEXT_INFO, (char *)message };
    const struct pam_message *pointer = &msg;
    struct pam_response *response = NULL;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) == PAM_SUCCESS && conv && conv->conv) {
        conv->conv(1, &pointer, &response, conv->appdata_ptr);
        if (response) { free(response->resp); free(response); }
    }
}

static unsigned timeout_seconds(int argc, const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            char *end = NULL;
            errno = 0;
            unsigned long value = strtoul(argv[i] + 8, &end, 10);
            if (errno || end == argv[i] + 8 || *end || value < 1 || value > 30) return 0;
            return (unsigned)value;
        }
    }
    return 15;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)flags;
    const char *user = NULL, *service = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user || !*user
        || pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS || !service)
        return PAM_AUTH_ERR;
    unsigned timeout = timeout_seconds(argc, argv);
    if (!timeout) return PAM_AUTH_ERR;
    long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t capacity = suggested > 0 && suggested <= 1048576 ? (size_t)suggested : 16384;
    char *buffer = malloc(capacity);
    if (!buffer) return PAM_AUTH_ERR;
    struct passwd record, *result = NULL;
    int status = getpwnam_r(user, &record, buffer, capacity, &result);
    int success = 0;
    if (status == 0 && result && record.pw_dir && record.pw_dir[0] == '/') {
        notify(pamh, "TouchBridge: check your paired phone and verify the user and service...");
        success = tb_authenticate(user, service, record.pw_uid, record.pw_dir, timeout);
    }
    free(buffer);
    syslog(LOG_AUTH | LOG_INFO, "pam_touchbridge: privileged proof %s", success ? "verified" : "rejected");
    notify(pamh, success ? "TouchBridge: authenticated" : "TouchBridge: no valid enrolled phone proof - using password");
    return success ? PAM_SUCCESS : PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_SUCCESS;
}
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_SUCCESS;
}
