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

    NSMutableArray<NSDictionary *> *developerRows = [NSMutableArray array];
    [developerRows addObject:@{ @"kind": @"switch", @"title": @"Developer menu", @"key": NXSlotPrefDeveloperMode, @"default": @NO }];
    if(developer)
    {
        [developerRows addObject:@{ @"kind": @"link", @"title": @"Processes" }];
        [developerRows addObject:@{ @"kind": @"switch", @"title": @"Show app details", @"key": NXSlotPrefShowDetails, @"default": @NO }];
    }
    [sections addObject:@{
        @"title": @"Developer",
        @"footer": developer ? @"App details shows each app's bundle identifier and process ID on the home screen." : @"",
        @"rows": developerRows,
    }];

    [sections addObject:@{
        @"title": @"",
        @"footer": @"",
        @"rows": @[ @{ @"kind": @"button", @"title": @"Reset Slate settings" } ],
    }];

    self.model = sections;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    [self reloadModel];
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

    UIListContentConfiguration *content = [kind isEqualToString:@"value"] ? [UIListContentConfiguration valueCellConfiguration] : [UIListContentConfiguration cellConfiguration];
    content.text = row[@"title"];

    if([kind isEqualToString:@"value"])
    {
        content.secondaryText = row[@"value"];
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
    else if([kind isEqualToString:@"button"])
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Slate settings?"
                                                                       message:@"This restores the default Slate settings."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:NXSlotPrefDeveloperMode];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:NXSlotPrefShowDetails];
            [self reloadModel];
            [self.tableView reloadData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

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
    self.applications = NXROMApplications();
    self.runningPids = [self currentRunningPids];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshRunningState];
    }];
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
    content.secondaryText = process ? @"Running" : @"Tap to open";
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

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[NXROMApplicationsViewController new]];
    navigation.navigationBar.prefersLargeTitles = YES;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.view.tintColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.95 alpha:1.0];
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
