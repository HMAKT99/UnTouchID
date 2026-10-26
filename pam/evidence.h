#ifndef TB_EVIDENCE_H
#define TB_EVIDENCE_H
#include <sys/types.h>

#define TB_MODULE_DIR "/Library/Security/TouchBridge"
#define TB_MODULE_PATH TB_MODULE_DIR "/pam_touchbridge.so"
#define TB_TRUST_DIR TB_MODULE_DIR "/Trust"

int tb_authenticate(const char *user, const char *service, uid_t uid,
                    const char *home, unsigned timeout);
int tb_check_secure_path(const char *path, uid_t owner, int directory);
int tb_open_secure_directory(const char *path, uid_t owner);

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Security/Security.h>
NSData *tb_build_challenge(NSData *nonce, NSData *macHash, uint32_t uid,
                         uint32_t pid, uint64_t issued, uint64_t expiry,
                         NSString *user, NSString *service);
BOOL tb_validate_trust(NSDictionary *trust, uid_t uid);
BOOL tb_verify_response(NSData *frame, NSDictionary *trust, NSData *challenge,
                        uint64_t now, BOOL deadlineValid);
NSData *tb_read_secure_file(const char *path, uid_t owner);
BOOL tb_valid_device_id(NSString *identifier);
SecKeyRef tb_public_key(NSData *data);
NSString *tb_fingerprint(NSData *data);
NSDictionary *tb_load_trust(uid_t uid);
#endif
#endif
