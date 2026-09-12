#include "librclone.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static const char* get_temp_directory(void) {
    const char* t = getenv("TEMP");
    if (!t) t = getenv("TMP");
    if (!t) t = "/tmp";
    return t;
}

int main(void) {
    printf("[Native C Test] Initializing librclone...\n");
    RcloneInitialize();

    // 1. Test version RPC
    struct RcloneRPCResultNative ver = RcloneRPC("core/version", "{}");
    printf("[Native C Test] core/version output: %s, status: %d\n", ver.output, ver.status);
    assert(ver.status == 200);
    assert(strstr(ver.output, "v1.66.0-pipesync-embedded") != NULL);
    RcloneFreeString(ver.output);

    // 2. Prepare test file
    const char *tmp_dir = get_temp_directory();
    char src_file[1024];
    snprintf(src_file, sizeof(src_file), "%s/pipesync_test_source.txt", tmp_dir);

    FILE *f = fopen(src_file, "w");
    assert(f != NULL);
    fprintf(f, "Hello PipeSync Native Test!\n");
    fclose(f);

    // 3. Test copyfile
    char copy_json[2048];
    snprintf(copy_json, sizeof(copy_json),
        "{\"srcFs\":\"%s\",\"srcRemote\":\"pipesync_test_source.txt\",\"dstFs\":\"%s/backup\",\"dstRemote\":\"pipesync_test_dest.txt\"}",
        tmp_dir, tmp_dir);

    struct RcloneRPCResultNative copy = RcloneRPC("operations/copyfile", copy_json);
    printf("[Native C Test] operations/copyfile output: %s, status: %d\n", copy.output, copy.status);
    assert(copy.status == 200);
    RcloneFreeString(copy.output);

    // 4. Test hashsum
    char hash_json[2048];
    snprintf(hash_json, sizeof(hash_json),
        "{\"htype\":\"sha256\",\"fs\":\"%s/backup\",\"remote\":\"pipesync_test_dest.txt\"}",
        tmp_dir);

    struct RcloneRPCResultNative hash = RcloneRPC("operations/hashsum", hash_json);
    printf("[Native C Test] operations/hashsum output: %s, status: %d\n", hash.output, hash.status);
    assert(hash.status == 200);
    assert(strstr(hash.output, "hash") != NULL);
    RcloneFreeString(hash.output);

    // 5. Finalize
    RcloneFinalize();
    printf("[Native C Test] PASS! librclone shared library works as expected.\n");
    return 0;
}
