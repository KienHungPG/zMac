#include "CSMC.h"
#include <string.h>

// Layout theo AppleSMC user client (80 byte). Giữ alignment mặc định.
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam phải đúng 80 byte");

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static kern_return_t call(io_connect_t conn, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCParam), out, &outSize);
    if (kr != KERN_SUCCESS) return kr;
    // result != 0: key không tồn tại (0x84) hoặc lỗi SMC.
    return out->result == 0 ? KERN_SUCCESS : (kern_return_t)(0x10000 | out->result);
}

kern_return_t zsmc_open(io_connect_t *conn) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, conn);
    IOObjectRelease(svc);
    return kr;
}

void zsmc_close(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

kern_return_t zsmc_get_info(io_connect_t conn, const char *key, zsmc_key_info *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    info->dataSize = out.keyInfo.dataSize;
    info->dataType = out.keyInfo.dataType;
    return KERN_SUCCESS;
}

kern_return_t zsmc_read(io_connect_t conn, const char *key, uint8_t *outBytes, uint32_t *size, uint32_t *type) {
    zsmc_key_info info;
    kern_return_t kr = zsmc_get_info(conn, key, &info);
    if (kr != KERN_SUCCESS) return kr;
    if (info.dataSize > 32) return kIOReturnOverrun;

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    memcpy(outBytes, out.bytes, info.dataSize);
    if (size) *size = info.dataSize;
    if (type) *type = info.dataType;
    return KERN_SUCCESS;
}

kern_return_t zsmc_write(io_connect_t conn, const char *key, const uint8_t *data, uint32_t size) {
    zsmc_key_info info;
    kern_return_t kr = zsmc_get_info(conn, key, &info);
    if (kr != KERN_SUCCESS) return kr;
    if (info.dataSize != size || size > 32) return kIOReturnBadArgument;

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = kSMCWriteKey;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, data, size);
    return call(conn, &in, &out);
}
