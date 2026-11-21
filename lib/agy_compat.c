// NOLINTNEXTLINE(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp)
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef ENOSYS
#define ENOSYS 38
#endif

#define AGY_SECCOMP_BLOCKED_SYSCALL_1 788533211L
#define AGY_SECCOMP_BLOCKED_SYSCALL_2 0x2f000fdbL
#define AGY_SYS_FACCESSAT2 439L
#define AGY_MAX_LINUX_ARM64_SYSCALL 500L
#define AGY_MAX_ERRNO_VALUE 4095UL

enum AgyWatchdogConfig {
  AGY_WATCHDOG_STACK_SIZE = 65536U,
  AGY_WATCHDOG_INITIAL_DELAY_US = 100000U,
  AGY_WATCHDOG_CHECK_INTERVAL_SEC = 2U
};

// NOLINTNEXTLINE(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp)
extern int *__errno_location(void);

static inline void set_errno(int err) {
  int *loc = __errno_location();
  if (loc != NULL) {
    *loc = err;
  }
}

static void agy_sigsys_handler(int sig, siginfo_t *si, void *ucontext_ptr) {
  if (si != NULL && si->si_code == 1 /* SYS_SECCOMP */) {
#ifdef __aarch64__
    ucontext_t *ctx = (ucontext_t *)ucontext_ptr;
    if (ctx != NULL) {
      ctx->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
      return;
    }
#endif
  }
  _exit(128 + sig);
}

static void install_sigsys_handler(void) {
  struct sigaction sa;
  sigemptyset(&sa.sa_mask);
  sa.sa_sigaction = agy_sigsys_handler;
  sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_ONSTACK;
  sigaction(SIGSYS, &sa, NULL);
}

static void *sigsys_watchdog_thread(void *arg) {
  (void)arg;
  usleep(AGY_WATCHDOG_INITIAL_DELAY_US);
  install_sigsys_handler();

  while (1) {
    sleep(AGY_WATCHDOG_CHECK_INTERVAL_SEC);
    struct sigaction current_sa;
    sigemptyset(&current_sa.sa_mask);
    if (sigaction(SIGSYS, NULL, &current_sa) == 0) {
      if (current_sa.sa_sigaction != agy_sigsys_handler) {
        install_sigsys_handler();
      }
    }
  }
  return NULL;
}

__attribute__((constructor)) static void agy_compat_init(void) {
  install_sigsys_handler();

  pthread_t th = 0;
  pthread_attr_t attr;
  if (pthread_attr_init(&attr) == 0) {
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, (size_t)AGY_WATCHDOG_STACK_SIZE);
    pthread_create(&th, &attr, sigsys_watchdog_thread, NULL);
    pthread_attr_destroy(&attr);
  }
}

long syscall(long number, ...) {
  if (number == AGY_SECCOMP_BLOCKED_SYSCALL_1 ||
      number == AGY_SECCOMP_BLOCKED_SYSCALL_2 || number == AGY_SYS_FACCESSAT2 ||
      number < 0 || number >= AGY_MAX_LINUX_ARM64_SYSCALL) {
    set_errno(ENOSYS);
    return -1;
  }

  va_list args;
  va_start(args, number);
  long a1 = va_arg(args, long);
  long a2 = va_arg(args, long);
  long a3 = va_arg(args, long);
  long a4 = va_arg(args, long);
  long a5 = va_arg(args, long);
  long a6 = va_arg(args, long);
  va_end(args);

#ifdef __aarch64__
  long ret = a1;
  long num = number;
  __asm__ volatile(
      "mov x8, %[num]\n"
      "mov x0, %[arg1]\n"
      "mov x1, %[arg2]\n"
      "mov x2, %[arg3]\n"
      "mov x3, %[arg4]\n"
      "mov x4, %[arg5]\n"
      "mov x5, %[arg6]\n"
      "svc #0\n"
      "mov %[ret], x0\n"
      : [ret] "=r"(ret)
      : [num] "r"(num), [arg1] "r"(a1), [arg2] "r"(a2), [arg3] "r"(a3),
        [arg4] "r"(a4), [arg5] "r"(a5), [arg6] "r"(a6)
      : "x0", "x1", "x2", "x3", "x4", "x5", "x8", "memory");

  if ((unsigned long)ret >= (unsigned long)-AGY_MAX_ERRNO_VALUE) {
    set_errno(-(int)ret);
    return -1;
  }
  return ret;
#else
  (void)a1;
  (void)a2;
  (void)a3;
  (void)a4;
  (void)a5;
  (void)a6;
  set_errno(ENOSYS);
  return -1;
#endif
}
