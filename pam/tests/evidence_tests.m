#import "evidence.h"
#import <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <fcntl.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <membership.h>

static NSData *signData(SecKeyRef key, NSData *data) {
    return CFBridgingRelease(SecKeyCreateSignature(key,
        kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)data, NULL));
}
static NSData *frame(NSData *signature) {
    return [NSJSONSerialization dataWithJSONObject:@{@"result":@"success", @"proof":@{
        @"deviceID":@"phone-1", @"signature":[signature base64EncodedStringWithOptions:0]}}
        options:0 error:NULL];
}
typedef struct { int listener; SecKeyRef key; int mode; } Server;
static void *serve(void *context) { @autoreleasepool {
    Server *server=context;int fd=accept(server->listener,NULL,NULL);assert(fd>=0);
    NSMutableData *request=[NSMutableData data];char byte;
    while(recv(fd,&byte,1,0)==1 && byte!='\n')[request appendBytes:&byte length:1];
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:request options:0 error:NULL];
    assert([json[@"evidenceVersion"] isEqual:@2]);
    NSData *challenge=[[NSData alloc] initWithBase64EncodedString:json[@"challenge"] options:0];
    assert(challenge.length==111);
    NSData *reply=server->mode==0?[@"{\"result\":\"success\"}\n" dataUsingEncoding:NSUTF8StringEncoding]:frame(signData(server->key,challenge));
    NSMutableData *wire=[reply mutableCopy];if(server->mode!=0)[wire appendBytes:"\n" length:1];
    if(server->mode==2)[wire setLength:wire.length-2];
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    for(NSUInteger i=0;i<wire.length;i++) { if(send(fd,(const uint8_t *)wire.bytes+i,1,0)!=1)break; }
    close(fd);return NULL;
} }
static void socketRegression(NSDictionary *trust,SecKeyRef key,int mode,int expected) {
    extern int tb_test_authenticate(const char *,unsigned,NSDictionary *);
    char path[100];snprintf(path,sizeof(path),"/private/tmp/tb-proof-%d-%d.sock",getpid(),mode);
    int listener=socket(AF_UNIX,SOCK_STREAM,0);assert(listener>=0);struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;
    strlcpy(addr.sun_path,path,sizeof(addr.sun_path));assert(bind(listener,(struct sockaddr *)&addr,sizeof(addr))==0);assert(listen(listener,1)==0);
    Server server={listener,key,mode};pthread_t thread;assert(pthread_create(&thread,NULL,serve,&server)==0);
    assert(tb_test_authenticate(path,2,trust)==expected);assert(pthread_join(thread,NULL)==0);close(listener);unlink(path);
}
int main(void) { @autoreleasepool {
    NSDictionary *attrs = @{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                            (__bridge id)kSecAttrKeySizeInBits:@256};
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, NULL);
    SecKeyRef pub = SecKeyCopyPublicKey(key);
    NSData *publicBytes = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, NULL));
    NSData *nonce = [NSMutableData dataWithLength:32], *mac = [NSMutableData dataWithLength:32];
    NSData *challenge = tb_build_challenge(nonce,mac,501,123,100,115,@"alice",@"sudo");
    assert(challenge.length == 111);
    NSMutableString *hex=[NSMutableString string];
    for(NSUInteger i=0;i<challenge.length;i++)[hex appendFormat:@"%02x",((const uint8_t *)challenge.bytes)[i]];
    assert([hex isEqual:@"54422d4155544800020100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f50000007b000000000000006400000000000000730005616c69636500047375646f"]);
    const unsigned char *b = challenge.bytes;
    assert(memcmp(b,"TB-AUTH\0",8)==0 && b[8]==2 && b[9]==1 && b[80]==0 && b[81]==123);
    NSDictionary *trust = @{@"Version":@2,@"UID":@501,@"MacIdentityHash":mac,
        @"Devices":@[@{@"DeviceID":@"phone-1",@"PublicKey":publicBytes}]};
    assert(tb_validate_trust(trust,501));
    assert([tb_fingerprint([@"abc" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]);
    assert(!tb_validate_trust(trust,502));
    socketRegression(trust,key,0,0);
    socketRegression(trust,key,1,1);
    socketRegression(trust,key,2,0);
    NSData *good = frame(signData(key,challenge));
    assert(tb_verify_response(good,trust,challenge,101,YES));
    assert(!tb_verify_response(good,trust,challenge,116,YES));
    assert(!tb_verify_response(good,trust,challenge,101,NO));
    NSData *fresh = tb_build_challenge([@"01234567890123456789012345678901" dataUsingEncoding:NSUTF8StringEncoding],mac,501,123,100,115,@"alice",@"sudo");
    assert(!tb_verify_response(good,trust,fresh,101,YES));
    NSMutableData *modified = [challenge mutableCopy]; ((uint8_t *)modified.mutableBytes)[80] ^= 1;
    assert(!tb_verify_response(good,trust,modified,101,YES));
    SecKeyRef wrong = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs,NULL);
    assert(!tb_verify_response(frame(signData(wrong,challenge)),trust,challenge,101,YES));
    NSArray *bad = @[@"{\"result\":\"success\"}",@"{\"note\":\"\\\"result\\\":\\\"success\\\"\"}",
      @"{",@"[]",@"{\"proof\":{}}",@"{\"proof\":{\"deviceID\":\"phone-1\",\"signature\":7}}",@"{}garbage"];
    for (NSString *s in bad) assert(!tb_verify_response([s dataUsingEncoding:NSUTF8StringEncoding],trust,challenge,101,YES));
    assert(!tb_verify_response([good subdataWithRange:NSMakeRange(0,good.length-1)],trust,challenge,101,YES));
    assert(!tb_build_challenge(nonce,mac,501,0,100,115,@"alice",@"sudo"));
    assert(!tb_build_challenge(nonce,mac,501,123,100,131,@"alice",@"sudo"));
    assert(!tb_build_challenge(nonce,mac,501,123,100,115,@"alice\n",@"sudo"));
    assert(!tb_build_challenge(nonce,mac,501,123,100,115,@"alice",@"bad/service"));
    NSMutableDictionary *badTrust=[trust mutableCopy]; badTrust[@"Devices"]=@[@{@"DeviceID":@"../bad",@"PublicKey":publicBytes}];
    assert(!tb_validate_trust(badTrust,501));
    NSMutableData *invalidPoint=[NSMutableData dataWithLength:65];((uint8_t *)invalidPoint.mutableBytes)[0]=4;
    badTrust[@"Devices"]=@[@{@"DeviceID":@"phone-1",@"PublicKey":invalidPoint}];
    assert(!tb_validate_trust(badTrust,501));
    assert(!tb_check_secure_path("/tmp",getuid(),1));
    assert(!tb_check_secure_path("/private/tmp",getuid(),1));
    assert(!tb_check_secure_path("/does/not/exist",getuid(),0));
    // Test-only trusted base FD permits safe temporary fixtures despite writable /tmp ancestors.
#ifdef TB_TESTING
    extern int tb_test_secure_relative(int base, const char *path, uid_t owner, int directory);
    extern NSData *tb_test_read_relative(int base,const char *path,uid_t owner);
    char tmp[]="/private/tmp/tb-pam-tests-XXXXXX"; assert(mkdtemp(tmp));
    int base=open(tmp,O_RDONLY|O_DIRECTORY|O_NOFOLLOW); assert(base>=0);
    assert(mkdirat(base,"safe",0700)==0);
    int file=openat(base,"safe/key",O_CREAT|O_EXCL|O_WRONLY,0600); assert(file>=0);assert(write(file,"fixture",7)==7); close(file);
    assert(tb_test_secure_relative(base,"safe/key",getuid(),0));
    assert([tb_test_read_relative(base,"safe/key",getuid()) isEqual:[@"fixture" dataUsingEncoding:NSUTF8StringEncoding]]);
    assert(linkat(base,"safe/key",base,"hardlink",0)==0);
    assert(!tb_test_read_relative(base,"safe/key",getuid()));assert(unlinkat(base,"hardlink",0)==0);
    assert(!tb_test_secure_relative(base,"../escape",getuid(),0));
    assert(!tb_test_secure_relative(base,"/absolute",getuid(),0));
    assert(!tb_test_secure_relative(base,"safe/key",getuid()+1,0));
    assert(symlinkat("safe/key",base,"link")==0);
    assert(!tb_test_secure_relative(base,"link",getuid(),0));
    assert(!tb_test_read_relative(base,"link",getuid()));
    assert(fchmodat(base,"safe",0770,0)==0);
    assert(!tb_test_secure_relative(base,"safe/key",getuid(),0));
    assert(fchmodat(base,"safe",0700,0)==0);
    NSString *safe=[NSString stringWithFormat:@"%s/safe",tmp];
    acl_t acl=acl_init(1);acl_entry_t entry;acl_permset_t perms;uuid_t identity;
    assert(acl && mbr_uid_to_uuid(getuid(),identity)==0 && acl_create_entry(&acl,&entry)==0);
    assert(acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)==0 && acl_set_qualifier(entry,identity)==0);
    assert(acl_get_permset(entry,&perms)==0 && acl_add_perm(perms,ACL_WRITE_DATA)==0 && acl_set_permset(entry,perms)==0);
    assert(acl_set_file(safe.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0);
    assert(!tb_test_secure_relative(base,"safe/key",getuid(),0));acl_free(acl);
    close(base); [[NSFileManager defaultManager] removeItemAtPath:@(tmp) error:NULL];
#endif
    CFRelease(key); CFRelease(pub); CFRelease(wrong);
    puts("PASS: native PAM evidence, forgery/replay/context/parser/trust/path regressions");
} return 0; }
