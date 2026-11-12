#import <UIKit/UIKit.h>
#include <unistd.h>

#pragma mark - Model

@interface SlateNote : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *preview;
@end

@implementation SlateNote

- (NSArray<NSString *> *)lines
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for(NSString *line in [self.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
    {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(trimmed.length > 0)
        {
            [lines addObject:trimmed];
        }
    }
    return lines;
}

- (NSString *)title
{
    return [self lines].firstObject ?: @"New Note";
}

- (NSString *)preview
{
    NSArray<NSString *> *lines = [self lines];
    return lines.count > 1 ? lines[1] : @"No additional text";
}

@end

#pragma mark - Storage locations

@interface SlateStorageLocation : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL durable;
@property (nonatomic, assign) BOOL writable;
@property (nonatomic, copy) NSString *detail;
@end

@implementation SlateStorageLocation
@end

#pragma mark - Storage

@interface SlateNoteStore : NSObject
@property (nonatomic, strong) NSMutableArray<SlateNote *> *notes;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, copy) NSString *storageProblem;
@property (nonatomic, copy) NSArray<SlateStorageLocation *> *locations;
@property (nonatomic, strong) SlateStorageLocation *chosen;
+ (instancetype)shared;
- (SlateNote *)createNote;
- (void)deleteNote:(SlateNote *)note;
- (void)save;
@end

@implementation SlateNoteStore

+ (instancetype)shared
{
    static SlateNoteStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [SlateNoteStore new];
        [store load];
    });
    return store;
}

- (void)probeStorage
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<SlateStorageLocation *> *locations = [NSMutableArray array];

    void (^add)(NSString *, NSString *, BOOL) = ^(NSString *name, NSString *path, BOOL durable) {
        if(path.length == 0)
        {
            return;
        }
        SlateStorageLocation *location = [SlateStorageLocation new];
        location.name = name;
        location.path = path;
        location.durable = durable;
        [locations addObject:location];
    };
    add(@"Documents", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject], YES);
    add(@"Application Support", [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject], YES);
    add(@"Library", [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject], YES);
    add(@"Home folder", NSHomeDirectory(), YES);
    add(@"Caches", [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject], NO);
    add(@"Temporary", NSTemporaryDirectory(), NO);
    add(@"/tmp", @"/tmp", NO);
    add(@"/var/tmp", @"/var/tmp", NO);

    SlateStorageLocation *chosen = nil;
    for(SlateStorageLocation *location in locations)
    {
        NSString *directory = [location.path stringByAppendingPathComponent:@"SlateNotes"];
        NSError *error = nil;
        BOOL ok = [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
        if(ok)
        {
            NSString *probe = [directory stringByAppendingPathComponent:@".write-test"];
            ok = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&error];
            if(ok)
            {
                [manager removeItemAtPath:probe error:nil];
            }
        }
        location.writable = ok;
        location.detail = ok ? @"Writable" : (error.localizedDescription ?: @"Not writable");
        if(ok && chosen == nil)
        {
            chosen = location;
            self.fileURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"notes.json"]];
        }
    }
    self.locations = locations;
    self.chosen = chosen;
    if(chosen == nil)
    {
        self.storageProblem = @"None of the tested locations can be written to.";
    }
}

- (void)load
{
    self.notes = [NSMutableArray array];

    [self probeStorage];
    if(self.fileURL == nil)
    {
        return;
    }

    NSData *data = [NSData dataWithContentsOfURL:self.fileURL];
    if(data == nil)
    {
        return;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![object isKindOfClass:NSArray.class])
    {
        return;
    }
    for(id item in (NSArray *)object)
    {
        if(![item isKindOfClass:NSDictionary.class])
        {
            continue;
        }
        NSDictionary *dictionary = item;
        SlateNote *note = [SlateNote new];
        note.identifier = dictionary[@"id"] ?: NSUUID.UUID.UUIDString;
        note.text = dictionary[@"text"] ?: @"";
        note.modified = [NSDate dateWithTimeIntervalSince1970:[dictionary[@"modified"] doubleValue]];
        [self.notes addObject:note];
    }
    [self sort];
}

- (void)sort
{
    [self.notes sortUsingComparator:^NSComparisonResult(SlateNote *a, SlateNote *b) {
        return [b.modified compare:a.modified];
    }];
}

- (SlateNote *)createNote
{
    SlateNote *note = [SlateNote new];
    note.identifier = NSUUID.UUID.UUIDString;
    note.text = @"";
    note.modified = [NSDate date];
    [self.notes insertObject:note atIndex:0];
    return note;
}

- (void)deleteNote:(SlateNote *)note
{
    [self.notes removeObject:note];
    [self save];
}

- (void)save
{
    [self sort];
    if(self.fileURL == nil)
    {
        return;
    }
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for(SlateNote *note in self.notes)
    {
        [items addObject:@{
            @"id": note.identifier,
            @"text": note.text ?: @"",
            @"modified": @(note.modified.timeIntervalSince1970),
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
    NSError *error = nil;
    if(data != nil && [data writeToURL:self.fileURL options:NSDataWritingAtomic error:&error])
    {
        self.storageProblem = nil;
    }
    else
    {
        self.storageProblem = error.localizedDescription ?: @"Writing the notes file failed.";
    }
}

@end

#pragma mark - Storage screen

@interface SlateStorageViewController : UITableViewController
@end

@implementation SlateStorageViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Storage";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if(section == 0)
    {
        return 1;
    }
    if(section == 1)
    {
        return [SlateNoteStore shared].locations.count;
    }
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if(section == 0)
    {
        return @"In use";
    }
    if(section == 1)
    {
        return @"Locations tested";
    }
    return @"Process";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    SlateNoteStore *store = [SlateNoteStore shared];
    if(section == 0 && store.chosen != nil && !store.chosen.durable)
    {
        return @"This location may be cleared by the system, so notes might not last.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SlateNoteStore *store = [SlateNoteStore shared];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;

    if(indexPath.section == 0)
    {
        content.text = store.chosen ? store.chosen.name : @"Nothing writable";
        content.secondaryText = store.chosen ? store.chosen.path : store.storageProblem;
    }
    else if(indexPath.section == 1)
    {
        SlateStorageLocation *location = store.locations[indexPath.row];
        content.text = location.name;
        content.secondaryText = location.writable ? location.path : [NSString stringWithFormat:@"%@\n%@", location.path, location.detail];
        content.image = [UIImage systemImageNamed:location.writable ? @"checkmark.circle.fill" : @"xmark.circle.fill"];
        content.imageProperties.tintColor = location.writable ? UIColor.systemGreenColor : UIColor.systemRedColor;
    }
    else if(indexPath.row == 0)
    {
        content.text = @"User ID";
        content.secondaryText = [NSString stringWithFormat:@"%d", (int)getuid()];
    }
    else if(indexPath.row == 1)
    {
        content.text = @"Home folder";
        content.secondaryText = NSHomeDirectory();
    }
    else
    {
        content.text = @"App bundle";
        content.secondaryText = NSBundle.mainBundle.bundlePath;
    }

    cell.contentConfiguration = content;
    return cell;
}

@end

#pragma mark - Editor

@interface SlateNoteEditorViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) SlateNote *note;
@property (nonatomic, assign) BOOL isNewNote;
@property (nonatomic, strong) UITextView *textView;
- (instancetype)initWithNote:(SlateNote *)note isNew:(BOOL)isNew;
@end

@implementation SlateNoteEditorViewController

- (instancetype)initWithNote:(SlateNote *)note isNew:(BOOL)isNew
{
    self = [super init];
    if(self)
    {
        _note = note;
        _isNewNote = isNew;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.delegate = self;
    self.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.textView.backgroundColor = UIColor.clearColor;
    self.textView.textContainerInset = UIEdgeInsetsMake(16.0, 12.0, 16.0, 12.0);
    self.textView.alwaysBounceVertical = YES;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.textView.text = self.note.text;
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if(self.isNewNote)
    {
        [self.textView becomeFirstResponder];
        self.isNewNote = NO;
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.view endEditing:YES];
    if(!self.isMovingFromParentViewController)
    {
        return;
    }
    NSString *trimmed = [self.note.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(trimmed.length == 0)
    {
        [[SlateNoteStore shared] deleteNote:self.note];
    }
    else
    {
        [[SlateNoteStore shared] save];
    }
}

- (void)doneTapped
{
    [self.textView resignFirstResponder];
}

- (void)textViewDidBeginEditing:(UITextView *)textView
{
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(doneTapped)];
}

- (void)textViewDidEndEditing:(UITextView *)textView
{
    self.navigationItem.rightBarButtonItem = nil;
    [[SlateNoteStore shared] save];
}

- (void)textViewDidChange:(UITextView *)textView
{
    self.note.text = textView.text;
    self.note.modified = [NSDate date];
}

@end

#pragma mark - List

@interface SlateNotesListViewController : UITableViewController
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation SlateNotesListViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Notes";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"note"];

    self.dateFormatter = [NSDateFormatter new];
    self.dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;
    self.dateFormatter.doesRelativeDateFormatting = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.pencil"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(composeTapped)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"New Note";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(storageTapped)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"Storage";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload
{
    NSArray<SlateNote *> *notes = [SlateNoteStore shared].notes;
    if(notes.count == 0)
    {
        UILabel *label = [UILabel new];
        label.text = @"No notes yet.\nTap the pencil to write one.";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.textColor = UIColor.secondaryLabelColor;
        self.tableView.backgroundView = label;
    }
    else
    {
        self.tableView.backgroundView = nil;
    }
    [self.tableView reloadData];
}

- (void)composeTapped
{
    SlateNote *note = [[SlateNoteStore shared] createNote];
    SlateNoteEditorViewController *editor = [[SlateNoteEditorViewController alloc] initWithNote:note isNew:YES];
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)storageTapped
{
    [self.navigationController pushViewController:[SlateStorageViewController new] animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [SlateNoteStore shared].notes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SlateNote *note = [SlateNoteStore shared].notes[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"note" forIndexPath:indexPath];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = note.title;
    content.textProperties.numberOfLines = 1;
    content.secondaryText = [NSString stringWithFormat:@"%@  %@", [self.dateFormatter stringFromDate:note.modified], note.preview];
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SlateNote *note = [SlateNoteStore shared].notes[indexPath.row];
    SlateNoteEditorViewController *editor = [[SlateNoteEditorViewController alloc] initWithNote:note isNew:NO];
    [self.navigationController pushViewController:editor animated:YES];
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
    SlateNote *note = [SlateNoteStore shared].notes[indexPath.row];
    [[SlateNoteStore shared] deleteNote:note];
    [self reload];
}

@end

#pragma mark - App

@interface SlateNotesSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SlateNotesSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    if(![scene isKindOfClass:UIWindowScene.class])
    {
        return;
    }

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[SlateNotesListViewController new]];
    navigation.navigationBar.prefersLargeTitles = YES;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.tintColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.95 alpha:1.0];
    window.rootViewController = navigation;
    self.window = window;
    [window makeKeyAndVisible];
}

- (void)sceneDidEnterBackground:(UIScene *)scene
{
    [[SlateNoteStore shared] save];
}

@end

@interface SlateNotesAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SlateNotesAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
    configuration.delegateClass = SlateNotesSceneDelegate.class;
    return configuration;
}

@end

__attribute__((visibility("default")))
int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SlateNotesAppDelegate.class));
    }
}
