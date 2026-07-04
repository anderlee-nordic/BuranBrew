#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void ambient_init(void);
int ambient_read_centi_c(int16_t *out);
#ifdef __cplusplus
}
#endif
