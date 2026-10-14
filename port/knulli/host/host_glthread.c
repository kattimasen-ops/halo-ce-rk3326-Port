/*
HOST_GLTHREAD.C

The GL thread of the Knulli port. On the handheld's Cortex-A53 the Mali
driver's own work (validating state, building descriptors and job chains)
is most of a frame, and it ran on the game's thread. Here the guest's
OpenGL ES calls, and the host functions that make GL calls for it
(host_gl.c, and the context and swap functions of host_sdl2.c), are
recorded into a queue that a thread of their own replays into the driver,
so that the game prepares the next frame while the driver builds this one.

- Calls that return nothing are queued, with a copy of the memory their
  pointers refer to (the generated recording functions, glthread_gen.py),
  and the game goes on at once.
- Calls that return a value wait for the GL thread to reach them. None
  occurs in a frame's usual work: glGen* names come from a reserve that the
  GL thread keeps filled.
- The game may be at most HALO_GL_THREAD_FRAMES (default 1) frames ahead of
  the GL thread: a swap waits for the one before it.

The queue is a ring of one producer (the game's render thread) and one
consumer. Each side spins briefly before sleeping on a futex.

HALO_GL_THREAD=0 makes the calls on the game's thread, as before.
*/

#include "host.h"
#include "host_glthread.h"
#include "host_knulli.h"

#include <EGL/egl.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define RING_SIZE (8u << 20)
/* larger payloads are allocated rather than queued */
#define INLINE_LIMIT (1u << 20)
/* polls before sleeping: a few microseconds, since spinning heats the
   handheld towards the temperature at which its clocks are lowered */
#define SPIN_LIMIT 500

enum
{
	_command_wrap,
	_command_call,
	_command_sync,
	_command_host,
};

#define COMMAND_EXTERNAL 1u

struct command
{
	uint32_t type;
	uint32_t flags;
	uint32_t size;          /* the whole command's, a multiple of 16 */
	uint32_t function;      /* _command_call: which */
};

/* where a command's external payload's pointer is: its last 8 bytes */
static void **external_payload(const struct command *command)
{
	return (void **)((unsigned char *)command + command->size - sizeof(void *));
}

struct sync_call
{
	void (*run)(void *);
	void *context;
	uint32_t *done;
};

struct host_call
{
	void (*run)(const void *data);
};

static unsigned char *ring;
static uint32_t frames_ahead = 1;
static pthread_t thread;
/* what each thread writes, on cache lines of its own: a write to a line the
other thread reads takes it from that core's cache. The producer's own
state, written with every command, is on a line the consumer never reads. */
static struct
{
	uint64_t head;              /* the end of what it wrote */
	uint64_t published;         /* producer_shared.published, as last stored */
	uint64_t consumed;          /* consumer.consumed, when last read */
	struct command *pending;
	uint32_t frames_submitted;
} __attribute__((aligned(64))) producer;
static struct
{
	uint64_t published;         /* the end of what the consumer may read */
	uint32_t sleeping;
} __attribute__((aligned(64))) producer_shared;
static struct
{
	uint64_t consumed;          /* the end of what it has done */
	uint32_t sleeping;
	uint32_t frames_done;
} __attribute__((aligned(64))) consumer;
static int started;
static int enabled = -1;

/* ---------- futexes */

static void futex_wait(uint32_t *word, uint32_t value)
{
	syscall(SYS_futex, word, FUTEX_WAIT_PRIVATE, value, NULL, NULL, 0);
}

static void futex_wake(uint32_t *word)
{
	syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0);
}

static inline void relax(void)
{
	__asm__ volatile("yield" ::: "memory");
}

/* waits while *word is value: spins for a while, then sleeps (whoever
changes the word wakes it) */
static void wait_while_equal(uint32_t *word, uint32_t value, int spins)
{
	int spin;

	for (spin = 0; spin < spins && __atomic_load_n(word, __ATOMIC_ACQUIRE) == value; spin++)
		relax();
	while (__atomic_load_n(word, __ATOMIC_ACQUIRE) == value)
		futex_wait(word, value);
}

/* wakes who sleeps on *word, if anyone does */
static void wake_sleeper(uint32_t *word)
{
	if (__atomic_load_n(word, __ATOMIC_ACQUIRE))
	{
		__atomic_store_n(word, 0, __ATOMIC_RELEASE);
		futex_wake(word);
	}
}

/* publishes up to producer.head to the consumer */
static void publish(void)
{
	if (producer.published == producer.head)
		return;
	producer.published = producer.head;
	__atomic_store_n(&producer_shared.published, producer.published, __ATOMIC_RELEASE);
	wake_sleeper(&producer_shared.sleeping);
}

/* ---------- slow command logging */

enum
{
	_slow_call,
	_slow_sync,
	_slow_host,
};

struct slow_command
{
	int kind;
	uint32_t function;
	void (*run)(const void *);
	uint64_t ns;
};

static struct
{
	uint64_t frame_start;
	uint64_t busy_ns;
	uint32_t calls;
	uint32_t skipped;
	struct slow_command slowest[3];
} gl_hitch;

static double hitch_ms;
static int hitch_on;

static uint64_t host_monotonic_ns(void)
{
	return host_ticks();
}

static void hitch_command(int kind, uint32_t function, void (*run)(const void *), uint64_t ns)
{
	int index = 2;

	gl_hitch.busy_ns += ns;
	if (ns <= gl_hitch.slowest[2].ns)
		return;
	while (index > 0 && ns > gl_hitch.slowest[index - 1].ns)
	{
		gl_hitch.slowest[index] = gl_hitch.slowest[index - 1];
		index--;
	}
	gl_hitch.slowest[index].kind = kind;
	gl_hitch.slowest[index].function = function;
	gl_hitch.slowest[index].run = run;
	gl_hitch.slowest[index].ns = ns;
}

static inline uint64_t command_start(void)
{
	return hitch_on ? host_monotonic_ns() : 0;
}

static inline void command_end(uint32_t function, uint64_t start)
{
	if (start)
		hitch_command(_slow_call, function, NULL, host_monotonic_ns() - start);
}

/* ---------- passes */

static int pass_timing;
static int pass_trace;
static int draw_trace;
static int bind_trace;
static int call_trace;
static uint32_t pass_trace_frame;
static uint32_t pass_trace_count = 1;
static uint32_t bind_frames;
static uint64_t bind_frame_start;
static unsigned long pass_draws;
static unsigned long pass_draw_elements;
static unsigned long pass_draw_arrays;
static unsigned long pass_draw_indices;
static unsigned long pass_draw_vertices;

struct pass_time
{
	const char *name;
	uint32_t fb;
	uint32_t draws;
	uint32_t draws_elements;
	uint32_t draws_arrays;
	uint64_t indices;
	uint64_t vertices;
	uint64_t ns;
};

static struct
{
	uint32_t current_fb;
	uint64_t current_start;
	unsigned int count;
	struct pass_time passes[32];
	uint64_t total_ns;
	uint32_t frames;
} pass_totals;

static void pass_stop(void)
{
	uint64_t elapsed = host_monotonic_ns() - pass_totals.current_start;
	struct pass_time *pass;

	if (pass_totals.count >= sizeof(pass_totals.passes) / sizeof(pass_totals.passes[0]))
		return;
	pass = &pass_totals.passes[pass_totals.count++];
	pass->fb = pass_totals.current_fb;
	pass->draws = pass_draws;
	pass->draws_elements = pass_draw_elements;
	pass->draws_arrays = pass_draw_arrays;
	pass->indices = pass_draw_indices;
	pass->vertices = pass_draw_vertices;
	pass->ns = elapsed;
	pass_totals.total_ns += elapsed;
	if (pass_trace && pass_totals.frames >= pass_trace_frame &&
		pass_totals.frames < pass_trace_frame + pass_trace_count)
	{
		host_logf(HOST_LOG_INFO, "pass %2u: fb %3u, %4.1f ms, %3u draws (%3u el, %3u ar, %6lu idx, %6lu vtx)",
			pass_totals.count, pass->fb, elapsed / 1e6, pass->draws, pass->draws_elements, pass->draws_arrays,
			pass->indices, pass->vertices);
	}
	pass_draws = 0;
	pass_draw_elements = 0;
	pass_draw_arrays = 0;
	pass_draw_indices = 0;
	pass_draw_vertices = 0;
}

static void pass_start(uint32_t fb)
{
	if (pass_totals.current_start)
		pass_stop();
	pass_totals.current_fb = fb;
	pass_totals.current_start = host_monotonic_ns();
}

static void pass_frame(void)
{
	unsigned int index;

	pass_stop();
	pass_totals.frames++;
	if (pass_totals.frames % 300 == 0)
	{
		host_logf(HOST_LOG_INFO, "passes of frame %u (%.1f ms across %u passes):", pass_totals.frames,
			pass_totals.total_ns / 1e6, pass_totals.count);
		for (index = 0; index < pass_totals.count; index++)
		{
			const struct pass_time *pass = &pass_totals.passes[index];

			host_logf(HOST_LOG_INFO, "  %2u: fb %3u, %4.1f ms, %3u draws (%3u el, %3u ar, %6lu idx, %6lu vtx)",
				index + 1, pass->fb, pass->ns / 1e6, pass->draws, pass->draws_elements, pass->draws_arrays,
				pass->indices, pass->vertices);
		}
	}
	pass_totals.count = 0;
	pass_totals.total_ns = 0;
	pass_totals.current_start = 0;
}

void glthread_pass_bind_framebuffer(GLenum target, GLuint framebuffer)
{
	if (pass_timing && target == GL_FRAMEBUFFER)
		pass_start(framebuffer);
}

void glthread_pass_draw_elements(GLsizei count)
{
	pass_draws++;
	pass_draw_elements++;
	pass_draw_indices += count;
	if (draw_trace && pass_totals.frames >= pass_trace_frame &&
		pass_totals.frames < pass_trace_frame + pass_trace_count)
		host_logf(HOST_LOG_INFO, "  draw elements %4d (total %lu)", count, pass_draw_indices);
}

void glthread_pass_draw_arrays(GLsizei count)
{
	pass_draws++;
	pass_draw_arrays++;
	pass_draw_vertices += count;
	if (draw_trace && pass_totals.frames >= pass_trace_frame &&
		pass_totals.frames < pass_trace_frame + pass_trace_count)
		host_logf(HOST_LOG_INFO, "  draw arrays   %4d (total %lu)", count, pass_draw_vertices);
}

/* ---------- timing report (glthread_timing_report) */

struct waits
{
	uint64_t syncs;
	uint64_t sync_ns;
	uint64_t room_waits;
	uint64_t room_ns;
	uint64_t frame_waits;
	uint64_t frame_ns;
};

static struct waits producer_waits;
static struct waits frame_waits;
static int timing;
static int measure_waits;

void glthread_timing_report(uint32_t frames)
{
	if (!timing || !frames)
		return;
	host_logf(HOST_LOG_INFO, "  glthread waits per frame: %.2f ms (%.2f ms room, %.2f ms in %lu syncs, %.2f ms behind)",
		(producer_waits.room_ns + producer_waits.sync_ns + producer_waits.frame_ns) / (frames * 1e6),
		producer_waits.room_ns / (frames * 1e6), producer_waits.sync_ns / (frames * 1e6),
		producer_waits.syncs / frames, producer_waits.frame_ns / (frames * 1e6));
	memset(&producer_waits, 0, sizeof(producer_waits));
}

/* ---------- queue: producer */

/* waits until at least size bytes are free in the ring */
static void wait_for_room(size_t size)
{
	uint64_t start = measure_waits ? host_monotonic_ns() : 0;

	publish();
	for (;;)
	{
		uint64_t done = __atomic_load_n(&consumer.consumed, __ATOMIC_ACQUIRE);

		producer.consumed = done;
		if (RING_SIZE - (producer.head - done) >= size)
			break;
		wait_while_equal(&consumer.sleeping, 0, SPIN_LIMIT);
	}
	if (start)
	{
		frame_waits.room_waits++;
		frame_waits.room_ns += host_monotonic_ns() - start;
	}
}

/* reserves room in the ring for a command of size bytes, publishing
previous commands and sleeping as needed */
static void *reserve_room(size_t size)
{
	size_t offset = (size_t)(producer.head & (RING_SIZE - 1));

	/* the command must fit before the end of the ring */
	if (offset + size > RING_SIZE)
	{
		struct command *wrap;

		if (RING_SIZE - (producer.head - producer.consumed) < size + (RING_SIZE - offset))
			wait_for_room(size + (RING_SIZE - offset));
		wrap = (struct command *)(ring + offset);
		wrap->type = _command_wrap;
		wrap->flags = 0;
		wrap->size = (uint32_t)(RING_SIZE - offset);
		producer.head += wrap->size;
		offset = 0;
	}
	else if (RING_SIZE - (producer.head - producer.consumed) < size)
		wait_for_room(size);
	return ring + offset;
}

void *glthread_begin(uint32_t function, size_t call_size)
{
	size_t size = (sizeof(struct command) + call_size + 15) & ~15u;
	struct command *command = reserve_room(size);

	command->type = _command_call;
	command->flags = 0;
	command->size = (uint32_t)size;
	command->function = function;
	producer.pending = command;
	return command + 1;
}

void *glthread_payload_inline(void *call, size_t size)
{
	(void)call;
	size_t aligned = (size + 15) & ~15u;
	void *space = reserve_room(aligned);

	producer.pending->size += (uint32_t)aligned;
	return space;
}

void *glthread_payload_external(void *call, size_t size)
{
	(void)call;
	void *payload = malloc(size);
	void **slot;

	if (!payload)
		host_fatal("out of memory for a GL thread payload (%zu bytes)", size);
	slot = (void **)glthread_payload_inline(call, sizeof(void *));
	*slot = payload;
	producer.pending->flags |= COMMAND_EXTERNAL;
	return payload;
}

void glthread_end(void)
{
	producer.head += producer.pending->size;
	producer.pending = NULL;
}

static void *host_begin(void (*run)(const void *), size_t call_size)
{
	size_t size = (sizeof(struct command) + sizeof(struct host_call) + call_size + 15) & ~15u;
	struct command *command = reserve_room(size);
	struct host_call *host = (struct host_call *)(command + 1);

	command->type = _command_host;
	command->flags = 0;
	command->size = (uint32_t)size;
	command->function = 0;
	host->run = run;
	producer.pending = command;
	return host + 1;
}

static void glthread_host(void (*run)(const void *), const void *call, size_t size)
{
	void *destination = host_begin(run, size);

	memcpy(destination, call, size);
	glthread_end();
}

static void glthread_sync(void (*run)(void *), void *context)
{
	uint32_t done = 0;
	size_t size = sizeof(struct command) + sizeof(struct sync_call);
	struct command *command = reserve_room(size);
	struct sync_call *call = (struct sync_call *)(command + 1);
	uint64_t start = measure_waits ? host_monotonic_ns() : 0;

	command->type = _command_sync;
	command->flags = 0;
	command->size = (uint32_t)size;
	command->function = 0;
	call->run = run;
	call->context = context;
	call->done = &done;
	producer.pending = command;
	glthread_end();
	publish();
	wait_while_equal(&done, 0, SPIN_LIMIT);
	if (start)
	{
		frame_waits.syncs++;
		frame_waits.sync_ns += host_monotonic_ns() - start;
	}
}

/* ---------- buffers: written without queueing a copy */

struct buffer_write
{
	uint32_t target;
	uint32_t offset;
	uint32_t size;
	const void *data;
};

static void run_buffer_write(const void *data)
{
	const struct buffer_write *call = data;

	host_gl_buffer_write(call->target, call->offset, call->size, call->data);
}

static void queued_gl_buffer_write(uint32_t target, uint32_t offset, uint32_t size, const void *data)
{
	struct buffer_write call = { target, offset, size, data };

	glthread_host(run_buffer_write, &call, sizeof(call));
}

static void run_buffer_write_to(const void *data)
{
	const struct buffer_write *call = data;

	host_gl_buffer_write_to(call->target, call->offset, call->size, call->data);
}

static void queued_gl_buffer_write_to(uint32_t target, uint32_t offset, uint32_t size, const void *data)
{
	struct buffer_write call = { target, offset, size, data };

	glthread_host(run_buffer_write_to, &call, sizeof(call));
}

/* ---------- frame pacing (flip_queue_frame) */

struct frame_times
{
	uint64_t start;
	uint64_t due;
	uint64_t ready;
	uint64_t drawn;
	uint32_t delayed;
};

#define FRAME_HISTORY 16
static struct frame_times frame_times[FRAME_HISTORY];
static int vsync_on = 1;
static int pacing_log;

static void flip_queue_frame(uint32_t frame)
{
	struct frame_times *times = &frame_times[frame % FRAME_HISTORY];
	uint64_t now = host_monotonic_ns();

	if (times->drawn && (now - times->drawn) / 1e6 > 34.0)
		host_logf(HOST_LOG_INFO, "flip: frame %u took %.1f ms (game %.1f, gl %.1f, held %.1f)", frame,
			(now - times->drawn) / 1e6, (times->ready - times->start) / 1e6,
			(now - times->ready) / 1e6, times->due ? (now - times->due) / 1e6 : 0.0);
	times->drawn = now;
}

/* ---------- scanout (DRM/KMS page flip) timing */

static struct
{
	int fd;
	int crtc_id;
	uint64_t period_ns;
	uint64_t last_vblank_ns;
	uint64_t last_flip_ns;
	uint32_t last_sequence;
} scanout_state;

static int scanout;

static void scanout_open(void)
{
	const char *card = getenv("HALO_DRM_CARD");
	int fd;
	struct fb_var_screeninfo var;
	int fb;

	if (scanout)
		return;
	fb = open("/dev/fb0", O_RDWR);
	if (fb >= 0)
	{
		if (ioctl(fb, FBIOGET_VSCREENINFO, &var) == 0 && var.pixclock)
		{
			uint64_t h = var.xres + var.left_margin + var.right_margin + var.hsync_len;
			uint64_t v = var.yres + var.upper_margin + var.lower_margin + var.vsync_len;
			uint64_t ps = (uint64_t)var.pixclock * h * v;

			scanout_state.period_ns = ps / 1000;
		}
		close(fb);
	}
	if (!scanout_state.period_ns)
		scanout_state.period_ns = 1000000000ULL / 60;
	fd = open(card && *card ? card : "/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0)
	{
		host_logf(HOST_LOG_INFO, "frames are not paced: no display timing to read (%s)", strerror(errno));
		return;
	}
	scanout_state.fd = fd;
	scanout = 1;
	host_logf(HOST_LOG_INFO, "frame pacing active (%.2f Hz display)", 1e9 / scanout_state.period_ns);
}

static uint64_t frame_due_time(void)
{
	uint64_t now = host_monotonic_ns();

	if (!scanout || !vsync_on)
		return now;
	/* the next refresh: at least 2 ms after now, so that the frame can be
	drawn before the scanout begins */
	if (scanout_state.last_vblank_ns)
	{
		uint64_t next = scanout_state.last_vblank_ns;

		while (next < now + 2000000ULL)
			next += scanout_state.period_ns;
		return next;
	}
	return now + scanout_state.period_ns;
}

static void frame_hold(uint32_t frame)
{
	struct frame_times *times = &frame_times[frame % FRAME_HISTORY];
	uint64_t due = times->due;
	uint64_t now;

	if (!due || !vsync_on)
		return;
	now = host_monotonic_ns();
	if (now < due)
	{
		struct timespec wait;

		wait.tv_sec = (time_t)((due - now) / 1000000000ULL);
		wait.tv_nsec = (long)((due - now) % 1000000000ULL);
		nanosleep(&wait, NULL);
	}
	else if (now - due > scanout_state.period_ns / 2)
		times->delayed = 1;
}

static void threaded_gl_frame_due(void)
{
	uint32_t submitted = producer.frames_submitted;
	struct frame_times *times = &frame_times[submitted % FRAME_HISTORY];

	times->due = frame_due_time();
}

/* ---------- reserve: glGen* names filled by the GL thread */

enum
{
	_name_textures,
	_name_buffers,
	_name_renderbuffers,
	_name_framebuffers,
	_name_queries,
	_name_vertex_arrays,
	_glthread_name_kinds,
};

#define RESERVE_CAPACITY 256
#define RESERVE_REFILL 64

struct name_reserve
{
	uint32_t count;
	uint32_t names[RESERVE_CAPACITY];
};

static struct name_reserve reserves[_glthread_name_kinds];

struct refill_call
{
	int kind;
	uint32_t count;
};

static void run_refill(const void *data)
{
	const struct refill_call *call = data;
	struct name_reserve *reserve = &reserves[call->kind];
	uint32_t make = RESERVE_CAPACITY - reserve->count;

	if (make > call->count)
		make = call->count;
	switch (call->kind)
	{
	case _name_textures:
		glGenTextures((GLsizei)make, reserve->names + reserve->count);
		break;
	case _name_buffers:
		glGenBuffers((GLsizei)make, reserve->names + reserve->count);
		break;
	case _name_renderbuffers:
		glGenRenderbuffers((GLsizei)make, reserve->names + reserve->count);
		break;
	case _name_framebuffers:
		glGenFramebuffers((GLsizei)make, reserve->names + reserve->count);
		break;
	case _name_queries:
		glGenQueries((GLsizei)make, reserve->names + reserve->count);
		break;
	}
	reserve->count += make;
}

static void refill(int kind, uint32_t count)
{
	struct refill_call call = { kind, count };

	glthread_host(run_refill, &call, sizeof(call));
}

static uint32_t reserve_take(int kind)
{
	struct name_reserve *reserve = &reserves[kind];
	uint32_t name;

	if (reserve->count == 0)
	{
		/* none left: must wait for the GL thread to fill the reserve */
		struct refill_call call = { kind, RESERVE_REFILL };

		glthread_sync((void (*)(void *))run_refill, &call);
	}
	name = reserve->names[--reserve->count];
	if (reserve->count < RESERVE_REFILL / 2)
		refill(kind, RESERVE_REFILL);
	return name;
}

void glthread_names_take(int kind, GLsizei count, GLuint *names)
{
	while (count > 0)
	{
		*names++ = reserve_take(kind);
		count--;
	}
}

/* ---------- async shader and program compilation */

struct program_build
{
	uint32_t program;
	uint32_t path_size;
	uint32_t vertex_size;
	uint32_t fragment_size;
	long long vertex_hash;
	long long fragment_hash;
};

struct program_job
{
	struct program_job *next;
	struct program_build build;
	uint32_t done;
	uint32_t linked;
	unsigned char *deferred;
	size_t deferred_size;
	size_t deferred_capacity;
};

struct builder
{
	const char *name;
	int nice;
	EGLContext context;
	uint32_t state;
	pthread_mutex_t lock;
	pthread_cond_t wake;
	struct program_job *first;
	struct program_job *last;
};

static struct builder loader = { "halo-loader", -2, EGL_NO_CONTEXT, 0, PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, NULL };
static struct builder compiler = { "halo-compiler", 10, EGL_NO_CONTEXT, 0, PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, NULL };
static struct program_job **jobs;
static uint32_t job_capacity;
static struct program_job unbuildable;
static int builders_running;
static EGLDisplay share_display;
static EGLContext share_context = EGL_NO_CONTEXT;
static EGLConfig share_config;
static EGLint share_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
static GLuint bound_program;
int glthread_program_blocked;
int glthread_direct;

static uint32_t programs_compiled;
static uint32_t programs_built;
static unsigned long skipped_draws;
static unsigned long skipped_frames;
static unsigned long program_frames;

static void builder_push(struct builder *builder, struct program_job *job)
{
	job->next = NULL;
	pthread_mutex_lock(&builder->lock);
	if (builder->last)
		builder->last->next = job;
	else
		builder->first = job;
	builder->last = job;
	pthread_cond_signal(&builder->wake);
	pthread_mutex_unlock(&builder->lock);
}

static struct program_job *builder_pop(struct builder *builder)
{
	struct program_job *job;

	pthread_mutex_lock(&builder->lock);
	while (!builder->first)
		pthread_cond_wait(&builder->wake, &builder->lock);
	job = builder->first;
	builder->first = job->next;
	if (!builder->first)
		builder->last = NULL;
	pthread_mutex_unlock(&builder->lock);
	return job;
}

typedef EGLDisplay (*pfn_eglGetCurrentDisplay)(void);
typedef EGLContext (*pfn_eglGetCurrentContext)(void);
typedef EGLBoolean (*pfn_eglQueryContext)(EGLDisplay, EGLContext, EGLint, EGLint *);
typedef EGLBoolean (*pfn_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
typedef EGLContext (*pfn_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
typedef EGLSurface (*pfn_eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
typedef EGLBoolean (*pfn_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
typedef EGLint     (*pfn_eglGetError)(void);

static pfn_eglGetCurrentDisplay    p_eglGetCurrentDisplay;
static pfn_eglGetCurrentContext    p_eglGetCurrentContext;
static pfn_eglQueryContext        p_eglQueryContext;
static pfn_eglChooseConfig        p_eglChooseConfig;
static pfn_eglCreateContext       p_eglCreateContext;
static pfn_eglCreatePbufferSurface p_eglCreatePbufferSurface;
static pfn_eglMakeCurrent         p_eglMakeCurrent;
static pfn_eglGetError            p_eglGetError;
static void *egl_lib_handle;
static int egl_funcs_resolved;
static EGLSurface share_pbuffer = EGL_NO_SURFACE;

static void resolve_egl_functions(void)
{
	if (egl_funcs_resolved)
		return;
	egl_funcs_resolved = 1;

	static const char *const lib_candidates[] = {
		"/tmp/halo-mali/libmali.so.0",
		"/tmp/halo-mali/libEGL.so.1",
		"/usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so",
		"/usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so",
		"libmali.so.1",
		"libmali.so.0",
		"libmali.so",
		"libEGL.so.1",
		"libEGL.so",
		"/usr/lib/aarch64-linux-gnu/libmali.so.1",
		"/usr/lib/aarch64-linux-gnu/libmali.so",
		"/usr/lib/libmali.so",
		"/usr/lib/aarch64-linux-gnu/libEGL.so.1",
		NULL
	};

	for (int i = 0; lib_candidates[i] && !egl_lib_handle; i++)
	{
		egl_lib_handle = dlopen(lib_candidates[i], RTLD_NOW | RTLD_GLOBAL);
	}

#define RESOLVE_EGL(fn) do { \
	if (egl_lib_handle) p_##fn = (pfn_##fn)dlsym(egl_lib_handle, #fn); \
	if (!p_##fn) p_##fn = (pfn_##fn)dlsym(RTLD_DEFAULT, #fn); \
} while (0)

	RESOLVE_EGL(eglGetCurrentDisplay);
	RESOLVE_EGL(eglGetCurrentContext);
	RESOLVE_EGL(eglQueryContext);
	RESOLVE_EGL(eglChooseConfig);
	RESOLVE_EGL(eglCreateContext);
	RESOLVE_EGL(eglCreatePbufferSurface);
	RESOLVE_EGL(eglMakeCurrent);
	RESOLVE_EGL(eglGetError);
#undef RESOLVE_EGL
}

/* on the GL thread, once its context is made */
static void share_initialize(void)
{
	EGLint config_id = 0, version = 3, count = 0;
	EGLint config_attributes[] = { EGL_CONFIG_ID, 0, EGL_NONE };

	host_logf(HOST_LOG_INFO, "DIAG: share_initialize entering resolve");
	resolve_egl_functions();
	host_logf(HOST_LOG_INFO, "DIAG: share_initialize resolved, handle=%p", egl_lib_handle);

	if (!p_eglGetCurrentDisplay || !p_eglGetCurrentContext ||
	    !p_eglQueryContext || !p_eglChooseConfig || !p_eglCreateContext || !p_eglMakeCurrent)
	{
		host_logf(HOST_LOG_INFO, "EGL share: dynamic EGL symbols unavailable; building on GL thread");
		share_context = EGL_NO_CONTEXT;
		return;
	}

	host_logf(HOST_LOG_INFO, "DIAG: share_initialize calling eglGetCurrentDisplay");
	share_display = p_eglGetCurrentDisplay();
	host_logf(HOST_LOG_INFO, "DIAG: share_display=%p", (void *)share_display);
	if (share_display == EGL_NO_DISPLAY || !share_display)
	{
		host_logf(HOST_LOG_INFO, "EGL share: no active EGL display; building on GL thread");
		share_context = EGL_NO_CONTEXT;
		return;
	}

	host_logf(HOST_LOG_INFO, "DIAG: share_initialize calling eglGetCurrentContext");
	share_context = p_eglGetCurrentContext();
	host_logf(HOST_LOG_INFO, "DIAG: share_context=%p", (void *)share_context);
	if (share_context == EGL_NO_CONTEXT || !share_context)
	{
		host_logf(HOST_LOG_INFO, "EGL share: no active EGL context; building on GL thread");
		share_context = EGL_NO_CONTEXT;
		return;
	}

	if (!p_eglQueryContext(share_display, share_context, EGL_CONFIG_ID, &config_id) ||
	    !p_eglQueryContext(share_display, share_context, EGL_CONTEXT_CLIENT_VERSION, &version))
	{
		host_logf(HOST_LOG_INFO, "EGL share: eglQueryContext failed; building on GL thread");
		share_context = EGL_NO_CONTEXT;
		return;
	}

	config_attributes[1] = config_id;
	share_attributes[1] = version;
	if (!p_eglChooseConfig(share_display, config_attributes, &share_config, 1, &count) || count != 1)
	{
		host_logf(HOST_LOG_INFO, "EGL share: eglChooseConfig failed; building on GL thread");
		share_context = EGL_NO_CONTEXT;
		return;
	}
	host_logf(HOST_LOG_INFO, "EGL share: initialized successfully (config %d, version %d)", config_id, version);
}

/* a context that shares the GL thread's objects, or EGL_NO_CONTEXT */
static EGLContext share_new(void)
{
	return (share_context == EGL_NO_CONTEXT || !p_eglCreateContext) ? EGL_NO_CONTEXT :
		p_eglCreateContext(share_display, share_config, share_context, share_attributes);
}

/* such a context current on the calling thread, without a surface
(EGL_KHR_surfaceless_context), with 1x1 pbuffer fallback if surfaceless unsupported */
static int share_make_current(EGLContext context)
{
	if (context == EGL_NO_CONTEXT || !p_eglMakeCurrent)
		return 0;
	if (p_eglMakeCurrent(share_display, EGL_NO_SURFACE, EGL_NO_SURFACE, context))
		return 1;
	if (share_pbuffer == EGL_NO_SURFACE && p_eglCreatePbufferSurface)
	{
		EGLint pbuffer_attribs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
		share_pbuffer = p_eglCreatePbufferSurface(share_display, share_config, pbuffer_attribs);
	}
	if (share_pbuffer != EGL_NO_SURFACE)
		return p_eglMakeCurrent(share_display, share_pbuffer, share_pbuffer, context);
	return 0;
}

/* host_gl_texture_thread: a shared context of its own, current on the
guest's texture worker's thread (xbox_textures.c), which then makes its GL
calls itself */
static int threaded_gl_texture_thread(void)
{
	if (!share_make_current(share_new()))
		return 0;
	glthread_direct = 1;
	return 1;
}

static void *builder_main(void *argument)
{
	struct builder *builder = argument;
	int current = share_make_current(builder->context);

	setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), builder->nice);
	__atomic_store_n(&builder->state, current ? 1u : 2u, __ATOMIC_SEQ_CST);
	futex_wake(&builder->state);
	if (!current)
		return NULL;
	for (;;)
	{
		struct program_job *job = builder_pop(builder);
		const char *path = (const char *)(job + 1);
		const char *vertex = path + job->build.path_size;

		if (builder == &loader)
		{
			if (!host_gl_program_load(job->build.program, path))
			{
				builder_push(&compiler, job);
				continue;
			}
			job->linked = 1;
		}
		else
		{
			job->linked = (uint32_t)host_gl_program_compile(job->build.program, path, vertex, job->build.vertex_hash,
				vertex + job->build.vertex_size, job->build.fragment_hash);
			__atomic_add_fetch(&programs_compiled, 1, __ATOMIC_RELAXED);
		}
		/* complete on this context before the GL thread's binds it */
		glFinish();
		__atomic_add_fetch(&programs_built, 1, __ATOMIC_RELAXED);
		__atomic_store_n(&job->done, 1, __ATOMIC_RELEASE);
	}
	return NULL;
}

/* on the GL thread, once its context is made: the builders, on contexts
that share its objects */
static void builders_start(void)
{
	struct builder *builders[] = { &loader, &compiler };
	const char *setting = getenv("HALO_ASYNC_PROGRAMS");
	unsigned int index = 0;

	if (builders_running || (setting && *setting == '0'))
		return;
	for (; index < 2; index++)
	{
		pthread_t builder_thread;

		builders[index]->context = share_new();
		if (builders[index]->context == EGL_NO_CONTEXT ||
			pthread_create(&builder_thread, NULL, builder_main, builders[index]) != 0)
			break;
		pthread_setname_np(builder_thread, builders[index]->name);
	}
	/* each makes its context current on its own thread */
	builders_running = index == 2;
	while (index > 0)
	{
		index--;
		wait_while_equal(&builders[index]->state, 0, SPIN_LIMIT);
		if (builders[index]->state != 1)
			builders_running = 0;
	}
	if (builders_running)
		host_logf(HOST_LOG_INFO, "programs are built by threads of their own");
	else
		host_logf(HOST_LOG_WARN, "cannot start the program builders (EGL error 0x%x): programs are built on the GL thread",
			p_eglGetError ? p_eglGetError() : 0);
}

/* the program names the builders' table takes (the driver's names are
small and dense; a larger one is built on the GL thread) */
#define JOB_NAMES (1u << 20)

static void run_program_build(const void *data)
{
	const struct program_build *build = data;
	const char *strings = (const char *)(build + 1);
	struct program_job *job;
	size_t size;

	size = build->path_size + build->vertex_size + build->fragment_size;
	if (builders_running && build->program < JOB_NAMES && build->program >= job_capacity)
	{
		uint32_t capacity = job_capacity ? job_capacity : 1024;
		struct program_job **grown;

		while (capacity <= build->program)
			capacity *= 2;
		grown = realloc(jobs, capacity * sizeof(*jobs));
		if (grown)
		{
			memset(grown + job_capacity, 0, (capacity - job_capacity) * sizeof(*jobs));
			jobs = grown;
			job_capacity = capacity;
		}
	}
	job = builders_running && build->program < job_capacity ? malloc(sizeof(*job) + size) : NULL;
	if (!job)
	{
		host_gl_program_build(build->program, strings, strings + build->path_size, build->vertex_hash,
			strings + build->path_size + build->vertex_size, build->fragment_hash);
		return;
	}
	memset(job, 0, sizeof(*job));
	job->build = *build;
	memcpy(job + 1, strings, size);
	jobs[build->program] = job;
	builder_push(&loader, job);
}

static void queued_gl_program_build(uint32_t program, const char *cache_path, const char *vertex_source,
	long long vertex_hash, const char *fragment_source, long long fragment_hash)
{
	size_t path_size = strlen(cache_path) + 1, vertex_size = strlen(vertex_source) + 1;
	size_t fragment_size = strlen(fragment_source) + 1;
	struct program_build *build = host_begin(run_program_build,
		sizeof(*build) + path_size + vertex_size + fragment_size);
	char *strings = (char *)(build + 1);

	build->program = program;
	build->path_size = (uint32_t)path_size;
	build->vertex_size = (uint32_t)vertex_size;
	build->fragment_size = (uint32_t)fragment_size;
	build->vertex_hash = vertex_hash;
	build->fragment_hash = fragment_hash;
	memcpy(strings, cache_path, path_size);
	memcpy(strings + path_size, vertex_source, vertex_size);
	memcpy(strings + path_size + vertex_size, fragment_source, fragment_size);
	glthread_end();
}

/* whether the program may be bound: it is not being built. One found not to
build becomes unbuildable */
static int program_ready(uint32_t program)
{
	struct program_job *job = program < job_capacity ? jobs[program] : NULL;

	if (!job)
		return 1;
	if (job == &unbuildable || !__atomic_load_n(&job->done, __ATOMIC_ACQUIRE))
		return 0;
	if (!job->linked)
	{
		free(job->deferred);
		free(job);
		jobs[program] = &unbuildable;
		return 0;
	}
	return 1;
}

/* binds the program, now built, and makes the uniform calls kept for it */
static void program_bind(uint32_t program)
{
	struct program_job *job = program < job_capacity ? jobs[program] : NULL;
	size_t offset;

	glthread_program_blocked = 0;
	glthread_driver_use_program(program);
	if (!job)
		return;
	jobs[program] = NULL;
	for (offset = 0; offset < job->deferred_size;)
	{
		const struct command *command = (const struct command *)(job->deferred + offset);

		glthread_replay(command->function, command + 1);
		offset += command->size;
	}
	free(job->deferred);
	free(job);
}

/* binds the bound program if it is built now: whether it could */
static int program_unblock(void)
{
	if (!program_ready(bound_program))
		return 0;
	program_bind(bound_program);
	return 1;
}

void glthread_program_use(GLuint program)
{
	bound_program = program;
	glthread_program_blocked = !program_unblock();
}

int glthread_program_draw(void)
{
	if (program_unblock())
		return 1;
	gl_hitch.skipped++;
	return 0;
}

/* a uniform call's command is kept whole (a uniform's payload is always in
the queue, never allocated) */
int glthread_program_uniform(const void *call)
{
	const struct command *command = (const struct command *)call - 1;
	struct program_job *job;

	if (program_unblock())
		return 1;
	job = jobs[bound_program];
	if (job == &unbuildable)
		return 0;
	if (job->deferred_size + command->size > job->deferred_capacity)
	{
		size_t capacity = job->deferred_capacity ? job->deferred_capacity : 1024;
		unsigned char *grown;

		while (job->deferred_size + command->size > capacity)
			capacity *= 2;
		grown = realloc(job->deferred, capacity);
		if (!grown)
		{
			/* (without memory the uniform is lost: the program draws with
			what it had) */
			host_logf(HOST_LOG_WARN, "out of memory for a program's uniforms");
			return 0;
		}
		job->deferred = grown;
		job->deferred_capacity = capacity;
	}
	memcpy(job->deferred + job->deferred_size, command, command->size);
	job->deferred_size += command->size;
	return 0;
}

struct buffer_persistent
{
	uint32_t target, size;
};

static void run_buffer_persistent(const void *data)
{
	const struct buffer_persistent *call = data;

	host_gl_buffer_persistent(call->target, call->size);
}

static void queued_gl_buffer_persistent(uint32_t target, uint32_t size)
{
	struct buffer_persistent call = { target, size };

	glthread_host(run_buffer_persistent, &call, sizeof(call));
}

static void run_fence_frame(const void *data)
{
	host_gl_fence_frame(*(const uint32_t *)data);
}

static void queued_gl_fence_frame(uint32_t slot)
{
	glthread_host(run_fence_frame, &slot, sizeof(slot));
}

static void run_wait_frame(const void *data)
{
	host_gl_wait_frame(*(const uint32_t *)data);
}

static void queued_gl_wait_frame(uint32_t slot)
{
	glthread_host(run_wait_frame, &slot, sizeof(slot));
}

void host_gl_visibility_frame(uint32_t counters, uint32_t counter_bytes, const uint32_t *pairs, uint32_t pair_count);

struct visibility_frame
{
	uint32_t counters, counter_bytes, pair_count;
};

static void run_visibility_frame(const void *data)
{
	const struct visibility_frame *frame = data;

	host_gl_visibility_frame(frame->counters, frame->counter_bytes, (const uint32_t *)(frame + 1), frame->pair_count);
}

static void queued_gl_visibility_frame(uint32_t counters, uint32_t counter_bytes, const uint32_t *pairs,
	uint32_t pair_count)
{
	struct visibility_frame *frame = host_begin(run_visibility_frame, sizeof(*frame) + pair_count * HALO_VISIBILITY_PAIR_WORDS * sizeof(uint32_t));

	frame->counters = counters;
	frame->counter_bytes = counter_bytes;
	frame->pair_count = pair_count;
	memcpy(frame + 1, pairs, pair_count * HALO_VISIBILITY_PAIR_WORDS * sizeof(uint32_t));
	glthread_end();
}

struct string_call
{
	uint32_t name;
	int index;
	char *buffer;
	uint32_t size;
	const char *extension;
	uint32_t result;
};

static void run_get_string(void *context)
{
	struct string_call *call = context;

	host_gl_get_string(call->name, call->index, call->buffer, call->size);
}

static void synced_gl_get_string(uint32_t name, int index, char *buffer, uint32_t size)
{
	struct string_call call = { name, index, buffer, size, NULL, 0 };

	glthread_sync(run_get_string, &call);
}

static void run_has_extension(void *context)
{
	struct string_call *call = context;

	call->result = (uint32_t)host_gl_has_extension(call->extension);
}

static int synced_gl_has_extension(const char *name)
{
	struct string_call call = { 0, 0, NULL, 0, name, 0 };

	glthread_sync(run_has_extension, &call);
	return (int)call.result;
}

struct word_call
{
	uint32_t a, b;
	int c;
	uint32_t result;
};

static void run_read_buffer_word(void *context)
{
	struct word_call *call = context;

	call->result = host_gl_read_buffer_word(call->a, call->b);
}

static uint32_t synced_gl_read_buffer_word(uint32_t buffer, uint32_t offset)
{
	struct word_call call = { buffer, offset, 0, 0 };

	glthread_sync(run_read_buffer_word, &call);
	return call.result;
}

static void run_create_context(void *context)
{
	struct word_call *call = context;
	int kind;

	host_logf(HOST_LOG_INFO, "DIAG: run-create ENTER (gl)");
	call->result = host_sdl_gl_create_context(call->a);
	host_logf(HOST_LOG_INFO, "DIAG: run-create after create result=%u", call->result);
	/* the reserve of names, now that there is a context */
	if (call->result)
	{
		host_logf(HOST_LOG_INFO, "DIAG: refill start");
		for (kind = 0; kind < _glthread_name_kinds; kind++)
		{
			if (!reserves[kind].count)
				refill(kind, RESERVE_REFILL);
		}
		host_logf(HOST_LOG_INFO, "DIAG: refill done");
		host_logf(HOST_LOG_INFO, "DIAG: share_initialize start");
		share_initialize();
		host_logf(HOST_LOG_INFO, "DIAG: share_initialize done");
		host_logf(HOST_LOG_INFO, "DIAG: scanout_open start");
		scanout_open();
		host_logf(HOST_LOG_INFO, "DIAG: scanout_open done");
		host_logf(HOST_LOG_INFO, "DIAG: builders_start start");
		builders_start();
		host_logf(HOST_LOG_INFO, "DIAG: builders_start done");
	}
	host_logf(HOST_LOG_INFO, "DIAG: run-create EXIT (gl)");
}

static void start(void);
static void run_swap(const void *data);

static const char *host_operation_name(void (*run)(const void *))
{
	if (run == run_buffer_write_to)
		return "buffer write";
	if (run == run_fence_frame)
		return "fence";
	if (run == run_wait_frame)
		return "wait for a frame";
	if (run == run_swap)
		return "swap";
	if (run == run_refill)
		return "reserve names";
	if (run == run_program_build)
		return "program build";
	return "?";
}

static uint32_t synced_sdl_gl_create_context(uint32_t window)
{
	struct word_call call = { window, 0, 0, 0 };

	host_logf(HOST_LOG_INFO, "DIAG: sync-create ENTER (main)");
	start();
	host_logf(HOST_LOG_INFO, "DIAG: sync-create after start() (main)");
	glthread_sync(run_create_context, &call);
	host_logf(HOST_LOG_INFO, "DIAG: sync-create EXIT (main) result=%u", call.result);
	return call.result;
}

static void run_make_current(void *context)
{
	struct word_call *call = context;

	call->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);
}

static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)
{
	struct word_call call = { window, context, 0, 0 };

	host_logf(HOST_LOG_INFO, "DIAG: sync-make ENTER (main)");
	glthread_sync(run_make_current, &call);
	host_logf(HOST_LOG_INFO, "DIAG: sync-make EXIT (main) result=%d", call.result);
	return (int)call.result;
}

static void run_swap_interval(void *context)
{
	struct word_call *call = context;

	call->result = (uint32_t)host_sdl_gl_set_swap_interval(call->c);
	/* frames that do not wait for the display have no refresh to be due at */
	vsync_on = host_sdl_gl_swap_interval() != 0;
}

static int synced_sdl_gl_set_swap_interval(int interval)
{
	struct word_call call = { 0, 0, interval, 0 };

	glthread_sync(run_swap_interval, &call);
	return (int)call.result;
}

/* the name of one of the GL thread's slowest commands of the frame */
static const char *slow_name(int slot)
{
	switch (gl_hitch.slowest[slot].kind)
	{
	case _slow_call:
		return glthread_function_name(gl_hitch.slowest[slot].function);
	case _slow_sync:
		return "a synchronous call";
	case _slow_host:
		return host_operation_name(gl_hitch.slowest[slot].run);
	default:
		return "-";
	}
}

static void run_swap(const void *data)
{
	const struct swap_call *call = data;

	/* (frame pacing: when the GL thread reached the frame's swap) */
	if (scanout)
		frame_times[call->frame % FRAME_HISTORY].ready = host_monotonic_ns();
	if (bind_trace)
	{
		uint64_t start = host_monotonic_ns();

		if (bind_frames >= 1500 && bind_frames < 1503)
			host_logf(HOST_LOG_INFO, "call: at %6.2f ms the swap", (start - bind_frame_start) / 1e6);
		bind_frames++;
		bind_frame_start = start;
		call_trace = bind_frames >= 1500 && bind_frames < 1503;
	}
	if (pass_timing)
		pass_frame();
	if (hitch_on)
	{
		uint64_t now = host_monotonic_ns();

		if (gl_hitch.frame_start && (now - gl_hitch.frame_start) / 1e6 > hitch_ms)
		{
			host_logf(HOST_LOG_INFO, "hitch: GL thread %.1f ms frame, %.1f ms in %u calls; slowest %s %.1f, %s %.1f, "
				"%s %.1f; %u draws skipped", (now - gl_hitch.frame_start) / 1e6, gl_hitch.busy_ns / 1e6, gl_hitch.calls,
				slow_name(0), gl_hitch.slowest[0].ns / 1e6, slow_name(1), gl_hitch.slowest[1].ns / 1e6,
				slow_name(2), gl_hitch.slowest[2].ns / 1e6, gl_hitch.skipped);
		}
		/* the program builders' work, every 600 frames */
		skipped_draws += gl_hitch.skipped;
		if (gl_hitch.skipped)
			skipped_frames++;
		if (++program_frames % 600 == 0)
			host_logf(HOST_LOG_INFO, "programs: %u built beside the GL thread (%u compiled); %lu draws skipped, "
				"in %lu frames, while theirs were", __atomic_load_n(&programs_built, __ATOMIC_RELAXED),
				__atomic_load_n(&programs_compiled, __ATOMIC_RELAXED), skipped_draws, skipped_frames);
	}
	if (scanout)
	{
		frame_hold(call->frame);
		if (pacing_log)
			flip_queue_frame(call->frame);
	}
	host_sdl_gl_swap_window(call->window);
	if (hitch_on)
	{
		memset(&gl_hitch, 0, sizeof(gl_hitch));
		gl_hitch.frame_start = host_monotonic_ns();
	}
	__atomic_add_fetch(&consumer.frames_done, 1, __ATOMIC_SEQ_CST);
	futex_wake(&consumer.frames_done);
}

static void waits_add(struct waits *total, const struct waits *frame)
{
	total->syncs += frame->syncs;
	total->sync_ns += frame->sync_ns;
	total->room_waits += frame->room_waits;
	total->room_ns += frame->room_ns;
	total->frame_waits += frame->frame_waits;
	total->frame_ns += frame->frame_ns;
}

static int queued_sdl_gl_swap_window(uint32_t window)
{
	uint32_t submitted = ++producer.frames_submitted;
	struct swap_call call = { window, submitted };
	/* when this frame began (its previous swap's wait ended), and the next */
	uint64_t start = frame_times[submitted % FRAME_HISTORY].start, waited, now;
	struct frame_times *next = &frame_times[(submitted + 1) % FRAME_HISTORY];

	glthread_host(run_swap, &call, sizeof(call));
	publish();
	/* at most frames_ahead frames queued behind the one on screen: the
	counter is the futex, so that only swaps wake the game, not every
	command the GL thread makes */
	waited = measure_waits ? host_monotonic_ns() : 0;
	for (;;)
	{
		uint32_t done = __atomic_load_n(&consumer.frames_done, __ATOMIC_ACQUIRE);

		if (submitted - done <= frames_ahead)
			break;
		wait_while_equal(&consumer.frames_done, done, SPIN_LIMIT);
	}
	now = host_monotonic_ns();
	next->start = now;
	next->due = 0;
	if (measure_waits)
	{
		frame_waits.frame_waits++;
		frame_waits.frame_ns += now - waited;
		if (timing)
			waits_add(&producer_waits, &frame_waits);
		if (hitch_on && start && (now - start) / 1e6 > hitch_ms)
		{
			host_logf(HOST_LOG_INFO, "hitch: game thread %.1f ms frame; waited %.1f ms for room in the queue (%u times), "
				"%.1f ms in %u synchronous calls, %.1f ms for the frame before", (now - start) / 1e6,
				frame_waits.room_ns / 1e6, (unsigned int)frame_waits.room_waits, frame_waits.sync_ns / 1e6,
				(unsigned int)frame_waits.syncs, (now - waited) / 1e6);
		}
		memset(&frame_waits, 0, sizeof(frame_waits));
	}
	/* for the profiler: where each frame ends among its samples */
	if (start && host_profile_sampling())
		host_profile_mark(submitted, (uint32_t)((now - start) / 1000));
	return 1;
}

/* ---------- start-up */

static int glthread_enabled(void)
{
	if (enabled < 0)
	{
		const char *setting = getenv("HALO_GL_THREAD");
		const char *frames = getenv("HALO_GL_THREAD_FRAMES");
		const char *timing = getenv("HALO_GPU_PASS_TIMING");
		const char *hitch = getenv("HALO_HITCH_LOG");
		const char *pacing = getenv("HALO_PACING_LOG");

		hitch_ms = hitch ? atof(hitch) : 0.0;
		hitch_on = hitch_ms > 0.0;
		pacing_log = pacing && *pacing ? atoi(pacing) : 0;

		enabled = !(setting && *setting == '0');
		pass_timing = timing && *timing && *timing != '0';
		pass_trace = timing && (*timing == '2' || *timing == '3');
		draw_trace = timing && *timing == '3';
		if (getenv("HALO_GPU_TRACE_PASSES_AT"))
			pass_trace_frame = (uint32_t)atoi(getenv("HALO_GPU_TRACE_PASSES_AT"));
		if (getenv("HALO_GPU_TRACE_PASSES_FRAMES"))
			pass_trace_count = (uint32_t)atoi(getenv("HALO_GPU_TRACE_PASSES_FRAMES"));
		bind_trace = timing && *timing == '4';
		if (bind_trace)
			pass_timing = 0;
		if (frames && *frames)
		{
			int ahead = atoi(frames);

			frames_ahead = ahead < 0 ? 1 : ahead > 7 ? 7 : (uint32_t)ahead;
		}
	}
	return enabled;
}

static void start(void)
{
	if (started)
		return;
	ring = mmap(NULL, RING_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (ring == MAP_FAILED)
		host_fatal("cannot make the GL thread's queue");
	timing = host_gl_timing_enabled();
	measure_waits = timing || hitch_on;
	if (pthread_create(&thread, NULL, gl_thread_main, NULL) != 0)
		host_fatal("cannot start the GL thread");
	pthread_setname_np(thread, "halo-gl");
	started = 1;
	host_logf(HOST_LOG_INFO, "GL thread started (%u frame%s ahead)", frames_ahead, frames_ahead == 1 ? "" : "s");
}

static void skipped_call(void)
{
}

void *host_import_wrap(const char *name, void *function)
{
	static const struct
	{
		const char *name;
		void *function;
	} host_functions[] =
	{
		{ "host_gl_get_string", (void *)synced_gl_get_string },
		{ "host_gl_has_extension", (void *)synced_gl_has_extension },
		{ "host_gl_read_buffer_word", (void *)synced_gl_read_buffer_word },
		{ "host_gl_buffer_write", (void *)queued_gl_buffer_write },
		{ "host_gl_buffer_persistent", (void *)queued_gl_buffer_persistent },
		{ "host_gl_program_build", (void *)queued_gl_program_build },
		{ "host_gl_texture_thread", (void *)threaded_gl_texture_thread },
		{ "host_gl_frame_due", (void *)threaded_gl_frame_due },
		{ "host_gl_buffer_write_to", (void *)queued_gl_buffer_write_to },
		{ "host_gl_fence_frame", (void *)queued_gl_fence_frame },
		{ "host_gl_wait_frame", (void *)queued_gl_wait_frame },
		{ "host_gl_visibility_frame", (void *)queued_gl_visibility_frame },
		{ "host_sdl_gl_create_context", (void *)synced_sdl_gl_create_context },
		{ "host_sdl_gl_make_current", (void *)synced_sdl_gl_make_current },
		{ "host_sdl_gl_set_swap_interval", (void *)synced_sdl_gl_set_swap_interval },
		{ "host_sdl_gl_swap_window", (void *)queued_sdl_gl_swap_window },
	};
	unsigned long index;

	if (function && !strncmp(name, "hostgl_", 7))
	{
		/* HALO_DEBUG_SKIP_GL=glA,glB: the GL thread does not make these
		calls, to measure what they cost the calls after them */
		const char *skip = getenv("HALO_DEBUG_SKIP_GL");
		size_t length = strlen(name + 7);

		void *direct = function;

		/* HALO_GL_TIMING: the driver's function, timed */
		function = host_gl_wrap(name + 7, function);
		if (!glthread_enabled())
			return function;

		while (skip && *skip)
		{
			if (!strncmp(skip, name + 7, length) && (skip[length] == ',' || !skip[length]))
			{
				host_logf(HOST_LOG_WARN, "debug: not making %s", name + 7);
				function = (void *)skipped_call;
				break;
			}
			skip = strchr(skip, ',');
			if (skip)
				skip++;
		}
		return glthread_record_function(name + 7, function, direct);
	}
	if (!function || !glthread_enabled())
		return function;
	for (index = 0; index < sizeof(host_functions) / sizeof(host_functions[0]); index++)
	{
		if (!strcmp(host_functions[index].name, name))
			return host_functions[index].function;
	}
	return function;
}
