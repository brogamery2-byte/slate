#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fnmatch.h>
#include <stdint.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---- Zip core (plain C, no Foundation) ---------------------------------- */

static uint32_t SZCRCTable[256];
static int SZCRCReady = 0;

static void SZCRCInit(void)
{
    for(uint32_t n = 0; n < 256; n++)
    {
        uint32_t c = n;
        for(int k = 0; k < 8; k++)
        {
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        SZCRCTable[n] = c;
    }
    SZCRCReady = 1;
}

static uint32_t SZCRC32(uint32_t crc, const uint8_t *bytes, size_t length)
{
    if(!SZCRCReady)
    {
        SZCRCInit();
    }
    crc = ~crc;
    for(size_t index = 0; index < length; index++)
    {
        crc = SZCRCTable[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

static void SZPut16(uint8_t *out, uint16_t value)
{
    out[0] = (uint8_t)(value & 0xFF);
    out[1] = (uint8_t)(value >> 8);
}

static void SZPut32(uint8_t *out, uint32_t value)
{
    out[0] = (uint8_t)(value & 0xFF);
    out[1] = (uint8_t)((value >> 8) & 0xFF);
    out[2] = (uint8_t)((value >> 16) & 0xFF);
    out[3] = (uint8_t)((value >> 24) & 0xFF);
}

static void SZDosTime(time_t when, uint16_t *dosTime, uint16_t *dosDate)
{
    struct tm parts;
    localtime_r(&when, &parts);
    int year = parts.tm_year + 1900;
    if(year < 1980)
    {
        year = 1980;
        parts.tm_mon = 0;
        parts.tm_mday = 1;
        parts.tm_hour = 0;
        parts.tm_min = 0;
        parts.tm_sec = 0;
    }
    *dosTime = (uint16_t)((parts.tm_hour << 11) | (parts.tm_min << 5) | (parts.tm_sec / 2));
    *dosDate = (uint16_t)(((year - 1980) << 9) | ((parts.tm_mon + 1) << 5) | parts.tm_mday);
}

/* Local file header: 30 bytes, followed by the name, then the data. */
static void SZLocalHeader(uint8_t *out, uint16_t flags, uint16_t method, uint16_t dosTime, uint16_t dosDate,
                          uint32_t crc, uint32_t compressed, uint32_t size, uint16_t nameLength)
{
    SZPut32(out + 0, 0x04034b50u);
    SZPut16(out + 4, 20);
    SZPut16(out + 6, flags);
    SZPut16(out + 8, method);
    SZPut16(out + 10, dosTime);
    SZPut16(out + 12, dosDate);
    SZPut32(out + 14, crc);
    SZPut32(out + 18, compressed);
    SZPut32(out + 22, size);
    SZPut16(out + 26, nameLength);
    SZPut16(out + 28, 0);
}

/* Central directory header: 46 bytes, followed by the name. */
static void SZCentralHeader(uint8_t *out, uint16_t flags, uint16_t method, uint16_t dosTime, uint16_t dosDate,
                            uint32_t crc, uint32_t compressed, uint32_t size, uint16_t nameLength,
                            uint32_t attributes, uint32_t localOffset)
{
    SZPut32(out + 0, 0x02014b50u);
    SZPut16(out + 4, 0x031E);
    SZPut16(out + 6, 20);
    SZPut16(out + 8, flags);
    SZPut16(out + 10, method);
    SZPut16(out + 12, dosTime);
    SZPut16(out + 14, dosDate);
    SZPut32(out + 16, crc);
    SZPut32(out + 20, compressed);
    SZPut32(out + 24, size);
    SZPut16(out + 28, nameLength);
    SZPut16(out + 30, 0);
    SZPut16(out + 32, 0);
    SZPut16(out + 34, 0);
    SZPut16(out + 36, 0);
    SZPut32(out + 38, attributes);
    SZPut32(out + 42, localOffset);
}

/* End of central directory record: 22 bytes. */
static void SZEndRecord(uint8_t *out, uint16_t count, uint32_t directorySize, uint32_t directoryOffset)
{
    SZPut32(out + 0, 0x06054b50u);
    SZPut16(out + 4, 0);
    SZPut16(out + 6, 0);
    SZPut16(out + 8, count);
    SZPut16(out + 10, count);
    SZPut32(out + 12, directorySize);
    SZPut32(out + 16, directoryOffset);
    SZPut16(out + 20, 0);
}

/* ---- Small helpers ------------------------------------------------------- */

static NSString *SZHumanSize(unsigned long long bytes)
{
    NSArray<NSString *> *units = @[ @"B", @"K", @"M", @"G", @"T" ];
    double value = (double)bytes;
    NSUInteger unit = 0;
    while(value >= 1024.0 && unit < units.count - 1)
    {
        value /= 1024.0;
        unit++;
    }
    if(unit == 0)
    {
        return [NSString stringWithFormat:@"%llu%@", bytes, units[0]];
    }
    return [NSString stringWithFormat:@"%.1f%@", value, units[unit]];
}

static NSString *SZModeString(mode_t mode)
{
    char text[11];
    text[0] = S_ISDIR(mode) ? 'd' : (S_ISLNK(mode) ? 'l' : '-');
    const char *letters = "rwxrwxrwx";
    for(int index = 0; index < 9; index++)
    {
        text[index + 1] = (mode & (1 << (8 - index))) ? letters[index] : '-';
    }
    text[10] = 0;
    return [NSString stringWithUTF8String:text];
}

static NSString *SZEscapePath(NSString *name)
{
    NSMutableString *result = [NSMutableString string];
    for(NSUInteger index = 0; index < name.length; index++)
    {
        unichar c = [name characterAtIndex:index];
        if(c == ' ' || c == '\'' || c == '"' || c == '|' || c == '>' || c == '*' || c == '?' || c == '\\' || c == '$')
        {
            [result appendString:@"\\"];
        }
        [result appendFormat:@"%C", c];
    }
    return result;
}

static NSString *SZReadText(NSString *path, NSString **problem)
{
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if(data == nil)
    {
        *problem = @"No such file, or it can't be read";
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(text == nil)
    {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

static BOOL SZLooksBinary(NSData *data)
{
    NSUInteger limit = MIN((NSUInteger)4096, data.length);
    const uint8_t *bytes = data.bytes;
    for(NSUInteger index = 0; index < limit; index++)
    {
        if(bytes[index] == 0)
        {
            return YES;
        }
    }
    return NO;
}

static NSString *SZDateText(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"MMM d HH:mm";
    });
    return date ? [formatter stringFromDate:date] : @"?";
}

/* ---- Zip reading (matches the importer in the ROM) ----------------------- */

@interface SZZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t localOffset;
@property (nonatomic, assign) uint32_t mode;
@end

@implementation SZZipEntry
@end

static uint16_t SZRead16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t SZRead32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static NSArray<SZZipEntry *> *SZZipEntries(NSData *zip, NSString **problem)
{
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    if(length < 22 || SZRead32(bytes) != 0x04034b50)
    {
        if(length >= 22 && SZRead32(bytes) == 0x06054b50)
        {
            return @[];
        }
        *problem = @"not a zip archive";
        return nil;
    }
    NSInteger eocd = -1;
    NSInteger first = (NSInteger)length - 22;
    NSInteger last = MAX(0, first - 65535);
    for(NSInteger index = first; index >= last; index--)
    {
        if(SZRead32(bytes + index) == 0x06054b50)
        {
            eocd = index;
            break;
        }
    }
    if(eocd < 0)
    {
        *problem = @"the zip file is damaged (no table of contents)";
        return nil;
    }
    uint16_t count = SZRead16(bytes + eocd + 10);
    uint32_t directorySize = SZRead32(bytes + eocd + 12);
    uint32_t directoryOffset = SZRead32(bytes + eocd + 16);
    if(count == 0xFFFF || directoryOffset == 0xFFFFFFFF)
    {
        *problem = @"archives larger than 4 GB are not supported";
        return nil;
    }
    if((uint64_t)directoryOffset + directorySize > length)
    {
        *problem = @"the zip file is damaged (table of contents out of range)";
        return nil;
    }
    NSMutableArray<SZZipEntry *> *entries = [NSMutableArray arrayWithCapacity:count];
    NSUInteger offset = directoryOffset;
    for(uint16_t index = 0; index < count; index++)
    {
        if(offset + 46 > length || SZRead32(bytes + offset) != 0x02014b50)
        {
            *problem = @"the zip file is damaged (unreadable entry)";
            return nil;
        }
        uint16_t nameLength = SZRead16(bytes + offset + 28);
        uint16_t extraLength = SZRead16(bytes + offset + 30);
        uint16_t commentLength = SZRead16(bytes + offset + 32);
        if(offset + 46 + nameLength > length)
        {
            *problem = @"the zip file is damaged (name out of range)";
            return nil;
        }
        SZZipEntry *entry = [SZZipEntry new];
        entry.method = SZRead16(bytes + offset + 10);
        entry.compressedSize = SZRead32(bytes + offset + 20);
        entry.size = SZRead32(bytes + offset + 24);
        entry.mode = SZRead32(bytes + offset + 38) >> 16;
        entry.localOffset = SZRead32(bytes + offset + 42);
        entry.name = [[NSString alloc] initWithBytes:bytes + offset + 46 length:nameLength encoding:NSUTF8StringEncoding] ?: @"";
        [entries addObject:entry];
        offset += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
}

static NSData *SZZipData(NSData *zip, SZZipEntry *entry)
{
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    NSUInteger local = entry.localOffset;
    if(local + 30 > length || SZRead32(bytes + local) != 0x04034b50)
    {
        return nil;
    }
    uint16_t nameLength = SZRead16(bytes + local + 26);
    uint16_t extraLength = SZRead16(bytes + local + 28);
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

/* ---- Shell: interfaces ----------------------------------------------------- */

@class SlateShell;
@class SlateContext;
typedef int (*SlateCommandFunction)(SlateContext *ctx);

@interface SlateOptions : NSObject
@property (nonatomic, strong) NSMutableSet<NSString *> *flags;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@end

@implementation SlateOptions
@end

@interface SlateContext : NSObject
@property (nonatomic, weak) SlateShell *shell;
@property (nonatomic, copy) NSArray<NSString *> *args;
@property (nonatomic, copy) NSString *input;
@property (nonatomic, strong) NSMutableString *output;
@property (nonatomic, assign) BOOL live;
- (void)print:(NSString *)text;
- (void)println:(NSString *)text;
- (void)fail:(NSString *)text;
- (BOOL)cancelled;
- (SlateOptions *)options:(NSString *)valueFlags;
@end

@interface SlateShell : NSObject
@property (nonatomic, copy) NSString *home;
@property (nonatomic, copy) NSString *cwd;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *environment;
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@property (nonatomic, assign) BOOL cancelRequested;
@property (nonatomic, assign) BOOL clearRequested;
@property (nonatomic, assign) int lastStatus;
@property (nonatomic, copy) void (^write)(NSString *text, BOOL isError);
@property (nonatomic, strong) NSDictionary<NSString *, NSValue *> *commands;
- (instancetype)init;
- (void)runLine:(NSString *)line;
- (NSString *)resolve:(NSString *)path;
- (NSString *)display:(NSString *)absolute;
- (NSString *)prompt;
- (NSArray<NSString *> *)commandNames;
- (NSDictionary *)complete:(NSString *)line;
@end

/* ---- Shell: parsing a command line ----------------------------------------- */

@interface SlateParser : NSObject
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *stages;
@property (nonatomic, strong) NSMutableArray<NSString *> *args;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *quotedFlags;
@property (nonatomic, copy) NSString *redirect;
@property (nonatomic, assign) BOOL append;
@property (nonatomic, assign) BOOL redirectPending;
@property (nonatomic, strong) NSMutableString *token;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL quoted;
@property (nonatomic, assign) BOOL noExpand;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, assign) int status;
+ (NSArray<NSDictionary *> *)parse:(NSString *)line environment:(NSDictionary<NSString *, NSString *> *)environment status:(int)status problem:(NSString **)problem;
@end

@implementation SlateParser

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _stages = [NSMutableArray array];
        _args = [NSMutableArray array];
        _quotedFlags = [NSMutableArray array];
        _token = [NSMutableString string];
    }
    return self;
}

- (NSString *)expand:(NSString *)text
{
    if([text rangeOfString:@"$"].location == NSNotFound)
    {
        return text;
    }
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"\\$(\\?|[A-Za-z_][A-Za-z0-9_]*)" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSMutableString *result = [text mutableCopy];
    for(NSTextCheckingResult *match in [matches reverseObjectEnumerator])
    {
        NSString *name = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *value = [name isEqualToString:@"?"] ? [NSString stringWithFormat:@"%d", self.status] : (self.environment[name] ?: @"");
        [result replaceCharactersInRange:match.range withString:value];
    }
    return result;
}

- (void)finishToken
{
    if(!self.started)
    {
        return;
    }
    NSString *text = self.noExpand ? [self.token copy] : [self expand:self.token];
    if(self.redirectPending)
    {
        self.redirect = text;
        self.redirectPending = NO;
    }
    else
    {
        [self.args addObject:text];
        [self.quotedFlags addObject:@(self.quoted)];
    }
    self.token = [NSMutableString string];
    self.started = NO;
    self.quoted = NO;
    self.noExpand = NO;
}

- (void)finishStage
{
    [self.stages addObject:@{
        @"args": [self.args copy],
        @"quoted": [self.quotedFlags copy],
        @"redirect": self.redirect ?: (id)NSNull.null,
        @"append": @(self.append),
    }];
    self.args = [NSMutableArray array];
    self.quotedFlags = [NSMutableArray array];
    self.redirect = nil;
    self.append = NO;
}

+ (NSArray<NSDictionary *> *)parse:(NSString *)line environment:(NSDictionary<NSString *, NSString *> *)environment status:(int)status problem:(NSString **)problem
{
    SlateParser *parser = [SlateParser new];
    parser.environment = environment;
    parser.status = status;

    unichar quote = 0;
    NSUInteger length = line.length;
    for(NSUInteger index = 0; index < length; index++)
    {
        unichar c = [line characterAtIndex:index];
        if(quote != 0)
        {
            if(c == quote)
            {
                quote = 0;
                continue;
            }
            if(quote == '"' && c == '\\' && index + 1 < length)
            {
                unichar next = [line characterAtIndex:index + 1];
                if(next == '"' || next == '\\' || next == '$')
                {
                    [parser.token appendFormat:@"%C", next];
                    index++;
                    continue;
                }
            }
            [parser.token appendFormat:@"%C", c];
            continue;
        }
        if(c == '\'' || c == '"')
        {
            quote = c;
            parser.started = YES;
            parser.quoted = YES;
            if(c == '\'')
            {
                parser.noExpand = YES;
            }
            continue;
        }
        if(c == '\\' && index + 1 < length)
        {
            [parser.token appendFormat:@"%C", [line characterAtIndex:index + 1]];
            parser.started = YES;
            index++;
            continue;
        }
        if(c == ' ' || c == '\t')
        {
            [parser finishToken];
            continue;
        }
        if(c == '|')
        {
            [parser finishToken];
            if(parser.redirectPending)
            {
                *problem = @"Missing file name after >.";
                return nil;
            }
            [parser finishStage];
            continue;
        }
        if(c == '>')
        {
            [parser finishToken];
            if(index + 1 < length && [line characterAtIndex:index + 1] == '>')
            {
                parser.append = YES;
                index++;
            }
            else
            {
                parser.append = NO;
            }
            parser.redirectPending = YES;
            continue;
        }
        [parser.token appendFormat:@"%C", c];
        parser.started = YES;
    }
    if(quote != 0)
    {
        *problem = @"A quote was not closed.";
        return nil;
    }
    [parser finishToken];
    if(parser.redirectPending)
    {
        *problem = @"Missing file name after >.";
        return nil;
    }
    [parser finishStage];
    return parser.stages;
}

@end

/* ---- Shell: the context a command runs in ---------------------------------- */

@implementation SlateContext

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _output = [NSMutableString string];
    }
    return self;
}

- (void)print:(NSString *)text
{
    if(text.length == 0)
    {
        return;
    }
    if(self.live && self.shell.write != nil)
    {
        self.shell.write(text, NO);
    }
    else
    {
        [self.output appendString:text];
    }
}

- (void)println:(NSString *)text
{
    [self print:[text stringByAppendingString:@"\n"]];
}

- (void)fail:(NSString *)text
{
    if(self.shell.write != nil)
    {
        self.shell.write([text stringByAppendingString:@"\n"], YES);
    }
}

- (BOOL)cancelled
{
    return self.shell.cancelRequested;
}

- (SlateOptions *)options:(NSString *)valueFlags
{
    SlateOptions *options = [SlateOptions new];
    options.flags = [NSMutableSet set];
    options.values = [NSMutableDictionary dictionary];
    options.paths = [NSMutableArray array];

    NSArray<NSString *> *args = self.args;
    for(NSUInteger index = 1; index < args.count; index++)
    {
        NSString *arg = args[index];
        if([arg isEqualToString:@"--"])
        {
            for(NSUInteger rest = index + 1; rest < args.count; rest++)
            {
                [options.paths addObject:args[rest]];
            }
            break;
        }
        if([arg hasPrefix:@"--"] && arg.length > 2)
        {
            [options.flags addObject:[arg substringFromIndex:2]];
            continue;
        }
        if([arg hasPrefix:@"-"] && arg.length > 1)
        {
            for(NSUInteger k = 1; k < arg.length; k++)
            {
                NSString *flag = [arg substringWithRange:NSMakeRange(k, 1)];
                if([valueFlags containsString:flag])
                {
                    NSString *value = @"";
                    if(k + 1 < arg.length)
                    {
                        value = [arg substringFromIndex:k + 1];
                    }
                    else if(index + 1 < args.count)
                    {
                        index++;
                        value = args[index];
                    }
                    options.values[flag] = value;
                    break;
                }
                [options.flags addObject:flag];
            }
            continue;
        }
        [options.paths addObject:arg];
    }
    return options;
}

@end

/* ---- Commands: helpers ------------------------------------------------------ */

static NSString *SZPad(NSString *text, NSUInteger width, BOOL padLeft)
{
    if(text.length >= width)
    {
        return text;
    }
    NSString *spaces = [@"" stringByPaddingToLength:width - text.length withString:@" " startingAtIndex:0];
    return padLeft ? [spaces stringByAppendingString:text] : [text stringByAppendingString:spaces];
}

static BOOL SZIsDirectory(NSString *path)
{
    BOOL isDirectory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

static BOOL SZExists(NSString *path)
{
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] != nil;
}

static NSString *SZErrorText(NSError *error)
{
    return error.localizedDescription ?: @"failed";
}

static mode_t SZModeOf(NSDictionary *attributes)
{
    NSString *type = attributes.fileType;
    mode_t mode = (mode_t)(attributes.filePosixPermissions & 07777);
    if([type isEqualToString:NSFileTypeDirectory])
    {
        mode |= S_IFDIR;
    }
    else if([type isEqualToString:NSFileTypeSymbolicLink])
    {
        mode |= S_IFLNK;
    }
    else
    {
        mode |= S_IFREG;
    }
    return mode;
}

static NSArray<NSString *> *SZLines(NSString *text)
{
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if(lines.count > 0 && lines.lastObject.length == 0)
    {
        [lines removeLastObject];
    }
    return lines;
}

static NSString *SZHex(const uint8_t *bytes, size_t length)
{
    NSMutableString *text = [NSMutableString stringWithCapacity:length * 2];
    for(size_t index = 0; index < length; index++)
    {
        [text appendFormat:@"%02x", bytes[index]];
    }
    return text;
}

/* Text for a file, or nil with an error message already printed. */
static NSString *SZContextText(SlateContext *ctx, NSString *name, NSString *command)
{
    NSString *absolute = [ctx.shell resolve:name];
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:absolute options:NSDataReadingMappedIfSafe error:&error];
    if(data == nil)
    {
        [ctx fail:[NSString stringWithFormat:@"%@: %@: %@", command, name, SZErrorText(error)]];
        return nil;
    }
    if(SZLooksBinary(data))
    {
        [ctx fail:[NSString stringWithFormat:@"%@: %@: binary file (try hexdump)", command, name]];
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(text == nil)
    {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

/* ---- Commands: the toolbox list and usage text ------------------------------ */

static NSArray<NSDictionary *> *SZToolboxItems(void)
{
    return @[
        @{ @"name": @"zip", @"summary": @"Pack files and folders into a zip archive", @"usage": @"zip archive.zip file-or-folder ...", @"template": @"zip archive.zip " },
        @{ @"name": @"unzip", @"summary": @"Unpack a zip archive, or list what is inside", @"usage": @"unzip [-l] [-o] archive.zip [-d folder]", @"template": @"unzip " },
        @{ @"name": @"search", @"summary": @"Find files by name (wildcards work)", @"usage": @"search [-s] [-n max] pattern [folder]", @"template": @"search \"*.txt\" ." },
        @{ @"name": @"search -t", @"summary": @"Search for text inside files", @"usage": @"search -t \"text\" [-s] [folder]", @"template": @"search -t \"text\" ." },
        @{ @"name": @"hash", @"summary": @"Checksum of a file (md5, sha1 or sha256)", @"usage": @"hash [-a md5|sha1|sha256] file ...", @"template": @"hash " },
        @{ @"name": @"base64", @"summary": @"Encode or decode base64", @"usage": @"base64 [-d] file [-o out]   or   base64 -s \"text\"", @"template": @"base64 " },
        @{ @"name": @"hexdump", @"summary": @"Show the bytes of a file", @"usage": @"hexdump [-n bytes] file", @"template": @"hexdump " },
        @{ @"name": @"rename", @"summary": @"Rename many files by replacing part of the name", @"usage": @"rename [-n] find replace file ...", @"template": @"rename " },
        @{ @"name": @"tree", @"summary": @"Show a folder as a tree", @"usage": @"tree [-a] [-L depth] [folder]", @"template": @"tree " },
        @{ @"name": @"du", @"summary": @"How much space files and folders use", @"usage": @"du [-h] [-s] [path ...]", @"template": @"du -h " },
    ];
}

static NSDictionary<NSString *, NSString *> *SZUsageTable(void)
{
    return @{
        @"help": @"help [command]        show commands, or how to use one",
        @"clear": @"clear                  clear the screen",
        @"pwd": @"pwd                    show the current folder",
        @"cd": @"cd [folder]            change folder (cd alone goes home, cd - goes back)",
        @"ls": @"ls [-l] [-a] [-h] [path ...]   list files",
        @"tree": @"tree [-a] [-L depth] [folder]   show a folder as a tree",
        @"cat": @"cat file ...           print files",
        @"head": @"head [-n lines] [file ...]   first lines (default 10)",
        @"tail": @"tail [-n lines] [file ...]   last lines (default 10)",
        @"touch": @"touch file ...         create files or update their time",
        @"mkdir": @"mkdir [-p] folder ...  make folders",
        @"rm": @"rm [-r] [-f] path ...   delete files (careful, there is no undo)",
        @"cp": @"cp [-r] source ... destination   copy",
        @"mv": @"mv source ... destination   move or rename",
        @"stat": @"stat path ...          details about files",
        @"du": @"du [-h] [-s] [path ...]   space used",
        @"chmod": @"chmod 755 file ...    change permissions (octal)",
        @"echo": @"echo [-n] text ...     print text",
        @"env": @"env                    show variables",
        @"export": @"export NAME=value     set a variable",
        @"whoami": @"whoami                 show the user",
        @"id": @"id                     show user and group numbers",
        @"uname": @"uname                  show system name",
        @"date": @"date                   show the date and time",
        @"history": @"history                show earlier commands",
        @"wc": @"wc [-l] [-w] [-c] [file ...]   count lines, words, bytes",
        @"grep": @"grep [-i] [-n] [-v] [-r] [-c] pattern [file ...]   find lines",
        @"sort": @"sort [-r] [-n] [-u] [file ...]   sort lines",
        @"uniq": @"uniq [-c] [file ...]   remove repeated lines next to each other",
        @"base64": @"base64 [-d] file [-o out]   or   base64 -s \"text\"",
        @"hash": @"hash [-a md5|sha1|sha256] file ...   checksum",
        @"hexdump": @"hexdump [-n bytes] file   show bytes",
        @"rename": @"rename [-n] find replace file ...   batch rename",
        @"search": @"search [-s] [-n max] pattern [folder]    find files by name\nsearch -t \"text\" [-s] [folder]          search inside files",
        @"zip": @"zip archive.zip file-or-folder ...   make a zip archive",
        @"unzip": @"unzip [-l] [-o] archive.zip [-d folder]   extract or list",
        @"toolbox": @"toolbox [tool ...]      show the toolbox, or run a tool from it",
    };
}

/* ---- Commands: shell and files ---------------------------------------------- */

static int SZCmdHelp(SlateContext *ctx)
{
    NSDictionary<NSString *, NSString *> *usage = SZUsageTable();
    if(ctx.args.count > 1)
    {
        NSString *text = usage[ctx.args[1]];
        if(text == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"help: no help for '%@'", ctx.args[1]]];
            return 1;
        }
        [ctx println:text];
        return 0;
    }
    [ctx println:@"Slate Terminal. Commands run inside this app (it is not a full Unix shell)."];
    [ctx println:@""];
    [ctx println:@"Files:    ls cd pwd tree cat head tail touch mkdir rm cp mv stat du chmod"];
    [ctx println:@"Text:     echo grep wc sort uniq"];
    [ctx println:@"Toolbox:  toolbox zip unzip search hash base64 hexdump rename"];
    [ctx println:@"Shell:    help clear env export history whoami id uname date"];
    [ctx println:@""];
    [ctx println:@"Try: help ls, toolbox, or search \"*.txt\""];
    [ctx println:@"You can chain commands with | and save output with > or >>."];
    [ctx println:@"Tap Tab to complete names, and the arrows for earlier commands."];
    return 0;
}

static int SZCmdClear(SlateContext *ctx)
{
    ctx.shell.clearRequested = YES;
    return 0;
}

static int SZCmdPwd(SlateContext *ctx)
{
    [ctx println:ctx.shell.cwd];
    return 0;
}

static int SZCmdCd(SlateContext *ctx)
{
    NSString *target = ctx.args.count > 1 ? ctx.args[1] : ctx.shell.home;
    if([target isEqualToString:@"-"])
    {
        target = ctx.shell.environment[@"OLDPWD"] ?: ctx.shell.cwd;
    }
    NSString *absolute = [ctx.shell resolve:target];
    if(!SZIsDirectory(absolute))
    {
        [ctx fail:[NSString stringWithFormat:@"cd: %@: %@", target, SZExists(absolute) ? @"Not a folder" : @"No such file or folder"]];
        return 1;
    }
    NSError *error = nil;
    if([NSFileManager.defaultManager contentsOfDirectoryAtPath:absolute error:&error] == nil)
    {
        [ctx fail:[NSString stringWithFormat:@"cd: %@: %@", target, SZErrorText(error)]];
        return 1;
    }
    ctx.shell.environment[@"OLDPWD"] = ctx.shell.cwd;
    ctx.shell.cwd = absolute;
    ctx.shell.environment[@"PWD"] = absolute;
    return 0;
}

static void SZListEntry(SlateContext *ctx, NSString *absolute, NSString *name, BOOL longFormat, BOOL human)
{
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:nil];
    BOOL isDirectory = [attributes.fileType isEqualToString:NSFileTypeDirectory];
    NSString *label = isDirectory ? [name stringByAppendingString:@"/"] : name;
    if(!longFormat)
    {
        [ctx print:[label stringByAppendingString:@"  "]];
        return;
    }
    unsigned long long size = attributes.fileSize;
    NSString *sizeText = human ? SZHumanSize(size) : [NSString stringWithFormat:@"%llu", size];
    NSString *owner = [NSString stringWithFormat:@"%@", attributes.fileOwnerAccountID ?: @"?"];
    [ctx println:[NSString stringWithFormat:@"%@ %@ %@ %@ %@",
                  SZModeString(SZModeOf(attributes)),
                  SZPad(owner, 4, YES),
                  SZPad(sizeText, 8, YES),
                  SZDateText(attributes.fileModificationDate),
                  label]];
}

static int SZCmdLs(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL all = [options.flags containsObject:@"a"];
    BOOL longFormat = [options.flags containsObject:@"l"];
    BOOL human = [options.flags containsObject:@"h"];
    NSArray<NSString *> *targets = options.paths.count > 0 ? options.paths : @[ @"." ];
    NSFileManager *manager = NSFileManager.defaultManager;
    int status = 0;

    for(NSString *target in targets)
    {
        NSString *absolute = [ctx.shell resolve:target];
        BOOL isDirectory = NO;
        if(![manager fileExistsAtPath:absolute isDirectory:&isDirectory] && !SZExists(absolute))
        {
            [ctx fail:[NSString stringWithFormat:@"ls: cannot access '%@': No such file or folder", target]];
            status = 1;
            continue;
        }
        if(targets.count > 1 && isDirectory)
        {
            [ctx println:[NSString stringWithFormat:@"%@:", target]];
        }
        if(!isDirectory)
        {
            SZListEntry(ctx, absolute, absolute.lastPathComponent, longFormat, human);
            if(!longFormat)
            {
                [ctx print:@"\n"];
            }
            continue;
        }
        NSError *error = nil;
        NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:absolute error:&error];
        if(names == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"ls: cannot open '%@': %@", target, SZErrorText(error)]];
            status = 1;
            continue;
        }
        names = [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for(NSString *name in names)
        {
            if([ctx cancelled])
            {
                break;
            }
            if(!all && [name hasPrefix:@"."])
            {
                continue;
            }
            SZListEntry(ctx, [absolute stringByAppendingPathComponent:name], name, longFormat, human);
        }
        if(!longFormat)
        {
            [ctx print:@"\n"];
        }
    }
    return status;
}

static void SZTree(SlateContext *ctx, NSString *directory, NSString *prefix, NSInteger depth, NSInteger maxDepth, NSUInteger *count, BOOL all)
{
    if(depth >= maxDepth || [ctx cancelled] || *count >= 500)
    {
        return;
    }
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    names = [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for(NSString *name in names)
    {
        if(all || ![name hasPrefix:@"."])
        {
            [visible addObject:name];
        }
    }
    for(NSUInteger index = 0; index < visible.count; index++)
    {
        if(*count >= 500)
        {
            return;
        }
        NSString *name = visible[index];
        BOOL last = (index == visible.count - 1);
        NSString *child = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = SZIsDirectory(child);
        [ctx println:[NSString stringWithFormat:@"%@%@%@%@", prefix, last ? @"└── " : @"├── ", name, isDirectory ? @"/" : @""]];
        (*count)++;
        if(isDirectory)
        {
            SZTree(ctx, child, [prefix stringByAppendingString:last ? @"    " : @"│   "], depth + 1, maxDepth, count, all);
        }
    }
}

static int SZCmdTree(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"L"];
    NSInteger maxDepth = options.values[@"L"] ? MAX(1, options.values[@"L"].integerValue) : 4;
    NSString *target = options.paths.firstObject ?: @".";
    NSString *absolute = [ctx.shell resolve:target];
    if(!SZIsDirectory(absolute))
    {
        [ctx fail:[NSString stringWithFormat:@"tree: %@: Not a folder", target]];
        return 1;
    }
    [ctx println:[ctx.shell display:absolute]];
    NSUInteger count = 0;
    SZTree(ctx, absolute, @"", 0, maxDepth, &count, [options.flags containsObject:@"a"]);
    if(count >= 500)
    {
        [ctx println:@"... (stopped after 500 entries; use -L to limit the depth)"];
    }
    return 0;
}

static int SZCmdCat(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    if(options.paths.count == 0)
    {
        if(ctx.input != nil)
        {
            [ctx print:ctx.input];
            return 0;
        }
        [ctx fail:@"cat: give a file name"];
        return 1;
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *text = SZContextText(ctx, name, @"cat");
        if(text == nil)
        {
            status = 1;
            continue;
        }
        if(text.length > 2000000)
        {
            text = [[text substringToIndex:2000000] stringByAppendingString:@"\n... (stopped after 2 MB)"];
        }
        [ctx print:text];
        if(![text hasSuffix:@"\n"])
        {
            [ctx print:@"\n"];
        }
    }
    return status;
}

static int SZCmdHeadOrTail(SlateContext *ctx, BOOL tail)
{
    NSString *command = tail ? @"tail" : @"head";
    SlateOptions *options = [ctx options:@"n"];
    NSInteger count = options.values[@"n"] ? MAX(0, options.values[@"n"].integerValue) : 10;
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if(options.paths.count == 0)
    {
        if(ctx.input == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"%@: give a file name", command]];
            return 1;
        }
        [sources addObject:ctx.input];
        [names addObject:@"-"];
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *text = SZContextText(ctx, name, command);
        if(text == nil)
        {
            status = 1;
            continue;
        }
        [sources addObject:text];
        [names addObject:name];
    }
    for(NSUInteger index = 0; index < sources.count; index++)
    {
        NSArray<NSString *> *lines = SZLines(sources[index]);
        NSInteger total = (NSInteger)lines.count;
        NSRange range = tail ? NSMakeRange((NSUInteger)MAX(0, total - count), (NSUInteger)MIN(count, total)) : NSMakeRange(0, (NSUInteger)MIN(count, total));
        if(sources.count > 1)
        {
            [ctx println:[NSString stringWithFormat:@"==> %@ <==", names[index]]];
        }
        for(NSString *line in [lines subarrayWithRange:range])
        {
            [ctx println:line];
        }
    }
    return status;
}

static int SZCmdHead(SlateContext *ctx)
{
    return SZCmdHeadOrTail(ctx, NO);
}

static int SZCmdTail(SlateContext *ctx)
{
    return SZCmdHeadOrTail(ctx, YES);
}

static int SZCmdTouch(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    if(options.paths.count == 0)
    {
        [ctx fail:@"touch: give a file name"];
        return 1;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *absolute = [ctx.shell resolve:name];
        BOOL ok;
        if(SZExists(absolute))
        {
            ok = [manager setAttributes:@{ NSFileModificationDate: [NSDate date] } ofItemAtPath:absolute error:nil];
        }
        else
        {
            ok = [manager createFileAtPath:absolute contents:[NSData data] attributes:nil];
        }
        if(!ok)
        {
            [ctx fail:[NSString stringWithFormat:@"touch: cannot touch '%@'", name]];
            status = 1;
        }
    }
    return status;
}

static int SZCmdMkdir(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL parents = [options.flags containsObject:@"p"];
    if(options.paths.count == 0)
    {
        [ctx fail:@"mkdir: give a folder name"];
        return 1;
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSError *error = nil;
        if(![NSFileManager.defaultManager createDirectoryAtPath:[ctx.shell resolve:name] withIntermediateDirectories:parents attributes:nil error:&error])
        {
            [ctx fail:[NSString stringWithFormat:@"mkdir: cannot create '%@': %@", name, SZErrorText(error)]];
            status = 1;
        }
    }
    return status;
}

static int SZCmdRm(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL recursive = [options.flags containsObject:@"r"] || [options.flags containsObject:@"R"];
    BOOL force = [options.flags containsObject:@"f"];
    if(options.paths.count == 0)
    {
        [ctx fail:@"rm: give a file name"];
        return 1;
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *absolute = [ctx.shell resolve:name];
        if([absolute isEqualToString:@"/"] || [absolute isEqualToString:ctx.shell.home])
        {
            [ctx fail:[NSString stringWithFormat:@"rm: refusing to delete '%@'", name]];
            status = 1;
            continue;
        }
        if(!SZExists(absolute))
        {
            if(!force)
            {
                [ctx fail:[NSString stringWithFormat:@"rm: cannot remove '%@': No such file or folder", name]];
                status = 1;
            }
            continue;
        }
        if(SZIsDirectory(absolute) && !recursive)
        {
            [ctx fail:[NSString stringWithFormat:@"rm: '%@' is a folder (use -r)", name]];
            status = 1;
            continue;
        }
        NSError *error = nil;
        if(![NSFileManager.defaultManager removeItemAtPath:absolute error:&error])
        {
            [ctx fail:[NSString stringWithFormat:@"rm: cannot remove '%@': %@", name, SZErrorText(error)]];
            status = 1;
        }
    }
    return status;
}

static int SZCopyOrMove(SlateContext *ctx, BOOL move)
{
    NSString *command = move ? @"mv" : @"cp";
    SlateOptions *options = [ctx options:@""];
    BOOL recursive = [options.flags containsObject:@"r"] || [options.flags containsObject:@"R"];
    if(options.paths.count < 2)
    {
        [ctx fail:[NSString stringWithFormat:@"%@: give a source and a destination", command]];
        return 1;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *destination = [ctx.shell resolve:options.paths.lastObject];
    BOOL destinationIsFolder = SZIsDirectory(destination);
    NSArray<NSString *> *sources = [options.paths subarrayWithRange:NSMakeRange(0, options.paths.count - 1)];
    if(sources.count > 1 && !destinationIsFolder)
    {
        [ctx fail:[NSString stringWithFormat:@"%@: '%@' is not a folder", command, options.paths.lastObject]];
        return 1;
    }
    int status = 0;
    for(NSString *name in sources)
    {
        NSString *source = [ctx.shell resolve:name];
        if(!SZExists(source))
        {
            [ctx fail:[NSString stringWithFormat:@"%@: cannot find '%@'", command, name]];
            status = 1;
            continue;
        }
        BOOL sourceIsFolder = SZIsDirectory(source);
        if(sourceIsFolder && !move && !recursive)
        {
            [ctx fail:[NSString stringWithFormat:@"cp: '%@' is a folder (use -r)", name]];
            status = 1;
            continue;
        }
        NSString *target = destinationIsFolder ? [destination stringByAppendingPathComponent:source.lastPathComponent] : destination;
        if([target isEqualToString:source])
        {
            [ctx fail:[NSString stringWithFormat:@"%@: '%@' and the destination are the same", command, name]];
            status = 1;
            continue;
        }
        if(SZExists(target))
        {
            if(SZIsDirectory(target))
            {
                [ctx fail:[NSString stringWithFormat:@"%@: '%@' already exists as a folder", command, target.lastPathComponent]];
                status = 1;
                continue;
            }
            [manager removeItemAtPath:target error:nil];
        }
        NSError *error = nil;
        BOOL ok = move ? [manager moveItemAtPath:source toPath:target error:&error] : [manager copyItemAtPath:source toPath:target error:&error];
        if(!ok)
        {
            [ctx fail:[NSString stringWithFormat:@"%@: cannot %@ '%@': %@", command, move ? @"move" : @"copy", name, SZErrorText(error)]];
            status = 1;
        }
    }
    return status;
}

static int SZCmdCp(SlateContext *ctx)
{
    return SZCopyOrMove(ctx, NO);
}

static int SZCmdMv(SlateContext *ctx)
{
    return SZCopyOrMove(ctx, YES);
}

static int SZCmdStat(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    if(options.paths.count == 0)
    {
        [ctx fail:@"stat: give a file name"];
        return 1;
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *absolute = [ctx.shell resolve:name];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:nil];
        if(attributes == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"stat: cannot stat '%@': No such file or folder", name]];
            status = 1;
            continue;
        }
        [ctx println:[NSString stringWithFormat:@"  File: %@", [ctx.shell display:absolute]]];
        [ctx println:[NSString stringWithFormat:@"  Type: %@", attributes.fileType]];
        [ctx println:[NSString stringWithFormat:@"  Size: %llu bytes (%@)", attributes.fileSize, SZHumanSize(attributes.fileSize)]];
        [ctx println:[NSString stringWithFormat:@"  Mode: %@ (%o)", SZModeString(SZModeOf(attributes)), (unsigned)(attributes.filePosixPermissions & 07777)]];
        [ctx println:[NSString stringWithFormat:@"  Owner: %@:%@", attributes.fileOwnerAccountID ?: @"?", attributes.fileGroupOwnerAccountID ?: @"?"]];
        [ctx println:[NSString stringWithFormat:@"  Modified: %@", attributes.fileModificationDate ?: @"?"]];
    }
    return status;
}

static unsigned long long SZTreeSize(SlateContext *ctx, NSString *path)
{
    unsigned long long total = 0;
    NSDirectoryEnumerator<NSString *> *enumerator = [NSFileManager.defaultManager enumeratorAtPath:path];
    for(NSString *sub in enumerator)
    {
        if([ctx cancelled])
        {
            break;
        }
        NSDictionary *attributes = enumerator.fileAttributes;
        if([attributes.fileType isEqualToString:NSFileTypeRegular])
        {
            total += attributes.fileSize;
        }
        (void)sub;
    }
    return total;
}

static int SZCmdDu(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL human = [options.flags containsObject:@"h"];
    BOOL summary = [options.flags containsObject:@"s"];
    NSArray<NSString *> *targets = options.paths.count > 0 ? options.paths : @[ @"." ];
    int status = 0;
    for(NSString *name in targets)
    {
        NSString *absolute = [ctx.shell resolve:name];
        if(!SZExists(absolute))
        {
            [ctx fail:[NSString stringWithFormat:@"du: cannot access '%@': No such file or folder", name]];
            status = 1;
            continue;
        }
        unsigned long long total = 0;
        if(SZIsDirectory(absolute))
        {
            if(!summary)
            {
                NSArray<NSString *> *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:absolute error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                for(NSString *child in names)
                {
                    if([ctx cancelled])
                    {
                        return 130;
                    }
                    NSString *childPath = [absolute stringByAppendingPathComponent:child];
                    unsigned long long size = SZIsDirectory(childPath) ? SZTreeSize(ctx, childPath) : [[NSFileManager.defaultManager attributesOfItemAtPath:childPath error:nil] fileSize];
                    total += size;
                    [ctx println:[NSString stringWithFormat:@"%@  %@", SZPad(human ? SZHumanSize(size) : [NSString stringWithFormat:@"%llu", size], 8, YES), child]];
                }
            }
            else
            {
                total = SZTreeSize(ctx, absolute);
            }
        }
        else
        {
            total = [[NSFileManager.defaultManager attributesOfItemAtPath:absolute error:nil] fileSize];
        }
        [ctx println:[NSString stringWithFormat:@"%@  %@ (total)", SZPad(human ? SZHumanSize(total) : [NSString stringWithFormat:@"%llu", total], 8, YES), name]];
    }
    return status;
}

static int SZCmdChmod(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    if(options.paths.count < 2)
    {
        [ctx fail:@"chmod: use chmod 755 file"];
        return 1;
    }
    NSString *modeText = options.paths[0];
    char *end = NULL;
    long mode = strtol(modeText.UTF8String, &end, 8);
    if(end == NULL || *end != '\0' || modeText.length == 0 || mode < 0 || mode > 07777)
    {
        [ctx fail:[NSString stringWithFormat:@"chmod: '%@' is not an octal mode like 755", modeText]];
        return 1;
    }
    int status = 0;
    for(NSUInteger index = 1; index < options.paths.count; index++)
    {
        NSError *error = nil;
        NSString *name = options.paths[index];
        if(![NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @(mode) } ofItemAtPath:[ctx.shell resolve:name] error:&error])
        {
            [ctx fail:[NSString stringWithFormat:@"chmod: cannot change '%@': %@", name, SZErrorText(error)]];
            status = 1;
        }
    }
    return status;
}

static int SZCmdEcho(SlateContext *ctx)
{
    NSMutableArray<NSString *> *words = [[ctx.args subarrayWithRange:NSMakeRange(1, ctx.args.count - 1)] mutableCopy];
    BOOL newline = YES;
    if(words.count > 0 && [words[0] isEqualToString:@"-n"])
    {
        newline = NO;
        [words removeObjectAtIndex:0];
    }
    NSString *text = [words componentsJoinedByString:@" "];
    [ctx print:newline ? [text stringByAppendingString:@"\n"] : text];
    return 0;
}

static int SZCmdEnv(SlateContext *ctx)
{
    NSArray<NSString *> *keys = [ctx.shell.environment.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *key in keys)
    {
        [ctx println:[NSString stringWithFormat:@"%@=%@", key, ctx.shell.environment[key]]];
    }
    return 0;
}

static int SZCmdExport(SlateContext *ctx)
{
    if(ctx.args.count < 2)
    {
        return SZCmdEnv(ctx);
    }
    for(NSUInteger index = 1; index < ctx.args.count; index++)
    {
        NSString *assignment = ctx.args[index];
        NSRange equals = [assignment rangeOfString:@"="];
        if(equals.location == NSNotFound || equals.location == 0)
        {
            [ctx fail:[NSString stringWithFormat:@"export: use NAME=value (got '%@')", assignment]];
            return 1;
        }
        ctx.shell.environment[[assignment substringToIndex:equals.location]] = [assignment substringFromIndex:equals.location + 1];
    }
    return 0;
}

static int SZCmdWhoami(SlateContext *ctx)
{
    [ctx println:getuid() == 501 ? @"mobile" : [NSString stringWithFormat:@"uid %d", (int)getuid()]];
    return 0;
}

static int SZCmdId(SlateContext *ctx)
{
    [ctx println:[NSString stringWithFormat:@"uid=%d gid=%d", (int)getuid(), (int)getgid()]];
    return 0;
}

static int SZCmdUname(SlateContext *ctx)
{
    [ctx println:@"Slate (Nyxian ROM)"];
    return 0;
}

static int SZCmdDate(SlateContext *ctx)
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"EEE MMM d HH:mm:ss zzz yyyy";
    [ctx println:[formatter stringFromDate:[NSDate date]]];
    return 0;
}

static int SZCmdHistory(SlateContext *ctx)
{
    NSArray<NSString *> *history = [ctx.shell.history copy];
    for(NSUInteger index = 0; index < history.count; index++)
    {
        [ctx println:[NSString stringWithFormat:@"%@  %@", SZPad([NSString stringWithFormat:@"%lu", (unsigned long)index + 1], 4, YES), history[index]]];
    }
    return 0;
}

/* ---- Commands: text tools ---------------------------------------------------- */

static NSString *SZQuietText(NSString *absolute)
{
    NSData *data = [NSData dataWithContentsOfFile:absolute options:NSDataReadingMappedIfSafe error:nil];
    if(data == nil || data.length > 5u * 1024u * 1024u || SZLooksBinary(data))
    {
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(text == nil)
    {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text;
}

/* Collects text from the file arguments, or from piped input. Returns nil if nothing could be read. */
static NSArray<NSDictionary *> *SZSources(SlateContext *ctx, NSArray<NSString *> *paths, NSString *command)
{
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    if(paths.count == 0)
    {
        if(ctx.input == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"%@: give a file name or pipe text into it", command]];
            return nil;
        }
        [sources addObject:@{ @"name": @"-", @"text": ctx.input }];
        return sources;
    }
    for(NSString *name in paths)
    {
        NSString *text = SZContextText(ctx, name, command);
        if(text != nil)
        {
            [sources addObject:@{ @"name": name, @"text": text }];
        }
    }
    return sources.count > 0 ? sources : nil;
}

static int SZCmdWc(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL wantLines = [options.flags containsObject:@"l"];
    BOOL wantWords = [options.flags containsObject:@"w"];
    BOOL wantBytes = [options.flags containsObject:@"c"];
    if(!wantLines && !wantWords && !wantBytes)
    {
        wantLines = wantWords = wantBytes = YES;
    }
    NSArray<NSDictionary *> *sources = SZSources(ctx, options.paths, @"wc");
    if(sources == nil)
    {
        return 1;
    }
    for(NSDictionary *source in sources)
    {
        NSString *text = source[@"text"];
        NSUInteger lines = [text componentsSeparatedByString:@"\n"].count - 1;
        NSUInteger words = 0;
        for(NSString *part in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        {
            if(part.length > 0)
            {
                words++;
            }
        }
        NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableArray<NSString *> *columns = [NSMutableArray array];
        if(wantLines)
        {
            [columns addObject:SZPad([NSString stringWithFormat:@"%lu", (unsigned long)lines], 7, YES)];
        }
        if(wantWords)
        {
            [columns addObject:SZPad([NSString stringWithFormat:@"%lu", (unsigned long)words], 7, YES)];
        }
        if(wantBytes)
        {
            [columns addObject:SZPad([NSString stringWithFormat:@"%lu", (unsigned long)bytes], 7, YES)];
        }
        if(![source[@"name"] isEqualToString:@"-"])
        {
            [columns addObject:source[@"name"]];
        }
        [ctx println:[columns componentsJoinedByString:@" "]];
    }
    return 0;
}

static NSRegularExpression *SZMakeRegex(NSString *pattern, BOOL ignoreCase)
{
    NSRegularExpressionOptions flags = ignoreCase ? NSRegularExpressionCaseInsensitive : 0;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:flags error:nil];
    if(regex == nil)
    {
        regex = [NSRegularExpression regularExpressionWithPattern:[NSRegularExpression escapedPatternForString:pattern] options:flags error:nil];
    }
    return regex;
}

static NSUInteger SZGrepText(SlateContext *ctx, NSString *text, NSRegularExpression *regex, NSString *label, BOOL numbers, BOOL invert, BOOL countOnly)
{
    NSUInteger matches = 0;
    NSUInteger number = 0;
    for(NSString *line in SZLines(text))
    {
        number++;
        if(number % 2000 == 0 && [ctx cancelled])
        {
            break;
        }
        BOOL hit = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
        if(hit == invert)
        {
            continue;
        }
        matches++;
        if(countOnly)
        {
            continue;
        }
        NSMutableString *prefix = [NSMutableString string];
        if(label != nil)
        {
            [prefix appendFormat:@"%@:", label];
        }
        if(numbers)
        {
            [prefix appendFormat:@"%lu:", (unsigned long)number];
        }
        [ctx println:[prefix stringByAppendingString:line]];
    }
    return matches;
}

static int SZCmdGrep(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL ignoreCase = [options.flags containsObject:@"i"];
    BOOL numbers = [options.flags containsObject:@"n"];
    BOOL invert = [options.flags containsObject:@"v"];
    BOOL recursive = [options.flags containsObject:@"r"] || [options.flags containsObject:@"R"];
    BOOL countOnly = [options.flags containsObject:@"c"];
    if(options.paths.count == 0)
    {
        [ctx fail:@"grep: give a pattern. Try: grep -n word file.txt"];
        return 2;
    }
    NSString *pattern = options.paths[0];
    NSMutableArray<NSString *> *files = [[options.paths subarrayWithRange:NSMakeRange(1, options.paths.count - 1)] mutableCopy];
    NSRegularExpression *regex = SZMakeRegex(pattern, ignoreCase);
    if(regex == nil)
    {
        [ctx fail:@"grep: that pattern could not be used"];
        return 2;
    }

    NSUInteger total = 0;
    if(files.count == 0)
    {
        if(ctx.input != nil)
        {
            total = SZGrepText(ctx, ctx.input, regex, nil, numbers, invert, countOnly);
            if(countOnly)
            {
                [ctx println:[NSString stringWithFormat:@"%lu", (unsigned long)total]];
            }
            return total > 0 ? 0 : 1;
        }
        if(!recursive)
        {
            [ctx fail:@"grep: give a file, use -r for the current folder, or pipe text into it"];
            return 2;
        }
        [files addObject:@"."];
    }

    BOOL showNames = files.count > 1 || recursive;
    NSFileManager *manager = NSFileManager.defaultManager;
    for(NSString *name in files)
    {
        NSString *absolute = [ctx.shell resolve:name];
        if(!SZExists(absolute))
        {
            [ctx fail:[NSString stringWithFormat:@"grep: %@: No such file or folder", name]];
            continue;
        }
        if(SZIsDirectory(absolute))
        {
            if(!recursive)
            {
                [ctx fail:[NSString stringWithFormat:@"grep: %@: is a folder (use -r)", name]];
                continue;
            }
            NSDirectoryEnumerator<NSString *> *enumerator = [manager enumeratorAtPath:absolute];
            for(NSString *sub in enumerator)
            {
                if([ctx cancelled])
                {
                    return 130;
                }
                if(![enumerator.fileAttributes.fileType isEqualToString:NSFileTypeRegular])
                {
                    continue;
                }
                NSString *text = SZQuietText([absolute stringByAppendingPathComponent:sub]);
                if(text == nil)
                {
                    continue;
                }
                NSUInteger found = SZGrepText(ctx, text, regex, [name stringByAppendingPathComponent:sub], numbers, invert, countOnly);
                total += found;
                if(countOnly && found > 0)
                {
                    [ctx println:[NSString stringWithFormat:@"%@:%lu", [name stringByAppendingPathComponent:sub], (unsigned long)found]];
                }
            }
            continue;
        }
        NSString *text = SZContextText(ctx, name, @"grep");
        if(text == nil)
        {
            continue;
        }
        NSUInteger found = SZGrepText(ctx, text, regex, showNames ? name : nil, numbers, invert, countOnly);
        total += found;
        if(countOnly)
        {
            [ctx println:showNames ? [NSString stringWithFormat:@"%@:%lu", name, (unsigned long)found] : [NSString stringWithFormat:@"%lu", (unsigned long)found]];
        }
    }
    return total > 0 ? 0 : 1;
}

static int SZCmdSort(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    NSArray<NSDictionary *> *sources = SZSources(ctx, options.paths, @"sort");
    if(sources == nil)
    {
        return 1;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for(NSDictionary *source in sources)
    {
        [lines addObjectsFromArray:SZLines(source[@"text"])];
    }
    BOOL numeric = [options.flags containsObject:@"n"];
    BOOL reverse = [options.flags containsObject:@"r"];
    NSArray<NSString *> *sorted = [lines sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSComparisonResult result;
        if(numeric)
        {
            double x = a.doubleValue;
            double y = b.doubleValue;
            result = x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : [a compare:b]);
        }
        else
        {
            result = [a compare:b];
        }
        return reverse ? (NSComparisonResult)(-result) : result;
    }];
    NSString *previous = nil;
    BOOL unique = [options.flags containsObject:@"u"];
    for(NSString *line in sorted)
    {
        if(unique && previous != nil && [previous isEqualToString:line])
        {
            continue;
        }
        [ctx println:line];
        previous = line;
    }
    return 0;
}

static int SZCmdUniq(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    NSArray<NSDictionary *> *sources = SZSources(ctx, options.paths, @"uniq");
    if(sources == nil)
    {
        return 1;
    }
    BOOL counts = [options.flags containsObject:@"c"];
    NSString *current = nil;
    NSUInteger repeat = 0;
    for(NSDictionary *source in sources)
    {
        for(NSString *line in SZLines(source[@"text"]))
        {
            if(current != nil && [current isEqualToString:line])
            {
                repeat++;
                continue;
            }
            if(current != nil)
            {
                [ctx println:counts ? [NSString stringWithFormat:@"%@ %@", SZPad([NSString stringWithFormat:@"%lu", (unsigned long)repeat], 6, YES), current] : current];
            }
            current = line;
            repeat = 1;
        }
    }
    if(current != nil)
    {
        [ctx println:counts ? [NSString stringWithFormat:@"%@ %@", SZPad([NSString stringWithFormat:@"%lu", (unsigned long)repeat], 6, YES), current] : current];
    }
    return 0;
}

/* ---- Commands: the toolbox ------------------------------------------------------ */

static int SZCmdBase64(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"os"];
    BOOL decode = [options.flags containsObject:@"d"];
    NSString *outName = options.values[@"o"];
    NSData *data = nil;
    if(options.values[@"s"] != nil)
    {
        data = [options.values[@"s"] dataUsingEncoding:NSUTF8StringEncoding];
    }
    else if(options.paths.count > 0)
    {
        NSError *error = nil;
        data = [NSData dataWithContentsOfFile:[ctx.shell resolve:options.paths[0]] options:NSDataReadingMappedIfSafe error:&error];
        if(data == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"base64: %@: %@", options.paths[0], SZErrorText(error)]];
            return 1;
        }
    }
    else if(ctx.input != nil)
    {
        data = [ctx.input dataUsingEncoding:NSUTF8StringEncoding];
    }
    if(data == nil)
    {
        [ctx fail:@"base64: give a file, use -s \"text\", or pipe text into it"];
        return 1;
    }

    if(!decode)
    {
        NSString *encoded = [data base64EncodedStringWithOptions:NSDataBase64Encoding76CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed];
        if(outName != nil)
        {
            NSError *error = nil;
            if(![encoded writeToFile:[ctx.shell resolve:outName] atomically:YES encoding:NSUTF8StringEncoding error:&error])
            {
                [ctx fail:[NSString stringWithFormat:@"base64: cannot write '%@': %@", outName, SZErrorText(error)]];
                return 1;
            }
            [ctx println:[NSString stringWithFormat:@"Wrote %lu characters to %@", (unsigned long)encoded.length, outName]];
            return 0;
        }
        [ctx println:encoded];
        return 0;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if(decoded == nil)
    {
        [ctx fail:@"base64: that is not valid base64"];
        return 1;
    }
    if(outName != nil)
    {
        NSError *error = nil;
        if(![decoded writeToFile:[ctx.shell resolve:outName] options:NSDataWritingAtomic error:&error])
        {
            [ctx fail:[NSString stringWithFormat:@"base64: cannot write '%@': %@", outName, SZErrorText(error)]];
            return 1;
        }
        [ctx println:[NSString stringWithFormat:@"Wrote %lu bytes to %@", (unsigned long)decoded.length, outName]];
        return 0;
    }
    NSString *asText = SZLooksBinary(decoded) ? nil : [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
    if(asText != nil)
    {
        [ctx println:asText];
    }
    else
    {
        [ctx println:[NSString stringWithFormat:@"(binary data, %lu bytes. Use -o file to save it.)", (unsigned long)decoded.length]];
    }
    return 0;
}

static NSString *SZHashFile(NSString *path, NSString *algorithm, SlateContext *ctx, NSString **problem)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if(handle == nil)
    {
        *problem = @"cannot open";
        return nil;
    }
    BOOL isMD5 = [algorithm isEqualToString:@"md5"];
    BOOL isSHA1 = [algorithm isEqualToString:@"sha1"];
    CC_MD5_CTX md5;
    CC_SHA1_CTX sha1;
    CC_SHA256_CTX sha256;
    if(isMD5)
    {
        CC_MD5_Init(&md5);
    }
    else if(isSHA1)
    {
        CC_SHA1_Init(&sha1);
    }
    else
    {
        CC_SHA256_Init(&sha256);
    }
    while(YES)
    {
        NSData *chunk = [handle readDataOfLength:1048576];
        if(chunk.length == 0)
        {
            break;
        }
        if([ctx cancelled])
        {
            [handle closeFile];
            *problem = @"cancelled";
            return nil;
        }
        if(isMD5)
        {
            CC_MD5_Update(&md5, chunk.bytes, (CC_LONG)chunk.length);
        }
        else if(isSHA1)
        {
            CC_SHA1_Update(&sha1, chunk.bytes, (CC_LONG)chunk.length);
        }
        else
        {
            CC_SHA256_Update(&sha256, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    size_t length;
    if(isMD5)
    {
        CC_MD5_Final(digest, &md5);
        length = CC_MD5_DIGEST_LENGTH;
    }
    else if(isSHA1)
    {
        CC_SHA1_Final(digest, &sha1);
        length = CC_SHA1_DIGEST_LENGTH;
    }
    else
    {
        CC_SHA256_Final(digest, &sha256);
        length = CC_SHA256_DIGEST_LENGTH;
    }
    return SZHex(digest, length);
}

static int SZCmdHash(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"a"];
    NSString *algorithm = (options.values[@"a"] ?: @"sha256").lowercaseString;
    if(![@[ @"md5", @"sha1", @"sha256" ] containsObject:algorithm])
    {
        [ctx fail:@"hash: choose md5, sha1 or sha256 with -a"];
        return 1;
    }
    if(options.paths.count == 0)
    {
        [ctx fail:@"hash: give a file name"];
        return 1;
    }
    int status = 0;
    for(NSString *name in options.paths)
    {
        NSString *problem = nil;
        NSString *hash = SZHashFile([ctx.shell resolve:name], algorithm, ctx, &problem);
        if(hash == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"hash: %@: %@", name, problem ?: @"failed"]];
            status = 1;
            continue;
        }
        [ctx println:[NSString stringWithFormat:@"%@  %@", hash, name]];
    }
    return status;
}

static int SZCmdHexdump(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"n"];
    if(options.paths.count == 0)
    {
        [ctx fail:@"hexdump: give a file name"];
        return 1;
    }
    NSUInteger limit = options.values[@"n"] ? (NSUInteger)MAX(1, options.values[@"n"].integerValue) : 256;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:[ctx.shell resolve:options.paths[0]]];
    if(handle == nil)
    {
        [ctx fail:[NSString stringWithFormat:@"hexdump: cannot open '%@'", options.paths[0]]];
        return 1;
    }
    NSData *data = [handle readDataOfLength:limit];
    [handle closeFile];
    const uint8_t *bytes = data.bytes;
    for(NSUInteger offset = 0; offset < data.length; offset += 16)
    {
        NSMutableString *hex = [NSMutableString string];
        NSMutableString *ascii = [NSMutableString string];
        for(NSUInteger column = 0; column < 16; column++)
        {
            if(offset + column < data.length)
            {
                uint8_t byte = bytes[offset + column];
                [hex appendFormat:@"%02x ", byte];
                [ascii appendFormat:@"%c", (byte >= 32 && byte < 127) ? byte : '.'];
            }
            else
            {
                [hex appendString:@"   "];
            }
            if(column == 7)
            {
                [hex appendString:@" "];
            }
        }
        [ctx println:[NSString stringWithFormat:@"%08lx  %@ |%@|", (unsigned long)offset, hex, ascii]];
    }
    return 0;
}

static int SZCmdRename(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    BOOL dryRun = [options.flags containsObject:@"n"];
    if(options.paths.count < 3)
    {
        [ctx fail:@"rename: use rename [-n] find replace file ..."];
        return 1;
    }
    NSString *find = options.paths[0];
    NSString *replacement = options.paths[1];
    if(find.length == 0)
    {
        [ctx fail:@"rename: the text to find can't be empty"];
        return 1;
    }
    int status = 0;
    NSUInteger changed = 0;
    for(NSUInteger index = 2; index < options.paths.count; index++)
    {
        NSString *absolute = [ctx.shell resolve:options.paths[index]];
        NSString *name = absolute.lastPathComponent;
        if([name rangeOfString:find].location == NSNotFound)
        {
            continue;
        }
        NSString *newName = [name stringByReplacingOccurrencesOfString:find withString:replacement];
        NSString *target = [[absolute stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
        if(SZExists(target))
        {
            [ctx fail:[NSString stringWithFormat:@"rename: '%@' already exists, skipping", newName]];
            status = 1;
            continue;
        }
        if(dryRun)
        {
            [ctx println:[NSString stringWithFormat:@"would rename %@ -> %@", name, newName]];
            changed++;
            continue;
        }
        NSError *error = nil;
        if([NSFileManager.defaultManager moveItemAtPath:absolute toPath:target error:&error])
        {
            [ctx println:[NSString stringWithFormat:@"%@ -> %@", name, newName]];
            changed++;
        }
        else
        {
            [ctx fail:[NSString stringWithFormat:@"rename: cannot rename '%@': %@", name, SZErrorText(error)]];
            status = 1;
        }
    }
    if(changed == 0 && status == 0)
    {
        [ctx println:@"No file names contained that text."];
    }
    return status;
}

static int SZCmdSearch(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"tn"];
    BOOL caseSensitive = [options.flags containsObject:@"s"];
    NSString *text = options.values[@"t"];
    NSUInteger maximum = options.values[@"n"] ? (NSUInteger)MAX(1, options.values[@"n"].integerValue) : 200;
    NSString *pattern = nil;
    NSString *folder = @".";
    if(text != nil)
    {
        if(options.paths.count > 0)
        {
            folder = options.paths[0];
        }
    }
    else
    {
        if(options.paths.count == 0)
        {
            [ctx fail:@"search: give a name pattern, or -t \"text\". Try: search \"*.txt\" ."];
            return 1;
        }
        pattern = options.paths[0];
        if(options.paths.count > 1)
        {
            folder = options.paths[1];
        }
        if([pattern rangeOfString:@"*"].location == NSNotFound && [pattern rangeOfString:@"?"].location == NSNotFound)
        {
            pattern = [NSString stringWithFormat:@"*%@*", pattern];
        }
    }

    NSString *root = [ctx.shell resolve:folder];
    if(!SZIsDirectory(root))
    {
        [ctx fail:[NSString stringWithFormat:@"search: '%@' is not a folder", folder]];
        return 1;
    }

    NSUInteger found = 0;
    NSUInteger scanned = 0;
    BOOL truncated = NO;
    NSDirectoryEnumerator<NSString *> *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    for(NSString *sub in enumerator)
    {
        if([ctx cancelled])
        {
            return 130;
        }
        scanned++;
        NSString *fileType = enumerator.fileAttributes.fileType;
        BOOL isDirectory = [fileType isEqualToString:NSFileTypeDirectory];
        NSString *shown = [folder stringByAppendingPathComponent:sub];

        if(text == nil)
        {
            int flags = caseSensitive ? 0 : FNM_CASEFOLD;
            if(fnmatch(pattern.UTF8String, sub.lastPathComponent.UTF8String, flags) == 0)
            {
                [ctx println:isDirectory ? [shown stringByAppendingString:@"/"] : shown];
                found++;
            }
        }
        else if([fileType isEqualToString:NSFileTypeRegular])
        {
            NSString *content = SZQuietText([root stringByAppendingPathComponent:sub]);
            if(content == nil)
            {
                continue;
            }
            NSUInteger number = 0;
            for(NSString *line in SZLines(content))
            {
                number++;
                NSStringCompareOptions compare = caseSensitive ? 0 : NSCaseInsensitiveSearch;
                if([line rangeOfString:text options:compare].location == NSNotFound)
                {
                    continue;
                }
                NSString *shortLine = line.length > 160 ? [[line substringToIndex:160] stringByAppendingString:@"..."] : line;
                [ctx println:[NSString stringWithFormat:@"%@:%lu: %@", shown, (unsigned long)number, shortLine]];
                found++;
                if(found >= maximum)
                {
                    break;
                }
            }
        }
        if(found >= maximum)
        {
            truncated = YES;
            break;
        }
    }
    [ctx println:[NSString stringWithFormat:@"%lu found%@ (looked at %lu items)", (unsigned long)found, truncated ? @", stopped at the limit (use -n for more)" : @"", (unsigned long)scanned]];
    return found > 0 ? 0 : 1;
}

/* ---- Commands: zip and unzip --------------------------------------------------- */

static NSString *SZEntryName(SlateShell *shell, NSString *absolute)
{
    NSString *prefix = [shell.cwd hasSuffix:@"/"] ? shell.cwd : [shell.cwd stringByAppendingString:@"/"];
    if([absolute hasPrefix:prefix] && absolute.length > prefix.length)
    {
        return [absolute substringFromIndex:prefix.length];
    }
    return absolute.lastPathComponent;
}

static BOOL SZWriteChunk(NSFileHandle *handle, const void *bytes, NSUInteger length, NSError **error)
{
    if(length == 0)
    {
        return YES;
    }
    return [handle writeData:[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO] error:error];
}

static int SZCmdZip(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@""];
    if(options.paths.count < 2)
    {
        [ctx fail:@"zip: use zip archive.zip file-or-folder ..."];
        return 1;
    }
    NSString *archiveName = options.paths[0];
    if(archiveName.pathExtension.length == 0)
    {
        archiveName = [archiveName stringByAppendingString:@".zip"];
    }
    NSString *archive = [ctx.shell resolve:archiveName];
    NSFileManager *manager = NSFileManager.defaultManager;

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for(NSUInteger index = 1; index < options.paths.count; index++)
    {
        NSString *name = options.paths[index];
        NSString *absolute = [ctx.shell resolve:name];
        if(!SZExists(absolute))
        {
            [ctx fail:[NSString stringWithFormat:@"zip: cannot find '%@'", name]];
            continue;
        }
        if([absolute isEqualToString:archive])
        {
            continue;
        }
        NSString *base = SZEntryName(ctx.shell, absolute);
        NSDictionary *attributes = [manager attributesOfItemAtPath:absolute error:nil];
        [items addObject:@{ @"path": absolute, @"name": base, @"type": attributes.fileType ?: NSFileTypeRegular, @"attributes": attributes ?: @{} }];
        if(SZIsDirectory(absolute))
        {
            NSDirectoryEnumerator<NSString *> *enumerator = [manager enumeratorAtPath:absolute];
            for(NSString *sub in enumerator)
            {
                if([ctx cancelled])
                {
                    return 130;
                }
                NSString *childPath = [absolute stringByAppendingPathComponent:sub];
                if([childPath isEqualToString:archive])
                {
                    continue;
                }
                NSDictionary *childAttributes = enumerator.fileAttributes;
                [items addObject:@{ @"path": childPath, @"name": [base stringByAppendingPathComponent:sub], @"type": childAttributes.fileType ?: NSFileTypeRegular, @"attributes": childAttributes ?: @{} }];
            }
        }
    }
    if(items.count == 0)
    {
        [ctx fail:@"zip: nothing to add"];
        return 1;
    }

    NSString *temporary = [archive stringByAppendingString:@".part"];
    [manager removeItemAtPath:temporary error:nil];
    if(![manager createFileAtPath:temporary contents:[NSData data] attributes:nil])
    {
        [ctx fail:[NSString stringWithFormat:@"zip: cannot create '%@'", archiveName]];
        return 1;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:temporary];
    if(handle == nil)
    {
        [manager removeItemAtPath:temporary error:nil];
        [ctx fail:@"zip: cannot open the archive for writing"];
        return 1;
    }

    NSMutableData *central = [NSMutableData data];
    unsigned long long offset = 0;
    NSUInteger count = 0;
    unsigned long long totalIn = 0;
    unsigned long long totalOut = 0;
    int status = 0;

    for(NSDictionary *item in items)
    {
        if([ctx cancelled])
        {
            [handle closeFile];
            [manager removeItemAtPath:temporary error:nil];
            return 130;
        }
        NSString *path = item[@"path"];
        NSString *type = item[@"type"];
        NSDictionary *attributes = item[@"attributes"];
        NSString *entryName = item[@"name"];
        BOOL isDirectory = [type isEqualToString:NSFileTypeDirectory];
        BOOL isLink = [type isEqualToString:NSFileTypeSymbolicLink];
        if(!isDirectory && !isLink && ![type isEqualToString:NSFileTypeRegular])
        {
            continue;
        }

        NSData *payload = [NSData data];
        uint32_t crc = 0;
        uint32_t size = 0;
        uint16_t method = 0;
        uint32_t mode = (uint32_t)(attributes.filePosixPermissions & 0777);
        if(isDirectory)
        {
            entryName = [entryName stringByAppendingString:@"/"];
            mode |= 0040000;
        }
        else if(isLink)
        {
            NSString *destination = [manager destinationOfSymbolicLinkAtPath:path error:nil] ?: @"";
            payload = [destination dataUsingEncoding:NSUTF8StringEncoding];
            size = (uint32_t)payload.length;
            crc = SZCRC32(0, payload.bytes, payload.length);
            mode |= 0120000;
        }
        else
        {
            NSError *error = nil;
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
            if(data == nil)
            {
                [ctx fail:[NSString stringWithFormat:@"zip: cannot read '%@': %@", entryName, SZErrorText(error)]];
                status = 1;
                continue;
            }
            if(data.length >= 0xFFFFFFFFu)
            {
                [ctx fail:[NSString stringWithFormat:@"zip: '%@' is 4 GB or larger, skipping", entryName]];
                status = 1;
                continue;
            }
            payload = data;
            size = (uint32_t)data.length;
            crc = SZCRC32(0, data.bytes, data.length);
            if(data.length > 32)
            {
                NSData *packed = [data compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
                if(packed != nil && packed.length < data.length)
                {
                    method = 8;
                    payload = packed;
                }
            }
            mode |= 0100000;
        }

        NSData *nameData = [entryName dataUsingEncoding:NSUTF8StringEncoding];
        if(nameData == nil || nameData.length > 65535)
        {
            [ctx fail:[NSString stringWithFormat:@"zip: name too long: '%@'", entryName]];
            status = 1;
            continue;
        }
        if(count >= 65535 || offset + 30 + nameData.length + payload.length > 0xFFFFFFFFull)
        {
            [ctx fail:@"zip: the archive would be larger than 4 GB or hold more than 65535 files"];
            status = 1;
            break;
        }

        uint16_t flags = 0;
        const uint8_t *nameBytes = nameData.bytes;
        for(NSUInteger k = 0; k < nameData.length; k++)
        {
            if(nameBytes[k] > 127)
            {
                flags |= 0x0800;
                break;
            }
        }
        uint16_t dosTime = 0;
        uint16_t dosDate = 0;
        NSDate *modified = attributes.fileModificationDate ?: [NSDate date];
        SZDosTime((time_t)modified.timeIntervalSince1970, &dosTime, &dosDate);

        uint8_t header[30];
        SZLocalHeader(header, flags, method, dosTime, dosDate, crc, (uint32_t)payload.length, size, (uint16_t)nameData.length);
        NSError *writeError = nil;
        BOOL ok = SZWriteChunk(handle, header, 30, &writeError) &&
                  SZWriteChunk(handle, nameData.bytes, nameData.length, &writeError) &&
                  SZWriteChunk(handle, payload.bytes, payload.length, &writeError);
        if(!ok)
        {
            [handle closeFile];
            [manager removeItemAtPath:temporary error:nil];
            [ctx fail:[NSString stringWithFormat:@"zip: could not write the archive: %@", SZErrorText(writeError)]];
            return 1;
        }

        uint8_t entry[46];
        SZCentralHeader(entry, flags, method, dosTime, dosDate, crc, (uint32_t)payload.length, size, (uint16_t)nameData.length, mode << 16, (uint32_t)offset);
        [central appendBytes:entry length:46];
        [central appendData:nameData];

        offset += 30 + nameData.length + payload.length;
        count++;
        totalIn += size;
        totalOut += payload.length;
        if(isDirectory)
        {
            [ctx println:[NSString stringWithFormat:@"  adding: %@", entryName]];
        }
        else
        {
            NSString *how = method == 8 ? [NSString stringWithFormat:@"deflated %d%%", size > 0 ? (int)(100 - (100.0 * payload.length / size)) : 0] : @"stored";
            [ctx println:[NSString stringWithFormat:@"  adding: %@ (%@)", entryName, how]];
        }
    }

    uint8_t end[22];
    SZEndRecord(end, (uint16_t)count, (uint32_t)central.length, (uint32_t)offset);
    NSError *finishError = nil;
    BOOL finished = SZWriteChunk(handle, central.bytes, central.length, &finishError) && SZWriteChunk(handle, end, 22, &finishError);
    [handle closeFile];
    if(!finished || count == 0)
    {
        [manager removeItemAtPath:temporary error:nil];
        [ctx fail:count == 0 ? @"zip: nothing was added" : [NSString stringWithFormat:@"zip: could not finish the archive: %@", SZErrorText(finishError)]];
        return 1;
    }
    [manager removeItemAtPath:archive error:nil];
    NSError *moveError = nil;
    if(![manager moveItemAtPath:temporary toPath:archive error:&moveError])
    {
        [ctx fail:[NSString stringWithFormat:@"zip: could not save '%@': %@", archiveName, SZErrorText(moveError)]];
        return 1;
    }
    [ctx println:[NSString stringWithFormat:@"Created %@: %lu items, %@ -> %@", archiveName, (unsigned long)count, SZHumanSize(totalIn), SZHumanSize(totalOut)]];
    return status;
}

static int SZCmdUnzip(SlateContext *ctx)
{
    SlateOptions *options = [ctx options:@"d"];
    BOOL listOnly = [options.flags containsObject:@"l"];
    BOOL overwrite = [options.flags containsObject:@"o"];
    if(options.paths.count == 0)
    {
        [ctx fail:@"unzip: use unzip [-l] [-o] archive.zip [-d folder]"];
        return 1;
    }
    NSString *archiveName = options.paths[0];
    NSError *error = nil;
    NSData *zip = [NSData dataWithContentsOfFile:[ctx.shell resolve:archiveName] options:NSDataReadingMappedIfSafe error:&error];
    if(zip == nil)
    {
        [ctx fail:[NSString stringWithFormat:@"unzip: cannot open '%@': %@", archiveName, SZErrorText(error)]];
        return 1;
    }
    NSString *problem = nil;
    NSArray<SZZipEntry *> *entries = SZZipEntries(zip, &problem);
    if(entries == nil)
    {
        [ctx fail:[NSString stringWithFormat:@"unzip: %@: %@", archiveName, problem ?: @"cannot read it"]];
        return 1;
    }

    if(listOnly)
    {
        unsigned long long total = 0;
        for(SZZipEntry *entry in entries)
        {
            total += entry.size;
            [ctx println:[NSString stringWithFormat:@"%@  %@", SZPad([NSString stringWithFormat:@"%u", entry.size], 10, YES), entry.name]];
        }
        [ctx println:[NSString stringWithFormat:@"%lu items, %@ unpacked", (unsigned long)entries.count, SZHumanSize(total)]];
        return 0;
    }

    NSString *destination = options.values[@"d"] ? [ctx.shell resolve:options.values[@"d"]] : ctx.shell.cwd;
    NSFileManager *manager = NSFileManager.defaultManager;
    if(![manager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error])
    {
        [ctx fail:[NSString stringWithFormat:@"unzip: cannot create '%@': %@", destination.lastPathComponent, SZErrorText(error)]];
        return 1;
    }
    NSString *safeRoot = [destination stringByStandardizingPath];
    NSUInteger extracted = 0;
    NSUInteger skipped = 0;
    int status = 0;

    for(SZZipEntry *entry in entries)
    {
        if([ctx cancelled])
        {
            return 130;
        }
        NSString *name = entry.name;
        if(name.length == 0)
        {
            continue;
        }
        BOOL unsafe = [name hasPrefix:@"/"];
        for(NSString *part in [name componentsSeparatedByString:@"/"])
        {
            if([part isEqualToString:@".."])
            {
                unsafe = YES;
            }
        }
        NSString *target = [[destination stringByAppendingPathComponent:name] stringByStandardizingPath];
        if(unsafe || !([target isEqualToString:safeRoot] || [target hasPrefix:[safeRoot stringByAppendingString:@"/"]]))
        {
            [ctx fail:[NSString stringWithFormat:@"unzip: skipping unsafe path '%@'", name]];
            skipped++;
            status = 1;
            continue;
        }

        if([name hasSuffix:@"/"])
        {
            [manager createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [manager createDirectoryAtPath:[target stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if(SZExists(target))
        {
            if(!overwrite)
            {
                [ctx println:[NSString stringWithFormat:@"  exists: %@ (use -o to overwrite)", name]];
                skipped++;
                continue;
            }
            [manager removeItemAtPath:target error:nil];
        }
        NSData *data = SZZipData(zip, entry);
        if(data == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"unzip: cannot unpack '%@' (damaged or an unsupported method)", name]];
            skipped++;
            status = 1;
            continue;
        }
        if((entry.mode & 0xF000) == 0xA000)
        {
            NSString *linkTarget = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if(linkTarget.length > 0)
            {
                [manager createSymbolicLinkAtPath:target withDestinationPath:linkTarget error:nil];
                extracted++;
            }
            continue;
        }
        NSError *writeError = nil;
        if(![data writeToFile:target options:NSDataWritingAtomic error:&writeError])
        {
            [ctx fail:[NSString stringWithFormat:@"unzip: cannot write '%@': %@", name, SZErrorText(writeError)]];
            skipped++;
            status = 1;
            continue;
        }
        uint32_t permissions = entry.mode & 0777;
        if(permissions == 0)
        {
            permissions = 0644;
        }
        [manager setAttributes:@{ NSFilePosixPermissions: @(permissions) } ofItemAtPath:target error:nil];
        [ctx println:[NSString stringWithFormat:@"  inflating: %@", name]];
        extracted++;
    }
    [ctx println:[NSString stringWithFormat:@"Unpacked %lu files into %@%@", (unsigned long)extracted, [ctx.shell display:destination], skipped > 0 ? [NSString stringWithFormat:@" (%lu skipped)", (unsigned long)skipped] : @""]];
    return status;
}

static int SZCmdToolbox(SlateContext *ctx)
{
    if(ctx.args.count > 1)
    {
        NSValue *function = ctx.shell.commands[ctx.args[1]];
        if(function == nil)
        {
            [ctx fail:[NSString stringWithFormat:@"toolbox: no tool called '%@'", ctx.args[1]]];
            return 1;
        }
        ctx.args = [ctx.args subarrayWithRange:NSMakeRange(1, ctx.args.count - 1)];
        return ((SlateCommandFunction)function.pointerValue)(ctx);
    }
    [ctx println:@"Toolbox"];
    [ctx println:@"-------"];
    for(NSDictionary *item in SZToolboxItems())
    {
        [ctx println:[NSString stringWithFormat:@"%@  %@", SZPad(item[@"name"], 10, NO), item[@"summary"]]];
        [ctx println:[NSString stringWithFormat:@"%@  %@", SZPad(@"", 10, NO), item[@"usage"]]];
    }
    [ctx println:@""];
    [ctx println:@"Run any of them by name, or tap the toolbox button for a quick start."];
    return 0;
}

/* ---- Shell: the command table and the shell itself ------------------------------ */

static NSValue *SZFn(SlateCommandFunction function)
{
    return [NSValue valueWithPointer:(const void *)function];
}

static NSDictionary<NSString *, NSValue *> *SZCommandTable(void)
{
    return @{
        @"help": SZFn(SZCmdHelp),
        @"clear": SZFn(SZCmdClear),
        @"pwd": SZFn(SZCmdPwd),
        @"cd": SZFn(SZCmdCd),
        @"ls": SZFn(SZCmdLs),
        @"tree": SZFn(SZCmdTree),
        @"cat": SZFn(SZCmdCat),
        @"head": SZFn(SZCmdHead),
        @"tail": SZFn(SZCmdTail),
        @"touch": SZFn(SZCmdTouch),
        @"mkdir": SZFn(SZCmdMkdir),
        @"rm": SZFn(SZCmdRm),
        @"cp": SZFn(SZCmdCp),
        @"mv": SZFn(SZCmdMv),
        @"stat": SZFn(SZCmdStat),
        @"du": SZFn(SZCmdDu),
        @"chmod": SZFn(SZCmdChmod),
        @"echo": SZFn(SZCmdEcho),
        @"env": SZFn(SZCmdEnv),
        @"export": SZFn(SZCmdExport),
        @"whoami": SZFn(SZCmdWhoami),
        @"id": SZFn(SZCmdId),
        @"uname": SZFn(SZCmdUname),
        @"date": SZFn(SZCmdDate),
        @"history": SZFn(SZCmdHistory),
        @"wc": SZFn(SZCmdWc),
        @"grep": SZFn(SZCmdGrep),
        @"sort": SZFn(SZCmdSort),
        @"uniq": SZFn(SZCmdUniq),
        @"base64": SZFn(SZCmdBase64),
        @"hash": SZFn(SZCmdHash),
        @"hexdump": SZFn(SZCmdHexdump),
        @"rename": SZFn(SZCmdRename),
        @"search": SZFn(SZCmdSearch),
        @"zip": SZFn(SZCmdZip),
        @"unzip": SZFn(SZCmdUnzip),
        @"toolbox": SZFn(SZCmdToolbox),
    };
}

@implementation SlateShell

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _home = [NSHomeDirectory() stringByStandardizingPath];
        _cwd = _home;
        _environment = [@{ @"HOME": _home, @"PWD": _home, @"USER": @"mobile", @"SHELL": @"slate", @"TERM": @"slate-terminal" } mutableCopy];
        _history = [NSMutableArray array];
        _commands = SZCommandTable();
    }
    return self;
}

- (NSString *)resolve:(NSString *)path
{
    if(path.length == 0)
    {
        return self.cwd;
    }
    if([path isEqualToString:@"~"])
    {
        return self.home;
    }
    if([path hasPrefix:@"~/"])
    {
        path = [self.home stringByAppendingString:[path substringFromIndex:1]];
    }
    NSString *full = [path hasPrefix:@"/"] ? path : [self.cwd stringByAppendingPathComponent:path];
    return [full stringByStandardizingPath];
}

- (NSString *)display:(NSString *)absolute
{
    if([absolute isEqualToString:self.home])
    {
        return @"~";
    }
    NSString *prefix = [self.home stringByAppendingString:@"/"];
    if([absolute hasPrefix:prefix])
    {
        return [@"~/" stringByAppendingString:[absolute substringFromIndex:prefix.length]];
    }
    return absolute;
}

- (NSString *)prompt
{
    NSString *shown = [self display:self.cwd];
    NSArray<NSString *> *parts = [shown pathComponents];
    if(parts.count > 3)
    {
        return [NSString stringWithFormat:@"…/%@/%@", parts[parts.count - 2], parts[parts.count - 1]];
    }
    return shown;
}

- (NSArray<NSString *> *)commandNames
{
    return [self.commands.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSSet<NSString *> *)globCommands
{
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[ @"ls", @"rm", @"cp", @"mv", @"cat", @"stat", @"du", @"head", @"tail", @"wc", @"hash", @"hexdump", @"zip", @"chmod", @"sort", @"uniq", @"touch" ]];
    });
    return set;
}

- (NSArray<NSString *> *)globMatches:(NSString *)pattern
{
    NSRange slash = [pattern rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *directoryPart = slash.location == NSNotFound ? @"" : [pattern substringToIndex:slash.location + 1];
    NSString *filePattern = slash.location == NSNotFound ? pattern : [pattern substringFromIndex:slash.location + 1];
    if([directoryPart containsString:@"*"] || [directoryPart containsString:@"?"])
    {
        return @[];
    }
    NSString *directory = [self resolve:directoryPart.length > 0 ? directoryPart : @"."];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for(NSString *name in names)
    {
        if(fnmatch(filePattern.UTF8String, name.UTF8String, FNM_PERIOD) == 0)
        {
            [matches addObject:[directoryPart stringByAppendingString:name]];
        }
    }
    return [matches sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSArray<NSString *> *)expandedArguments:(NSArray<NSString *> *)args quoted:(NSArray<NSNumber *> *)quoted
{
    BOOL globbing = [[SlateShell globCommands] containsObject:args.firstObject];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for(NSUInteger index = 0; index < args.count; index++)
    {
        NSString *arg = args[index];
        BOOL wasQuoted = index < quoted.count ? quoted[index].boolValue : NO;
        if(index > 0 && !wasQuoted && ([arg isEqualToString:@"~"] || [arg hasPrefix:@"~/"]))
        {
            arg = [self.home stringByAppendingString:[arg substringFromIndex:1]];
        }
        if(globbing && index > 0 && !wasQuoted && ![arg hasPrefix:@"-"] && ([arg containsString:@"*"] || [arg containsString:@"?"]))
        {
            NSArray<NSString *> *matches = [self globMatches:arg];
            if(matches.count > 0)
            {
                [result addObjectsFromArray:matches];
                continue;
            }
        }
        [result addObject:arg];
    }
    return result;
}

- (void)writeText:(NSString *)text toPath:(NSString *)name append:(BOOL)append
{
    NSString *absolute = [self resolve:name];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    BOOL ok;
    if(append && SZExists(absolute))
    {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:absolute];
        if(handle == nil)
        {
            ok = NO;
        }
        else
        {
            [handle seekToEndOfFile];
            ok = [handle writeData:data error:&error];
            [handle closeFile];
        }
    }
    else
    {
        ok = [data writeToFile:absolute options:NSDataWritingAtomic error:&error];
    }
    if(!ok && self.write != nil)
    {
        self.write([NSString stringWithFormat:@"slate: cannot write to '%@': %@\n", name, SZErrorText(error)], YES);
    }
}

- (void)runLine:(NSString *)line
{
    self.cancelRequested = NO;
    self.clearRequested = NO;
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(trimmed.length == 0)
    {
        return;
    }
    NSString *problem = nil;
    NSArray<NSDictionary *> *stages = [SlateParser parse:trimmed environment:self.environment status:self.lastStatus problem:&problem];
    if(stages == nil)
    {
        if(self.write != nil)
        {
            self.write([NSString stringWithFormat:@"slate: %@\n", problem ?: @"could not read that command"], YES);
        }
        self.lastStatus = 2;
        return;
    }

    NSString *pipeInput = nil;
    for(NSUInteger index = 0; index < stages.count; index++)
    {
        NSDictionary *stage = stages[index];
        NSArray<NSString *> *args = stage[@"args"];
        if(args.count == 0)
        {
            if(self.write != nil)
            {
                self.write(@"slate: missing command next to |\n", YES);
            }
            self.lastStatus = 2;
            return;
        }
        BOOL last = (index == stages.count - 1);
        id redirectValue = stage[@"redirect"];
        NSString *redirect = [redirectValue isKindOfClass:NSString.class] ? redirectValue : nil;

        NSValue *function = self.commands[args[0]];
        if(function == nil)
        {
            if(self.write != nil)
            {
                self.write([NSString stringWithFormat:@"slate: command not found: %@ (type help)\n", args[0]], YES);
            }
            self.lastStatus = 127;
            return;
        }

        SlateContext *context = [SlateContext new];
        context.shell = self;
        context.input = pipeInput;
        context.live = last && redirect == nil;
        context.args = [self expandedArguments:args quoted:stage[@"quoted"]];
        int status = ((SlateCommandFunction)function.pointerValue)(context);
        self.lastStatus = status;
        if(self.cancelRequested)
        {
            if(self.write != nil)
            {
                self.write(@"^C\n", YES);
            }
            return;
        }
        if(!last)
        {
            pipeInput = [context.output copy];
            continue;
        }
        if(redirect != nil)
        {
            [self writeText:context.output toPath:redirect append:[stage[@"append"] boolValue]];
        }
    }
}

- (NSDictionary *)complete:(NSString *)line
{
    NSRange space = [line rangeOfString:@" " options:NSBackwardsSearch];
    NSString *head = space.location == NSNotFound ? @"" : [line substringToIndex:space.location + 1];
    NSString *word = space.location == NSNotFound ? line : [line substringFromIndex:space.location + 1];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSMutableArray<NSString *> *replacements = [NSMutableArray array];

    BOOL completingCommand = (head.length == 0) || [head hasSuffix:@"| "];
    if(completingCommand)
    {
        for(NSString *name in [self commandNames])
        {
            if([name hasPrefix:word])
            {
                [candidates addObject:name];
                [replacements addObject:name];
            }
        }
    }
    else
    {
        NSRange slash = [word rangeOfString:@"/" options:NSBackwardsSearch];
        NSString *directoryPart = slash.location == NSNotFound ? @"" : [word substringToIndex:slash.location + 1];
        NSString *basePrefix = slash.location == NSNotFound ? word : [word substringFromIndex:slash.location + 1];
        NSString *directory = [self resolve:directoryPart.length > 0 ? directoryPart : @"."];
        NSArray<NSString *> *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for(NSString *name in names)
        {
            if(![name hasPrefix:basePrefix] || ([name hasPrefix:@"."] && ![basePrefix hasPrefix:@"."]))
            {
                continue;
            }
            BOOL isDirectory = SZIsDirectory([directory stringByAppendingPathComponent:name]);
            [candidates addObject:isDirectory ? [name stringByAppendingString:@"/"] : name];
            [replacements addObject:[directoryPart stringByAppendingString:[SZEscapePath(name) stringByAppendingString:isDirectory ? @"/" : @""]]];
        }
    }

    if(candidates.count == 0)
    {
        return @{ @"line": line, @"candidates": @[] };
    }
    NSString *common = replacements.firstObject;
    for(NSString *replacement in replacements)
    {
        common = [common commonPrefixWithString:replacement options:0];
    }
    NSString *newLine = [head stringByAppendingString:common];
    if(replacements.count == 1 && ![common hasSuffix:@"/"])
    {
        newLine = [newLine stringByAppendingString:@" "];
    }
    return @{ @"line": newLine, @"candidates": candidates.count > 1 ? candidates : @[] };
}

@end

/* ---- Screens ---------------------------------------------------------------------- */

static UIColor *SZBackground(void)
{
    return [UIColor colorWithRed:0.055 green:0.063 blue:0.078 alpha:1.0];
}

static UIColor *SZBarColor(void)
{
    return [UIColor colorWithRed:0.09 green:0.10 blue:0.125 alpha:1.0];
}

static UIColor *SZTextColor(void)
{
    return [UIColor colorWithWhite:0.88 alpha:1.0];
}

static UIColor *SZDimColor(void)
{
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

static UIColor *SZErrorColor(void)
{
    return [UIColor colorWithRed:1.0 green:0.45 blue:0.42 alpha:1.0];
}

static UIColor *SZAccent(void)
{
    return [UIColor colorWithRed:0.45 green:0.62 blue:0.95 alpha:1.0];
}

static UIFont *SZMono(CGFloat size, UIFontWeight weight)
{
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

@interface SlateToolboxViewController : UITableViewController
@property (nonatomic, copy) void (^onPick)(NSString *template);
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@implementation SlateToolboxViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Toolbox";
    self.items = SZToolboxItems();
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"tool"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];
}

- (void)doneTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Tap a tool to put its command in the Terminal, then fill in the names and press Go.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *item = self.items[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"tool" forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = item[@"name"];
    content.textProperties.font = SZMono(16.0, UIFontWeightSemibold);
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@", item[@"summary"], item[@"usage"]];
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *template = self.items[indexPath.row][@"template"];
    void (^pick)(NSString *) = self.onPick;
    [self dismissViewControllerAnimated:YES completion:^{
        if(pick != nil)
        {
            pick(template);
        }
    }];
}

@end

@interface SlateTerminalViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) SlateShell *shell;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) UITextView *outputView;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UILabel *promptLabel;
@property (nonatomic, strong) UIBarButtonItem *stopButton;
@property (nonatomic, strong) NSMutableAttributedString *pending;
@property (nonatomic, assign) BOOL flushScheduled;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSInteger historyIndex;
@end

@implementation SlateTerminalViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Terminal";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = SZBackground();
    self.queue = dispatch_queue_create("dev.alloycore.slate.terminal", DISPATCH_QUEUE_SERIAL);
    self.pending = [NSMutableAttributedString new];
    self.shell = [SlateShell new];

    __weak typeof(self) weakSelf = self;
    self.shell.write = ^(NSString *text, BOOL isError) {
        [weakSelf enqueue:text isError:isError];
    };

    UIBarButtonItem *toolbox = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"wrench.and.screwdriver"] style:UIBarButtonItemStylePlain target:self action:@selector(toolboxTapped)];
    toolbox.accessibilityLabel = @"Toolbox";
    self.stopButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"stop.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(stopTapped)];
    self.stopButton.accessibilityLabel = @"Stop";
    self.stopButton.enabled = NO;
    self.navigationItem.rightBarButtonItems = @[ toolbox, self.stopButton ];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearTapped)];

    self.outputView = [UITextView new];
    self.outputView.translatesAutoresizingMaskIntoConstraints = NO;
    self.outputView.backgroundColor = UIColor.clearColor;
    self.outputView.editable = NO;
    self.outputView.selectable = YES;
    self.outputView.textContainerInset = UIEdgeInsetsMake(12.0, 10.0, 12.0, 10.0);
    self.outputView.alwaysBounceVertical = YES;
    self.outputView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.outputView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:self.outputView];

    UIView *bottomBar = [UIView new];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.backgroundColor = SZBarColor();
    [self.view addSubview:bottomBar];

    UIScrollView *keys = [UIScrollView new];
    keys.translatesAutoresizingMaskIntoConstraints = NO;
    keys.showsHorizontalScrollIndicator = NO;
    [bottomBar addSubview:keys];

    UIStackView *keyStack = [UIStackView new];
    keyStack.translatesAutoresizingMaskIntoConstraints = NO;
    keyStack.axis = UILayoutConstraintAxisHorizontal;
    keyStack.spacing = 6.0;
    [keys addSubview:keyStack];
    for(NSString *title in @[ @"Tab", @"▲", @"▼", @"~", @"/", @"-", @"|", @">", @"*", @".", @"\"" ])
    {
        UIButtonConfiguration *configuration = [UIButtonConfiguration grayButtonConfiguration];
        configuration.title = title;
        configuration.buttonSize = UIButtonConfigurationSizeSmall;
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
        button.accessibilityLabel = title;
        [button addTarget:self action:@selector(quickKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [keyStack addArrangedSubview:button];
    }

    self.promptLabel = [UILabel new];
    self.promptLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.promptLabel.font = SZMono(14.0, UIFontWeightSemibold);
    self.promptLabel.textColor = SZAccent();
    [self.promptLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.promptLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [bottomBar addSubview:self.promptLabel];

    self.inputField = [UITextField new];
    self.inputField.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputField.font = SZMono(15.0, UIFontWeightRegular);
    self.inputField.textColor = SZTextColor();
    self.inputField.tintColor = SZAccent();
    self.inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inputField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inputField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.inputField.smartDashesType = UITextSmartDashesTypeNo;
    self.inputField.smartQuotesType = UITextSmartQuotesTypeNo;
    self.inputField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.inputField.returnKeyType = UIReturnKeyGo;
    self.inputField.keyboardAppearance = UIKeyboardAppearanceDark;
    self.inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"type a command, or help" attributes:@{ NSForegroundColorAttributeName: SZDimColor() }];
    self.inputField.delegate = self;
    [bottomBar addSubview:self.inputField];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.outputView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.outputView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.outputView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.outputView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor],

        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],

        [keys.topAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:8.0],
        [keys.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor constant:10.0],
        [keys.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-10.0],
        [keys.heightAnchor constraintEqualToConstant:34.0],

        [keyStack.topAnchor constraintEqualToAnchor:keys.contentLayoutGuide.topAnchor],
        [keyStack.bottomAnchor constraintEqualToAnchor:keys.contentLayoutGuide.bottomAnchor],
        [keyStack.leadingAnchor constraintEqualToAnchor:keys.contentLayoutGuide.leadingAnchor],
        [keyStack.trailingAnchor constraintEqualToAnchor:keys.contentLayoutGuide.trailingAnchor],
        [keyStack.heightAnchor constraintEqualToAnchor:keys.frameLayoutGuide.heightAnchor],

        [self.promptLabel.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor constant:12.0],
        [self.promptLabel.centerYAnchor constraintEqualToAnchor:self.inputField.centerYAnchor],

        [self.inputField.topAnchor constraintEqualToAnchor:keys.bottomAnchor constant:6.0],
        [self.inputField.leadingAnchor constraintEqualToAnchor:self.promptLabel.trailingAnchor constant:8.0],
        [self.inputField.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-12.0],
        [self.inputField.bottomAnchor constraintEqualToAnchor:bottomBar.bottomAnchor constant:-8.0],
        [self.inputField.heightAnchor constraintEqualToConstant:36.0],
    ]];

    [self updatePrompt];
    [self enqueue:@"Slate Terminal\n" isError:NO];
    [self enqueue:@"Type help for commands, or tap the toolbox button (top right).\n" isError:NO];
    [self enqueue:[NSString stringWithFormat:@"Home: %@\n\n", self.shell.home] isError:NO];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.inputField becomeFirstResponder];
}

- (void)updatePrompt
{
    self.promptLabel.text = [NSString stringWithFormat:@"%@ $", [self.shell prompt]];
}

- (void)enqueue:(NSString *)text isError:(BOOL)isError
{
    if(text.length == 0)
    {
        return;
    }
    NSDictionary *attributes = @{ NSFontAttributeName: SZMono(13.0, UIFontWeightRegular), NSForegroundColorAttributeName: isError ? SZErrorColor() : SZTextColor() };
    NSAttributedString *piece = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    @synchronized(self)
    {
        [self.pending appendAttributedString:piece];
        if(self.flushScheduled)
        {
            return;
        }
        self.flushScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self flush];
    });
}

- (void)flush
{
    NSAttributedString *batch = nil;
    @synchronized(self)
    {
        batch = [self.pending copy];
        self.pending = [NSMutableAttributedString new];
        self.flushScheduled = NO;
    }
    if(batch.length == 0)
    {
        return;
    }
    NSTextStorage *storage = self.outputView.textStorage;
    [storage appendAttributedString:batch];
    if(storage.length > 200000)
    {
        [storage deleteCharactersInRange:NSMakeRange(0, 60000)];
    }
    [self.outputView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)appendEcho:(NSString *)prompt command:(NSString *)command
{
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:prompt attributes:@{ NSFontAttributeName: SZMono(13.0, UIFontWeightSemibold), NSForegroundColorAttributeName: SZAccent() }]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:[command stringByAppendingString:@"\n"] attributes:@{ NSFontAttributeName: SZMono(13.0, UIFontWeightRegular), NSForegroundColorAttributeName: UIColor.whiteColor }]];
    @synchronized(self)
    {
        [self.pending appendAttributedString:line];
    }
    [self flush];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self submit];
    return NO;
}

- (void)submit
{
    NSString *line = self.inputField.text ?: @"";
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self appendEcho:[NSString stringWithFormat:@"%@ $ ", [self.shell prompt]] command:line];
    self.inputField.text = @"";
    if(trimmed.length == 0)
    {
        return;
    }
    if(self.running)
    {
        [self enqueue:@"(a command is still running. Tap the stop button first.)\n" isError:YES];
        return;
    }
    if(![self.shell.history.lastObject isEqualToString:trimmed])
    {
        [self.shell.history addObject:trimmed];
    }
    self.historyIndex = (NSInteger)self.shell.history.count;
    self.running = YES;
    self.stopButton.enabled = YES;

    SlateShell *shell = self.shell;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        [shell runLine:trimmed];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf commandFinished];
        });
    });
}

- (void)commandFinished
{
    [self flush];
    self.running = NO;
    self.stopButton.enabled = NO;
    if(self.shell.clearRequested)
    {
        [self.outputView.textStorage setAttributedString:[NSAttributedString new]];
        self.shell.clearRequested = NO;
    }
    [self updatePrompt];
}

- (void)stopTapped
{
    self.shell.cancelRequested = YES;
}

- (void)clearTapped
{
    [self.outputView.textStorage setAttributedString:[NSAttributedString new]];
}

- (void)toolboxTapped
{
    SlateToolboxViewController *toolbox = [SlateToolboxViewController new];
    __weak typeof(self) weakSelf = self;
    toolbox.onPick = ^(NSString *template) {
        weakSelf.inputField.text = template;
        [weakSelf.inputField becomeFirstResponder];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:toolbox];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = navigation.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)historyUp
{
    NSArray<NSString *> *history = self.shell.history;
    if(history.count == 0)
    {
        return;
    }
    if(self.historyIndex > 0)
    {
        self.historyIndex--;
    }
    self.inputField.text = history[(NSUInteger)self.historyIndex];
}

- (void)historyDown
{
    NSArray<NSString *> *history = self.shell.history;
    if(self.historyIndex < (NSInteger)history.count - 1)
    {
        self.historyIndex++;
        self.inputField.text = history[(NSUInteger)self.historyIndex];
    }
    else
    {
        self.historyIndex = (NSInteger)history.count;
        self.inputField.text = @"";
    }
}

- (void)tabTapped
{
    NSDictionary *result = [self.shell complete:self.inputField.text ?: @""];
    self.inputField.text = result[@"line"];
    NSArray<NSString *> *candidates = result[@"candidates"];
    if(candidates.count > 0)
    {
        [self enqueue:[[candidates componentsJoinedByString:@"  "] stringByAppendingString:@"\n"] isError:NO];
    }
}

- (void)quickKeyTapped:(UIButton *)sender
{
    NSString *title = sender.configuration.title;
    if([title isEqualToString:@"Tab"])
    {
        [self tabTapped];
    }
    else if([title isEqualToString:@"▲"])
    {
        [self historyUp];
    }
    else if([title isEqualToString:@"▼"])
    {
        [self historyDown];
    }
    else if(title.length > 0)
    {
        [self.inputField insertText:title];
    }
    [self.inputField becomeFirstResponder];
}

@end

/* ---- App ---------------------------------------------------------------------------- */

@interface SlateTerminalSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SlateTerminalSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    if(![scene isKindOfClass:UIWindowScene.class])
    {
        return;
    }
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[SlateTerminalViewController new]];
    navigation.navigationBar.prefersLargeTitles = NO;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.tintColor = SZAccent();
    window.rootViewController = navigation;
    self.window = window;
    [window makeKeyAndVisible];
}

@end

@interface SlateTerminalAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SlateTerminalAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
    configuration.delegateClass = SlateTerminalSceneDelegate.class;
    return configuration;
}

@end

__attribute__((visibility("default")))
int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SlateTerminalAppDelegate.class));
    }
}
