/*
HOST_GL_TIMING.S

The shared half of the OpenGL call timer (host_gl_timing.c): each wrapped
function's stub loads its slot into x16 and branches here. The driver's
function runs with the caller's registers and stack untouched (x9 to x17
are free between calls), and the counter's ticks around it and the call go
into the slot: { function, calls, ticks, longest, longest's caller }.

GL runs on one thread, so the return address and start time wait in one
global save area rather than on the stack, which must stay as the caller
left it for arguments passed there.
*/

	.text
	.globl	host_gl_timing_common
	.type	host_gl_timing_common, %function
	.p2align 4
host_gl_timing_common:
	ldr	x17, [x16, #0]
	br	x17
	.size	host_gl_timing_common, .-host_gl_timing_common

	.bss
	.p2align 4
	.globl	host_gl_timing_save
host_gl_timing_save:
	.zero	32

	.section .note.GNU-stack,"",%progbits
