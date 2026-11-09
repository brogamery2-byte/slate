#ifndef FOUNDATION_PRIVATE_H
#define FOUNDATION_PRIVATE_H

#include <Foundation/Foundation.h>

@interface NSBundle(private)
- (id)_cfBundle;
@end

@interface NSUserDefaults(private)
+ (void)setStandardUserDefaults:(id)defaults;
- (instancetype)_initWithSuiteName:(NSString*)suiteName container:(NSURL*)container;
- (void)_setIdentifier:(NSString*)identifier;
- (NSString*)_identifier;
- (NSString*)_container;
- (void)_setContainer:(NSURL*)identifier;
@end

@interface NSExtension : NSObject
@property (nonatomic, strong, readwrite) NSArray *preferredLanguages;
@property (setter=_setPlugIn:, nonatomic, retain) id _plugIn;
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void(^)(NSUUID *))callback;
- (NSUUID*)beginExtensionRequestWithInputItems:(NSArray*)arg1 error:(NSError**)arg2;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)arg1;
- (void)setRequestCancellationBlock:(void(^)(NSUUID *uuid, NSError *error))callback;
- (void)setRequestInterruptionBlock:(void(^)(NSUUID *))callback;
- (void)_hostDidEnterBackgroundNote:(NSNotification *)note;

- (id)uns_extensionContainerBundleProxy;
@end

@interface EXConcreteExtension : NSExtension

- (id)_plugIn;

@end

void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
NSString *SecTaskCopyTeamIdentifier(void *task, NSError **error);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);


@interface _CFXPreferences2 : NSObject
+(instancetype)copyDefaultPreferences;
-(CFPropertyListRef)hook_copyAppValueForKey:(CFStringRef)key identifier:(CFStringRef)identifier container:(CFStringRef)container configurationURL:(CFURLRef)configurationURL;
-(CFPropertyListRef)hook_copyValueForKey:(CFStringRef)key identifier:(CFStringRef)identifier user:(CFStringRef)user host:(CFStringRef)host container:(CFStringRef)container;
-(void)hook_setValue:(CFPropertyListRef)value forKey:(CFStringRef)key appIdentifier:(CFStringRef)appIdentifier container:(CFStringRef)container configurationURL:(CFURLRef)configurationURL;
@end

@interface CFPrefsPlistSource2 : NSObject
-(id)hook_initWithDomain:(CFStringRef)arg1 user:(CFStringRef)arg2 byHost:(bool)arg3 containerPath:(CFStringRef)arg4 containingPreferences:(id)arg5 ;
@end

@interface PKHostPlugIn : NSObject

@property (readonly) NSDictionary *entitlements;
@property (readonly) NSDictionary *attributes;
@property unsigned int useCount;

@end

#endif /* FOUNDATION_PRIVATE_H */
