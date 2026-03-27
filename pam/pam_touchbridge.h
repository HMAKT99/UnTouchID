/*
 * pam_touchbridge.h — TouchBridge PAM module
 *
 * Delegates macOS authentication to a companion iOS device
 * via the TouchBridge daemon's Unix domain socket.
 */

#ifndef PAM_TOUCHBRIDGE_H
#define PAM_TOUCHBRIDGE_H

#include <security/pam_appl.h>
#include <security/pam_modules.h>

/* PAM entry points */
PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv);
PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv);
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv);

#endif /* PAM_TOUCHBRIDGE_H */
