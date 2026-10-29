/*
 * audio-out - tiny CoreAudio helper for macping.
 *
 * Lets the alarm ring through the Mac's built-in speakers even when headphones
 * (Bluetooth or wired) are connected.
 *
 * Usage:
 *   audio-out get                  print the default output device ID
 *   audio-out builtin              print the ID of the built-in output device
 *   audio-out set ID               make ID the default output device
 *   audio-out source ID            print the output data source of ID (e.g. 0x6973706B)
 *   audio-out source ID CODE       set it; CODE is 'ispk' (speakers), 'hdpn' (headphone
 *                                  jack) or a 0x... value as printed above
 *
 * Build: cc -O2 -o audio-out audio-out.c -framework CoreAudio -framework CoreFoundation
 */

#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* kAudioObjectPropertyElementMain (formerly ...ElementMaster) is 0. */
#define ELEM_MAIN 0

static AudioObjectPropertyAddress mk(AudioObjectPropertySelector sel,
                                     AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a;
    a.mSelector = sel;
    a.mScope = scope;
    a.mElement = ELEM_MAIN;
    return a;
}

static AudioObjectID default_output(void)
{
    AudioObjectPropertyAddress a =
        mk(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != 0)
        return kAudioObjectUnknown;
    return dev;
}

static int set_default_output(AudioObjectID dev)
{
    AudioObjectPropertyAddress a =
        mk(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof dev, &dev);
}

static int has_output(AudioObjectID dev)
{
    AudioObjectPropertyAddress a =
        mk(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    int channels = 0;
    AudioBufferList *list;

    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != 0 || size == 0)
        return 0;
    list = (AudioBufferList *)malloc(size);
    if (!list)
        return 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, list) == 0) {
        UInt32 i;
        for (i = 0; i < list->mNumberBuffers; i++)
            channels += (int)list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return channels > 0;
}

static AudioObjectID find_builtin_output(void)
{
    AudioObjectPropertyAddress a =
        mk(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0, n, i;
    AudioObjectID *ids;
    AudioObjectID found = kAudioObjectUnknown;

    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != 0 ||
        size == 0)
        return kAudioObjectUnknown;
    ids = (AudioObjectID *)malloc(size);
    if (!ids)
        return kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) == 0) {
        n = size / (UInt32)sizeof(AudioObjectID);
        for (i = 0; i < n && found == kAudioObjectUnknown; i++) {
            AudioObjectPropertyAddress t =
                mk(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
            UInt32 transport = 0, tsize = sizeof transport;
            if (AudioObjectGetPropertyData(ids[i], &t, 0, NULL, &tsize, &transport) == 0 &&
                transport == kAudioDeviceTransportTypeBuiltIn && has_output(ids[i]))
                found = ids[i];
        }
    }
    free(ids);
    return found;
}

static int get_source(AudioObjectID dev, UInt32 *value)
{
    AudioObjectPropertyAddress a =
        mk(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
    UInt32 size = sizeof *value;
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, value);
}

static int set_source(AudioObjectID dev, UInt32 value)
{
    AudioObjectPropertyAddress a =
        mk(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
    return AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof value, &value);
}

/* "ispk" -> four-character code, "0x6973706B" -> hex value. */
static UInt32 parse_code(const char *s)
{
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        return (UInt32)strtoul(s, NULL, 16);
    if (strlen(s) == 4)
        return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) |
               ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3];
    return (UInt32)strtoul(s, NULL, 10);
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;

    if (strcmp(argv[1], "get") == 0) {
        AudioObjectID d = default_output();
        if (d == kAudioObjectUnknown)
            return 1;
        printf("%u\n", (unsigned)d);
        return 0;
    }
    if (strcmp(argv[1], "builtin") == 0) {
        AudioObjectID d = find_builtin_output();
        if (d == kAudioObjectUnknown)
            return 1;
        printf("%u\n", (unsigned)d);
        return 0;
    }
    if (strcmp(argv[1], "set") == 0 && argc >= 3)
        return set_default_output((AudioObjectID)strtoul(argv[2], NULL, 10)) == 0 ? 0 : 1;
    if (strcmp(argv[1], "source") == 0 && argc >= 3) {
        AudioObjectID dev = (AudioObjectID)strtoul(argv[2], NULL, 10);
        if (argc >= 4)
            return set_source(dev, parse_code(argv[3])) == 0 ? 0 : 1;
        {
            UInt32 v = 0;
            if (get_source(dev, &v) != 0)
                return 1;
            printf("0x%08X\n", (unsigned)v);
            return 0;
        }
    }
    return 2;
}
