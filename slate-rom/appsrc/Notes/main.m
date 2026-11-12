#import <UIKit/UIKit.h>

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

#pragma mark - Storage

@interface SlateNoteStore : NSObject
@property (nonatomic, strong) NSMutableArray<SlateNote *> *notes;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, copy) NSString *storageProblem;
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

- (void)load
{
    self.notes = [NSMutableArray array];

    NSURL *base = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [base URLByAppendingPathComponent:@"SlateNotes" isDirectory:YES];
    NSError *error = nil;
    if(directory == nil || ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error])
    {
        self.storageProblem = error.localizedDescription ?: @"No storage folder is available.";
        return;
    }
    self.fileURL = [directory URLByAppendingPathComponent:@"notes.json"];

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
    SlateNoteStore *store = [SlateNoteStore shared];
    NSString *message;
    if(store.storageProblem.length > 0)
    {
        message = [NSString stringWithFormat:@"Notes can't be saved here, so they will be lost when the app closes.\n\n%@", store.storageProblem];
    }
    else
    {
        message = [NSString stringWithFormat:@"Notes are saved in:\n%@", store.fileURL.path];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Storage" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
