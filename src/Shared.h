#ifndef XIAOAIKEY_SHARED_H
#define XIAOAIKEY_SHARED_H
#define XIAOAIKEY_MAGIC 0x58414B31u
typedef struct {
    DWORD magic, targetPid, controllerPid, reserved;
    FILETIME controllerCreated;
    volatile LONG enabled, status, suppressed;
} SharedState;
static void MappingName(wchar_t *name, size_t size, DWORD pid) {
    swprintf(name,size,L"Local\\XiaoAiKey.Process.%lu",pid);
}
#endif
