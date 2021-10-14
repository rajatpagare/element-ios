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

#import <MatrixKit/MatrixKit.h>

@class ShareExtensionManager;

typedef NS_ENUM(NSUInteger, ShareExtensionManagerResult) {
    ShareExtensionManagerResultFinished,
    ShareExtensionManagerResultCancelled,
    ShareExtensionManagerResultFailed
};

@interface ShareExtensionManager : NSObject

@property (nonatomic, copy) void (^completionCallback)(ShareExtensionManagerResult);

- (instancetype)initWithShareExtensionContext:(NSExtensionContext *)shareExtensionContext
                               extensionItems:(NSArray<NSExtensionItem *> *)extensionItems;

- (UIViewController *)mainViewController;

@end


@interface NSItemProvider (ShareExtensionManager)

@property BOOL isLoaded;

@end
