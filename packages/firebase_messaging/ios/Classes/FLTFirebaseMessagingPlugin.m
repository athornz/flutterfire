// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <UserNotifications/UserNotifications.h>

#import "FLTFirebaseMessagingPlugin.h"
#import "UserAgent.h"

#import "Firebase/Firebase.h"

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
@interface FLTFirebaseMessagingPlugin () <FIRMessagingDelegate>
@end
#endif

static FlutterError *getFlutterError(NSError *error) {
  if (error == nil) return nil;
  return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %ld", (long)error.code]
                             message:error.domain
                             details:error.localizedDescription];
}


static NSString* backgroundSetupCallbackHandle = @"background_setup_callback";
static NSString* backgroundMessageCallbackHandle = @"background_message_callback";
static FlutterPluginRegistrantCallback pluginRegistrantCallback = nil;

typedef void (^FetchCompletionHandler)(UIBackgroundFetchResult result);

@implementation FLTFirebaseMessagingPlugin {
  FlutterMethodChannel *_channel;
  FlutterMethodChannel *_backgroundCallbackChannel;
  NSDictionary *_launchNotification;
  BOOL _resumingFromBackground;
  NSUserDefaults *_userDefaults;
  NSObject<FlutterPluginRegistrar> *_registrar;
  NSMutableArray *_remoteMessageQueue;
  FlutterEngine *_headlessRunner;
  BOOL backgroundIsolateInitialized;
  FetchCompletionHandler fetchCompletionHandler;
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
    pluginRegistrantCallback = callback;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/firebase_messaging"
                                  binaryMessenger:[registrar messenger]];
  FLTFirebaseMessagingPlugin *instance =
    [[FLTFirebaseMessagingPlugin alloc] initWithChannel:channel registrar:registrar];
  [registrar addApplicationDelegate:instance];
  [registrar addMethodCallDelegate:instance channel:channel];

  SEL sel = NSSelectorFromString(@"registerLibrary:withVersion:");
  if ([FIRApp respondsToSelector:sel]) {
    [FIRApp performSelector:sel withObject:LIBRARY_NAME withObject:LIBRARY_VERSION];
  }
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];

  if (self) {
    _channel = channel;
    _resumingFromBackground = NO;

    if (![FIRApp appNamed:@"__FIRAPP_DEFAULT"]) {
      NSLog(@"Configuring the default Firebase app...");
      [FIRApp configure];
      NSLog(@"Configured the default Firebase app %@.", [FIRApp defaultApp].name);
    }
    [FIRMessaging messaging].delegate = self;

    _userDefaults = [NSUserDefaults standardUserDefaults];
    _remoteMessageQueue = [[NSMutableArray alloc] init];
    _registrar = registrar;
    _headlessRunner = [[FlutterEngine alloc] initWithName:@"firebase_messaging_background" project:nil allowHeadlessExecution:YES];
    _backgroundCallbackChannel = [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/firebase_messaging_background" binaryMessenger:[_headlessRunner binaryMessenger]];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *method = call.method;
  if ([@"requestNotificationPermissions" isEqualToString:method]) {
    NSDictionary *arguments = call.arguments;
    if (@available(iOS 10.0, *)) {
      UNAuthorizationOptions authOptions = 0;
      NSNumber *provisional = arguments[@"provisional"];
      if ([arguments[@"sound"] boolValue]) {
        authOptions |= UNAuthorizationOptionSound;
      }
      if ([arguments[@"alert"] boolValue]) {
        authOptions |= UNAuthorizationOptionAlert;
      }
      if ([arguments[@"badge"] boolValue]) {
        authOptions |= UNAuthorizationOptionBadge;
      }

      NSNumber *isAtLeastVersion12;
      if (@available(iOS 12, *)) {
        isAtLeastVersion12 = [NSNumber numberWithBool:YES];
        if ([provisional boolValue]) authOptions |= UNAuthorizationOptionProvisional;
      } else {
        isAtLeastVersion12 = [NSNumber numberWithBool:NO];
      }

      [[UNUserNotificationCenter currentNotificationCenter]
          requestAuthorizationWithOptions:authOptions
                        completionHandler:^(BOOL granted, NSError *_Nullable error) {
                          if (error) {
                            result(getFlutterError(error));
                            return;
                          }
                          // This works for iOS >= 10. See
                          // [UIApplication:didRegisterUserNotificationSettings:notificationSettings]
                          // for ios < 10.
                          [[UNUserNotificationCenter currentNotificationCenter]
                              getNotificationSettingsWithCompletionHandler:^(
                                  UNNotificationSettings *_Nonnull settings) {
                                NSDictionary *settingsDictionary = @{
                                  @"sound" : [NSNumber numberWithBool:settings.soundSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"badge" : [NSNumber numberWithBool:settings.badgeSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"alert" : [NSNumber numberWithBool:settings.alertSetting ==
                                                                      UNNotificationSettingEnabled],
                                  @"provisional" :
                                      [NSNumber numberWithBool:granted && [provisional boolValue] &&
                                                               isAtLeastVersion12],
                                };
                                [self->_channel invokeMethod:@"onIosSettingsRegistered"
                                                   arguments:settingsDictionary];
                              }];
                          result([NSNumber numberWithBool:granted]);
                        }];

      [[UIApplication sharedApplication] registerForRemoteNotifications];
    } else {
      UIUserNotificationType notificationTypes = 0;
      if ([arguments[@"sound"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeSound;
      }
      if ([arguments[@"alert"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeAlert;
      }
      if ([arguments[@"badge"] boolValue]) {
        notificationTypes |= UIUserNotificationTypeBadge;
      }

      UIUserNotificationSettings *settings =
          [UIUserNotificationSettings settingsForTypes:notificationTypes categories:nil];
      [[UIApplication sharedApplication] registerUserNotificationSettings:settings];

      [[UIApplication sharedApplication] registerForRemoteNotifications];
      result([NSNumber numberWithBool:YES]);
    }
  } else if ([@"configure" isEqualToString:method]) {
    [FIRMessaging messaging].shouldEstablishDirectChannel = true;
    [[UIApplication sharedApplication] registerForRemoteNotifications];
    if (_launchNotification != nil) {
      [_channel invokeMethod:@"onLaunch" arguments:_launchNotification];
    }
    result(nil);
  } else if ([@"subscribeToTopic" isEqualToString:method]) {
    NSString *topic = call.arguments;
    [[FIRMessaging messaging] subscribeToTopic:topic
                                    completion:^(NSError *error) {
                                      result(getFlutterError(error));
                                    }];
  } else if ([@"unsubscribeFromTopic" isEqualToString:method]) {
    NSString *topic = call.arguments;
    [[FIRMessaging messaging] unsubscribeFromTopic:topic
                                        completion:^(NSError *error) {
                                          result(getFlutterError(error));
                                        }];
  } else if ([@"getToken" isEqualToString:method]) {
    [[FIRInstanceID instanceID]
        instanceIDWithHandler:^(FIRInstanceIDResult *_Nullable instanceIDResult,
                                NSError *_Nullable error) {
          if (error != nil) {
            NSLog(@"getToken, error fetching instanceID: %@", error);
            result(nil);
          } else {
            result(instanceIDResult.token);
          }
        }];
  } else if ([@"deleteInstanceID" isEqualToString:method]) {
    [[FIRInstanceID instanceID] deleteIDWithHandler:^void(NSError *_Nullable error) {
      if (error.code != 0) {
        NSLog(@"deleteInstanceID, error: %@", error);
        result([NSNumber numberWithBool:NO]);
      } else {
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        result([NSNumber numberWithBool:YES]);
      }
    }];
  } else if ([@"autoInitEnabled" isEqualToString:method]) {
    BOOL value = [[FIRMessaging messaging] isAutoInitEnabled];
    result([NSNumber numberWithBool:value]);
  } else if ([@"setAutoInitEnabled" isEqualToString:method]) {
    NSNumber *value = call.arguments;
    [FIRMessaging messaging].autoInitEnabled = value.boolValue;
    result(nil);
  } else if ([@"FcmDartService#initialized" isEqualToString:call.method]) {
      // called when the Dart isolate and Firebase Messaging plugin has been initalized.
      // any pending remote messages should be dispatched now.
      @synchronized(self) {
          backgroundIsolateInitialized = YES;
          while ([_remoteMessageQueue count] > 0) {
              NSDictionary* message = _remoteMessageQueue[0];
              [_remoteMessageQueue removeObjectAtIndex:0];

              [self handleBackgroundMessage: message];
          }
      }
      result(nil);
  } else if ([@"FcmDartService#start" isEqualToString:method]) {
      // called when configuring the Firebase Messaging plugin.
      // save the callback handles here so they can used later
      // when a message is received in the background
      NSDictionary *arguments = call.arguments;
      long setupHandle = [arguments[@"setupHandle"] longValue];
      long backgroundHandle = [arguments[@"backgroundHandle"] longValue];

      [self _saveCallbackHandle:backgroundSetupCallbackHandle handle:setupHandle];
      [self _saveCallbackHandle:backgroundMessageCallbackHandle handle:backgroundHandle];
      result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
// Receive data message on iOS 10 devices while app is in the foreground.
- (void)applicationReceivedRemoteMessage:(FIRMessagingRemoteMessage *)remoteMessage {
  [self didReceiveRemoteNotification:remoteMessage.appData];
}
#endif

- (void)didReceiveRemoteNotification:(NSDictionary *)userInfo {
  if (_resumingFromBackground) {
    [_channel invokeMethod:@"onResume" arguments:userInfo];
  } else {
    [_channel invokeMethod:@"onMessage" arguments:userInfo];
  }
}

#pragma mark - AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  if (launchOptions != nil) {
    _launchNotification = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
  }
  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  _resumingFromBackground = YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
  _resumingFromBackground = NO;
  // Clears push notifications from the notification center, with the
  // side effect of resetting the badge count. We need to clear notifications
  // because otherwise the user could tap notifications in the notification
  // center while the app is in the foreground, and we wouldn't be able to
  // distinguish that case from the case where a message came in and the
  // user dismissed the notification center without tapping anything.
  // TODO(goderbauer): Revisit this behavior once we provide an API for managing
  // the badge number, or if we add support for running Dart in the background.
  // Setting badgeNumber to 0 is a no-op (= notifications will not be cleared)
  // if it is already 0,
  // therefore the next line is setting it to 1 first before clearing it again
  // to remove all
  // notifications.
  application.applicationIconBadgeNumber = 1;
  application.applicationIconBadgeNumber = 0;
}

- (BOOL)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {

    int64_t backgroundMessageHandle = [self getCallbackHandle:backgroundMessageCallbackHandle];

    // when a message is received, the application is in the background and it has a background message handle,
    // queue the message to be handled, and start the background isolate if needed
    if (application.applicationState == UIApplicationStateBackground && backgroundMessageHandle != nil) {
        //save this handler for later so it can be completed
        fetchCompletionHandler = completionHandler;

        NSDictionary *args = @{
                              @"handle" : @(backgroundMessageHandle),
                              @"message" : userInfo,
                            };
        [self queueRemoteMessage:args];

        if (!backgroundIsolateInitialized){
            [self startBackgroundIsolate];
        }
    } else {
        [self didReceiveRemoteNotification:userInfo];
        completionHandler(UIBackgroundFetchResultNewData);
    }
  return YES;
}

- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
#ifdef DEBUG
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeSandbox];
#else
  [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeProd];
#endif

  [_channel invokeMethod:@"onToken" arguments:[FIRMessaging messaging].FCMToken];
}

// This will only be called for iOS < 10. For iOS >= 10, we make this call when we request
// permissions.
- (void)application:(UIApplication *)application
    didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
  NSDictionary *settingsDictionary = @{
    @"sound" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeSound],
    @"badge" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeBadge],
    @"alert" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeAlert],
    @"provisional" : [NSNumber numberWithBool:NO],
  };
  [_channel invokeMethod:@"onIosSettingsRegistered" arguments:settingsDictionary];
}

- (void)messaging:(nonnull FIRMessaging *)messaging
    didReceiveRegistrationToken:(nonnull NSString *)fcmToken {
  [_channel invokeMethod:@"onToken" arguments:fcmToken];
}

- (void)messaging:(FIRMessaging *)messaging
    didReceiveMessage:(FIRMessagingRemoteMessage *)remoteMessage {
  [_channel invokeMethod:@"onMessage" arguments:remoteMessage.appData];
}

- (void) startBackgroundIsolate {
    NSLog(@"Starting Firebase Messaging background isolate");

    int64_t handle = [self getCallbackHandle:backgroundSetupCallbackHandle];

    FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
    NSAssert(info != nil, @"failed to find callback");
    NSString *entrypoint = info.callbackName;
    NSString *uri = info.callbackLibraryPath;

    [_headlessRunner runWithEntrypoint:entrypoint libraryURI:uri];
    [_registrar addMethodCallDelegate:self channel:_backgroundCallbackChannel];

    // Once our headless runner has been started, we need to register the application's plugins
    // with the runner in order for them to work on the background isolate. `pluginRegistrantCallback` is
    // a callback set from AppDelegate.m in the main application. This callback should register
    // all relevant plugins (excluding those which require UI).

    NSAssert(pluginRegistrantCallback != nil, @"failed to set pluginRegistrantCallback");
    pluginRegistrantCallback(_headlessRunner);
}

// Get a callback handle that has been stored in NSUserDefaults
- (int64_t) getCallbackHandle:(NSString *) key {
    id handle = [_userDefaults objectForKey:key];
    if (handle == nil) {
        return 0;
    }
    return [handle longLongValue];
}

// Save a callback handle in NSUserDefaults
- (void) _saveCallbackHandle:(NSString *)key handle:(int64_t)handle {
    [_userDefaults setObject:[NSNumber numberWithLongLong:handle] forKey:key];
}

// Queues a remote message for handling
// If the background isolate is not yet started, queues the message and starts the isolate
// Otherwise the message is handled by the background isolate immediately
- (void) queueRemoteMessage:(NSDictionary*)message {
    @synchronized(self) {
        if (backgroundIsolateInitialized) {
            [self handleBackgroundMessage:message];
        } else {
            [_remoteMessageQueue addObject:message];
        }
    }
}

// dispatches a remote message to be handled by the dart background isolate
- (void) handleBackgroundMessage:(NSDictionary*)arguments {
    [_backgroundCallbackChannel invokeMethod:@"handleBackgroundMessage" arguments:arguments result:^(id  _Nullable result) {
        if (fetchCompletionHandler!=nil) {
            fetchCompletionHandler(UIBackgroundFetchResultNewData);
            fetchCompletionHandler = nil;
        }
    }];
}


@end
