#import "AudioCaptureBridge.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <exception>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <unistd.h>

namespace {

constexpr uint32_t kMaximumFramesPerCallback = 8192;
constexpr uint32_t kDefaultRingCapacity = 256;
constexpr uint32_t kDefaultChunkDurationSeconds = 15;
constexpr auto kWriterIdlePollInterval = std::chrono::milliseconds(10);

void copy_error(const std::string &message, char *destination, size_t capacity) noexcept {
    if (destination == nullptr || capacity == 0) {
        return;
    }
    std::snprintf(destination, capacity, "%s", message.c_str());
}

std::string status_description(const char *operation, OSStatus status) {
    char fourcc[5] = {};
    const uint32_t value = static_cast<uint32_t>(status);
    fourcc[0] = static_cast<char>((value >> 24) & 0xff);
    fourcc[1] = static_cast<char>((value >> 16) & 0xff);
    fourcc[2] = static_cast<char>((value >> 8) & 0xff);
    fourcc[3] = static_cast<char>(value & 0xff);
    const bool printable = fourcc[0] >= 32 && fourcc[0] <= 126 &&
        fourcc[1] >= 32 && fourcc[1] <= 126 &&
        fourcc[2] >= 32 && fourcc[2] <= 126 &&
        fourcc[3] >= 32 && fourcc[3] <= 126;
    char buffer[256] = {};
    if (printable) {
        std::snprintf(buffer, sizeof(buffer), "%s failed (%d, '%s')", operation,
                      static_cast<int>(status), fourcc);
    } else {
        std::snprintf(buffer, sizeof(buffer), "%s failed (%d)", operation,
                      static_cast<int>(status));
    }
    return buffer;
}

AudioObjectPropertyAddress property_address(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain
) noexcept {
    return AudioObjectPropertyAddress{selector, scope, element};
}

OSStatus get_default_device(AudioObjectPropertySelector selector, AudioObjectID *device) noexcept {
    if (device == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }
    auto address = property_address(selector);
    UInt32 size = sizeof(*device);
    *device = kAudioObjectUnknown;
    return AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        nullptr,
        &size,
        device
    );
}

class AudioWriter final {
public:
    struct Slot {
        uint64_t sequence = 0;
        uint64_t host_time = 0;
        double sample_time = std::numeric_limits<double>::quiet_NaN();
        uint32_t frames = 0;
        std::array<float, kMaximumFramesPerCallback> samples{};
    };

    AudioWriter(std::string directory, uint32_t ring_capacity, uint32_t chunk_seconds)
        : directory_(std::move(directory)),
          capacity_(ring_capacity == 0 ? kDefaultRingCapacity : ring_capacity),
          chunk_seconds_(chunk_seconds == 0 ? kDefaultChunkDurationSeconds : chunk_seconds) {}

    ~AudioWriter() {
        stop();
    }

    AudioWriter(const AudioWriter &) = delete;
    AudioWriter &operator=(const AudioWriter &) = delete;

    bool start(double sample_rate, std::string &error) {
        if (!std::isfinite(sample_rate) || sample_rate <= 0) {
            error = "The capture source reported an invalid sample rate.";
            return false;
        }

        std::error_code filesystem_error;
        std::filesystem::create_directories(directory_, filesystem_error);
        if (filesystem_error) {
            error = "Unable to create capture directory: " + filesystem_error.message();
            return false;
        }

        slots_.reset(new (std::nothrow) Slot[capacity_]);
        if (!slots_) {
            error = "Unable to allocate the bounded audio buffer.";
            return false;
        }

        const auto metadata_path = std::filesystem::path(directory_) / "chunks.jsonl";
        metadata_file_ = std::fopen(metadata_path.c_str(), "wb");
        if (metadata_file_ == nullptr) {
            error = "Unable to create capture metadata: " + std::string(std::strerror(errno));
            slots_.reset();
            return false;
        }

        sample_rate_ = sample_rate;
        stopping_.store(false, std::memory_order_release);
        running_.store(true, std::memory_order_release);
        try {
            writer_thread_ = std::thread(&AudioWriter::writer_loop, this);
        } catch (const std::exception &exception) {
            running_.store(false, std::memory_order_release);
            if (std::fclose(metadata_file_) != 0) {
                writer_error_.store(errno == 0 ? 1 : errno, std::memory_order_release);
            }
            metadata_file_ = nullptr;
            slots_.reset();
            error = "Unable to start the capture writer: " + std::string(exception.what());
            return false;
        }
        return true;
    }

    void stop() noexcept {
        if (!running_.exchange(false, std::memory_order_acq_rel)) {
            return;
        }
        stopping_.store(true, std::memory_order_release);
        if (writer_thread_.joinable()) {
            writer_thread_.join();
        }
        close_chunk();
        if (metadata_file_ != nullptr) {
            if (std::fflush(metadata_file_) != 0 ||
                ::fsync(::fileno(metadata_file_)) != 0) {
                writer_error_.store(errno == 0 ? 1 : errno, std::memory_order_release);
            }
            std::fclose(metadata_file_);
            metadata_file_ = nullptr;
        }
    }

    void push_downmixed(
        const AudioBufferList *buffer_list,
        uint32_t frames,
        const AudioStreamBasicDescription &format,
        const AudioTimeStamp *timestamp
    ) noexcept {
        const uint64_t sequence = callback_sequence_++;
        if (buffer_list == nullptr || frames == 0) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            return;
        }
        if (frames > kMaximumFramesPerCallback || !is_supported_float_format(format)) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            callback_error_.store(kAudio_ParamError, std::memory_order_release);
            return;
        }

        Slot *slot = reserve_slot();
        if (slot == nullptr) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            return;
        }

        float peak = 0;
        if (buffer_list->mNumberBuffers == 1 &&
            buffer_list->mBuffers[0].mData != nullptr &&
            buffer_list->mBuffers[0].mNumberChannels == 1) {
            // The mono global tap takes this path. Keep its callback to one copy
            // and one peak comparison per frame instead of running the generic
            // buffer/channel mixer for audio that is already downmixed by HAL.
            const float *samples =
                static_cast<const float *>(buffer_list->mBuffers[0].mData);
            for (uint32_t frame = 0; frame < frames; ++frame) {
                const float sample = samples[frame];
                slot->samples[frame] = sample;
                peak = std::max(peak, std::fabs(sample));
            }
        } else {
            for (uint32_t frame = 0; frame < frames; ++frame) {
                float sum = 0;
                uint32_t channel_count = 0;
                for (UInt32 buffer_index = 0;
                     buffer_index < buffer_list->mNumberBuffers;
                     ++buffer_index) {
                    const AudioBuffer &buffer = buffer_list->mBuffers[buffer_index];
                    if (buffer.mData == nullptr || buffer.mNumberChannels == 0) {
                        continue;
                    }
                    const float *samples = static_cast<const float *>(buffer.mData);
                    const uint32_t channels = buffer.mNumberChannels;
                    for (uint32_t channel = 0; channel < channels; ++channel) {
                        sum += samples[frame * channels + channel];
                        ++channel_count;
                    }
                }
                const float mono = channel_count == 0
                    ? 0
                    : sum / static_cast<float>(channel_count);
                slot->samples[frame] = mono;
                peak = std::max(peak, std::fabs(mono));
            }
        }

        slot->sequence = sequence;
        slot->host_time = timestamp != nullptr &&
                (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0
            ? timestamp->mHostTime
            : AudioGetCurrentHostTime();
        slot->sample_time = timestamp != nullptr &&
                (timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0
            ? timestamp->mSampleTime
            : std::numeric_limits<double>::quiet_NaN();
        slot->frames = frames;
        level_.store(std::min(peak, 1.0f), std::memory_order_relaxed);
        captured_frames_.fetch_add(frames, std::memory_order_relaxed);
        commit_slot();
    }

    OSStatus render_microphone(
        AudioUnit audio_unit,
        AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *render_timestamp,
        UInt32 bus,
        UInt32 frames,
        const AudioTimeStamp *writer_timestamp
    ) noexcept {
        const uint64_t sequence = callback_sequence_++;
        if (frames == 0 || frames > kMaximumFramesPerCallback) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            callback_error_.store(kAudio_ParamError, std::memory_order_release);
            return kAudio_ParamError;
        }

        Slot *slot = reserve_slot();
        float *destination = slot == nullptr ? scratch_.data() : slot->samples.data();
        AudioBufferList buffer_list{};
        buffer_list.mNumberBuffers = 1;
        buffer_list.mBuffers[0].mNumberChannels = 1;
        buffer_list.mBuffers[0].mDataByteSize = frames * sizeof(float);
        buffer_list.mBuffers[0].mData = destination;

        const OSStatus status = AudioUnitRender(
            audio_unit,
            flags,
            render_timestamp,
            bus,
            frames,
            &buffer_list
        );
        if (status != noErr) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            callback_error_.store(status, std::memory_order_release);
            return status;
        }
        if (slot == nullptr) {
            dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
            return noErr;
        }

        float peak = 0;
        for (UInt32 frame = 0; frame < frames; ++frame) {
            peak = std::max(peak, std::fabs(destination[frame]));
        }
        slot->sequence = sequence;
        slot->host_time = writer_timestamp != nullptr &&
                (writer_timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0
            ? writer_timestamp->mHostTime
            : AudioGetCurrentHostTime();
        slot->sample_time = writer_timestamp != nullptr &&
                (writer_timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0
            ? writer_timestamp->mSampleTime
            : std::numeric_limits<double>::quiet_NaN();
        slot->frames = frames;
        level_.store(std::min(peak, 1.0f), std::memory_order_relaxed);
        captured_frames_.fetch_add(frames, std::memory_order_relaxed);
        commit_slot();
        return noErr;
    }

    float level() const noexcept {
        return level_.load(std::memory_order_relaxed);
    }

    void clear_level() noexcept {
        level_.store(0, std::memory_order_relaxed);
    }

    OSStatus render_microphone_discard(
        AudioUnit audio_unit,
        AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timestamp,
        UInt32 bus,
        UInt32 frames
    ) noexcept {
        if (frames == 0 || frames > kMaximumFramesPerCallback) {
            return kAudio_ParamError;
        }
        AudioBufferList buffer_list{};
        buffer_list.mNumberBuffers = 1;
        buffer_list.mBuffers[0].mNumberChannels = 1;
        buffer_list.mBuffers[0].mDataByteSize = frames * sizeof(float);
        buffer_list.mBuffers[0].mData = scratch_.data();
        return AudioUnitRender(
            audio_unit,
            flags,
            timestamp,
            bus,
            frames,
            &buffer_list
        );
    }

    uint64_t captured_frames() const noexcept {
        return captured_frames_.load(std::memory_order_relaxed);
    }

    uint64_t dropped_frames() const noexcept {
        return dropped_frames_.load(std::memory_order_relaxed);
    }

    double sample_rate() const noexcept {
        return sample_rate_;
    }

    bool has_error() const noexcept {
        return writer_error_.load(std::memory_order_acquire) != 0 ||
            callback_error_.load(std::memory_order_acquire) != 0;
    }

private:
    static bool is_supported_float_format(const AudioStreamBasicDescription &format) noexcept {
        return format.mFormatID == kAudioFormatLinearPCM &&
            (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
            format.mBitsPerChannel == 32;
    }

    Slot *reserve_slot() noexcept {
        const uint64_t write = write_index_.load(std::memory_order_relaxed);
        const uint64_t read = read_index_.load(std::memory_order_acquire);
        if (write - read >= capacity_) {
            return nullptr;
        }
        return &slots_[write % capacity_];
    }

    void commit_slot() noexcept {
        const uint64_t write = write_index_.load(std::memory_order_relaxed);
        write_index_.store(write + 1, std::memory_order_release);
    }

    void writer_loop() noexcept {
        while (!stopping_.load(std::memory_order_acquire) ||
               read_index_.load(std::memory_order_relaxed) <
                   write_index_.load(std::memory_order_acquire)) {
            const uint64_t read = read_index_.load(std::memory_order_relaxed);
            const uint64_t write = write_index_.load(std::memory_order_acquire);
            if (read == write) {
                // Recording can tolerate a few milliseconds of writer latency: the
                // callback is isolated behind a 256-slot ring. Polling every 2 ms
                // caused two otherwise-idle writers to wake roughly 1,000 times per
                // second. A 10 ms interval cuts those wakeups by 80% without adding
                // any work or synchronization to the real-time callback.
                std::this_thread::sleep_for(kWriterIdlePollInterval);
                continue;
            }

            const Slot &slot = slots_[read % capacity_];
            if (writer_error_.load(std::memory_order_relaxed) == 0) {
                write_slot(slot);
            }
            read_index_.store(read + 1, std::memory_order_release);
        }
    }

    bool should_rotate(const Slot &slot) const noexcept {
        if (audio_file_ == nullptr) {
            return true;
        }
        if (slot.sequence != last_sequence_ + 1) {
            return true;
        }
        if (chunk_frames_ >= static_cast<uint64_t>(sample_rate_ * chunk_seconds_)) {
            return true;
        }
        if (slot.host_time <= last_host_time_) {
            return true;
        }
        const uint64_t delta_nanos = AudioConvertHostTimeToNanos(slot.host_time - last_host_time_);
        const double expected_nanos =
            static_cast<double>(last_frames_) / sample_rate_ * 1'000'000'000.0;
        return static_cast<double>(delta_nanos) > expected_nanos + 50'000'000.0;
    }

    void write_slot(const Slot &slot) noexcept {
        if (should_rotate(slot)) {
            close_chunk();
            if (!open_chunk(slot)) {
                writer_error_.store(1, std::memory_order_release);
                return;
            }
        }

        AudioBufferList buffer_list{};
        buffer_list.mNumberBuffers = 1;
        buffer_list.mBuffers[0].mNumberChannels = 1;
        buffer_list.mBuffers[0].mDataByteSize = slot.frames * sizeof(float);
        buffer_list.mBuffers[0].mData = const_cast<float *>(slot.samples.data());
        const OSStatus status = ExtAudioFileWrite(audio_file_, slot.frames, &buffer_list);
        if (status != noErr) {
            writer_error_.store(status == 0 ? 1 : status, std::memory_order_release);
            close_chunk();
            return;
        }

        chunk_frames_ += slot.frames;
        last_sequence_ = slot.sequence;
        last_host_time_ = slot.host_time;
        last_sample_time_ = slot.sample_time;
        last_frames_ = slot.frames;
    }

    bool open_chunk(const Slot &slot) noexcept {
        char filename[96] = {};
        std::snprintf(
            filename,
            sizeof(filename),
            "%06u-%llu.caf",
            chunk_index_++,
            static_cast<unsigned long long>(slot.host_time)
        );
        current_filename_ = filename;
        const auto path = std::filesystem::path(directory_) / current_filename_;
        const std::string path_string = path.string();
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault,
            reinterpret_cast<const UInt8 *>(path_string.data()),
            path_string.size(),
            false
        );
        if (url == nullptr) {
            return false;
        }

        AudioStreamBasicDescription format{};
        format.mSampleRate = sample_rate_;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        format.mBytesPerPacket = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float);
        format.mChannelsPerFrame = 1;
        format.mBitsPerChannel = 32;

        const OSStatus status = ExtAudioFileCreateWithURL(
            url,
            kAudioFileCAFType,
            &format,
            nullptr,
            kAudioFileFlags_EraseFile,
            &audio_file_
        );
        CFRelease(url);
        if (status != noErr) {
            audio_file_ = nullptr;
            return false;
        }

        first_host_time_ = slot.host_time;
        first_sample_time_ = slot.sample_time;
        last_host_time_ = slot.host_time;
        last_sample_time_ = slot.sample_time;
        last_sequence_ = slot.sequence;
        last_frames_ = 0;
        chunk_frames_ = 0;
        return true;
    }

    void close_chunk() noexcept {
        if (audio_file_ == nullptr) {
            return;
        }
        const OSStatus dispose_status = ExtAudioFileDispose(audio_file_);
        audio_file_ = nullptr;
        if (dispose_status != noErr) {
            writer_error_.store(dispose_status, std::memory_order_release);
            chunk_frames_ = 0;
            current_filename_.clear();
            return;
        }

        const auto audio_path = std::filesystem::path(directory_) / current_filename_;
        const int audio_fd = ::open(audio_path.c_str(), O_RDONLY);
        if (audio_fd < 0 || ::fsync(audio_fd) != 0) {
            const int sync_error = errno == 0 ? 1 : errno;
            if (audio_fd >= 0) {
                ::close(audio_fd);
            }
            writer_error_.store(sync_error, std::memory_order_release);
            chunk_frames_ = 0;
            current_filename_.clear();
            return;
        }
        ::close(audio_fd);

        if (metadata_file_ != nullptr && chunk_frames_ > 0) {
            const int write_result = std::fprintf(
                metadata_file_,
                "{\"file\":\"%s\",\"firstHostTime\":%llu,"
                "\"lastHostTime\":%llu,\"lastFrames\":%u,"
                "\"frames\":%llu,\"sampleRate\":%.3f}\n",
                current_filename_.c_str(),
                static_cast<unsigned long long>(first_host_time_),
                static_cast<unsigned long long>(last_host_time_),
                last_frames_,
                static_cast<unsigned long long>(chunk_frames_),
                sample_rate_
            );
            if (write_result < 0 || std::fflush(metadata_file_) != 0 ||
                ::fsync(::fileno(metadata_file_)) != 0) {
                writer_error_.store(errno == 0 ? 1 : errno, std::memory_order_release);
            }
        }
        chunk_frames_ = 0;
        current_filename_.clear();
    }

    std::string directory_;
    uint64_t capacity_;
    uint32_t chunk_seconds_;
    std::unique_ptr<Slot[]> slots_;
    std::array<float, kMaximumFramesPerCallback> scratch_{};
    std::atomic<uint64_t> write_index_{0};
    std::atomic<uint64_t> read_index_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> stopping_{false};
    std::thread writer_thread_;
    std::atomic<float> level_{0};
    std::atomic<uint64_t> captured_frames_{0};
    std::atomic<uint64_t> dropped_frames_{0};
    std::atomic<int32_t> writer_error_{0};
    std::atomic<int32_t> callback_error_{0};
    uint64_t callback_sequence_ = 0;
    double sample_rate_ = 0;

    FILE *metadata_file_ = nullptr;
    ExtAudioFileRef audio_file_ = nullptr;
    uint32_t chunk_index_ = 0;
    std::string current_filename_;
    uint64_t chunk_frames_ = 0;
    uint64_t first_host_time_ = 0;
    uint64_t last_host_time_ = 0;
    double first_sample_time_ = std::numeric_limits<double>::quiet_NaN();
    double last_sample_time_ = std::numeric_limits<double>::quiet_NaN();
    uint64_t last_sequence_ = 0;
    uint32_t last_frames_ = 0;
};

class CaptureEngine final {
public:
    explicit CaptureEngine(const CRCaptureConfiguration &configuration)
        : system_writer_(
              configuration.system_directory,
              configuration.ring_capacity_blocks,
              configuration.chunk_duration_seconds),
          microphone_writer_(
              configuration.microphone_directory,
              configuration.ring_capacity_blocks,
              configuration.chunk_duration_seconds),
          microphone_uid_(configuration.microphone_uid) {}

    ~CaptureEngine() {
        std::string ignored;
        stop(ignored);
    }

    CaptureEngine(const CaptureEngine &) = delete;
    CaptureEngine &operator=(const CaptureEngine &) = delete;

    int32_t start(std::string &error) {
        if (!start_system_capture(error)) {
            stop(error);
            return start_error_code_;
        }
        if (!start_microphone_capture(error)) {
            stop(error);
            return start_error_code_;
        }
        running_.store(true, std::memory_order_release);
        return CR_CAPTURE_OK;
    }

    int32_t stop(std::string &error) noexcept {
        running_.store(false, std::memory_order_release);

        unregister_listeners();

        if (microphone_started_ && microphone_unit_ != nullptr) {
            AudioOutputUnitStop(microphone_unit_);
            microphone_started_ = false;
        }
        if (microphone_unit_ != nullptr) {
            AudioUnitUninitialize(microphone_unit_);
            AudioComponentInstanceDispose(microphone_unit_);
            microphone_unit_ = nullptr;
        }

        if (system_started_ && aggregate_device_id_ != kAudioObjectUnknown &&
            system_io_proc_ != nullptr) {
            AudioDeviceStop(aggregate_device_id_, system_io_proc_);
            system_started_ = false;
        }
        if (aggregate_device_id_ != kAudioObjectUnknown && system_io_proc_ != nullptr) {
            AudioDeviceDestroyIOProcID(aggregate_device_id_, system_io_proc_);
            system_io_proc_ = nullptr;
        }

        microphone_writer_.stop();
        system_writer_.stop();

        if (aggregate_device_id_ != kAudioObjectUnknown) {
            const OSStatus status = AudioHardwareDestroyAggregateDevice(aggregate_device_id_);
            if (status != noErr && error.empty()) {
                error = status_description("Destroying the private aggregate device", status);
            }
            aggregate_device_id_ = kAudioObjectUnknown;
        }
        if (tap_id_ != kAudioObjectUnknown) {
            if (@available(macOS 14.2, *)) {
                const OSStatus status = AudioHardwareDestroyProcessTap(tap_id_);
                if (status != noErr && error.empty()) {
                    error = status_description("Destroying the system-audio tap", status);
                }
            }
            tap_id_ = kAudioObjectUnknown;
        }

        if (system_writer_.has_error() || microphone_writer_.has_error()) {
            if (error.empty()) {
                error = "A capture writer failed. Audio already finalized in earlier chunks was preserved.";
            }
            return CR_CAPTURE_ERROR_WRITER;
        }
        return error.empty() ? CR_CAPTURE_OK : CR_CAPTURE_ERROR_SYSTEM_IO;
    }

    void set_paused(bool paused) noexcept {
        if (paused) {
            if (paused_.load(std::memory_order_acquire)) {
                return;
            }
            pause_started_host_time_.store(AudioGetCurrentHostTime(), std::memory_order_relaxed);
            paused_.store(true, std::memory_order_release);
            system_writer_.clear_level();
            microphone_writer_.clear_level();
            return;
        }

        if (!paused_.load(std::memory_order_acquire)) {
            return;
        }
        const uint64_t now = AudioGetCurrentHostTime();
        const uint64_t started = pause_started_host_time_.load(std::memory_order_relaxed);
        if (now > started) {
            paused_host_time_.fetch_add(now - started, std::memory_order_relaxed);
        }
        paused_.store(false, std::memory_order_release);
    }

    void copy_statistics(CRCaptureStatistics &statistics) const noexcept {
        statistics.running = running_.load(std::memory_order_acquire);
        statistics.system_level = system_writer_.level();
        statistics.microphone_level = microphone_writer_.level();
        statistics.system_frames = system_writer_.captured_frames();
        statistics.microphone_frames = microphone_writer_.captured_frames();
        statistics.system_dropped_frames = system_writer_.dropped_frames();
        statistics.microphone_dropped_frames = microphone_writer_.dropped_frames();
        statistics.system_sample_rate = system_writer_.sample_rate();
        statistics.microphone_sample_rate = microphone_writer_.sample_rate();
        int32_t fatal = fatal_error_code_.load(std::memory_order_acquire);
        if (fatal == CR_CAPTURE_OK &&
            (system_writer_.has_error() || microphone_writer_.has_error())) {
            fatal = CR_CAPTURE_ERROR_WRITER;
        }
        statistics.fatal_error_code = fatal;
    }

private:
    static OSStatus system_io_callback(
        AudioObjectID,
        const AudioTimeStamp *,
        const AudioBufferList *input,
        const AudioTimeStamp *input_time,
        AudioBufferList *,
        const AudioTimeStamp *,
        void *context
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        if (engine == nullptr || input == nullptr || input->mNumberBuffers == 0) {
            return noErr;
        }
        if (engine->paused_.load(std::memory_order_acquire)) {
            return noErr;
        }
        const AudioBuffer &first_buffer = input->mBuffers[0];
        uint32_t frames = 0;
        if ((engine->system_format_.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
            frames = first_buffer.mDataByteSize / sizeof(float);
        } else if (engine->system_format_.mBytesPerFrame > 0) {
            frames = first_buffer.mDataByteSize / engine->system_format_.mBytesPerFrame;
        } else if (first_buffer.mNumberChannels > 0) {
            frames = first_buffer.mDataByteSize /
                (first_buffer.mNumberChannels * sizeof(float));
        }
        AudioTimeStamp adjusted_time{};
        const AudioTimeStamp *writer_time = engine->adjusted_timestamp(
            input_time,
            adjusted_time
        );
        engine->system_writer_.push_downmixed(
            input,
            frames,
            engine->system_format_,
            writer_time
        );
        return noErr;
    }

    static OSStatus microphone_callback(
        void *context,
        AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timestamp,
        UInt32,
        UInt32 frames,
        AudioBufferList *
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        if (engine == nullptr || engine->microphone_unit_ == nullptr) {
            return kAudio_ParamError;
        }
        if (engine->paused_.load(std::memory_order_acquire)) {
            const OSStatus status = engine->microphone_writer_.render_microphone_discard(
                engine->microphone_unit_,
                flags,
                timestamp,
                1,
                frames
            );
            if (status != noErr) {
                engine->mark_fatal(CR_CAPTURE_ERROR_MICROPHONE_IO);
            }
            return status;
        }
        AudioTimeStamp adjusted_time{};
        const AudioTimeStamp *writer_time = engine->adjusted_timestamp(
            timestamp,
            adjusted_time
        );
        const OSStatus status = engine->microphone_writer_.render_microphone(
            engine->microphone_unit_,
            flags,
            timestamp,
            1,
            frames,
            writer_time
        );
        if (status != noErr) {
            engine->mark_fatal(CR_CAPTURE_ERROR_MICROPHONE_IO);
        }
        return status;
    }

    const AudioTimeStamp *adjusted_timestamp(
        const AudioTimeStamp *timestamp,
        AudioTimeStamp &adjusted
    ) const noexcept {
        if (timestamp != nullptr) {
            adjusted = *timestamp;
        }
        if ((adjusted.mFlags & kAudioTimeStampHostTimeValid) == 0) {
            adjusted.mHostTime = AudioGetCurrentHostTime();
            adjusted.mFlags |= kAudioTimeStampHostTimeValid;
        }
        const uint64_t paused_host_time = paused_host_time_.load(std::memory_order_relaxed);
        if (adjusted.mHostTime >= paused_host_time) {
            adjusted.mHostTime -= paused_host_time;
        }
        return &adjusted;
    }

    static OSStatus default_output_changed(
        AudioObjectID,
        UInt32,
        const AudioObjectPropertyAddress *,
        void *context
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        if (engine == nullptr) {
            return noErr;
        }
        AudioObjectID current = kAudioObjectUnknown;
        if (get_default_device(kAudioHardwarePropertyDefaultOutputDevice, &current) != noErr ||
            current != engine->initial_output_device_) {
            engine->mark_fatal(CR_CAPTURE_ERROR_OUTPUT_DEVICE_CHANGED);
        }
        return noErr;
    }

    static OSStatus microphone_device_changed(
        AudioObjectID device,
        UInt32 address_count,
        const AudioObjectPropertyAddress *addresses,
        void *context
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        if (engine == nullptr) {
            return noErr;
        }
        for (UInt32 index = 0; index < address_count; ++index) {
            auto address = addresses[index];
            if (address.mSelector == kAudioDevicePropertyDeviceIsAlive) {
                UInt32 alive = 0;
                UInt32 size = sizeof(alive);
                if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &alive) != noErr ||
                    alive == 0) {
                    engine->mark_fatal(CR_CAPTURE_ERROR_MICROPHONE_DEVICE_CHANGED);
                }
            } else if (address.mSelector == kAudioDevicePropertyNominalSampleRate) {
                Float64 sample_rate = 0;
                UInt32 size = sizeof(sample_rate);
                if (AudioObjectGetPropertyData(
                        device, &address, 0, nullptr, &size, &sample_rate) != noErr ||
                    std::fabs(sample_rate - engine->microphone_sample_rate_) > 0.1) {
                    engine->mark_fatal(CR_CAPTURE_ERROR_MICROPHONE_DEVICE_CHANGED);
                }
            }
        }
        return noErr;
    }

    static OSStatus aggregate_device_changed(
        AudioObjectID device,
        UInt32,
        const AudioObjectPropertyAddress *addresses,
        void *context
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        UInt32 alive = 0;
        UInt32 size = sizeof(alive);
        auto address = addresses[0];
        if (engine != nullptr &&
            (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &alive) != noErr ||
             alive == 0)) {
            engine->mark_fatal(CR_CAPTURE_ERROR_SYSTEM_IO);
        }
        return noErr;
    }

    static OSStatus tap_format_changed(
        AudioObjectID tap,
        UInt32,
        const AudioObjectPropertyAddress *addresses,
        void *context
    ) noexcept {
        auto *engine = static_cast<CaptureEngine *>(context);
        AudioStreamBasicDescription format{};
        UInt32 size = sizeof(format);
        auto address = addresses[0];
        if (engine != nullptr &&
            (AudioObjectGetPropertyData(tap, &address, 0, nullptr, &size, &format) != noErr ||
             format.mSampleRate != engine->system_format_.mSampleRate ||
             format.mFormatID != engine->system_format_.mFormatID ||
             format.mFormatFlags != engine->system_format_.mFormatFlags ||
             format.mChannelsPerFrame != engine->system_format_.mChannelsPerFrame ||
             format.mBitsPerChannel != engine->system_format_.mBitsPerChannel)) {
            engine->mark_fatal(CR_CAPTURE_ERROR_OUTPUT_DEVICE_CHANGED);
        }
        return noErr;
    }

    void mark_fatal(int32_t error_code) noexcept {
        int32_t expected = CR_CAPTURE_OK;
        fatal_error_code_.compare_exchange_strong(
            expected,
            error_code,
            std::memory_order_acq_rel
        );
    }

    bool start_system_capture(std::string &error) {
        OSStatus status = get_default_device(
            kAudioHardwarePropertyDefaultOutputDevice,
            &initial_output_device_
        );
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_SYSTEM_IO;
            error = status_description("Reading the default output device", status);
            return false;
        }

        pid_t process_id = getpid();
        AudioObjectID process_object_id = kAudioObjectUnknown;
        auto process_address = property_address(
            kAudioHardwarePropertyTranslatePIDToProcessObject
        );
        UInt32 process_size = sizeof(process_object_id);
        status = AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &process_address,
            sizeof(process_id),
            &process_id,
            &process_size,
            &process_object_id
        );
        if (status != noErr || process_object_id == kAudioObjectUnknown) {
            start_error_code_ = CR_CAPTURE_ERROR_PROCESS_LOOKUP;
            error = status_description("Resolving this app's Core Audio process", status);
            return false;
        }

        CATapDescription *tap_description =
            [[CATapDescription alloc] initMonoGlobalTapButExcludeProcesses:
                @[ @(process_object_id) ]];
        tap_description.name = @"Call Recorder system audio";
        tap_description.privateTap = YES;
        tap_description.muteBehavior = CATapUnmuted;

        if (@available(macOS 14.2, *)) {
            status = AudioHardwareCreateProcessTap(tap_description, &tap_id_);
        } else {
            status = kAudioHardwareUnsupportedOperationError;
        }
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_TAP_CREATE;
            error = status_description(
                "Creating the private system-audio tap (check System Audio Recording permission)",
                status
            );
            return false;
        }

        auto format_address = property_address(kAudioTapPropertyFormat);
        UInt32 format_size = sizeof(system_format_);
        status = AudioObjectGetPropertyData(
            tap_id_,
            &format_address,
            0,
            nullptr,
            &format_size,
            &system_format_
        );
        if (status != noErr || system_format_.mSampleRate <= 0 ||
            system_format_.mFormatID != kAudioFormatLinearPCM ||
            (system_format_.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
            system_format_.mBitsPerChannel != 32) {
            start_error_code_ = CR_CAPTURE_ERROR_TAP_FORMAT;
            error = status == noErr
                ? "The system-audio tap returned an unsupported format."
                : status_description("Reading the system-audio tap format", status);
            return false;
        }

        CFStringRef tap_uid = nullptr;
        auto uid_address = property_address(kAudioTapPropertyUID);
        UInt32 uid_size = sizeof(tap_uid);
        status = AudioObjectGetPropertyData(
            tap_id_,
            &uid_address,
            0,
            nullptr,
            &uid_size,
            &tap_uid
        );
        if (status != noErr || tap_uid == nullptr) {
            start_error_code_ = CR_CAPTURE_ERROR_TAP_CREATE;
            error = status_description("Reading the system-audio tap identifier", status);
            return false;
        }

        NSString *aggregate_uid = NSUUID.UUID.UUIDString;
        NSDictionary *aggregate_description = @{
            [NSString stringWithUTF8String:kAudioAggregateDeviceNameKey]:
                @"Call Recorder private tap",
            [NSString stringWithUTF8String:kAudioAggregateDeviceUIDKey]: aggregate_uid,
            [NSString stringWithUTF8String:kAudioAggregateDeviceIsPrivateKey]: @YES,
            [NSString stringWithUTF8String:kAudioAggregateDeviceIsStackedKey]: @NO,
        };
        status = AudioHardwareCreateAggregateDevice(
            (__bridge CFDictionaryRef)aggregate_description,
            &aggregate_device_id_
        );
        if (status != noErr) {
            CFRelease(tap_uid);
            start_error_code_ = CR_CAPTURE_ERROR_AGGREGATE_CREATE;
            error = status_description("Creating the private aggregate device", status);
            return false;
        }

        CFArrayRef tap_list = (__bridge CFArrayRef)@[ (__bridge NSString *)tap_uid ];
        auto tap_list_address = property_address(kAudioAggregateDevicePropertyTapList);
        const UInt32 tap_list_size = sizeof(tap_list);
        status = AudioObjectSetPropertyData(
            aggregate_device_id_,
            &tap_list_address,
            0,
            nullptr,
            tap_list_size,
            &tap_list
        );
        CFRelease(tap_uid);
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_AGGREGATE_CONFIGURE;
            error = status_description("Adding the tap to the private aggregate device", status);
            return false;
        }

        if (!system_writer_.start(system_format_.mSampleRate, error)) {
            start_error_code_ = CR_CAPTURE_ERROR_WRITER;
            return false;
        }

        status = AudioDeviceCreateIOProcID(
            aggregate_device_id_,
            system_io_callback,
            this,
            &system_io_proc_
        );
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_SYSTEM_IO;
            error = status_description("Creating system-audio I/O", status);
            return false;
        }

        if (!register_system_listeners(error)) {
            start_error_code_ = CR_CAPTURE_ERROR_SYSTEM_IO;
            return false;
        }
        status = AudioDeviceStart(aggregate_device_id_, system_io_proc_);
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_SYSTEM_IO;
            error = status_description(
                "Starting system-audio capture (check System Audio Recording permission)",
                status
            );
            return false;
        }
        system_started_ = true;
        return true;
    }

    bool start_microphone_capture(std::string &error) {
        CFStringRef uid = CFStringCreateWithCString(
            kCFAllocatorDefault,
            microphone_uid_.c_str(),
            kCFStringEncodingUTF8
        );
        if (uid == nullptr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_LOOKUP;
            error = "The selected microphone identifier is invalid.";
            return false;
        }
        AudioValueTranslation translation{};
        translation.mInputData = &uid;
        translation.mInputDataSize = sizeof(uid);
        translation.mOutputData = &microphone_device_id_;
        translation.mOutputDataSize = sizeof(microphone_device_id_);
        auto translation_address = property_address(kAudioHardwarePropertyDeviceForUID);
        UInt32 translation_size = sizeof(translation);
        OSStatus status = AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &translation_address,
            0,
            nullptr,
            &translation_size,
            &translation
        );
        CFRelease(uid);
        if (status != noErr || microphone_device_id_ == kAudioObjectUnknown) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_LOOKUP;
            error = status_description("Finding the selected microphone", status);
            return false;
        }

        Float64 device_sample_rate = 0;
        auto format_address = property_address(
            kAudioDevicePropertyNominalSampleRate
        );
        UInt32 format_size = sizeof(device_sample_rate);
        status = AudioObjectGetPropertyData(
            microphone_device_id_,
            &format_address,
            0,
            nullptr,
            &format_size,
            &device_sample_rate
        );
        if (status != noErr || device_sample_rate <= 0) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_FORMAT;
            error = status_description("Reading the microphone format", status);
            return false;
        }

        AudioComponentDescription component_description{};
        component_description.componentType = kAudioUnitType_Output;
        component_description.componentSubType = kAudioUnitSubType_HALOutput;
        component_description.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent component = AudioComponentFindNext(nullptr, &component_description);
        if (component == nullptr ||
            AudioComponentInstanceNew(component, &microphone_unit_) != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            error = "Unable to create the microphone audio unit.";
            return false;
        }

        UInt32 enabled = 1;
        status = AudioUnitSetProperty(
            microphone_unit_,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enabled,
            sizeof(enabled)
        );
        UInt32 disabled = 0;
        if (status == noErr) {
            status = AudioUnitSetProperty(
                microphone_unit_,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disabled,
                sizeof(disabled)
            );
        }
        if (status == noErr) {
            status = AudioUnitSetProperty(
                microphone_unit_,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &microphone_device_id_,
                sizeof(microphone_device_id_)
            );
        }
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            error = status_description("Configuring the selected microphone", status);
            return false;
        }

        AudioStreamBasicDescription client_format{};
        client_format.mSampleRate = device_sample_rate;
        client_format.mFormatID = kAudioFormatLinearPCM;
        client_format.mFormatFlags =
            kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        client_format.mBytesPerPacket = sizeof(float);
        client_format.mFramesPerPacket = 1;
        client_format.mBytesPerFrame = sizeof(float);
        client_format.mChannelsPerFrame = 1;
        client_format.mBitsPerChannel = 32;
        microphone_sample_rate_ = client_format.mSampleRate;
        status = AudioUnitSetProperty(
            microphone_unit_,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &client_format,
            sizeof(client_format)
        );
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_FORMAT;
            error = status_description("Setting the microphone capture format", status);
            return false;
        }

        UInt32 maximum_frames = kMaximumFramesPerCallback;
        status = AudioUnitSetProperty(
            microphone_unit_,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximum_frames,
            sizeof(maximum_frames)
        );
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            error = status_description("Setting the microphone callback capacity", status);
            return false;
        }

        AURenderCallbackStruct callback{};
        callback.inputProc = microphone_callback;
        callback.inputProcRefCon = this;
        status = AudioUnitSetProperty(
            microphone_unit_,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            sizeof(callback)
        );
        if (status == noErr) {
            status = AudioUnitInitialize(microphone_unit_);
        }
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            error = status_description("Initializing microphone capture", status);
            return false;
        }

        if (!microphone_writer_.start(client_format.mSampleRate, error)) {
            start_error_code_ = CR_CAPTURE_ERROR_WRITER;
            return false;
        }

        if (!register_microphone_listeners(error)) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            return false;
        }
        status = AudioOutputUnitStart(microphone_unit_);
        if (status != noErr) {
            start_error_code_ = CR_CAPTURE_ERROR_MICROPHONE_IO;
            error = status_description(
                "Starting microphone capture (check Microphone permission)",
                status
            );
            return false;
        }
        microphone_started_ = true;
        return true;
    }

    bool register_system_listeners(std::string &error) {
        default_output_address_ = property_address(kAudioHardwarePropertyDefaultOutputDevice);
        OSStatus status = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject,
            &default_output_address_,
            default_output_changed,
            this
        );
        if (status != noErr) {
            error = status_description("Monitoring the default output device", status);
            return false;
        }
        default_output_listener_registered_ = true;

        aggregate_alive_address_ = property_address(kAudioDevicePropertyDeviceIsAlive);
        status = AudioObjectAddPropertyListener(
            aggregate_device_id_,
            &aggregate_alive_address_,
            aggregate_device_changed,
            this
        );
        if (status != noErr) {
            error = status_description("Monitoring the private aggregate device", status);
            return false;
        }
        aggregate_listener_registered_ = true;

        tap_format_address_ = property_address(kAudioTapPropertyFormat);
        status = AudioObjectAddPropertyListener(
            tap_id_,
            &tap_format_address_,
            tap_format_changed,
            this
        );
        if (status != noErr) {
            error = status_description("Monitoring the system-audio tap format", status);
            return false;
        }
        tap_format_listener_registered_ = true;
        return true;
    }

    bool register_microphone_listeners(std::string &error) {
        microphone_alive_address_ = property_address(kAudioDevicePropertyDeviceIsAlive);
        OSStatus status = AudioObjectAddPropertyListener(
            microphone_device_id_,
            &microphone_alive_address_,
            microphone_device_changed,
            this
        );
        if (status != noErr) {
            error = status_description("Monitoring the microphone connection", status);
            return false;
        }
        microphone_alive_listener_registered_ = true;
        microphone_rate_address_ = property_address(kAudioDevicePropertyNominalSampleRate);
        status = AudioObjectAddPropertyListener(
            microphone_device_id_,
            &microphone_rate_address_,
            microphone_device_changed,
            this
        );
        if (status != noErr) {
            error = status_description("Monitoring the microphone sample rate", status);
            return false;
        }
        microphone_rate_listener_registered_ = true;
        return true;
    }

    void unregister_listeners() noexcept {
        if (default_output_listener_registered_) {
            AudioObjectRemovePropertyListener(
                kAudioObjectSystemObject,
                &default_output_address_,
                default_output_changed,
                this
            );
            default_output_listener_registered_ = false;
        }
        if (aggregate_listener_registered_ && aggregate_device_id_ != kAudioObjectUnknown) {
            AudioObjectRemovePropertyListener(
                aggregate_device_id_,
                &aggregate_alive_address_,
                aggregate_device_changed,
                this
            );
            aggregate_listener_registered_ = false;
        }
        if (tap_format_listener_registered_ && tap_id_ != kAudioObjectUnknown) {
            AudioObjectRemovePropertyListener(
                tap_id_,
                &tap_format_address_,
                tap_format_changed,
                this
            );
            tap_format_listener_registered_ = false;
        }
        if (microphone_alive_listener_registered_ &&
            microphone_device_id_ != kAudioObjectUnknown) {
            AudioObjectRemovePropertyListener(
                microphone_device_id_,
                &microphone_alive_address_,
                microphone_device_changed,
                this
            );
            microphone_alive_listener_registered_ = false;
        }
        if (microphone_rate_listener_registered_ &&
            microphone_device_id_ != kAudioObjectUnknown) {
            AudioObjectRemovePropertyListener(
                microphone_device_id_,
                &microphone_rate_address_,
                microphone_device_changed,
                this
            );
            microphone_rate_listener_registered_ = false;
        }
    }

    AudioWriter system_writer_;
    AudioWriter microphone_writer_;
    std::string microphone_uid_;
    std::atomic<bool> running_{false};
    std::atomic<bool> paused_{false};
    std::atomic<uint64_t> pause_started_host_time_{0};
    std::atomic<uint64_t> paused_host_time_{0};
    std::atomic<int32_t> fatal_error_code_{CR_CAPTURE_OK};
    int32_t start_error_code_ = CR_CAPTURE_ERROR_SYSTEM_IO;

    AudioObjectID tap_id_ = kAudioObjectUnknown;
    AudioObjectID aggregate_device_id_ = kAudioObjectUnknown;
    AudioObjectID microphone_device_id_ = kAudioObjectUnknown;
    AudioObjectID initial_output_device_ = kAudioObjectUnknown;
    AudioStreamBasicDescription system_format_{};
    Float64 microphone_sample_rate_ = 0;
    AudioDeviceIOProcID system_io_proc_ = nullptr;
    AudioUnit microphone_unit_ = nullptr;
    bool system_started_ = false;
    bool microphone_started_ = false;

    AudioObjectPropertyAddress default_output_address_{};
    AudioObjectPropertyAddress aggregate_alive_address_{};
    AudioObjectPropertyAddress tap_format_address_{};
    AudioObjectPropertyAddress microphone_alive_address_{};
    AudioObjectPropertyAddress microphone_rate_address_{};
    bool default_output_listener_registered_ = false;
    bool aggregate_listener_registered_ = false;
    bool tap_format_listener_registered_ = false;
    bool microphone_alive_listener_registered_ = false;
    bool microphone_rate_listener_registered_ = false;
};

bool valid_configuration(const CRCaptureConfiguration *configuration) noexcept {
    return configuration != nullptr &&
        configuration->system_directory != nullptr &&
        configuration->system_directory[0] != '\0' &&
        configuration->microphone_directory != nullptr &&
        configuration->microphone_directory[0] != '\0' &&
        configuration->microphone_uid != nullptr &&
        configuration->microphone_uid[0] != '\0';
}

} // namespace

extern "C" int32_t cr_capture_start(
    const CRCaptureConfiguration *configuration,
    CRCaptureHandle *out_handle,
    char *error_message,
    size_t error_message_capacity
) {
    @autoreleasepool {
        if (!valid_configuration(configuration) || out_handle == nullptr) {
            copy_error("The capture configuration is incomplete.", error_message, error_message_capacity);
            return CR_CAPTURE_ERROR_INVALID_CONFIGURATION;
        }
        *out_handle = nullptr;
        auto engine = std::make_unique<CaptureEngine>(*configuration);
        std::string error;
        const int32_t result = engine->start(error);
        if (result != CR_CAPTURE_OK) {
            copy_error(error, error_message, error_message_capacity);
            return result;
        }
        *out_handle = engine.release();
        return CR_CAPTURE_OK;
    }
}

extern "C" int32_t cr_capture_copy_statistics(
    CRCaptureHandle handle,
    CRCaptureStatistics *out_statistics
) {
    if (handle == nullptr || out_statistics == nullptr) {
        return CR_CAPTURE_ERROR_INVALID_CONFIGURATION;
    }
    static_cast<CaptureEngine *>(handle)->copy_statistics(*out_statistics);
    return CR_CAPTURE_OK;
}

extern "C" int32_t cr_capture_set_paused(CRCaptureHandle handle, bool paused) {
    if (handle == nullptr) {
        return CR_CAPTURE_ERROR_INVALID_CONFIGURATION;
    }
    static_cast<CaptureEngine *>(handle)->set_paused(paused);
    return CR_CAPTURE_OK;
}

extern "C" int32_t cr_capture_stop(
    CRCaptureHandle handle,
    char *error_message,
    size_t error_message_capacity
) {
    @autoreleasepool {
        if (handle == nullptr) {
            return CR_CAPTURE_OK;
        }
        std::string error;
        const int32_t result = static_cast<CaptureEngine *>(handle)->stop(error);
        copy_error(error, error_message, error_message_capacity);
        return result;
    }
}

extern "C" void cr_capture_destroy(CRCaptureHandle handle) {
    @autoreleasepool {
        delete static_cast<CaptureEngine *>(handle);
    }
}

extern "C" int32_t cr_copy_default_audio_devices(
    CRDefaultAudioDevices *out_devices,
    char *error_message,
    size_t error_message_capacity
) {
    if (out_devices == nullptr) {
        copy_error("No destination was provided for the audio route snapshot.", error_message,
                   error_message_capacity);
        return CR_CAPTURE_ERROR_INVALID_CONFIGURATION;
    }
    AudioObjectID input = kAudioObjectUnknown;
    AudioObjectID output = kAudioObjectUnknown;
    OSStatus status = get_default_device(kAudioHardwarePropertyDefaultInputDevice, &input);
    if (status == noErr) {
        status = get_default_device(kAudioHardwarePropertyDefaultOutputDevice, &output);
    }
    if (status != noErr) {
        copy_error(status_description("Reading the default audio routes", status), error_message,
                   error_message_capacity);
        return CR_CAPTURE_ERROR_SYSTEM_IO;
    }
    out_devices->default_input_device = input;
    out_devices->default_output_device = output;
    return CR_CAPTURE_OK;
}

extern "C" const char *cr_capture_error_name(int32_t error_code) {
    switch (error_code) {
        case CR_CAPTURE_OK: return "No error";
        case CR_CAPTURE_ERROR_INVALID_CONFIGURATION: return "Invalid capture configuration";
        case CR_CAPTURE_ERROR_PROCESS_LOOKUP: return "Unable to exclude the recorder process";
        case CR_CAPTURE_ERROR_TAP_CREATE: return "Unable to create the system-audio tap";
        case CR_CAPTURE_ERROR_TAP_FORMAT: return "Unsupported system-audio format";
        case CR_CAPTURE_ERROR_AGGREGATE_CREATE: return "Unable to create the private aggregate device";
        case CR_CAPTURE_ERROR_AGGREGATE_CONFIGURE: return "Unable to attach the tap";
        case CR_CAPTURE_ERROR_SYSTEM_IO: return "System-audio capture failed";
        case CR_CAPTURE_ERROR_MICROPHONE_LOOKUP: return "Selected microphone not found";
        case CR_CAPTURE_ERROR_MICROPHONE_FORMAT: return "Unsupported microphone format";
        case CR_CAPTURE_ERROR_MICROPHONE_IO: return "Microphone capture failed";
        case CR_CAPTURE_ERROR_WRITER: return "Local audio writer failed";
        case CR_CAPTURE_ERROR_OUTPUT_DEVICE_CHANGED: return "Output device changed during recording";
        case CR_CAPTURE_ERROR_MICROPHONE_DEVICE_CHANGED: return "Microphone changed during recording";
        default: return "Unknown capture error";
    }
}
