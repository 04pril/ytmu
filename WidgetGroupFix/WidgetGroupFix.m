#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// SideStore provisions the app's original groups with a team-ID suffix. The
// stock widget and app still request the unsuffixed identifiers embedded in
// Google's binaries, so both processes must resolve them to their own signed
// entitlements before opening a shared container or suite.
static NSArray<NSString *> *signedGroups(void) {
    static NSArray<NSString *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // SecTask is present on iOS but omitted from the public SDK headers.
        CFTypeRef (*createTask)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        CFTypeRef (*copyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *) =
            dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
        if (createTask == NULL || copyEntitlement == NULL) return;
        CFTypeRef task = createTask(kCFAllocatorDefault);
        if (task == NULL) return;
        CFTypeRef value = copyEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
        CFRelease(task);
        if (value != NULL) {
            if (CFGetTypeID(value) == CFArrayGetTypeID()) {
                groups = [(__bridge NSArray *)value copy];
            }
            CFRelease(value);
        }
    });
    return groups;
}

static NSString *resolvedGroup(NSString *requested) {
    if (![requested hasPrefix:@"group.com.google."]) return requested;
    NSArray<NSString *> *groups = signedGroups();
    if ([groups containsObject:requested]) return requested;
    NSString *prefix = [requested stringByAppendingString:@"."];
    for (NSString *group in groups) {
        if ([group hasPrefix:prefix]) return group;
    }
    return requested;
}

static NSURL *(*originalContainerURL)(id, SEL, NSString *);
static NSURL *replacementContainerURL(id manager, SEL selector, NSString *group) {
    return originalContainerURL(manager, selector, resolvedGroup(group));
}

static id (*originalSuiteDefaults)(id, SEL, NSString *);
static id replacementSuiteDefaults(id defaults, SEL selector, NSString *group) {
    return originalSuiteDefaults(defaults, selector, resolvedGroup(group));
}

__attribute__((constructor)) static void installGroupFix(void) {
    Method container = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
    if (container != NULL) {
        originalContainerURL = (void *)method_setImplementation(container, (IMP)replacementContainerURL);
    }
    if (suite != NULL) {
        originalSuiteDefaults = (void *)method_setImplementation(suite, (IMP)replacementSuiteDefaults);
    }
}
