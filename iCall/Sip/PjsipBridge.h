#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Registration state surfaced to Swift (mirrors Android's SipState).
typedef NS_ENUM(NSInteger, SipRegState) {
    SipRegStateIdle = 0,
    SipRegStateRegistering,
    SipRegStateRegistered,
    SipRegStateFailed,
};

/// Call state surfaced to Swift (mirrors Android's CallState).
typedef NS_ENUM(NSInteger, SipCallState) {
    SipCallStateIdle = 0,
    SipCallStateCalling,     // INVITE sent, no answer yet
    SipCallStateRinging,     // 180/183 — far end alerting
    SipCallStateConnected,   // 200 OK — media flowing
    SipCallStateEnded,       // disconnected
};

/// Line index: 0 = Line 1 (primary), 1 = Line 2 (secondary).
@protocol PjsipBridgeDelegate <NSObject>
/// Always delivered on the main thread.
- (void)sipRegStateChanged:(SipRegState)state line:(NSInteger)line code:(int)code reason:(NSString *)reason;
@optional
- (void)sipCallStateChanged:(SipCallState)state line:(NSInteger)line peer:(NSString *)peer code:(int)code reason:(NSString *)reason;
/// Fired when an inbound INVITE arrives on `line` (ringing, not yet answered).
- (void)sipIncomingCall:(NSString *)peer line:(NSInteger)line;
/// Inbound SIP MESSAGE (IM) on `line`.
- (void)sipMessageReceived:(NSString *)fromUri body:(NSString *)body line:(NSInteger)line;
/// Delivery status for an outbound SIP MESSAGE.
- (void)sipMessageStatus:(NSString *)toUri delivered:(BOOL)delivered line:(NSInteger)line;
/// Held-call changed (nil = no held call) — drives the multi-call UI.
- (void)sipHeldCallChanged:(nullable NSString *)heldPeer;
/// Conference (3-way) bridge active/inactive.
- (void)sipConferenceChanged:(BOOL)active;
/// Video on the active call changed. `remoteView` is the PJSIP render UIView
/// (nil when video is off). Always on the main thread.
- (void)sipVideoChanged:(BOOL)active remoteView:(nullable UIView *)remoteView;
/// Local camera self-view changed. `localView` is the PJSIP capture-preview
/// UIView (nil when off). Always on the main thread.
- (void)sipLocalVideoChanged:(nullable UIView *)localView;
/// The peer added video while we were BACKGROUNDED (answered the voice call
/// from the CallKit lock-screen). The request is held/ringing; surface an
/// Accept/Decline alert. Accept -> -acceptPendingVideo, Decline -> -declinePendingVideo.
- (void)sipIncomingVideoRequest:(NSString *)peer line:(NSInteger)line;
@end

/// Obj-C facade over PJSIP (pjsua2). Supports two accounts (Line 1 + Line 2),
/// both registered to the push gateway. One active call at a time.
@interface PjsipBridge : NSObject

+ (instancetype)shared;
+ (NSString *)pjsipVersion;

@property (nonatomic, weak) id<PjsipBridgeDelegate> delegate;

- (BOOL)startEngine:(NSError **)error;

/// Register `line` (0 or 1) to the gateway.
/// `srtp`: "disabled" (default) | "optional" | "mandatory".
- (void)registerLine:(NSInteger)line
            username:(NSString *)username
            password:(NSString *)password
              server:(NSString *)server
         gatewayHost:(NSString *)gatewayHost
           transport:(NSString *)transport
                srtp:(NSString *)srtp;

/// Unregister a single line.
- (void)unregisterLine:(NSInteger)line;

/// Place an outbound call to `number` on the given line.
- (void)makeCall:(NSString *)number line:(NSInteger)line;

/// Send a SIP MESSAGE (IM) to `toNumber` on the given line.
- (void)sendMessage:(NSString *)toNumber body:(NSString *)body line:(NSInteger)line;

/// Answer the current incoming call (200 OK). Driven by CallKit's answer action.
- (void)answer;

/// CallKit activated/deactivated its audio session.
- (void)onCallKitAudioActivated;
- (void)onCallKitAudioDeactivated;

/// Hang up / cancel / decline the current call.
- (void)hangup;

/// In-call controls (operate on the single active call).
- (void)setMuted:(BOOL)muted;
- (void)setSpeaker:(BOOL)on;
- (void)sendDtmf:(NSString *)digits;
- (void)setHold:(BOOL)hold;
/// Blind (unattended) transfer of the active call to `number` on its line.
- (void)blindTransfer:(NSString *)number;

/// Portal-managed list of SIP domains that need app-side local music-on-hold
/// (the fts family). Overrides the built-in defaults.
- (void)setMohDomains:(NSArray<NSString *> *)domains;

/// Portal-managed list of SIP domains whose VIDEO routes internally via the
/// push gateway (bypass PBX). Others send the sidecar down the voice path.
- (void)setVideoDomains:(NSArray<NSString *> *)domains;

// Multi-call. "Add Call" = makeCall while a call is active (auto-holds it).
- (void)swapCalls;          // active ↔ held
- (void)mergeConference;    // bridge active + held into a 3-way audio conf
- (void)splitConference;    // tear down the conf, re-hold the 2nd call
- (void)attendedTransfer;   // REFER held → active (warm transfer), drops both
- (void)endHeldCall;        // hang up just the held call

// Codec selection (Settings → Codecs). Each entry: {id, name, enabled}.
- (NSArray<NSDictionary *> *)audioCodecList;
- (NSArray<NSDictionary *> *)videoCodecList;
- (void)setAudioCodecEnabled:(NSString *)codecId enabled:(BOOL)enabled;
- (void)setVideoCodecEnabled:(NSString *)codecId enabled:(BOOL)enabled;

/// Live in-call stats for the Information sheet: {state, codec}.
- (NSDictionary *)currentCallStats;

// Video (escalate from an ongoing audio call; WhatsApp-style).
- (void)startVideo;                 // add video to the active call
- (void)stopVideo;                  // remove video (back to audio-only)
- (void)switchCamera;               // front <-> back
- (void)setVideoMuted:(BOOL)muted;  // pause/resume local camera transmit
- (CGSize)remoteVideoSize;          // decoded far-end frame size (for aspect)

// Call recording (both directions → WAV in Documents). Returns the resulting
// state (YES = now recording). Mirrors Android's in-call record button.
- (void)setRecording:(BOOL)on;

// Incoming-video-while-backgrounded flow (WhatsApp-style). The bridge holds an
// incoming video request when the app isn't foreground; Swift surfaces an
// Accept/Decline alert and calls these.
- (void)setAppForeground:(BOOL)foreground;  // mirror scenePhase into the bridge
- (void)acceptPendingVideo;                 // answer the held request (camera on)
- (void)declinePendingVideo;                // hang up the held request

@end

NS_ASSUME_NONNULL_END
