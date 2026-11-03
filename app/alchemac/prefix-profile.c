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
    static const wchar_t *korean[] = {L"Gulim", L"GulimChe", L"Dotum", L"DotumChe", L"Batang", L"Malgun Gothic",
        L"\xad74\xb9bc", L"\xb3cb\xc6c0", L"\xbc14\xd0d5", L"\xb9d1\xc740 \xace0\xb515"}; /* 굴림 돋움 바탕 맑은 고딕 */
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
    printf("prefix-profile: Korean UI font fallback updated (%u entries)\n", changed);
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

int wmain(int argc, wchar_t **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* --launch keeps the program's own DPI awareness, --launch-scaled has Wine scale it,
     * --setup leaves it to the environment default (installers and their helpers). */
    if (argc < 3 || (wcscmp(argv[1], L"--check") && wcscmp(argv[1], L"--launch") && wcscmp(argv[1], L"--launch-scaled")
            && wcscmp(argv[1], L"--setup") && wcscmp(argv[1], L"--command"))) {
        fprintf(stderr, "usage: prefix-profile.exe --check font.ttf | --launch|--launch-scaled|--setup font.ttf Program.exe | --command font.ttf \"command line\"\n");
        return 2;
    }
    if (install_font(argv[2])) return 1;
    link_korean_ui();
    if (!wcscmp(argv[1], L"--check")) return 0;
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
    if (argc != 4 || wcschr(argv[3], L'"')) return 2;
    if (wcscmp(argv[1], L"--setup")) {
        set_dpi_override(argv[3], !wcscmp(argv[1], L"--launch-scaled"));
        set_folder_dpi_override(argv[3], !wcscmp(argv[1], L"--launch-scaled"));
    }
    DWORD attributes = GetFileAttributesW(argv[3]);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) return fail("launcher file");
    ensure_mono(argv[3]);
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
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    /* The standalone supervisor waits for wineserver, including update/game children. */
    return 0;
}
