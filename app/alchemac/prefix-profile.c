/* Generic private-prefix font preparation followed by the unmodified launcher.
 * All game processes still belong to standalone-run and its watchdog.
 */
#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>
#include <stddef.h>

static int fail(const char *step) {
    fprintf(stderr, "prefix-profile: %s failed (Win32 %lu)\n", step, GetLastError());
    return 1;
}

static int install_font(const wchar_t *source) {
    wchar_t destination[MAX_PATH];
    HKEY key;
    DWORD disposition;
    const wchar_t *filename = L"NanumGothic-Regular.ttf";
    if (!GetWindowsDirectoryW(destination, MAX_PATH) || wcslen(destination) + 40 >= MAX_PATH)
        return fail("Windows directory");
    wcscat(destination, L"\\Fonts\\");
    wcscat(destination, filename);
    if (!CopyFileW(source, destination, FALSE)) return fail("font copy");
    LONG result = RegCreateKeyExW(HKEY_LOCAL_MACHINE,
        L"Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", 0, NULL, 0,
        KEY_SET_VALUE, NULL, &key, &disposition);
    if (result != ERROR_SUCCESS) { SetLastError(result); return fail("font registry key"); }
    result = RegSetValueExW(key, L"NanumGothic (TrueType)", 0, REG_SZ,
        (const BYTE *)filename, (DWORD)((wcslen(filename) + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    if (result != ERROR_SUCCESS) { SetLastError(result); return fail("font registry value"); }
    if (!AddFontResourceExW(destination, 0, NULL)) return fail("font registration");
    DWORD_PTR ignored;
    SendMessageTimeoutW(HWND_BROADCAST, WM_FONTCHANGE, 0, 0,
        SMTO_ABORTIFHUNG, 1000, &ignored);
    HDC dc = CreateCompatibleDC(NULL);
    HFONT font = CreateFontW(-24, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
        DEFAULT_PITCH, L"NanumGothic");
    if (!dc || !font) return fail("font glyph-check setup");
    HGDIOBJ old = SelectObject(dc, font);
    WORD glyphs[2] = {0xffff, 0xffff};
    const wchar_t text[] = {0xd55c, 0xae00, 0}; /* 한글 */
    DWORD got = GetGlyphIndicesW(dc, text, 2, glyphs, GGI_MARK_NONEXISTING_GLYPHS);
    SelectObject(dc, old); DeleteObject(font); DeleteDC(dc);
    if (got == GDI_ERROR || glyphs[0] == 0xffff || glyphs[1] == 0xffff) {
        fprintf(stderr, "prefix-profile: Korean glyph lookup failed\n"); return 1;
    }
    printf("prefix-profile: font registered; Korean glyphs %u %u\n", glyphs[0], glyphs[1]);
    fflush(stdout);
    return 0;
}

static int CALLBACK note_family(const LOGFONTW *font, const TEXTMETRICW *metrics, DWORD type, LPARAM found) {
    (void)font; (void)metrics; (void)type;
    *(BOOL *)found = TRUE;
    return 0;
}

static BOOL family_present(const wchar_t *name) {
    LOGFONTW query = {0}; BOOL found = FALSE;
    HDC dc = GetDC(NULL);
    query.lfCharSet = DEFAULT_CHARSET;
    wcsncpy(query.lfFaceName, name, LF_FACESIZE - 1);
    EnumFontFamiliesExW(dc, &query, note_family, (LPARAM)&found, 0);
    ReleaseDC(NULL, dc);
    return found;
}

/* Windows UI fonts carry no Hangul and borrow it through FontSubstitutes and
 * FontLink\SystemLink. A fresh prefix points both at Gulim/Malgun Gothic files
 * it does not have, so menus and dialogs show boxes. Point them at NanumGothic
 * where those fonts are absent; existing link entries are kept behind it.
 * Links name files: Wine prefers a newer macOS NanumGothic.ttc over the copy in
 * C:\windows\Fonts when the Mac has one, so both file names are linked. */
static void link_korean_ui(void) {
    static const wchar_t *korean[] = {L"Gulim", L"GulimChe", L"Dotum", L"DotumChe", L"Batang", L"Gungsuh", L"Malgun Gothic",
        L"\xad74\xb9bc", L"\xb3cb\xc6c0", L"\xbc14\xd0d5", L"\xad81\xc11c", L"\xb9d1\xc740 \xace0\xb515"}; /* 굴림 돋움 바탕 궁서 맑은 고딕 */
    static const wchar_t *ui[] = {L"Tahoma", L"Microsoft Sans Serif", L"Lucida Sans Unicode", L"Segoe UI"};
    static const wchar_t *links[] = {L"NanumGothic.ttc,NanumGothic", L"NanumGothic-Regular.ttf,NanumGothic"};
    static const wchar_t nanum[] = L"NanumGothic";
    const DWORD nanum_size = sizeof(nanum);
    unsigned changed = 0;
    HKEY key;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes",
            0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        wchar_t current[LF_FACESIZE]; DWORD size = sizeof(current), type;
        /* Substitutes resolve one level only: MS Shell Dlg must name NanumGothic itself. */
        if (RegQueryValueExW(key, L"MS Shell Dlg", NULL, &type, (BYTE *)current, &size) == ERROR_SUCCESS && type == REG_SZ) {
            for (size_t i = 0; i < ARRAYSIZE(korean); i++)
                if (!_wcsicmp(current, korean[i]) && !family_present(current)) {
                    if (RegSetValueExW(key, L"MS Shell Dlg", 0, REG_SZ, (const BYTE *)nanum, nanum_size) == ERROR_SUCCESS) changed++;
                    break;
                }
        }
        for (size_t i = 0; i < ARRAYSIZE(korean); i++) {
            size = sizeof(current);
            if (family_present(korean[i]) || RegQueryValueExW(key, korean[i], NULL, NULL, (BYTE *)current, &size) == ERROR_SUCCESS) continue;
            if (RegSetValueExW(key, korean[i], 0, REG_SZ, (const BYTE *)nanum, nanum_size) == ERROR_SUCCESS) changed++;
        }
        RegCloseKey(key);
    }
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink",
            0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        for (size_t i = 0; i < ARRAYSIZE(ui); i++) {
            static wchar_t old[8192], merged[8192 + 128];
            DWORD size = sizeof(old) - 2 * sizeof(wchar_t), type = REG_MULTI_SZ;
            memset(old, 0, sizeof(old));
            if (RegQueryValueExW(key, ui[i], NULL, &type, (BYTE *)old, &size) != ERROR_SUCCESS || type != REG_MULTI_SZ) old[0] = 0;
            wchar_t *out = merged;
            for (size_t j = 0; j < ARRAYSIZE(links); j++) { wcscpy(out, links[j]); out += wcslen(links[j]) + 1; }
            for (wchar_t *entry = old; *entry; entry += wcslen(entry) + 1) {
                BOOL ours = FALSE;
                for (size_t j = 0; j < ARRAYSIZE(links); j++) ours |= !_wcsicmp(entry, links[j]);
                if (!ours) { wcscpy(out, entry); out += wcslen(entry) + 1; }
            }
            *out++ = 0;
            DWORD merged_size = (DWORD)((out - merged) * sizeof(wchar_t)), old_size = 0;
            for (wchar_t *entry = old; *entry; entry += wcslen(entry) + 1) old_size = (DWORD)((entry + wcslen(entry) + 2 - old) * sizeof(wchar_t));
            if (merged_size == old_size && !memcmp(merged, old, merged_size)) continue;
            if (RegSetValueExW(key, ui[i], 0, REG_MULTI_SZ, (const BYTE *)merged, merged_size) == ERROR_SUCCESS) changed++;
        }
        RegCloseKey(key);
    }
    /* DirectWrite (WPF, modern UI toolkits) ignores both of the above and only honours
     * Wine's own Fonts\Replacements, so the same families are mapped there. */
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Wine\\Fonts\\Replacements",
            0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        for (size_t i = 0; i < ARRAYSIZE(korean); i++) {
            wchar_t current[LF_FACESIZE]; DWORD size = sizeof(current);
            if (family_present(korean[i]) || RegQueryValueExW(key, korean[i], NULL, NULL, (BYTE *)current, &size) == ERROR_SUCCESS) continue;
            if (RegSetValueExW(key, korean[i], 0, REG_SZ, (const BYTE *)nanum, nanum_size) == ERROR_SUCCESS) changed++;
        }
        RegCloseKey(key);
    }
    printf("prefix-profile: Korean UI font fallback updated (%u entries)\n", changed);
}

/* Alchemac 0.5.7 turned WPF hardware rendering off by default (Avalon.Graphics
 * DisableHWAcceleration=1) because of mtld3d bugs that are fixed now. Once per
 * environment that value is removed if it is still 1; a later choice is kept. */
static void restore_wpf_hardware(void) {
    HKEY key;
    DWORD done = 0, size = sizeof(done), type;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Alchemac",
            0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return;
    if (RegQueryValueExW(key, L"WpfHardwareRestored", NULL, &type, (BYTE *)&done, &size) == ERROR_SUCCESS) {
        RegCloseKey(key);
        return;
    }
    RegCloseKey(key);
    HKEY avalon;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Avalon.Graphics", 0,
            KEY_QUERY_VALUE | KEY_SET_VALUE, &avalon) == ERROR_SUCCESS) {
        DWORD existing = 0; size = sizeof(existing);
        if (RegQueryValueExW(avalon, L"DisableHWAcceleration", NULL, &type, (BYTE *)&existing, &size) == ERROR_SUCCESS
                && type == REG_DWORD && existing == 1
                && RegDeleteValueW(avalon, L"DisableHWAcceleration") == ERROR_SUCCESS)
            printf("prefix-profile: WPF hardware rendering restored\n");
        RegCloseKey(avalon);
    }
    DWORD marker = 1;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Alchemac", 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        RegSetValueExW(key, L"WpfHardwareRestored", 0, REG_DWORD, (const BYTE *)&marker, sizeof(marker));
        RegCloseKey(key);
    }
}

/* Wine's WinHTTP proxy auto-detect asks DNS for wpad.<domain>, and the domain comes from
 * the Mac's host name (<name>.local). On some networks wpad.local resolves to a host that
 * accepts the connection but never answers, so every first request waits 60 s. Windows
 * does not search WPAD under .local. Unless a connection setting already exists (a proxy
 * the user configured is never touched), write a direct-connection value without
 * PROXY_AUTODETECT_SETTINGS: DWORD 0x46, counter 2, flags 1, then 44 zero bytes. */
static void default_direct_connection(void) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections",
            0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return;
    if (RegQueryValueExW(key, L"DefaultConnectionSettings", NULL, NULL, NULL, NULL) == ERROR_FILE_NOT_FOUND) {
        BYTE settings[56] = {0};
        DWORD header[3] = {0x46, 2, 1};
        memcpy(settings, header, sizeof(header));
        if (RegSetValueExW(key, L"DefaultConnectionSettings", 0, REG_BINARY, settings, sizeof(settings)) == ERROR_SUCCESS)
            printf("prefix-profile: proxy auto-detect off (direct connection)\n");
    }
    RegCloseKey(key);
}

/* Per-program DPI override, read by Wine from AppCompatFlags\Layers by lower-case
 * file name. An empty value keeps the program's own DPI awareness even where the
 * environment's default value scales every unaware window (see the app's Retina mode);
 * DPIUNAWARE has Wine scale this program like Windows' "Override high DPI scaling". */
static void set_dpi_override(const wchar_t *exe, BOOL scaled) {
    const wchar_t *name = exe;
    for (const wchar_t *c = exe; *c; c++) if (*c == L'\\' || *c == L'/') name = c + 1;
    wchar_t lower[MAX_PATH];
    if (!*name || wcslen(name) >= MAX_PATH) return;
    for (size_t i = 0; ; i++) { lower[i] = towlower(name[i]); if (!name[i]) break; }
    const wchar_t *value = scaled ? L"~ DPIUNAWARE" : L"";
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
            0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return;
    if (RegSetValueExW(key, lower, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(wchar_t))) == ERROR_SUCCESS)
        printf("prefix-profile: DPI %s for %ls\n", scaled ? "scaled" : "own", lower);
    RegCloseKey(key);
}

/* .NET Framework programs carry a CLR header and need Wine Mono, which a prefix does not
 * have until something asks for it. .NET 5+ apphosts are ordinary native programs. */
static BOOL needs_clr(const wchar_t *exe) {
    HANDLE file = CreateFileW(exe, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    IMAGE_DOS_HEADER dos; IMAGE_NT_HEADERS32 nt; DWORD got = 0; BOOL clr = FALSE;
    if (ReadFile(file, &dos, sizeof(dos), &got, NULL) && got == sizeof(dos) && dos.e_magic == IMAGE_DOS_SIGNATURE
            && SetFilePointer(file, dos.e_lfanew, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER
            && ReadFile(file, &nt, sizeof(nt), &got, NULL) && got == sizeof(nt) && nt.Signature == IMAGE_NT_SIGNATURE) {
        if (nt.OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC)
            clr = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress != 0;
        else if (nt.OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC)
            clr = ((IMAGE_NT_HEADERS64 *)&nt)->OptionalHeader.NumberOfRvaAndSizes > IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR
                && SetFilePointer(file, dos.e_lfanew + offsetof(IMAGE_NT_HEADERS64, OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR]), NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER
                && ReadFile(file, &nt.OptionalHeader.DataDirectory[0], sizeof(IMAGE_DATA_DIRECTORY), &got, NULL) && got == sizeof(IMAGE_DATA_DIRECTORY)
                && nt.OptionalHeader.DataDirectory[0].VirtualAddress != 0;
    }
    CloseHandle(file);
    return clr;
}

/* Installs the Wine Mono package kept beside this helper, once per prefix, and waits for it. */
static void ensure_mono(const wchar_t *exe) {
    if (!needs_clr(exe)) return;
    wchar_t check[MAX_PATH], msi[MAX_PATH], command[MAX_PATH * 2];
    UINT length = GetWindowsDirectoryW(check, MAX_PATH);
    if (!length || length + 48 > MAX_PATH) return;
    wcscat(check, L"\\mono\\mono-2.0\\bin\\libmono-2.0-x86_64.dll");
    if (GetFileAttributesW(check) != INVALID_FILE_ATTRIBUTES) return;
    DWORD size = GetModuleFileNameW(NULL, msi, MAX_PATH);
    if (!size || size >= MAX_PATH) return;
    wchar_t *slash = wcsrchr(msi, L'\\');
    if (!slash || (size_t)(slash - msi) + 16 > MAX_PATH) return;
    wcscpy(slash + 1, L"wine-mono.msi");
    if (GetFileAttributesW(msi) == INVALID_FILE_ATTRIBUTES) { printf("prefix-profile: Wine Mono package missing\n"); return; }
    if (swprintf(command, MAX_PATH * 2, L"msiexec.exe /i \"%ls\" /qn", msi) < 0) return;
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION child = {0}; startup.cb = sizeof(startup);
    printf("prefix-profile: installing Wine Mono for a .NET Framework program\n");
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) { fail("Wine Mono install"); return; }
    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD status = 1; GetExitCodeProcess(child.hProcess, &status);
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    printf("prefix-profile: Wine Mono install exit=%lu\n", status);
}

/* Programs a launcher starts, such as a Unity game next to its launcher, are named by
 * their own file, so every EXE beside the registered one gets the same override. */
static void set_folder_dpi_override(const wchar_t *exe, BOOL scaled) {
    const wchar_t *name = exe;
    for (const wchar_t *c = exe; *c; c++) if (*c == L'\\' || *c == L'/') name = c + 1;
    size_t folder = name - exe;
    wchar_t pattern[MAX_PATH];
    if (!folder || folder + 6 > MAX_PATH) return;
    memcpy(pattern, exe, folder * sizeof(wchar_t));
    wcscpy(pattern + folder, L"*.exe");
    WIN32_FIND_DATAW found;
    HANDLE search = FindFirstFileW(pattern, &found);
    if (search == INVALID_HANDLE_VALUE) return;
    unsigned count = 0;
    do {
        if (!(found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && _wcsicmp(found.cFileName, name))
            set_dpi_override(found.cFileName, scaled);
    } while (++count < 64 && FindNextFileW(search, &found));
    FindClose(search);
}

/* Wine patch 0009 redirects steamclient(64).dll to a bridge into the host's Steam unless
 * HADRON_DISABLE_LSTEAMCLIENT is set to something other than "0", and the standalone path cannot pass
 * that variable. Wine loads HKCU\Environment into every process's environment, so the value is created
 * there (an existing value, such as a user's "0", is left alone). A process started by this helper in
 * its first run inherits this process's environment, which predates the new value, so it is set here too. */
static void disable_steam_redirect(void) {
    static const wchar_t name[] = L"HADRON_DISABLE_LSTEAMCLIENT";
    wchar_t value[16] = L"1";
    HKEY key;
    DWORD size = sizeof(value) - sizeof(wchar_t), type = 0;
    LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, L"Environment", 0, NULL, 0,
        KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL);
    if (result != ERROR_SUCCESS) {
        fprintf(stderr, "prefix-profile: Steam redirect registry key failed (Win32 %ld)\n", (long)result);
    } else {
        wchar_t existing[16] = {0};
        result = RegQueryValueExW(key, name, NULL, &type, (BYTE *)existing, &size);
        if (result == ERROR_SUCCESS && type == REG_SZ && existing[0]) {
            wcscpy(value, existing);
        } else if (result == ERROR_FILE_NOT_FOUND) {
            result = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)L"1", 2 * sizeof(wchar_t));
            if (result != ERROR_SUCCESS)
                fprintf(stderr, "prefix-profile: Steam redirect registry value failed (Win32 %ld)\n", (long)result);
        }
        RegCloseKey(key);
    }
    if (!GetEnvironmentVariableW(name, NULL, 0) && GetLastError() == ERROR_ENVVAR_NOT_FOUND
            && !SetEnvironmentVariableW(name, value))
        fprintf(stderr, "prefix-profile: Steam redirect environment failed (Win32 %lu)\n", GetLastError());
}

/* Reads a whole file, at most 64 MB; NULL when it cannot be read. Shared read/write/delete so a DLL that
 * running processes have mapped can still be read. */
static BYTE *read_whole(const wchar_t *path, DWORD *size) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER length; BYTE *data = NULL; DWORD got = 0;
    if (GetFileSizeEx(file, &length) && length.QuadPart > 0 && length.QuadPart <= (64 << 20)
            && (data = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)length.QuadPart))) {
        if (!ReadFile(file, data, (DWORD)length.QuadPart, &got, NULL) || got != length.QuadPart) { HeapFree(GetProcessHeap(), 0, data); data = NULL; }
        else *size = got;
    }
    CloseHandle(file);
    return data;
}

/* mtld3d's native d3d9.dll is copied into a prefix only when the prefix is created. After the runtime
 * migrated an environment (or for one that is up to date) the copy in the prefix may be older than the
 * mtld3d.dll/.so of the runtime that runs it, so it is replaced here, in the same run and after
 * prefix-init's migration. The app's bundled runtime sits at ..\SharedSupport\runtime of this helper
 * (Contents\Resources\prefix-profile.exe); where it does not (tests), nothing happens.
 * Only a file that is already mtld3d's (contains "mtld3d") and differs is replaced: Wine's builtin, a
 * user's own file and an absent file are left alone. The copy goes to a temporary file in the same
 * directory and replaces the target with MoveFileEx, so a failure never leaves a half-written DLL.
 * This helper is an x86_64 PE, but on ARM64 Wine x64 code runs as ARM64EC inside an ARM64 process and
 * is not a WOW64 process (only i386 and ARM32 are): there is no file system redirection for it
 * (dlls/wow64/file.c get_file_redirect belongs to the 32-bit thunk layer, and kernelbase's
 * get_machine_wow64_dir has no AMD64 case), so C:\windows\system32 is the real ARM64X folder that
 * holds the aarch64 d3d9.dll and C:\windows\syswow64 is reached by its own name. */
static void refresh_d3d9(void) {
    static const struct { const wchar_t *arch, *folder; } files[] = {{L"aarch64", L"system32"}, {L"i386", L"syswow64"}};
    wchar_t module[MAX_PATH], source_dir[MAX_PATH];
    DWORD size = GetModuleFileNameW(NULL, module, MAX_PATH);
    if (!size || size >= MAX_PATH) return;
    wchar_t *slash = wcsrchr(module, L'\\');
    if (!slash) return;
    *slash = 0;
    if (swprintf(source_dir, MAX_PATH, L"%ls\\..\\SharedSupport\\runtime\\dist\\lib\\hadron\\d3d9", module) < 0) return;
    DWORD attributes = GetFileAttributesW(source_dir);
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) return;
    for (size_t i = 0; i < ARRAYSIZE(files); i++) {
        wchar_t source[MAX_PATH], target[MAX_PATH], temp[MAX_PATH];
        if (swprintf(source, MAX_PATH, L"%ls\\%ls\\d3d9.dll", source_dir, files[i].arch) < 0
                || swprintf(target, MAX_PATH, L"C:\\windows\\%ls\\d3d9.dll", files[i].folder) < 0
                || swprintf(temp, MAX_PATH, L"C:\\windows\\%ls\\d3d9.dll.alchemac-%lu.tmp", files[i].folder, GetCurrentProcessId()) < 0) continue;
        DWORD old_size = 0, new_size = 0;
        BYTE *old_data = read_whole(target, &old_size);
        if (!old_data) continue;                               /* absent: not ours to create */
        BYTE *new_data = NULL;
        BOOL marked = FALSE;
        for (DWORD at = 0; !marked && old_size >= 6 && at <= old_size - 6; at++) marked = !memcmp(old_data + at, "mtld3d", 6);
        if (marked && (new_data = read_whole(source, &new_size)) && (new_size != old_size || memcmp(old_data, new_data, old_size))) {
            HANDLE out = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            DWORD wrote = 0;
            BOOL ok = out != INVALID_HANDLE_VALUE && WriteFile(out, new_data, new_size, &wrote, NULL) && wrote == new_size && FlushFileBuffers(out);
            if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
            if (ok && MoveFileExW(temp, target, MOVEFILE_REPLACE_EXISTING)) {
                printf("prefix-profile: d3d9.dll refreshed (%ls)\n", files[i].folder);
            } else {
                fprintf(stderr, "prefix-profile: d3d9 refresh failed (%ls, Win32 %lu)\n", files[i].folder, GetLastError());
                DeleteFileW(temp);
            }
        }
        HeapFree(GetProcessHeap(), 0, old_data);
        if (new_data) HeapFree(GetProcessHeap(), 0, new_data);
    }
}

/* Optional "WxH" for --display-mode: 640..8192, both even, nothing else. */
static BOOL parse_display_mode(const wchar_t *text, DWORD *width, DWORD *height) {
    DWORD values[2] = {0, 0};
    const wchar_t *c = text;
    for (int part = 0; part < 2; part++) {
        int digits = 0;
        while (*c >= L'0' && *c <= L'9') {
            if (++digits > 4) return FALSE;
            values[part] = values[part] * 10 + (DWORD)(*c - L'0'); c++;
        }
        if (!digits || (*c != (part ? 0 : L'x'))) return FALSE;
        if (part == 0) c++;
    }
    for (int i = 0; i < 2; i++) if (values[i] < 640 || values[i] > 8192 || (values[i] & 1)) return FALSE;
    *width = values[0]; *height = values[1];
    return TRUE;
}

/* Changes the primary display's size for this Wine session only, before the target starts. Flags 0, not
 * CDS_UPDATEREGISTRY (nothing is written to the prefix) and not CDS_FULLSCREEN (Wine's explorer would then
 * restore the mode as soon as this helper exits, but the launcher's own children need it). The mode lives in
 * the wineserver session and is gone when the session ends. Only a mode EnumDisplaySettingsW lists is
 * accepted; otherwise the nearest ones are logged and the launch continues unchanged. */
static void apply_display_mode(DWORD width, DWORD height) {
    DEVMODEW current = {0}; current.dmSize = sizeof(current);
    if (!EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &current)) {
        printf("prefix-profile: display mode %lux%lu skipped, current mode unavailable (Win32 %lu)\n", width, height, GetLastError());
        return;
    }
    DEVMODEW found = {0}; BOOL have = FALSE;
    DEVMODEW near1 = {0}, near2 = {0}; double d1 = 1e18, d2 = 1e18;
    for (DWORD i = 0;; i++) {
        DEVMODEW mode = {0}; mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsW(NULL, i, &mode)) break;
        if (mode.dmPelsWidth == width && mode.dmPelsHeight == height && mode.dmBitsPerPel == current.dmBitsPerPel
                && mode.dmDisplayFrequency == current.dmDisplayFrequency) { found = mode; have = TRUE; break; }
        double dw = (double)mode.dmPelsWidth - width, dh = (double)mode.dmPelsHeight - height, d = dw * dw + dh * dh;
        if (d < d1) { near2 = near1; d2 = d1; near1 = mode; d1 = d; }
        else if (d < d2 && (mode.dmPelsWidth != near1.dmPelsWidth || mode.dmPelsHeight != near1.dmPelsHeight)) { near2 = mode; d2 = d; }
    }
    if (!have) {
        printf("prefix-profile: display mode %lux%lu is not listed, unchanged (current %lux%lu@%lu, nearest %lux%lu, %lux%lu)\n",
               width, height, current.dmPelsWidth, current.dmPelsHeight, current.dmDisplayFrequency,
               near1.dmPelsWidth, near1.dmPelsHeight, near2.dmPelsWidth, near2.dmPelsHeight);
        return;
    }
    found.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    LONG result = ChangeDisplaySettingsExW(NULL, &found, NULL, 0, NULL);
    DEVMODEW after = {0}; after.dmSize = sizeof(after);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &after);
    printf("prefix-profile: display mode %lux%lu@%lu requested from %lux%lu, result=%ld, now %lux%lu\n", width, height,
           found.dmDisplayFrequency, current.dmPelsWidth, current.dmPelsHeight, (long)result, after.dmPelsWidth, after.dmPelsHeight);
}

int wmain(int argc, wchar_t **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* --launch keeps the program's own DPI awareness, --launch-scaled has Wine scale it,
     * --setup leaves it to the environment default (installers and their helpers). */
    if (argc < 3 || (wcscmp(argv[1], L"--check") && wcscmp(argv[1], L"--launch") && wcscmp(argv[1], L"--launch-scaled")
            && wcscmp(argv[1], L"--setup") && wcscmp(argv[1], L"--command"))) {
        fprintf(stderr, "usage: prefix-profile.exe --check font.ttf | --launch|--launch-scaled|--setup font.ttf Program.exe | --command font.ttf \"command line\" | [--launch|--launch-scaled font.ttf Program.exe --display-mode WxH]\n");
        return 2;
    }
    if (install_font(argv[2])) return 1;
    link_korean_ui();
    restore_wpf_hardware();
    default_direct_connection();
    disable_steam_redirect();
    if (!wcscmp(argv[1], L"--check")) return 0;
    refresh_d3d9();
    if (!wcscmp(argv[1], L"--command")) {
        /* A registered Windows command line, such as an UninstallString, parsed by
         * CreateProcess the way Windows parses it. No shell is involved. */
        if (argc != 4) return 2;
        for (const wchar_t *c = argv[3]; *c; c++) if (*c < L' ') return 2;
        size_t length = wcslen(argv[3]);
        wchar_t *command = HeapAlloc(GetProcessHeap(), 0, (length + 1) * sizeof(wchar_t));
        if (!command) return fail("command allocation");
        memcpy(command, argv[3], (length + 1) * sizeof(wchar_t));
        STARTUPINFOW startup = {0}; PROCESS_INFORMATION child = {0}; startup.cb = sizeof(startup);
        BOOL launched = CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child);
        HeapFree(GetProcessHeap(), 0, command);
        if (!launched) return fail("command CreateProcess");
        printf("prefix-profile: command started, child=%lu\n", child.dwProcessId);
        CloseHandle(child.hThread); CloseHandle(child.hProcess);
        return 0;
    }
    DWORD mode_width = 0, mode_height = 0;
    if (argc == 6 && wcscmp(argv[1], L"--setup") && !wcscmp(argv[4], L"--display-mode")) {
        if (!parse_display_mode(argv[5], &mode_width, &mode_height)) { fprintf(stderr, "prefix-profile: invalid --display-mode\n"); return 2; }
    } else if (argc != 4) return 2;
    if (wcschr(argv[3], L'"')) return 2;
    if (wcscmp(argv[1], L"--setup")) {
        set_dpi_override(argv[3], !wcscmp(argv[1], L"--launch-scaled"));
        set_folder_dpi_override(argv[3], !wcscmp(argv[1], L"--launch-scaled"));
    }
    DWORD attributes = GetFileAttributesW(argv[3]);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) return fail("launcher file");
    ensure_mono(argv[3]);
    if (mode_width) apply_display_mode(mode_width, mode_height);
    size_t length = wcslen(argv[3]);
    wchar_t *command = HeapAlloc(GetProcessHeap(), 0, (length + 3) * sizeof(wchar_t));
    if (!command) return fail("command allocation");
    command[0] = L'"'; memcpy(command + 1, argv[3], length * sizeof(wchar_t));
    command[length + 1] = L'"'; command[length + 2] = 0;
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION child = {0}; startup.cb = sizeof(startup);
    BOOL launched = CreateProcessW(argv[3], command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child);
    HeapFree(GetProcessHeap(), 0, command);
    if (!launched) return fail("original launcher CreateProcess");
    printf("prefix-profile: original launcher started, child=%lu\n", child.dwProcessId);
    CloseHandle(child.hThread);
    /* A program that ends right away is recorded for the app, which tells the user only when the whole
     * session also ends at once (an updater that starts another program and leaves is not an error).
     * Installers and tools (--setup) are expected to finish quickly and are not watched. The wait stops
     * at 5 seconds, so a normal program is never held back longer than that. */
    if (wcscmp(argv[1], L"--setup") && WaitForSingleObject(child.hProcess, 5000) == WAIT_OBJECT_0) {
        DWORD code = 0;
        if (GetExitCodeProcess(child.hProcess, &code)) printf("prefix-profile: target exited early, code=0x%08lx\n", (unsigned long)code);
    }
    CloseHandle(child.hProcess);
    /* The standalone supervisor waits for wineserver, including update/game children. */
    return 0;
}
