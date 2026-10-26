#import "evidence.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(const char *message) { fprintf(stderr,"touchbridge-trust: %s\n",message);return 1; }
static BOOL confirm(NSString *label,NSString *fingerprint) {
    FILE *tty=fopen("/dev/tty","r+");if(!tty)return NO;
    fprintf(tty,"%s SHA-256: %s\nVerify this fingerprint against the paired phone.\nType the complete fingerprint to confirm: ",
        label.UTF8String,fingerprint.UTF8String);fflush(tty);
    char input[256];BOOL ok=fgets(input,sizeof(input),tty)!=NULL;fclose(tty);
    if(!ok)return NO;
    NSString *entered=[[@(input) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [entered isEqual:fingerprint];
}
static BOOL prepareDirectory(void) {
    int parent=tb_open_secure_directory("/Library/Security",0);if(parent<0)return NO;
    if(mkdirat(parent,"TouchBridge",0755)!=0 && errno!=EEXIST){close(parent);return NO;}close(parent);
    int base=tb_open_secure_directory(TB_MODULE_DIR,0);if(base<0)return NO;
    if(mkdirat(base,"Trust",0700)!=0 && errno!=EEXIST){close(base);return NO;}close(base);
    return tb_check_secure_path(TB_TRUST_DIR,0,1);
}
static BOOL writeTrust(int dir,NSString *name,NSDictionary *trust) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:trust format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if(!data)return NO;
    NSString *temp=[@".pending-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(dir,temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
    size_t offset=0;BOOL good=YES;
    while(offset<data.length) { ssize_t n=write(fd,(const uint8_t *)data.bytes+offset,data.length-offset);
        if(n<0 && errno==EINTR)continue;if(n<=0){good=NO;break;}offset+=(size_t)n; }
    if(fsync(fd)!=0)good=NO;if(close(fd)!=0)good=NO;
    if(good && renameat(dir,temp.fileSystemRepresentation,dir,name.fileSystemRepresentation)!=0)good=NO;
    if(!good)unlinkat(dir,temp.fileSystemRepresentation,0);
    if(good && fsync(dir)!=0)good=NO;return good;
}
static BOOL parseUID(const char *s,uid_t *uid) {
    if(!s||!*s)return NO;for(const char *p=s;*p;p++)if(*p<'0'||*p>'9')return NO;
    char *end=NULL;errno=0;unsigned long long n=strtoull(s,&end,10);
    if(errno||*end||n>UINT32_MAX)return NO;*uid=(uid_t)n;return YES;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==4 && !strcmp(argv[1],"check")) {
        if(strcmp(argv[3],"directory") && strcmp(argv[3],"file"))return fail("check expects directory or file");
        return tb_check_secure_path(argv[2],0,!strcmp(argv[3],"directory"))?0:fail("unsafe path owner, permissions, ACL, type or symlink");
    }
    if(argc==2 && !strcmp(argv[1],"prepare")) {
        if(geteuid()!=0)return fail("root administration is required");
        return prepareDirectory()?0:fail("cannot prepare secure root directories; shared ancestors were not changed");
    }
    if(argc<3)return fail("usage: check PATH file|directory; prepare; list UID; enroll UID DEVICE_ID MAC_PUBLIC_KEY_BASE64 DEVICE_PUBLIC_KEY_BASE64; revoke UID DEVICE_ID");
    if(geteuid()!=0)return fail("root administration is required; use trusted password/root authorization, not a legacy phone PAM hook");
    uid_t uid;if(!parseUID(argv[2],&uid))return fail("invalid numeric target UID");
    if(!tb_check_secure_path(TB_MODULE_DIR "/touchbridge-trust",0,0))return fail("admin binary is not installed on a trusted root path");
    int dir=tb_open_secure_directory(TB_TRUST_DIR,0);if(dir<0)return fail("missing or unsafe trust directory");
    NSString *name=[NSString stringWithFormat:@"%u.plist",uid];struct stat st;
    BOOL exists=fstatat(dir,name.fileSystemRepresentation,&st,AT_SYMLINK_NOFOLLOW)==0;
    if(!exists && errno!=ENOENT){close(dir);return fail("cannot inspect trust record");}
    NSDictionary *existing=exists?tb_load_trust(uid):nil;
    if(exists&&!existing){close(dir);return fail("existing trust record is unsafe or invalid; refusing replacement");}
    if(argc==3 && !strcmp(argv[1],"list")) {
        if(!existing){close(dir);return fail("no enrolled trust for target UID");}
        printf("UID: %u\nMacIdentityHash: %s\n",uid,[[existing[@"MacIdentityHash"] description] UTF8String]);
        for(NSDictionary *device in existing[@"Devices"])printf("%s SHA-256 %s\n",[device[@"DeviceID"] UTF8String],tb_fingerprint(device[@"PublicKey"]).UTF8String);
        close(dir);return 0;
    }
    if(argc==6 && !strcmp(argv[1],"enroll")) {
        NSString *deviceID=@(argv[3]);NSData *macKey=[[NSData alloc] initWithBase64EncodedString:@(argv[4]) options:0];
        NSData *deviceKey=[[NSData alloc] initWithBase64EncodedString:@(argv[5]) options:0];
        SecKeyRef mac=tb_public_key(macKey),phone=tb_public_key(deviceKey);
        if(!tb_valid_device_id(deviceID)||!mac||!phone){if(mac)CFRelease(mac);if(phone)CFRelease(phone);close(dir);return fail("invalid device ID or P-256 public key");}
        CFRelease(mac);CFRelease(phone);uint8_t digest[32];CC_SHA256(macKey.bytes,(CC_LONG)macKey.length,digest);
        NSData *hash=[NSData dataWithBytes:digest length:32];
        if(existing && ![existing[@"MacIdentityHash"] isEqual:hash]){close(dir);return fail("Mac identity differs: revoke existing pins explicitly before enrolling a new identity");}
        NSMutableArray *devices=existing?[existing[@"Devices"] mutableCopy]:[NSMutableArray array];
        for(NSDictionary *device in devices)if([device[@"DeviceID"] isEqual:deviceID]){close(dir);return fail("device ID is already enrolled; revoke it explicitly before any replacement");}
        if(!confirm(@"Mac identity",tb_fingerprint(macKey))||!confirm(@"Phone signing key",tb_fingerprint(deviceKey))){close(dir);return fail("fingerprint confirmation failed; no trust was changed");}
        [devices addObject:@{@"DeviceID":deviceID,@"PublicKey":deviceKey}];
        NSDictionary *trust=@{@"Version":@2,@"UID":@(uid),@"MacIdentityHash":hash,@"Devices":devices};
        BOOL good=tb_validate_trust(trust,uid)&&writeTrust(dir,name,trust);close(dir);
        if(!good||![tb_load_trust(uid) isEqual:trust])return fail("trust write/readback failed");
        puts("Enrollment saved and verified. User Keychain records were not imported automatically.");return 0;
    }
    if(argc==4 && !strcmp(argv[1],"revoke")) {
        if(!existing||!tb_valid_device_id(@(argv[3]))){close(dir);return fail("no matching enrolled device");}
        NSMutableArray *devices=[existing[@"Devices"] mutableCopy];NSDictionary *found=nil;
        for(NSDictionary *device in devices)if([device[@"DeviceID"] isEqual:@(argv[3])]){found=device;break;}
        if(!found||!confirm(@"Revoke phone signing key",tb_fingerprint(found[@"PublicKey"]))){close(dir);return fail("revocation not confirmed");}
        [devices removeObject:found];BOOL good;
        if(devices.count==0)good=unlinkat(dir,name.fileSystemRepresentation,0)==0&&fsync(dir)==0;
        else { NSMutableDictionary *trust=[existing mutableCopy];trust[@"Devices"]=devices;good=writeTrust(dir,name,trust); }
        close(dir);if(!good)return fail("revocation write failed");
        NSDictionary *readback=tb_load_trust(uid);
        for(NSDictionary *device in readback[@"Devices"])if([device[@"DeviceID"] isEqual:@(argv[3])])return fail("revocation readback failed");
        puts("Root trust revoked. Remove pairing/signing state on the phone separately.");return 0;
    }
    close(dir);return fail("invalid arguments");
} }
