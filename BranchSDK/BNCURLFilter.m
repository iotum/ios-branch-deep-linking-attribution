/**
 @file          BNCURLFilter.m
 @package       Branch-SDK
 @brief         Manages a list of URLs that we should ignore.

 @author        Edward Smith
 @date          February 14, 2018
 @copyright     Copyright © 2018 Branch. All rights reserved.
*/

#import "BNCURLFilter.h"
#import "Branch.h"
#import "BNCLog.h"

@interface BNCURLFilter ()

@property (strong, nonatomic, readwrite) NSArray<NSString *> *patternList;

// Is YES if the list has already been updated from the server, or is overridden with a custom list.
@property (nonatomic, assign, readwrite) BOOL hasUpdatedPatternList;

@property (strong, nonatomic) NSArray<NSRegularExpression*> *ignoredURLRegex;
@property (assign, nonatomic) NSInteger listVersion;

@end

@implementation BNCURLFilter

- (instancetype)init {
    self = [super init];
    if (!self) return self;

    [self useDefaultPatternList];
    
    return self;
}

- (void)useDefaultPatternList {
    self.patternList = @[
        @"^fb\\d+:((?!campaign_ids).)*$", // Facebook
        @"^li\\d+:", // LinkedIn - deprecated
        @"^pdk\\d+:", // Pinterest - deprecated
        @"^twitterkit-.*:", // TwitterKit - deprecated
        @"^com\\.googleusercontent\\.apps\\.\\d+-.*:\\/oauth", // Google
        @"^(?i)(?!(http|https):).*(:|:.*\\b)(password|o?auth|o?auth.?token|access|access.?token)\\b",
        @"^(?i)((http|https):\\/\\/).*[\\/|?|#].*\\b(password|o?auth|o?auth.?token|access|access.?token)\\b",
    ];
    self.listVersion = -1; // First time always refresh the list version, version 0.
    self.ignoredURLRegex = [self compileRegexArray:self.patternList];
}

- (NSArray<NSRegularExpression *> *)compileRegexArray:(NSArray<NSString *> *)patternList {
    NSMutableArray<NSRegularExpression *> *array = [NSMutableArray<NSRegularExpression *> new];
    for (NSString *pattern in patternList) {
        NSError *regexError = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options: NSRegularExpressionAnchorsMatchLines | NSRegularExpressionUseUnicodeWordBoundaries error:&regexError];
        
        if (regex && !regexError) {
            [array addObject:regex];
        } else {
            BNCLogError([NSString stringWithFormat:@"Invalid regular expression '%@': %@.", pattern, regexError]);
        }
    }
    return array;
}

- (nullable NSString *)patternMatchingURL:(NSURL *)url {
    NSString *urlString = url.absoluteString;
    if (urlString == nil || urlString.length <= 0) return nil;
    
    NSRange range = NSMakeRange(0, urlString.length);
    for (NSRegularExpression* regex in self.ignoredURLRegex) {
        NSUInteger matches = [regex numberOfMatchesInString:urlString options:0 range:range];
        if (matches > 0) return regex.pattern;
    }
    
    return nil;
}

- (BOOL)shouldIgnoreURL:(NSURL *)url {
    return ([self patternMatchingURL:url]) ? YES : NO;
}

- (void)useSavedPatternList {
    NSArray *storedList = [BNCPreferenceHelper sharedInstance].savedURLPatternList;
    if (storedList.count > 0) {
        self.patternList = storedList;
        self.listVersion = [BNCPreferenceHelper sharedInstance].savedURLPatternListVersion;
    }
    self.ignoredURLRegex = [self compileRegexArray:self.patternList];
}

- (void)useCustomPatternList:(NSArray<NSString *> *)patternList {
    if (patternList.count > 0) {
        self.patternList = patternList;
        self.listVersion = 0;
    }
    self.ignoredURLRegex = [self compileRegexArray:self.patternList];
}

#pragma mark Server update

- (void)updatePatternListFromServerWithCompletion:(void (^_Nullable) (void))completion {
    if (self.hasUpdatedPatternList) {
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/sdk/uriskiplist_v%ld.json", [BNCPreferenceHelper sharedInstance].patternListURL, (long) self.listVersion+1];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];

    __block id<BNCNetworkServiceProtocol> networkService = [[Branch networkServiceClass] new];
    id<BNCNetworkOperationProtocol> operation = [networkService networkOperationWithURLRequest:request completion: ^(id<BNCNetworkOperationProtocol> operation) {
        [self processServerOperation:operation];
        if (completion) {
            completion();
        }
    }];
    [operation start];
}

- (BOOL)foundUpdatedURLList:(id<BNCNetworkOperationProtocol>)operation {
    NSInteger statusCode = operation.response.statusCode;
    NSError *error = operation.error;
    NSString *jsonString = nil;
    if (operation.responseData) {
        jsonString = [[NSString alloc] initWithData:operation.responseData encoding:NSUTF8StringEncoding];
    }
    
    if (statusCode == 404) {
        BNCLogDebug([NSString stringWithFormat:@"No update for URL ignore list found."]);
        return NO;
        
    } else if (statusCode != 200 || error != nil || jsonString == nil) {
        BNCLogError([NSString stringWithFormat:@"Failed to update URL ignore list. error: %@ status: %ld", operation.error, (long)operation.response.statusCode]);
        BNCLogDebug([NSString stringWithFormat:@"URL ignore JSON: %@", jsonString]);
        return NO;
        
    } else {
        return YES;
    }
}

- (nullable NSDictionary *)parseJSONFromData:(NSData *)data {
    NSError *error = nil;
    NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (error) {
        BNCLogError([NSString stringWithFormat:@"Can't parse URL ignore JSON: %@.", error]);
        return nil;
    }
    
    NSArray *urls = dictionary[@"uri_skip_list"];
    if (![urls isKindOfClass:NSArray.class]) {
        BNCLogError([NSString stringWithFormat:@"Can't parse URL ignore JSON, uri_skip_list is not a NSArray."]);
        return nil;
    }
    
    NSNumber *version = dictionary[@"version"];
    if (![version isKindOfClass:NSNumber.class]) {
        BNCLogError([NSString stringWithFormat:@"Can't parse URL ignore JSON, version is not a NSNumber."]);
        return nil;
    }
    
    return dictionary;
}

- (void)processServerOperation:(id<BNCNetworkOperationProtocol>)operation {
    if ([self foundUpdatedURLList:operation]) {
        NSDictionary *json = [self parseJSONFromData:operation.responseData];
        if (json) {
            self.hasUpdatedPatternList = YES;
            self.patternList = json[@"uri_skip_list"];
            self.listVersion = (long)json[@"version"];
            self.ignoredURLRegex = [self compileRegexArray:self.patternList];

            [BNCPreferenceHelper sharedInstance].savedURLPatternList = self.patternList;
            [BNCPreferenceHelper sharedInstance].savedURLPatternListVersion = self.listVersion;
        }
    }
}

@end
