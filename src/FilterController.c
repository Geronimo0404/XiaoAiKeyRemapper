#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <wintrust.h>
#include <softpub.h>
#include <wincrypt.h>
#include <wchar.h>
#include <stdio.h>

#include "Shared.h"

static wchar_t root[32768];
static wchar_t stateRoot[32768];


static HANDLE target;
static DWORD targetPid;
static BOOL ready;

static void FilePath(wchar_t *out, const wchar_t *name) { swprintf(out, 32768, L"%ls\\%ls", stateRoot, name); }
static void Log(const wchar_t *text) {
    wchar_t path[32768]; FilePath(path, L"controller.log");
    WIN32_FILE_ATTRIBUTE_DATA info;
    DWORD disposition = OPEN_ALWAYS;
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &info) &&
        (info.nFileSizeHigh || info.nFileSizeLow > 65536)) disposition = CREATE_ALWAYS;
    HANDLE h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, disposition, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    char buffer[4096]; SYSTEMTIME t; GetLocalTime(&t);
    wchar_t line[2048];
    int n = swprintf(line, 2048, L"%04u-%02u-%02u %02u:%02u:%02u %ls\r\n",
        t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond,text);
    if (n > 0) { int bytes = WideCharToMultiByte(CP_UTF8,0,line,n,buffer,sizeof(buffer),NULL,NULL);
        DWORD written; if (bytes > 0) WriteFile(h,buffer,(DWORD)bytes,&written,NULL); }
    CloseHandle(h);
}

static void MarkReady(BOOL enabled) {
    wchar_t path[32768]; FilePath(path, L"ready.txt");
    if (!enabled) { DeleteFileW(path); ready = FALSE; return; }
    if (ready) return;
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        char data[64]; int n = snprintf(data,sizeof(data),"%lu\r\n",targetPid); DWORD written;
        WriteFile(h,data,(DWORD)n,&written,NULL); CloseHandle(h); ready = TRUE;
        Log(L"READY: process-wide prompt filter confirmed in verified Xiaomi OSD process.");
    }
}

static BOOL RegisteredLocation(const wchar_t *path) {
    wchar_t install[32768]; DWORD bytes = sizeof(install);
    if (RegGetValueW(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Timi Personal Computing\\Update\\Clients\\XiaomiPCManager",
        L"InstallPath", RRF_RT_REG_SZ, NULL, install, &bytes) == ERROR_SUCCESS) {
        size_t n = wcslen(install); while (n && install[n-1] == L'\\') install[--n] = 0;
        if (n + 16 < 32768) { wcscat(install, L"\\OSDUtility.exe"); if (_wcsicmp(path,install) == 0) return TRUE; }
    }
    /* Update transitions may briefly leave registry and live process out of sync. */
    wchar_t base[32768]; DWORD n = GetEnvironmentVariableW(L"ProgramFiles",base,32768);
    if (!n || n > 32000) return FALSE;
    wcscat(base,L"\\MI\\XiaomiPCManager\\"); size_t prefix=wcslen(base);
    if (_wcsnicmp(path,base,prefix) != 0) return FALSE;
    const wchar_t *p=path+prefix, *version=p;
    while ((*p >= L'0' && *p <= L'9') || *p == L'.') ++p;
    return p > version && _wcsicmp(p,L"\\OSDUtility.exe") == 0;
}

static BOOL XiaomiSignature(const wchar_t *path) {
    WINTRUST_FILE_INFO file = {0}; file.cbStruct=sizeof(file); file.pcwszFilePath=path;
    WINTRUST_DATA trust={0}; trust.cbStruct=sizeof(trust); trust.dwUIChoice=WTD_UI_NONE;
    trust.fdwRevocationChecks=WTD_REVOKE_NONE; trust.dwUnionChoice=WTD_CHOICE_FILE;
    trust.pFile=&file; trust.dwStateAction=WTD_STATEACTION_VERIFY;
    trust.dwProvFlags=WTD_CACHE_ONLY_URL_RETRIEVAL;
    GUID action=WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status=WinVerifyTrust(NULL,&action,&trust);
    trust.dwStateAction=WTD_STATEACTION_CLOSE; WinVerifyTrust(NULL,&action,&trust);
    if (status != ERROR_SUCCESS) return FALSE;
    HCERTSTORE store=NULL; HCRYPTMSG msg=NULL;
    if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE,path,CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
        CERT_QUERY_FORMAT_FLAG_BINARY,0,NULL,NULL,NULL,&store,&msg,NULL)) return FALSE;
    BOOL ok=FALSE; DWORD size=0;
    if (CryptMsgGetParam(msg,CMSG_SIGNER_INFO_PARAM,0,NULL,&size) && size) {
        CMSG_SIGNER_INFO *signer=(CMSG_SIGNER_INFO *)HeapAlloc(GetProcessHeap(),0,size);
        if (signer && CryptMsgGetParam(msg,CMSG_SIGNER_INFO_PARAM,0,signer,&size)) {
            CERT_INFO search={0}; search.Issuer=signer->Issuer; search.SerialNumber=signer->SerialNumber;
            PCCERT_CONTEXT cert=CertFindCertificateInStore(store,X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,
                0,CERT_FIND_SUBJECT_CERT,&search,NULL);
            if (cert) {
                wchar_t org[256];
                if (CertGetNameStringW(cert,CERT_NAME_ATTR_TYPE,0,(void *)szOID_ORGANIZATION_NAME,org,256)>1)
                    ok=wcscmp(org,L"\x5317\x4eac\x5c0f\x7c73\x667a\x80fd\x79d1\x6280\x6709\x9650\x516c\x53f8")==0;
                CertFreeCertificateContext(cert);
            }
        }
        if (signer) HeapFree(GetProcessHeap(),0,signer);
    }
    if(msg) CryptMsgClose(msg);
    if(store) CertCloseStore(store,0);
    return ok;
}

static HANDLE FindTarget(DWORD *foundPid) {
    DWORD ourSession=0; ProcessIdToSessionId(GetCurrentProcessId(),&ourSession);
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if (snapshot==INVALID_HANDLE_VALUE) return NULL;
    HANDLE result=NULL; PROCESSENTRY32W pe; pe.dwSize=sizeof(pe);
    if (Process32FirstW(snapshot,&pe)) do {
        DWORD session;
        if (_wcsicmp(pe.szExeFile,L"OSDUtility.exe") ||
            !ProcessIdToSessionId(pe.th32ProcessID,&session) || session!=ourSession) continue;
        HANDLE p=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,pe.th32ProcessID);
        if (!p) continue;
        wchar_t path[32768]; DWORD len=32768;
        if(QueryFullProcessImageNameW(p,0,path,&len) && RegisteredLocation(path) && XiaomiSignature(path)) {
            *foundPid=pe.th32ProcessID; result=p;
            wchar_t line[2048]; swprintf(line,2048,L"Verified target PID=%lu path=%ls",*foundPid,path); Log(line); break;
        }
        CloseHandle(p);
    } while(Process32NextW(snapshot,&pe));
    CloseHandle(snapshot); return result;
}

static HANDLE mapping;
static SharedState *shared;
static HMODULE hookModule;
static HOOKPROC bootstrap;
static LONG lastSuppressed;
static BOOL failureLogged;
static void Detach(void) {
    MarkReady(FALSE);
    if(shared){InterlockedExchange(&shared->enabled,0);UnmapViewOfFile(shared);shared=NULL;}
    if(mapping){CloseHandle(mapping);mapping=NULL;}
    if(target)CloseHandle(target);
    target=NULL;targetPid=0;lastSuppressed=0;failureLogged=FALSE;
}
static BOOL CALLBACK BootstrapWindow(HWND window,LPARAM ignored) {
    (void)ignored;
    DWORD pid=0;DWORD tid=GetWindowThreadProcessId(window,&pid);
    if(pid!=targetPid || !tid)return TRUE;
    HHOOK hook=SetWindowsHookExW(WH_CALLWNDPROC,bootstrap,hookModule,tid);
    if(!hook)return TRUE;
    DWORD_PTR result=0;
    SendMessageTimeoutW(window,WM_NULL,0,0,SMTO_ABORTIFHUNG|SMTO_BLOCK,500,&result);
    UnhookWindowsHookEx(hook);
    return shared->status!=1;
}
static void EnsureFilter(HMODULE dll,HOOKPROC callback) {
    hookModule=dll;bootstrap=callback;
    if(!shared){
        wchar_t name[128];MappingName(name,128,targetPid);
        mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,sizeof(SharedState),name);
        if(!mapping){Log(L"ERROR: could not create process control mapping.");return;}
        shared=(SharedState *)MapViewOfFile(mapping,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(SharedState));
        if(!shared){CloseHandle(mapping);mapping=NULL;return;}
        ZeroMemory(shared,sizeof(*shared));shared->magic=XIAOAIKEY_MAGIC;shared->targetPid=targetPid;
        shared->controllerPid=GetCurrentProcessId();
        FILETIME exited,kernel,user;
        GetProcessTimes(GetCurrentProcess(),&shared->controllerCreated,&exited,&kernel,&user);
        InterlockedExchange(&shared->enabled,1);
    }
    if(shared->status!=1){
        EnumWindows(BootstrapWindow,0);
        HWND message=NULL;
        while(shared->status!=1 && (message=FindWindowExW(HWND_MESSAGE,message,NULL,NULL)))BootstrapWindow(message,0);
    }
    if(shared->status==1){
        if(!ready)Log(L"ACK: process-wide MessageBoxW filter installed; new threads covered.");
        MarkReady(TRUE);
        LONG count=shared->suppressed;
        if(count!=lastSuppressed){
            wchar_t line[128];swprintf(line,128,L"Missing-XiaoAi prompts suppressed=%ld",count);Log(line);lastSuppressed=count;
        }
    }else {
        MarkReady(FALSE);
        if(shared->status==-1 && !failureLogged){
            Log(L"ERROR: MessageBoxW import could not be safely filtered; original behavior retained.");
            failureLogged=TRUE;
        }
    }
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE prev,PWSTR cmd,int show) {
    (void)instance;(void)prev;(void)cmd;(void)show;
    GetModuleFileNameW(NULL,root,32768);wchar_t *slash=wcsrchr(root,L'\\');if(!slash)return 1;*slash=0;
    DWORD stateLength=GetEnvironmentVariableW(L"LOCALAPPDATA",stateRoot,32768);
    if(!stateLength || stateLength>32000)return 7;
    wcscat(stateRoot,L"\\XiaoAiKey");CreateDirectoryW(stateRoot,NULL);
    int argc;LPWSTR *argv=CommandLineToArgvW(GetCommandLineW(),&argc);
    BOOL continuous=argc==2 && wcscmp(argv[1],L"--run")==0;
    BOOL check=argc==2 && wcscmp(argv[1],L"--check")==0;
    LocalFree(argv);
    if(check){DWORD pid=0;HANDLE p=FindTarget(&pid);if(p){CloseHandle(p);Log(L"CHECK PASSED: location and Xiaomi signature verified; no hooks installed.");return 0;}Log(L"CHECK FAILED: no trusted target found; no hooks installed.");return 5;}
    if(!continuous)return 2;
    HANDLE mutex=CreateMutexW(NULL,TRUE,L"Local\\XiaoAiKey.Controller");
    if(!mutex || GetLastError()==ERROR_ALREADY_EXISTS){if(mutex)CloseHandle(mutex);return 0;}
    MarkReady(FALSE);
    wchar_t dllPath[32768],stopPath[32768];swprintf(dllPath,32768,L"%ls\\PromptFilter.dll",root);FilePath(stopPath,L"stop.request");
    HMODULE dll=LoadLibraryW(dllPath);
    if(!dll){Log(L"ERROR: could not load hook DLL.");CloseHandle(mutex);return 3;}
    HOOKPROC callback=(HOOKPROC)GetProcAddress(dll,"XiaoAiBootstrapProc");
    if(!callback){FreeLibrary(dll);CloseHandle(mutex);return 4;}
    DeleteFileW(stopPath); /* A new explicit launch, including the next logon, resumes operation. */
    Log(L"START: prompt filter controller.");
    ULONGLONG lastDiscovery=0,lastFilterCheck=0;BOOL waitingLogged=FALSE;MSG msg;
    while(GetFileAttributesW(stopPath)==INVALID_FILE_ATTRIBUTES){
        if(target && WaitForSingleObject(target,0)!=WAIT_TIMEOUT){Log(L"Target exited; waiting to reconnect.");Detach();lastDiscovery=0;lastFilterCheck=0;}
        if(!target && (!lastDiscovery||GetTickCount64()-lastDiscovery>=2000)){
            lastDiscovery=GetTickCount64();target=FindTarget(&targetPid);
            if(target)waitingLogged=FALSE;
            else if(!waitingLogged){Log(L"WAITING: no verified Xiaomi OSD process in this session.");waitingLogged=TRUE;}
        }
        if(target && (!lastFilterCheck || GetTickCount64()-lastFilterCheck>=1000)){
            lastFilterCheck=GetTickCount64();
            EnsureFilter(dll,callback);
        }
        while(PeekMessageW(&msg,NULL,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
        MsgWaitForMultipleObjects(0,NULL,FALSE,1000,QS_ALLINPUT);
    }
    Detach();Log(L"STOPPED: process-wide filter disabled; retained DLL passes calls through.");FreeLibrary(dll);ReleaseMutex(mutex);CloseHandle(mutex);return 0;
}
