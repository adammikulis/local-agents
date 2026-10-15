#include "LANoActivation.hpp"

#import <AppKit/AppKit.h>
#include <pthread.h>

void la_agent_process_policy() {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid != nil && [bid isEqualToString:@"com.localagents.godot-agent"]) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        // A foreground app's main thread and no App Nap, so a timed run costs what a watched one does.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        static id<NSObject> activity = [[[NSProcessInfo processInfo]
                beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical)
                                  reason:@"agent run"] retain];
        (void)activity;
    }
}
