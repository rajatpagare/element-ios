/*
 Copyright 2017 Aram Sargsyan
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

@import MobileCoreServices;

#import <mach/mach.h>

#import <MatrixKit/MatrixKit.h>

#import "ShareManager.h"
#import "ShareViewController.h"
#import "ShareDataSource.h"

#ifdef IS_SHARE_EXTENSION
#import "RiotShareExtension-Swift.h"
#else
#import "Riot-Swift.h"
#endif

static const CGFloat kLargeImageSizeMaxDimension = 2048.0;

typedef NS_ENUM(NSInteger, ImageCompressionMode)
{
    ImageCompressionModeNone,
    ImageCompressionModeSmall,
    ImageCompressionModeMedium,
    ImageCompressionModeLarge
};

@interface ShareManager () <ShareViewControllerDelegate>

@property (nonatomic, strong, readonly) id<ShareItemProviderProtocol> shareItemProvider;
@property (nonatomic, strong, readonly) ShareViewController *shareViewController;

@property (nonatomic, strong, readonly) NSMutableArray<NSData *> *pendingImages;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSNumber *> *imageUploadProgresses;
@property (nonatomic, strong, readonly) id<Configurable> configuration;

@property (nonatomic, strong) MXKAccount *userAccount;
@property (nonatomic, strong) MXFileStore *fileStore;

@property (nonatomic, assign) ImageCompressionMode imageCompressionMode;
@property (nonatomic, assign) CGFloat actualLargeSize;

@end


@implementation ShareManager

- (instancetype)initWithShareItemProvider:(id<ShareItemProviderProtocol>)shareItemProvider
{
    if (self = [super init])
    {
        _shareItemProvider = shareItemProvider;
        
        _pendingImages = [NSMutableArray array];
        _imageUploadProgresses = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onMediaLoaderStateDidChange:) name:kMXMediaLoaderStateDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkUserAccount) name:kMXKAccountManagerDidRemoveAccountNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkUserAccount) name:NSExtensionHostWillEnterForegroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        
        _configuration = [[CommonConfiguration alloc] init];
        [_configuration setupSettings];
        
        // NSLog -> console.log file when not debugging the app
        MXLogConfiguration *configuration = [[MXLogConfiguration alloc] init];
        configuration.logLevel = MXLogLevelVerbose;
        configuration.logFilesSizeLimit = 0;
        configuration.maxLogFilesCount = 10;
        configuration.subLogName = @"share";
        
        // Redirect NSLogs to files only if we are not debugging
        if (!isatty(STDERR_FILENO)) {
            configuration.redirectLogsToFiles = YES;
        }
        
        [MXLog configure:configuration];
        
        _shareViewController = [[ShareViewController alloc] initWithType:ShareViewControllerTypeSend
                                                            currentState:ShareViewControllerAccountStateNotConfigured];
        [_shareViewController setDelegate:self];
        
        // Set up runtime language on each context update.
        NSUserDefaults *sharedUserDefaults = [MXKAppSettings standardAppSettings].sharedUserDefaults;
        NSString *language = [sharedUserDefaults objectForKey:@"appLanguage"];
        [NSBundle mxk_setLanguage:language];
        [NSBundle mxk_setFallbackLanguage:@"en"];
        
        // Check the current matrix user.
        [self checkUserAccount];
    }
    
    return self;
}

#pragma mark - Public

- (UIViewController *)mainViewController
{
    return self.shareViewController;
}

#pragma mark - ShareViewControllerDelegate

- (void)shareViewControllerDidRequestShare:(ShareViewController *)shareViewController
                         forRoomIdentifier:(NSString *)roomIdentifier
{
    MXSession *session = [[MXSession alloc] initWithMatrixRestClient:[[MXRestClient alloc] initWithCredentials:self.userAccount.mxCredentials andOnUnrecognizedCertificateBlock:nil]];
    [MXFileStore setPreloadOptions:0];
    
    MXWeakify(session);
    [session setStore:self.fileStore success:^{
        MXStrongifyAndReturnIfNil(session);
        
        session.crypto.warnOnUnknowDevices = NO; // Do not warn for unknown devices. We have cross-signing now
        
        MXRoom *selectedRoom = [MXRoom loadRoomFromStore:self.fileStore withRoomId:roomIdentifier matrixSession:session];
        [self sendContentToRoom:selectedRoom success:nil failure:^(NSError *error){
            [self showFailureAlert:[VectorL10n roomEventFailedToSend]];
        }];
    } failure:^(NSError *error) {
        MXLogError(@"[ShareManager] Failed preparign matrix session");
    }];
}

- (void)shareViewControllerDidRequestDismissal:(ShareViewController *)shareViewController
{
    self.completionCallback(ShareManagerResultCancelled);
}

#pragma mark - Private

- (void)sendContentToRoom:(MXRoom *)room success:(void(^)(void))success failure:(void(^)(NSError *))failure
{
    [self resetPendingData];
    
    NSMutableArray <id<ShareItemProtocol>> *pendingImagesItemProviders = [NSMutableArray array]; // Used to keep the items associated to pending images (used only when all items are images).
    
    __block NSError *firstRequestError = nil;
    dispatch_group_t dispatchGroup = dispatch_group_create();
    
    void (^requestFailure)(NSError*) = ^(NSError *requestError) {
        if (requestError && !firstRequestError)
        {
            firstRequestError = requestError;
        }
        
        dispatch_group_leave(dispatchGroup);
    };
    
    MXWeakify(self);
    for (id<ShareItemProtocol> item in self.shareItemProvider.items)
    {
        if (item.type == ShareItemTypeFileURL) {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSURL *url, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendFileWithUrl:url toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
        
        if (item.type == ShareItemTypeText) {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSString *text, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendText:text toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
        
        if (item.type == ShareItemTypeURL)
        {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSURL *url, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendText:url.absoluteString toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
        
        if (item.type == ShareItemTypeImage)
        {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(id<NSSecureCoding> itemProviderItem, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                NSData *imageData;
                if ([(NSObject *)itemProviderItem isKindOfClass:[NSData class]])
                {
                    imageData = (NSData*)itemProviderItem;
                }
                else if ([(NSObject *)itemProviderItem isKindOfClass:[NSURL class]])
                {
                    NSURL *imageURL = (NSURL*)itemProviderItem;
                    imageData = [NSData dataWithContentsOfURL:imageURL];
                }
                else if ([(NSObject *)itemProviderItem isKindOfClass:[UIImage class]])
                {
                    // An application can share directly an UIImage.
                    // The most common case is screenshot sharing without saving to file.
                    // As screenshot using PNG format when they are saved to file we also use PNG format when saving UIImage to NSData.
                    UIImage *image = (UIImage*)itemProviderItem;
                    imageData = UIImagePNGRepresentation(image);
                }
                
                MXStrongifyAndReturnIfNil(self);
                
                if (imageData)
                {
                    if ([self.shareItemProvider areAllItemsImages])
                    {
                        [self.pendingImages addObject:imageData];
                        [pendingImagesItemProviders addObject:item];
                    }
                    else
                    {
                        CGSize imageSize = [self imageSizeFromImageData:imageData];
                        self.imageCompressionMode = ImageCompressionModeNone;
                        self.actualLargeSize = MAX(imageSize.width, imageSize.height);
                        
                        [self sendImageData:imageData withItem:item toRoom:room success:^{
                            dispatch_group_leave(dispatchGroup);
                        } failure:requestFailure];
                    }
                }
                else
                {
                    MXLogError(@"[ShareManager] sendContentToRoom: failed to loadItemForTypeIdentifier. Error: %@", error);
                    dispatch_group_leave(dispatchGroup);
                }
                
                // Only prompt for image resize if all items are images
                // Ignore showMediaCompressionPrompt setting due to memory constraints with full size images.
                if ([self.shareItemProvider areAllItemsImages])
                {
                    if ([self.shareItemProvider areAllItemsLoaded])
                    {
                        UIAlertController *compressionPrompt = [self compressionPromptForPendingImagesWithShareBlock:^{
                            [self sendImageDatas:self.pendingImages.copy withItems:pendingImagesItemProviders toRoom:room success:^{
                                dispatch_group_leave(dispatchGroup);
                            } failure:requestFailure];
                        }];
                        
                        if (compressionPrompt)
                        {
                            [self presentCompressionPrompt:compressionPrompt];
                        }
                    }
                    else
                    {
                        dispatch_group_leave(dispatchGroup);
                    }
                }
            }];
        }
        
        if (item.type == ShareItemTypeVideo)
        {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSURL *videoLocalUrl, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendVideo:videoLocalUrl toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
        
        if (item.type == ShareItemTypeMovie)
        {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSURL *videoLocalUrl, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendVideo:videoLocalUrl toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
        
        if (item.type == ShareItemTypeVoiceMessage)
        {
            dispatch_group_enter(dispatchGroup);
            [self.shareItemProvider loadItem:item completion:^(NSURL *fileURL, NSError *error) {
                if (error) {
                    requestFailure(error);
                    dispatch_group_leave(dispatchGroup);
                    return;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    MXStrongifyAndReturnIfNil(self);
                    [self sendVoiceMessage:fileURL toRoom:room success:^{
                        dispatch_group_leave(dispatchGroup);
                    } failure:requestFailure];
                });
            }];
        }
    }
    
    dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^{
        [self resetPendingData];
        
        if (firstRequestError)
        {
            failure(firstRequestError);
        }
        else
        {
            self.completionCallback(ShareManagerResultFinished);
        }
    });
}

- (void)showFailureAlert:(NSString *)title
{
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    MXWeakify(self);
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:[MatrixKitL10n ok] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        MXStrongifyAndReturnIfNil(self);
        
        if (self.completionCallback)
        {
            self.completionCallback(ShareManagerResultFailed);
        }
    }];
    
    [alertController addAction:okAction];
    
    [self.mainViewController presentViewController:alertController animated:YES completion:nil];
}

- (void)checkUserAccount
{
    // Force account manager to reload account from the local storage.
    [[MXKAccountManager sharedManager] forceReloadAccounts];
    
    if (self.userAccount)
    {
        // Check whether the used account is still the first active one
        MXKAccount *firstAccount = [MXKAccountManager sharedManager].activeAccounts.firstObject;
        
        // Compare the access token
        if (!firstAccount || ![self.userAccount.mxCredentials.accessToken isEqualToString:firstAccount.mxCredentials.accessToken])
        {
            // Remove this account
            self.userAccount = nil;
        }
    }
    
    if (!self.userAccount)
    {
        // We consider the first enabled account.
        // TODO: Handle multiple accounts
        self.userAccount = [MXKAccountManager sharedManager].activeAccounts.firstObject;
    }
    
    // Reset the file store to reload the room data.
    if (_fileStore)
    {
        [_fileStore close];
        _fileStore = nil;
    }
    
    if (self.userAccount)
    {
        _fileStore = [[MXFileStore alloc] initWithCredentials:self.userAccount.mxCredentials];
        
        ShareDataSource *roomDataSource = [[ShareDataSource alloc] initWithMode:DataSourceModeRooms
                                                                      fileStore:_fileStore
                                                                    credentials:self.userAccount.mxCredentials];
        
        ShareDataSource *peopleDataSource = [[ShareDataSource alloc] initWithMode:DataSourceModePeople
                                                                        fileStore:_fileStore
                                                                      credentials:self.userAccount.mxCredentials];
        
        [self.shareViewController configureWithState:ShareViewControllerAccountStateConfigured
                                      roomDataSource:roomDataSource
                                    peopleDataSource:peopleDataSource];
    } else {
        [self.shareViewController configureWithState:ShareViewControllerAccountStateNotConfigured
                                      roomDataSource:nil
                                    peopleDataSource:nil];
    }
}

- (void)resetPendingData
{
    [self.pendingImages removeAllObjects];
    [self.imageUploadProgresses removeAllObjects];
}

- (BOOL)isAPendingImageNotOrientedUp
{
    BOOL isAPendingImageNotOrientedUp = NO;
    
    for (NSData *imageData in self.pendingImages)
    {
        if ([self isImageOrientationNotUpOrUndeterminedForImageData:imageData])
        {
            isAPendingImageNotOrientedUp = YES;
            break;
        }
    }
    
    return isAPendingImageNotOrientedUp;
}

// TODO: When select multiple images:
// - Enhance prompt to display sum of all file sizes for each compression.
// - Find a way to choose compression sizes for all images.
- (UIAlertController *)compressionPromptForPendingImagesWithShareBlock:(void(^)(void))shareBlock
{
    if (!self.pendingImages.count)
    {
        return nil;
    }
    
    BOOL isAPendingImageNotOrientedUp = [self isAPendingImageNotOrientedUp];
    
    NSData *firstImageData = self.pendingImages.firstObject;
    UIImage *firstImage = [UIImage imageWithData:firstImageData];
    
    MXKImageCompressionSizes compressionSizes = [MXKTools availableCompressionSizesForImage:firstImage originalFileSize:firstImageData.length];
    
    if (compressionSizes.small.fileSize == 0 && compressionSizes.medium.fileSize == 0 && compressionSizes.large.fileSize == 0)
    {
        if (isAPendingImageNotOrientedUp && self.pendingImages.count > 1)
        {
            self.imageCompressionMode = ImageCompressionModeSmall;
        }
        else
        {
            self.imageCompressionMode = ImageCompressionModeNone;
        }
        
        MXLogDebug(@"[ShareManager] Send %lu image(s) without compression prompt using compression mode: %ld", (unsigned long)self.pendingImages.count, (long)self.imageCompressionMode);
        
        shareBlock();
        
        return nil;
    }
    
    UIAlertController *compressionPrompt = [UIAlertController alertControllerWithTitle:[MatrixKitL10n attachmentSizePromptTitle]
                                                                               message:[MatrixKitL10n attachmentSizePromptMessage]
                                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    
    if (compressionSizes.small.fileSize)
    {
        NSString *title = [MatrixKitL10n attachmentSmall:[MXTools fileSizeToString:compressionSizes.small.fileSize]];
        
        MXWeakify(self);
        [compressionPrompt addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            MXStrongifyAndReturnIfNil(self);
            
            self.imageCompressionMode = ImageCompressionModeSmall;
            [self logCompressionSizeChoice:compressionSizes.large];
            
            shareBlock();
        }]];
    }
    
    if (compressionSizes.medium.fileSize)
    {
        NSString *title = [MatrixKitL10n attachmentMedium:[MXTools fileSizeToString:compressionSizes.medium.fileSize]];
        
        MXWeakify(self);
        [compressionPrompt addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            MXStrongifyAndReturnIfNil(self);
            
            self.imageCompressionMode = ImageCompressionModeMedium;
            [self logCompressionSizeChoice:compressionSizes.large];
            
            shareBlock();
        }]];
    }
    
    // Do not offer the possibility to resize an image with a dimension above kLargeImageSizeMaxDimension, to prevent the risk of memory limit exception.
    // TODO: Remove this condition when issue https://github.com/vector-im/riot-ios/issues/2341 will be fixed.
    if (compressionSizes.large.fileSize && (MAX(compressionSizes.large.imageSize.width, compressionSizes.large.imageSize.height) <= kLargeImageSizeMaxDimension))
    {
        NSString *title = [MatrixKitL10n attachmentLarge:[MXTools fileSizeToString:compressionSizes.large.fileSize]];
        
        MXWeakify(self);
        [compressionPrompt addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            MXStrongifyAndReturnIfNil(self);
            
            self.imageCompressionMode = ImageCompressionModeLarge;
            self.actualLargeSize = compressionSizes.actualLargeSize;
            
            [self logCompressionSizeChoice:compressionSizes.large];
            
            shareBlock();
        }]];
    }
    
    // To limit memory consumption, we suggest the original resolution only if the image orientation is up, or if the image size is moderate
    if (!isAPendingImageNotOrientedUp || !compressionSizes.large.fileSize)
    {
        NSString *fileSizeString = [MXTools fileSizeToString:compressionSizes.original.fileSize];
        
        NSString *title = [MatrixKitL10n attachmentOriginal:fileSizeString];
        
        MXWeakify(self);
        [compressionPrompt addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            MXStrongifyAndReturnIfNil(self);
            
            self.imageCompressionMode = ImageCompressionModeNone;
            [self logCompressionSizeChoice:compressionSizes.large];
            
            shareBlock();
        }]];
    }
    
    [compressionPrompt addAction:[UIAlertAction actionWithTitle:[MatrixKitL10n cancel]
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];
    
    return compressionPrompt;
}

- (void)didStartSendingToRoom:(MXRoom *)room
{
    [self.shareViewController showProgressIndicator];
}

- (NSString*)utiFromImageData:(NSData*)imageData
{
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
    NSString *uti = (NSString*)CGImageSourceGetType(imageSource);
    CFRelease(imageSource);
    return uti;
}

- (NSString*)mimeTypeFromUTI:(NSString*)uti
{
    return (__bridge_transfer NSString *) UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)uti, kUTTagClassMIMEType);
}

- (BOOL)isResizingSupportedForImageData:(NSData*)imageData
{
    NSString *imageUTI = [self utiFromImageData:imageData];
    return [self isResizingSupportedForUTI:imageUTI];
}

- (BOOL)isResizingSupportedForUTI:(NSString*)imageUTI
{
    if ([imageUTI isEqualToString:(__bridge NSString *)kUTTypePNG] || [imageUTI isEqualToString:(__bridge NSString *)kUTTypeJPEG])
    {
        return YES;
    }
    return NO;
}

- (CGSize)imageSizeFromImageData:(NSData*)imageData
{
    CGFloat width = 0.0f;
    CGFloat height = 0.0f;
    
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
    
    CFDictionaryRef imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
    
    CFRelease(imageSource);
    
    if (imageProperties != NULL)
    {
        CFNumberRef widthNumber  = CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelWidth);
        CFNumberRef heightNumber = CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelHeight);
        CFNumberRef orientationNumber = CFDictionaryGetValue(imageProperties, kCGImagePropertyOrientation);
        
        if (widthNumber != NULL)
        {
            CFNumberGetValue(widthNumber, kCFNumberCGFloatType, &width);
        }
        
        if (heightNumber != NULL)
        {
            CFNumberGetValue(heightNumber, kCFNumberCGFloatType, &height);
        }
        
        // Check orientation and flip size if required
        if (orientationNumber != NULL)
        {
            int orientation;
            CFNumberGetValue(orientationNumber, kCFNumberIntType, &orientation);
            
            // For orientation from kCGImagePropertyOrientationLeftMirrored to kCGImagePropertyOrientationLeft flip size
            if (orientation >= 5)
            {
                CGFloat tempWidth = width;
                width = height;
                height = tempWidth;
            }
        }
        
        CFRelease(imageProperties);
    }
    
    return CGSizeMake(width, height);
}

- (NSNumber*)cgImageimageOrientationNumberFromImageData:(NSData*)imageData
{
    NSNumber *orientationNumber;
    
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
    
    CFDictionaryRef imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
    
    CFRelease(imageSource);
    
    if (imageProperties != NULL)
    {
        CFNumberRef orientationNum = CFDictionaryGetValue(imageProperties, kCGImagePropertyOrientation);
        
        // Check orientation and flip size if required
        if (orientationNum != NULL)
        {
            orientationNumber = (__bridge NSNumber *)orientationNum;
        }
        
        CFRelease(imageProperties);
    }
    
    return orientationNumber;
}

- (BOOL)isImageOrientationNotUpOrUndeterminedForImageData:(NSData*)imageData
{
    BOOL isImageNotOrientedUp = YES;
    
    NSNumber *cgImageOrientationNumber = [self cgImageimageOrientationNumberFromImageData:imageData];
    
    if (cgImageOrientationNumber && cgImageOrientationNumber.unsignedIntegerValue == (NSUInteger)kCGImagePropertyOrientationUp)
    {
        isImageNotOrientedUp = NO;
    }
    
    return isImageNotOrientedUp;
}

- (void)logCompressionSizeChoice:(MXKImageCompressionSize)compressionSize
{
    NSString *fileSize = [MXTools fileSizeToString:compressionSize.fileSize round:NO];
    NSUInteger imageWidth = compressionSize.imageSize.width;
    NSUInteger imageHeight = compressionSize.imageSize.height;
    
    MXLogDebug(@"[ShareManager] User choose image compression with output size %lu x %lu (output file size: %@)", (unsigned long)imageWidth, (unsigned long)imageHeight, fileSize);
    MXLogDebug(@"[ShareManager] Number of images to send: %lu", (unsigned long)self.pendingImages.count);
}

// Log memory usage.
// NOTE: This result may not be reliable for all iOS versions (see https://forums.developer.apple.com/thread/64665 for more information).
- (void)logMemoryUsage
{
    struct task_basic_info basicInfo;
    mach_msg_type_number_t size = TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(),
                                   TASK_BASIC_INFO,
                                   (task_info_t)&basicInfo,
                                   &size);
    
    vm_size_t memoryUsedInBytes = basicInfo.resident_size;
    CGFloat memoryUsedInMegabytes = memoryUsedInBytes / (1024*1024);
    
    if (kerr == KERN_SUCCESS)
    {
        MXLogDebug(@"[ShareManager] Memory in use (in MB): %f", memoryUsedInMegabytes);
    }
    else
    {
        MXLogDebug(@"[ShareManager] Error with task_info(): %s", mach_error_string(kerr));
    }
}

- (void)presentCompressionPrompt:(UIAlertController *)compressionPrompt
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [compressionPrompt popoverPresentationController].sourceView = self.mainViewController.view;
        [compressionPrompt popoverPresentationController].sourceRect = self.mainViewController.view.frame;
        [self.mainViewController presentViewController:compressionPrompt animated:YES completion:nil];
    });
}

#pragma mark - Notifications

- (void)onMediaLoaderStateDidChange:(NSNotification *)notification
{
    MXMediaLoader *loader = (MXMediaLoader*)notification.object;
    // Consider only upload progress
    switch (loader.state) {
        case MXMediaLoaderStateUploadInProgress:
        {
            self.imageUploadProgresses[loader.uploadId] = (NSNumber *)loader.statisticsDict[kMXMediaLoaderProgressValueKey];
            
            const NSInteger totalImagesCount = self.pendingImages.count;
            CGFloat totalProgress = 0.0;
            
            for (NSNumber *progress in self.imageUploadProgresses.allValues)
            {
                totalProgress += progress.floatValue/totalImagesCount;
            }
            
            [self.shareViewController setProgress:totalProgress];
            break;
        }
        default:
            break;
    }
}

- (void)didReceiveMemoryWarning:(NSNotification*)notification
{
    MXLogDebug(@"[ShareManager] Did receive memory warning");
    [self logMemoryUsage];
}

#pragma mark - Sharing

- (void)sendText:(NSString *)text
          toRoom:(MXRoom *)room
         success:(dispatch_block_t)success
         failure:(void(^)(NSError *error))failure
{
    [self didStartSendingToRoom:room];
    if (!text)
    {
        MXLogError(@"[ShareManager] Invalid text.");
        failure(nil);
        return;
    }
    
    [room sendTextMessage:text success:^(NSString *eventId) {
        success();
    } failure:^(NSError *error) {
        MXLogError(@"[ShareManager] sendTextMessage failed with error %@", error);
        failure(error);
    }];
}

- (void)sendFileWithUrl:(NSURL *)fileUrl toRoom:(MXRoom *)room
           success:(dispatch_block_t)success
           failure:(void(^)(NSError *error))failure
{
    [self didStartSendingToRoom:room];
    if (!fileUrl)
    {
        MXLogError(@"[ShareManager] Invalid file url.");
        failure(nil);
        return;
    }
    
    NSString *mimeType;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[fileUrl pathExtension] , NULL);
    mimeType = [self mimeTypeFromUTI:(__bridge NSString *)uti];
    CFRelease(uti);
    
    [room sendFile:fileUrl mimeType:mimeType localEcho:nil success:^(NSString *eventId) {
        success();
    } failure:^(NSError *error) {
        MXLogError(@"[ShareManager] sendFile failed with error %@", error);
        failure(error);
    } keepActualFilename:YES];
}

- (void)sendImageData:(NSData *)imageData
             withItem:(id<ShareItemProtocol>)item
               toRoom:(MXRoom *)room
              success:(dispatch_block_t)success
              failure:(void(^)(NSError *error))failure
{
    [self didStartSendingToRoom:room];
    
    NSString *imageUTI;
    NSString *mimeType;
    
    if (!mimeType)
    {
        imageUTI = [self utiFromImageData:imageData];
        if (imageUTI)
        {
            mimeType = [self mimeTypeFromUTI:imageUTI];
        }
    }
    
    if (!mimeType)
    {
        MXLogError(@"[ShareManager] sendImage failed. Cannot determine MIME type of %@", item);
        if (failure)
        {
            failure(nil);
        }
        return;
    }
    
    CGSize imageSize;
    NSData *finalImageData;
    
    // Only resize JPEG or PNG files
    if ([self isResizingSupportedForUTI:imageUTI])
    {
        UIImage *convertedImage;
        CGSize newImageSize;
        
        switch (self.imageCompressionMode) {
            case ImageCompressionModeSmall:
                newImageSize = CGSizeMake(MXKTOOLS_SMALL_IMAGE_SIZE, MXKTOOLS_SMALL_IMAGE_SIZE);
                break;
            case ImageCompressionModeMedium:
                newImageSize = CGSizeMake(MXKTOOLS_MEDIUM_IMAGE_SIZE, MXKTOOLS_MEDIUM_IMAGE_SIZE);
                break;
            case ImageCompressionModeLarge:
                newImageSize = CGSizeMake(self.actualLargeSize, self.actualLargeSize);
                break;
            default:
                newImageSize = CGSizeZero;
                break;
        }
        
        if (CGSizeEqualToSize(newImageSize, CGSizeZero))
        {
            // No resize to make
            // Make sure the uploaded image orientation is up
            if ([self isImageOrientationNotUpOrUndeterminedForImageData:imageData])
            {
                UIImage *image = [UIImage imageWithData:imageData];
                convertedImage = [MXKTools forceImageOrientationUp:image];
            }
        }
        else
        {
            // Resize the image and set image in right orientation too
            convertedImage = [MXKTools resizeImageWithData:imageData toFitInSize:newImageSize];
        }
        
        if (convertedImage)
        {
            if ([imageUTI isEqualToString:(__bridge NSString *)kUTTypePNG])
            {
                finalImageData = UIImagePNGRepresentation(convertedImage);
            }
            else if ([imageUTI isEqualToString:(__bridge NSString *)kUTTypeJPEG])
            {
                finalImageData = UIImageJPEGRepresentation(convertedImage, 0.9);
            }
            
            imageSize = convertedImage.size;
        }
        else
        {
            finalImageData = imageData;
            imageSize = [self imageSizeFromImageData:imageData];
        }
    }
    else
    {
        finalImageData = imageData;
        imageSize = [self imageSizeFromImageData:imageData];
    }
    
    UIImage *thumbnail = nil;
    // Thumbnail is useful only in case of encrypted room
    if (room.summary.isEncrypted)
    {
        thumbnail = [MXKTools resizeImageWithData:imageData toFitInSize:CGSizeMake(800, 600)];
    }
    
    [room sendImage:finalImageData withImageSize:imageSize mimeType:mimeType andThumbnail:thumbnail localEcho:nil success:^(NSString *eventId) {
        success();
    } failure:^(NSError *error) {
        MXLogError(@"[ShareManager] sendImage failed with error %@", error);
        failure(error);
    }];
}

- (void)sendImageDatas:(NSArray<id<ShareItemProtocol>> *)imageDatas
             withItems:(NSArray<id<ShareItemProtocol>> *)items toRoom:(MXRoom *)room
               success:(dispatch_block_t)success
               failure:(void(^)(NSError *error))failure
{
    if (imageDatas.count == 0 || imageDatas.count != items.count)
    {
        MXLogError(@"[ShareManager] sendImages: no images to send.");
        failure(nil);
        return;
    }
    
    [self didStartSendingToRoom:room];
    
    dispatch_group_t requestsGroup = dispatch_group_create();
    __block NSError *firstRequestError;
    
    NSUInteger index = 0;
    
    for (NSData *imageData in imageDatas)
    {
        @autoreleasepool
        {
            dispatch_group_enter(requestsGroup);
            [self sendImageData:imageData withItem:items[index] toRoom:room success:^{
                dispatch_group_leave(requestsGroup);
            } failure:^(NSError *error) {
                if (error && !firstRequestError)
                {
                    firstRequestError = error;
                }
                
               dispatch_group_leave(requestsGroup);
            }];
        }
        
        index++;
    }
    
    dispatch_group_notify(requestsGroup, dispatch_get_main_queue(), ^{
        
        if (firstRequestError)
        {
            failure(firstRequestError);
        }
        else
        {
            success();
        }
    });
}

- (void)sendVideo:(NSURL *)videoLocalUrl
           toRoom:(MXRoom *)room
          success:(dispatch_block_t)success
          failure:(void(^)(NSError *error))failure
{
    AVURLAsset *videoAsset = [[AVURLAsset alloc] initWithURL:videoLocalUrl options:nil];
    
    MXWeakify(self);
    
    // Ignore showMediaCompressionPrompt setting due to memory constraints when encrypting large videos.
    UIAlertController *compressionPrompt = [MXKTools videoConversionPromptForVideoAsset:videoAsset withCompletion:^(NSString *presetName) {
        MXStrongifyAndReturnIfNil(self);
        
        // If the preset name is nil, the user cancelled.
        if (!presetName)
        {
            return;
        }
        
        // Set the chosen video conversion preset.
        [MXSDKOptions sharedInstance].videoConversionPresetName = presetName;
        
        [self didStartSendingToRoom:room];
        if (!videoLocalUrl)
        {
            MXLogError(@"[ShareManager] Invalid video file url.");
            failure(nil);
            return;
        }
        
        // Retrieve the video frame at 1 sec to define the video thumbnail
        AVAssetImageGenerator *assetImageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:videoAsset];
        assetImageGenerator.appliesPreferredTrackTransform = YES;
        CMTime time = CMTimeMake(1, 1);
        CGImageRef imageRef = [assetImageGenerator copyCGImageAtTime:time actualTime:NULL error:nil];
        // Finalize video attachment
        UIImage *videoThumbnail = [[UIImage alloc] initWithCGImage:imageRef];
        CFRelease(imageRef);
        
        [room sendVideoAsset:videoAsset withThumbnail:videoThumbnail localEcho:nil success:^(NSString *eventId) {
            success();
        } failure:^(NSError *error) {
            MXLogError(@"[ShareManager] Failed sending video with error %@", error);
            failure(error);
        }];
    }];
    
    [self presentCompressionPrompt:compressionPrompt];
}

- (void)sendVoiceMessage:(NSURL *)fileUrl
                  toRoom:(MXRoom *)room
                 success:(dispatch_block_t)success
                 failure:(void(^)(NSError *error))failure
{
    [self didStartSendingToRoom:room];
    if (!fileUrl)
    {
        MXLogError(@"[ShareManager] Invalid voice message file url.");
        failure(nil);
        return;
    }
    
    [room sendVoiceMessage:fileUrl mimeType:nil duration:0.0 samples:nil localEcho:nil success:^(NSString *eventId) {
        success();
    } failure:^(NSError *error) {
        MXLogError(@"[ShareManager] sendVoiceMessage failed with error %@", error);
        failure(error);
    } keepActualFilename:YES];
}

@end
