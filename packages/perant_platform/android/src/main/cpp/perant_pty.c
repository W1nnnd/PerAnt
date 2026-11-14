// SPDX-License-Identifier: GPL-3.0-only
// POSIX PTY transport for PerAnt. The child receives only its explicit argv/env
// and stdio; no Java/Flutter/database descriptors are kept across exec.
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "workspace_import.h"

static void io_error(JNIEnv *env, const char *message) {
    jclass type = (*env)->FindClass(env, "java/io/IOException");
    if (type) (*env)->ThrowNew(env, type, message);
}

// GetStringUTFChars uses modified UTF-8, which corrupts supplementary Unicode.
// Perform Java's standard UTF-8 conversion before forking the multithreaded VM.
static char *utf8(JNIEnv *env, jstring value) {
    if (!value) return NULL;
    jclass string_type = (*env)->FindClass(env, "java/lang/String");
    jmethodID get_bytes = (*env)->GetMethodID(env, string_type, "getBytes", "(Ljava/lang/String;)[B");
    jstring encoding = (*env)->NewStringUTF(env, "UTF-8");
    jbyteArray bytes = (jbyteArray)(*env)->CallObjectMethod(env, value, get_bytes, encoding);
    (*env)->DeleteLocalRef(env, encoding);
    (*env)->DeleteLocalRef(env, string_type);
    if (!bytes || (*env)->ExceptionCheck(env)) return NULL;
    jsize size = (*env)->GetArrayLength(env, bytes);
    char *copy = calloc((size_t)size + 1U, 1U);
    if (copy) (*env)->GetByteArrayRegion(env, bytes, 0, size, (jbyte *)copy);
    (*env)->DeleteLocalRef(env, bytes);
    if (copy && memchr(copy, 0, (size_t)size)) { free(copy); return NULL; }
    return copy;
}

static void free_vector(char **vector) {
    if (!vector) return;
    for (size_t i = 0; vector[i]; ++i) free(vector[i]);
    free(vector);
}

static char **strings(JNIEnv *env, jobjectArray array) {
    if (!array) return NULL;
    jsize count = (*env)->GetArrayLength(env, array);
    char **result = calloc((size_t)count + 1U, sizeof(char *));
    if (!result) return NULL;
    for (jsize i = 0; i < count; ++i) {
        jstring value = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        result[i] = utf8(env, value);
        (*env)->DeleteLocalRef(env, value);
        if (!result[i]) { free_vector(result); return NULL; }
    }
    return result;
}

static void close_inherited(void) {
    // Do not require newer syscalls in the Android API 29 seccomp allowlist.
    struct rlimit limit;
    rlim_t end = 65536;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY)
        end = limit.rlim_cur;
    for (rlim_t fd = 3; fd < end; ++fd) syscall(__NR_close, (int)fd);
}

JNIEXPORT jintArray JNICALL Java_dev_perant_platform_NativePty_spawn(
    JNIEnv *env, jclass klass, jobjectArray arguments, jobjectArray environment,
    jstring working_directory, jint columns, jint rows) {
    char **argv = strings(env, arguments);
    char **envp = strings(env, environment);
    char *cwd = utf8(env, working_directory);
    if (!argv || !argv[0] || !envp || !cwd) {
        free_vector(argv); free_vector(envp); free(cwd);
        if (!(*env)->ExceptionCheck(env)) io_error(env, "Invalid PTY spawn arguments.");
        return NULL;
    }
    struct termios tio;
    memset(&tio, 0, sizeof(tio));
    tio.c_iflag = ICRNL | IXON | IUTF8;
    tio.c_oflag = OPOST | ONLCR;
    tio.c_cflag = CREAD | CS8 | HUPCL;
    tio.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
    cfsetispeed(&tio, B38400); cfsetospeed(&tio, B38400);
    tio.c_cc[VINTR] = 3; tio.c_cc[VQUIT] = 28; tio.c_cc[VERASE] = 127;
    tio.c_cc[VKILL] = 21; tio.c_cc[VEOF] = 4; tio.c_cc[VSTART] = 17;
    tio.c_cc[VSTOP] = 19; tio.c_cc[VSUSP] = 26; tio.c_cc[VMIN] = 1;
    struct winsize size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns };
    int master = -1;
    pid_t parent = getpid();
    pid_t pid = forkpty(&master, NULL, &tio, &size);
    int saved_errno = errno;
    if (pid == 0) {
        // Only async-signal-safe operations after fork; no JNI, logging or malloc.
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (getppid() != parent) _exit(127);
        sigset_t empty;
        sigemptyset(&empty); sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction action;
        memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int s = 1; s < NSIG; ++s) sigaction(s, &action, NULL);
        close_inherited();
        if (chdir(cwd) == 0) execve(argv[0], argv, envp);
        const char message[] = "PerAnt: native exec failed.\r\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }
    free_vector(argv); free_vector(envp); free(cwd);
    if (pid < 0) { errno = saved_errno; io_error(env, "Unable to create PTY process."); return NULL; }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    jint values[2] = { master, pid };
    jintArray result = (*env)->NewIntArray(env, 2);
    if (result) (*env)->SetIntArrayRegion(env, result, 0, 2, values);
    else { kill(-pid, SIGKILL); close(master); waitpid(pid, NULL, 0); }
    return result;
}

// null = poll timeout, empty = EOF. The caller owns closing, after reader exit.
JNIEXPORT jbyteArray JNICALL Java_dev_perant_platform_NativePty_read(
    JNIEnv *env, jclass klass, jint fd, jint maximum) {
    struct pollfd descriptor = { .fd = fd, .events = POLLIN };
    int ready;
    do { ready = poll(&descriptor, 1, 100); } while (ready < 0 && errno == EINTR);
    if (ready == 0) return NULL;
    if (ready < 0) { io_error(env, "PTY poll failed."); return NULL; }
    if (maximum < 1 || maximum > 8192) { io_error(env, "Invalid PTY buffer size."); return NULL; }
    char buffer[8192];
    ssize_t count;
    do { count = read(fd, buffer, (size_t)maximum); } while (count < 0 && errno == EINTR);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return NULL;
    if (count < 0 && errno == EIO) count = 0; // Linux PTY hangup.
    if (count < 0) { io_error(env, "PTY read failed."); return NULL; }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)count);
    if (result && count) (*env)->SetByteArrayRegion(env, result, 0, (jsize)count, (const jbyte *)buffer);
    return result;
}

static int64_t milliseconds(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

JNIEXPORT void JNICALL Java_dev_perant_platform_NativePty_write(
    JNIEnv *env, jclass klass, jint fd, jbyteArray data) {
    jsize length = (*env)->GetArrayLength(env, data);
    if (length > 65536) { io_error(env, "PTY input exceeds the limit."); return; }
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (!bytes) return;
    jsize offset = 0;
    int64_t deadline = milliseconds() + 3000;
    while (offset < length && milliseconds() < deadline) {
        struct pollfd descriptor = { .fd = fd, .events = POLLOUT };
        int ready = poll(&descriptor, 1, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) { if (ready < 0) break; else continue; }
        ssize_t count = write(fd, bytes + offset, (size_t)(length - offset));
        if (count > 0) offset += (jsize)count;
        else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) break;
    }
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    if (offset != length) io_error(env, "PTY input was not fully written; retrying may duplicate input.");
}

JNIEXPORT void JNICALL Java_dev_perant_platform_NativePty_resize(
    JNIEnv *env, jclass klass, jint fd, jint columns, jint rows) {
    struct winsize size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns };
    if (ioctl(fd, TIOCSWINSZ, &size) < 0) io_error(env, "PTY resize failed.");
}

JNIEXPORT jint JNICALL Java_dev_perant_platform_NativePty_waitFor(
    JNIEnv *env, jclass klass, jint pid) {
    int status; pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return 125;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}

JNIEXPORT void JNICALL Java_dev_perant_platform_NativePty_signal(
    JNIEnv *env, jclass klass, jint pid, jint signal_number, jboolean group) {
    if (pid > 0) kill(group ? -pid : pid, signal_number);
}

JNIEXPORT void JNICALL Java_dev_perant_platform_NativePty_close(
    JNIEnv *env, jclass klass, jint fd) {
    if (fd >= 0) close(fd);
}

JNIEXPORT jint JNICALL Java_dev_perant_platform_NativePty_duplicate(
    JNIEnv *env, jclass klass, jint fd) {
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (copy < 0) io_error(env, "PTY descriptor is no longer available.");
    return copy;
}

// Complete file publication without an overwrite window. In particular, do
// not emulate this with access()+rename() or link(), which Android may deny.
JNIEXPORT jint JNICALL Java_dev_perant_platform_NativePty_renameNoReplace(
    JNIEnv *env, jclass klass, jstring source, jstring destination) {
    char *from = utf8(env, source);
    char *to = utf8(env, destination);
    if (!from || !to) {
        free(from); free(to);
        if (!(*env)->ExceptionCheck(env)) io_error(env, "Invalid file publication paths.");
        return EINVAL;
    }
#ifdef __NR_renameat2
    int result;
    do {
        result = (int)syscall(__NR_renameat2, AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE);
    } while (result < 0 && errno == EINTR);
    int failure = result == 0 ? 0 : errno;
#else
    int failure = ENOSYS;
#endif
    free(from); free(to);
    return failure;
}

// Only the generated root-level create operation may coexist with a ready
// desktop. Staging is app-private and is not bound into the guest workspace.
JNIEXPORT jint JNICALL Java_dev_perant_platform_NativePty_publishWorkspaceText(
    JNIEnv *env, jclass klass, jstring workspace, jstring staging_directory,
    jstring filename, jbyteArray content) {
    char *directory = utf8(env, workspace);
    char *staging_path = utf8(env, staging_directory);
    char *name = utf8(env, filename);
    jsize size = content ? (*env)->GetArrayLength(env, content) : -1;
    unsigned char *bytes = NULL;
    int failure = EINVAL;
    if (!directory || !staging_path || !name || size < 0 || size > 262144 ||
        (*env)->ExceptionCheck(env)) goto cleanup;
    bytes = malloc((size_t)size + 1U);
    if (!bytes) { failure = ENOMEM; goto cleanup; }
    (*env)->GetByteArrayRegion(env, content, 0, size, (jbyte *)bytes);
    if (!(*env)->ExceptionCheck(env))
        failure = perant_publish_workspace_text(directory, staging_path, name, bytes, (size_t)size);
cleanup:
    free(directory); free(staging_path); free(name); free(bytes);
    return failure;
}
