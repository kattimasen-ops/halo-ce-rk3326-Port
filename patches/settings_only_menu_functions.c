/*
SETTINGS_ONLY_MENU_FUNCTIONS.C — v6 (Xbox-Struktur + Kompatibilitäts-Makros)
*/
#include "cseries.h"
#include "input/input.h"
#include "interface/event_manager.h"
#include "interface/player_ui.h"
#include "interface/ui_widget.h"
#include "saved games/player_profile.h"
#include "text/unicode.h"
#include "halo_menus.h"
#include <stdlib.h>
#include <string.h>
#include <xtl.h>

void platform_log(char const *format, ...);
void platform_request_quit(void);
int config_text(char const *name, char *text, unsigned int size);
int config_write(char const *name, char const *value);
int config_boolean(char const *name);
int config_default(char const *name, char *text, unsigned int size);
char const *config_string(char const *name);
void platform_display_apply(void);
short pc_menu_string_index(long definition_index);
char const *pc_menu_function_name(long function_index);
char const *pc_menu_game_data_input_name(long function_index);
void ui_widget_port_go_back(struct widget_instance *widget);

struct widget_instance {
    long definition_tag_index;
    char const *name;
    short local_player_index;
    byte unknown0A[4];
    short type;
    boolean visible;
    byte unknown11;
    boolean disabled;
    byte unknown13[9];
    long unknown1C;
    byte unknown20[12];
    struct widget_instance *next;
    struct widget_instance *parent;
    struct widget_instance *child;
    struct widget_instance *focused_child;
    union {
        short selected_index;
        wchar_t *text;
        long value;
    } data3C;
    void *generated_list;
    short generated_count;
};

#define WIDGET_LIST_SELECTED(w)         ((w)->data3C.selected_index)
#define WIDGET_LIST_ITEM_COUNT(w)       ((w)->generated_count)
#define WIDGET_LIST_ITEMS(w)            ((w)->generated_list)
#define WIDGET_TEXT(w)                  ((w)->data3C.text)

struct widget_extra { struct widget_instance *list; struct widget_instance *extended_description; };
static struct widget_extra extras[32] = { 0 };

static struct widget_instance *get_extended_description(struct widget_instance *list) {
    for (int i = 0; i < 32; i++) if (extras[i].list == list) return extras[i].extended_description;
    return NULL;
}
static void set_extended_description(struct widget_instance *list, struct widget_instance *desc) {
    int slot = -1;
    for (int i = 0; i < 32; i++) {
        if (extras[i].list == list) { extras[i].extended_description = desc; return; }
        if (!extras[i].list && slot < 0) slot = i;
    }
    if (slot >= 0) { extras[slot].list = list; extras[slot].extended_description = desc; }
}

#define MAXIMUM_SETTING_VALUES 64
struct pc_menu_setting { long definition_index; char const *setting; long value_count; char const *values[MAXIMUM_SETTING_VALUES]; short loaded_index; };
struct pc_menu_setting *pc_menu_setting_get(long definition_index);

#define BUTTON_A 0
#define BUTTON_B 1
#define BUTTON_X 2
#define ROW_TEXT_LENGTH 64

static struct widget_instance *descendant(struct widget_instance *widget, char const *name, long *nth) {
    if (!widget) return NULL;
    for (struct widget_instance *child = widget->child; child; child = child->next) {
        struct widget_instance *found;
        if (!strcmp(child->name, name) && (*nth)-- == 0) return child;
        found = descendant(child, name, nth);
        if (found) return found;
    }
    return NULL;
}
static struct widget_instance *named(struct widget_instance *widget, char const *name, long nth) {
    return widget ? descendant(widget, name, &nth) : NULL;
}
static void text_set_length(struct widget_instance *text_box, wchar_t const *text, short length) {
    wchar_t *buf;
    if (!text_box || length <= 0) return;
    buf = WIDGET_TEXT(text_box);
    if (!buf) {
        buf = ui_widget_realloc(NULL, length * sizeof(wchar_t), __FILE__, __LINE__);
        WIDGET_TEXT(text_box) = buf;
    }
    if (buf) { ustrncpy(buf, text, length - 1); buf[length - 1] = 0; }
}
static void text_set(struct widget_instance *text_box, wchar_t const *text) { text_set_length(text_box, text, ROW_TEXT_LENGTH); }
static void visible_set(struct widget_instance *widget, boolean visible) { if (widget) widget->visible = visible; }
static struct widget_instance *screen_of(struct widget_instance *widget) { while (widget && widget->parent) widget = widget->parent; return widget; }

static boolean text_is_number(char const *text, double *number) { char *end; *number = strtod(text, &end); return *text && !*end; }
static boolean spinner_item(struct widget_instance const *widget) { return widget->parent && widget->parent->definition_tag_index == widget->definition_tag_index; }

static short setting_value_index(struct pc_menu_setting const *setting, char const *current) {
    double current_number, value_number, distance = 0.0;
    short index, nearest = 0;
    for (index = 0; index < setting->value_count; index++) if (!_stricmp(setting->values[index], current)) return index;
    if (!text_is_number(current, &current_number)) return 0;
    for (index = 0; index < setting->value_count; index++) {
        if (text_is_number(setting->values[index], &value_number)) {
            double gap = value_number > current_number ? value_number - current_number : current_number - value_number;
            if (index == 0 || gap < distance) { distance = gap; nearest = index; }
        }
    }
    return nearest;
}

static struct { char const *name; short field; byte default_value; } const profile_settings[] = {
    { "profile.look_sensitivity", 0, 3 }, { "profile.invert_look", 1, FALSE }, { "profile.flight_inversion", 2, FALSE },
    { "profile.autocenter", 3, FALSE }, { "profile.button_preset", 4, 0 }, { "profile.joystick_preset", 5, 0 },
    { "profile.vibration", 6, TRUE }, { "profile.ingame_help", 7, TRUE }
};

static byte *profile_setting_field(struct player_profile *profile, short field) {
    struct player_profile_controller_settings *controls = &profile->controller_settings;
    switch (field) {
        case 0: return &controls->look_sensitivity;
        case 1: return (byte *)&controls->invert_look;
        case 2: return (byte *)&controls->flight_stick_aircraft_controls;
        case 3: return (byte *)&controls->autocenter;
        case 4: return &controls->button_preset;
        case 5: return &controls->joystick_preset;
        case 6: return (byte *)&controls->vibration_disabled;
        case 7: return (byte *)&controls->ingame_help_disabled;
    }
    return NULL;
}
static boolean profile_setting_boolean(short field) { return field != 0 && field != 4 && field != 5; }

static boolean setting_text(char const *name, char *text, unsigned int size, boolean default_value) {
    short index;
    if (strncmp(name, "profile.", 8)) {
        if (!(default_value ? config_default(name, text, size) : config_text(name, text, size))) return FALSE;
        if (!strcmp(name, "display.mode") && !text[0]) snprintf(text, size, "%s", default_value || config_boolean("display.fullscreen") ? "borderless" : "windowed");
        if (!strcmp(name, "display.window_size") && !text[0]) snprintf(text, size, "1280x960");
        return TRUE;
    }
    for (index = 0; index < NUMBEROF(profile_settings); index++) {
        struct player_profile *profile = player_ui_get_edit_player_profile();
        short field = profile_settings[index].field;
        long value;
        if (strcmp(name, profile_settings[index].name)) continue;
        if (default_value) value = profile_settings[index].default_value;
        else if (profile && profile_setting_field(profile, field)) value = *profile_setting_field(profile, field);
        else return FALSE;
        if (!default_value && (field == 6 || field == 7)) value = !value;
        if (profile_setting_boolean(field)) snprintf(text, size, "%s", value ? "true" : "false");
        else snprintf(text, size, "%ld", value);
        return TRUE;
    }
    return FALSE;
}

static boolean setting_write(char const *name, char const *value) {
    short index;
    if (strncmp(name, "profile.", 8)) return config_write(name, value);
    for (index = 0; index < NUMBEROF(profile_settings); index++) {
        struct player_profile *profile = player_ui_get_edit_player_profile();
        short field = profile_settings[index].field;
        byte *place;
        long number;
        if (strcmp(name, profile_settings[index].name)) continue;
        if (!profile || !(place = profile_setting_field(profile, field))) return FALSE;
        number = profile_setting_boolean(field) ? !strcmp(value, "true") : atol(value);
        if (field == 6 || field == 7) number = !number;
        *place = (byte)number;
        return TRUE;
    }
    return FALSE;
}

static boolean setting_load(struct widget_instance *widget) {
    struct pc_menu_setting *setting;
    char current[300];
    if (!widget) return FALSE;
    if (spinner_item(widget)) return TRUE;
    setting = pc_menu_setting_get(widget->definition_tag_index);
    if (!setting || !setting_text(setting->setting, current, sizeof(current), FALSE)) return FALSE;
    setting->loaded_index = setting_value_index(setting, current);
    if (setting->loaded_index < (short)WIDGET_LIST_ITEM_COUNT(widget)) WIDGET_LIST_SELECTED(widget) = setting->loaded_index;
    return TRUE;
}

static boolean setting_save(struct widget_instance *widget) {
    struct pc_menu_setting *setting;
    if (!widget) return FALSE;
    if (spinner_item(widget)) return TRUE;
    setting = pc_menu_setting_get(widget->definition_tag_index);
    if (!setting || setting->loaded_index == NONE || WIDGET_LIST_SELECTED(widget) < 0 || WIDGET_LIST_SELECTED(widget) >= setting->value_count) return FALSE;
    if (WIDGET_LIST_SELECTED(widget) == setting->loaded_index) return TRUE;
    if (!config_write(setting->setting, setting->values[WIDGET_LIST_SELECTED(widget)])) return FALSE;
    setting->loaded_index = WIDGET_LIST_SELECTED(widget);
    return TRUE;
}

static void settings_each(struct widget_instance *widget, boolean (*visit)(struct widget_instance *spinner, struct pc_menu_setting *setting)) {
    if (!widget) return;
    for (struct widget_instance *child = widget->child; child; child = child->next) {
        struct pc_menu_setting *setting = child->type == 2 && !spinner_item(child) ? pc_menu_setting_get(child->definition_tag_index) : NULL;
        if (setting) visit(child, setting); else settings_each(child, visit);
    }
}

static boolean setting_changed_save(struct widget_instance *spinner, struct pc_menu_setting *setting) {
    short index = WIDGET_LIST_SELECTED(spinner);
    if (index < 0 || index >= setting->value_count || index == setting->loaded_index) return TRUE;
    if (!setting_write(setting->setting, setting->values[index])) return FALSE;
    setting->loaded_index = index;
    return TRUE;
}

static boolean setting_default_show(struct widget_instance *spinner, struct pc_menu_setting *setting) {
    char text[300];
    if (setting_text(setting->setting, text, sizeof(text), TRUE)) WIDGET_LIST_SELECTED(spinner) = setting_value_index(setting, text);
    return TRUE;
}

static void settings_help(struct widget_instance *list) {
    struct widget_instance *help = get_extended_description(list);
    struct widget_instance *row = list ? list->focused_child : NULL;
    short index = 0;
    if (!help) return;
    if (row && row->child && row->child->type == 1 && strncmp(row->name, "button", 6)) {
        short label = pc_menu_string_index(row->child->definition_tag_index);
        if (label != NONE) index = label + 1;
    }
    help->data3C.value = index;
}

static void video_rows_show(struct widget_instance *list) {
    struct widget_instance *mode, *resolution, *window_size, *shown, *child;
    struct pc_menu_setting *setting;
    short index;
    if (!list) return;
    mode = named(list, "mode_spinner", 0);
    resolution = named(list, "op_resolution", 0);
    window_size = named(list, "op_window_size", 0);
    if (!mode || !resolution || !window_size) return;
    setting = pc_menu_setting_get(mode->definition_tag_index);
    if (!setting) return;
    index = WIDGET_LIST_SELECTED(mode);
    shown = (index >= 0 && index < setting->value_count && !strcmp(setting->values[index], "windowed")) ? window_size : resolution;
    resolution->visible = (shown == resolution);
    window_size->visible = (shown == window_size);
    if (list->focused_child == (shown == resolution ? window_size : resolution)) {
        for (index = 0, child = list->child; child && child != shown; child = child->next) index++;
        list->focused_child = shown;
        list->data3C.selected_index = index;
    }
}

#define CONTROL_BINDINGS 2
#define CONTROL_NAME_LENGTH 32
static struct { char const *setting; wchar_t const *label; short group; } const controls[] = {
    { "controls.move_forward", L"MOVE FORWARD", 0 }, { "controls.move_backward", L"MOVE BACKWARD", 0 },
    { "controls.strafe_left", L"STRAFE LEFT", 0 }, { "controls.strafe_right", L"STRAFE RIGHT", 0 },
    { "controls.jump", L"JUMP", 0 }, { "controls.crouch", L"CROUCH", 0 },
    { "controls.fire", L"FIRE", 1 }, { "controls.throw_grenade", L"THROW GRENADE", 1 },
    { "controls.melee", L"MELEE", 1 }, { "controls.reload", L"RELOAD", 1 },
    { "controls.zoom", L"ZOOM", 1 }, { "controls.switch_weapon", L"SWITCH WEAPON", 1 },
    { "controls.switch_grenade", L"SWITCH GRENADE", 1 }, { "controls.action", L"ACTION", 2 },
    { "controls.flashlight", L"FLASHLIGHT", 2 }, { "controls.scoreboard", L"SHOW SCORES", 2 },
    { "controls.pause", L"PAUSE MENU", 2 }
};

static struct { char bindings[NUMBEROF(controls)][CONTROL_BINDINGS][CONTROL_NAME_LENGTH]; short slot; short capturing_control; short capturing_slot; } controls_screen = { { { { 0 } } }, 0, NONE, 0 };

static void control_bindings_read(short control, char const *text) {
    for (short slot = 0; slot < CONTROL_BINDINGS; slot++) {
        char *binding = controls_screen.bindings[control][slot];
        unsigned int length;
        while (*text == ' ' || *text == ',') text++;
        length = (unsigned int)strcspn(text, ", ");
        if (length >= CONTROL_NAME_LENGTH) length = CONTROL_NAME_LENGTH - 1;
        memcpy(binding, text, length);
        binding[length] = 0;
        while (length && binding[length - 1] == ' ') binding[--length] = 0;
        text += strcspn(text, ", ");
    }
}

static void control_bindings_text(short control, char *text, unsigned int size) {
    char const *first = controls_screen.bindings[control][0];
    char const *second = controls_screen.bindings[control][1];
    snprintf(text, size, "%s%s%s", *first ? first : second, *first && *second ? ", " : "", *first ? second : "");
}

static boolean controls_load(boolean defaults) {
    for (short control = 0; control < NUMBEROF(controls); control++) {
        char text[128];
        if (defaults) config_default(controls[control].setting, text, sizeof(text));
        else snprintf(text, sizeof(text), "%s", config_string(controls[control].setting));
        control_bindings_read(control, text);
    }
    controls_screen.capturing_control = NONE;
    return TRUE;
}

static boolean controls_save(void) {
    boolean result = TRUE;
    for (short control = 0; control < NUMBEROF(controls); control++) {
        char text[128];
        control_bindings_text(control, text, sizeof(text));
        if (strcmp(text, config_string(controls[control].setting))) {
            if (!config_write(controls[control].setting, text)) result = FALSE;
        }
    }
    return result;
}

static struct widget_instance *control_row(struct widget_instance *widget) {
    for (; widget; widget = widget->parent) if (!strncmp(widget->name, "op_command_", 11)) return widget;
    return NULL;
}

static short control_of_row(struct widget_instance *row, short group) {
    short wanted = row ? (short)(atoi(row->name + 11) - 1) : NONE;
    for (short control = 0; control < NUMBEROF(controls) && wanted >= 0; control++)
        if (controls[control].group == group && wanted-- == 0) return control;
    return NONE;
}

static short controls_group(struct widget_instance *screen) {
    struct widget_instance *spinner = named(screen, "group_spinner", 0);
    return spinner ? WIDGET_LIST_SELECTED(spinner) : 0;
}

static void controls_update(struct widget_instance *list) {
    if (!list) return;
    short group = controls_group(list);
    struct widget_instance *focused_row = control_row(list->focused_child);
    for (struct widget_instance *row = list->child; row; row = row->next) {
        short control = control_of_row(row, group);
        if (strncmp(row->name, "op_command_", 11)) continue;
        row->visible = (control != NONE);
        if (control == NONE) continue;
        text_set(named(row, "command_label", 0), controls[control].label);
        for (short slot = 0; slot < CONTROL_BINDINGS; slot++) {
            char const *binding = controls_screen.bindings[control][slot];
            wchar_t text[ROW_TEXT_LENGTH];
            char shown[64];
            if (row == focused_row && controls_screen.slot == slot) snprintf(shown, sizeof(shown), " > %s < ", *binding ? binding : "-");
            else snprintf(shown, sizeof(shown), "%s ", *binding ? binding : "-");
            short index;
            for (index = 0; shown[index] && index < ROW_TEXT_LENGTH - 1; index++) text[index] = (wchar_t)(unsigned char)shown[index];
            text[index] = 0;
            text_set(named(row, "command_binding", slot), text);
        }
    }
    struct widget_instance *desc = get_extended_description(list);
    if (desc) desc->data3C.value = focused_row ? 1 : 0;
}

boolean pc_menu_profile_edit_begin(void) {
    struct player_profile profile;
    long profile_index = player_ui_get_active_player_profile_index(0);
    if (profile_index == NONE || !player_profile_get(profile_index, &profile)) {
        word count = 1;
        profile_index = NONE;
        player_profiles_enumerate_available_to_local_player_index(NONE, &count, &profile_index, FALSE);
        if ((short)count <= 0 || profile_index == NONE || !player_profile_get(profile_index, &profile)) return FALSE;
    }
    player_ui_set_active_player_profile(0, profile_index, &profile);
    player_ui_begin_editing_profile(profile_index);
    return TRUE;
}

boolean pc_menu_event_function_invoke(struct widget_instance *widget, struct event_record *event, long function_index, boolean *widget_deleted) {
    char const *name;
    (void)event;
    if (!widget) return FALSE;
    name = pc_menu_function_name(function_index);
    if (!name) return FALSE;
    if (!strcmp(name, "port quit game") || !strcmp(name, "main menu quit game")) { platform_request_quit(); return TRUE; }
    if (!strcmp(name, "port setting load")) return setting_load(widget);
    if (!strcmp(name, "port setting save")) return setting_save(widget);
    if (!strcmp(name, "port settings save")) { settings_each(screen_of(widget), setting_changed_save); platform_display_apply(); return TRUE; }
    if (!strcmp(name, "port settings defaults")) { settings_each(screen_of(widget), setting_default_show); return TRUE; }
    if (!strcmp(name, "profile set edit begin")) return pc_menu_profile_edit_begin();
    if (!strcmp(name, "controls screen init")) return controls_load(FALSE);
    if (!strcmp(name, "controls screen defaults")) return controls_load(TRUE);
    if (!strcmp(name, "controls screen change set")) return controls_save();
    if (!strcmp(name, "controls begin binding")) return TRUE;
    if (!strcmp(name, "controls binding slot")) { controls_screen.slot = (short)!controls_screen.slot; return TRUE; }
    if (!strcmp(name, "controls back handler") || !strcmp(name, "gamespy back handler") || !strcmp(name, "gamespy dismiss error") || !strcmp(name, "gamespy dismiss filters")) {
        ui_widget_port_go_back(widget);
        if (widget_deleted) *widget_deleted = TRUE;
        return TRUE;
    }
    if (!strcmp(name, "mouse emit accept event")) { event_manager_post_button(0, BUTTON_A); return TRUE; }
    if (!strcmp(name, "mouse emit back event")) { event_manager_post_button(0, BUTTON_B); return TRUE; }
    if (!strcmp(name, "mouse emit x event")) { event_manager_post_button(0, BUTTON_X); return TRUE; }
    return TRUE;
}

void pc_menu_game_data_function_invoke(struct widget_instance *widget, long function) {
    char const *name;
    if (!widget) return;
    name = pc_menu_game_data_input_name(function);
    if (!name) return;
    if (!strcmp(name, "port settings help")) { video_rows_show(widget); settings_help(widget); }
    else if (!strcmp(name, "controls update menu")) { controls_update(widget); }
}
