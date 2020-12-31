#include <mach/mach.h>


struct sCSTypeRef {
    void *csCppData;
    void *csCppObj;
};

typedef struct sCSTypeRef CSTypeRef;
typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolRef;

extern "C" CSSymbolicatorRef CSSymbolicatorCreateWithTask(task_t task);
extern "C" CSSymbolRef CSSymbolicatorGetSymbolWithAddressAtTime(CSSymbolicatorRef cs, vm_address_t addr, uint64_t time);
extern "C" Boolean CSIsNull(CSTypeRef cs);
extern "C" const char* CSSymbolGetName(CSSymbolRef sym);

#define kCSNow 0x80000000u


void writeSymbolicatedLogToFile(NSString *unsymbolicatedLogContents, NSString *outputPath)
{
    CSSymbolicatorRef symbolicator =  CSSymbolicatorCreateWithTask(mach_task_self());
    NSString *symbolicatedLogContents = [unsymbolicatedLogContents copy];
    NSString *memoryAddressPattern = @"0[xX][0-9a-fA-F]+";

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:memoryAddressPattern options:0 error:nil];
    NSArray *matches = [regex matchesInString:unsymbolicatedLogContents options:0 range:NSMakeRange(0, [unsymbolicatedLogContents length])];
    for (NSTextCheckingResult *match in matches)
    {
        NSString *memoryAddressString = [unsymbolicatedLogContents substringWithRange:[match range]];

        int64_t addr = strtoull([memoryAddressString UTF8String], NULL, 0);
        CSSymbolRef symbolInfo = CSSymbolicatorGetSymbolWithAddressAtTime(symbolicator, addr, kCSNow);
        if (!CSIsNull(symbolInfo))
        {
            NSString *symbolName = [NSString stringWithFormat:@"%s", CSSymbolGetName(symbolInfo)];
            symbolicatedLogContents = [symbolicatedLogContents stringByReplacingOccurrencesOfString:memoryAddressString withString:symbolName];
        }
    }

    [symbolicatedLogContents writeToFile:outputPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

void gatherUnsymbolicatedCrashlogs(NSString *outputDirectory)
{
    // Find unsymbolicated crash reports
    NSString *unsymbolicatedLogsPath = @"/var/mobile/Library/Logs/CrashReporter";
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:unsymbolicatedLogsPath error:nil])
    {
        if (![[file pathExtension] isEqualToString:@"ips"])
        {
            continue;
        }

        NSString *fullPath = [NSString stringWithFormat:@"%@/%@", unsymbolicatedLogsPath, file];
        // Skip reports older than 1h
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
        NSTimeInterval fileAge = ABS([[attributes fileCreationDate] timeIntervalSinceNow]);
        if ((fileAge / 3600) > 1)
        {
            continue;
        }

        NSArray *interestingProcesses = @[@"SpringBoard", @"CarPlay"];
        NSString *crashedProcessName = [file componentsSeparatedByString:@"-"][0];
        if (![interestingProcesses containsObject:crashedProcessName])
        {
            continue;
        }

        // Skip the crash if the tweak wasn't injected in the process
        NSString *crashlogContents = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:nil];
        if (![crashlogContents containsString:@"/Library/MobileSubstrate/DynamicLibraries/carplayenable.dylib"])
        {
            continue;
        }

        NSString *outputFile = [NSString stringWithFormat:@"%@/%@.symbolicated", outputDirectory, file];
        writeSymbolicatedLogToFile(crashlogContents, outputFile);
    }
}

void gatherCr4shedLogs(NSString *outputDirectory)
{
    NSString *unsymbolicatedLogsPath = @"/var/mobile/Library/Cr4shed";
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:unsymbolicatedLogsPath error:nil])
    {
        if (![[file pathExtension] isEqualToString:@"log"])
        {
            continue;
        }

        NSString *fullPath = [NSString stringWithFormat:@"%@/%@", unsymbolicatedLogsPath, file];
        // Skip reports older than 1h
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
        NSTimeInterval fileAge = ABS([[attributes fileCreationDate] timeIntervalSinceNow]);
        if ((fileAge / 3600) > 1)
        {
            continue;
        }

        NSArray *interestingProcesses = @[@"SpringBoard", @"CarPlay"];
        NSString *crashedProcessName = [file componentsSeparatedByString:@"@"][0];
        if (![interestingProcesses containsObject:crashedProcessName])
        {
            continue;
        }

        // Skip the crash if the tweak wasn't injected in the process
        NSString *crashlogContents = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:nil];
        if (![crashlogContents containsString:@"/Library/MobileSubstrate/DynamicLibraries/carplayenable.dylib"])
        {
            continue;
        }

        NSString *outputFile = [NSString stringWithFormat:@"%@/%@.cr4shed", outputDirectory, file];
        [[NSFileManager defaultManager] copyItemAtPath:fullPath toPath:outputFile error:nil];
    }
}

void symbolicateAndUploadCrashlogs(void)
{
    // Setup a tmp directory to contain the gathered crash reports
    NSString *crashReportsStash = @"/tmp/crash_reports";
    if ([[NSFileManager defaultManager] fileExistsAtPath:crashReportsStash])
    {
        [[NSFileManager defaultManager] removeItemAtPath:crashReportsStash error:nil];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:crashReportsStash withIntermediateDirectories:NO attributes:nil error:NULL];

    // Gather logs from all sources
    gatherUnsymbolicatedCrashlogs(crashReportsStash);    
    gatherCr4shedLogs(crashReportsStash);
    
    // TODO delete files
}