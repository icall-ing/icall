#import "PjsipBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

// Obj-C++ translation unit: C++ PJSIP headers live here only.
#include <pjlib.h>
#include <pjsua2.hpp>
#include <string>

using namespace pj;

// ---- pjsua2 globals (Endpoint must outlive all accounts/calls) --------------
static Endpoint *g_ep = nullptr;
static bool g_started = false;
static std::string g_server[2];      // customer realm per line, for call URIs
static std::string g_gateway[2];     // push gateway host per line, for internal video
static std::string g_tparam[2];      // ";transport=tls" | ";transport=tcp" per line
// Per-line transports: each line gets its OWN connection (distinct source
// port) so the gateway tracks an independent NAT/outbound flow per line.
// Sharing one connection across both accounts left Line 2 with a broken
// contact (private IP, no flow) → no inbound on Line 2.
static int g_tlsTid[2] = {-1, -1};
static int g_tcpTid[2] = {-1, -1};
// Video capture devices (front/back), discovered at startup.
static int g_frontCamId = -1;
static int g_backCamId  = -1;
static int g_curCaptureDev = -1;

@class PjsipBridge;
static __weak PjsipBridge *g_bridge = nil;

static void notifyRegState(SipRegState state, NSInteger line, int code, const std::string &reason) {
    NSString *r = [NSString stringWithUTF8String:reason.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_bridge.delegate sipRegStateChanged:state line:line code:code reason:r];
    });
}

static void notifyCallState(SipCallState state, NSInteger line, const std::string &peer,
                            int code = 0, const std::string &reason = "") {
    NSString *p = [NSString stringWithUTF8String:peer.c_str()];
    NSString *r = [NSString stringWithUTF8String:reason.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
        PjsipBridge *b = g_bridge;
        if ([b.delegate respondsToSelector:@selector(sipCallStateChanged:line:peer:code:reason:)]) {
            [b.delegate sipCallStateChanged:state line:line peer:p code:code reason:r];
        }
    });
}

// NOTE: the AVAudioSession is owned by CallKit on a real device.

// Two-call model (Add Call / Swap / Conference / Attended Transfer). Forward-
// declared here so the call class below can reference the slots + notifiers.
class ICallCall;
static ICallCall *g_call = nullptr;   // active call
static ICallCall *g_held = nullptr;   // parked (held) call
// Internal VIDEO SIDECAR (bypasses PBX). iOS runs EXACTLY ONE video dialog at
// a time — two concurrent video dialogs crash PJSIP's iOS video stack. So a
// single g_video leg carries BOTH directions (sendrecv); we never place a
// second "reverse" leg, and we DECLINE any incoming sidecar that arrives while
// one is already up.
static ICallCall *g_video = nullptr;
// An incoming video request HELD while the app is backgrounded (the user
// answered the voice call from the CallKit lock-screen without opening iCall).
// The camera can't open in the background, so instead of auto-answering we
// "ring" this leg and surface a notification; accepted/declined from Swift.
static ICallCall *g_pendingVideo = nullptr;
static bool g_appForeground = false;   // mirrored from Swift scenePhase
// Last-seen decoded REMOTE video frame size (for aspect-correct rendering).
static int g_remoteVidW = 0;
static int g_remoteVidH = 0;
static VideoPreview *g_preview = nullptr;  // local camera self-view preview
static bool g_previewStarted = false;
static AudioMediaRecorder *g_recorder = nullptr;  // active call recorder (WAV)
static bool g_recording = false;
static AudioMediaPlayer *g_moh = nullptr;         // local music-on-hold player
static bool g_mohActive = false;                  // true while local MOH is playing
// SIP domains whose PBX doesn't relay music-on-hold (the fts family). For these
// we play app-side local MOH; every other domain keeps the standard SIP hold
// (its PBX plays MOH fine). Seeded with defaults; overridable from Swift via
// setMohDomains: (portal-managed list).
static bool domainInList(const std::string &server, const std::vector<std::string> &list) {
    std::string s = server;
    for (auto &c : s) c = (char)tolower((unsigned char)c);
    if (!s.empty() && s.back() == '.') s.pop_back();
    for (const auto &d : list) {
        if (s == d) return true;
        std::string suf = "." + d;
        if (s.size() > suf.size() && s.compare(s.size()-suf.size(), suf.size(), suf) == 0) return true;
    }
    return false;
}
static std::vector<std::string> g_mohDomains = {
    "fts.example.com", "fts3.example.com", "fts4.example.com" };
static bool mohDomainMatch(const std::string &server) { return domainInList(server, g_mohDomains); }
// Domains whose VIDEO routes INTERNALLY via the push gateway (bypass PBX).
// Others send the video sidecar down the voice path. Portal-overridable.
static std::vector<std::string> g_videoDomains = {
    "fts.example.com", "fts3.example.com", "fts4.example.com" };
static bool videoDomainMatch(const std::string &server) { return domainInList(server, g_videoDomains); }
static bool g_conf = false;           // audio conference bridge live?
static void notifyLocalVideo(UIView *local);
static UIView *startLocalPreviewView();
static void stopLocalPreviewView();

// Extract the user part from a SIP URI / name-addr.
// "Foo <sip:13340224@fts.example.com;transport=tls>" -> "13340224".
static std::string sipUser(const std::string &uri) {
    std::string s = uri;
    auto lt = s.find('<'); auto gt = s.find('>');
    if (lt != std::string::npos && gt != std::string::npos && gt > lt) s = s.substr(lt + 1, gt - lt - 1);
    auto sp = s.find("sips:"); if (sp != std::string::npos) s = s.substr(sp + 5);
    sp = s.find("sip:");       if (sp != std::string::npos) s = s.substr(sp + 4);
    auto at = s.find('@');     if (at != std::string::npos) s = s.substr(0, at);
    auto semi = s.find(';');   if (semi != std::string::npos) s = s.substr(0, semi);
    auto colon = s.find(':');  if (colon != std::string::npos) s = s.substr(0, colon);
    return s;
}
static void notifyHeld(ICallCall *held);
static void notifyConf(bool active);
static void notifyVideo(bool active, UIView *remote);

// ---- Call ------------------------------------------------------------------
class ICallCall : public Call {
public:
    int line;
    bool isVideoSidecar = false;   // internal video leg (bypasses PBX)
    ICallCall(Account &acc, int lineIdx, int callId = PJSUA_INVALID_ID)
        : Call(acc, callId), line(lineIdx) {}

    // Re-surface the sidecar's remote video + force send+recv so both ends
    // transmit. Safe to call repeatedly. Returns true once a real remote
    // render view was obtained.
    bool pollVideoOnce() {
        bool gotView = false;
        try {
            CallInfo ci2 = getInfo();
            UIView *rv = nil; bool hv = false;
            for (unsigned i = 0; i < ci2.media.size(); i++) {
                if (ci2.media[i].type == PJMEDIA_TYPE_VIDEO &&
                    ci2.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                    hv = true;
                    try {
                        CallVidSetStreamParam dp; dp.medIdx = i;
                        dp.dir = PJMEDIA_DIR_ENCODING_DECODING;
                        dp.capDev = g_curCaptureDev;
                        vidSetStream(PJSUA_CALL_VID_STRM_CHANGE_DIR, dp);
                    } catch (...) {}
                    try {
                        VideoWindow vw = ci2.media[i].videoWindow;
                        VideoWindowInfo wi = vw.getInfo();
                        rv = (__bridge UIView *)wi.winHandle.handle.window;
                        if (rv) gotView = true;
                        if (wi.size.w > 0 && wi.size.h > 0) {
                            g_remoteVidW = (int)wi.size.w; g_remoteVidH = (int)wi.size.h;
                        }
                    } catch (...) {}
                }
            }
            if (hv && g_ep && g_curCaptureDev >= 0) {
                try { g_ep->vidDevManager().setCaptureOrient(
                        g_curCaptureDev, PJMEDIA_ORIENT_ROTATE_270DEG, true); } catch (...) {}
            }
            notifyVideo(hv, rv);
            // Local self-view (PiP). Shares the running call capture device.
            if (hv) {
                UIView *lv = startLocalPreviewView();
                if (lv) notifyLocalVideo(lv);
            }
        } catch (...) {}
        return gotView;
    }

    virtual void onCallState(OnCallStateParam &prm) override {
        CallInfo ci;
        try { ci = getInfo(); } catch (...) { return; }
        std::string peer = ci.remoteUri;
        // Video SIDECAR: drives only the video delegate; it must NEVER touch
        // the voice call's peer/duration UI (that's g_call's job).
        if (isVideoSidecar) {
            if (ci.state == PJSIP_INV_STATE_CONFIRMED) {
                // The CALLER's remote render window can lag CONFIRMED, and the
                // callee can come up recvonly. Poll at several fixed delays:
                // each pass forces send+recv AND re-surfaces the remote view.
                ICallCall *self = this;
                double delays[] = {0.6, 1.2, 2.0, 3.0, 4.5};
                for (double d : delays) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (g_video == self) self->pollVideoOnce();
                    });
                }
            }
            if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
                ICallCall *self = this;
                if (g_video == self) g_video = nullptr;
                stopLocalPreviewView();
                notifyVideo(false, nil);
                dispatch_async(dispatch_get_main_queue(), ^{ delete self; });
            }
            return;
        }
        switch (ci.state) {
            case PJSIP_INV_STATE_CALLING:
            case PJSIP_INV_STATE_INCOMING:
                notifyCallState(SipCallStateCalling, line, peer); break;
            case PJSIP_INV_STATE_EARLY:
            case PJSIP_INV_STATE_CONNECTING:
                notifyCallState(SipCallStateRinging, line, peer); break;
            case PJSIP_INV_STATE_CONFIRMED:
                notifyCallState(SipCallStateConnected, line, peer); break;
            case PJSIP_INV_STATE_DISCONNECTED: {
                ICallCall *self = this;
                if (g_held == self) {
                    // The HELD call ended — clear it, leave the active call's UI alone.
                    g_held = nullptr;
                    notifyHeld(nullptr);
                    dispatch_async(dispatch_get_main_queue(), ^{ delete self; });
                } else {
                    if (g_call == self) g_call = nullptr;
                    // Finalise any in-progress recording so the WAV is playable.
                    if (g_recorder) { try { delete g_recorder; } catch (...) {} g_recorder = nullptr; g_recording = false; }
                    // Stop music-on-hold if the call ended while held.
                    if (g_moh) { try { delete g_moh; } catch (...) {} g_moh = nullptr; }
                    // Voice call ended → drop the internal video sidecar too.
                    if (g_video) { ICallCall *v = g_video; g_video = nullptr;
                        try { CallOpParam vp; vp.statusCode = PJSIP_SC_OK; v->hangup(vp); } catch (...) {}
                        notifyVideo(false, nil); }
                    g_conf = false; notifyConf(false);
                    if (g_call == nullptr && g_held != nullptr) {
                        // Active ended but a held call remains → promote it (unhold).
                        ICallCall *h = g_held; g_held = nullptr; g_call = h;
                        try { CallOpParam up(true); up.opt.audioCount = 1; up.opt.videoCount = 0;
                              up.opt.flag = PJSUA_CALL_UNHOLD; h->reinvite(up); } catch (...) {}
                        notifyHeld(nullptr);
                        std::string hp; try { hp = h->getInfo().remoteUri; } catch (...) {}
                        notifyCallState(SipCallStateConnected, h->line, hp);
                    } else {
                        notifyCallState(SipCallStateEnded, line, peer, ci.lastStatusCode, ci.lastReason);
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{ delete self; });
                }
                break;
            }
            default: break;
        }
    }

    virtual void onCallMediaState(OnCallMediaStateParam &prm) override {
        CallInfo ci;
        try { ci = getInfo(); } catch (...) { return; }
        for (unsigned i = 0; i < ci.media.size(); i++) {
            // Bridge audio on ACTIVE *and* REMOTE_HOLD (mirrors Android). When
            // the far end puts us on hold the stream goes REMOTE_HOLD; keeping
            // it bridged means we still play whatever the holder/PBX sends —
            // i.e. the music-on-hold — instead of dropping to silence.
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO &&
                (ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE ||
                 ci.media[i].status == PJSUA_CALL_MEDIA_REMOTE_HOLD)) {
                // Don't re-bridge the mic over local music-on-hold (would mix the
                // live mic back into the call mid-hold).
                if (this == g_call && g_mohActive) continue;
                try {
                    AudioMedia am = getAudioMedia(i);
                    AudDevManager &mgr = g_ep->audDevManager();
                    mgr.getCaptureDevMedia().startTransmit(am);   // mic  -> remote
                    am.startTransmit(mgr.getPlaybackDevMedia());  // remote -> speaker
                } catch (...) {}
            }
        }
        // Video UI is driven ONLY by the internal sidecar — never by the
        // voice call. Without this gate, a voice call that happens to carry
        // (or renegotiate) a video m-line would spuriously flip the iPhone
        // into the black video screen with no user tap.
        if (this == g_video) {
            UIView *remoteView = nil;
            bool hasVideo = false;
            for (unsigned i = 0; i < ci.media.size(); i++) {
                if (ci.media[i].type == PJMEDIA_TYPE_VIDEO &&
                    ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                    hasVideo = true;
                    try {
                        VideoWindow vw = ci.media[i].videoWindow;
                        VideoWindowInfo wi = vw.getInfo();
                        remoteView = (__bridge UIView *)wi.winHandle.handle.window;
                        if (wi.size.w > 0 && wi.size.h > 0) {
                            g_remoteVidW = (int)wi.size.w; g_remoteVidH = (int)wi.size.h;
                        }
                    } catch (...) {}
                }
            }
            // Rotate our capture to portrait so the far end doesn't see us
            // sideways (the iPhone sensor delivers landscape frames).
            if (hasVideo && g_ep && g_curCaptureDev >= 0) {
                try { g_ep->vidDevManager().setCaptureOrient(
                        g_curCaptureDev, PJMEDIA_ORIENT_ROTATE_270DEG, true); } catch (...) {}
            }
            notifyVideo(hasVideo, remoteView);
        }
    }
};

// Set when CallKit's answer fires before the SIP INVITE arrives (push wake).
static bool g_answerPending = false;

// Notify Swift of held-call / conference changes (defined now that ICallCall is complete).
static void notifyHeld(ICallCall *held) {
    std::string peer;
    if (held) { try { peer = held->getInfo().remoteUri; } catch (...) {} }
    NSString *p = held ? [NSString stringWithUTF8String:peer.c_str()] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        PjsipBridge *b = g_bridge;
        if ([b.delegate respondsToSelector:@selector(sipHeldCallChanged:)]) [b.delegate sipHeldCallChanged:p];
    });
}
static void notifyConf(bool active) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PjsipBridge *b = g_bridge;
        if ([b.delegate respondsToSelector:@selector(sipConferenceChanged:)]) [b.delegate sipConferenceChanged:active];
    });
}
static void notifyVideo(bool active, UIView *remote) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PjsipBridge *b = g_bridge;
        if ([b.delegate respondsToSelector:@selector(sipVideoChanged:remoteView:)])
            [b.delegate sipVideoChanged:active remoteView:remote];
    });
}
static void notifyLocalVideo(UIView *local) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PjsipBridge *b = g_bridge;
        if ([b.delegate respondsToSelector:@selector(sipLocalVideoChanged:)])
            [b.delegate sipLocalVideoChanged:local];
    });
}

// Start (idempotent) the local camera preview and return its render UIView,
// or nil. PJSIP shares the already-running call capture device, so this does
// NOT open the camera a second time.
static UIView *startLocalPreviewView() {
    if (!g_ep || g_curCaptureDev < 0) return nil;
    try {
        if (!g_preview) g_preview = new VideoPreview(g_curCaptureDev);
        if (!g_previewStarted) {
            VideoPreviewOpParam pp;
            pp.show = false;   // we attach the window into our own SwiftUI view
            g_preview->start(pp);
            g_previewStarted = true;
        }
        VideoWindow w = g_preview->getVideoWindow();
        VideoWindowInfo wi = w.getInfo();
        return (__bridge UIView *)wi.winHandle.handle.window;
    } catch (...) { return nil; }
}
static void stopLocalPreviewView() {
    try {
        if (g_preview && g_previewStarted) g_preview->stop();
    } catch (...) {}
    g_previewStarted = false;
    if (g_preview) { try { delete g_preview; } catch (...) {} g_preview = nullptr; }
    notifyLocalVideo(nil);
}

// ── Codec preferences (persisted in NSUserDefaults) ──────────────────────
// Video: store enabled short-names (e.g. "VP8"). Default = VP8 only (VP9/H264
// off out of the box) — mirrors Android. Audio: store DISABLED full ids; all
// enabled by default. ptime stays at PJSIP's default (20 ms) and is not exposed.
static void applyVideoCodecPrefs() {
    if (!g_ep) return;
    NSArray<NSString *> *en = [[NSUserDefaults standardUserDefaults] arrayForKey:@"videoCodecsEnabled"];
    if (en.count == 0) en = @[@"VP8"];
    try {
        const CodecInfoVector2 v = g_ep->videoCodecEnum2();
        for (size_t i = 0; i < v.size(); i++) {
            std::string id = v[i].codecId;                       // "VP8/97"
            NSString *nid = [NSString stringWithUTF8String:id.c_str()];
            bool on = false;
            for (NSString *p in en) { if ([nid hasPrefix:p]) { on = true; break; } }
            try { g_ep->videoCodecSetPriority(id, on ? 255 : 0); } catch (...) {}
        }
    } catch (...) {}
}
static void applyAudioCodecPrefs() {
    if (!g_ep) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *dis = [d arrayForKey:@"audioCodecsDisabled"];
    try {
        const CodecInfoVector2 c = g_ep->codecEnum2();
        // First run (no saved preference): default to ONLY G722, PCMU, PCMA
        // enabled — every other audio codec disabled but still user-selectable
        // (matches Android). Seed the disabled list once so later toggles
        // persist normally. Existing users with a saved list are untouched.
        if (dis == nil) {
            NSArray<NSString *> *keep = @[@"G722", @"PCMU", @"PCMA"];
            NSMutableArray<NSString *> *seed = [NSMutableArray array];
            for (size_t i = 0; i < c.size(); i++) {
                NSString *nid = [NSString stringWithUTF8String:c[i].codecId.c_str()];
                NSString *name = [[nid componentsSeparatedByString:@"/"] firstObject] ?: nid;
                bool keepIt = false;
                for (NSString *k in keep) {
                    if ([name caseInsensitiveCompare:k] == NSOrderedSame) { keepIt = true; break; }
                }
                if (!keepIt) [seed addObject:nid];
            }
            [d setObject:seed forKey:@"audioCodecsDisabled"];
            dis = seed;
        }
        for (size_t i = 0; i < c.size(); i++) {
            std::string id = c[i].codecId;
            NSString *nid = [NSString stringWithUTF8String:id.c_str()];
            bool off = [dis containsObject:nid];
            try { g_ep->codecSetPriority(id, off ? 0 : 128); } catch (...) {}
        }
    } catch (...) {}
}
// First active audio media of a call, or nullptr.
static AudioMedia *firstAudio(ICallCall *c) {
    try {
        CallInfo ci = c->getInfo();
        for (unsigned i = 0; i < ci.media.size(); i++) {
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO &&
                ci.media[i].status != PJSUA_CALL_MEDIA_NONE) {
                return new AudioMedia(c->getAudioMedia(i));
            }
        }
    } catch (...) {}
    return nullptr;
}

// ---- Account ---------------------------------------------------------------
class ICallAccount : public Account {
public:
    int line;
    ICallAccount(int lineIdx) : line(lineIdx) {}

    virtual void onRegState(OnRegStateParam &prm) override {
        bool active = false;
        try { active = getInfo().regIsActive; } catch (...) {}
        SipRegState st;
        if (prm.code / 100 == 2 && active) st = SipRegStateRegistered;
        else if (prm.code >= 400)          st = SipRegStateFailed;
        else if (prm.code / 100 == 2)      st = SipRegStateIdle;     // unregister 200
        else                               st = SipRegStateRegistering;
        notifyRegState(st, line, prm.code, prm.reason);
    }

    virtual void onIncomingCall(OnIncomingCallParam &iprm) override {
        // Internal VIDEO SIDECAR (X-iCall-Video header)? Auto-answer video-only
        // IFF we're already on a voice call with this same peer (anti-misuse).
        // No ring, no second-call UI — it just lights up video on the call.
        std::string whole; try { whole = iprm.rdata.wholeMsg; } catch (...) {}
        if (whole.find("X-iCall-Video") != std::string::npos) {
            ICallCall *vc = new ICallCall(*this, line, iprm.callId);
            vc->isVideoSidecar = true;
            std::string fromUser, peerUser;
            try { fromUser = sipUser(vc->getInfo().remoteUri); } catch (...) {}
            if (g_call) { try { peerUser = sipUser(g_call->getInfo().remoteUri); } catch (...) {} }
            // Decline unless: (a) we're on a voice call with this same peer
            // (anti-misuse) AND (b) we don't already have a video dialog up.
            // (b) is critical on iOS: a SECOND concurrent video dialog crashes
            // PJSIP's video stack. One sendrecv leg carries both directions.
            bool ok = (g_call != nullptr) && !fromUser.empty() &&
                      fromUser == peerUser && g_video == nullptr;
            if (!ok) {
                CallOpParam dp; dp.statusCode = PJSIP_SC_DECLINE;
                try { vc->hangup(dp); } catch (...) {}
                dispatch_async(dispatch_get_main_queue(), ^{ delete vc; });
                return;
            }
            // BACKGROUNDED: the peer added video but we answered the voice call
            // from the CallKit lock-screen without opening iCall. The camera
            // can't open in the background, so DON'T auto-answer — ring this
            // leg (180) to keep the peer's request alive and surface an
            // Accept/Decline alert. acceptPendingVideo answers it once the user
            // foregrounds the app; declinePendingVideo / timeout hangs it up.
            if (!g_appForeground) {
                g_pendingVideo = vc;
                CallOpParam rp; rp.statusCode = PJSIP_SC_RINGING;
                try { vc->answer(rp); } catch (...) {}
                NSString *p = [NSString stringWithUTF8String:fromUser.c_str()];
                NSInteger lineIdx = line;
                dispatch_async(dispatch_get_main_queue(), ^{
                    PjsipBridge *b = g_bridge;
                    if ([b.delegate respondsToSelector:@selector(sipIncomingVideoRequest:line:)]) {
                        [b.delegate sipIncomingVideoRequest:p line:lineIdx];
                    }
                });
                return;
            }
            g_video = vc;
            CallOpParam op; op.statusCode = PJSIP_SC_OK;
            op.opt.audioCount = 0; op.opt.videoCount = 1;   // sendrecv: send + render
            try { vc->answer(op); } catch (...) {}
            return;
        }
        ICallCall *call = new ICallCall(*this, line, iprm.callId);
        if (g_call) { delete g_call; }
        g_call = call;
        std::string peer;
        try { peer = call->getInfo().remoteUri; } catch (...) {}
        CallOpParam op;
        op.statusCode = g_answerPending ? PJSIP_SC_OK : PJSIP_SC_RINGING;
        try { call->answer(op); } catch (...) {}
        if (g_answerPending) {
            g_answerPending = false;
        } else {
            notifyCallState(SipCallStateRinging, line, peer);
        }
        NSString *p = [NSString stringWithUTF8String:peer.c_str()];
        NSInteger lineIdx = line;
        dispatch_async(dispatch_get_main_queue(), ^{
            PjsipBridge *b = g_bridge;
            if ([b.delegate respondsToSelector:@selector(sipIncomingCall:line:)]) {
                [b.delegate sipIncomingCall:p line:lineIdx];
            }
        });
    }

    virtual void onInstantMessage(OnInstantMessageParam &prm) override {
        std::string from = prm.fromUri;
        std::string body = prm.msgBody;
        NSString *f = [NSString stringWithUTF8String:from.c_str()];
        NSString *b = [NSString stringWithUTF8String:body.c_str()];
        NSInteger lineIdx = line;
        dispatch_async(dispatch_get_main_queue(), ^{
            PjsipBridge *br = g_bridge;
            if ([br.delegate respondsToSelector:@selector(sipMessageReceived:body:line:)]) {
                [br.delegate sipMessageReceived:f body:b line:lineIdx];
            }
        });
    }

    virtual void onInstantMessageStatus(OnInstantMessageStatusParam &prm) override {
        bool delivered = (prm.code / 100 == 2);
        NSString *to = [NSString stringWithUTF8String:prm.toUri.c_str()];
        NSInteger lineIdx = line;
        dispatch_async(dispatch_get_main_queue(), ^{
            PjsipBridge *br = g_bridge;
            if ([br.delegate respondsToSelector:@selector(sipMessageStatus:delivered:line:)]) {
                [br.delegate sipMessageStatus:to delivered:delivered line:lineIdx];
            }
        });
    }
};

static ICallAccount *g_acc[2] = {nullptr, nullptr};

// ---- Bridge ----------------------------------------------------------------
@implementation PjsipBridge

+ (instancetype)shared {
    static PjsipBridge *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PjsipBridge alloc] init]; g_bridge = s; });
    return s;
}

+ (NSString *)pjsipVersion {
    const char *v = pj_get_version();
    return v ? [NSString stringWithUTF8String:v] : @"unknown";
}

- (BOOL)startEngine:(NSError **)error {
    if (g_started) return YES;
    try {
        g_ep = new Endpoint();
        g_ep->libCreate();
        EpConfig epCfg;
        epCfg.uaConfig.userAgent = "iCall-iOS/0.1";
        epCfg.logConfig.level = 3;
        epCfg.logConfig.consoleLevel = 3;
        g_ep->libInit(epCfg);
        // One dedicated TCP + TLS transport PER LINE (distinct ephemeral source
        // port each) so each account registers over its own connection.
        for (int i = 0; i < 2; i++) {
            TransportConfig tcpCfg; g_tcpTid[i] = g_ep->transportCreate(PJSIP_TRANSPORT_TCP, tcpCfg);
            TransportConfig tlsCfg; g_tlsTid[i] = g_ep->transportCreate(PJSIP_TRANSPORT_TLS, tlsCfg);
        }
        g_ep->libStart();
        try { g_ep->audDevManager().setNullDev(); } catch (...) {}
        // Apply persisted codec preferences (defaults: video = VP8 only,
        // all audio enabled). User-selectable in Settings → Codecs (#59).
        applyVideoCodecPrefs();
        applyAudioCodecPrefs();
        // Discover front/back capture cameras for switchCamera().
        try {
            VidDevManager &vdm = g_ep->vidDevManager();
            for (unsigned i = 0; i < vdm.getDevCount(); i++) {
                VideoDevInfo vi = vdm.getDevInfo(i);
                if (vi.dir == PJMEDIA_DIR_CAPTURE || vi.dir == PJMEDIA_DIR_CAPTURE_RENDER) {
                    std::string nm = vi.name;
                    if (nm.find("Front") != std::string::npos || nm.find("front") != std::string::npos) g_frontCamId = (int)i;
                    else if (nm.find("Back") != std::string::npos || nm.find("back") != std::string::npos) g_backCamId = (int)i;
                }
            }
            g_curCaptureDev = (g_frontCamId >= 0) ? g_frontCamId : g_backCamId;
        } catch (...) {}
        g_started = true;
        return YES;
    } catch (Error &err) {
        if (error) *error = [NSError errorWithDomain:@"PjsipBridge" code:err.status
                                userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithUTF8String:err.info(true).c_str()]}];
        return NO;
    }
}

- (void)registerLine:(NSInteger)line
            username:(NSString *)username
            password:(NSString *)password
              server:(NSString *)server
         gatewayHost:(NSString *)gatewayHost
           transport:(NSString *)transport
                srtp:(NSString *)srtp {
    dispatch_async(dispatch_get_main_queue(), ^{
        int li = (int)line; if (li < 0 || li > 1) li = 0;
        std::string srtpMode = srtp ? std::string(srtp.lowercaseString.UTF8String) : "disabled";
        std::string user = username.UTF8String;
        std::string pass = password.UTF8String;
        std::string srv  = server.UTF8String;
        std::string gw   = gatewayHost.UTF8String;
        std::string tp   = transport.lowercaseString.UTF8String;

        bool tls = (tp == "tls");
        std::string scheme = tls ? "sips" : "sip";
        std::string port   = tls ? "5061" : "5060";
        g_tparam[li] = tls ? ";transport=tls" : ";transport=tcp";
        g_server[li] = srv;
        g_gateway[li] = gw;   // push gateway host — internal video target
        std::string registrar = scheme + ":" + gw + ":" + port + g_tparam[li];

        notifyRegState(SipRegStateRegistering, li, 0, "registering");
        try {
            if (g_acc[li]) { delete g_acc[li]; g_acc[li] = nullptr; }
            AccountConfig acfg;
            acfg.idUri = "sip:" + user + "@" + srv;
            acfg.regConfig.registrarUri = registrar;
            acfg.regConfig.timeoutSec = 60;
            acfg.regConfig.retryIntervalSec = 30;
            acfg.regConfig.firstRetryIntervalSec = 10;
            acfg.sipConfig.proxies.push_back(registrar);
            // Pin this account to ITS OWN transport (separate connection per line).
            acfg.sipConfig.transportId = tls ? g_tlsTid[li] : g_tcpTid[li];
            acfg.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", user, 0, pass));
            acfg.mediaConfig.transportConfig.port = 0;
            // Media encryption (SRTP) — default disabled.
            if (srtpMode == "mandatory") {
                acfg.mediaConfig.srtpUse = PJMEDIA_SRTP_MANDATORY;
                acfg.mediaConfig.srtpSecureSignaling = 1;
            } else if (srtpMode == "optional") {
                acfg.mediaConfig.srtpUse = PJMEDIA_SRTP_OPTIONAL;
                acfg.mediaConfig.srtpSecureSignaling = 0;
            } else {
                acfg.mediaConfig.srtpUse = PJMEDIA_SRTP_DISABLED;
                acfg.mediaConfig.srtpSecureSignaling = 0;
            }
            acfg.natConfig.contactRewriteUse = 1;
            acfg.natConfig.viaRewriteUse = 1;
            acfg.natConfig.sipOutboundUse = 1;
            acfg.natConfig.udpKaIntervalSec = 15;
            // Video: capable but audio-first. We do NOT auto-transmit video on
            // outgoing calls (escalate-from-audio model, like WhatsApp); incoming
            // video auto-shows. Capture/render devices are the iOS defaults.
            // Transmit outgoing video automatically so the video SIDECAR
            // actually SENDS the camera (matches Android). Voice calls are
            // unaffected because they explicitly set videoCount=0 (see
            // makeCall), so no video stream is created on them.
            acfg.videoConfig.autoTransmitOutgoing = true;
            acfg.videoConfig.autoShowIncoming     = true;
            acfg.videoConfig.defaultCaptureDevice = PJMEDIA_VID_DEFAULT_CAPTURE_DEV;
            acfg.videoConfig.defaultRenderDevice  = PJMEDIA_VID_DEFAULT_RENDER_DEV;
            g_acc[li] = new ICallAccount(li);
            g_acc[li]->create(acfg);
        } catch (Error &err) {
            notifyRegState(SipRegStateFailed, li, err.status, err.info(true));
        }
    });
}

- (void)unregisterLine:(NSInteger)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        int li = (int)line; if (li < 0 || li > 1) li = 0;
        try {
            if (g_call && g_call->line == li) { delete g_call; g_call = nullptr; }
            if (g_acc[li]) { g_acc[li]->setRegistration(false); delete g_acc[li]; g_acc[li] = nullptr; }
            notifyRegState(SipRegStateIdle, li, 0, "signed out");
        } catch (Error &err) {
            notifyRegState(SipRegStateFailed, li, err.status, err.info(true));
        }
    });
}

- (void)makeCall:(NSString *)number line:(NSInteger)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        int li = (int)line; if (li < 0 || li > 1) li = 0;
        if (!g_acc[li]) { notifyCallState(SipCallStateEnded, li, "not registered"); return; }
        std::string num = number.UTF8String;
        std::string uri = "sip:" + num + "@" + g_server[li] + g_tparam[li];
        try {
            if (g_call) {
                if (g_held == nullptr) {
                    // Add Call: park the current call on hold (don't drop it).
                    try { CallOpParam hp(true); g_call->setHold(hp); } catch (...) {}
                    g_held = g_call; g_call = nullptr;
                    notifyHeld(g_held);
                } else {
                    delete g_call; g_call = nullptr;
                }
            }
            ICallCall *call = new ICallCall(*g_acc[li], li);
            g_call = call;
            notifyCallState(SipCallStateCalling, li, num);
            CallOpParam op(true);   // include default media/SDP
            op.opt.audioCount = 1;  // voice only — video goes over the sidecar
            op.opt.videoCount = 0;
            call->makeCall(uri, op);
        } catch (Error &err) {
            notifyCallState(SipCallStateEnded, li, err.info(true));
        }
    });
}

- (void)sendMessage:(NSString *)toNumber body:(NSString *)body line:(NSInteger)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        int li = (int)line; if (li < 0 || li > 1) li = 0;
        if (!g_acc[li]) return;
        std::string num = toNumber.UTF8String;
        std::string uri = "sip:" + num + "@" + g_server[li] + g_tparam[li];
        std::string content = body.UTF8String;
        // pjsua2 Account has no IM send; use the pjsua C API directly.
        pj_str_t to = pj_str((char *)uri.c_str());
        pj_str_t mime = pj_str((char *)"text/plain");
        pj_str_t c = pj_str((char *)content.c_str());
        pjsua_im_send(g_acc[li]->getId(), &to, &mime, &c, NULL, NULL);
    });
}

- (void)answer {
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (g_call) {
                CallOpParam op;
                op.statusCode = PJSIP_SC_OK;   // 200 OK
                g_call->answer(op);
            } else {
                g_answerPending = true;   // INVITE not here yet (push wake)
            }
        } catch (...) {}
    });
}

- (void)hangup {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_answerPending = false;
        try {
            if (g_call) {
                CallOpParam op;
                op.statusCode = PJSIP_SC_DECLINE;
                g_call->hangup(op);
            }
        } catch (...) {}
    });
}

- (void)setMuted:(BOOL)muted {
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (!g_call || !g_ep) return;
            AudioMedia am = g_call->getAudioMedia(-1);
            AudDevManager &mgr = g_ep->audDevManager();
            if (muted) mgr.getCaptureDevMedia().stopTransmit(am);
            else       mgr.getCaptureDevMedia().startTransmit(am);
        } catch (...) {}
    });
}

- (void)setSpeaker:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *e = nil;
        [s overrideOutputAudioPort:(on ? AVAudioSessionPortOverrideSpeaker
                                       : AVAudioSessionPortOverrideNone)
                             error:&e];
        if (e) NSLog(@"[PjsipBridge] setSpeaker error: %@", e.localizedDescription);
    });
}

- (void)sendDtmf:(NSString *)digits {
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (g_call && digits.length) g_call->dialDtmf(std::string(digits.UTF8String));
        } catch (...) {}
    });
}

- (void)setHold:(BOOL)hold {
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (!g_call) return;
            int li = g_call->line; if (li < 0 || li > 1) li = 0;
            // The fts-family PBXs don't relay MOH for the callee leg → play
            // app-side local music for those domains. Every other domain keeps
            // the standard SIP hold (its PBX generates MOH correctly).
            bool useLocalMoh = mohDomainMatch(g_server[li]);
            CallOpParam prm(true);
            prm.opt.audioCount = 1;
            prm.opt.videoCount = 0;
            if (useLocalMoh) {
                AudioMedia *am = firstAudio(g_call);
                if (am && g_ep) {
                    AudDevManager &mgr = g_ep->audDevManager();
                    if (hold) {
                        // Keep the call ACTIVE (encoder running) and swap mic→music;
                        // mute the far end locally. PJSIP pauses the encoder on a
                        // real sendonly hold so the music wouldn't reach them.
                        g_mohActive = true;
                        try { mgr.getCaptureDevMedia().stopTransmit(*am); } catch (...) {}
                        if (!g_moh) {
                            NSString *path = [[NSBundle mainBundle] pathForResource:@"moh" ofType:@"wav"];
                            if (path) {
                                try {
                                    g_moh = new AudioMediaPlayer();
                                    g_moh->createPlayer(std::string(path.UTF8String), 0);  // loop
                                    g_moh->startTransmit(*am);                            // music → far end
                                } catch (...) { if (g_moh) { try { delete g_moh; } catch (...) {} g_moh = nullptr; } }
                            }
                        }
                        try { am->stopTransmit(mgr.getPlaybackDevMedia()); } catch (...) {}
                    } else {
                        g_mohActive = false;
                        if (g_moh) { try { delete g_moh; } catch (...) {} g_moh = nullptr; }
                        try { mgr.getCaptureDevMedia().startTransmit(*am); } catch (...) {}
                        try { am->startTransmit(mgr.getPlaybackDevMedia()); } catch (...) {}
                    }
                }
                if (am) delete am;
            } else {
                // STANDARD SIP hold (sendonly). UNHOLD must pass PJSUA_CALL_UNHOLD
                // to regenerate a sendrecv offer.
                if (hold) {
                    g_call->setHold(prm);
                } else {
                    prm.opt.flag = PJSUA_CALL_UNHOLD;
                    g_call->reinvite(prm);
                }
            }
        } catch (...) {}
    });
}

- (void)setMohDomains:(NSArray<NSString *> *)domains {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (domains.count == 0) return;
        std::vector<std::string> v;
        for (NSString *d in domains) {
            NSString *t = [[d stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
            if (t.length) v.push_back(std::string(t.UTF8String));
        }
        if (!v.empty()) g_mohDomains = v;
    });
}

- (void)setVideoDomains:(NSArray<NSString *> *)domains {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (domains.count == 0) return;
        std::vector<std::string> v;
        for (NSString *d in domains) {
            NSString *t = [[d stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
            if (t.length) v.push_back(std::string(t.UTF8String));
        }
        if (!v.empty()) g_videoDomains = v;
    });
}

- (void)blindTransfer:(NSString *)number {
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (!g_call) return;
            int li = g_call->line; if (li < 0 || li > 1) li = 0;
            std::string uri = "sip:" + std::string(number.UTF8String) + "@" + g_server[li] + g_tparam[li];
            CallOpParam prm;
            g_call->xfer(uri, prm);
        } catch (...) {}
    });
}

// ---- Multi-call (Add Call via makeCall auto-hold; here: swap/merge/xfer) ----
- (void)swapCalls {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_call || !g_held || g_conf) return;
        try {
            CallOpParam hp(true); hp.opt.audioCount = 1; hp.opt.videoCount = 0;
            CallOpParam up(true); up.opt.audioCount = 1; up.opt.videoCount = 0;
            up.opt.flag = PJSUA_CALL_UNHOLD;
            g_call->setHold(hp);
            g_held->reinvite(up);
            ICallCall *tmp = g_call; g_call = g_held; g_held = tmp;
            notifyHeld(g_held);
            std::string p; try { p = g_call->getInfo().remoteUri; } catch (...) {}
            notifyCallState(SipCallStateConnected, g_call->line, p);
        } catch (...) {}
    });
}

- (void)mergeConference {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_call || !g_held || g_conf || !g_ep) return;
        try { CallOpParam up(true); up.opt.audioCount = 1; up.opt.videoCount = 0;
              up.opt.flag = PJSUA_CALL_UNHOLD; g_held->reinvite(up); } catch (...) {}  // unhold held
        AudioMedia *a = firstAudio(g_call);
        AudioMedia *h = firstAudio(g_held);
        if (a && h) {
            try {
                a->startTransmit(*h); h->startTransmit(*a);
                AudDevManager &mgr = g_ep->audDevManager();
                mgr.getCaptureDevMedia().startTransmit(*h);
                h->startTransmit(mgr.getPlaybackDevMedia());
                g_conf = true; notifyConf(true); notifyHeld(nullptr);
            } catch (...) {}
        }
        if (a) delete a; if (h) delete h;
    });
}

- (void)splitConference {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_conf || !g_call || !g_held || !g_ep) return;
        AudioMedia *a = firstAudio(g_call);
        AudioMedia *h = firstAudio(g_held);
        try {
            if (a && h) {
                a->stopTransmit(*h); h->stopTransmit(*a);
                AudDevManager &mgr = g_ep->audDevManager();
                mgr.getCaptureDevMedia().stopTransmit(*h);
                h->stopTransmit(mgr.getPlaybackDevMedia());
            }
            CallOpParam prm(true); g_held->setHold(prm);
        } catch (...) {}
        if (a) delete a; if (h) delete h;
        g_conf = false; notifyConf(false); notifyHeld(g_held);
    });
}

- (void)attendedTransfer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_call || !g_held) return;
        try { CallOpParam prm; g_held->xferReplaces(*g_call, prm); } catch (...) {}
    });
}

- (void)endHeldCall {
    dispatch_async(dispatch_get_main_queue(), ^{
        try { if (g_held) { CallOpParam prm; prm.statusCode = PJSIP_SC_OK; g_held->hangup(prm); } } catch (...) {}
    });
}

// ---- Video (escalate from audio; WhatsApp-style) ----
// Video is carried on an INTERNAL sidecar (bypasses the PBX), NOT a re-INVITE
// on the PBX-routed voice call (the PBX is voice-only and strips m=video).
// See INTERNAL_VIDEO_DESIGN.md + route[inv_internal_video] on the gateway.
- (void)startVideo {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_call || g_video) return;
        try {
            int li = g_call->line; if (li < 0 || li > 1) li = 0;
            if (!g_acc[li]) return;
            std::string peer = sipUser(g_call->getInfo().remoteUri);
            if (peer.empty()) return;
            std::string corr; try { corr = g_call->getInfo().callIdString; } catch (...) {}
            if (corr.empty()) corr = "icall-video";
            // Routing decision (portal-managed): fts-family domains → R-URI =
            // push gateway so OpenSIPS routes via route[inv_internal_video]
            // (internal rtpengine, bypass PBX). Other domains → R-URI = the
            // voice SIP server so OpenSIPS forwards down the voice path.
            std::string vhost = videoDomainMatch(g_server[li]) ? g_gateway[li] : g_server[li];
            std::string uri = "sip:" + peer + "@" + vhost + g_tparam[li];
            ICallCall *vc = new ICallCall(*g_acc[li], li);
            vc->isVideoSidecar = true;
            g_video = vc;
            CallOpParam op(true);
            op.opt.audioCount = 0; op.opt.videoCount = 1;
            SipHeader h; h.hName = "X-iCall-Video"; h.hValue = corr;
            op.txOption.headers.push_back(h);
            vc->makeCall(uri, op);
        } catch (...) {}
    });
}
- (void)stopVideo {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_video) { notifyVideo(false, nil); return; }
        try { CallOpParam op; op.statusCode = PJSIP_SC_OK; g_video->hangup(op); } catch (...) {}
        // g_video is cleared + deleted in onCallState's sidecar branch.
    });
}
// Mirrored from Swift's scenePhase so onIncomingCall (PJSIP thread) knows
// whether the app is foreground and can open the camera for a video request.
- (void)setAppForeground:(BOOL)fg {
    g_appForeground = fg ? true : false;
}
// User ACCEPTED the lock-screen incoming-video alert. We're foregrounded now,
// so answer the held request with video (becomes the single g_video leg).
- (void)acceptPendingVideo {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_pendingVideo) return;
        ICallCall *vc = g_pendingVideo;
        g_pendingVideo = nullptr;
        if (g_video != nullptr) {
            // A video dialog already came up — decline this one to keep ONE leg.
            try { CallOpParam dp; dp.statusCode = PJSIP_SC_DECLINE; vc->hangup(dp); } catch (...) {}
            dispatch_async(dispatch_get_main_queue(), ^{ delete vc; });
            return;
        }
        g_video = vc;
        try {
            CallOpParam op; op.statusCode = PJSIP_SC_OK;
            op.opt.audioCount = 0; op.opt.videoCount = 1;   // sendrecv: send + render
            vc->answer(op);
        } catch (...) {}
    });
}
// User DECLINED (or the alert timed out). Hang up the held request; the voice
// call continues. vc is freed after the callback unwinds (mirrors the decline
// path in onIncomingCall) so we never delete a director mid-callback.
- (void)declinePendingVideo {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_pendingVideo) return;
        ICallCall *vc = g_pendingVideo;
        g_pendingVideo = nullptr;
        try { CallOpParam dp; dp.statusCode = PJSIP_SC_DECLINE; vc->hangup(dp); } catch (...) {}
        dispatch_async(dispatch_get_main_queue(), ^{ delete vc; });
    });
}
- (void)switchCamera {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_video || !g_ep) return;
        try {
            // Toggle to the "other" capture device (front <-> back).
            int cur = g_curCaptureDev;
            int next = (cur == g_frontCamId) ? g_backCamId : g_frontCamId;
            if (next < 0) return;
            CallInfo ci = g_video->getInfo();
            for (unsigned i = 0; i < ci.media.size(); i++) {
                if (ci.media[i].type == PJMEDIA_TYPE_VIDEO &&
                    ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                    CallVidSetStreamParam p; p.medIdx = i; p.capDev = next;
                    g_video->vidSetStream(PJSUA_CALL_VID_STRM_CHANGE_CAP_DEV, p);
                    g_curCaptureDev = next;
                }
            }
        } catch (...) {}
    });
}
- (void)setVideoMuted:(BOOL)muted {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_video) return;
        try {
            CallInfo ci = g_video->getInfo();
            for (unsigned i = 0; i < ci.media.size(); i++) {
                if (ci.media[i].type == PJMEDIA_TYPE_VIDEO) {
                    CallVidSetStreamParam p; p.medIdx = i;
                    g_video->vidSetStream(muted ? PJSUA_CALL_VID_STRM_STOP_TRANSMIT
                                                : PJSUA_CALL_VID_STRM_START_TRANSMIT, p);
                }
            }
        } catch (...) {}
    });
}
- (CGSize)remoteVideoSize {
    return CGSizeMake((CGFloat)g_remoteVidW, (CGFloat)g_remoteVidH);
}

// Record BOTH directions of the active call: transmit the call's remote audio
// AND the mic capture into one WAV recorder. Files land in Documents (visible
// in the Files app via UIFileSharingEnabled). Deleting the recorder finalises
// the WAV header so the file is playable.
- (void)setRecording:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (on) {
            if (g_recording || !g_call || !g_ep) return;
            try {
                AudioMedia *am = firstAudio(g_call);
                if (!am) return;
                NSString *docs = NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
                NSString *fname = [NSString stringWithFormat:@"iCall_%@.wav",
                                   [df stringFromDate:[NSDate date]]];
                NSString *path = [docs stringByAppendingPathComponent:fname];
                g_recorder = new AudioMediaRecorder();
                g_recorder->createRecorder(std::string(path.UTF8String));
                am->startTransmit(*g_recorder);                            // remote → file
                g_ep->audDevManager().getCaptureDevMedia().startTransmit(*g_recorder); // mic → file
                delete am;
                g_recording = true;
            } catch (...) {
                if (g_recorder) { try { delete g_recorder; } catch (...) {} g_recorder = nullptr; }
                g_recording = false;
            }
        } else {
            // Deleting the recorder stops the transmits + finalises the WAV.
            if (g_recorder) { try { delete g_recorder; } catch (...) {} g_recorder = nullptr; }
            g_recording = false;
        }
    });
}

// ── Codec selection (Settings → Codecs, #59) ───────────────────────────
- (NSArray<NSDictionary *> *)videoCodecList {
    NSMutableArray *out = [NSMutableArray array];
    if (!g_ep) return out;
    try {
        const CodecInfoVector2 v = g_ep->videoCodecEnum2();
        for (size_t i = 0; i < v.size(); i++) {
            NSString *nid = [NSString stringWithUTF8String:v[i].codecId.c_str()];
            NSString *name = [[nid componentsSeparatedByString:@"/"] firstObject] ?: nid;
            [out addObject:@{ @"id": nid, @"name": name, @"enabled": @(v[i].priority > 0) }];
        }
    } catch (...) {}
    return out;
}
- (NSArray<NSDictionary *> *)audioCodecList {
    NSMutableArray *out = [NSMutableArray array];
    if (!g_ep) return out;
    try {
        const CodecInfoVector2 c = g_ep->codecEnum2();
        for (size_t i = 0; i < c.size(); i++) {
            NSString *nid = [NSString stringWithUTF8String:c[i].codecId.c_str()];
            NSString *name = [[nid componentsSeparatedByString:@"/"] firstObject] ?: nid;
            [out addObject:@{ @"id": nid, @"name": name, @"enabled": @(c[i].priority > 0) }];
        }
    } catch (...) {}
    return out;
}

// Live stats for the in-call Information sheet: negotiated audio codec + the
// current call-state text. Transport/AOR/server are already known to Swift
// (SipEngine.currentAor/currentTransport per line).
- (NSDictionary *)currentCallStats {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!g_call) return d;
    try {
        CallInfo ci = g_call->getInfo();
        d[@"state"] = [NSString stringWithUTF8String:ci.stateText.c_str()];
        for (unsigned i = 0; i < ci.media.size(); i++) {
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO) {
                try {
                    StreamInfo si = g_call->getStreamInfo(i);
                    if (!si.codecName.empty())
                        d[@"codec"] = [NSString stringWithUTF8String:si.codecName.c_str()];
                } catch (...) {}
                break;
            }
        }
    } catch (...) {}
    return d;
}

- (void)setVideoCodecEnabled:(NSString *)codecId enabled:(BOOL)enabled {
    NSString *pref = [[codecId componentsSeparatedByString:@"/"] firstObject] ?: codecId;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *cur = [d arrayForKey:@"videoCodecsEnabled"] ?: @[@"VP8"];
    NSMutableArray *list = [cur mutableCopy];
    if (enabled) { if (![list containsObject:pref]) [list addObject:pref]; }
    else { [list removeObject:pref]; }
    [d setObject:list forKey:@"videoCodecsEnabled"];
    dispatch_async(dispatch_get_main_queue(), ^{ applyVideoCodecPrefs(); });
}
- (void)setAudioCodecEnabled:(NSString *)codecId enabled:(BOOL)enabled {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *dis = [([d arrayForKey:@"audioCodecsDisabled"] ?: @[]) mutableCopy];
    if (enabled) { [dis removeObject:codecId]; }
    else { if (![dis containsObject:codecId]) [dis addObject:codecId]; }
    [d setObject:dis forKey:@"audioCodecsDisabled"];
    dispatch_async(dispatch_get_main_queue(), ^{ applyAudioCodecPrefs(); });
}

- (void)onCallKitAudioActivated {
    dispatch_async(dispatch_get_main_queue(), ^{
        pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
    });
}

- (void)onCallKitAudioDeactivated {
    dispatch_async(dispatch_get_main_queue(), ^{
        try { if (g_ep) g_ep->audDevManager().setNullDev(); } catch (...) {}
    });
}

@end
