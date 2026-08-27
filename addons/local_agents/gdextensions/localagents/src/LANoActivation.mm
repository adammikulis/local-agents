#include "LANoActivation.hpp"

#import <AppKit/AppKit.h>

void la_prohibit_activation() {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}
