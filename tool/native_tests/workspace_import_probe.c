// SPDX-License-Identifier: GPL-3.0-only
// Standalone Android probe for the exact core called by production JNI.
// All fixtures are below one new /data/local/tmp directory, never app data.
#define _XOPEN_SOURCE 700
#include <dirent.h>
#include <ftw.h>
#include <stdlib.h>
#include "../../packages/perant_platform/android/src/main/cpp/workspace_import.h"

static int write_new(const char *path, const char *value) {
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    size_t size = strlen(value);
    int ok = write(fd, value, size) == (ssize_t)size;
    close(fd);
    return ok;
}

static int equals_file(const char *path, const char *value) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    size_t size = strlen(value);
    char *bytes = malloc(size + 1U);
    ssize_t count = bytes ? read(fd, bytes, size + 1U) : -1;
    int ok = count == (ssize_t)size && memcmp(bytes, value, size) == 0;
    free(bytes); close(fd);
    return ok;
}

static int empty_directory(const char *path) {
    DIR *directory = opendir(path);
    if (!directory) return 0;
    struct dirent *entry;
    int empty = 1;
    while ((entry = readdir(directory))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) { empty = 0; break; }
    }
    closedir(directory);
    return empty;
}

static int remove_fixture(const char *path, const struct stat *metadata, int kind, struct FTW *state) {
    (void)metadata; (void)kind; (void)state;
    return remove(path);
}

int main(void) {
    char owned[] = "/data/local/tmp/perant-import-probe-XXXXXX";
    if (!mkdtemp(owned)) {
        printf("{\"suite\":\"android-native-workspace-import\",\"setupFailed\":true}\n");
        return 1;
    }
    char workspace[256], staging[256], outside[256], target[384], temporary[384];
    char marker[384], root_alias[256], staging_alias[256];
    snprintf(workspace, sizeof(workspace), "%s/workspace", owned);
    snprintf(staging, sizeof(staging), "%s/import-staging", owned);
    snprintf(outside, sizeof(outside), "%s/outside", owned);
    snprintf(marker, sizeof(marker), "%s/marker.txt", outside);
    snprintf(root_alias, sizeof(root_alias), "%s/workspace-alias", owned);
    snprintf(staging_alias, sizeof(staging_alias), "%s/staging-alias", owned);
    int ready = mkdir(workspace, 0700) == 0 && mkdir(staging, 0700) == 0 &&
        mkdir(outside, 0700) == 0 && write_new(marker, "OUTSIDE");
    const char *names[] = {
        "web-12345678-1234-1234-1234-123456789ab1.md",
        "web-12345678-1234-1234-1234-123456789ab2.md",
        "web-12345678-1234-1234-1234-123456789ab3.md",
        "web-12345678-1234-1234-1234-123456789ab4.md",
        "web-12345678-1234-1234-1234-123456789ab5.md",
        "web-12345678-1234-1234-1234-123456789ab6.md"
    };
    const char *labels[] = {
        "unicode-success-and-private-staging-cleaned",
        "existing-file-not-overwritten-and-failed-temp-cleaned",
        "existing-symlink-and-outside-target-preserved",
        "preexisting-staging-temp-not-deleted",
        "failed-directory-publication-cleaned",
        "root-and-staging-aliases-rejected"
    };
    int checks[6] = { 0 };
    const char *content = "# Native 中文 🐜\n\nLiteral $(touch never); <script>text</script>\n";
    size_t size = strlen(content);
    if (ready) {
        snprintf(target, sizeof(target), "%s/%s", workspace, names[0]);
        checks[0] = perant_publish_workspace_text(workspace, staging, names[0],
            (const unsigned char *)content, size) == 0 && equals_file(target, content) && empty_directory(staging);

        snprintf(target, sizeof(target), "%s/%s", workspace, names[1]);
        checks[1] = write_new(target, "KEEP") && perant_publish_workspace_text(workspace, staging, names[1],
            (const unsigned char *)content, size) == EEXIST && equals_file(target, "KEEP") && empty_directory(staging);

        snprintf(target, sizeof(target), "%s/%s", workspace, names[2]);
        struct stat alias;
        checks[2] = symlink(marker, target) == 0 && perant_publish_workspace_text(workspace, staging, names[2],
            (const unsigned char *)content, size) == EEXIST && lstat(target, &alias) == 0 &&
            S_ISLNK(alias.st_mode) && equals_file(marker, "OUTSIDE") && empty_directory(staging);

        snprintf(temporary, sizeof(temporary), "%s/.perant-write-%s", staging, names[3]);
        snprintf(target, sizeof(target), "%s/%s", workspace, names[3]);
        checks[3] = write_new(temporary, "ANOTHER-OPERATION") &&
            perant_publish_workspace_text(workspace, staging, names[3], (const unsigned char *)content, size) == EEXIST &&
            equals_file(temporary, "ANOTHER-OPERATION") && lstat(target, &alias) != 0 && errno == ENOENT;
        unlink(temporary);

        snprintf(target, sizeof(target), "%s/%s", workspace, names[4]);
        checks[4] = mkdir(target, 0700) == 0 && perant_publish_workspace_text(workspace, staging, names[4],
            (const unsigned char *)content, size) != 0 && empty_directory(staging) &&
            lstat(target, &alias) == 0 && S_ISDIR(alias.st_mode);

        int same = perant_publish_workspace_text(workspace, workspace, names[5], (const unsigned char *)content, size);
        int aliases_created = symlink(workspace, root_alias) == 0 && symlink(staging, staging_alias) == 0;
        int root_result = perant_publish_workspace_text(root_alias, staging, names[5], (const unsigned char *)content, size);
        int stage_result = perant_publish_workspace_text(workspace, staging_alias, names[5], (const unsigned char *)content, size);
        snprintf(target, sizeof(target), "%s/%s", workspace, names[5]);
        checks[5] = same == EACCES && aliases_created && root_result != 0 && stage_result != 0 &&
            lstat(target, &alias) != 0 && errno == ENOENT && empty_directory(staging) && equals_file(marker, "OUTSIDE");
    }
    int passed = 0;
    for (int i = 0; i < 6; ++i) passed += checks[i];
    int removed = nftw(owned, remove_fixture, 16, FTW_DEPTH | FTW_PHYS) == 0;
    printf("{\"suite\":\"android-native-workspace-import\",\"passed\":%d,\"failed\":%d,\"checks\":[", passed, 6 - passed);
    for (int i = 0; i < 6; ++i)
        printf("%s{\"check\":\"%s\",\"passed\":%s}", i ? "," : "", labels[i], checks[i] ? "true" : "false");
    printf("],\"testDirectoryRemoved\":%s,\"appDataAccessed\":false}\n", removed ? "true" : "false");
    return passed == 6 && removed ? 0 : 1;
}
