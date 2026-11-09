#include "zsign.hpp"
#include "common/common.h"
#include "common/json.h"
#include "openssl.h"
#include "macho.h"
#include "bundle.h"
#include <libgen.h>
#include <dirent.h>
#include <getopt.h>
#include <stdlib.h>
#include <openssl/ocsp.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/asn1.h>
#import <openssl/cms.h>
#include "timer.h"
#include "common/log.h"


NSString* getTmpDir() {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	return [[[paths objectAtIndex:0] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"tmp"];
}

extern "C" {

NSError* makeErrorFromLog(const std::vector<std::string>& vec) {
    NSMutableString *result = [NSMutableString string];
    
    for (size_t i = 0; i < vec.size(); ++i) {
        // Convert each std::string to NSString
        NSString *str = [NSString stringWithUTF8String:vec[i].c_str()];
        [result appendString:str];
        
        // Append newline if it's not the last element
        if (i != vec.size() - 1) {
            [result appendString:@"\n"];
        }
    }
    
    NSDictionary* userInfo = @{
        NSLocalizedDescriptionKey : result
    };
    return [NSError errorWithDomain:@"Failed to Sign" code:-1 userInfo:userInfo];
}

void zsign(NSString *appPath,
           NSData *prov,
           NSData *key,
           NSString *pass,
           NSProgress* progress,
           void(^completionHandler)(BOOL success, NSError *error))
{
    ZTimer gtimer;
    ZTimer timer;
    timer.Reset();
    
	bool bForce = false;
	bool bWeakInject = false;
	bool bDontGenerateEmbeddedMobileProvision = YES;
	
	string strPassword;

	string strDyLibFile;
	string strOutputFile;

	string strEntitlementsFile;

    const char* strPKeyFileData = (const char*)[key bytes];
    const char* strProvFileData = (const char*)[prov bytes];
	strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];
	
	
	string strPath = [appPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    ZLog::logs.clear();

	__block ZSignAsset zSignAsset;
	
    if (!zSignAsset.InitSimple(strPKeyFileData, (int)[key length], strProvFileData, (int)[prov length], strPassword)) {
        completionHandler(NO, makeErrorFromLog(ZLog::logs));
        ZLog::logs.clear();
		return;
	}
    
	bool bEnableCache = false;
	string strFolder = strPath;
	
	__block ZBundle bundle;
	bool success = bundle.ConfigureFolderSign(&zSignAsset, strFolder, "", "", "", strDyLibFile, bForce, bWeakInject, bEnableCache, bDontGenerateEmbeddedMobileProvision);

    if(!success) {
        completionHandler(NO, makeErrorFromLog(ZLog::logs));
        ZLog::logs.clear();
        return;
    }
    
    int filesNeedToSign = bundle.GetSignCount();
    [progress setTotalUnitCount:filesNeedToSign];
    bundle.progressHandler = [&progress] {
        [progress setCompletedUnitCount:progress.completedUnitCount + 1];
    };

    ZLog::PrintV(">>> Files Need to Sign: \t%d\n", filesNeedToSign);
    bool bRet = bundle.StartSign(bEnableCache);
    timer.PrintResult(bRet, ">>> Signed %s!", bRet ? "OK" : "Failed");
    gtimer.Print(">>> Done.");
    NSError* signError = nil;
    if(!bundle.signFailedFiles.empty()) {
        NSDictionary* userInfo = @{
            NSLocalizedDescriptionKey : [NSString stringWithUTF8String:bundle.signFailedFiles.c_str()]
        };
        signError = [NSError errorWithDomain:@"Failed to Sign" code:-1 userInfo:userInfo];
    }
    
    completionHandler(YES, signError);
    ZLog::logs.clear();
    
	return;
}

bool zsignMachO(NSString *machoPath,
                NSData *prov,
                NSData *key,
                NSString *pass)
{
    ZTimer gtimer;
    ZTimer timer;
    timer.Reset();

    string strPassword;
    const char* strPKeyFileData = (const char*)[key bytes];
    const char* strProvFileData = (const char*)[prov bytes];
    strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];

    ZLog::logs.clear();
    
    __block ZSignAsset zSignAsset;
    
    if (!zSignAsset.InitSimple(strPKeyFileData, (int)[key length], strProvFileData, (int)[prov length], strPassword)) {
        ZLog::logs.clear();
        return NO;
    }

    __block ZMachO* macho = new ZMachO();
    if (!macho->Init(machoPath.UTF8String)) {
        delete macho;
        ZLog::logs.clear();
        return NO;
    }
    
    string strInfoSHA1;
    string strInfoSHA256;
    string strCodeResourcesData;
    bool bRet = macho->Sign(&zSignAsset, true,
                            [[[NSBundle mainBundle] bundleIdentifier] UTF8String],
                            strInfoSHA1, strInfoSHA256, strCodeResourcesData);

    delete macho;

    timer.PrintResult(bRet, ">>> Mach-O Signed %s!", bRet ? "OK" : "Failed");
    gtimer.Print(">>> Done.");

    NSError* signError = nil;
    if (!bRet) {
        NSDictionary* userInfo = @{
            NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to sign Mach-O at path: %@", machoPath]
        };
        signError = [NSError errorWithDomain:@"MachOSignError" code:-1 userInfo:userInfo];
    }

    ZLog::logs.clear();
    return bRet;
}

bool adhocSignMachO(NSString *machoPath, NSString *bundleId, NSData* entitlementData) {
    ZSignAsset zSignAsset;
    zSignAsset.InitAdhoc([entitlementData bytes], (int)[entitlementData length]);
    
    ZMachO* macho = new ZMachO();
    if (!macho->Init(machoPath.UTF8String)) {
        ZLog::ErrorV(">>> Invalid mach-o file! %s\n", machoPath.UTF8String);
        return false;
    }

    string strInfoSHA1;
    string strInfoSHA256;
    string strCodeResourcesData;
    string strBundleId(bundleId.UTF8String);
    bool bRet = macho->Sign(&zSignAsset, true, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResourcesData);
    return bRet;
}

NSString* getTeamId(NSData *prov,
                    NSData *key,
                    NSString *pass) {
    string strPassword;

    const char* strPKeyFileData = (const char*)[key bytes];
    const char* strProvFileData = (const char*)[prov bytes];
    strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];
    
    ZLog::logs.clear();

    __block ZSignAsset zSignAsset;
    
    if (!zSignAsset.InitSimple(strPKeyFileData, (int)[key length], strProvFileData, (int)[prov length], strPassword)) {
        ZLog::logs.clear();
        return nil;
    }
    NSString* teamId = [NSString stringWithUTF8String:zSignAsset.m_strTeamId.c_str()];
    return teamId;
}

static NSDictionary *DecodeProvisioningProfile(NSData *prov,
                                               NSString **errorOut)
{
    if(!prov || prov.length == 0)
    {
        if(errorOut)
        {
            *errorOut = @"Provisioning profile is empty.";
        }
        return nil;
    }
    
    const unsigned char *bytes = (const unsigned char *)prov.bytes;
    CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &bytes, (long)prov.length);
    if(!cms)
    {
        if(errorOut)
        {
            *errorOut = @"Unable to decode provisioning profile CMS.";
        }
        return nil;
    }
    
    BIO *output = BIO_new(BIO_s_mem());
    if(!output)
    {
        CMS_ContentInfo_free(cms);
        if(errorOut)
        {
            *errorOut = @"Unable to allocate provisioning profile buffer.";
        }
        return nil;
    }
    
    unsigned int flags = CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY | CMS_NO_ATTR_VERIFY | CMS_NO_CONTENT_VERIFY;
    int result = CMS_verify(cms, NULL, NULL, NULL, output, flags);
    if(result != 1)
    {
        BIO_free(output);
        CMS_ContentInfo_free(cms);
        if(errorOut)
        {
            *errorOut = @"Unable to extract provisioning profile payload.";
        }
        return nil;
    }
    
    BUF_MEM *buffer = NULL;
    BIO_get_mem_ptr(output, &buffer);
    if(!buffer || !buffer->data || buffer->length == 0)
    {
        BIO_free(output);
        CMS_ContentInfo_free(cms);
        if(errorOut)
        {
            *errorOut = @"Provisioning profile contains no payload.";
        }
        return nil;
    }
    
    NSData *plistData = [NSData dataWithBytes:buffer->data length:buffer->length];
    NSError *plistError = nil;
    
    id plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NULL error:&plistError];
    
    BIO_free(output);
    CMS_ContentInfo_free(cms);
    
    if(![plist isKindOfClass:[NSDictionary class]])
    {
        if(errorOut)
        {
            *errorOut = plistError.localizedDescription ?: @"Invalid provisioning profile property list.";
        }
        return nil;
    }
    
    return (NSDictionary *)plist;
}

static BOOL ProvisionContainsCertificate(NSData *prov,
                                         X509 *certificate,
                                         NSString **errorOut)
{
    if(!certificate)
    {
        if(errorOut)
        {
            *errorOut = @"Certificate is missing.";
        }
        return NO;
    }
    
    NSDictionary *profile = DecodeProvisioningProfile(prov, errorOut);
    
    if(!profile)
    {
        return NO;
    }
    
    NSArray *developerCertificates = profile[@"DeveloperCertificates"];
    
    if(![developerCertificates isKindOfClass:[NSArray class]])
    {
        if(errorOut)
        {
            *errorOut = @"Provisioning profile does not contain DeveloperCertificates.";
        }
        
        return NO;
    }
    
    int derLength = i2d_X509(certificate, NULL);
    
    if(derLength <= 0)
    {
        if(errorOut)
        {
            *errorOut = @"Unable to encode certificate.";
        }
        return NO;
    }
    
    NSMutableData *certificateData = [NSMutableData dataWithLength:derLength];
    
    unsigned char *der = (unsigned char *)certificateData.mutableBytes;
    
    int written = i2d_X509(certificate, &der);
    if(written != derLength)
    {
        if(errorOut)
        {
            *errorOut = @"Unable to encode certificate.";
        }
        return NO;
    }
    
    for(id item in developerCertificates)
    {
        if(![item isKindOfClass:[NSData class]])
        {
            continue;
        }
        NSData *profileCertificate = (NSData *)item;
        if([profileCertificate isEqualToData:certificateData])
        {
            return YES;
        }
    }
    
    if(errorOut)
    {
        *errorOut = @"The provisioning profile Nyxian was signed with does not include this certificate, make sure you use the same certificate Nyxian was signed with.";
    }
    
    return NO;
}

int checkCert(NSData *prov,
              NSData *key,
              NSString *pass,
              void(^completionHandler)(int status, NSString *error)) {
    const char* strPKeyFileData = (const char*)[key bytes];
    const char* strProvFileData = (const char*)[prov bytes];
    
    if(pass == nil)
    {
        pass = @"";
    }
    
    string strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];
    
    ZLog::logs.clear();

    __block ZSignAsset zSignAsset;
    
    if (!zSignAsset.InitSimple(strPKeyFileData, (int)[key length], strProvFileData, (int)[prov length], strPassword)) {
        ZLog::logs.clear();
        completionHandler(2, @"Unable to initialize certificate. Please check your password.");
        return -1;
    }
    
    X509* cert = (X509*)zSignAsset.m_x509Cert;
    BIO *brother1;
    unsigned long issuerHash = X509_issuer_name_hash((X509*)cert);
    if (0x9b16b75c == issuerHash) {
        brother1 = BIO_new_mem_buf(ZSignAsset::s_szAppleDevCACertG3, (int)strlen(ZSignAsset::s_szAppleDevCACertG3));
    } else {
        completionHandler(2, @"Unable to determine issuer of the certificate. It is signed by Apple Developer?");
        return -2;
    }
    
    if (!brother1)
    {
        completionHandler(2, @"Unable to initialize issuer certificate.");
        return -3;
    }
    
    X509 *issuer = PEM_read_bio_X509(brother1, NULL, 0, NULL);
    
    if (!cert || !issuer) {
        completionHandler(2, @"Error loading cert or issuer");
        return -4;
    }

    
    // Extract OCSP URL from cert
    STACK_OF(ACCESS_DESCRIPTION)* aia = (STACK_OF(ACCESS_DESCRIPTION)*)X509_get_ext_d2i((X509*)cert, NID_info_access, 0, 0);
    if (!aia) {
        completionHandler(2, @"No AIA (OCSP) extension found in certificate");
        return -5;
    }
    
    ASN1_IA5STRING* uri = nullptr;
    for (int i = 0; i < sk_ACCESS_DESCRIPTION_num(aia); i++) {
        ACCESS_DESCRIPTION* ad = sk_ACCESS_DESCRIPTION_value(aia, i);
        if (OBJ_obj2nid(ad->method) == NID_ad_OCSP &&
            ad->location->type == GEN_URI) {
            uri = ad->location->d.uniformResourceIdentifier;
            
            break;
        }
    }

    
    if (!uri) {
        completionHandler(2, @"No OCSP URI found in certificate.");
        return -6;
    }

    OCSP_REQUEST* req = OCSP_REQUEST_new();
    OCSP_CERTID* cert_id = OCSP_cert_to_id(nullptr, (X509*)cert, issuer);
    OCSP_request_add0_id(req, cert_id);  // Ownership transferred to request
    cert_id = OCSP_cert_to_id(nullptr, (X509*)cert, issuer);
    unsigned char* der = 0;
    
    OPENSSL_free(der);
    if (aia) {
        sk_ACCESS_DESCRIPTION_pop_free(aia, ACCESS_DESCRIPTION_free);
    }
    OCSP_REQUEST_free(req);
    X509_free(issuer);
    BIO_free(brother1);
    
    NSString *profileError = nil;
    if(!ProvisionContainsCertificate(prov, cert, &profileError))
    {
        completionHandler(777, profileError ?: @"Certificate does not match provisioning profile.");
    }
    else
    {
        completionHandler(0, nil);
    }
    
    return 1;
}

}
