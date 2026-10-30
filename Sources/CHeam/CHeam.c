#include "CHeam.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>

// MARK: - HID temperature sensors (private API, declared here)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef svc, int64_t type, int32_t options, int64_t timeout);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef svc, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15

int heam_read_temps(double *values, char *names, int maxn) {
    static IOHIDEventSystemClientRef client;
    if (!client) client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return 0;

    int page = 0xff00, usage = 5;
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(pageNum); CFRelease(usageNum);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    int n = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && n < maxn; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        double v = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
        CFRelease(ev);

        char *dst = names + (size_t)n * HEAM_NAME_LEN;
        dst[0] = 0;
        CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (name) {
            if (CFGetTypeID(name) == CFStringGetTypeID())
                CFStringGetCString(name, dst, HEAM_NAME_LEN, kCFStringEncodingUTF8);
            CFRelease(name);
        }
        values[n++] = v;
    }
    CFRelease(services);
    return n;
}

// MARK: - SMC

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData layout mismatch");

enum { kSMCReadBytes = 5, kSMCWriteBytes = 6, kSMCGetKeyInfo = 9 };

static io_connect_t conn;

static uint32_t key_to_u32(const char *k) {
    return ((uint32_t)(uint8_t)k[0] << 24) | ((uint32_t)(uint8_t)k[1] << 16) |
           ((uint32_t)(uint8_t)k[2] << 8) | (uint32_t)(uint8_t)k[3];
}

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &outSize);
}

int heam_smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static int smc_key_info(const char *key, SMCKeyInfoData *info) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.data8 = kSMCGetKeyInfo;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

int heam_smc_read(const char *key, uint8_t *bytes, uint32_t *size, char type[5]) {
    if (heam_smc_open() != 0) return -1;
    SMCKeyInfoData info;
    if (smc_key_info(key, &info) != 0) return -1;

    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadBytes;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;

    uint32_t n = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(bytes, out.bytes, n);
    *size = n;
    type[0] = (info.dataType >> 24) & 0xff; type[1] = (info.dataType >> 16) & 0xff;
    type[2] = (info.dataType >> 8) & 0xff;  type[3] = info.dataType & 0xff;
    type[4] = 0;
    return 0;
}

int heam_smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    if (heam_smc_open() != 0) return -1;
    SMCKeyInfoData info;
    if (smc_key_info(key, &info) != 0) return -1;
    if (size != info.dataSize || size > 32) return -1;

    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key_to_u32(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCWriteBytes;
    memcpy(in.bytes, bytes, size);
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    return 0;
}

// MARK: - Process responsibility (private libsystem API)

extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

pid_t heam_responsible_pid(pid_t pid) {
    pid_t r = responsibility_get_pid_responsible_for_pid(pid);
    return r > 0 ? r : pid;
}
