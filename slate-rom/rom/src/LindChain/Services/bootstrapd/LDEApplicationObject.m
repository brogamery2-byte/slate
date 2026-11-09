#import <Frameworks/LiveProcessLegacy/LindChain/Services/bootstrapd/LDEApplicationObject.h>

@implementation LDEApplicationObject

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithNSBundle:(NSBundle *)bundle
{
    self = [super init];
    if(self && bundle)
    {
        self.bundleIdentifier = bundle.bundleIdentifier;
        self.localizedName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: bundle.bundleIdentifier;
        self.bundlePath = bundle.bundlePath;
        self.executablePath = bundle.executablePath;
        self.iconDictionary = [bundle objectForInfoDictionaryKey:@"CFBundleIcons"];
        self.bundleVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        self.shortVersionString = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: self.bundleVersion;
        self.sdkVersion = [bundle objectForInfoDictionaryKey:@"DTPlatformVersion"];
        self.minimumSystemVersion = [bundle objectForInfoDictionaryKey:@"MinimumOSVersion"];
        self.entitlements = @{};
        self.isLaunchAllowed = YES;
        self.isFullscreenRequired = [[bundle objectForInfoDictionaryKey:@"UIRequiresFullScreen"] boolValue];

        NSDictionary<NSString*, NSNumber*> *masks = @{
            @"UIInterfaceOrientationPortrait": @(UIInterfaceOrientationMaskPortrait),
            @"UIInterfaceOrientationPortraitUpsideDown": @(UIInterfaceOrientationMaskPortraitUpsideDown),
            @"UIInterfaceOrientationLandscapeLeft": @(UIInterfaceOrientationMaskLandscapeLeft),
            @"UIInterfaceOrientationLandscapeRight": @(UIInterfaceOrientationMaskLandscapeRight),
        };
        UIInterfaceOrientationMask mask = 0;
        id orientations = [bundle objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations"];
        if([orientations isKindOfClass:NSArray.class])
        {
            for(id orientation in orientations)
            {
                if([orientation isKindOfClass:NSString.class]) mask |= masks[orientation].unsignedIntegerValue;
            }
        }
        self.supportedInterfaceOrientations = mask ?: UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.bundleIdentifier forKey:@"bundleIdentifier"];
    [coder encodeObject:self.bundlePath forKey:@"bundlePath"];
    [coder encodeObject:self.executablePath forKey:@"executablePath"];
    [coder encodeObject:self.localizedName forKey:@"localizedName"];
    [coder encodeObject:self.containerPath forKey:@"containerPath"];
    [coder encodeObject:self.icon forKey:@"icon"];
    [coder encodeObject:self.darkIcon forKey:@"darkIcon"];
    [coder encodeObject:self.iconDictionary forKey:@"iconDictionary"];
    [coder encodeObject:self.bundleVersion forKey:@"bundleVersion"];
    [coder encodeObject:self.shortVersionString forKey:@"shortVersionString"];
    [coder encodeObject:self.sdkVersion forKey:@"sdkVersion"];
    [coder encodeObject:self.minimumSystemVersion forKey:@"minimumSystemVersion"];
    [coder encodeObject:self.entitlements forKey:@"entitlements"];
    [coder encodeObject:@(self.supportedInterfaceOrientations) forKey:@"supportedInterfaceOrientations"];
    [coder encodeObject:@(self.isLaunchAllowed) forKey:@"isLaunchAllowed"];
    [coder encodeObject:@(self.isFullscreenRequired) forKey:@"isFullscreenRequired"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if(self)
    {
        _bundleIdentifier = [coder decodeObjectOfClass:NSString.class forKey:@"bundleIdentifier"];
        _bundlePath = [coder decodeObjectOfClass:NSString.class forKey:@"bundlePath"];
        _executablePath = [coder decodeObjectOfClass:NSString.class forKey:@"executablePath"];
        _localizedName = [coder decodeObjectOfClass:NSString.class forKey:@"localizedName"];
        _containerPath = [coder decodeObjectOfClass:NSString.class forKey:@"containerPath"];
        _icon = [coder decodeObjectOfClass:UIImage.class forKey:@"icon"];
        _darkIcon = [coder decodeObjectOfClass:UIImage.class forKey:@"darkIcon"];
        NSSet *plist = [NSSet setWithArray:@[NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSData.class]];
        _iconDictionary = [coder decodeObjectOfClasses:plist forKey:@"iconDictionary"];
        _bundleVersion = [coder decodeObjectOfClass:NSString.class forKey:@"bundleVersion"];
        _shortVersionString = [coder decodeObjectOfClass:NSString.class forKey:@"shortVersionString"];
        _sdkVersion = [coder decodeObjectOfClass:NSString.class forKey:@"sdkVersion"];
        _minimumSystemVersion = [coder decodeObjectOfClass:NSString.class forKey:@"minimumSystemVersion"];
        _entitlements = [coder decodeObjectOfClasses:plist forKey:@"entitlements"];
        _supportedInterfaceOrientations = [[coder decodeObjectOfClass:NSNumber.class forKey:@"supportedInterfaceOrientations"] unsignedLongLongValue];
        _isLaunchAllowed = [[coder decodeObjectOfClass:NSNumber.class forKey:@"isLaunchAllowed"] boolValue];
        _isFullscreenRequired = [[coder decodeObjectOfClass:NSNumber.class forKey:@"isFullscreenRequired"] boolValue];
    }
    return self;
}

- (BOOL)isEqual:(id)object
{
    if(self == object)
    {
        return YES;
    }
    if(![object isKindOfClass:LDEApplicationObject.class])
    {
        return NO;
    }
    return [self.bundleIdentifier isEqualToString:((LDEApplicationObject *)object).bundleIdentifier];
}

- (NSUInteger)hash
{
    return self.bundleIdentifier.hash;
}

@end
