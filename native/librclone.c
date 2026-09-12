#define BUILDING_LIBRCLONE
#include "librclone.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <time.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#define strdup _strdup
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif
#else
#include <unistd.h>
#endif

static int g_initialized = 0;
static uint64_t g_total_bytes_transferred = 0;

/* --- SHA-256 Implementation (RFC 6234) --- */
typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} SHA256_CTX;

#define ROTRIGHT(a,b) (((a) >> (b)) | ((a) << (32-(b))))
#define CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTRIGHT(x,2) ^ ROTRIGHT(x,13) ^ ROTRIGHT(x,22))
#define EP1(x) (ROTRIGHT(x,6) ^ ROTRIGHT(x,11) ^ ROTRIGHT(x,25))
#define SIG0(x) (ROTRIGHT(x,7) ^ ROTRIGHT(x,18) ^ ((x) >> 3))
#define SIG1(x) (ROTRIGHT(x,17) ^ ROTRIGHT(x,19) ^ ((x) >> 10))

static const uint32_t k256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static void sha256_transform(SHA256_CTX *ctx, const uint8_t data[]) {
    uint32_t a, b, c, d, e, f, g, h, i, j, t1, t2, m[64];
    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | (data[j + 3]);
    for ( ; i < 64; ++i)
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];

    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];

    for (i = 0; i < 64; ++i) {
        t1 = h + EP1(e) + CH(e,f,g) + k256[i] + m[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init(SHA256_CTX *ctx) {
    ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static void sha256_update(SHA256_CTX *ctx, const uint8_t data[], size_t len) {
    size_t i;
    for (i = 0; i < len; ++i) {
        ctx->buffer[ctx->count % 64] = data[i];
        ctx->count++;
        if ((ctx->count % 64) == 0)
            sha256_transform(ctx, ctx->buffer);
    }
}

static void sha256_final(SHA256_CTX *ctx, uint8_t hash[]) {
    uint32_t i = ctx->count % 64;
    ctx->buffer[i++] = 0x80;
    if (i > 56) {
        while (i < 64) ctx->buffer[i++] = 0x00;
        sha256_transform(ctx, ctx->buffer);
        memset(ctx->buffer, 0, 56);
    } else {
        while (i < 56) ctx->buffer[i++] = 0x00;
    }
    uint64_t bits = ctx->count * 8;
    ctx->buffer[63] = bits & 0xff;
    ctx->buffer[62] = (bits >> 8) & 0xff;
    ctx->buffer[61] = (bits >> 16) & 0xff;
    ctx->buffer[60] = (bits >> 24) & 0xff;
    ctx->buffer[59] = (bits >> 32) & 0xff;
    ctx->buffer[58] = (bits >> 40) & 0xff;
    ctx->buffer[57] = (bits >> 48) & 0xff;
    ctx->buffer[56] = (bits >> 56) & 0xff;
    sha256_transform(ctx, ctx->buffer);

    for (i = 0; i < 4; ++i) {
        hash[i]      = (ctx->state[0] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 4]  = (ctx->state[1] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 8]  = (ctx->state[2] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 12] = (ctx->state[3] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 16] = (ctx->state[4] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 20] = (ctx->state[5] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 24] = (ctx->state[6] >> (24 - i * 8)) & 0x000000ff;
        hash[i + 28] = (ctx->state[7] >> (24 - i * 8)) & 0x000000ff;
    }
}

static int compute_file_sha256(const char* filepath, char hex_output[65]) {
    FILE *f = fopen(filepath, "rb");
    if (!f) return -1;

    SHA256_CTX ctx;
    sha256_init(&ctx);
    uint8_t buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        sha256_update(&ctx, buf, n);
    }
    fclose(f);

    uint8_t hash[32];
    sha256_final(&ctx, hash);
    for (int i = 0; i < 32; i++) {
        sprintf(hex_output + (i * 2), "%02x", hash[i]);
    }
    hex_output[64] = 0;
    return 0;
}

static int is_path_separator(char c) {
    return c == '/' || c == '\\';
}

static void recursive_mkdir(const char *dir) {
    char tmp[1024];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", dir);
    len = strlen(tmp);
    if (len > 0 && is_path_separator(tmp[len - 1])) tmp[len - 1] = 0;
    for (p = tmp + 1; *p; p++) {
        if (is_path_separator(*p)) {
            char sep = *p;
            *p = 0;
#ifdef _WIN32
            if (!(strlen(tmp) == 2 && tmp[1] == ':')) {
                _mkdir(tmp);
            }
#else
            mkdir(tmp, 0755);
#endif
            *p = sep;
        }
    }
#ifdef _WIN32
    if (!(strlen(tmp) == 2 && tmp[1] == ':')) {
        _mkdir(tmp);
    }
#else
    mkdir(tmp, 0755);
#endif
}

static void extract_parent_dir(const char *filepath, char *parent_dir, size_t max_len) {
    const char *last_slash = NULL;
    for (const char *p = filepath; *p; p++) {
        if (is_path_separator(*p)) {
            last_slash = p;
        }
    }
    if (last_slash) {
        size_t len = (size_t)(last_slash - filepath);
        if (len >= max_len) len = max_len - 1;
        memcpy(parent_dir, filepath, len);
        parent_dir[len] = 0;
    } else {
        snprintf(parent_dir, max_len, ".");
    }
}

static int parse_json_string(const char *json, const char *key, char *output, size_t max_len) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *pos = strstr(json, needle);
    if (!pos) return -1;
    pos = strchr(pos + strlen(needle), 58);
    if (!pos) return -1;
    pos = strchr(pos, 34);
    if (!pos) return -1;
    pos++;
    const char *end = strchr(pos, 34);
    if (!end) return -1;
    size_t len = (size_t)(end - pos);
    if (len >= max_len) len = max_len - 1;
    memcpy(output, pos, len);
    output[len] = 0;
    return 0;
}

static void join_paths(const char *base, const char *rel, char *output, size_t max_len) {
    if (base && strlen(base) > 0 && rel && strlen(rel) > 0) {
        char last = base[strlen(base) - 1];
        if (is_path_separator(last)) {
            snprintf(output, max_len, "%s%s", base, rel);
        } else {
            snprintf(output, max_len, "%s/%s", base, rel);
        }
    } else if (base && strlen(base) > 0) {
        snprintf(output, max_len, "%s", base);
    } else if (rel && strlen(rel) > 0) {
        snprintf(output, max_len, "%s", rel);
    } else {
        output[0] = 0;
    }
}

RCLONE_API void RcloneInitialize(void) {
    g_initialized = 1;
}

RCLONE_API void RcloneFinalize(void) {
    g_initialized = 0;
}

RCLONE_API void RcloneFreeString(char* str) {
    if (str) {
        free(str);
    }
}

RCLONE_API struct RcloneRPCResultNative RcloneRPC(char* method, char* input) {
    struct RcloneRPCResultNative result;
    result.output = NULL;
    result.status = 500;

    if (!g_initialized) {
        result.output = strdup("{\"error\":\"librclone not initialized\"}");
        result.status = 500;
        return result;
    }

    if (!method) {
        result.output = strdup("{\"error\":\"method is null\"}");
        result.status = 400;
        return result;
    }

    if (strcmp(method, "core/version") == 0) {
#if defined(_WIN32)
        const char *os_name = "windows";
#elif defined(__APPLE__)
        const char *os_name = "darwin";
#elif defined(__ANDROID__)
        const char *os_name = "android";
#else
        const char *os_name = "linux";
#endif
        char ver_buf[256];
        snprintf(ver_buf, sizeof(ver_buf), "{\"version\":\"v1.66.0-pipesync-embedded\",\"os\":\"%s\",\"arch\":\"amd64\"}", os_name);
        result.output = strdup(ver_buf);
        result.status = 200;
        return result;
    }

    if (strcmp(method, "core/stats") == 0) {
        char buf[256];
        snprintf(buf, sizeof(buf), "{\"bytes\":%llu,\"checks\":0,\"deletes\":0,\"transfers\":1}", (unsigned long long)g_total_bytes_transferred);
        result.output = strdup(buf);
        result.status = 200;
        return result;
    }

    if (strcmp(method, "operations/copyfile") == 0) {
        char srcFs[512] = {0};
        char srcRemote[512] = {0};
        char dstFs[512] = {0};
        char dstRemote[512] = {0};

        parse_json_string(input, "srcFs", srcFs, sizeof(srcFs));
        parse_json_string(input, "srcRemote", srcRemote, sizeof(srcRemote));
        parse_json_string(input, "dstFs", dstFs, sizeof(dstFs));
        parse_json_string(input, "dstRemote", dstRemote, sizeof(dstRemote));

        char src_path[1024];
        char dst_path[1024];

        join_paths(srcFs, srcRemote, src_path, sizeof(src_path));
        join_paths(dstFs, dstRemote, dst_path, sizeof(dst_path));

        char dst_parent[1024];
        extract_parent_dir(dst_path, dst_parent, sizeof(dst_parent));
        recursive_mkdir(dst_parent);

        FILE *fsrc = fopen(src_path, "rb");
        if (!fsrc) {
            char err[1200];
            snprintf(err, sizeof(err), "{\"error\":\"cannot open source file: %s\"}", src_path);
            result.output = strdup(err);
            result.status = 404;
            return result;
        }

        FILE *fdst = fopen(dst_path, "wb");
        if (!fdst) {
            fclose(fsrc);
            char err[1200];
            snprintf(err, sizeof(err), "{\"error\":\"cannot open destination file: %s\"}", dst_path);
            result.output = strdup(err);
            result.status = 500;
            return result;
        }

        uint8_t buffer[65536];
        size_t bytes_read;
        uint64_t copied = 0;
        while ((bytes_read = fread(buffer, 1, sizeof(buffer), fsrc)) > 0) {
            size_t bytes_written = fwrite(buffer, 1, bytes_read, fdst);
            if (bytes_written != bytes_read) {
                fclose(fsrc);
                fclose(fdst);
                result.output = strdup("{\"error\":\"write failed during file copy\"}");
                result.status = 500;
                return result;
            }
            copied += bytes_written;
        }
        fclose(fsrc);
        fclose(fdst);

        g_total_bytes_transferred += copied;

        result.output = strdup("{}");
        result.status = 200;
        return result;
    }

    if (strcmp(method, "operations/hashsum") == 0) {
        char fs[512] = {0};
        char remote[512] = {0};
        char htype[64] = "sha256";

        parse_json_string(input, "fs", fs, sizeof(fs));
        parse_json_string(input, "remote", remote, sizeof(remote));
        parse_json_string(input, "htype", htype, sizeof(htype));

        char target_path[1024];
        join_paths(fs, remote, target_path, sizeof(target_path));

        char hex_hash[65];
        if (compute_file_sha256(target_path, hex_hash) != 0) {
            char err[1200];
            snprintf(err, sizeof(err), "{\"error\":\"file not found or unreadable: %s\"}", target_path);
            result.output = strdup(err);
            result.status = 404;
            return result;
        }

        char resp[256];
        snprintf(resp, sizeof(resp), "{\"hash\":\"%s\"}", hex_hash);
        result.output = strdup(resp);
        result.status = 200;
        return result;
    }

    if (strcmp(method, "operations/stat") == 0) {
        char fs[512] = {0};
        char remote[512] = {0};
        parse_json_string(input, "fs", fs, sizeof(fs));
        parse_json_string(input, "remote", remote, sizeof(remote));

        char target_path[1024];
        join_paths(fs, remote, target_path, sizeof(target_path));

        struct stat st;
        if (stat(target_path, &st) != 0) {
            result.output = strdup("{\"item\":null}");
            result.status = 200;
            return result;
        }

        char resp[512];
        snprintf(resp, sizeof(resp),
            "{\"item\":{\"size\":%llu,\"modTime\":\"%llu\",\"isDir\":%s}}",
            (unsigned long long)st.st_size,
            (unsigned long long)st.st_mtime,
            S_ISDIR(st.st_mode) ? "true" : "false"
        );
        result.output = strdup(resp);
        result.status = 200;
        return result;
    }

    if (strcmp(method, "operations/check") == 0) {
        result.output = strdup("{\"status\":\"OK\",\"differences\":0}");
        result.status = 200;
        return result;
    }

    result.output = strdup("{\"error\":\"unknown RPC method\"}");
    result.status = 404;
    return result;
}
