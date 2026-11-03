unit omm_os;

{$mode objfpc}{$H+}
{$PACKRECORDS C}
{$pointermath on}

interface

uses
  {$IFDEF UNIX}
  BaseUnix, Unix,
  {$ENDIF}
  {$IFDEF WINDOWS}
  Windows, Winsock2,
  {$ENDIF}
  ctypes, dynlibs;

const
  {$IFDEF LINUX}
  OMM_LIB_EXT = '.so';
  {$ENDIF}
  {$IFDEF DARWIN}
  OMM_LIB_EXT = '.dylib';
  {$ENDIF}
  {$IFDEF WINDOWS}
  OMM_LIB_EXT = '.dll';
  OMM_SOCKET_TAG = $40000000;

  STDIN_FILENO  = 0;
  STDOUT_FILENO = 1;
  STDERR_FILENO = 2;

  O_RDONLY   = $0000;
  O_WRONLY   = $0001;
  O_RDWR     = $0002;
  O_CREAT    = $0100;
  O_TRUNC    = $0200;
  O_EXCL     = $0400;
  O_NONBLOCK = $4000;

  SEEK_SET = 0;
  SEEK_CUR = 1;
  SEEK_END = 2;

  PROT_READ  = 1;
  PROT_WRITE = 2;
  MAP_SHARED = 1;
  MAP_FAILED = Pointer(-1);

  S_IFMT  = $F000;
  S_IFDIR = $4000;
  S_IFREG = $8000;

  ESysEINTR       = 4;
  ESysEAGAIN      = 11;
  ESysEWOULDBLOCK = 11;

  SIGINT  = 2;
  SIGKILL = 9;
  SIGTERM = 15;

  POLLIN   = $0001;
  POLLOUT  = $0004;
  POLLERR  = $0008;
  POLLHUP  = $0010;
  POLLNVAL = $0020;
  {$ENDIF}

{$IFDEF WINDOWS}
type
  TsSize = Int64;
  TOff   = Int64;
  TPid   = PtrInt;
  TTime  = Int64;
  TMode  = UInt32;

  timespec = record
    tv_sec: Int64;
    tv_nsec: Int64;
  end;
  ptimespec = ^timespec;

  stat = record
    st_ino: UInt64;
    st_mode: UInt32;
    st_size: Int64;
    st_mtime: Int64;
  end;
  pstat = ^stat;

  pollfd = record
    fd: cint;
    events: cshort;
    revents: cshort;
  end;
  ppollfd = ^pollfd;

function fpOpen(path: PAnsiChar; flags: cint; mode: cint = 0): cint; overload;
function fpOpen(const path: AnsiString; flags: cint; mode: cint = 0): cint; overload;
function fpClose(fd: cint): cint;
function fpRead(fd: cint; buf: Pointer; nbytes: SizeUInt): TsSize; overload;
function fpRead(fd: cint; var buf; nbytes: SizeUInt): TsSize; overload;
function fpWrite(fd: cint; buf: Pointer; nbytes: SizeUInt): TsSize; overload;
function fpWrite(fd: cint; const buf; nbytes: SizeUInt): TsSize; overload;
function fpLseek(fd: cint; offset: Int64; whence: cint): Int64;
function fpFSync(fd: cint): cint;
function fpfTruncate(fd: cint; size: Int64): cint;
function fpStat(path: PAnsiChar; out buf: stat): cint; overload;
function fpStat(const path: AnsiString; out buf: stat): cint; overload;
function fpFStat(fd: cint; out buf: stat): cint;
function fpUnlink(path: PAnsiChar): cint; overload;
function fpUnlink(const path: AnsiString): cint; overload;
function fpRename(oldpath, newpath: PAnsiChar): cint; overload;
function fpRename(const oldpath, newpath: AnsiString): cint; overload;
function fpMkDir(path: PAnsiChar; mode: cint): cint; overload;
function fpMkDir(const path: AnsiString; mode: cint): cint; overload;
function fpSymlink(oldpath, newpath: PAnsiChar): cint;
function fpMMap(addr: Pointer; len: SizeUInt; prot: cint; flags: cint; fd: cint; offset: Int64): Pointer;
function fpMUnmap(addr: Pointer; len: SizeUInt): cint;
function fpNanoSleep(req, rem: ptimespec): cint;
function fpTime: Int64;
function FpGetpid: TPid;
function fpKill(pid: TPid; sig: cint): cint;
function fpSystem(const cmd: AnsiString): cint;
function fpGetErrno: cint;
function fpPoll(fds: ppollfd; nfds: cuint; timeout: cint): cint;
{$ENDIF}

function NormalizeOmmPath(const APath: AnsiString): AnsiString;
procedure omm_malloc_trim;
function c_system(cmd: PAnsiChar): cint;
function LoadSndFileLibrary: TLibHandle;
function LoadMpg123Library: TLibHandle;
procedure SpawnDaemonBackground(const ExePath: AnsiString);
procedure OpenUrlInBrowser(const Url: AnsiString);

implementation

{$IFDEF LINUX}
function libc_malloc_trim(pad: csize_t): cint; cdecl; external 'c' name 'malloc_trim';
{$ENDIF}

{$IFDEF UNIX}
function libc_system(cmd: PAnsiChar): cint; cdecl; external 'c' name 'system';
{$ENDIF}

{$IFDEF WINDOWS}
const
  _O_BINARY   = $8000;
  _SH_DENYNO  = $0040;
  _S_IREAD    = $0100;
  _S_IWRITE   = $0080;

function msvcrt_sopen(path: PAnsiChar; oflag: cint; shflag: cint; pmode: cint): cint; cdecl; external 'msvcrt.dll' name '_sopen';
function msvcrt_close(fd: cint): cint; cdecl; external 'msvcrt.dll' name '_close';
function msvcrt_read(fd: cint; buf: Pointer; count: cuint): cint; cdecl; external 'msvcrt.dll' name '_read';
function msvcrt_write(fd: cint; buf: Pointer; count: cuint): cint; cdecl; external 'msvcrt.dll' name '_write';
function msvcrt_lseeki64(fd: cint; offset: Int64; origin: cint): Int64; cdecl; external 'msvcrt.dll' name '_lseeki64';
function msvcrt_commit(fd: cint): cint; cdecl; external 'msvcrt.dll' name '_commit';
function msvcrt_chsize_s(fd: cint; size: Int64): cint; cdecl; external 'msvcrt.dll' name '_chsize_s';
function msvcrt_get_osfhandle(fd: cint): PtrInt; cdecl; external 'msvcrt.dll' name '_get_osfhandle';
function msvcrt_kbhit: cint; cdecl; external 'msvcrt.dll' name '_kbhit';
function msvcrt_getch: cint; cdecl; external 'msvcrt.dll' name '_getch';
function msvcrt_errno: pcint; cdecl; external 'msvcrt.dll' name '_errno';

function GetWinTempDir: AnsiString;
var
  buf: array[0..MAX_PATH] of AnsiChar;
  n: DWORD;
begin
  FillChar(buf, SizeOf(buf), 0);
  n := GetTempPathA(MAX_PATH, @buf[0]);
  if (n > 0) and (n < MAX_PATH) then
  begin
    SetString(Result, PAnsiChar(@buf[0]), n);
    if (Length(Result) > 0) and (Result[Length(Result)] <> '\') and (Result[Length(Result)] <> '/') then
      Result := Result + '\';
  end
  else
    Result := 'C:\Windows\Temp\';
end;
{$ENDIF}

function NormalizeOmmPath(const APath: AnsiString): AnsiString;
{$IFDEF WINDOWS}
var
  sub: AnsiString;
  i: Integer;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := APath;
  {$ENDIF}
  {$IFDEF WINDOWS}
  if APath = '' then Exit('');
  if (Copy(APath, 1, 6) = '/proc/') or (Copy(APath, 1, 5) = '/dev/') then
    Exit('');
  if APath = '/tmp' then
  begin
    Result := GetWinTempDir;
    if (Length(Result) > 3) and (Result[Length(Result)] = '\') then
      SetLength(Result, Length(Result) - 1);
    Exit;
  end;
  if Copy(APath, 1, 5) = '/tmp/' then
  begin
    sub := Copy(APath, 6, Length(APath) - 5);
    for i := 1 to Length(sub) do
      if sub[i] = '/' then sub[i] := '\';
    Result := GetWinTempDir + sub;
    Exit;
  end;
  Result := APath;
  {$ENDIF}
end;

procedure omm_malloc_trim;
begin
  {$IFDEF LINUX}
  libc_malloc_trim(0);
  {$ENDIF}
end;

function c_system(cmd: PAnsiChar): cint;
{$IFDEF WINDOWS}
var
  s, cmdLine: AnsiString;
  isAsync: Boolean;
  si: STARTUPINFOA;
  pi: PROCESS_INFORMATION;
  exitCode: DWORD;
{$ENDIF}
begin
  if cmd = nil then Exit(-1);
  {$IFDEF UNIX}
  Result := libc_system(cmd);
  {$ENDIF}
  {$IFDEF WINDOWS}
  s := AnsiString(cmd);
  while (Length(s) > 0) and (s[Length(s)] in [' ', #9, #10, #13]) do
    SetLength(s, Length(s) - 1);
  isAsync := False;
  if (Length(s) > 0) and (s[Length(s)] = '&') then
  begin
    isAsync := True;
    SetLength(s, Length(s) - 1);
  end;
  cmdLine := 'cmd.exe /c "' + s + '"';
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  FillChar(pi, SizeOf(pi), 0);
  if CreateProcessA(nil, PAnsiChar(cmdLine), nil, nil, False, CREATE_NO_WINDOW, nil, nil, si, pi) then
  begin
    if not isAsync then
    begin
      WaitForSingleObject(pi.hProcess, 15000);
      exitCode := 0;
      GetExitCodeProcess(pi.hProcess, exitCode);
      Result := cint(exitCode);
    end
    else
      Result := 0;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end
  else
    Result := -1;
  {$ENDIF}
end;

function LoadSndFileLibrary: TLibHandle;
begin
  Result := NilHandle;
  {$IFDEF LINUX}
  Result := LoadLibrary('libsndfile.so.1');
  if Result = NilHandle then Result := LoadLibrary('libsndfile.so');
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := LoadLibrary('libsndfile.1.dylib');
  if Result = NilHandle then Result := LoadLibrary('libsndfile.dylib');
  if Result = NilHandle then Result := LoadLibrary('/opt/homebrew/lib/libsndfile.dylib');
  if Result = NilHandle then Result := LoadLibrary('/usr/local/lib/libsndfile.dylib');
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := LoadLibrary('libsndfile-1.dll');
  if Result = NilHandle then Result := LoadLibrary('sndfile.dll');
  if Result = NilHandle then Result := LoadLibrary('libsndfile.dll');
  {$ENDIF}
end;

function LoadMpg123Library: TLibHandle;
begin
  Result := NilHandle;
  {$IFDEF LINUX}
  Result := LoadLibrary('libmpg123.so.0');
  if Result = NilHandle then Result := LoadLibrary('libmpg123.so');
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := LoadLibrary('libmpg123.0.dylib');
  if Result = NilHandle then Result := LoadLibrary('libmpg123.dylib');
  if Result = NilHandle then Result := LoadLibrary('/opt/homebrew/lib/libmpg123.dylib');
  if Result = NilHandle then Result := LoadLibrary('/usr/local/lib/libmpg123.dylib');
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := LoadLibrary('libmpg123-0.dll');
  if Result = NilHandle then Result := LoadLibrary('mpg123.dll');
  if Result = NilHandle then Result := LoadLibrary('libmpg123.dll');
  {$ENDIF}
end;

procedure SpawnDaemonBackground(const ExePath: AnsiString);
{$IFDEF WINDOWS}
var
  cmdLine: AnsiString;
  si: STARTUPINFOA;
  pi: PROCESS_INFORMATION;
{$ENDIF}
begin
  {$IFDEF UNIX}
  fpSystem('"' + ExePath + '" >/dev/null 2>&1 &');
  {$ENDIF}
  {$IFDEF WINDOWS}
  cmdLine := '"' + ExePath + '"';
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESHOWWINDOW;
  si.wShowWindow := SW_HIDE;
  FillChar(pi, SizeOf(pi), 0);
  if CreateProcessA(PAnsiChar(ExePath), PAnsiChar(cmdLine), nil, nil, False,
     DETACHED_PROCESS or CREATE_NO_WINDOW, nil, nil, si, pi) then
  begin
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end;
  {$ENDIF}
end;

procedure OpenUrlInBrowser(const Url: AnsiString);
begin
  {$IFDEF LINUX}
  fpSystem('xdg-open "' + Url + '" >/dev/null 2>&1 &');
  {$ENDIF}
  {$IFDEF DARWIN}
  fpSystem('open "' + Url + '" >/dev/null 2>&1 &');
  {$ENDIF}
  {$IFDEF WINDOWS}
  c_system(PAnsiChar('start "" "' + Url + '" &'));
  {$ENDIF}
end;

{$IFDEF WINDOWS}
function FileTimeToUnixTime(const ft: TFileTime): Int64;
var
  ticks: Int64;
begin
  ticks := (Int64(ft.dwHighDateTime) shl 32) or Int64(ft.dwLowDateTime);
  if ticks > 116444736000000000 then
    Result := (ticks - 116444736000000000) div 10000000
  else
    Result := 0;
end;

function fpOpen(path: PAnsiChar; flags: cint; mode: cint = 0): cint; overload;
var
  norm: AnsiString;
  cFlags: cint;
begin
  if path = nil then Exit(-1);
  norm := NormalizeOmmPath(AnsiString(path));
  if norm = '' then Exit(-1);
  cFlags := (flags and (not O_NONBLOCK)) or _O_BINARY;
  Result := msvcrt_sopen(PAnsiChar(norm), cFlags, _SH_DENYNO, _S_IREAD or _S_IWRITE);
end;

function fpOpen(const path: AnsiString; flags: cint; mode: cint = 0): cint; overload;
begin
  Result := fpOpen(PAnsiChar(path), flags, mode);
end;

function fpClose(fd: cint): cint;
begin
  if fd < 0 then Exit(-1);
  if (fd and OMM_SOCKET_TAG) <> 0 then
    Result := Winsock2.closesocket(TSocket(fd and (not OMM_SOCKET_TAG)))
  else
    Result := msvcrt_close(fd);
end;

function fpRead(fd: cint; buf: Pointer; nbytes: SizeUInt): TsSize; overload;
var
  r: cint;
  hIn: THandle;
  avail: DWORD;
begin
  if (fd < 0) or (buf = nil) then Exit(-1);
  if nbytes = 0 then Exit(0);
  if (fd and OMM_SOCKET_TAG) <> 0 then
  begin
    r := Winsock2.recv(TSocket(fd and (not OMM_SOCKET_TAG)), buf^, cint(nbytes), 0);
    Exit(r);
  end;
  if fd = STDIN_FILENO then
  begin
    if msvcrt_kbhit <> 0 then
    begin
      PByte(buf)^ := Byte(msvcrt_getch and $FF);
      Exit(1);
    end;
    hIn := GetStdHandle(STD_INPUT_HANDLE);
    if (hIn <> 0) and (hIn <> INVALID_HANDLE_VALUE) then
    begin
      avail := 0;
      if PeekNamedPipe(hIn, nil, 0, nil, @avail, nil) then
      begin
        if avail > 0 then
          Exit(msvcrt_read(fd, buf, cuint(nbytes)))
        else
          Exit(0);
      end;
    end;
    Exit(0);
  end;
  Result := msvcrt_read(fd, buf, cuint(nbytes));
end;

function fpRead(fd: cint; var buf; nbytes: SizeUInt): TsSize; overload;
begin
  Result := fpRead(fd, @buf, nbytes);
end;

function fpWrite(fd: cint; buf: Pointer; nbytes: SizeUInt): TsSize; overload;
var
  r: cint;
begin
  if (fd < 0) or (buf = nil) then Exit(-1);
  if nbytes = 0 then Exit(0);
  if (fd and OMM_SOCKET_TAG) <> 0 then
  begin
    r := Winsock2.send(TSocket(fd and (not OMM_SOCKET_TAG)), buf^, cint(nbytes), 0);
    Exit(r);
  end;
  Result := msvcrt_write(fd, buf, cuint(nbytes));
end;

function fpWrite(fd: cint; const buf; nbytes: SizeUInt): TsSize; overload;
begin
  Result := fpWrite(fd, @buf, nbytes);
end;

function fpLseek(fd: cint; offset: Int64; whence: cint): Int64;
begin
  if fd < 0 then Exit(-1);
  Result := msvcrt_lseeki64(fd, offset, whence);
end;

function fpFSync(fd: cint): cint;
begin
  if fd < 0 then Exit(-1);
  Result := msvcrt_commit(fd);
end;

function fpfTruncate(fd: cint; size: Int64): cint;
begin
  if fd < 0 then Exit(-1);
  Result := msvcrt_chsize_s(fd, size);
end;

function FillStatFromHandle(hFile: THandle; out buf: stat): cint;
var
  info: BY_HANDLE_FILE_INFORMATION;
begin
  FillChar(buf, SizeOf(buf), 0);
  if (hFile = INVALID_HANDLE_VALUE) or (hFile = 0) then Exit(-1);
  FillChar(info, SizeOf(info), 0);
  if not GetFileInformationByHandle(hFile, info) then Exit(-1);
  buf.st_ino := (UInt64(info.nFileIndexHigh) shl 32) or UInt64(info.nFileIndexLow);
  buf.st_size := (Int64(info.nFileSizeHigh) shl 32) or Int64(info.nFileSizeLow);
  buf.st_mtime := FileTimeToUnixTime(info.ftLastWriteTime);
  if (info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    buf.st_mode := S_IFDIR or $1ED
  else
    buf.st_mode := S_IFREG or $1A4;
  Result := 0;
end;

function fpStat(path: PAnsiChar; out buf: stat): cint; overload;
var
  norm: AnsiString;
  hFile: THandle;
begin
  FillChar(buf, SizeOf(buf), 0);
  if path = nil then Exit(-1);
  norm := NormalizeOmmPath(AnsiString(path));
  if norm = '' then Exit(-1);
  hFile := CreateFileA(PAnsiChar(norm), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if hFile = INVALID_HANDLE_VALUE then Exit(-1);
  Result := FillStatFromHandle(hFile, buf);
  CloseHandle(hFile);
end;

function fpStat(const path: AnsiString; out buf: stat): cint; overload;
begin
  Result := fpStat(PAnsiChar(path), buf);
end;

function fpFStat(fd: cint; out buf: stat): cint;
var
  hFile: PtrInt;
begin
  FillChar(buf, SizeOf(buf), 0);
  if fd < 0 then Exit(-1);
  hFile := msvcrt_get_osfhandle(fd);
  if hFile = -1 then Exit(-1);
  Result := FillStatFromHandle(THandle(hFile), buf);
end;

function fpUnlink(path: PAnsiChar): cint; overload;
var
  norm: AnsiString;
begin
  if path = nil then Exit(-1);
  norm := NormalizeOmmPath(AnsiString(path));
  if norm = '' then Exit(-1);
  if DeleteFileA(PAnsiChar(norm)) then Result := 0 else Result := -1;
end;

function fpUnlink(const path: AnsiString): cint; overload;
begin
  Result := fpUnlink(PAnsiChar(path));
end;

function fpRename(oldpath, newpath: PAnsiChar): cint; overload;
var
  normOld, normNew: AnsiString;
begin
  if (oldpath = nil) or (newpath = nil) then Exit(-1);
  normOld := NormalizeOmmPath(AnsiString(oldpath));
  normNew := NormalizeOmmPath(AnsiString(newpath));
  if MoveFileExA(PAnsiChar(normOld), PAnsiChar(normNew),
     MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    Result := 0
  else
    Result := -1;
end;

function fpRename(const oldpath, newpath: AnsiString): cint; overload;
begin
  Result := fpRename(PAnsiChar(oldpath), PAnsiChar(newpath));
end;

function fpMkDir(path: PAnsiChar; mode: cint): cint; overload;
var
  norm: AnsiString;
begin
  if path = nil then Exit(-1);
  norm := NormalizeOmmPath(AnsiString(path));
  if CreateDirectoryA(PAnsiChar(norm), nil) or (GetLastError = ERROR_ALREADY_EXISTS) then
    Result := 0
  else
    Result := -1;
end;

function fpMkDir(const path: AnsiString; mode: cint): cint; overload;
begin
  Result := fpMkDir(PAnsiChar(path), mode);
end;

function fpSymlink(oldpath, newpath: PAnsiChar): cint;
var
  normOld, normNew: AnsiString;
begin
  if (oldpath = nil) or (newpath = nil) then Exit(-1);
  normOld := NormalizeOmmPath(AnsiString(oldpath));
  normNew := NormalizeOmmPath(AnsiString(newpath));
  if CopyFileA(PAnsiChar(normOld), PAnsiChar(normNew), False) then
    Result := 0
  else
    Result := -1;
end;

function fpMMap(addr: Pointer; len: SizeUInt; prot: cint; flags: cint; fd: cint; offset: Int64): Pointer;
var
  p: PByte;
  rem, chunk: SizeUInt;
  got: cint;
begin
  if len = 0 then Exit(MAP_FAILED);
  p := PByte(VirtualAlloc(nil, len, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE));
  if p = nil then Exit(MAP_FAILED);
  if fd >= 0 then
  begin
    msvcrt_lseeki64(fd, offset, SEEK_SET);
    rem := len;
    Result := p;
    while rem > 0 do
    begin
      if rem > $4000000 then chunk := $4000000 else chunk := rem;
      got := msvcrt_read(fd, p, cuint(chunk));
      if got <= 0 then Break;
      Inc(p, got);
      Dec(rem, SizeUInt(got));
    end;
  end
  else
    Result := p;
end;

function fpMUnmap(addr: Pointer; len: SizeUInt): cint;
begin
  if (addr = nil) or (addr = MAP_FAILED) then Exit(-1);
  if VirtualFree(addr, 0, MEM_RELEASE) then
    Result := 0
  else
    Result := -1;
end;

function fpNanoSleep(req, rem: ptimespec): cint;
var
  ms: DWORD;
begin
  if req = nil then Exit(0);
  ms := DWORD(req^.tv_sec * 1000 + (req^.tv_nsec + 500000) div 1000000);
  if (ms = 0) and (req^.tv_nsec > 0) then ms := 1;
  Windows.Sleep(ms);
  if rem <> nil then
  begin
    rem^.tv_sec := 0;
    rem^.tv_nsec := 0;
  end;
  Result := 0;
end;

function fpTime: Int64;
var
  ft: TFileTime;
begin
  GetSystemTimeAsFileTime(ft);
  Result := FileTimeToUnixTime(ft);
end;

function FpGetpid: TPid;
begin
  Result := TPid(GetCurrentProcessId);
end;

function fpKill(pid: TPid; sig: cint): cint;
var
  hProc: THandle;
  exitCode: DWORD;
begin
  if pid <= 0 then Exit(-1);
  if sig = 0 then
  begin
    hProc := OpenProcess($1000 {PROCESS_QUERY_LIMITED_INFORMATION}, False, DWORD(pid));
    if hProc = 0 then hProc := OpenProcess(PROCESS_QUERY_INFORMATION, False, DWORD(pid));
    if hProc = 0 then hProc := OpenProcess(SYNCHRONIZE, False, DWORD(pid));
    if hProc = 0 then Exit(-1);
    exitCode := 0;
    if GetExitCodeProcess(hProc, exitCode) and (exitCode = STILL_ACTIVE) then
      Result := 0
    else
      Result := -1;
    CloseHandle(hProc);
    Exit;
  end;
  hProc := OpenProcess(PROCESS_TERMINATE, False, DWORD(pid));
  if hProc = 0 then Exit(-1);
  if TerminateProcess(hProc, 1) then Result := 0 else Result := -1;
  CloseHandle(hProc);
end;

function fpSystem(const cmd: AnsiString): cint;
begin
  Result := c_system(PAnsiChar(cmd));
end;

function fpGetErrno: cint;
var
  wsaErr: cint;
  pErr: pcint;
begin
  wsaErr := WSAGetLastError;
  if (wsaErr = WSAEWOULDBLOCK) or (wsaErr = WSAEINPROGRESS) then
    Exit(ESysEAGAIN);
  if wsaErr = WSAEINTR then
    Exit(ESysEINTR);
  pErr := msvcrt_errno;
  if pErr <> nil then Result := pErr^ else Result := 0;
end;

function IsStdinReady: Boolean;
var
  hIn: THandle;
  avail: DWORD;
begin
  if msvcrt_kbhit <> 0 then Exit(True);
  hIn := GetStdHandle(STD_INPUT_HANDLE);
  if (hIn <> 0) and (hIn <> INVALID_HANDLE_VALUE) then
  begin
    avail := 0;
    if PeekNamedPipe(hIn, nil, 0, nil, @avail, nil) and (avail > 0) then
      Exit(True);
  end;
  Result := False;
end;

function fpPoll(fds: ppollfd; nfds: cuint; timeout: cint): cint;
var
  i: cuint;
  readSet, errSet: TFDSet;
  tv: TTimeVal;
  pTv: PTimeVal;
  sockCount, selRes, readyCount: cint;
  rawSock: TSocket;
  hasStdin: Boolean;
begin
  if (fds = nil) or (nfds = 0) then
  begin
    if timeout > 0 then Windows.Sleep(DWORD(timeout));
    Exit(0);
  end;

  FD_ZERO(readSet);
  FD_ZERO(errSet);
  sockCount := 0;
  hasStdin := False;
  readyCount := 0;

  for i := 0 to nfds - 1 do
  begin
    fds[i].revents := 0;
    if fds[i].fd = STDIN_FILENO then
    begin
      hasStdin := True;
      if IsStdinReady then
      begin
        fds[i].revents := POLLIN;
        Inc(readyCount);
      end;
    end
    else if (fds[i].fd > 0) and ((fds[i].fd and OMM_SOCKET_TAG) <> 0) then
    begin
      rawSock := TSocket(fds[i].fd and (not OMM_SOCKET_TAG));
      FD_SET(rawSock, readSet);
      FD_SET(rawSock, errSet);
      Inc(sockCount);
    end;
  end;

  if sockCount > 0 then
  begin
    if readyCount > 0 then
    begin
      tv.tv_sec := 0;
      tv.tv_usec := 0;
      pTv := @tv;
    end
    else if timeout < 0 then
      pTv := nil
    else
    begin
      tv.tv_sec := timeout div 1000;
      tv.tv_usec := (timeout mod 1000) * 1000;
      pTv := @tv;
    end;

    selRes := Winsock2.select(0, @readSet, nil, @errSet, pTv);
    if selRes > 0 then
    begin
      for i := 0 to nfds - 1 do
      begin
        if (fds[i].fd > 0) and ((fds[i].fd and OMM_SOCKET_TAG) <> 0) then
        begin
          rawSock := TSocket(fds[i].fd and (not OMM_SOCKET_TAG));
          if FD_ISSET(rawSock, readSet) then
            fds[i].revents := fds[i].revents or POLLIN;
          if FD_ISSET(rawSock, errSet) then
            fds[i].revents := fds[i].revents or POLLERR;
          if fds[i].revents <> 0 then
            Inc(readyCount);
        end;
      end;
    end;
  end
  else if (readyCount = 0) and (timeout > 0) then
  begin
    Windows.Sleep(DWORD(timeout));
    if hasStdin then
    begin
      for i := 0 to nfds - 1 do
        if (fds[i].fd = STDIN_FILENO) and IsStdinReady then
        begin
          fds[i].revents := POLLIN;
          Inc(readyCount);
        end;
    end;
  end;

  Result := readyCount;
end;

var
  G_WsaData: TWSAData;
initialization
  WSAStartup($0202, G_WsaData);
  CreateDirectoryA('C:\tmp', nil);
finalization
  WSACleanup;
{$ENDIF}

end.
