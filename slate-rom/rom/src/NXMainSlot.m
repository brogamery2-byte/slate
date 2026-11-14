#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <string.h>
#include <limits.h>
#include <stdlib.h>
#import <LindChain/IDEFoundation/NXBootstrap.h>
#import <LindChain/ProcEnvironment/PEUserspaceManager.h>
#import <LindChain/ProcEnvironment/PEProcessManager.h>
#import <LindChain/ProcEnvironment/PEFileTable.h>
#import <Frameworks/LiveProcessLegacy/LindChain/Services/bootstrapd/LDEApplicationObject.h>
#if __has_include(<Frameworks/LiveProcessLegacy/LindChain/Services/bootstrapd/LDEApplicationWorkspace.h>)
#import <Frameworks/LiveProcessLegacy/LindChain/Services/bootstrapd/LDEApplicationWorkspace.h>
#elif __has_include(<LindChain/Services/bootstrapd/LDEApplicationWorkspace.h>)
#import <LindChain/Services/bootstrapd/LDEApplicationWorkspace.h>
#else
#error "LDEApplicationWorkspace.h was not found. Send the include errors to get the right path."
#endif
#import <LindChain/ProcEnvironment/Surface/trust/trust.h>
#import <LindChain/ProcEnvironment/Surface/libkern/klog.h>
#import <LindChain/ProcEnvironment/Surface/proc/list.h>
#import <LindChain/ProcEnvironment/Surface/proc/lookup.h>
#import <LindChain/ProcEnvironment/Surface/proc/spawn.h>
#import <LindChain/ProcEnvironment/Surface/lock.h>
#import <LindChain/ProcEnvironment/Surface/libkern/radix/radix.h>
#import <LindChain/WindowServer/NXWindowServer.h>
#import <LindChain/WindowServer/Session/NXWindowSessionApplication.h>
#include <NXBootArgs.h>

extern NSString *NXROMApplicationSourcePath(void);

#pragma mark - The ROM and its applications

static NSString *NXROMSlotDirectory(void)
{
    NSString *applications = NXROMApplicationSourcePath();
    return applications.length > 0 ? applications.stringByDeletingLastPathComponent : nil;
}

static NSString *NXROMDisplayName(void)
{
    NSString *slot = NXROMSlotDirectory();
    NSDictionary *manifest = slot ? [NSDictionary dictionaryWithContentsOfFile:[slot stringByAppendingPathComponent:@"manifest.plist"]] : nil;
    NSString *name = manifest[@"NXRomName"];
    return ([name isKindOfClass:NSString.class] && name.length > 0) ? name : @"ROM";
}

static NSString *NXROMVersionString(void)
{
    NSString *slot = NXROMSlotDirectory();
    NSDictionary *manifest = slot ? [NSDictionary dictionaryWithContentsOfFile:[slot stringByAppendingPathComponent:@"manifest.plist"]] : nil;
    NSString *version = manifest[@"NXRomVersion"];
    return [version isKindOfClass:NSString.class] ? version : @"?";
}

@interface NXROMApplication : NSObject
@property (nonatomic, strong) NSBundle *bundle;
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) UIImage *icon;
@end

@implementation NXROMApplication
@end

static UIImage *NXROMApplicationIcon(NSBundle *bundle)
{
    NSDictionary *icons = [bundle objectForInfoDictionaryKey:@"CFBundleIcons"];
    NSDictionary *primary = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSArray *files = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconFiles"] : nil;
    if(![files isKindOfClass:NSArray.class])
    {
        return nil;
    }
    for(NSString *file in files.reverseObjectEnumerator)
    {
        if(![file isKindOfClass:NSString.class])
        {
            continue;
        }
        UIImage *image = [UIImage imageNamed:file inBundle:bundle compatibleWithTraitCollection:nil];
        if(image != nil)
        {
            return image;
        }
    }
    return nil;
}

static NSArray<NXROMApplication *> *NXROMApplications(void)
{
    NSString *applications = NXROMApplicationSourcePath();
    NSMutableArray<NXROMApplication *> *result = [NSMutableArray array];
    if(applications.length == 0)
    {
        return result;
    }
    for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:applications error:nil])
    {
        if(![entry.pathExtension isEqualToString:@"app"])
        {
            continue;
        }
        NSBundle *bundle = [NSBundle bundleWithPath:[applications stringByAppendingPathComponent:entry]];
        if(bundle.bundleIdentifier.length == 0 || bundle.executablePath == nil)
        {
            continue;
        }
        NXROMApplication *application = [NXROMApplication new];
        application.bundle = bundle;
        application.bundleIdentifier = bundle.bundleIdentifier;
        application.name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: entry.stringByDeletingPathExtension;
        application.icon = NXROMApplicationIcon(bundle);
        [result addObject:application];
    }
    [result sortUsingComparator:^NSComparisonResult(NXROMApplication *a, NXROMApplication *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return result;
}

#pragma mark - Launching

static dispatch_queue_t NXROMLaunchQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("org.emexlabs.rom.launch", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableDictionary<NSString *, NSDate *> *NXROMLaunchTimes(void)
{
    static NSMutableDictionary *times;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ times = [NSMutableDictionary dictionary]; });
    return times;
}

static BOOL NXROMActivateWindow(NSString *bundleIdentifier)
{
    NXWindowServer *windowServer = [NXWindowServer shared];
    NXWindowSession *session = [windowServer windowSessionForBundleIdentifier:bundleIdentifier];
    if(session == nil || session.window == nil)
    {
        return NO;
    }
    if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone)
    {
        [windowServer activateWindowForIdentifier:session.windowIdentifier animated:YES withCompletion:nil];
    }
    else
    {
        [session.window focusWindow];
    }
    return YES;
}

static void NXROMSpawnApplication(NXROMApplication *application)
{
    NSString *executablePath = application.bundle.executablePath;

    PEFileTable *table = [PEFileTable emptyTable];
    [table appendFileDescriptor:STDOUT_FILENO withMappingToLoc:STDOUT_FILENO];
    [table appendFileDescriptor:STDERR_FILENO withMappingToLoc:STDERR_FILENO];

    errno = 0;
    pid_t pid = [[PEProcessManager shared] spawnProcessWithItems:@{
        @"PEExecutablePath": executablePath,
        @"PEArguments": @[ executablePath ],
        @"PEWorkingDirectory": NXBootstrap.shared.rootfsURL.path,
        @"PEEnvironment": @{},
        @"PEFileTable": table,
    } withKernelSurfaceProcess:NULL];
    if(pid < 0)
    {
        int error = errno;
        klog_log("NXMainSlot", "spawning %s failed: %s", executablePath.UTF8String, error ? strerror(error) : "rejected");
        [NXROMLaunchTimes() removeObjectForKey:application.bundleIdentifier];
        return;
    }

    PEProcess *process = [[PEProcessManager shared] processForProcessIdentifier:pid];
    if(process != nil && process.bundleIdentifier == nil)
    {
        process.applicationObject = [[LDEApplicationObject alloc] initWithNSBundle:application.bundle];
        process.bundleIdentifier = application.bundleIdentifier;
        process.displayName = application.name;
    }
    klog_log("NXMainSlot", "launched %s as pid %d", application.bundleIdentifier.UTF8String, pid);
}

static void NXROMOpenApplication(NXROMApplication *application)
{
    if(NXROMActivateWindow(application.bundleIdentifier))
    {
        return;
    }
    dispatch_async(NXROMLaunchQueue(), ^{
        NSString *bundleIdentifier = application.bundleIdentifier;
        PEProcess *running = [[PEProcessManager shared] processForBundleIdentifier:bundleIdentifier];
        if(running != nil)
        {
            NSDate *launched = NXROMLaunchTimes()[bundleIdentifier];
            if(launched != nil && -launched.timeIntervalSinceNow < 5.0)
            {
                return;
            }
            [running forceTerminate];
        }
        NXROMLaunchTimes()[bundleIdentifier] = [NSDate date];
        NXROMSpawnApplication(application);
    });
}

#pragma mark - Process viewer

@interface NXROMProcessEntry : NSObject
@property (nonatomic) BOOL isKernel;
@property (nonatomic) pid_t pid;
@property (nonatomic) pid_t ppid;
@property (nonatomic) uid_t uid;
@property (nonatomic, copy) NSString *name;
@end

@implementation NXROMProcessEntry

- (BOOL)isEqual:(id)object
{
    if(![object isKindOfClass:NXROMProcessEntry.class])
    {
        return NO;
    }
    NXROMProcessEntry *other = object;
    return other.pid == self.pid && other.ppid == self.ppid && other.uid == self.uid &&
           other.isKernel == self.isKernel && [other.name isEqualToString:self.name];
}

- (NSUInteger)hash
{
    return (NSUInteger)self.pid;
}

@end

typedef struct {
    kinfo_proc_t *kp;
    size_t count;
    size_t capacity;
} NXROMProcessWalk;

static void NXROMProcessWalkCallback(uint64_t ident, void *value, void *ctx)
{
    NXROMProcessWalk *walk = ctx;
    ksurface_proc_t *proc = value;
    if(walk->count >= walk->capacity || !kvo_retain(proc))
    {
        return;
    }
    kvo_rdlock(proc);
    if(proc->bsd.kp_proc.p_stat != SZOMB)
    {
        memcpy(&walk->kp[walk->count++], &proc->bsd, sizeof(kinfo_proc_t));
    }
    kvo_unlock(proc);
    kvo_release(proc);
}

static NSArray<NXROMProcessEntry *> *NXROMProcessList(void)
{
    NSMutableArray<NXROMProcessEntry *> *entries = [NSMutableArray array];
    NXROMProcessWalk walk = {0};

    proc_table_rdlock();
    walk.capacity = ksurface->proc_info.proc_count;
    walk.kp = walk.capacity > 0 ? calloc(walk.capacity, sizeof(kinfo_proc_t)) : NULL;
    if(walk.kp != NULL)
    {
        radix_walk(&(ksurface->proc_info.tree), NXROMProcessWalkCallback, &walk);
    }
    proc_table_unlock();

    for(size_t i = 0; i < walk.count; i++)
    {
        NXROMProcessEntry *entry = [NXROMProcessEntry new];
        entry.pid = walk.kp[i].kp_proc.p_pid;
        entry.isKernel = (entry.pid == proc_getpid(kernel_proc_));
        entry.ppid = walk.kp[i].kp_eproc.e_ppid;
        entry.uid = walk.kp[i].kp_eproc.e_ucred.cr_uid;

        char comm[MAXCOMLEN + 1] = {0};
        memcpy(comm, walk.kp[i].kp_proc.p_comm, MAXCOMLEN);
        NSString *name = [NSString stringWithUTF8String:comm];
        PEProcess *process = [[PEProcessManager shared] processForProcessIdentifier:entry.pid];
        if(process.displayName.length > 0)
        {
            name = process.displayName;
        }
        entry.name = name.length > 0 ? name : @"?";
        [entries addObject:entry];
    }
    free(walk.kp);

    [entries sortUsingComparator:^NSComparisonResult(NXROMProcessEntry *a, NXROMProcessEntry *b) {
        return a.pid < b.pid ? NSOrderedAscending : (a.pid > b.pid ? NSOrderedDescending : NSOrderedSame);
    }];
    return entries;
}

static NSString *NXROMSignalName(int sig)
{
    if(sig > 0 && sig < NSIG)
    {
        return [@"SIG" stringByAppendingString:@(sys_signame[sig]).uppercaseString];
    }
    return [NSString stringWithFormat:@"signal %d", sig];
}

static NSString *NXROMSignalProcess(pid_t pid, int sig)
{
    ksurface_proc_t *proc = NULL;
    if(proc_for_pid(pid, &proc) != KERN_SUCCESS || proc == NULL)
    {
        return @"the process no longer exists";
    }
    kern_return_t kr = proc_kill(proc, sig);
    kvo_release(proc);
    if(kr != KERN_SUCCESS)
    {
        return [NSString stringWithFormat:@"the kernel surface did not deliver it (%s)", mach_error_string(kr)];
    }
    klog_log("NXMainSlot", "sent %s to pid %d", NXROMSignalName(sig).UTF8String, pid);
    return nil;
}

@interface NXROMProcessesViewController : UITableViewController
@property (nonatomic, copy) NSArray<NXROMProcessEntry *> *processes;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic) BOOL refreshing;
@property (nonatomic) NSInteger openMenus;
@end

@implementation NXROMProcessesViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Processes";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"process"];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refresh
{
    if(self.refreshing || self.openMenus > 0 || self.tableView.isEditing || self.tableView.isTracking || self.tableView.isDecelerating)
    {
        return;
    }
    self.refreshing = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NXROMProcessEntry *> *processes = NXROMProcessList();
        dispatch_async(dispatch_get_main_queue(), ^{
            NXROMProcessesViewController *controller = weakSelf;
            if(controller == nil)
            {
                return;
            }
            controller.refreshing = NO;
            if([processes isEqualToArray:controller.processes ?: @[]] && controller.processes != nil)
            {
                return;
            }
            UITableView *table = controller.tableView;
            if(controller.processes != nil &&
               (controller.openMenus > 0 || table.isEditing || table.isTracking || table.isDragging || table.isDecelerating || controller.presentedViewController != nil))
            {
                return;
            }
            controller.processes = processes;
            [table reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.processes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [NSString stringWithFormat:@"%lu processes", (unsigned long)self.processes.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"process" forIndexPath:indexPath];
    NXROMProcessEntry *entry = self.processes[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = entry.name;
    content.secondaryText = entry.isKernel ? [NSString stringWithFormat:@"pid %d · kernel", entry.pid]
                                           : [NSString stringWithFormat:@"pid %d · ppid %d · uid %u", entry.pid, entry.ppid, entry.uid];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = [UIImage systemImageNamed:entry.isKernel ? @"cpu" : @"gearshape.2"];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)sendSignal:(int)sig toEntry:(NXROMProcessEntry *)entry
{
    pid_t pid = entry.pid;
    NSString *name = entry.name;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = NXROMSignalProcess(pid, sig);
        dispatch_async(dispatch_get_main_queue(), ^{
            NXROMProcessesViewController *controller = weakSelf;
            if(controller == nil)
            {
                return;
            }
            [controller refresh];
            if(failure != nil)
            {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ not sent", NXROMSignalName(sig)]
                                                                               message:[NSString stringWithFormat:@"%@ (pid %d): %@.", name, pid, failure]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [controller presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (UIMenu *)signalMenuForEntry:(NXROMProcessEntry *)entry
{
    struct { const char *title; const char *image; int sig; BOOL destructive; } signals[] = {
        { "Terminate", "xmark.circle", SIGTERM, YES },
        { "Kill", "bolt.circle", SIGKILL, YES },
        { "Interrupt", "hand.raised", SIGINT, NO },
        { "Hang Up", "phone.down", SIGHUP, NO },
        { "Stop", "pause.circle", SIGSTOP, NO },
        { "Continue", "play.circle", SIGCONT, NO },
        { "User Signal 1", "1.circle", SIGUSR1, NO },
        { "User Signal 2", "2.circle", SIGUSR2, NO },
    };
    NSMutableArray<UIMenuElement *> *control = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *ending = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for(size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
    {
        int sig = signals[i].sig;
        UIAction *action = [UIAction actionWithTitle:@(signals[i].title)
                                               image:[UIImage systemImageNamed:@(signals[i].image)]
                                          identifier:nil
                                             handler:^(UIAction *a) {
            [weakSelf sendSignal:sig toEntry:entry];
        }];
        action.subtitle = NXROMSignalName(sig);
        if(signals[i].destructive)
        {
            action.attributes = UIMenuElementAttributesDestructive;
            [ending addObject:action];
        }
        else
        {
            [control addObject:action];
        }
    }
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"%@ · pid %d", entry.name, entry.pid] children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:control],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:ending],
    ]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NXROMProcessEntry *entry = self.processes[indexPath.row];
    if(entry.isKernel)
    {
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [weakSelf signalMenuForEntry:entry];
    }];
}

- (void)tableView:(UITableView *)tableView willDisplayContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
    self.openMenus++;
}

- (void)tableView:(UITableView *)tableView willEndContextMenuInteractionWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
    if(self.openMenus > 0) self.openMenus--;
}

@end

#pragma mark - Settings

static NSString *const NXSlotPrefDeveloperMode = @"slate.pref.developerMode";
static NSString *const NXSlotPrefShowDetails = @"slate.pref.showDetails";
static NSString *const NXSlotPrefAccent = @"slate.pref.accent";
static NSString *const NXSlotPrefLayout = @"slate.pref.layout";
static NSString *const NXSlotPrefSetupOnUpdate = @"slate.pref.setupOnUpdate";
static NSString *const NXSlotPrefSetupBuild = @"slate.setup.completedBuild";

static BOOL NXSlotSetupShownThisSession = NO;

static UIViewController *NXSlotMakeHome(void);
static void NXSlotPresentSetup(UIViewController *presenter, BOOL force);
static void NXSlotImportApp(UIViewController *presenter);
static UIViewController *NXSlotMakeInstalledAppsController(void);

static BOOL NXROMDefaultBool(NSString *key, BOOL fallback)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : fallback;
}

static NSString *NXROMManifestString(NSString *key, NSString *fallback)
{
    NSString *slot = NXROMSlotDirectory();
    NSDictionary *manifest = slot ? [NSDictionary dictionaryWithContentsOfFile:[slot stringByAppendingPathComponent:@"manifest.plist"]] : nil;
    id value = manifest[key];
    if([value isKindOfClass:NSNumber.class])
    {
        return [value stringValue];
    }
    if([value isKindOfClass:NSString.class] && [value length] > 0)
    {
        return value;
    }
    return fallback;
}

static NSArray<NSDictionary *> *NXSlotAccentOptions(void)
{
    return @[
        @{ @"id": @"slate", @"title": @"Slate" },
        @{ @"id": @"blue", @"title": @"Blue" },
        @{ @"id": @"indigo", @"title": @"Indigo" },
        @{ @"id": @"purple", @"title": @"Purple" },
        @{ @"id": @"pink", @"title": @"Pink" },
        @{ @"id": @"red", @"title": @"Red" },
        @{ @"id": @"orange", @"title": @"Orange" },
        @{ @"id": @"green", @"title": @"Green" },
        @{ @"id": @"teal", @"title": @"Teal" },
    ];
}

static NSArray<NSDictionary *> *NXSlotLayoutOptions(void)
{
    return @[
        @{ @"id": @"list", @"title": @"List" },
        @{ @"id": @"grid", @"title": @"Grid" },
    ];
}

static NSString *NXSlotChoice(NSString *key, NSArray<NSDictionary *> *options)
{
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:key];
    for(NSDictionary *option in options)
    {
        if([option[@"id"] isEqualToString:stored])
        {
            return stored;
        }
    }
    return options.firstObject[@"id"];
}

static NSString *NXSlotChoiceTitle(NSString *key, NSArray<NSDictionary *> *options)
{
    NSString *current = NXSlotChoice(key, options);
    for(NSDictionary *option in options)
    {
        if([option[@"id"] isEqualToString:current])
        {
            return option[@"title"];
        }
    }
    return current;
}

static UIColor *NXSlotAccentColorForID(NSString *identifier)
{
    if([identifier isEqualToString:@"blue"])
    {
        return UIColor.systemBlueColor;
    }
    if([identifier isEqualToString:@"indigo"])
    {
        return UIColor.systemIndigoColor;
    }
    if([identifier isEqualToString:@"purple"])
    {
        return UIColor.systemPurpleColor;
    }
    if([identifier isEqualToString:@"pink"])
    {
        return UIColor.systemPinkColor;
    }
    if([identifier isEqualToString:@"red"])
    {
        return UIColor.systemRedColor;
    }
    if([identifier isEqualToString:@"orange"])
    {
        return UIColor.systemOrangeColor;
    }
    if([identifier isEqualToString:@"green"])
    {
        return UIColor.systemGreenColor;
    }
    if([identifier isEqualToString:@"teal"])
    {
        return UIColor.systemTealColor;
    }
    return [UIColor colorWithRed:0.45 green:0.62 blue:0.95 alpha:1.0];
}

static UIColor *NXSlotAccentColor(void)
{
    return NXSlotAccentColorForID(NXSlotChoice(NXSlotPrefAccent, NXSlotAccentOptions()));
}

static void NXSlotApplyAppearance(UINavigationController *navigation)
{
    if(!navigation)
    {
        return;
    }
    navigation.view.tintColor = NXSlotAccentColor();

    BOOL wantsGrid = [NXSlotChoice(NXSlotPrefLayout, NXSlotLayoutOptions()) isEqualToString:@"grid"];
    UIViewController *root = navigation.viewControllers.firstObject;
    BOOL isGrid = [root isKindOfClass:NSClassFromString(@"NXROMGridViewController")];
    if(wantsGrid != isGrid)
    {
        NSMutableArray<UIViewController *> *stack = [navigation.viewControllers mutableCopy];
        stack[0] = NXSlotMakeHome();
        [navigation setViewControllers:stack animated:NO];
    }
}

static NSString *NXSlotBuildID(void)
{
    return [NSString stringWithFormat:@"%@|%@|%@",
            NXROMManifestString(@"NXRomIdentifier", @""),
            NXROMManifestString(@"NXRomVersion", @""),
            NXROMManifestString(@"NXRomSecurityVersion", @"")];
}

static BOOL NXSlotSetupNeeded(void)
{
    NSString *done = [NSUserDefaults.standardUserDefaults stringForKey:NXSlotPrefSetupBuild];
    if(done.length == 0)
    {
        return YES;
    }
    if(NXROMDefaultBool(NXSlotPrefSetupOnUpdate, YES))
    {
        return ![done isEqualToString:NXSlotBuildID()];
    }
    return NO;
}

@interface NXROMChoiceViewController : UITableViewController
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, copy) NSArray<NSDictionary *> *options;
@property (nonatomic, copy) void (^onChange)(void);
- (instancetype)initWithTitle:(NSString *)title
                      prefKey:(NSString *)prefKey
                      options:(NSArray<NSDictionary *> *)options
                     onChange:(void (^)(void))onChange;
@end

@implementation NXROMChoiceViewController

- (instancetype)initWithTitle:(NSString *)title
                      prefKey:(NSString *)prefKey
                      options:(NSArray<NSDictionary *> *)options
                     onChange:(void (^)(void))onChange
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if(self)
    {
        self.title = title;
        _prefKey = [prefKey copy];
        _options = [options copy];
        _onChange = [onChange copy];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"choice"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *option = self.options[indexPath.row];
    NSString *current = NXSlotChoice(self.prefKey, self.options);

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice" forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = option[@"title"];
    if([self.prefKey isEqualToString:NXSlotPrefAccent])
    {
        content.image = [UIImage systemImageNamed:@"circle.fill"];
        content.imageProperties.tintColor = NXSlotAccentColorForID(option[@"id"]);
    }
    cell.contentConfiguration = content;
    cell.accessoryType = [option[@"id"] isEqualToString:current] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *option = self.options[indexPath.row];
    [NSUserDefaults.standardUserDefaults setObject:option[@"id"] forKey:self.prefKey];
    [tableView reloadData];
    if(self.onChange)
    {
        self.onChange();
    }
}

@end

@interface NXROMSettingsViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *model;
@end

@implementation NXROMSettingsViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)reloadModel
{
    BOOL developer = NXROMDefaultBool(NXSlotPrefDeveloperMode, NO);
    NSUInteger appCount = NXROMApplications().count;

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    [sections addObject:@{
        @"title": @"About",
        @"footer": @"",
        @"rows": @[
            @{ @"kind": @"value", @"title": @"Name", @"value": NXROMManifestString(@"NXRomName", @"Slate") },
            @{ @"kind": @"value", @"title": @"Version", @"value": NXROMManifestString(@"NXRomVersion", @"unknown") },
            @{ @"kind": @"value", @"title": @"Security version", @"value": NXROMManifestString(@"NXRomSecurityVersion", @"unknown") },
            @{ @"kind": @"value", @"title": @"Identifier", @"value": NXROMManifestString(@"NXRomIdentifier", @"unknown") },
            @{ @"kind": @"value", @"title": @"Requires Nyxian", @"value": NXROMManifestString(@"NXRomMinimumNyxianVersion", @"unknown") },
            @{ @"kind": @"value", @"title": @"Apps", @"value": [NSString stringWithFormat:@"%lu", (unsigned long)appCount] },
        ],
    }];

    [sections addObject:@{
        @"title": @"Appearance",
        @"footer": @"Changes apply right away.",
        @"rows": @[
            @{ @"kind": @"choice", @"title": @"Accent color", @"key": NXSlotPrefAccent, @"options": NXSlotAccentOptions(), @"value": NXSlotChoiceTitle(NXSlotPrefAccent, NXSlotAccentOptions()) },
            @{ @"kind": @"choice", @"title": @"Home layout", @"key": NXSlotPrefLayout, @"options": NXSlotLayoutOptions(), @"value": NXSlotChoiceTitle(NXSlotPrefLayout, NXSlotLayoutOptions()) },
        ],
    }];

    [sections addObject:@{
        @"title": @"Apps",
        @"footer": @"Import a decrypted .ipa file from Files. Imported apps are listed under Installed apps.",
        @"rows": @[
            @{ @"kind": @"import", @"title": @"Import app" },
            @{ @"kind": @"installed", @"title": @"Installed apps" },
        ],
    }];

    [sections addObject:@{
        @"title": @"Setup",
        @"footer": @"Slate walks you through setup the first time you open it after an update.",
        @"rows": @[
            @{ @"kind": @"switch", @"title": @"Show setup after updates", @"key": NXSlotPrefSetupOnUpdate, @"default": @YES },
            @{ @"kind": @"setup", @"title": @"Run setup again" },
        ],
    }];

    NSMutableArray<NSDictionary *> *developerRows = [NSMutableArray array];
    [developerRows addObject:@{ @"kind": @"switch", @"title": @"Developer menu", @"key": NXSlotPrefDeveloperMode, @"default": @NO }];
    if(developer)
    {
        [developerRows addObject:@{ @"kind": @"link", @"title": @"Processes" }];
        [developerRows addObject:@{ @"kind": @"switch", @"title": @"Show app details", @"key": NXSlotPrefShowDetails, @"default": @NO }];
    }
    [sections addObject:@{
        @"title": @"Developer",
        @"footer": developer ? @"App details shows each app's bundle identifier and process ID on the home screen (list layout)." : @"",
        @"rows": developerRows,
    }];

    [sections addObject:@{
        @"title": @"",
        @"footer": @"",
        @"rows": @[ @{ @"kind": @"button", @"title": @"Reset Slate settings" } ],
    }];

    self.model = sections;
}

- (void)applyAppearance
{
    NXSlotApplyAppearance(self.navigationController);
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    [self reloadModel];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.view.tintColor = NXSlotAccentColor();
    [self reloadModel];
    [self.tableView reloadData];
}

- (void)switchChanged:(UISwitch *)sender
{
    NSString *key = sender.accessibilityIdentifier;
    if(key.length == 0)
    {
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:key];
    if([key isEqualToString:NXSlotPrefDeveloperMode])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadModel];
            [self.tableView reloadData];
        });
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.model.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.model[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSString *title = self.model[section][@"title"];
    return title.length > 0 ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *footer = self.model[section][@"footer"];
    return footer.length > 0 ? footer : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = self.model[indexPath.section][@"rows"][indexPath.row];
    NSString *kind = row[@"kind"];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    BOOL valueStyle = [kind isEqualToString:@"value"] || [kind isEqualToString:@"choice"];
    UIListContentConfiguration *content = valueStyle ? [UIListContentConfiguration valueCellConfiguration] : [UIListContentConfiguration cellConfiguration];
    content.text = row[@"title"];

    if([kind isEqualToString:@"value"])
    {
        content.secondaryText = row[@"value"];
    }
    else if([kind isEqualToString:@"choice"])
    {
        content.secondaryText = row[@"value"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if([kind isEqualToString:@"switch"])
    {
        UISwitch *toggle = [UISwitch new];
        toggle.on = NXROMDefaultBool(row[@"key"], [row[@"default"] boolValue]);
        toggle.accessibilityIdentifier = row[@"key"];
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    else if([kind isEqualToString:@"link"])
    {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if([kind isEqualToString:@"import"])
    {
        content.textProperties.color = self.view.tintColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if([kind isEqualToString:@"installed"])
    {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if([kind isEqualToString:@"setup"])
    {
        content.textProperties.color = self.view.tintColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if([kind isEqualToString:@"button"])
    {
        content.textProperties.color = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[indexPath.section][@"rows"][indexPath.row];
    NSString *kind = row[@"kind"];

    if([kind isEqualToString:@"link"])
    {
        [self.navigationController pushViewController:[NXROMProcessesViewController new] animated:YES];
    }
    else if([kind isEqualToString:@"choice"])
    {
        __weak typeof(self) weakSelf = self;
        NXROMChoiceViewController *picker = [[NXROMChoiceViewController alloc] initWithTitle:row[@"title"]
                                                                                     prefKey:row[@"key"]
                                                                                     options:row[@"options"]
                                                                                    onChange:^{
            [weakSelf applyAppearance];
        }];
        [self.navigationController pushViewController:picker animated:YES];
    }
    else if([kind isEqualToString:@"import"])
    {
        NXSlotImportApp(self);
    }
    else if([kind isEqualToString:@"installed"])
    {
        [self.navigationController pushViewController:NXSlotMakeInstalledAppsController() animated:YES];
    }
    else if([kind isEqualToString:@"setup"])
    {
        NXSlotPresentSetup(self, YES);
    }
    else if([kind isEqualToString:@"button"])
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Slate settings?"
                                                                       message:@"This restores the default Slate settings."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            for(NSString *key in @[ NXSlotPrefDeveloperMode, NXSlotPrefShowDetails, NXSlotPrefAccent, NXSlotPrefLayout, NXSlotPrefSetupOnUpdate, NXSlotPrefSetupBuild ])
            {
                [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
            }
            [self applyAppearance];
            [self reloadModel];
            [self.tableView reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

#pragma mark - First-run setup

static const NSInteger NXSlotSetupStepCount = 5;

@interface NXROMSetupViewController : UIViewController
@property (nonatomic, assign) NSInteger step;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) UIButton *primaryButton;
@property (nonatomic, strong) UIButton *secondaryButton;
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation NXROMSetupViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    self.view.tintColor = NXSlotAccentColor();

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:32.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.labelColor;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;

    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.numberOfLines = 0;

    self.contentView = [UIView new];

    self.pageControl = [UIPageControl new];
    self.pageControl.numberOfPages = NXSlotSetupStepCount;
    self.pageControl.userInteractionEnabled = NO;

    UIButtonConfiguration *primary = [UIButtonConfiguration filledButtonConfiguration];
    primary.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    primary.buttonSize = UIButtonConfigurationSizeLarge;
    self.primaryButton = [UIButton buttonWithConfiguration:primary primaryAction:nil];
    [self.primaryButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButtonConfiguration *secondary = [UIButtonConfiguration plainButtonConfiguration];
    self.secondaryButton = [UIButton buttonWithConfiguration:secondary primaryAction:nil];
    [self.secondaryButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ self.primaryButton, self.secondaryButton ]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 8.0;

    for(UIView *view in @[ self.titleLabel, self.subtitleLabel, self.contentView, self.pageControl, buttons ])
    {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:view];
    }

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:48.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:12.0],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],
        [self.contentView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:32.0],
        [self.contentView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [self.contentView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-16.0],
        [self.pageControl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.pageControl.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-16.0],
        [buttons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [buttons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],
        [buttons.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-16.0],
    ]];

    self.navigationItem.hidesBackButton = YES;
    [self showStep:0 animated:NO];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    self.navigationController.interactivePopGestureRecognizer.enabled = NO;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    self.navigationController.interactivePopGestureRecognizer.enabled = YES;
}

- (void)setTitle:(NSString *)title forButton:(UIButton *)button
{
    UIButtonConfiguration *configuration = button.configuration;
    configuration.title = title;
    button.configuration = configuration;
    button.hidden = (title.length == 0);
}

- (void)placeContent:(UIView *)view fillWidth:(BOOL)fill
{
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:view];
    [view.topAnchor constraintEqualToAnchor:self.contentView.topAnchor].active = YES;
    if(fill)
    {
        [view.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor].active = YES;
        [view.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor].active = YES;
    }
    else
    {
        [view.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor].active = YES;
        [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor].active = YES;
        [view.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor].active = YES;
    }
}

- (void)showStep:(NSInteger)step animated:(BOOL)animated
{
    self.step = step;
    void (^update)(void) = ^{
        for(UIView *view in self.contentView.subviews)
        {
            [view removeFromSuperview];
        }
        [self configureStep];
    };
    if(animated)
    {
        [UIView transitionWithView:self.view duration:0.28 options:UIViewAnimationOptionTransitionCrossDissolve animations:update completion:nil];
    }
    else
    {
        update();
    }
}

- (void)configureStep
{
    self.pageControl.currentPage = self.step;
    self.view.tintColor = NXSlotAccentColor();

    switch(self.step)
    {
        case 0:
        {
            self.titleLabel.text = @"Welcome to Slate";
            self.subtitleLabel.text = @"Let's set up your home screen. It only takes a moment.";
            UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:88.0 weight:UIImageSymbolWeightRegular];
            UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:symbol]];
            icon.tintColor = self.view.tintColor;
            [self placeContent:icon fillWidth:NO];
            [self setTitle:@"Get Started" forButton:self.primaryButton];
            [self setTitle:@"Skip setup" forButton:self.secondaryButton];
            break;
        }
        case 1:
        {
            self.titleLabel.text = @"Choose your color";
            self.subtitleLabel.text = @"This tints buttons and icons across Slate.";
            [self placeContent:[self accentView] fillWidth:NO];
            [self setTitle:@"Continue" forButton:self.primaryButton];
            [self setTitle:@"Back" forButton:self.secondaryButton];
            break;
        }
        case 2:
        {
            self.titleLabel.text = @"Pick a home layout";
            self.subtitleLabel.text = @"How should your apps appear?";
            [self placeContent:[self layoutView] fillWidth:YES];
            [self setTitle:@"Continue" forButton:self.primaryButton];
            [self setTitle:@"Back" forButton:self.secondaryButton];
            break;
        }
        case 3:
        {
            self.titleLabel.text = @"Developer tools";
            self.subtitleLabel.text = @"Optional. You can change this any time in Settings.";
            [self placeContent:[self developerView] fillWidth:YES];
            [self setTitle:@"Continue" forButton:self.primaryButton];
            [self setTitle:@"Back" forButton:self.secondaryButton];
            break;
        }
        default:
        {
            self.titleLabel.text = @"You're all set";
            self.subtitleLabel.text = @"You can change all of this later in Settings.";
            [self placeContent:[self summaryView] fillWidth:YES];
            [self setTitle:@"Start using Slate" forButton:self.primaryButton];
            [self setTitle:@"Back" forButton:self.secondaryButton];
            break;
        }
    }
}

- (UIView *)accentView
{
    NSArray<NSDictionary *> *options = NXSlotAccentOptions();
    NSString *current = NXSlotChoice(NXSlotPrefAccent, options);

    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 18.0;
    rows.alignment = UIStackViewAlignmentCenter;

    for(NSInteger start = 0; start < (NSInteger)options.count; start += 3)
    {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 18.0;
        for(NSInteger index = start; index < MIN(start + 3, (NSInteger)options.count); index++)
        {
            NSDictionary *option = options[index];
            UIButton *swatch = [UIButton buttonWithType:UIButtonTypeCustom];
            swatch.backgroundColor = NXSlotAccentColorForID(option[@"id"]);
            swatch.layer.cornerRadius = 32.0;
            swatch.tag = index;
            swatch.accessibilityLabel = option[@"title"];
            [swatch.widthAnchor constraintEqualToConstant:64.0].active = YES;
            [swatch.heightAnchor constraintEqualToConstant:64.0].active = YES;
            if([option[@"id"] isEqualToString:current])
            {
                swatch.layer.borderWidth = 4.0;
                swatch.layer.borderColor = UIColor.whiteColor.CGColor;
                swatch.tintColor = UIColor.whiteColor;
                [swatch setImage:[UIImage systemImageNamed:@"checkmark"] forState:UIControlStateNormal];
            }
            [swatch addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:swatch];
        }
        [rows addArrangedSubview:row];
    }
    return rows;
}

- (UIView *)layoutView
{
    NSString *current = NXSlotChoice(NXSlotPrefLayout, NXSlotLayoutOptions());
    NSArray<NSDictionary *> *items = @[
        @{ @"id": @"list", @"title": @"List", @"detail": @"Rows with names", @"symbol": @"list.bullet.rectangle" },
        @{ @"id": @"grid", @"title": @"Grid", @"detail": @"Large icons", @"symbol": @"square.grid.2x2" },
    ];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 16.0;
    stack.distribution = UIStackViewDistributionFillEqually;

    for(NSDictionary *item in items)
    {
        UIButtonConfiguration *configuration = [UIButtonConfiguration grayButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:item[@"symbol"] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:40.0]];
        configuration.imagePlacement = NSDirectionalRectEdgeTop;
        configuration.imagePadding = 12.0;
        configuration.title = item[@"title"];
        configuration.subtitle = item[@"detail"];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(24.0, 12.0, 24.0, 12.0);

        UIButton *card = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
        card.accessibilityIdentifier = item[@"id"];
        card.layer.cornerRadius = 22.0;
        if([item[@"id"] isEqualToString:current])
        {
            card.layer.borderWidth = 3.0;
            card.layer.borderColor = self.view.tintColor.CGColor;
        }
        [card addTarget:self action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:card];
    }
    return stack;
}

- (UIView *)developerView
{
    UIView *container = [UIView new];
    container.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    container.layer.cornerRadius = 16.0;

    UILabel *label = [UILabel new];
    label.text = @"Developer menu";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];

    UISwitch *toggle = [UISwitch new];
    toggle.on = NXROMDefaultBool(NXSlotPrefDeveloperMode, NO);
    [toggle addTarget:self action:@selector(developerToggled:) forControlEvents:UIControlEventValueChanged];

    UILabel *detail = [UILabel new];
    detail.text = @"Adds a process list and app details to Slate. Most people can leave this off.";
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.numberOfLines = 0;

    for(UIView *view in @[ label, toggle, detail ])
    {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12.0],
        [toggle.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [toggle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [detail.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8.0],
        [detail.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [detail.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [detail.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
    ]];
    return container;
}

- (UIView *)summaryView
{
    NSArray<NSString *> *lines = @[
        [NSString stringWithFormat:@"Accent color: %@", NXSlotChoiceTitle(NXSlotPrefAccent, NXSlotAccentOptions())],
        [NSString stringWithFormat:@"Home layout: %@", NXSlotChoiceTitle(NXSlotPrefLayout, NXSlotLayoutOptions())],
        [NSString stringWithFormat:@"Developer menu: %@", NXROMDefaultBool(NXSlotPrefDeveloperMode, NO) ? @"On" : @"Off"],
    ];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.layoutMargins = UIEdgeInsetsMake(20.0, 20.0, 20.0, 20.0);
    stack.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    stack.layer.cornerRadius = 16.0;

    for(NSString *line in lines)
    {
        UILabel *label = [UILabel new];
        label.text = line;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [stack addArrangedSubview:label];
    }
    return stack;
}

- (void)swatchTapped:(UIButton *)sender
{
    NSArray<NSDictionary *> *options = NXSlotAccentOptions();
    if(sender.tag < 0 || sender.tag >= (NSInteger)options.count)
    {
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:options[sender.tag][@"id"] forKey:NXSlotPrefAccent];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self showStep:self.step animated:NO];
}

- (void)cardTapped:(UIButton *)sender
{
    NSString *identifier = sender.accessibilityIdentifier;
    if(identifier.length == 0)
    {
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:NXSlotPrefLayout];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self showStep:self.step animated:NO];
}

- (void)developerToggled:(UISwitch *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:NXSlotPrefDeveloperMode];
}

- (void)nextTapped
{
    if(self.step < NXSlotSetupStepCount - 1)
    {
        [self showStep:self.step + 1 animated:YES];
    }
    else
    {
        [self finish];
    }
}

- (void)backTapped
{
    if(self.step == 0)
    {
        [self finish];
    }
    else
    {
        [self showStep:self.step - 1 animated:YES];
    }
}

- (void)finish
{
    [NSUserDefaults.standardUserDefaults setObject:NXSlotBuildID() forKey:NXSlotPrefSetupBuild];
    void (^completion)(void) = self.completion;
    UINavigationController *navigation = self.navigationController;
    if(!navigation)
    {
        if(completion)
        {
            completion();
        }
        return;
    }
    [navigation popViewControllerAnimated:YES];
    id<UIViewControllerTransitionCoordinator> coordinator = navigation.transitionCoordinator;
    if(coordinator)
    {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if(completion)
            {
                completion();
            }
        }];
    }
    else if(completion)
    {
        completion();
    }
}

@end

static void NXSlotPresentSetup(UIViewController *presenter, BOOL force)
{
    UINavigationController *navigation = presenter.navigationController;
    if(navigation == nil || [navigation.topViewController isKindOfClass:NXROMSetupViewController.class])
    {
        return;
    }
    if(!force)
    {
        if(NXSlotSetupShownThisSession || !NXSlotSetupNeeded() || navigation.topViewController != presenter)
        {
            return;
        }
    }
    NXSlotSetupShownThisSession = YES;

    NXROMSetupViewController *setup = [NXROMSetupViewController new];
    __weak typeof(presenter) weakPresenter = presenter;
    setup.completion = ^{
        NXSlotApplyAppearance(weakPresenter.navigationController);
    };
    [navigation pushViewController:setup animated:force];
}

#pragma mark - Apps (import and installed)

static void NXSlotShowMessage(UIViewController *presenter, NSString *title, NSString *message)
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Reading .ipa files

@interface NXROMZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t localOffset;
@property (nonatomic, assign) uint32_t mode;
@end

@implementation NXROMZipEntry
@end

static uint16_t NXSlotRead16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t NXSlotRead32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t NXSlotRead32BE(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static NSArray<NXROMZipEntry *> *NXSlotZipEntries(NSData *zip, NSString **problem)
{
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    if(length < 22 || NXSlotRead32(bytes) != 0x04034b50)
    {
        *problem = @"The file is not a zip archive, so it is not an .ipa.";
        return nil;
    }

    NSInteger eocd = -1;
    NSInteger first = (NSInteger)length - 22;
    NSInteger last = MAX(0, first - 65535);
    for(NSInteger index = first; index >= last; index--)
    {
        if(NXSlotRead32(bytes + index) == 0x06054b50)
        {
            eocd = index;
            break;
        }
    }
    if(eocd < 0)
    {
        *problem = @"The zip file is damaged: its table of contents is missing.";
        return nil;
    }

    uint16_t count = NXSlotRead16(bytes + eocd + 10);
    uint32_t directorySize = NXSlotRead32(bytes + eocd + 12);
    uint32_t directoryOffset = NXSlotRead32(bytes + eocd + 16);
    if(count == 0xFFFF || directoryOffset == 0xFFFFFFFF)
    {
        *problem = @"This archive is larger than 4 GB, which Slate can't read yet.";
        return nil;
    }
    if((uint64_t)directoryOffset + directorySize > length)
    {
        *problem = @"The zip file is damaged: its table of contents is out of range.";
        return nil;
    }

    NSMutableArray<NXROMZipEntry *> *entries = [NSMutableArray arrayWithCapacity:count];
    NSUInteger offset = directoryOffset;
    for(uint16_t index = 0; index < count; index++)
    {
        if(offset + 46 > length || NXSlotRead32(bytes + offset) != 0x02014b50)
        {
            *problem = @"The zip file is damaged: an entry is unreadable.";
            return nil;
        }
        uint16_t nameLength = NXSlotRead16(bytes + offset + 28);
        uint16_t extraLength = NXSlotRead16(bytes + offset + 30);
        uint16_t commentLength = NXSlotRead16(bytes + offset + 32);
        if(offset + 46 + nameLength > length)
        {
            *problem = @"The zip file is damaged: a file name is out of range.";
            return nil;
        }

        NXROMZipEntry *entry = [NXROMZipEntry new];
        entry.method = NXSlotRead16(bytes + offset + 10);
        entry.compressedSize = NXSlotRead32(bytes + offset + 20);
        entry.size = NXSlotRead32(bytes + offset + 24);
        entry.mode = NXSlotRead32(bytes + offset + 38) >> 16;
        entry.localOffset = NXSlotRead32(bytes + offset + 42);
        entry.name = [[NSString alloc] initWithBytes:bytes + offset + 46 length:nameLength encoding:NSUTF8StringEncoding] ?: @"";
        [entries addObject:entry];

        offset += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
}

static NSData *NXSlotZipData(NSData *zip, NXROMZipEntry *entry)
{
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    NSUInteger local = entry.localOffset;
    if(local + 30 > length || NXSlotRead32(bytes + local) != 0x04034b50)
    {
        return nil;
    }
    uint16_t nameLength = NXSlotRead16(bytes + local + 26);
    uint16_t extraLength = NXSlotRead16(bytes + local + 28);
    NSUInteger start = local + 30 + nameLength + extraLength;
    if(start + entry.compressedSize > length)
    {
        return nil;
    }

    NSData *raw = [NSData dataWithBytes:bytes + start length:entry.compressedSize];
    if(entry.method == 0)
    {
        return raw;
    }
    if(entry.method == 8)
    {
        return [raw decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
    }
    return nil;
}

static BOOL NXSlotMachOInfo(NSData *binary, BOOL *encrypted, BOOL *signedBinary, NSString **architecture)
{
    const uint8_t *bytes = binary.bytes;
    NSUInteger length = binary.length;
    NSUInteger base = 0;
    if(length < 32)
    {
        return NO;
    }

    if(NXSlotRead32BE(bytes) == 0xCAFEBABE)
    {
        uint32_t count = NXSlotRead32BE(bytes + 4);
        BOOL found = NO;
        for(uint32_t index = 0; index < count && 8 + (NSUInteger)(index + 1) * 20 <= length; index++)
        {
            const uint8_t *arch = bytes + 8 + index * 20;
            if(NXSlotRead32BE(arch) == 0x0100000C)
            {
                base = NXSlotRead32BE(arch + 8);
                found = YES;
                break;
            }
        }
        if(!found || base + 32 > length)
        {
            *architecture = @"no arm64 version";
            return NO;
        }
    }

    if(NXSlotRead32(bytes + base) != 0xFEEDFACF)
    {
        *architecture = @"not a 64-bit Mach-O file";
        return NO;
    }
    *architecture = (NXSlotRead32(bytes + base + 4) == 0x0100000C) ? @"arm64" : @"other CPU";

    uint32_t commandCount = NXSlotRead32(bytes + base + 16);
    NSUInteger position = base + 32;
    *encrypted = NO;
    *signedBinary = NO;
    for(uint32_t index = 0; index < commandCount; index++)
    {
        if(position + 8 > length)
        {
            break;
        }
        uint32_t command = NXSlotRead32(bytes + position);
        uint32_t size = NXSlotRead32(bytes + position + 4);
        if(size < 8)
        {
            break;
        }
        if(command == 0x2C && position + 20 <= length)
        {
            *encrypted = (NXSlotRead32(bytes + position + 16) != 0);
        }
        if(command == 0x1D)
        {
            *signedBinary = YES;
        }
        position += size;
    }
    return YES;
}

static NSDictionary *NXSlotInspectIPA(NSData *zip, NSArray<NXROMZipEntry *> *entries, NSString **problem)
{
    NXROMZipEntry *plistEntry = nil;
    for(NXROMZipEntry *entry in entries)
    {
        NSArray<NSString *> *parts = [entry.name componentsSeparatedByString:@"/"];
        if(parts.count == 3 && [parts[0] isEqualToString:@"Payload"] && [parts[1] hasSuffix:@".app"] && [parts[2] isEqualToString:@"Info.plist"])
        {
            plistEntry = entry;
            break;
        }
    }
    if(plistEntry == nil)
    {
        *problem = @"There is no Payload/<name>.app folder with an Info.plist inside, so this is not an iOS app package.";
        return nil;
    }

    NSData *plistData = NXSlotZipData(zip, plistEntry);
    id plist = plistData ? [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:nil] : nil;
    if(![plist isKindOfClass:NSDictionary.class])
    {
        *problem = @"The app's Info.plist could not be read.";
        return nil;
    }
    NSDictionary *info = plist;

    NSString *appFolder = [plistEntry.name stringByDeletingLastPathComponent];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"appFolder"] = appFolder;
    result[@"bundleID"] = info[@"CFBundleIdentifier"] ?: @"(no bundle ID)";
    result[@"name"] = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: appFolder.lastPathComponent;
    result[@"version"] = info[@"CFBundleShortVersionString"] ?: @"?";
    result[@"minOS"] = info[@"MinimumOSVersion"] ?: @"?";

    NSString *executable = info[@"CFBundleExecutable"];
    if([executable isKindOfClass:NSString.class] && executable.length > 0)
    {
        NSString *executableName = [appFolder stringByAppendingPathComponent:executable];
        for(NXROMZipEntry *entry in entries)
        {
            if([entry.name isEqualToString:executableName])
            {
                if(entry.size > 200u * 1024u * 1024u)
                {
                    result[@"architecture"] = @"too large to check";
                    break;
                }
                NSData *binary = NXSlotZipData(zip, entry);
                BOOL encrypted = NO;
                BOOL signedBinary = NO;
                NSString *architecture = nil;
                if(binary != nil && NXSlotMachOInfo(binary, &encrypted, &signedBinary, &architecture))
                {
                    result[@"encrypted"] = @(encrypted);
                    result[@"signed"] = @(signedBinary);
                }
                if(architecture != nil)
                {
                    result[@"architecture"] = architecture;
                }
                break;
            }
        }
    }
    return result;
}

static NSString *NXSlotSummary(NSDictionary *info)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"%@ (%@)", info[@"name"], info[@"bundleID"]]];
    [lines addObject:[NSString stringWithFormat:@"Version %@, needs iOS %@ or newer", info[@"version"], info[@"minOS"]]];
    if(info[@"architecture"] != nil)
    {
        [lines addObject:[NSString stringWithFormat:@"Binary: %@", info[@"architecture"]]];
    }
    if(info[@"encrypted"] != nil)
    {
        [lines addObject:[NSString stringWithFormat:@"Encrypted: %@", [info[@"encrypted"] boolValue] ? @"yes" : @"no"]];
    }
    if(info[@"signed"] != nil)
    {
        [lines addObject:[NSString stringWithFormat:@"Code signature: %@", [info[@"signed"] boolValue] ? @"present" : @"missing"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *NXSlotExtractApp(NSData *zip, NSArray<NXROMZipEntry *> *entries, NSString *appFolder, NSString **problem)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"SlateImport-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *prefix = [appFolder stringByAppendingString:@"/"];

    for(NXROMZipEntry *entry in entries)
    {
        if(![entry.name hasPrefix:prefix] || [entry.name containsString:@".."] || [entry.name hasPrefix:@"/"])
        {
            continue;
        }
        NSString *destination = [root stringByAppendingPathComponent:entry.name];
        if([entry.name hasSuffix:@"/"])
        {
            [manager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        [manager createDirectoryAtPath:[destination stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = NXSlotZipData(zip, entry);
        if(data == nil)
        {
            *problem = [NSString stringWithFormat:@"Could not unpack %@.", entry.name.lastPathComponent];
            [manager removeItemAtPath:root error:nil];
            return nil;
        }

        if((entry.mode & 0xF000) == 0xA000)
        {
            NSString *target = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if(target.length > 0)
            {
                [manager createSymbolicLinkAtPath:destination withDestinationPath:target error:nil];
            }
            continue;
        }

        NSError *error = nil;
        if(![data writeToFile:destination options:NSDataWritingAtomic error:&error])
        {
            *problem = [NSString stringWithFormat:@"Could not write %@: %@", entry.name.lastPathComponent, error.localizedDescription];
            [manager removeItemAtPath:root error:nil];
            return nil;
        }
        uint32_t permissions = entry.mode & 0777;
        if(permissions == 0)
        {
            permissions = 0644;
        }
        [manager setAttributes:@{ NSFilePosixPermissions: @(permissions) } ofItemAtPath:destination error:nil];
    }
    return [root stringByAppendingPathComponent:appFolder];
}

static void NXSlotRunInstall(NSString *path, NSString **title, NSString **message)
{
    NSString *problem = nil;
    NSData *zip = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSArray<NXROMZipEntry *> *entries = zip ? NXSlotZipEntries(zip, &problem) : nil;
    if(entries == nil)
    {
        *title = @"Can't read the file";
        *message = problem ?: @"The file could not be opened.";
        return;
    }
    NSDictionary *info = NXSlotInspectIPA(zip, entries, &problem);
    if(info == nil)
    {
        *title = @"Not an app package";
        *message = problem ?: @"This file does not look like an iOS app.";
        return;
    }
    NSString *summary = NXSlotSummary(info);

    if([info[@"encrypted"] boolValue])
    {
        *title = @"This app is encrypted";
        *message = [NSString stringWithFormat:@"%@\n\nThe App Store encrypts its apps, and Slate can only run decrypted ones, such as open-source apps or apps you built yourself.", summary];
        return;
    }

    LDEApplicationWorkspace *workspace = [LDEApplicationWorkspace shared];
    if([workspace installApplicationAtPackagePath:path])
    {
        *title = @"Installed";
        *message = [NSString stringWithFormat:@"%@\n\nOpen it from Settings > Installed apps.", summary];
        return;
    }

    NSString *extractProblem = nil;
    NSString *bundlePath = NXSlotExtractApp(zip, entries, info[@"appFolder"], &extractProblem);
    if(bundlePath != nil)
    {
        BOOL installed = [workspace installApplicationAtBundlePath:bundlePath];
        NSString *root = [[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        if(installed)
        {
            *title = @"Installed";
            *message = [NSString stringWithFormat:@"%@\n\nSlate unpacked the app first. Open it from Settings > Installed apps.", summary];
            return;
        }
    }

    *title = @"Install failed";
    *message = [NSString stringWithFormat:@"%@\n\nSlate tried the .ipa directly and after unpacking it. The system refused both and gave no reason.%@", summary, extractProblem ? [@"\n\n" stringByAppendingString:extractProblem] : @""];
}

static void NXSlotInstallPackage(NSString *path, UIViewController *presenter)
{
    if(![path.pathExtension.lowercaseString isEqualToString:@"ipa"])
    {
        NXSlotShowMessage(presenter, @"Not an .ipa file", @"Choose a file whose name ends in .ipa.");
        return;
    }

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Installing…" message:@"Checking and installing the app.\n\n" preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [progress.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-20.0],
    ]];
    [spinner startAnimating];

    [presenter presentViewController:progress animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *title = nil;
            NSString *message = nil;
            NXSlotRunInstall(path, &title, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:YES completion:^{
                    NXSlotShowMessage(presenter, title ?: @"Install finished", message ?: @"");
                }];
            });
        });
    }];
}

@interface NXROMImportDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
@end

static NXROMImportDelegate *NXSlotImportDelegate;

@implementation NXROMImportDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    UIViewController *presenter = self.presenter;
    NXSlotImportDelegate = nil;
    if(url == nil || presenter == nil)
    {
        return;
    }
    NXSlotInstallPackage(url.path, presenter);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    NXSlotImportDelegate = nil;
}

@end

static void NXSlotImportApp(UIViewController *presenter)
{
    NXROMImportDelegate *delegate = [NXROMImportDelegate new];
    delegate.presenter = presenter;
    NXSlotImportDelegate = delegate;

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.data" ] inMode:UIDocumentPickerModeImport];
    picker.delegate = delegate;
    picker.allowsMultipleSelection = NO;
    [presenter presentViewController:picker animated:YES completion:nil];
}

static NSString *NXSlotAppDetails(LDEApplicationObject *app)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *executable = app.executablePath;
    BOOL exists = executable.length > 0 && [manager fileExistsAtPath:executable];
    BOOL runnable = exists && [manager isExecutableFileAtPath:executable];
    return [NSString stringWithFormat:@"Bundle ID: %@\nExecutable: %@\nFile found: %@, runnable: %@\nLaunch allowed: %@\nPermissions given: %lu",
            app.bundleIdentifier ?: @"?",
            executable ?: @"(none)",
            exists ? @"yes" : @"no",
            runnable ? @"yes" : @"no",
            app.isLaunchAllowed ? @"yes" : @"no",
            (unsigned long)app.entitlements.count];
}

/* The installer can drop the "runnable" permission of the main executable. Put it back and report why that failed, or nil on success. */
static NSString *NXSlotRepairExecutable(LDEApplicationObject *app)
{
    NSString *path = app.executablePath;
    NSFileManager *manager = NSFileManager.defaultManager;
    if(path.length == 0 || ![manager fileExistsAtPath:path])
    {
        return @"The app's executable file is missing.";
    }
    if([manager isExecutableFileAtPath:path])
    {
        return nil;
    }
    NSError *error = nil;
    if(![manager setAttributes:@{ NSFilePosixPermissions: @(0755) } ofItemAtPath:path error:&error])
    {
        return [NSString stringWithFormat:@"The executable is not marked runnable and Slate could not fix it: %@", error.localizedDescription];
    }
    if(![manager isExecutableFileAtPath:path])
    {
        return @"The executable is still not runnable after fixing its permissions.";
    }
    return nil;
}

/* Starts an installed app the same way the ROM starts its own apps and returns why it failed, or nil on success. */
static NSString *NXSlotLaunchInstalled(LDEApplicationObject *app)
{
    NSString *executablePath = app.executablePath;
    NSString *repairProblem = NXSlotRepairExecutable(app);
    if(repairProblem != nil)
    {
        return repairProblem;
    }
    if(!app.isLaunchAllowed)
    {
        return @"The system marked this app as not allowed to launch.";
    }

    PEFileTable *table = [PEFileTable emptyTable];
    [table appendFileDescriptor:STDOUT_FILENO withMappingToLoc:STDOUT_FILENO];
    [table appendFileDescriptor:STDERR_FILENO withMappingToLoc:STDERR_FILENO];

    errno = 0;
    pid_t pid = [[PEProcessManager shared] spawnProcessWithItems:@{
        @"PEExecutablePath": executablePath,
        @"PEArguments": @[ executablePath ],
        @"PEWorkingDirectory": NXBootstrap.shared.rootfsURL.path,
        @"PEEnvironment": @{},
        @"PEFileTable": table,
    } withKernelSurfaceProcess:NULL];
    if(pid < 0)
    {
        int error = errno;
        return [NSString stringWithFormat:@"Starting the process failed: %s", error ? strerror(error) : "the system rejected it"];
    }

    PEProcess *process = [[PEProcessManager shared] processForProcessIdentifier:pid];
    if(process != nil && process.bundleIdentifier == nil)
    {
        process.applicationObject = app;
        process.bundleIdentifier = app.bundleIdentifier;
        process.displayName = app.localizedName;
    }
    return nil;
}

@interface NXROMInstalledAppsViewController : UITableViewController
@property (nonatomic, copy) NSArray<LDEApplicationObject *> *apps;
@end

@implementation NXROMInstalledAppsViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Installed apps";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"app"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(importTapped)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Import app";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
}

- (UILabel *)messageLabel:(NSString *)text
{
    UILabel *label = [UILabel new];
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

- (void)reload
{
    if(self.apps.count == 0)
    {
        self.tableView.backgroundView = [self messageLabel:@"Loading…"];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<LDEApplicationObject *> *apps = [[LDEApplicationWorkspace shared] allApplicationObjects] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            NXROMInstalledAppsViewController *strongSelf = weakSelf;
            if(strongSelf == nil)
            {
                return;
            }
            strongSelf.apps = apps;
            if(apps.count == 0)
            {
                strongSelf.tableView.backgroundView = [strongSelf messageLabel:@"No imported apps yet.\nTap + to import an .ipa file."];
            }
            else
            {
                strongSelf.tableView.backgroundView = nil;
            }
            [strongSelf.tableView reloadData];
        });
    });
}

- (void)importTapped
{
    NXSlotImportApp(self);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    LDEApplicationObject *app = self.apps[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app" forIndexPath:indexPath];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = app.localizedName.length > 0 ? app.localizedName : app.bundleIdentifier;
    NSString *version = app.shortVersionString.length > 0 ? app.shortVersionString : @"?";
    content.secondaryText = [NSString stringWithFormat:@"%@ · %@", app.bundleIdentifier, version];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = app.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    content.imageProperties.maximumSize = CGSizeMake(44.0, 44.0);
    content.imageProperties.cornerRadius = 10.0;
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openApp:self.apps[indexPath.row]];
}

- (void)openApp:(LDEApplicationObject *)app
{
    NSString *bundleIdentifier = app.bundleIdentifier;
    NSString *name = app.localizedName.length > 0 ? app.localizedName : bundleIdentifier;
    if(NXROMActivateWindow(bundleIdentifier))
    {
        return;
    }

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Opening…" message:name preferredStyle:UIAlertControllerStyleAlert];
    [progress addAction:[UIAlertAction actionWithTitle:@"Hide" style:UIAlertActionStyleCancel handler:nil]];
    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;

    [self presentViewController:progress animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NXSlotRepairExecutable(app);
            BOOL opened = [[LDEApplicationWorkspace shared] openApplicationWithBundleID:bundleIdentifier];
            NSString *reason = nil;
            if(!opened)
            {
                reason = NXSlotLaunchInstalled(app);
                opened = (reason == nil);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                finished = YES;
                [progress dismissViewControllerAnimated:YES completion:^{
                    if(!opened && weakSelf != nil)
                    {
                        NSString *text = [NSString stringWithFormat:@"%@\n\n%@", reason ?: @"The system refused to start it.", NXSlotAppDetails(app)];
                        NXSlotShowMessage(weakSelf, @"Couldn't open the app", text);
                    }
                }];
            });
        });
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if(!finished && progress.presentingViewController != nil)
        {
            progress.message = [NSString stringWithFormat:@"%@\n\nStill starting. Some apps need features this ROM doesn't have, so this one may never open. You can tap Hide and keep using Slate.", name];
        }
    });
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if(editingStyle != UITableViewCellEditingStyleDelete)
    {
        return;
    }
    NSString *bundleIdentifier = self.apps[indexPath.row].bundleIdentifier;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL deleted = [[LDEApplicationWorkspace shared] deleteApplicationWithBundleID:bundleIdentifier];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(!deleted && weakSelf != nil)
            {
                NXSlotShowMessage(weakSelf, @"Couldn't delete the app", @"The system refused to remove it.");
            }
            [weakSelf reload];
        });
    });
}

@end

static UIViewController *NXSlotMakeInstalledAppsController(void)
{
    return [NXROMInstalledAppsViewController new];
}

#pragma mark - Home

@interface NXROMApplicationsViewController : UITableViewController
@property (nonatomic, copy) NSArray<NXROMApplication *> *applications;
@property (nonatomic, copy) NSArray<NSNumber *> *runningPids;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation NXROMApplicationsViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = NXROMDisplayName();
    self.tableView.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"application"];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet.rectangle"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(showProcesses:)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"Processes";

    UIBarButtonItem *switcher = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.stack.3d.up"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(showAppSwitcher:)];
    switcher.accessibilityLabel = @"App Switcher";
    switcher.enabled = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(showSettings:)];
    settings.accessibilityLabel = @"Settings";
    self.navigationItem.rightBarButtonItems = @[ settings, switcher ];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.view.tintColor = NXSlotAccentColor();
    self.applications = NXROMApplications();
    self.runningPids = [self currentRunningPids];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshRunningState];
    }];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    NXSlotPresentSetup(self, NO);
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (NSArray<NSNumber *> *)currentRunningPids
{
    NSMutableArray<NSNumber *> *pids = [NSMutableArray arrayWithCapacity:self.applications.count];
    for(NXROMApplication *application in self.applications)
    {
        PEProcess *process = [[PEProcessManager shared] processForBundleIdentifier:application.bundleIdentifier];
        [pids addObject:@(process ? process.pid : 0)];
    }
    return pids;
}

- (void)refreshRunningState
{
    NSArray<NSNumber *> *pids = [self currentRunningPids];
    if([pids isEqualToArray:self.runningPids])
    {
        return;
    }
    NSMutableArray<NSIndexPath *> *changed = [NSMutableArray array];
    for(NSUInteger row = 0; row < pids.count && row < self.runningPids.count; row++)
    {
        if(![pids[row] isEqualToNumber:self.runningPids[row]])
        {
            [changed addObject:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]];
        }
    }
    self.runningPids = pids;
    [self.tableView reconfigureRowsAtIndexPaths:changed];
}

- (void)showProcesses:(id)sender
{
    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:[NXROMProcessesViewController new]];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *presentation = sheet.sheetPresentationController;
    presentation.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
    presentation.prefersGrabberVisible = YES;
    presentation.prefersScrollingExpandsWhenScrolledToEdge = NO;
    presentation.prefersEdgeAttachedInCompactHeight = YES;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSettings:(id)sender
{
    [self.navigationController pushViewController:[NXROMSettingsViewController new] animated:YES];
}

- (void)showAppSwitcher:(id)sender
{
    [[NXWindowServer shared] showAppSwitcherExternal];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.applications.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @"Apps";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return self.applications.count == 0 ? @"This ROM ships no apps (Application/*.app)." : [NSString stringWithFormat:@"Slate %@", NXROMVersionString()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"application" forIndexPath:indexPath];
    NXROMApplication *application = self.applications[indexPath.row];
    PEProcess *process = [[PEProcessManager shared] processForBundleIdentifier:application.bundleIdentifier];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = application.name;
    BOOL showDetails = NXROMDefaultBool(NXSlotPrefDeveloperMode, NO) && NXROMDefaultBool(NXSlotPrefShowDetails, NO);
    if(showDetails && process)
    {
        content.secondaryText = [NSString stringWithFormat:@"%@ · running, pid %d", application.bundleIdentifier, process.pid];
    }
    else if(showDetails)
    {
        content.secondaryText = application.bundleIdentifier;
    }
    else
    {
        content.secondaryText = process ? @"Running" : @"Tap to open";
    }
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = application.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    content.imageProperties.maximumSize = CGSizeMake(40.0, 40.0);
    content.imageProperties.reservedLayoutSize = CGSizeMake(40.0, 40.0);
    content.imageProperties.cornerRadius = application.icon ? 9.0 : 0.0;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NXROMOpenApplication(self.applications[indexPath.row]);
}

@end

#pragma mark - Grid layout

@interface NXROMGridCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIView *runningDot;
@end

@implementation NXROMGridCell

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if(self)
    {
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 14.0;
        _iconView.clipsToBounds = YES;

        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.numberOfLines = 2;

        _runningDot = [UIView new];
        _runningDot.backgroundColor = UIColor.systemGreenColor;
        _runningDot.layer.cornerRadius = 4.0;

        for(UIView *view in @[ _iconView, _nameLabel, _runningDot ])
        {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:view];
        }

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4.0],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:60.0],
            [_iconView.heightAnchor constraintEqualToConstant:60.0],
            [_nameLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:6.0],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_runningDot.widthAnchor constraintEqualToConstant:8.0],
            [_runningDot.heightAnchor constraintEqualToConstant:8.0],
            [_runningDot.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_runningDot.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4.0],
        ]];
    }
    return self;
}

@end

@interface NXROMGridViewController : UICollectionViewController
@property (nonatomic, copy) NSArray<NXROMApplication *> *applications;
@property (nonatomic, copy) NSArray<NSNumber *> *runningPids;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation NXROMGridViewController

- (instancetype)init
{
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(92.0, 112.0);
    layout.minimumInteritemSpacing = 8.0;
    layout.minimumLineSpacing = 16.0;
    layout.sectionInset = UIEdgeInsetsMake(16.0, 16.0, 24.0, 16.0);
    return [super initWithCollectionViewLayout:layout];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = NXROMDisplayName();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.collectionView.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    [self.collectionView registerClass:NXROMGridCell.class forCellWithReuseIdentifier:@"app"];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet.rectangle"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(showProcesses:)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"Processes";

    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(showSettings:)];
    settings.accessibilityLabel = @"Settings";

    UIBarButtonItem *switcher = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.stack.3d.up"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(showAppSwitcher:)];
    switcher.accessibilityLabel = @"App Switcher";
    switcher.enabled = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    self.navigationItem.rightBarButtonItems = @[ settings, switcher ];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.view.tintColor = NXSlotAccentColor();
    [self reloadApplications];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshRunningState];
    }];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    NXSlotPresentSetup(self, NO);
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (NSArray<NSNumber *> *)currentRunningPids
{
    NSMutableArray<NSNumber *> *pids = [NSMutableArray arrayWithCapacity:self.applications.count];
    for(NXROMApplication *application in self.applications)
    {
        PEProcess *process = [[PEProcessManager shared] processForBundleIdentifier:application.bundleIdentifier];
        [pids addObject:@(process ? process.pid : 0)];
    }
    return pids;
}

- (void)reloadApplications
{
    self.applications = NXROMApplications();
    self.runningPids = [self currentRunningPids];
    if(self.applications.count == 0)
    {
        UILabel *label = [UILabel new];
        label.text = @"This ROM ships no apps (Application/*.app).";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.textColor = UIColor.secondaryLabelColor;
        self.collectionView.backgroundView = label;
    }
    else
    {
        self.collectionView.backgroundView = nil;
    }
    [self.collectionView reloadData];
}

- (void)refreshRunningState
{
    NSArray<NSNumber *> *pids = [self currentRunningPids];
    if([pids isEqualToArray:self.runningPids])
    {
        return;
    }
    self.runningPids = pids;
    [self.collectionView reloadData];
}

- (void)showProcesses:(id)sender
{
    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:[NXROMProcessesViewController new]];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *presentation = sheet.sheetPresentationController;
    presentation.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
    presentation.prefersGrabberVisible = YES;
    presentation.prefersScrollingExpandsWhenScrolledToEdge = NO;
    presentation.prefersEdgeAttachedInCompactHeight = YES;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSettings:(id)sender
{
    [self.navigationController pushViewController:[NXROMSettingsViewController new] animated:YES];
}

- (void)showAppSwitcher:(id)sender
{
    [[NXWindowServer shared] showAppSwitcherExternal];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self.applications.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    NXROMGridCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"app" forIndexPath:indexPath];
    NXROMApplication *application = self.applications[indexPath.item];
    PEProcess *process = [[PEProcessManager shared] processForBundleIdentifier:application.bundleIdentifier];
    cell.iconView.image = application.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.nameLabel.text = application.name;
    cell.runningDot.hidden = (process == nil);
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    NXROMOpenApplication(self.applications[indexPath.item]);
}

@end

static UIViewController *NXSlotMakeHome(void)
{
    if([NXSlotChoice(NXSlotPrefLayout, NXSlotLayoutOptions()) isEqualToString:@"grid"])
    {
        return [NXROMGridViewController new];
    }
    return [NXROMApplicationsViewController new];
}

UIViewController *NXMainSlot(void)
{
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"nyxian.boot.entitlements.mode"];
    PEEnforcementMode enforcement = kPEEnforcementModeEnforcing;
    if([mode isEqualToString:@"permissive"])
    {
        enforcement = kPEEnforcementModePermissive;
    }
    else if ([mode isEqualToString:@"disabled"])
    {
        enforcement = kPEEnforcementModeDisabled;
    }

    trust_enforcement_set_mode(enforcement);
    char bootArguments[NX_BOOT_ARGS_MAX];
    NXBootArgsCopy(bootArguments, sizeof(bootArguments));
    klog_set_obfuscation(NXBootArgsGetBool(bootArguments, NX_BOOT_ARG_KLOG_OBFUSCATE, true));

    [[NXBootstrap shared] bootstrap];
    [[NXBootstrap shared] waitTillDoneNoButton];

    BOOL loadKexts = !NXBootArgsHasFlag(bootArguments, NX_BOOT_ARG_NO_KEXTS);
    [[PEUserspaceManager shared] bootWithKextLoadingEnabled:loadKexts];

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:NXSlotMakeHome()];
    navigation.navigationBar.prefersLargeTitles = YES;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.view.tintColor = NXSlotAccentColor();
    return navigation;
}

__attribute__((visibility("default")))
void *NXSlotMain(void)
{
    UIViewController *root = NXMainSlot();
    return (__bridge_retained void *)root;
}

__attribute__((visibility("default")))
void *NXSlotCreateWindow(void *scenePtr)
{
    if(scenePtr == NULL)
    {
        return NULL;
    }
    UIWindowScene *scene = (__bridge UIWindowScene *)scenePtr;
    NXWindowServer *window = [NXWindowServer sharedWithWindowScene:scene];
    return window ? (__bridge_retained void *)window : NULL;
}

__attribute__((visibility("default")))
void NXSlotDidAppear(void)
{
    [[NXWindowServer shared] makeKeyAndVisible];
}
