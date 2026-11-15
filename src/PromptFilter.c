#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>
#include <string.h>
#include "Shared.h"
typedef int (WINAPI *MessageBoxFn)(HWND,LPCWSTR,LPCWSTR,UINT);
static MessageBoxFn original;
static SharedState *shared;
static HANDLE mapping;
static volatile LONG installing;
static BOOL IsTargetProcess(void) {
    wchar_t path[32768];
    if(!GetModuleFileNameW(NULL,path,32768))return FALSE;
    const wchar_t *name=wcsrchr(path,L'\\');
    return name && _wcsicmp(name+1,L"OSDUtility.exe")==0;
}
static BOOL ControllerAlive(void) {
    if(!shared || !shared->enabled)return FALSE;
    HANDLE p=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,shared->controllerPid);
    if(!p)return FALSE;
    FILETIME created,exited,kernel,user;
    BOOL active=WaitForSingleObject(p,0)==WAIT_TIMEOUT &&
        GetProcessTimes(p,&created,&exited,&kernel,&user) &&
        CompareFileTime(&created,&shared->controllerCreated)==0;
    CloseHandle(p);return active;
}
static int WINAPI FilterMessageBox(HWND owner,LPCWSTR text,LPCWSTR title,UINT type) {
    /* Only the missing-XiaoAi download prompt is cancelled. */
    if(title && text && !IS_INTRESOURCE(title) && !IS_INTRESOURCE(text) &&
       wcscmp(title,L"\x5c0f\x7231\x540c\x5b66")==0 &&
       wcsstr(text,L"\x672a\x68c0\x6d4b\x5230\x5c0f\x7231\x540c\x5b66") && ControllerAlive()) {
        InterlockedIncrement(&shared->suppressed);
        return (type & MB_TYPEMASK)==MB_YESNO ? IDNO : IDCANCEL;
    }
    return original(owner,text,title,type);
}
static void Install(void) {
    if(InterlockedCompareExchange(&installing,1,0))return;
    if(!IsTargetProcess())goto done;
    if(!shared){
        wchar_t name[128];MappingName(name,128,GetCurrentProcessId());
        mapping=OpenFileMappingW(FILE_MAP_READ|FILE_MAP_WRITE,FALSE,name);
        if(!mapping)goto done;
        shared=(SharedState *)MapViewOfFile(mapping,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(SharedState));
        if(!shared){CloseHandle(mapping);mapping=NULL;goto done;}
    }
    if(shared->magic!=XIAOAIKEY_MAGIC || shared->targetPid!=GetCurrentProcessId() || !ControllerAlive())goto done;
    if(original){InterlockedExchange(&shared->status,1);goto done;}
    BYTE *base=(BYTE *)GetModuleHandleW(NULL);
    IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER *)base;
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<=0)goto failed;
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64 *)(base+dos->e_lfanew);
    if(nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC)goto failed;
    DWORD imageSize=nt->OptionalHeader.SizeOfImage;
    IMAGE_DATA_DIRECTORY dir=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if(!dir.VirtualAddress || dir.VirtualAddress>=imageSize || dir.Size>imageSize-dir.VirtualAddress)goto failed;
    IMAGE_IMPORT_DESCRIPTOR *desc=(IMAGE_IMPORT_DESCRIPTOR *)(base+dir.VirtualAddress);
    for(size_t d=0;(d+1)*sizeof(*desc)<=dir.Size && desc[d].Name;d++){
        if(desc[d].Name>=imageSize || !memchr(base+desc[d].Name,0,imageSize-desc[d].Name))goto failed;
        if(_stricmp((char *)base+desc[d].Name,"USER32.dll") || !desc[d].OriginalFirstThunk)continue;
        DWORD names=desc[d].OriginalFirstThunk,slots=desc[d].FirstThunk;
        for(size_t i=0;;i++){
            if(names>=imageSize || slots>=imageSize || (i+1)*sizeof(IMAGE_THUNK_DATA64)>imageSize-names ||
               (i+1)*sizeof(IMAGE_THUNK_DATA64)>imageSize-slots)goto failed;
            IMAGE_THUNK_DATA64 *name=((IMAGE_THUNK_DATA64 *)(base+names))+i;
            if(!name->u1.AddressOfData)break;
            if(IMAGE_SNAP_BY_ORDINAL64(name->u1.Ordinal))continue;
            ULONGLONG rva=name->u1.AddressOfData;
            if(rva>=imageSize || imageSize-rva<3 || !memchr(base+(size_t)rva+2,0,imageSize-(size_t)rva-2))goto failed;
            if(strcmp((char *)base+(size_t)rva+2,"MessageBoxW"))continue;
            void **slot=(void **)&(((IMAGE_THUNK_DATA64 *)(base+slots))+i)->u1.Function;
            /* Preserve any existing import filter by chaining its entry point. */
            void *previousEntry=*slot;
            MEMORY_BASIC_INFORMATION region;
            if(!previousEntry || !VirtualQuery(previousEntry,&region,sizeof(region)) ||
               region.State!=MEM_COMMIT || region.Type!=MEM_IMAGE ||
               !(region.Protect & (PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))goto failed;
            HMODULE pinned;
            if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
                (LPCWSTR)(ULONG_PTR)FilterMessageBox,&pinned))goto failed;
            DWORD protection;
            if(!VirtualProtect(slot,sizeof(*slot),PAGE_READWRITE,&protection))goto failed;
            original=(MessageBoxFn)previousEntry;
            void *previous=InterlockedCompareExchangePointer(slot,(void *)(ULONG_PTR)FilterMessageBox,previousEntry);
            DWORD unused;VirtualProtect(slot,sizeof(*slot),protection,&unused);
            if(previous!=previousEntry){original=NULL;goto failed;}
            InterlockedExchange(&shared->status,1);goto done;
        }
    }
failed:
    InterlockedExchange(&shared->status,-1);
done:
    InterlockedExchange(&installing,0);
}
__declspec(dllexport) LRESULT CALLBACK XiaoAiBootstrapProc(int code,WPARAM wp,LPARAM lp) {
    if(code>=0)Install();
    return CallNextHookEx(NULL,code,wp,lp);
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(module);
    return TRUE;
}
