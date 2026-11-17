#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

// Truy cập AppleSMC qua IOConnectCallStructMethod. Đọc không cần root, ghi cần root.
// Trả về 0 khi thành công, mã lỗi kern_return_t / SMC khác 0 khi thất bại.

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;   // FourCC kiểu dữ liệu, vd 'ui8 ', 'hex_', 'flt '
} zsmc_key_info;

kern_return_t zsmc_open(io_connect_t *conn);
void zsmc_close(io_connect_t conn);

/// key: 4 ký tự ASCII. Ghi tối đa 32 byte vào out, cập nhật *size.
kern_return_t zsmc_get_info(io_connect_t conn, const char *key, zsmc_key_info *info);
kern_return_t zsmc_read(io_connect_t conn, const char *key, uint8_t *out, uint32_t *size, uint32_t *type);
/// size phải bằng dataSize của key.
kern_return_t zsmc_write(io_connect_t conn, const char *key, const uint8_t *data, uint32_t size);

#endif
