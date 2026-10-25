#import "evidence.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/acl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

#define TB_MAX_FRAME 4096
#define TB_MAX_TRUST 65536

static BOOL integer(id value, uint64_t expected) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
        && !CFNumberIsFloatType((__bridge CFNumberRef)value) && [value longLongValue]>=0
        && [value unsignedLongLongValue]==expected;
}
static BOOL asciiAllowed(NSString *s, NSString *chars, NSUInteger maximum) {
    if (![s isKindOfClass:NSString.class] || s.length<1 || s.length>maximum) return NO;
    return [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:chars] invertedSet]].location==NSNotFound;
}
BOOL tb_valid_device_id(NSString *s) {
    return asciiAllowed(s,@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-",128);
}
SecKeyRef tb_public_key(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length!=65 || ((const uint8_t *)data.bytes)[0]!=4) return NULL;
    NSDictionary *attrs=@{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPublic,(__bridge id)kSecAttrKeySizeInBits:@256};
    return SecKeyCreateWithData((__bridge CFDataRef)data,(__bridge CFDictionaryRef)attrs,NULL);
}
NSString *tb_fingerprint(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];
    for (unsigned i=0;i<sizeof(digest);i++) [hex appendFormat:@"%02x",digest[i]];
    return hex;
}
BOOL tb_validate_trust(NSDictionary *trust, uid_t uid) {
    if (![trust isKindOfClass:NSDictionary.class] || !integer(trust[@"Version"],2) || !integer(trust[@"UID"],uid)
        || ![trust[@"MacIdentityHash"] isKindOfClass:NSData.class] || [trust[@"MacIdentityHash"] length]!=32
        || ![trust[@"Devices"] isKindOfClass:NSArray.class] || [trust[@"Devices"] count]<1 || [trust[@"Devices"] count]>64) return NO;
    NSMutableSet *ids=[NSMutableSet set];
    for (id device in trust[@"Devices"]) {
        if (![device isKindOfClass:NSDictionary.class] || !tb_valid_device_id(device[@"DeviceID"])
            || [ids containsObject:device[@"DeviceID"]]) return NO;
        SecKeyRef key=tb_public_key(device[@"PublicKey"]); if(!key) return NO; CFRelease(key);
        [ids addObject:device[@"DeviceID"]];
    }
    return YES;
}
static BOOL secureFD(int fd,uid_t owner,BOOL directory) {
    struct stat st;
    if(fstat(fd,&st)!=0 || st.st_uid!=owner || (st.st_mode&0022)!=0
        || (directory?!S_ISDIR(st.st_mode):!S_ISREG(st.st_mode))) return NO;
    errno=0; acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl) return errno==ENOENT;
    if(acl_valid(acl)!=0){acl_free(acl);return NO;}
    acl_entry_t entry; int result=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry); acl_free(acl);
    // Conservatively reject extended ACLs, including inherited ACLs.
    // Darwin returns zero when an entry exists (unlike the POSIX 1 convention).
    return result!=0;
}
static int secureRelativeFD(int base,const char *path,uid_t owner,BOOL directory) {
    if(!path || !*path || *path=='/' || !secureFD(base,owner,YES)) return -1;
    char *copy=strdup(path); if(!copy) return -1;
    int current=dup(base); char *save=NULL; char *part=strtok_r(copy,"/",&save);
    while(part && current>=0) {
        if(!strcmp(part,".") || !strcmp(part,"..")) { close(current); current=-1; break; }
        char *next=strtok_r(NULL,"/",&save); BOOL isDir=next!=NULL || directory;
        int fd=openat(current,part,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(isDir?O_DIRECTORY:0)|O_NONBLOCK);
        close(current); current=fd;
        if(fd<0 || !secureFD(fd,owner,isDir)) { if(fd>=0) close(fd); current=-1; break; }
        part=next;
    }
    free(copy); return current;
}
static int securePathFD(const char *path,uid_t owner,BOOL directory) {
    if(!path || path[0]!='/' || strlen(path)>=PATH_MAX) return -1;
    int root=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if(root<0) return -1;
    int result=secureRelativeFD(root,path+1,owner,directory); close(root); return result;
}
int tb_check_secure_path(const char *path,uid_t owner,int directory) {
    int fd=securePathFD(path,owner,directory!=0); if(fd<0) return 0; close(fd); return 1;
}
int tb_open_secure_directory(const char *path,uid_t owner) { return securePathFD(path,owner,YES); }
#ifdef TB_TESTING
int tb_test_secure_relative(int base,const char *path,uid_t owner,int directory) {
    int fd=secureRelativeFD(base,path,owner,directory!=0); if(fd<0)return 0; close(fd);return 1;
}
#endif
static NSData *readSecureFD(int fd) {
    if(fd<0)return nil;
    struct stat before,after; NSMutableData *data=nil;
    if(fstat(fd,&before)==0 && before.st_size>0 && before.st_size<=TB_MAX_TRUST && before.st_nlink==1) {
        data=[NSMutableData dataWithLength:(NSUInteger)before.st_size]; size_t offset=0;
        while(offset<data.length) { ssize_t n=read(fd,(uint8_t *)data.mutableBytes+offset,data.length-offset);
            if(n<0 && errno==EINTR)continue; if(n<=0){data=nil;break;} offset+=(size_t)n; }
        char tail;
        if(data && (read(fd,&tail,1)!=0 || fstat(fd,&after)!=0 || before.st_size!=after.st_size
            || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec))data=nil;
    }
    close(fd); return data;
}
NSData *tb_read_secure_file(const char *path,uid_t owner) { return readSecureFD(securePathFD(path,owner,NO)); }
#ifdef TB_TESTING
NSData *tb_test_read_relative(int base,const char *path,uid_t owner) { return readSecureFD(secureRelativeFD(base,path,owner,NO)); }
#endif
NSDictionary *tb_load_trust(uid_t uid) {
    char path[PATH_MAX]; snprintf(path,sizeof(path),TB_TRUST_DIR "/%u.plist",uid);
    NSData *data=tb_read_secure_file(path,0); if(!data)return nil;
    id trust=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    return tb_validate_trust(trust,uid)?trust:nil;
}
static void appendInteger(NSMutableData *data,uint64_t value,unsigned bytes) {
    for(unsigned i=bytes;i>0;i--) { uint8_t b=(uint8_t)(value>>((i-1)*8)); [data appendBytes:&b length:1]; }
}
NSData *tb_build_challenge(NSData *nonce,NSData *macHash,uint32_t uid,uint32_t pid,
        uint64_t issued,uint64_t expiry,NSString *user,NSString *service) {
    if(nonce.length!=32 || macHash.length!=32 || !pid || expiry<=issued || expiry-issued>30
        || ![user isKindOfClass:NSString.class] || [user rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound
        || !asciiAllowed(service,@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-",64))return nil;
    NSData *username=[user dataUsingEncoding:NSUTF8StringEncoding]; NSData *surface=[service dataUsingEncoding:NSASCIIStringEncoding];
    if(username.length<1 || username.length>255)return nil;
    NSMutableData *out=[NSMutableData dataWithBytes:"TB-AUTH\0\2\1" length:10];
    [out appendData:nonce];[out appendData:macHash]; appendInteger(out,uid,4); appendInteger(out,pid,4);
    appendInteger(out,issued,8);appendInteger(out,expiry,8);appendInteger(out,username.length,2);[out appendData:username];
    appendInteger(out,surface.length,2);[out appendData:surface];return out;
}
static uint64_t readInteger(const uint8_t *b,unsigned n) { uint64_t v=0;for(unsigned i=0;i<n;i++)v=(v<<8)|b[i];return v; }
BOOL tb_verify_response(NSData *frame,NSDictionary *trust,NSData *challenge,uint64_t now,BOOL deadlineValid) {
    if(!deadlineValid || frame.length<2 || frame.length>TB_MAX_FRAME || challenge.length<102)return NO;
    const uint8_t *b=challenge.bytes;
    if(memcmp(b,"TB-AUTH\0\2\1",10)!=0 || !tb_validate_trust(trust,(uid_t)readInteger(b+74,4))
        || memcmp(b+42,[trust[@"MacIdentityHash"] bytes],32)!=0)return NO;
    uint64_t issued=readInteger(b+82,8),expiry=readInteger(b+90,8);
    if(issued>now || expiry<=now || expiry<=issued || expiry-issued>30)return NO;
    id response=[NSJSONSerialization JSONObjectWithData:frame options:0 error:NULL];
    if(![response isKindOfClass:NSDictionary.class])return NO;
    id proof=response[@"proof"]; if(![proof isKindOfClass:NSDictionary.class] || !tb_valid_device_id(proof[@"deviceID"])
        || ![proof[@"signature"] isKindOfClass:NSString.class] || [proof[@"signature"] length]>104)return NO;
    NSData *signature=[[NSData alloc] initWithBase64EncodedString:proof[@"signature"] options:0];
    if(signature.length<8 || signature.length>72)return NO;
    for(NSDictionary *device in trust[@"Devices"]) if([device[@"DeviceID"] isEqual:proof[@"deviceID"]]) {
        SecKeyRef key=tb_public_key(device[@"PublicKey"]);if(!key)return NO;
        BOOL valid=SecKeyVerifySignature(key,kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)challenge,(__bridge CFDataRef)signature,NULL);CFRelease(key);return valid;
    }
    return NO;
}
static double monotonic(void) { struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t)!=0)return -1;return t.tv_sec+t.tv_nsec/1e9; }
static BOOL ready(int fd,short events,double deadline) {
    for(;;) { double now=monotonic();if(now<0)return NO;double left=deadline-now;if(left<=0)return NO;
        struct pollfd p={fd,events,0};int r=poll(&p,1,(int)MIN(left*1000+1,INT_MAX));
        if(r<0 && errno==EINTR)continue;return r>0 && (p.revents&events)!=0; }
}
static NSData *exchange(int fd,NSData *request,double deadline) {
    size_t offset=0;
    while(offset<request.length) { if(!ready(fd,POLLOUT,deadline))return nil;
        ssize_t n=send(fd,(const uint8_t *)request.bytes+offset,request.length-offset,0);
        if(n<0 && (errno==EINTR||errno==EAGAIN))continue;if(n<=0)return nil;offset+=(size_t)n; }
    NSMutableData *out=[NSMutableData data];
    while(out.length<TB_MAX_FRAME) { if(!ready(fd,POLLIN,deadline))return nil;
        uint8_t buf[512];ssize_t n=recv(fd,buf,MIN(sizeof(buf),TB_MAX_FRAME-out.length),0);
        if(n<0 && (errno==EINTR||errno==EAGAIN))continue;if(n<=0)return nil;
        for(ssize_t i=0;i<n;i++)if(buf[i]=='\n') {
            if(i!=n-1)return nil;[out appendBytes:buf length:(NSUInteger)i];return out; }
        [out appendBytes:buf length:(NSUInteger)n];
    }
    return nil;
}
static int authenticateCore(const char *user,const char *service,uid_t uid,const char *socketPath,
                           unsigned timeout,NSDictionary *trust,BOOL refreshTrust) {
    if(!user||!service||!socketPath||timeout<1||timeout>30||!tb_validate_trust(trust,uid))return 0;
    NSString *username=[NSString stringWithUTF8String:user],*surface=[NSString stringWithUTF8String:service];
    if(!username||!surface)return 0;
    uint8_t random[32];if(SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)!=errSecSuccess)return 0;
    uint64_t now=(uint64_t)time(NULL);double start=monotonic();if(start<0)return 0;double deadline=start+timeout;
    NSData *challenge=tb_build_challenge([NSData dataWithBytes:random length:32],trust[@"MacIdentityHash"],uid,
        (uint32_t)getpid(),now,now+timeout,username,surface);if(!challenge)return 0;
    NSDictionary *request=@{@"action":@"authenticate",@"evidenceVersion":@2,@"challenge":[challenge base64EncodedStringWithOptions:0],
        @"user":username,@"service":surface,@"pid":@(getpid())};
    NSMutableData *wire=[[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL] mutableCopy];if(!wire)return 0;
    [wire appendBytes:"\n" length:1];
    struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;
    int length=snprintf(addr.sun_path,sizeof(addr.sun_path),"%s",socketPath);
    if(length<0 || (size_t)length>=sizeof(addr.sun_path))return 0;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return 0;int one=1;
    if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))!=0 || fcntl(fd,F_SETFL,O_NONBLOCK)!=0){close(fd);return 0;}
    fcntl(fd,F_SETFD,FD_CLOEXEC);
    if(connect(fd,(struct sockaddr *)&addr,sizeof(addr))!=0) {
        if(errno!=EINPROGRESS || !ready(fd,POLLOUT,deadline)){close(fd);return 0;}
        int error=0;socklen_t size=sizeof(error);if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size)!=0||error){close(fd);return 0;}
    }
    NSData *response=exchange(fd,wire,deadline);close(fd);
    // A root revocation during the phone prompt must take effect before success.
    NSDictionary *currentTrust=refreshTrust?tb_load_trust(uid):trust;
    double finished=monotonic();
    return response && tb_verify_response(response,currentTrust,challenge,(uint64_t)time(NULL),finished>=0&&finished<deadline);
}
#ifdef TB_TESTING
int tb_test_authenticate(const char *socketPath,unsigned timeout,NSDictionary *trust) {
    return authenticateCore("alice","sudo",501,socketPath,timeout,trust,NO);
}
#endif
int tb_authenticate(const char *user,const char *service,uid_t uid,const char *home,unsigned timeout) { @autoreleasepool {
    if(!home||!tb_check_secure_path(TB_MODULE_PATH,0,0))return 0;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int length=snprintf(path,sizeof(path),"%s/Library/Application Support/TouchBridge/daemon.sock",home);
    if(length<0||(size_t)length>=sizeof(path))return 0;
    return authenticateCore(user,service,uid,path,timeout,tb_load_trust(uid),YES);
} }
