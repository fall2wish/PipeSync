#define BUILDING_PIPESYNC_QJS
#include "pipesync_quickjs.h"
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32
  #include <windows.h>
  #define strdup _strdup
#else
  #include <unistd.h>
#endif

/* --- Fast SHA-256 for JS Utils --- */
typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} SHA256_CTX_QJS;

#define ROTRIGHT(a,b) (((a) >> (b)) | ((a) << (32-(b))))
#define CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTRIGHT(x,2) ^ ROTRIGHT(x,13) ^ ROTRIGHT(x,22))
#define EP1(x) (ROTRIGHT(x,6) ^ ROTRIGHT(x,11) ^ ROTRIGHT(x,25))
#define SIG0(x) (ROTRIGHT(x,7) ^ ROTRIGHT(x,18) ^ ((x) >> 3))
#define SIG1(x) (ROTRIGHT(x,17) ^ ROTRIGHT(x,19) ^ ((x) >> 10))

static const uint32_t k256_table[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static void sha256_transform_qjs(SHA256_CTX_QJS *ctx, const uint8_t data[]) {
    uint32_t a, b, c, d, e, f, g, h, i, j, t1, t2, m[64];
    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | (data[j + 3]);
    for ( ; i < 64; ++i)
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];

    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];

    for (i = 0; i < 64; ++i) {
        t1 = h + EP1(e) + CH(e,f,g) + k256_table[i] + m[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init_qjs(SHA256_CTX_QJS *ctx) {
    ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static void sha256_update_qjs(SHA256_CTX_QJS *ctx, const uint8_t data[], size_t len) {
    size_t i;
    for (i = 0; i < len; ++i) {
        ctx->buffer[ctx->count % 64] = data[i];
        ctx->count++;
        if ((ctx->count % 64) == 0)
            sha256_transform_qjs(ctx, ctx->buffer);
    }
}

static void sha256_final_qjs(SHA256_CTX_QJS *ctx, uint8_t hash[]) {
    uint32_t i = ctx->count % 64;
    ctx->buffer[i++] = 0x80;
    if (i > 56) {
        while (i < 64) ctx->buffer[i++] = 0x00;
        sha256_transform_qjs(ctx, ctx->buffer);
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
    sha256_transform_qjs(ctx, ctx->buffer);

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

static void compute_string_sha256(const char* input, char hex_out[65]) {
    SHA256_CTX_QJS ctx;
    sha256_init_qjs(&ctx);
    sha256_update_qjs(&ctx, (const uint8_t*)input, strlen(input));
    uint8_t hash[32];
    sha256_final_qjs(&ctx, hash);
    for (int i = 0; i < 32; i++) {
        sprintf(hex_out + (i * 2), "%02x", hash[i]);
    }
    hex_out[64] = 0;
}

/* --- Timeout Interrupt State --- */
struct InterruptState {
    struct timespec start_time;
    int timeout_ms;
    int interrupted;
};

static int qjs_interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    struct InterruptState *is = (struct InterruptState *)opaque;
    if (!is || is->timeout_ms <= 0) return 0;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed_ms = (now.tv_sec - is->start_time.tv_sec) * 1000 +
                      (now.tv_nsec - is->start_time.tv_nsec) / 1000000;
    if (elapsed_ms >= is->timeout_ms) {
        is->interrupted = 1;
        return 1; // Abort JS execution
    }
    return 0;
}

/* --- JS Native Callbacks for PipeContext.utils --- */
static JSValue js_util_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    (void)ctx;
    (void)argc;
    (void)argv;
    return JS_UNDEFINED;
}

static JSValue js_util_warn(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    (void)ctx;
    (void)argc;
    (void)argv;
    return JS_UNDEFINED;
}

static JSValue js_util_sha256(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_NewString(ctx, "");
    const char *str = JS_ToCString(ctx, argv[0]);
    if (!str) return JS_NewString(ctx, "");
    char hex[65];
    compute_string_sha256(str, hex);
    JS_FreeCString(ctx, str);
    return JS_NewString(ctx, hex);
}

static JSValue js_util_format_date(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_NewString(ctx, "");
    int64_t ts_ms = 0;
    JS_ToInt64(ctx, &ts_ms, argv[0]);
    const char *pattern = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;

    time_t raw_sec = (time_t)(ts_ms / 1000);
    struct tm gm_time;
#ifdef _WIN32
    gmtime_s(&gm_time, &raw_sec);
#else
    gmtime_r(&raw_sec, &gm_time);
#endif

    char buf[64];
    if (pattern && strcmp(pattern, "yyyy-MM-dd") == 0) {
        snprintf(buf, sizeof(buf), "%04d-%02d-%02d",
                 gm_time.tm_year + 1900, gm_time.tm_mon + 1, gm_time.tm_mday);
    } else {
        snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
                 gm_time.tm_year + 1900, gm_time.tm_mon + 1, gm_time.tm_mday,
                 gm_time.tm_hour, gm_time.tm_min, gm_time.tm_sec);
    }
    if (pattern) JS_FreeCString(ctx, pattern);
    return JS_NewString(ctx, buf);
}

QJS_API QuickJSExecutionResultNative QuickJS_RunPreHookNative(
    const char* script_source,
    const char* execution_context_json,
    int memory_limit_bytes,
    int timeout_ms
) {
    QuickJSExecutionResultNative result;
    result.output_json = NULL;
    result.status = 500;

    if (!script_source || !execution_context_json) {
        result.output_json = strdup("{\"error\":\"Null arguments to QuickJS runner\"}");
        result.status = 400;
        return result;
    }

    JSRuntime *rt = JS_NewRuntime();
    if (!rt) {
        result.output_json = strdup("{\"error\":\"Failed to initialize QuickJS JSRuntime\"}");
        result.status = 500;
        return result;
    }

    // 1. Strict memory quota hard limit (e.g. 16 MB)
    size_t mem_limit = memory_limit_bytes > 0 ? (size_t)memory_limit_bytes : (16 * 1024 * 1024);
    JS_SetMemoryLimit(rt, mem_limit);

    // 2. Strict timeout interrupt handler
    struct InterruptState istate;
    clock_gettime(CLOCK_MONOTONIC, &istate.start_time);
    istate.timeout_ms = timeout_ms > 0 ? timeout_ms : 5000;
    istate.interrupted = 0;
    JS_SetInterruptHandler(rt, qjs_interrupt_handler, &istate);

    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        result.output_json = strdup("{\"error\":\"Failed to create QuickJS JSContext\"}");
        result.status = 500;
        return result;
    }

    // 3. Inject global PipeContext from JSON
    JSValue global_obj = JS_GetGlobalObject(ctx);
    JSValue context_val = JS_ParseJSON(ctx, execution_context_json, strlen(execution_context_json), "<context>");
    if (JS_IsException(context_val)) {
        JS_FreeValue(ctx, global_obj);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        result.output_json = strdup("{\"error\":\"Failed to parse PipeContext JSON into QuickJS context\"}");
        result.status = 400;
        return result;
    }

    // 4. Inject utils into PipeContext
    JSValue utils_obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, utils_obj, "log", JS_NewCFunction(ctx, js_util_log, "log", 1));
    JS_SetPropertyStr(ctx, utils_obj, "warn", JS_NewCFunction(ctx, js_util_warn, "warn", 1));
    JS_SetPropertyStr(ctx, utils_obj, "sha256", JS_NewCFunction(ctx, js_util_sha256, "sha256", 1));
    JS_SetPropertyStr(ctx, utils_obj, "formatDate", JS_NewCFunction(ctx, js_util_format_date, "formatDate", 2));
    JS_SetPropertyStr(ctx, context_val, "utils", utils_obj);

    JS_SetPropertyStr(ctx, global_obj, "PipeContext", context_val);
    JS_FreeValue(ctx, global_obj);

    // 5. Evaluate the user script / IIFE
    JSValue eval_ret = JS_Eval(ctx, script_source, strlen(script_source), "<prehook>", JS_EVAL_TYPE_GLOBAL);

    if (istate.interrupted) {
        JS_FreeValue(ctx, eval_ret);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        char err_msg[128];
        snprintf(err_msg, sizeof(err_msg), "{\"error\":\"Execution timeout exceeded %d ms\"}", istate.timeout_ms);
        result.output_json = strdup(err_msg);
        result.status = 408;
        return result;
    }

    if (JS_IsException(eval_ret)) {
        JSValue exception_val = JS_GetException(ctx);
        const char *err_str = JS_ToCString(ctx, exception_val);
        char buf[1024];
        snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", err_str ? err_str : "Unknown QuickJS exception");
        if (err_str) JS_FreeCString(ctx, err_str);
        JS_FreeValue(ctx, exception_val);
        JS_FreeValue(ctx, eval_ret);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        result.output_json = strdup(buf);
        result.status = 400;
        return result;
    }

    // 6. Check if result is an array
    int is_arr = JS_IsArray(ctx, eval_ret);
    if (!is_arr) {
        JS_FreeValue(ctx, eval_ret);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        result.output_json = strdup("{\"error\":\"PreHook script must return an array of {sourcePath, targetRelativePath}\"}");
        result.status = 400;
        return result;
    }

    // 7. Serialize returned array to JSON: {"success":true,"plan":[...]}
    JSValue json_stringify = JS_JSONStringify(ctx, eval_ret, JS_UNDEFINED, JS_UNDEFINED);
    const char *json_str = JS_ToCString(ctx, json_stringify);

    size_t out_len = strlen(json_str) + 64;
    char *final_out = (char*)malloc(out_len);
    snprintf(final_out, out_len, "{\"success\":true,\"plan\":%s}", json_str);

    JS_FreeCString(ctx, json_str);
    JS_FreeValue(ctx, json_stringify);
    JS_FreeValue(ctx, eval_ret);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);

    result.output_json = final_out;
    result.status = 200;
    return result;
}

QJS_API void QuickJS_FreeNativeResult(QuickJSExecutionResultNative result) {
    if (result.output_json) {
        free(result.output_json);
    }
}
