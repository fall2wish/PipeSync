#ifndef PIPESYNC_QUICKJS_H
#define PIPESYNC_QUICKJS_H

#ifdef _WIN32
  #ifdef BUILDING_PIPESYNC_QJS
    #define QJS_API __declspec(dllexport)
  #else
    #define QJS_API __declspec(dllimport)
  #endif
#else
  #define QJS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char* output_json;
    int status; // 200: OK, 400: Eval error, 408: Timeout, 500: Fatal
} QuickJSExecutionResultNative;

QJS_API QuickJSExecutionResultNative QuickJS_RunPreHookNative(
    const char* script_source,
    const char* execution_context_json,
    int memory_limit_bytes,
    int timeout_ms
);

QJS_API void QuickJS_FreeNativeResult(QuickJSExecutionResultNative result);

#ifdef __cplusplus
}
#endif

#endif // PIPESYNC_QUICKJS_H
