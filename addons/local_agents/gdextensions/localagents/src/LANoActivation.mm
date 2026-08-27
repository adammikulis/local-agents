#include "LANoActivation.hpp"

#import <AppKit/AppKit.h>

void la_prohibit_activation() {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid != nil && [bid isEqualToString:@"com.localagents.godot-agent"]) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    }
}
