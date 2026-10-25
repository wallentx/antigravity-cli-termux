#include <stdarg.h>
#include <unistd.h>

#ifndef ENOSYS
#define ENOSYS 38
#endif

#define AGY_SECCOMP_BLOCKED_SYSCALL_1 788533211L
#define AGY_SECCOMP_BLOCKED_SYSCALL_2 0x2f000fdbL
#define AGY_MAX_LINUX_ARM64_SYSCALL 500L
#define AGY_MAX_ERRNO_VALUE 4095UL

extern int *__errno_location(void);

static inline void set_errno(int err) {
    int *loc = __errno_location();
    if (loc != NULL) {
        *loc = err;
    }
}

long syscall(long number, ...) {
    if (number == AGY_SECCOMP_BLOCKED_SYSCALL_1 || number == AGY_SECCOMP_BLOCKED_SYSCALL_2 ||
        number < 0 || number >= AGY_MAX_LINUX_ARM64_SYSCALL) {
        set_errno(ENOSYS);
        return -1;
    }

    va_list args;
    va_start(args, number);
    long arg1 = va_arg(args, long);
    long arg2 = va_arg(args, long);
    long arg3 = va_arg(args, long);
    long arg4 = va_arg(args, long);
    long arg5 = va_arg(args, long);
    long arg6 = va_arg(args, long);
    va_end(args);

#if defined(__aarch64__) && !defined(__CPPCHECK__)
    register long reg_x8 __asm__("x8") = number;
    register long reg_x0 __asm__("x0") = arg1;
    register long reg_x1 __asm__("x1") = arg2;
    register long reg_x2 __asm__("x2") = arg3;
    register long reg_x3 __asm__("x3") = arg4;
    register long reg_x4 __asm__("x4") = arg5;
    register long reg_x5 __asm__("x5") = arg6;

    __asm__ volatile("svc #0"
                     : "=r"(reg_x0)
                     : "r"(reg_x8), "r"(reg_x0), "r"(reg_x1), "r"(reg_x2), "r"(reg_x3),
                       "r"(reg_x4), "r"(reg_x5)
                     : "memory");

    if ((unsigned long)reg_x0 >= (unsigned long)-AGY_MAX_ERRNO_VALUE) {
        set_errno(-(int)reg_x0);
        return -1;
    }
    return reg_x0;
#else
    (void)arg1;
    (void)arg2;
    (void)arg3;
    (void)arg4;
    (void)arg5;
    (void)arg6;
    set_errno(ENOSYS);
    return -1;
#endif
}
