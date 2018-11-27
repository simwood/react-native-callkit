//
//  RNCallKit.m
//  RNCallKit
//
//  Created by Ian Yu-Hsun Lin on 12/22/16.
//  Copyright © 2016 Ian Yu-Hsun Lin. All rights reserved.
//

#import "RNCallKit.h"

#import <React/RCTBridge.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTUtils.h>

#import <AVFoundation/AVAudioSession.h>
#import <AVFoundation/AVFoundation.h>

#import <WebRTC/RTCAudioSession.h>

static int const DelayInSeconds = 3;

static NSString *const RNCallKitHandleStartCallNotification = @"RNCallKitHandleStartCallNotification";
static NSString *const RNCallKitDidReceiveStartCallAction = @"RNCallKitDidReceiveStartCallAction";
static NSString *const RNCallKitPerformAnswerCallAction = @"RNCallKitPerformAnswerCallAction";
static NSString *const RNCallKitPerformEndCallAction = @"RNCallKitPerformEndCallAction";
static NSString *const RNCallKitDidActivateAudioSession = @"RNCallKitDidActivateAudioSession";
static NSString *const RNCallKitDidDeactivateAudioSession = @"RNCallKitDidDeactivateAudioSession";
static NSString *const RNCallKitDidDisplayIncomingCall = @"RNCallKitDidDisplayIncomingCall";
static NSString *const RNCallKitDidPerformSetMutedCallAction = @"RNCallKitDidPerformSetMutedCallAction";
static NSString *const RNCallKitDidPerformSetHeldCallAction = @"RNCallKitDidPerformSetHeldCallAction";
static NSString *const RNCallKitDidPerformPlayDTMFCallAction = @"RNCallKitDidPerformPlayDTMFCallAction";
static NSString *const RNCallKitDidPerformSetGroupCallAction = @"RNCallKitDidPerformSetGroupCallAction";

@implementation RNCallKit
{
    NSMutableDictionary *_settings;
    NSOperatingSystemVersion _version;
    BOOL _isStartCallActionEventListenerAdded;
}

// should initialise in AppDelegate.m
RCT_EXPORT_MODULE()

- (instancetype)init
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][init]");
#endif
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleStartCallNotification:)
                                                     name:RNCallKitHandleStartCallNotification
                                                   object:nil];
        _isStartCallActionEventListenerAdded = NO;
    }
    return self;
}

- (void)dealloc
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][dealloc]");
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Override method of RCTEventEmitter
- (NSArray<NSString *> *)supportedEvents
{
    return @[
             RNCallKitDidReceiveStartCallAction,
             RNCallKitPerformAnswerCallAction,
             RNCallKitPerformEndCallAction,
             RNCallKitDidActivateAudioSession,
             RNCallKitDidDeactivateAudioSession,
             RNCallKitDidDisplayIncomingCall,
             RNCallKitDidPerformSetMutedCallAction,
             RNCallKitDidPerformSetHeldCallAction,
             RNCallKitDidPerformPlayDTMFCallAction,
             RNCallKitDidPerformSetGroupCallAction
             ];
}

RCT_EXPORT_METHOD(setup:(NSDictionary *)options)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][setup] options = %@", options);
#endif
    _version = [[[NSProcessInfo alloc] init] operatingSystemVersion];
    self.callKitCallController = [[CXCallController alloc] init];
    _settings = [[NSMutableDictionary alloc] initWithDictionary:options];
    self.callKitProvider = [[CXProvider alloc] initWithConfiguration:[self getProviderConfiguration]];
    [self.callKitProvider setDelegate:self queue:nil];
}

RCT_REMAP_METHOD(checkIfBusy,
                 checkIfBusyWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][checkIfBusy]");
#endif
    resolve(@(self.callKitCallController.callObserver.calls.count > 0));
}

RCT_REMAP_METHOD(checkSpeaker,
                 checkSpeakerResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][checkSpeaker]");
#endif
    NSString *output = [AVAudioSession sharedInstance].currentRoute.outputs.count > 0 ? [AVAudioSession sharedInstance].currentRoute.outputs[0].portType : nil;
    resolve(@([output isEqualToString:@"Speaker"]));
}

#pragma mark - CXCallController call actions

// Display the incoming call to the user
RCT_EXPORT_METHOD(displayIncomingCall:(NSString *)uuidString
                               handle:(NSString *)handle
                           handleType:(NSString *)handleType
                             hasVideo:(BOOL)hasVideo
                  localizedCallerName:(NSString * _Nullable)localizedCallerName
                         supportsDTMF:(BOOL)supportsDTMF
                      supportsHolding:(BOOL)supportsHolding
                     supportsGrouping:(BOOL)supportsGrouping
                   supportsUngrouping:(BOOL)supportsUngrouping)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][displayIncomingCall] uuidString = %@", uuidString);
#endif
    int _handleType = [self getHandleType:handleType];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = [[CXHandle alloc] initWithType:_handleType value:handle];
    callUpdate.supportsDTMF = supportsDTMF;
    callUpdate.supportsHolding = supportsHolding;
    callUpdate.supportsGrouping = supportsGrouping;
    callUpdate.supportsUngrouping = supportsUngrouping;
    callUpdate.hasVideo = hasVideo;
    callUpdate.localizedCallerName = localizedCallerName;

    [self.callKitProvider reportNewIncomingCallWithUUID:uuid update:callUpdate completion:^(NSError * _Nullable error) {
        [self sendEventWithName:RNCallKitDidDisplayIncomingCall body:@{ @"error": error ? error.localizedDescription : @"" }];
        if (error == nil) {
            // Workaround per https://forums.developer.apple.com/message/169511
            if ([self lessThanIos10_2]) {
                [self configureAudioSession];
            }
        }
    }];
}

// Update information about the call
RCT_EXPORT_METHOD(updateCall:(NSString *)uuidString
                               handle:(NSString *)handle
                           handleType:(NSString *)handleType
                             hasVideo:(BOOL)hasVideo
                  localizedCallerName:(NSString * _Nullable)localizedCallerName
                         supportsDTMF:(BOOL)supportsDTMF
                      supportsHolding:(BOOL)supportsHolding
                     supportsGrouping:(BOOL)supportsGrouping
                   supportsUngrouping:(BOOL)supportsUngrouping)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][updateCall] uuidString = %@, hasVideo = %@", uuidString, hasVideo);
#endif
    int _handleType = [self getHandleType:handleType];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = [[CXHandle alloc] initWithType:_handleType value:handle];
    callUpdate.supportsDTMF = supportsDTMF;
    callUpdate.supportsHolding = supportsHolding;
    callUpdate.supportsGrouping = supportsGrouping;
    callUpdate.supportsUngrouping = supportsUngrouping;
    callUpdate.hasVideo = hasVideo;
    callUpdate.localizedCallerName = localizedCallerName;
    [self.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
}

RCT_EXPORT_METHOD(startCall:(NSString *)uuidString
                     handle:(NSString *)handle
                 handleType:(NSString *)handleType
                      video:(BOOL)video
          contactIdentifier:(NSString * _Nullable)contactIdentifier)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][startCall] uuidString = %@", uuidString);
#endif
    int _handleType = [self getHandleType:handleType];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXHandle *callHandle = [[CXHandle alloc] initWithType:_handleType value:handle];
    CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
    [startCallAction setVideo:video];
    [startCallAction setContactIdentifier:contactIdentifier];

    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];

    [self requestTransaction:transaction];
}

RCT_EXPORT_METHOD(endCall:(NSString *)uuidString)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][endCall] uuidString = %@", uuidString);
#endif
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

    [self requestTransaction:transaction];
}

RCT_EXPORT_METHOD(endAllCalls)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][endAllCalls] calls = %@", self.callKitCallController.callObserver.calls);
#endif
    for (CXCall *call in self.callKitCallController.callObserver.calls) {
        CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:call.UUID];
        CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];
        [self requestTransaction:transaction];
    }
}

RCT_EXPORT_METHOD(setHeldCall:(NSString *)uuidString onHold:(BOOL)onHold)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][setHeldCall] uuidString = %@", uuidString);
#endif
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXSetHeldCallAction *setHeldCallAction = [[CXSetHeldCallAction alloc] initWithCallUUID:uuid onHold:onHold];
    CXTransaction *transaction = [[CXTransaction alloc] init];
    [transaction addAction:setHeldCallAction];

    // RTCAudioSession* rtcAudioSession = [RTCAudioSession sharedInstance];
    // if (onHold) {
    //     NSLog(@"[RNCallKit][setHeldCall] deactivating rtc audio session");
    //     [rtcAudioSession deactivateAudioUnit];
    // } else {
    //     NSLog(@"[RNCallKit][setHeldCall] activating rtc audio session");
    //     [rtcAudioSession activateAudioUnit];
    // }

    [self requestTransaction:transaction];
}

RCT_EXPORT_METHOD(_startCallActionEventListenerAdded)
{
    _isStartCallActionEventListenerAdded = YES;
}

RCT_EXPORT_METHOD(reportConnectedOutgoingCallWithUUID:(NSString *)uuidString)
{
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    [self.callKitProvider reportOutgoingCallWithUUID:uuid connectedAtDate:[NSDate date]];
}

RCT_EXPORT_METHOD(setMutedCall:(NSString *)uuidString muted:(BOOL)muted)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][setMutedCall] muted = %i", muted);
#endif
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    CXSetMutedCallAction *setMutedAction = [[CXSetMutedCallAction alloc] initWithCallUUID:uuid muted:muted];
    CXTransaction *transaction = [[CXTransaction alloc] init];
    [transaction addAction:setMutedAction];

    [self requestTransaction:transaction];
}

- (void)requestTransaction:(CXTransaction *)transaction
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][requestTransaction] transaction = %@", transaction);
#endif
    if (self.callKitCallController == nil) {
        self.callKitCallController = [[CXCallController alloc] init];
    }
    [self.callKitCallController requestTransaction:transaction completion:^(NSError * _Nullable error) {
        if (error != nil) {
            NSLog(@"[RNCallKit][requestTransaction] Error requesting transaction (%@): (%@)", transaction.actions, error);
        } else {
            NSLog(@"[RNCallKit][requestTransaction] Requested transaction successfully");

            // CXStartCallAction
            if ([[transaction.actions firstObject] isKindOfClass:[CXStartCallAction class]]) {
                CXStartCallAction *startCallAction = [transaction.actions firstObject];
                CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
                callUpdate.remoteHandle = startCallAction.handle;
                // callUpdate.supportsDTMF = NO;
                // callUpdate.supportsHolding = YES;
                // callUpdate.supportsGrouping = YES;
                // callUpdate.supportsUngrouping = YES;
                // callUpdate.hasVideo = startCallAction.video;
                [self.callKitProvider reportCallWithUUID:startCallAction.callUUID updated:callUpdate];
            }
        }
    }];
}

- (BOOL)lessThanIos10_2
{
    if (_version.majorVersion < 10) {
        return YES;
    } else if (_version.majorVersion > 10) {
        return NO;
    } else {
        return _version.minorVersion < 2;
    }
}

- (BOOL)containsLowerCaseLetter:(NSString *)callUUID
{
    NSRegularExpression* regex = [[NSRegularExpression alloc] initWithPattern:@"[a-z]" options:0 error:nil];
    return [regex numberOfMatchesInString:callUUID options:0 range:NSMakeRange(0, [callUUID length])] > 0;
}

- (int)getHandleType:(NSString *)handleType
{
    int _handleType;
    if ([handleType isEqualToString:@"generic"]) {
        _handleType = CXHandleTypeGeneric;
    } else if ([handleType isEqualToString:@"number"]) {
        _handleType = CXHandleTypePhoneNumber;
    } else if ([handleType isEqualToString:@"email"]) {
        _handleType = CXHandleTypeEmailAddress;
    } else {
        _handleType = CXHandleTypeGeneric;
    }
    return _handleType;
}

- (CXProviderConfiguration *)getProviderConfiguration
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][getProviderConfiguration]");
#endif
    CXProviderConfiguration *providerConfiguration = [[CXProviderConfiguration alloc] initWithLocalizedName:_settings[@"appName"]];
    providerConfiguration.supportsVideo = _settings[@"supportsVideo"];
    providerConfiguration.maximumCallGroups = _settings[@"maximumCallGroups"];
    providerConfiguration.maximumCallsPerCallGroup = _settings[@"maximumCallsPerCallGroup"];
    providerConfiguration.supportedHandleTypes = [NSSet setWithObjects:[NSNumber numberWithInteger:CXHandleTypePhoneNumber], [NSNumber numberWithInteger:CXHandleTypeEmailAddress], [NSNumber numberWithInteger:CXHandleTypeGeneric], nil];
    if (_settings[@"imageName"]) {
        providerConfiguration.iconTemplateImageData = UIImagePNGRepresentation([UIImage imageNamed:_settings[@"imageName"]]);
    }
    if (_settings[@"ringtoneSound"]) {
        providerConfiguration.ringtoneSound = _settings[@"ringtoneSound"];
    }
    return providerConfiguration;
}

- (void)configureAudioSession
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][configureAudioSession] Activating audio session");
#endif

    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];

    [audioSession setMode:AVAudioSessionModeVoiceChat error:nil];

    double sampleRate = 44100.0;
    [audioSession setPreferredSampleRate:sampleRate error:nil];

    NSTimeInterval bufferDuration = .005;
    [audioSession setPreferredIOBufferDuration:bufferDuration error:nil];
    [audioSession setActive:TRUE error:nil];

    RTCAudioSession* rtcAudioSession = [RTCAudioSession sharedInstance];
    [rtcAudioSession setUseManualAudio:YES];
}

+ (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options NS_AVAILABLE_IOS(9_0)
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][application:openURL]");
#endif
    /*
    NSString *handle = [url startCallHandle];
    if (handle != nil && handle.length > 0 ){
        NSDictionary *userInfo = @{
            @"handle": handle,
            @"video": @NO
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:RNCallKitHandleStartCallNotification
                                                            object:self
                                                          userInfo:userInfo];
        return YES;
    }
    return NO;
    */
    return YES;
}

+ (BOOL)application:(UIApplication *)application
continueUserActivity:(NSUserActivity *)userActivity
 restorationHandler:(void(^)(NSArray * __nullable restorableObjects))restorationHandler
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][application:continueUserActivity]");
#endif
    INInteraction *interaction = userActivity.interaction;
    INPerson *contact;
    NSString *handle;
    BOOL isAudioCall = [userActivity.activityType isEqualToString:INStartAudioCallIntentIdentifier];
    BOOL isVideoCall = [userActivity.activityType isEqualToString:INStartVideoCallIntentIdentifier];

    if (isAudioCall) {
        INStartAudioCallIntent *startAudioCallIntent = (INStartAudioCallIntent *)interaction.intent;
        contact = [startAudioCallIntent.contacts firstObject];
    } else if (isVideoCall) {
        INStartVideoCallIntent *startVideoCallIntent = (INStartVideoCallIntent *)interaction.intent;
        contact = [startVideoCallIntent.contacts firstObject];
    }

    if (contact != nil) {
        handle = contact.personHandle.value;
    }

    if (handle != nil && handle.length > 0 ){
        NSDictionary *userInfo = @{
                                   @"handle": handle,
                                   @"video": @(isVideoCall)
                                   };

        [[NSNotificationCenter defaultCenter] postNotificationName:RNCallKitHandleStartCallNotification
                                                            object:self
                                                          userInfo:userInfo];
        return YES;
    }
    return NO;
}

- (void)handleStartCallNotification:(NSNotification *)notification
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][handleStartCallNotification] userInfo = %@", notification.userInfo);
#endif
    int delayInSeconds;
    if (!_isStartCallActionEventListenerAdded) {
        // Workaround for when app is just launched and JS side hasn't registered to the event properly
        delayInSeconds = DelayInSeconds;
    } else {
        delayInSeconds = 0;
    }
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^{
        [self sendEventWithName:RNCallKitDidReceiveStartCallAction body:notification.userInfo];
    });
}

#pragma mark - CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider{
#ifdef DEBUG
    NSLog(@"[RNCallKit][providerDidReset]");
#endif
}

// Starting outgoing call
- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performStartCallAction]");
#endif
    [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];
    [self configureAudioSession];
    [action fulfill];
}

// Answering incoming call
- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performAnswerCallAction]");
#endif
    if (![self lessThanIos10_2]) {
        [self configureAudioSession];
    }
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitPerformAnswerCallAction body:@{ @"callUUID": callUUID }];
    [action fulfill];
}

// Ending incoming call
- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performEndCallAction]");
#endif
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitPerformEndCallAction body:@{ @"callUUID": callUUID }];

    RTCAudioSession* rtcAudioSession = [RTCAudioSession sharedInstance];
    [rtcAudioSession setIsAudioEnabled:NO];
    [rtcAudioSession setUseManualAudio:NO];

    [action fulfillWithDateEnded:[NSDate date]];
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:timedOutPerformingAction]");
#endif
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:didActivateAudioSession]");
#endif
    // NSDictionary *info = @{
    //                        AVAudioSessionInterruptionTypeKey: @0,
    //                        AVAudioSessionInterruptionOptionKey: @1
    //                        };
    // [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionInterruptionNotification object:self userInfo:info];

    RTCAudioSession* rtcAudioSession = [RTCAudioSession sharedInstance];
    [rtcAudioSession setIsAudioEnabled:YES];
    [rtcAudioSession activateAudioUnit];

    [self sendEventWithName:RNCallKitDidActivateAudioSession body:nil];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:didDeactivateAudioSession]");
#endif

    RTCAudioSession* rtcAudioSession = [RTCAudioSession sharedInstance];
    [rtcAudioSession deactivateAudioUnit];

    [self sendEventWithName:RNCallKitDidDeactivateAudioSession body:nil];
}

-(void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performSetMutedCallAction]");
#endif
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitDidPerformSetMutedCallAction body:@{ @"muted": @(action.muted), @"callUUID": callUUID }];
    [action fulfill];
}

-(void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performSetHeldCallAction]");
#endif
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitDidPerformSetHeldCallAction body:@{ @"onHold": @(action.onHold), @"callUUID": callUUID }];
    // AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    // if (action.onHold)
    //   [audioSession setActive:FALSE error:nil];
    // else
    //   [audioSession setActive:TRUE error:nil];
    [action fulfill];
}

-(void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performPlayDTMFCallAction]");
#endif
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitDidPerformPlayDTMFCallAction body:@{ @"digits": action.digits, @"callUUID": callUUID }];
    [action fulfill];
}

-(void)provider:(CXProvider *)provider performSetGroupCallAction:(CXSetGroupCallAction *)action
{
#ifdef DEBUG
    NSLog(@"[RNCallKit][CXProviderDelegate][provider:performSetGroupCallAction]");
#endif
    NSString *callUUID = [self containsLowerCaseLetter:action.callUUID.UUIDString] ? action.callUUID.UUIDString : [action.callUUID.UUIDString lowercaseString];
    NSString *callUUIDToGroupWith = [self containsLowerCaseLetter:action.callUUIDToGroupWith.UUIDString] ? action.callUUIDToGroupWith.UUIDString : [action.callUUIDToGroupWith.UUIDString lowercaseString];
    [self sendEventWithName:RNCallKitDidPerformSetGroupCallAction body:@{ @"callUUID": callUUID, @"callUUIDToGroupWith": callUUID }];
    [action fulfill];
}

@end
