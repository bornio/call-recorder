#ifndef AUDIO_CAPTURE_BRIDGE_H
#define AUDIO_CAPTURE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *CRCaptureHandle;

typedef struct {
    const char *system_directory;
    const char *microphone_directory;
    const char *microphone_uid;
    uint32_t chunk_duration_seconds;
    uint32_t ring_capacity_blocks;
} CRCaptureConfiguration;

typedef struct {
    bool running;
    float system_level;
    float microphone_level;
    uint64_t system_frames;
    uint64_t microphone_frames;
    uint64_t system_dropped_frames;
    uint64_t microphone_dropped_frames;
    double system_sample_rate;
    double microphone_sample_rate;
    int32_t fatal_error_code;
} CRCaptureStatistics;

typedef struct {
    uint32_t default_input_device;
    uint32_t default_output_device;
} CRDefaultAudioDevices;

enum {
    CR_CAPTURE_OK = 0,
    CR_CAPTURE_ERROR_INVALID_CONFIGURATION = 1,
    CR_CAPTURE_ERROR_PROCESS_LOOKUP = 2,
    CR_CAPTURE_ERROR_TAP_CREATE = 3,
    CR_CAPTURE_ERROR_TAP_FORMAT = 4,
    CR_CAPTURE_ERROR_AGGREGATE_CREATE = 5,
    CR_CAPTURE_ERROR_AGGREGATE_CONFIGURE = 6,
    CR_CAPTURE_ERROR_SYSTEM_IO = 7,
    CR_CAPTURE_ERROR_MICROPHONE_LOOKUP = 8,
    CR_CAPTURE_ERROR_MICROPHONE_FORMAT = 9,
    CR_CAPTURE_ERROR_MICROPHONE_IO = 10,
    CR_CAPTURE_ERROR_WRITER = 11,
    CR_CAPTURE_ERROR_OUTPUT_DEVICE_CHANGED = 12,
    CR_CAPTURE_ERROR_MICROPHONE_DEVICE_CHANGED = 13,
};

int32_t cr_capture_start(
    const CRCaptureConfiguration *configuration,
    CRCaptureHandle *out_handle,
    char *error_message,
    size_t error_message_capacity
);

int32_t cr_capture_copy_statistics(
    CRCaptureHandle handle,
    CRCaptureStatistics *out_statistics
);

int32_t cr_capture_stop(
    CRCaptureHandle handle,
    char *error_message,
    size_t error_message_capacity
);

void cr_capture_destroy(CRCaptureHandle handle);

int32_t cr_copy_default_audio_devices(
    CRDefaultAudioDevices *out_devices,
    char *error_message,
    size_t error_message_capacity
);

const char *cr_capture_error_name(int32_t error_code);

#ifdef __cplusplus
}
#endif

#endif
