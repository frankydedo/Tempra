//
//  Tempra-Bridging-Header.h
//  Private IOKit HID declarations used to read Apple Silicon temperature sensors.
//  These symbols live in IOKit.framework but are not in the public SDK headers.
//

#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <libproc.h>
#import "SMC.h"

// IOHIDEventRef is a CF type; declared as CFTypeRef so Swift manages it via Unmanaged.
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFTypeRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);

// kIOHIDEventTypeTemperature
#define TEMPRA_HID_EVENT_TYPE_TEMPERATURE 15
