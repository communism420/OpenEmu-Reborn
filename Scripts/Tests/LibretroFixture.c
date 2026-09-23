/* Synthetic, ROM-free libretro core for the bridge regression test. */
#include "libretro.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>

static retro_input_poll_t poll_input;
static retro_input_state_t read_input;
static retro_video_refresh_t video;
static retro_environment_t environment_callback;
static unsigned char memory[8];

void retro_init(void) { memset(memory, 0, sizeof(memory)); }
void retro_deinit(void) {}
void retro_reset(void) { memset(memory, 0, sizeof(memory)); }
void retro_unload_game(void) {}
bool retro_load_game(const struct retro_game_info *game) {
    if (!game || !game->path || !game->size) return false;
    const char *directory = NULL;
    char expected[PATH_MAX], parent[PATH_MAX];
    snprintf(parent, sizeof(parent), "%s", game->path);
    char *separator = strrchr(parent, '/');
    if (!separator) return false;
    *separator = '\0';
    snprintf(expected, sizeof(expected), "%s/Profile/BIOS", parent);
    memory[4] = environment_callback(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, &directory) && directory && strcmp(directory, expected) == 0;
    snprintf(expected, sizeof(expected), "%s/Profile/Fixture-RetroArch/Battery Saves", parent);
    memory[5] = environment_callback(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, &directory) && directory && strcmp(directory, expected) == 0;
    memory[6] = environment_callback(RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY, &directory) && directory && strcmp(directory, parent) == 0;
    return true;
}
void retro_get_system_info(struct retro_system_info *info) {
    *info = (struct retro_system_info){"Reborn Fixture", "fixture-1", "dat", false, false};
}
void retro_get_system_av_info(struct retro_system_av_info *info) {
    *info = (struct retro_system_av_info){{2, 2, 2, 2, 1.0f}, {60.0, 44100.0}};
}
void retro_set_environment(retro_environment_t environment) {
    environment_callback = environment;
    enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
    environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}
void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
void retro_set_input_poll(retro_input_poll_t callback) { poll_input = callback; }
void retro_set_input_state(retro_input_state_t callback) { read_input = callback; }
void retro_run(void) {
    static const uint32_t pixels[4] = {0xff0000, 0x00ff00, 0x0000ff, 0xffffff};
    poll_input();
    memory[0]++;
    memory[1] = read_input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A) != 0;
    memory[2] = read_input(1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B) != 0;
    memory[3] = read_input(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X) > 0;
    video(pixels, 2, 2, 2 * sizeof(uint32_t));
}
size_t retro_serialize_size(void) { return sizeof(memory); }
bool retro_serialize(void *bytes, size_t size) {
    if (size != sizeof(memory)) return false;
    memcpy(bytes, memory, size);
    return true;
}
bool retro_unserialize(const void *bytes, size_t size) {
    if (size != sizeof(memory)) return false;
    memcpy(memory, bytes, size);
    return true;
}
void *retro_get_memory_data(unsigned id) { return id == RETRO_MEMORY_SAVE_RAM ? memory : NULL; }
size_t retro_get_memory_size(unsigned id) { return id == RETRO_MEMORY_SAVE_RAM ? sizeof(memory) : 0; }
