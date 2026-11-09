#import <LindChain/IDEFoundation/NXBootstrap.h>

@implementation NXBootstrap {
    dispatch_group_t _bootstrapGroup;
    dispatch_once_t _bootstrapOnce;
    BOOL _bootstrapSucceeded;
}

+ (instancetype)shared
{
    static NXBootstrap *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[NXBootstrap alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _bootstrapGroup = dispatch_group_create();
        dispatch_group_enter(_bootstrapGroup);
    }
    return self;
}

- (NSURL *)rootURL
{
    static NSURL *url;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *home = NSHomeDirectory();
        if(![home hasPrefix:@"/private/"])
        {
            home = [@"/private" stringByAppendingPathComponent:home];
        }
        url = [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
    });
    return url;
}

- (NSURL *)rootfsURL { return [self.rootURL URLByAppendingPathComponent:@"rootfs" isDirectory:YES]; }
- (NSURL *)sdkURL { return [self.rootURL URLByAppendingPathComponent:@"SDK" isDirectory:YES]; }
- (NSURL *)includeURL { return [self.rootURL URLByAppendingPathComponent:@"Include" isDirectory:YES]; }
- (NSURL *)projectsURL { return [self.rootURL URLByAppendingPathComponent:@"Projects" isDirectory:YES]; }
- (NSURL *)cacheURL { return [self.rootURL URLByAppendingPathComponent:@"Cache" isDirectory:YES]; }
- (NSURL *)bootstrapPlistURL { return [self.rootURL URLByAppendingPathComponent:@"bootstrap.plist"]; }
- (NSURL *)swiftURL { return [self.rootURL URLByAppendingPathComponent:@"swift" isDirectory:YES]; }
- (NSURL *)swiftModuleCacheURL { return [self.rootURL URLByAppendingPathComponent:@"ModuleCache" isDirectory:YES]; }

- (UInt64)version
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:self.bootstrapPlistURL];
    NSNumber *n = plist[@"BootstrapVersion"];
    return [n isKindOfClass:NSNumber.class] ? n.unsignedLongLongValue : 0;
}

- (BOOL)isInstalled { return self.version > 0; }
- (BOOL)isNewest { return self.version >= NXBOOTSTRAP_NEWEST_VERSION; }

- (void)bootstrap
{
    dispatch_once(&_bootstrapOnce, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        NSArray<NSURL *> *directories = @[
            self.rootURL,
            self.rootfsURL,
            [self.rootfsURL URLByAppendingPathComponent:@"tmp" isDirectory:YES],
            [self.rootURL URLByAppendingPathComponent:@"mntfs/bootfs" isDirectory:YES],
            [self.rootURL URLByAppendingPathComponent:@"mntfs/lsfs" isDirectory:YES],
            [self.rootURL URLByAppendingPathComponent:@"RootCAs" isDirectory:YES],
        ];

        BOOL ok = YES;
        for (NSURL *url in directories) {
            if (![fm createDirectoryAtURL:url
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&error]) {
                NSLog(@"NXBootstrap: failed to create %@: %@", url.path, error);
                ok = NO;
                break;
            }
        }

        if(ok)
        {
            NSDictionary *plist = @{ @"BootstrapVersion": @(NXBOOTSTRAP_NEWEST_VERSION) };
            ok = [plist writeToURL:self.bootstrapPlistURL atomically:YES];
        }
        _bootstrapSucceeded = ok;
        dispatch_group_leave(_bootstrapGroup);
    });
}

- (void)waitTillDone
{
    dispatch_group_wait(_bootstrapGroup, DISPATCH_TIME_FOREVER);
}

- (void)waitTillDoneNoButton
{
    [self waitTillDone];
}

- (void)clearURL:(NSURL *)url
{
    if(url)
    {
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
}

- (NSString *)relativeToBootstrapWithAbsolutePath:(NSString *)path
{
    if(!path)
    {
        return nil;
    }
    NSString *root = self.rootURL.path.stringByStandardizingPath;
    NSString *candidate = path.stringByStandardizingPath;
    if([candidate isEqualToString:root])
    {
        return @"";
    }
    NSString *prefix = [root stringByAppendingString:@"/"];
    return [candidate hasPrefix:prefix] ? [candidate substringFromIndex:prefix.length] : nil;
}

@end
