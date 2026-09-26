#include "Render.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct ARRenderState {
    uint32_t skip, inputChannels, outputChannels;
    _Atomic uint64_t callbacks, audible;
};
ARRenderState *ARCreateState(uint32_t skip, uint32_t inputChannels, uint32_t outputChannels) {
    ARRenderState *s = calloc(1, sizeof(*s));
    if (s) { s->skip = skip; s->inputChannels = inputChannels; s->outputChannels = outputChannels; }
    return s;
}
void ARDestroyState(ARRenderState *s) { free(s); }
uint64_t ARCallbackCount(ARRenderState *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
uint64_t ARAudibleCount(ARRenderState *s) { return atomic_load_explicit(&s->audible, memory_order_relaxed); }

// No allocation, locks, Objective-C, or Swift runtime work on the audio thread.
void ARRender(ARRenderState *s, const AudioBufferList *input, AudioBufferList *output) {
    if (!s || !output) return;
    for (uint32_t b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    if (!input) return;
    uint32_t totalIn = 0, totalOut = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) totalIn += input->mBuffers[b].mNumberChannels;
    for (uint32_t b = 0; b < output->mNumberBuffers; b++) totalOut += output->mBuffers[b].mNumberChannels;
    // Device format changes must be rebuilt by the control thread, never guessed here.
    if (totalIn != s->inputChannels || totalOut != s->outputChannels) return;
    const float *source[2] = {0};
    uint32_t stride[2] = {0}, frames[2] = {0};
    uint32_t channelBase = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buf = &input->mBuffers[b];
        for (uint32_t c = 0; c < 2; c++) {
            uint32_t target = s->skip + c;
            if (target >= channelBase && target < channelBase + buf->mNumberChannels && buf->mData) {
                source[c] = (const float *)buf->mData + target - channelBase;
                stride[c] = buf->mNumberChannels;
                frames[c] = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
            }
        }
        channelBase += buf->mNumberChannels;
    }
    if (!source[0] || !source[1]) return;
    int audible = 0;
    channelBase = 0;
    for (uint32_t b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buf = &output->mBuffers[b];
        if (buf->mData && buf->mNumberChannels) {
            uint32_t n = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
            for (uint32_t c = 0; c < buf->mNumberChannels && channelBase + c < 2; c++) {
                uint32_t src = channelBase + c;
                uint32_t limit = n < frames[src] ? n : frames[src];
                for (uint32_t f = 0; f < limit; f++) {
                    float v = source[src][f * stride[src]];
                    if (!isfinite(v)) v = 0;
                    ((float *)buf->mData)[f * buf->mNumberChannels + c] = v;
                    audible |= fabsf(v) > 0.00001f;
                }
            }
        }
        channelBase += buf->mNumberChannels;
    }
    if (audible) atomic_fetch_add_explicit(&s->audible, 1, memory_order_relaxed);
}
OSStatus ARIOProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                 const AudioTimeStamp *inputTime, AudioBufferList *output,
                 const AudioTimeStamp *outputTime, void *context) {
    ARRender(context, input, output);
    return noErr;
}
OSStatus ARDisableHardwareInputs(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t count, uint32_t start) {
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    for (uint32_t i = 0; i < count; i++) usage->mStreamIsOn[i] = i >= start;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    OSStatus result = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)size, usage);
    free(usage);
    return result;
}
