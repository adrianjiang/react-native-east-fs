#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef void (^DownloadCompleteCallback)(NSNumber*, NSNumber*);
typedef void (^ErrorCallback)(NSError*);
typedef void (^BeginCallback)(NSNumber*, NSNumber*, NSDictionary*);
typedef void (^ProgressCallback)(NSNumber*, NSNumber*);
typedef void (^ResumableCallback)();


@class RNFSDownloadParams;
@class CDVFileTransferEntityLengthRequest;
@interface RNFSDownloader : NSObject <NSURLSessionDelegate, NSURLSessionDownloadDelegate>

- (NSString *)downloadFile:(RNFSDownloadParams*)params;
- (void)stopDownload;
- (void)resumeDownload;
- (BOOL)isResumable;

@property (nonatomic, strong) NSOperationQueue* queue;
@property (readonly) NSMutableDictionary* activeTransfers;

@end

@interface RNFSDownloadParams : NSObject

@property (copy) NSString* fromUrl;
@property (copy) NSString* toFile;
@property (copy) NSDictionary* headers;
@property (copy) DownloadCompleteCallback completeCallback;   // Download has finished (data written)
@property (copy) ErrorCallback errorCallback;                 // Something went wrong
@property (copy) BeginCallback beginCallback;                 // Download has started (headers received)
@property (copy) ProgressCallback progressCallback;           // Download is progressing
@property (copy) ResumableCallback resumableCallback;         // Download has stopped but is resumable
@property        bool background;                             // Whether to continue download when app is in background
@property        bool discretionary;                          // Whether the file may be downloaded at the OS's discretion (iOS only)
@property (copy) NSNumber* progressDivider;
@property (copy) NSNumber* readTimeout;
@property (copy) NSNumber* lastProgressValue;

//add new download
@property (nonatomic, strong) NSURLConnection* connection;
@property (nonatomic, copy) NSString* mimeType;
@property (assign) int responseCode; // atomic
@property (nonatomic, assign) long long bytesTransfered;
@property (nonatomic, assign) long long bytesExpected;
@property (nonatomic, assign) long long partialDownloadSize;
@property (strong) NSFileHandle* targetFileHandle;
@property (strong) NSMutableData* responseData; // atomic
@property (nonatomic, strong) NSDictionary* responseHeaders;
@property (nonatomic, copy) NSString* objectId;
@property (nonatomic, strong) RNFSDownloader* command;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskID;
@property (nonatomic, strong) CDVFileTransferEntityLengthRequest* entityLengthRequest;
@property (nonatomic, assign) BOOL trustAllHosts;

- (void)updateBytesExpected:(long long)newBytesExpected;
- (void)cancelTransfer:(NSURLConnection*)connection;


@end



