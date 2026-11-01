//
//  SMC.c
//  Minimal read-only access to the System Management Controller (fan speeds), through the
//  AppleSMC user client. No privileges are needed to read keys.
//

#include "SMC.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPowerLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key;
    SMCVersion version;
    SMCPowerLimit powerLimit;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData;

enum { kSMCUserClientCall = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t connection = 0;

static UInt32 fourCC(const char *s) {
    return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3];
}

int tempra_smc_open(void) {
    if (connection) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? 0 : -1;
}

void tempra_smc_close(void) {
    if (connection) IOServiceClose(connection);
    connection = 0;
}

int tempra_smc_read(const char *key, double *value) {
    if (!connection || strlen(key) != 4) return -1;
    SMCKeyData input = {0}, output = {0};
    size_t size = sizeof(output);

    input.key = fourCC(key);
    input.data8 = kSMCGetKeyInfo;
    if (IOConnectCallStructMethod(connection, kSMCUserClientCall, &input, sizeof(input), &output, &size) != KERN_SUCCESS
        || output.result) return -1;
    UInt32 dataSize = output.keyInfo.dataSize, dataType = output.keyInfo.dataType;

    input.keyInfo.dataSize = dataSize;
    input.data8 = kSMCReadKey;
    memset(&output, 0, sizeof(output));
    size = sizeof(output);
    if (IOConnectCallStructMethod(connection, kSMCUserClientCall, &input, sizeof(input), &output, &size) != KERN_SUCCESS
        || output.result) return -1;

    const unsigned char *b = output.bytes;
    if (dataType == fourCC("flt ") && dataSize == 4) {
        float f; memcpy(&f, b, 4); *value = f;          // Apple Silicon: native little-endian float
    } else if (dataType == fourCC("fpe2") && dataSize == 2) {
        *value = ((b[0] << 8) | b[1]) / 4.0;           // Intel: unsigned 14.2 fixed point
    } else if (dataType == fourCC("ui8 ")) {
        *value = b[0];
    } else if (dataType == fourCC("ui16")) {
        *value = (b[0] << 8) | b[1];
    } else if (dataType == fourCC("ui32")) {
        *value = ((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3];
    } else {
        return -2;
    }
    return 0;
}
