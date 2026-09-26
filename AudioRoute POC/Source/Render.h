#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
typedef struct ARRenderState ARRenderState;
ARRenderState * _Nullable ARCreateState(uint32_t skippedInputChannels, uint32_t inputChannels, uint32_t outputChannels);
void ARDestroyState(ARRenderState * _Nullable state);
uint64_t ARCallbackCount(ARRenderState * _Nonnull state);
uint64_t ARAudibleCount(ARRenderState * _Nonnull state);
void ARRender(ARRenderState * _Nullable state, const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
OSStatus ARIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now, const AudioBufferList * _Nonnull input,
                 const AudioTimeStamp * _Nonnull inputTime, AudioBufferList * _Nonnull output,
                 const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
OSStatus ARDisableHardwareInputs(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, uint32_t streamCount, uint32_t tapStreamStart);
