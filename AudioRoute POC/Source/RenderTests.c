#include "Render.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static AudioBufferList *buffers(unsigned count) {
    AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + count * sizeof(AudioBuffer));
    list->mNumberBuffers = count;
    return list;
}
int main(void) {
    AudioBufferList *in = buffers(3), *out = buffers(2);
    float mic[] = {9, 9, 9, 9};
    float stereo[] = {.1f, .2f, .3f, .4f, .5f, .6f};
    float left[4] = {1,1,1,1}, right[4] = {1,1,1,1};
    in->mNumberBuffers = 2;
    in->mBuffers[0] = (AudioBuffer){1, sizeof(mic), mic};
    in->mBuffers[1] = (AudioBuffer){2, sizeof(stereo), stereo};
    out->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
    out->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    ARRenderState *s = ARCreateState(1, 3, 2);
    ARRender(s, in, out);
    assert(left[0] == .1f && left[2] == .5f && right[0] == .2f && right[2] == .6f);
    assert(left[3] == 0 && right[3] == 0); // unequal buffer lengths never over-read
    assert(ARCallbackCount(s) == 1 && ARAudibleCount(s) == 1);
    in->mBuffers[0].mData = NULL; // disabled physical microphone does not affect routing
    ARRender(s, in, out);
    assert(left[0] == .1f && right[0] == .2f);
    in->mBuffers[1].mData = NULL;
    ARRender(s, in, out);
    assert(left[0] == 0 && right[0] == 0);
    ARDestroyState(s);

    float planarL[] = {.2f, NAN}, planarR[] = {.4f, .6f};
    float interleaved[6] = {1,1,1,1,1,1};
    in->mBuffers[0] = (AudioBuffer){1, sizeof(planarL), planarL};
    in->mBuffers[1] = (AudioBuffer){1, sizeof(planarR), planarR};
    out->mNumberBuffers = 1;
    out->mBuffers[0] = (AudioBuffer){2, sizeof(interleaved), interleaved};
    s = ARCreateState(0, 2, 2);
    ARRender(s, in, out);
    assert(interleaved[0] == .2f && interleaved[1] == .4f && interleaved[2] == 0 && interleaved[3] == .6f);
    assert(interleaved[4] == 0 && interleaved[5] == 0);
    in->mNumberBuffers = 1; // changed channel layout fails silent
    ARRender(s, in, out);
    assert(interleaved[0] == 0 && interleaved[3] == 0);
    ARDestroyState(s);
    free(in); free(out);
    puts("PASS: stereo/planar routing, microphone exclusion, short buffers, missing data, format changes, non-finite samples, counters.");
}
