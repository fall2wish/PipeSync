#ifndef LIBRCLONE_H
#define LIBRCLONE_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
  #ifdef BUILDING_LIBRCLONE
    #define RCLONE_API __declspec(dllexport)
  #else
    #define RCLONE_API __declspec(dllimport)
  #endif
#else
  #if defined(__GNUC__) && __GNUC__ >= 4
    #define RCLONE_API __attribute__((visibility("default")))
  #else
    #define RCLONE_API
  #endif
#endif

struct RcloneRPCResultNative {
    char* output;
    int status;
};

RCLONE_API void RcloneInitialize(void);
RCLONE_API void RcloneFinalize(void);
RCLONE_API struct RcloneRPCResultNative RcloneRPC(char* method, char* input);
RCLONE_API void RcloneFreeString(char* str);

#ifdef __cplusplus
}
#endif

#endif // LIBRCLONE_H
