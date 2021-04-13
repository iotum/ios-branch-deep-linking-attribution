//
//  AppDelegate.h
//  Branch-TestBed
//
//  Created by Alex Austin on 6/5/14.
//  Copyright (c) 2014 Branch Metrics. All rights reserved.
//

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property NSString* logFileName;
@property NSString* PrevCommandLogFileName;
- (void) processLogMessage:(NSString*)message;
- (void) setLogFile:(NSString*)fileName;
@end
