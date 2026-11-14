// SPDX-License-Identifier: GPL-3.0-only
#ifndef PERANT_WORKSPACE_IMPORT_H
#define PERANT_WORKSPACE_IMPORT_H

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static int perant_valid_import_name(const char *name) {
    if (!name || strlen(name) != 43 || strncmp(name, "web-", 4) || strcmp(name + 40, ".md"))
        return 0;
    for (size_t i = 4; i < 40; ++i) {
        if (i == 12 || i == 17 || i == 22 || i == 27) {
            if (name[i] != '-') return 0;
        } else if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

// Shared by the production JNI and the standalone Android native probe.
// Pin separate private staging and workspace roots. No guest descendant paths,
// overwrite fallback, or shell evaluation are part of this operation.
// PRoot remains a convenience runtime, not a strong same-UID security sandbox.
static int perant_publish_workspace_text(
    const char *directory, const char *staging_path, const char *name,
    const unsigned char *bytes, size_t size) {
    if (!directory || directory[0] != '/' || !staging_path || staging_path[0] != '/' ||
        !perant_valid_import_name(name) || size > 262144 || (size && (!bytes || memchr(bytes, 0, size))))
        return EINVAL;
    int failure = EINVAL;
    int root = -1, staging = -1, output = -1, created = 0;
    char temporary[80] = { 0 };
    snprintf(temporary, sizeof(temporary), ".perant-write-%s", name);
    do { root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); }
    while (root < 0 && errno == EINTR);
    if (root < 0) { failure = errno; goto cleanup; }
    do { staging = open(staging_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); }
    while (staging < 0 && errno == EINTR);
    if (staging < 0) { failure = errno; goto cleanup; }
    struct stat root_stat, staging_stat;
    if (fstat(root, &root_stat) < 0 || fstat(staging, &staging_stat) < 0) {
        failure = errno; goto cleanup;
    }
    if ((root_stat.st_dev == staging_stat.st_dev && root_stat.st_ino == staging_stat.st_ino) ||
        (staging_stat.st_mode & 077) != 0) { failure = EACCES; goto cleanup; }
    do { output = openat(staging, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600); }
    while (output < 0 && errno == EINTR);
    if (output < 0) { failure = errno; goto cleanup; }
    created = 1;
    size_t written = 0;
    while (written < (size_t)size) {
        ssize_t count = write(output, bytes + written, (size_t)size - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { failure = count < 0 ? errno : EIO; goto cleanup; }
        written += (size_t)count;
    }
    int result;
    do { result = fsync(output); } while (result < 0 && errno == EINTR);
    if (result < 0) { failure = errno; goto cleanup; }
    // Source remains in the unbound private staging directory. Do not put this
    // temporary name in /workspace, where ordinary guest operations can race.
    struct stat opened, named;
    if (fstat(output, &opened) < 0 || fstatat(staging, temporary, &named, AT_SYMLINK_NOFOLLOW) < 0) {
        failure = errno; goto cleanup;
    }
    if (!S_ISREG(named.st_mode) || opened.st_dev != named.st_dev || opened.st_ino != named.st_ino ||
        named.st_nlink != 1) { failure = ESTALE; goto cleanup; }
#ifdef __NR_renameat2
    do {
        result = (int)syscall(__NR_renameat2, staging, temporary, root, name, RENAME_NOREPLACE);
    } while (result < 0 && errno == EINTR);
    if (result < 0) { failure = errno; goto cleanup; }
    created = 0;
    // Publication already committed. A directory fsync failure must not report
    // an unsaved operation that callers might retry into a duplicate file.
    do { result = fsync(root); } while (result < 0 && errno == EINTR);
    failure = 0;
#else
    failure = ENOSYS;
#endif
cleanup:
    if (output >= 0) close(output);
    if (created && staging >= 0) unlinkat(staging, temporary, 0);
    if (staging >= 0) close(staging);
    if (root >= 0) close(root);
    return failure;
}

#endif
