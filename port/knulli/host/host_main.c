/*
HOST_MAIN.C

Entry point of the Knulli port: an ordinary aarch64 Linux (glibc) program
that runs the Android port's guest image (port/android/README.md) on
handhelds whose GPU driver offers only OpenGL ES through the framebuffer,
as the Allwinner H700 devices (Anbernic RG35XX H) under Knulli do.

The host is the Android host library (port/android/host) with three files
replaced: this one (no JNI, no APK: the image and the game data are files
next to the executable), host_sdl2.c (SDL3's calls answered by the
firmware's SDL2, which drives the Mali framebuffer) and the NDK's log
functions (the standard error stream). Refer to port/knulli/README.md.

Paths, each overridable from the environment:
- HALO_GUEST_IMAGE: the guest image (default: halo_guest.elf next to the
  executable);
- HALO_DATA_ROOT: the folder that holds maps/ and config.toml (default: the
  executable's folder);
- HALO_SAVE_ROOT: the saved games (default: save/ in the data folder);
- HALO_DISPLAY_WIDTH: the columns of the 480-line picture (default: from
  the framebuffer's mode; 640 on a 640x480 screen).
*/

#include "host.h"
#include "host_knulli.h"
#include "tomlc17.h"

#include <android/log.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <ucontext.h>

void host_install_signal_handlers(void);

/* ---------- logging and termination */

static const char *priority_name(int priority)
{
	switch (priority)
	{
	case ANDROID_LOG_WARN: return "W";
	case ANDROID_LOG_ERROR: return "E";
	case ANDROID_LOG_FATAL: return "F";
	default: return "I";
	}
}

int __android_log_write(int priority, const char *tag, const char *text)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	fprintf(stderr, "%5ld.%03ld %s %s: %s\n", (long)now.tv_sec, now.tv_nsec / 1000000L, priority_name(priority),
		tag, text);
	return 1;
}

int __android_log_vprint(int priority, const char *tag, const char *format, va_list arguments)
{
	char text[2048];

	vsnprintf(text, sizeof(text), format, arguments);
	return __android_log_write(priority, tag, text);
}

int __android_log_print(int priority, const char *tag, const char *format, ...)
{
	va_list arguments;
	int result;

	va_start(arguments, format);
	result = __android_log_vprint(priority, tag, format, arguments);
	va_end(arguments);
	return result;
}

void host_logf(int priority, const char *format, ...)
{
	va_list arguments;

	va_start(arguments, format);
	__android_log_vprint(priority, "halo", format, arguments);
	va_end(arguments);
}

void host_log(int priority, const char *text)
{
	__android_log_write(priority, "halo", text);
}

void host_fatal(const char *format, ...)
{
	char message[1024];
	va_list arguments;

	va_start(arguments, format);
	vsnprintf(message, sizeof(message), format, arguments);
	va_end(arguments);
	__android_log_write(ANDROID_LOG_FATAL, "halo", message);
	_exit(1);
}

void host_abort(const char *reason)
{
	__android_log_print(ANDROID_LOG_FATAL, "halo", "guest abort: %s", reason);
	abort();
}

void host_exit(int code)
{
	host_logf(HOST_LOG_INFO, "the game exited (%d)", code);
	host_profile_write();
	fflush(stderr);
	_exit(code);
}

int host_errno(void)
{
	return errno;
}

/* ---------- crash diagnosis signal handlers */

static void host_signal_handler(int sig, siginfo_t *info, void *ucontext_ptr)
{
	ucontext_t *uc = (ucontext_t *)ucontext_ptr;
	uintptr_t pc = 0;
#if defined(__aarch64__)
	if (uc)
		pc = (uintptr_t)uc->uc_mcontext.pc;
#endif
	host_logf(HOST_LOG_FATAL, "CRASH: signal %d (%s) at address %p, pc=%p",
		sig, strsignal(sig), info ? info->si_addr : NULL, (void *)pc);
	fflush(stderr);
	_exit(128 + sig);
}

void host_install_signal_handlers(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = host_signal_handler;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGFPE, &sa, NULL);
}

/* ---------- paths */

static char executable_root[PATH_MAX];
static char data_root[PATH_MAX];
static char save_root[PATH_MAX];

void host_android_path(int which, char *buffer, uint32_t size)
{
	snprintf(buffer, size, "%s", which ? save_root : data_root);
}

static void find_executable_root(void)
{
	ssize_t length = readlink("/proc/self/exe", executable_root, sizeof(executable_root) - 1);
	char *slash;

	if (length <= 0)
	{
		strcpy(executable_root, ".");
		return;
	}
	executable_root[length] = '\0';
	slash = strrchr(executable_root, '/');
	if (slash)
		*slash = '\0';
	else
		strcpy(executable_root, ".");
}

static int directory_has_maps(const char *root)
{
	char path[PATH_MAX];
	struct stat state;

	snprintf(path, sizeof(path), "%s/maps/ui.map", root);
	return stat(path, &state) == 0 && S_ISREG(state.st_mode);
}

static int display_width(void)
{
	FILE *file = fopen("/sys/class/graphics/fb0/virtual_size", "r");
	int width = 640;

	if (file)
	{
		int x = 0, y = 0;

		if (fscanf(file, "%d,%d", &x, &y) == 2 && x > 0 && y > 0)
			width = y == 480 ? x : (x * 480) / y;
		fclose(file);
	}
	return width;
}

static void time_zone(char *buffer, size_t size)
{
	char link[PATH_MAX];
	ssize_t length = readlink("/etc/localtime", link, sizeof(link) - 1);
	const char *prefix = "zoneinfo/";
	const char *found;

	if (length > 0)
	{
		link[length] = '\0';
		found = strstr(link, prefix);
		if (found && snprintf(buffer, size, "%s", found + strlen(prefix)) < (int)size)
			return;
	}
	snprintf(buffer, size, "UTC");
}

/* ---------- config */

static int config_sample_seconds(const char *path, char *seconds, size_t size)
{
	FILE *file = fopen(path, "r");
	toml_table_t *config;
	toml_table_t *debug;
	toml_value_t value;
	char error[128];
	int result = 0;

	if (!file)
		return 0;
	config = toml_parse_file(file, error, sizeof(error));
	fclose(file);
	if (!config)
		return 0;
	debug = toml_table_in(config, "debug");
	if (debug)
	{
		value = toml_string_in(debug, "sample");
		if (value.ok)
		{
			snprintf(seconds, size, "%s", value.u.s);
			free(value.u.s);
			result = 1;
		}
	}
	toml_free(config);
	return result;
}

/* ---------- environment and boot block */

#define ENVIRONMENT_MAX 64

struct environment
{
	char *entries[ENVIRONMENT_MAX];
	int count;
};

static void environment_set(struct environment *environment, const char *name, const char *value)
{
	size_t length = strlen(name) + 1 + strlen(value) + 1;
	char *entry = malloc(length);
	int index;

	if (!entry)
		return;
	snprintf(entry, length, "%s=%s", name, value);
	for (index = 0; index < environment->count; index++)
	{
		if (strncmp(environment->entries[index], name, strlen(name)) == 0 &&
			environment->entries[index][strlen(name)] == '=')
		{
			free(environment->entries[index]);
			environment->entries[index] = entry;
			return;
		}
	}
	if (environment->count < ENVIRONMENT_MAX)
		environment->entries[environment->count++] = entry;
	else
		free(entry);
}

static void environment_copy_halo(struct environment *environment)
{
	extern char **environ;
	char **cursor;

	for (cursor = environ; cursor && *cursor; cursor++)
	{
		if (strncmp(*cursor, "HALO_", 5) == 0 ||
			strncmp(*cursor, "MESA_", 5) == 0 ||
			strncmp(*cursor, "SDL_", 4) == 0 ||
			strncmp(*cursor, "TMPDIR=", 7) == 0)
		{
			const char *equals = strchr(*cursor, '=');

			if (equals && environment->count < ENVIRONMENT_MAX)
			{
				size_t name_length = (size_t)(equals - *cursor);
				char name[128];

				if (name_length < sizeof(name))
				{
					memcpy(name, *cursor, name_length);
					name[name_length] = '\0';
					environment_set(environment, name, equals + 1);
				}
			}
		}
	}
}

static uint32_t make_boot(struct environment *environment)
{
	size_t size = 64 * 1024;
	char *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	struct halo_guest_boot *boot;
	uint32_t *argv;
	uint32_t *environ_list;
	char *strings;
	int index;

	if (memory == MAP_FAILED)
		host_fatal("cannot map memory for the guest boot arguments");
	boot = (struct halo_guest_boot *)memory;
	argv = (uint32_t *)(boot + 1);
	environ_list = argv + 2;
	strings = (char *)(environ_list + environment->count + 1);

	strcpy(strings, "halo");
	argv[0] = (uint32_t)(uintptr_t)strings;
	argv[1] = 0;
	strings += strlen("halo") + 1;

	for (index = 0; index < environment->count; index++)
	{
		size_t length = strlen(environment->entries[index]) + 1;

		if (strings + length > memory + size)
			break;
		memcpy(strings, environment->entries[index], length);
		environ_list[index] = (uint32_t)(uintptr_t)strings;
		strings += length;
	}
	environ_list[index] = 0;
	boot->argc = 1;
	boot->argv = (uint32_t)(uintptr_t)argv;
	boot->environment = (uint32_t)(uintptr_t)environ_list;
	boot->page_size = (uint32_t)getpagesize();
	return (uint32_t)(uintptr_t)boot;
}

static void *read_file(const char *path, size_t *size)
{
	FILE *file = fopen(path, "rb");
	void *data = NULL;
	long length;

	if (!file)
		return NULL;
	if (fseek(file, 0, SEEK_END) == 0 && (length = ftell(file)) > 0 && fseek(file, 0, SEEK_SET) == 0)
	{
		data = malloc((size_t)length);
		if (data && fread(data, 1, (size_t)length, file) != (size_t)length)
		{
			free(data);
			data = NULL;
		}
		*size = (size_t)length;
	}
	fclose(file);
	return data;
}

/* ---------- main */

#define MAIN_STACK_SIZE (16 * 1024 * 1024)

static void *game_main(void *unused)
{
	struct environment environment = { { 0 }, 0 };
	const char *setting;
	char zone[64];
	char path[PATH_MAX + 32];
	char width[16];
	size_t image_size = 0;
	void *image;
	uint32_t boot;

	(void)unused;
	setting = getenv("HALO_DATA_ROOT");
	snprintf(data_root, sizeof(data_root), "%s", setting && *setting ? setting : executable_root);
	setting = getenv("HALO_SAVE_ROOT");
	if (setting && *setting)
		snprintf(save_root, sizeof(save_root), "%s", setting);
	else
		snprintf(save_root, sizeof(save_root), "%s/save", data_root);
	mkdir(save_root, 0755);
	if (!directory_has_maps(data_root))
		host_fatal("The Halo game data was not found: %s/maps/ui.map is missing. Put the maps folder of an Xbox "
			"disc image there (the launcher extracts it from a .iso in the same folder).", data_root);

	environment_copy_halo(&environment);
	environment_set(&environment, "HOME", save_root);
	environment_set(&environment, "HALO_DATA_ROOT", data_root);
	environment_set(&environment, "HALO_SAVE_ROOT", save_root);
	setting = getenv("HALO_DISPLAY_WIDTH");
	if (setting && *setting)
		snprintf(width, sizeof(width), "%s", setting);
	else
		snprintf(width, sizeof(width), "%d", display_width());
	environment_set(&environment, "HALO_DISPLAY_WIDTH", width);
	host_logf(HOST_LOG_INFO, "rendering %sx480", width);
	time_zone(zone, sizeof(zone));
	environment_set(&environment, "TZ", zone);

	setting = getenv("HALO_GUEST_IMAGE");
	if (setting && *setting)
		snprintf(path, sizeof(path), "%s", setting);
	else
		snprintf(path, sizeof(path), "%s/halo_guest.elf", executable_root);
	image = read_file(path, &image_size);
	if (!image)
		host_fatal("cannot read the game image %s: %s", path, strerror(errno));
	if (host_load_image(image, image_size) != 0)
		host_fatal("cannot load the game image %s", path);
	free(image);

	snprintf(path, sizeof(path), "%s/config.toml", data_root);
	{
		char seconds[32];

		if (config_sample_seconds(path, seconds, sizeof(seconds)))
			host_debug_start_sampler(seconds);
	}
	boot = make_boot(&environment);
	host_logf(HOST_LOG_INFO, "data %s, saves %s", data_root, save_root);
	host_profile_start(data_root);
	host_run_guest_main(boot);
}

int main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;
	setvbuf(stderr, NULL, _IOLBF, 0);
	find_executable_root();
	host_logf(HOST_LOG_INFO, "Halo for Knulli starting (%s)", executable_root);
	host_install_signal_handlers();
	if (host_native_thread_create(game_main, NULL, MAIN_STACK_SIZE) != 0)
		host_fatal("cannot start the game thread");
	/* the game ends the process itself (host_exit) */
	for (;;)
		pause();
}
