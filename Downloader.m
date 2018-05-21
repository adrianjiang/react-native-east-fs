#import "Downloader.h"



@interface CDVFileTransferEntityLengthRequest : NSObject {
    NSURLConnection* _connection;
    RNFSDownloadParams* __weak _originalDelegate;
}

- (CDVFileTransferEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(RNFSDownloadParams*)originalDelegate;

@end

@implementation CDVFileTransferEntityLengthRequest

- (CDVFileTransferEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(RNFSDownloadParams*)originalDelegate
{
    if (self) {
        //DLog(@"Requesting entity length for GZIPped content...");
        
        NSMutableURLRequest* req = [originalRequest mutableCopy];
        [req setHTTPMethod:@"HEAD"];
        [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        
        _originalDelegate = originalDelegate;
        _connection = [NSURLConnection connectionWithRequest:req delegate:self];
    }
    return self;
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    NSLog(@"HEAD request returned; content-length is %lld", [response expectedContentLength]);
    [_originalDelegate updateBytesExpected:[response expectedContentLength]];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{}

@end


//**************************************************************************
@interface RNFSDownloader()

@property (copy) RNFSDownloadParams* params;

@property (retain) NSURLSession* session;
@property (retain) NSURLSessionDownloadTask* task;
@property (retain) NSNumber* statusCode;
@property (retain) NSNumber* contentLength;
@property (retain) NSNumber* bytesWritten;
@property (retain) NSData* resumeData;

@property (retain) NSFileHandle* fileHandle;

@end

@implementation RNFSDownloadParams
@synthesize command,objectId,backgroundTaskID;

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    NSString* uploadResponse = nil;
    NSString* downloadResponse = nil;
    NSMutableDictionary* uploadResult;
    
    
    NSLog(@"File Transfer Finished with response code %d", self.responseCode);
    
    
        if (self.targetFileHandle) {
            [self.targetFileHandle closeFile];
            self.targetFileHandle = nil;
            NSLog(@"File Transfer Download success");
            
            //result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self.filePlugin makeEntryForURL:self.targetURL]];
        } else {
            downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
            //result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:downloadResponse]];
        }
 
    
    // remove connection for activeTransfers
    @synchronized (command.activeTransfers) {
        [command.activeTransfers removeObjectForKey:objectId];
        // remove background id task in case our upload was done in the background
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskID];
        self.backgroundTaskID = UIBackgroundTaskInvalid;
    }
}

- (void)cancelTransfer:(NSURLConnection*)connection
{
    [connection cancel];
    if (self.targetFileHandle) {
        [self.targetFileHandle closeFile];
        self.targetFileHandle = nil;
        NSLog(@"File Transfer cancel close success");
    }
    @synchronized (self.command.activeTransfers) {
       RNFSDownloadParams* delegate = self.command.activeTransfers[self.objectId];
        [self.command.activeTransfers removeObjectForKey:self.objectId];
        [[UIApplication sharedApplication] endBackgroundTask:delegate.backgroundTaskID];
        delegate.backgroundTaskID = UIBackgroundTaskInvalid;
    }
    self.bytesTransfered = 0;
}

- (void)cancelTransferWithError:(NSURLConnection*)connection errorMessage:(NSString*)errorMessage
{
    /*
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsDictionary:[self.command createFileTransferError:FILE_NOT_FOUND_ERR AndSource:self.source AndTarget:self.target AndHttpStatus:self.responseCode AndBody:errorMessage]];
    
    NSLog(@"File Transfer Error: %@", errorMessage);
    [self cancelTransfer:connection];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];*/
    
    NSError* error = [NSError errorWithDomain:@"Downloader" code:NSURLErrorFileDoesNotExist
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"Failed to tracsfere data: %@", errorMessage]}];
    
    self.errorCallback(error);
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    NSError* __autoreleasing error = nil;
    
    self.mimeType = [response MIMEType];
    self.targetFileHandle = nil;
    
    // required for iOS 4.3, for some reason; response is
    // a plain NSURLResponse, not the HTTP subclass
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
        
        self.responseCode = [httpResponse statusCode];
        self.bytesExpected = [response expectedContentLength]+self.partialDownloadSize;
        self.responseHeaders = [httpResponse allHeaderFields];
        if ((self.responseCode == 200) && (self.bytesExpected == NSURLResponseUnknownLength))
        {
            // Kick off HEAD request to server to get real length
            // bytesExpected will be updated when that response is returned
            self.entityLengthRequest = [[CDVFileTransferEntityLengthRequest alloc] initWithOriginalRequest:connection.currentRequest andDelegate:self];
            
            //self.beginCallback([NSNumber numberWithInt:self.responseCode], [NSNumber numberWithLong:self.bytesExpected], self.responseHeaders);
        }
    } else if ([response.URL isFileURL]) {
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[response.URL path] error:nil];
        self.responseCode = 200;
        self.bytesExpected = [attr[NSFileSize] longLongValue];
    } else {
        self.responseCode = 200;
        self.bytesExpected = NSURLResponseUnknownLength;
    }
    if ((self.responseCode >= 200) && (self.responseCode < 300)) {
        // Download response is okay; begin streaming output to file
        NSString *filePath = self.toFile;
        if (filePath == nil) {
            // We couldn't find the asset.  Send the appropriate error.
            [self cancelTransferWithError:connection errorMessage:[NSString stringWithFormat:@"Could not create target file"]];
            return;
        }
        
        NSString* parentPath = [filePath stringByDeletingLastPathComponent];
        
        // create parent directories if needed
        if ([[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error] == NO) {
            if (error) {
                [self cancelTransferWithError:connection errorMessage:[NSString stringWithFormat:@"Could not create path to save downloaded file: %@", [error localizedDescription]]];
            } else {
                [self cancelTransferWithError:connection errorMessage:@"Could not create path to save downloaded file"];
            }
            return;
        }
        if (self.partialDownloadSize==0)
        {   // create target file
            if ([[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil] == NO)
            {
                [self cancelTransferWithError:connection errorMessage:@"Could not create target file"];
                return;
            }
        }
        
        // open target file for writing
        self.targetFileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        //offset file
        if (self.responseCode>200) {
            [self.targetFileHandle seekToFileOffset:self.partialDownloadSize];
            self.bytesTransfered = self.partialDownloadSize;
        }
        if (self.targetFileHandle == nil) {
            [self cancelTransferWithError:connection errorMessage:@"Could not open target file for writing"];
        }
        self.beginCallback([NSNumber numberWithInt:self.responseCode], [NSNumber numberWithLong:self.bytesExpected], self.responseHeaders);
        NSLog(@"Streaming to file %@", filePath);
    }
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
    /*
    NSString* body = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:body]];*/
    
    NSError* error1 = [NSError errorWithDomain:@"Downloader" code:NSURLErrorFileDoesNotExist
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"Failed to connect responseCode: %d", self.responseCode]}];
    
    self.errorCallback(error1);
    
    NSLog(@"File Transfer Error: %@", [error localizedDescription]);
    
    [self cancelTransfer:connection];
    
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
    self.bytesTransfered += data.length;
    if (self.targetFileHandle) {
        [self.targetFileHandle writeData:data];
    } else {
        [self.responseData appendData:data];
    }
    NSLog(@"downloading bytesTransfered to %lld-------%lld", self.bytesTransfered,self.bytesExpected);
    [self updateProgress];
}

- (void)updateBytesExpected:(long long)newBytesExpected
{
    NSLog(@"Updating bytesExpected to %lld", newBytesExpected);
    self.bytesExpected = newBytesExpected;
    [self updateProgress];
}

- (void)updateProgress
{
   
        BOOL lengthComputable = (self.bytesExpected != NSURLResponseUnknownLength);
        // If the response is GZipped, and we have an outstanding HEAD request to get
        // the length, then hold off on sending progress events.
        if (!lengthComputable && (self.entityLengthRequest != nil)) {
            return;
        }
         /*NSMutableDictionary* downloadProgress = [NSMutableDictionary dictionaryWithCapacity:3];
        [downloadProgress setObject:[NSNumber numberWithBool:lengthComputable] forKey:@"lengthComputable"];
        [downloadProgress setObject:[NSNumber numberWithLongLong:self.bytesTransfered] forKey:@"loaded"];
        [downloadProgress setObject:[NSNumber numberWithLongLong:self.bytesExpected] forKey:@"total"];
       CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:downloadProgress];
        [result setKeepCallbackAsBool:true];
        [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];*/
    
    if (self.progressDivider.integerValue <= 0) {
        return self.progressCallback([NSNumber numberWithLongLong:self.bytesExpected], [NSNumber numberWithLongLong:self.bytesTransfered] );
    } else {
        double doubleBytesWritten = self.bytesTransfered;
        double doubleContentLength = self.bytesExpected;
        double doublePercents = doubleBytesWritten / doubleContentLength * 100;
        NSNumber* progress = [NSNumber numberWithUnsignedInt: floor(doublePercents)];
        if ([progress unsignedIntValue] % [self.progressDivider integerValue] == 0) {
            if (([progress unsignedIntValue] != [_lastProgressValue unsignedIntValue]) || (self.bytesTransfered == self.bytesExpected)) {
                NSLog(@"---Progress callback EMIT--- %zu", [progress unsignedIntValue]);
                _lastProgressValue = [NSNumber numberWithUnsignedInt:[progress unsignedIntValue]];
                return self.progressCallback([NSNumber numberWithLongLong:self.bytesExpected], [NSNumber numberWithLongLong:self.bytesTransfered] );
            }
        }
    }
}

- (void)connection:(NSURLConnection*)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{

    self.bytesTransfered = totalBytesWritten;
}

// for self signed certificates
- (void)connection:(NSURLConnection*)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (self.trustAllHosts) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        }
        [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } else {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
    }
}

@end



@implementation RNFSDownloader
@synthesize activeTransfers;

- (NSString *)downloadFile:(RNFSDownloadParams*)params
{
    NSString *uuid = nil;
    
    _params = params;
    
    _bytesWritten = 0;
    
    NSURL* sourceURL = [NSURL URLWithString:_params.fromUrl];
    NSString *targetFile = _params.toFile;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:_params.toFile]) {
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:_params.toFile];
        
        if (!_fileHandle) {
            NSError* error = [NSError errorWithDomain:@"Downloader" code:NSURLErrorFileDoesNotExist
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"Failed to write target file at path: %@", _params.toFile]}];
            
            _params.errorCallback(error);
            return nil;
        } else {
            [_fileHandle closeFile];
        }
    }
    
    // Should this request resume an existing download?
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    NSDictionary* headers  = nil;
    unsigned long long fileSize=0;
    if (_params.toFile) {
        
        NSError *err = nil;
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:_params.toFile error:&err];
        
        fileSize = [attr[NSFileSize] longLongValue];
        if (fileSize>0) {
            if (err) {
                NSLog(@"FileTransferError %@", err);
                
            }
            else {
                if (headers ==nil)
                    headers = [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"bytes=%llu-",fileSize],@"Range",nil];
                else
                    [headers setValue:[NSString stringWithFormat:@"bytes=%llu-",fileSize] forKey:@"Range"];
            }
        }

    }
    
    _params.command = self;
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:sourceURL];
    [self applyRequestHeaders:headers toRequest:req];
    [req setTimeoutInterval:6.0f];
 
    _params.connection = [[NSURLConnection alloc] initWithRequest:req delegate:_params startImmediately:NO];
    
    if (self.queue == nil) {
        self.queue = [[NSOperationQueue alloc] init];
    }
    [_params.connection setDelegateQueue:self.queue];
    
    if (activeTransfers==nil)
       activeTransfers = [[NSMutableDictionary alloc] init];
    
    _params.partialDownloadSize = fileSize;
 
    /*_params.backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [_params cancelTransfer:_params.connection];
    }];*/


    _params.objectId = [[NSUUID UUID] UUIDString];
    @synchronized (activeTransfers) {
        activeTransfers[_params.objectId] = _params;
    }
    // Downloads can take time
    // sending this to a new thread calling the download_async method
    dispatch_async(
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, (unsigned long)NULL),
                   ^(void) { [_params.connection start];}
                   );
    
    return _params.objectId;

}

- (void)stopDownload
{
    [_params cancelTransfer:_params.connection];
}


- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req
{
    //[req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    
//    NSString* userAgent = [self.commandDelegate userAgent];
//    if (userAgent) {
//        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
//    }
    
    for (NSString* headerName in headers) {
        id value = [headers objectForKey:headerName];
        if (!value || (value == [NSNull null])) {
            value = @"null";
        }
        
        // First, remove an existing header if one exists.
        [req setValue:nil forHTTPHeaderField:headerName];
        
        if (![value isKindOfClass:[NSArray class]]) {
            value = [NSArray arrayWithObject:value];
        }
        
        // Then, append all header values.
        for (id __strong subValue in value) {
            // Convert from an NSNumber -> NSString.
            if ([subValue respondsToSelector:@selector(stringValue)]) {
                subValue = [subValue stringValue];
            }
            if ([subValue isKindOfClass:[NSString class]]) {
                [req addValue:subValue forHTTPHeaderField:headerName];
            }
        }
    }
}
@end




/*
- (NSString *)downloadFile:(RNFSDownloadParams*)params
{
    NSString *uuid = nil;
    
    _params = params;

  _bytesWritten = 0;

  NSURL* url = [NSURL URLWithString:_params.fromUrl];

  if ([[NSFileManager defaultManager] fileExistsAtPath:_params.toFile]) {
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:_params.toFile];

    if (!_fileHandle) {
      NSError* error = [NSError errorWithDomain:@"Downloader" code:NSURLErrorFileDoesNotExist
                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"Failed to write target file at path: %@", _params.toFile]}];

      _params.errorCallback(error);
      return nil;
    } else {
      [_fileHandle closeFile];
    }
  }

  NSURLSessionConfiguration *config;
  if (_params.background) {
    uuid = [[NSUUID UUID] UUIDString];
    config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:uuid];
    config.discretionary = _params.discretionary;
  } else {
    config = [NSURLSessionConfiguration defaultSessionConfiguration];
  }

  config.HTTPAdditionalHeaders = _params.headers;
  config.timeoutIntervalForRequest = [_params.readTimeout intValue] / 1000.0;

  _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
  _task = [_session downloadTaskWithURL:url];
  [_task resume];
    
    return uuid;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)downloadTask.response;
  if (!_statusCode) {
    _statusCode = [NSNumber numberWithLong:httpResponse.statusCode];
    _contentLength = [NSNumber numberWithLong:httpResponse.expectedContentLength];
    return _params.beginCallback(_statusCode, _contentLength, httpResponse.allHeaderFields);
  }

  if ([_statusCode isEqualToNumber:[NSNumber numberWithInt:200]]) {
    _bytesWritten = @(totalBytesWritten);

    if (_params.progressDivider.integerValue <= 0) {
      return _params.progressCallback(_contentLength, _bytesWritten);
    } else {
      double doubleBytesWritten = (double)[_bytesWritten longValue];
      double doubleContentLength = (double)[_contentLength longValue];
      double doublePercents = doubleBytesWritten / doubleContentLength * 100;
      NSNumber* progress = [NSNumber numberWithUnsignedInt: floor(doublePercents)];
      if ([progress unsignedIntValue] % [_params.progressDivider integerValue] == 0) {
        if (([progress unsignedIntValue] != [_lastProgressValue unsignedIntValue]) || ([_bytesWritten unsignedIntegerValue] == [_contentLength longValue])) {
          NSLog(@"---Progress callback EMIT--- %zu", [progress unsignedIntValue]);
          _lastProgressValue = [NSNumber numberWithUnsignedInt:[progress unsignedIntValue]];
          return _params.progressCallback(_contentLength, _bytesWritten);
        }
      }
    }
  }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)downloadTask.response;
  if (!_statusCode) {
    _statusCode = [NSNumber numberWithLong:httpResponse.statusCode];
  }
  NSURL *destURL = [NSURL fileURLWithPath:_params.toFile];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  if([_statusCode integerValue] >= 200 && [_statusCode integerValue] < 300) {
    [fm removeItemAtURL:destURL error:nil];       // Remove file at destination path, if it exists
    [fm moveItemAtURL:location toURL:destURL error:&error];
  }
  if (error) {
    NSLog(@"RNFS download: unable to move tempfile to destination. %@, %@", error, error.userInfo);
  }

  return _params.completeCallback(_statusCode, _bytesWritten);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
  if (error && error.code != -999) {
      _resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
      if (_resumeData != nil) {
          _params.resumableCallback();
      } else {
          _params.errorCallback(error);
      }
  }
}

- (void)stopDownload
{
  if (_task.state == NSURLSessionTaskStateRunning) {
    [_task cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
        if (resumeData != nil) {
            self.resumeData = resumeData;
            _params.resumableCallback();
        } else {
            NSError *error = [NSError errorWithDomain:@"RNFS"
                                                 code:@"Aborted"
                                             userInfo:@{
                                                        NSLocalizedDescriptionKey: @"Download has been aborted"
                                                        }];
            
            _params.errorCallback(error);
        }
    }];

  }
}

- (void)resumeDownload
{
    if (_resumeData != nil) {
        _task = [_session downloadTaskWithResumeData:_resumeData];
        [_task resume];
        _resumeData = nil;
    }
}

- (BOOL)isResumable
{
    return _resumeData != nil;
}

@end*/
