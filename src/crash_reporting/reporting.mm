#include <mach/mach.h>
#include "../common.h"
#include "reporting.h"


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

void gatherUnsymbolicatedCrashlogs(NSString *outputDirectory, NSArray *alreadyUploaded)
{
    // Find unsymbolicated crash reports
    NSString *unsymbolicatedLogsPath = @"/var/mobile/Library/Logs/CrashReporter";
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:unsymbolicatedLogsPath error:nil])
    {
        if ([alreadyUploaded containsObject:file])
        {
            continue;
        }

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

        NSString *outputFile = [NSString stringWithFormat:@"%@/%@", outputDirectory, file];
        writeSymbolicatedLogToFile(crashlogContents, outputFile);
    }
}

void gatherCr4shedLogs(NSString *outputDirectory, NSArray *alreadyUploaded)
{
    NSString *unsymbolicatedLogsPath = @"/var/mobile/Library/Cr4shed";
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:unsymbolicatedLogsPath error:nil])
    {
        if ([alreadyUploaded containsObject:file])
        {
            continue;
        }

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

        // Skip the crash if the tweak wasn't responsible
        NSString *crashlogContents = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:nil];
        if (![crashlogContents containsString:@"Culprit: carplayenable.dylib"])
        {
            continue;
        }

        NSString *outputFile = [NSString stringWithFormat:@"%@/%@", outputDirectory, file];
        [[NSFileManager defaultManager] copyItemAtPath:fullPath toPath:outputFile error:nil];
    }
}

void symbolicateAndUploadCrashlogs(void)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Setup a tmp directory to contain the gathered crash reports
        NSString *crashReportsStash = @"/tmp/crash_reports";
        if ([[NSFileManager defaultManager] fileExistsAtPath:crashReportsStash])
        {
            [[NSFileManager defaultManager] removeItemAtPath:crashReportsStash error:nil];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:crashReportsStash withIntermediateDirectories:NO attributes:nil error:NULL];

        // Keep track of which logs have already been uploaded, to avoid duplicate work
        NSMutableArray *uploadedLogFileNames = [[NSMutableArray alloc] init];
        if ([[NSFileManager defaultManager] fileExistsAtPath:UPLOADED_LOGS_PLIST_PATH])
        {
            uploadedLogFileNames = [[NSArray arrayWithContentsOfFile:UPLOADED_LOGS_PLIST_PATH] mutableCopy];
        }

        // Gather logs from all sources
        gatherUnsymbolicatedCrashlogs(crashReportsStash, uploadedLogFileNames);
        gatherCr4shedLogs(crashReportsStash, uploadedLogFileNames);

        NSArray *reports = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:crashReportsStash error:nil];
        
        // Update the uploaded-files cache
        [uploadedLogFileNames addObjectsFromArray:reports];
        [uploadedLogFileNames writeToFile:UPLOADED_LOGS_PLIST_PATH atomically:YES];

        if ([reports count] > 0)
        {
            // Archive them
            NSString *archivePath = @"/tmp/crash_reports.tar.gz";

            id task = [[objc_getClass("NSTask") alloc] init];
            objcInvoke_1(task, @"setLaunchPath:", @"/bin/sh");
            NSString *tarCommand = [NSString stringWithFormat:@"tar cfz %@ -C /tmp/ crash_reports", archivePath];
            NSArray *args = @[@"--login", @"-c", tarCommand];
            objcInvoke_1(task, @"setArguments:", args);
            objcInvoke(task, @"launch");
            objcInvoke(task, @"waitUntilExit");
            int status = objcInvokeT(task, @"terminationStatus", int);
            if (status == 0)
            {
                // Upload the archive
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:CRASH_REPORT_URL]];
                [request setHTTPMethod:@"POST"];
                NSURLSessionUploadTask *uploadTask = [[NSURLSession sharedSession] uploadTaskWithRequest:request fromFile:[NSURL URLWithString:archivePath] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    // Delete the archive when the upload completes
                    if ([[NSFileManager defaultManager] fileExistsAtPath:archivePath])
                    {
                        [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
                    }
                }];
                [uploadTask resume];
            }
        }
    
        [[NSFileManager defaultManager] removeItemAtPath:crashReportsStash error:nil];
    });
}