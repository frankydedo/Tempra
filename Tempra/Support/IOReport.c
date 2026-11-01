//
//  IOReport.c
//  GPU energy from the private IOReport library ("Energy Model" group, "GPU Energy" channel).
//  Loaded with dlopen so Tempra still launches if a future macOS drops the library.
//  On macOS 27 the CPU, ANE and DRAM channels read zero without privileges; GPU energy works.
//

#include "IOReport.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <time.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
typedef CFMutableDictionaryRef (*CopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesFn)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int64_t (*SimpleGetIntegerValueFn)(CFDictionaryRef, int32_t);
typedef CFStringRef (*ChannelGetStringFn)(CFDictionaryRef);

static CreateSamplesFn createSamples;
static CreateSamplesDeltaFn createSamplesDelta;
static SimpleGetIntegerValueFn simpleGetIntegerValue;
static ChannelGetStringFn channelGetName, channelGetUnit;

static IOReportSubscriptionRef subscription;
static CFMutableDictionaryRef subscribedChannels;
static CFDictionaryRef previous;
static double previousTime;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int tempra_ioreport_open(void) {
    if (subscription) return 0;
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!lib) return -1;
    CopyChannelsInGroupFn copyChannels = (CopyChannelsInGroupFn)dlsym(lib, "IOReportCopyChannelsInGroup");
    CreateSubscriptionFn createSubscription = (CreateSubscriptionFn)dlsym(lib, "IOReportCreateSubscription");
    createSamples = (CreateSamplesFn)dlsym(lib, "IOReportCreateSamples");
    createSamplesDelta = (CreateSamplesDeltaFn)dlsym(lib, "IOReportCreateSamplesDelta");
    simpleGetIntegerValue = (SimpleGetIntegerValueFn)dlsym(lib, "IOReportSimpleGetIntegerValue");
    channelGetName = (ChannelGetStringFn)dlsym(lib, "IOReportChannelGetChannelName");
    channelGetUnit = (ChannelGetStringFn)dlsym(lib, "IOReportChannelGetUnitLabel");
    if (!copyChannels || !createSubscription || !createSamples || !createSamplesDelta
        || !simpleGetIntegerValue || !channelGetName || !channelGetUnit) return -1;

    CFMutableDictionaryRef channels = copyChannels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return -1;
    subscription = createSubscription(NULL, channels, &subscribedChannels, 0, NULL);
    CFRelease(channels);
    return subscription ? 0 : -1;
}

static double joules(int64_t value, CFStringRef unit) {
    if (CFStringCompare(unit, CFSTR("nJ"), 0) == kCFCompareEqualTo) return value / 1e9;
    if (CFStringCompare(unit, CFSTR("uJ"), 0) == kCFCompareEqualTo) return value / 1e6;
    if (CFStringCompare(unit, CFSTR("mJ"), 0) == kCFCompareEqualTo) return value / 1e3;
    return value;
}

double tempra_ioreport_gpu_watts(void) {
    if (!subscription) return -1;
    CFDictionaryRef current = createSamples(subscription, subscribedChannels, NULL);
    double time = now_seconds();
    if (!current) return -1;
    double watts = -1;
    if (previous && time > previousTime) {
        CFDictionaryRef delta = createSamplesDelta(previous, current, NULL);
        CFArrayRef items = delta ? CFDictionaryGetValue(delta, CFSTR("IOReportChannels")) : NULL;
        if (items) {
            double energy = 0;
            for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
                CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
                CFStringRef name = channelGetName(item);
                if (name && CFStringCompare(name, CFSTR("GPU Energy"), 0) == kCFCompareEqualTo) {
                    energy += joules(simpleGetIntegerValue(item, 0), channelGetUnit(item));
                }
            }
            watts = energy / (time - previousTime);
        }
        if (delta) CFRelease(delta);
    }
    if (previous) CFRelease(previous);
    previous = current;
    previousTime = time;
    return watts;
}
