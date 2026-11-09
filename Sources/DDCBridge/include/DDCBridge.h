#ifndef DDCBridge_h
#define DDCBridge_h
#include <stdint.h>
#include <stddef.h>
typedef struct { char id[96]; char name[128]; char audio_uid[256]; uint16_t current; uint16_t maximum; } DDCMonitor;
int ddc_discover(DDCMonitor *out, size_t capacity, size_t *count, char *error, size_t error_cap);
int ddc_get_volume(const char *id, uint16_t *current, uint16_t *maximum, char *error, size_t error_cap);
int ddc_set_volume(const char *id, uint16_t value, char *error, size_t error_cap);
int ddc_set_mute(const char *id, int muted, char *error, size_t error_cap);
int ddc_get_mute(const char *id, int *muted, char *error, size_t error_cap);
#endif
