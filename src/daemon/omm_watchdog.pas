unit omm_watchdog;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  dynlibs, SysUtils, ctypes, omm_os, omm_shm, omm_ipc, omm_audio;

const
  PLUGIN_DEFAULT_LIB_PATH    = 'bin/libomm_mineral' + OMM_LIB_EXT;
  PLUGIN_FALLBACK_LIB_PATH   = 'target/release/libomm_mineral' + OMM_LIB_EXT;
  PLUGIN_DEFAULT_CONFIG_PATH = 'daemon.lua';

  // Lifecycle inactivity timeout thresholds (seconds)
  PLUGIN_SUSPEND_IDLE_TIMEOUT_SECS     = 300;   // 5 minutes
  PLUGIN_DEEP_UNLOAD_IDLE_TIMEOUT_SECS = 1800;  // 30 minutes

type
  TOmmPluginSearchFn = function(Query: PAnsiChar; OutTracks: POMMCondensedTrack; MaxTracks: SizeUInt; OutCount: PSizeUInt): Int32; cdecl;
  TOmmPluginGetTrackMetaFn = function(URI: PAnsiChar; OutTrack: POMMCondensedTrack): Int32; cdecl;

  TOmmWatchdog = class
  private
    FLibHandle: TLibHandle;
    FVTable: POmmPluginVTable;
    FSearchFn: TOmmPluginSearchFn;
    FGetMetaFn: TOmmPluginGetTrackMetaFn;
    FState: UInt32;
    FIdleSeconds: UInt32;
    FActiveStreams: UInt32;
    FRssBytes: UInt64;
    FLibPath: string;
    FConfigPath: string;

    function LoadAndResolveVTable: Boolean;
    procedure UpdateStatusFromPlugin;
    function GetIsLoaded: Boolean; inline;
  public
    constructor Create(const ALibPath: string = ''; const AConfigPath: string = '');
    destructor Destroy; override;

    // Lifecycle State Transitions
    function EnsureLoaded: Boolean;
    function EnsureActive: Boolean;
    function Suspend: Boolean;
    function Resume: Boolean;
    function DeepUnload: Boolean;

    // Periodic Maintenance (called once per second from daemon main loop)
    procedure Tick(DeltaSecs: UInt32 = 1);
    procedure RecordActivity;

    // Plugin Stream & Online Search Operations
    function SearchOnline(const Query: string; OutTracks: POMMCondensedTrack; MaxTracks: SizeUInt; out OutCount: SizeUInt): Int32;
    function GetTrackMeta(const URI: string; out OutTrack: TOMMCondensedTrack): Boolean;
    function OpenStream(const URI: string; out Handle: TOmmStreamHandle): Int32;
    function ReadStream(Handle: TOmmStreamHandle; Buffer: PByte; Count: SizeUInt; out BytesRead: SizeUInt): Int32;
    function SeekStream(Handle: TOmmStreamHandle; Offset: Int64; Whence: Int32; out OutPos: Int64): Int32;
    function CloseStream(Handle: TOmmStreamHandle): Int32;
    function FetchLyrics(const URI: string; OutBuf: PAnsiChar; BufLen: SizeUInt; out OutLen: SizeUInt): Int32;

    // Status Properties
    property State: UInt32 read FState;
    property IdleSeconds: UInt32 read FIdleSeconds;
    property ActiveStreams: UInt32 read FActiveStreams;
    property RssBytes: UInt64 read FRssBytes;
    property IsLoaded: Boolean read GetIsLoaded;
    property VTable: POmmPluginVTable read FVTable;
  end;

implementation
 
function TOmmWatchdog.GetIsLoaded: Boolean;
begin
  Result := (FLibHandle <> NilHandle);
end;

constructor TOmmWatchdog.Create(const ALibPath, AConfigPath: string);
begin
  inherited Create;
  FLibHandle := NilHandle;
  FVTable := nil;
  FSearchFn := nil;
  FGetMetaFn := nil;
  FState := OMM_PLUGIN_UNLOADED;
  FIdleSeconds := 0;
  FActiveStreams := 0;
  FRssBytes := 0;

  // Zero-Scan / Zero-Preload Startup: store path only, never call LoadLibrary or FileExists at startup
  if ALibPath <> '' then
    FLibPath := ALibPath
  else
    FLibPath := PLUGIN_DEFAULT_LIB_PATH;

  if AConfigPath <> '' then
    FConfigPath := AConfigPath
  else
    FConfigPath := PLUGIN_DEFAULT_CONFIG_PATH;
end;

destructor TOmmWatchdog.Destroy;
begin
  DeepUnload;
  inherited Destroy;
end;

function TOmmWatchdog.LoadAndResolveVTable: Boolean;
var
  get_vtable: TOmmPluginGetVTableFn;
  resolvedPath: string;
begin
  Result := False;
  if FLibHandle <> NilHandle then Exit(True);

  resolvedPath := FLibPath;
  if not FileExists(resolvedPath) then
  begin
    if FileExists(ExtractFilePath(ParamStr(0)) + 'libomm_mineral' + OMM_LIB_EXT) then
      resolvedPath := ExtractFilePath(ParamStr(0)) + 'libomm_mineral' + OMM_LIB_EXT
    else if FileExists(ExtractFilePath(ParamStr(0)) + 'omm_mineral' + OMM_LIB_EXT) then
      resolvedPath := ExtractFilePath(ParamStr(0)) + 'omm_mineral' + OMM_LIB_EXT
    else if FileExists(ExtractFilePath(ParamStr(0)) + 'libomm_mineral.so') then
      resolvedPath := ExtractFilePath(ParamStr(0)) + 'libomm_mineral.so'
    else if FileExists(PLUGIN_DEFAULT_LIB_PATH) then
      resolvedPath := PLUGIN_DEFAULT_LIB_PATH
    else if FileExists('bin/omm_mineral' + OMM_LIB_EXT) then
      resolvedPath := 'bin/omm_mineral' + OMM_LIB_EXT
    else if FileExists(PLUGIN_FALLBACK_LIB_PATH) then
      resolvedPath := PLUGIN_FALLBACK_LIB_PATH
    else if FileExists('target/release/omm_mineral' + OMM_LIB_EXT) then
      resolvedPath := 'target/release/omm_mineral' + OMM_LIB_EXT
    else if FileExists('/usr/lib64/oh-mini-mineral/libomm_mineral.so') then
      resolvedPath := '/usr/lib64/oh-mini-mineral/libomm_mineral.so'
    else if FileExists('/usr/lib/oh-mini-mineral/libomm_mineral.so') then
      resolvedPath := '/usr/lib/oh-mini-mineral/libomm_mineral.so'
    else if FileExists('/usr/lib64/oh-my-mineral/libomm_mineral.so') then
      resolvedPath := '/usr/lib64/oh-my-mineral/libomm_mineral.so'
    else if FileExists('/usr/lib/oh-my-mineral/libomm_mineral.so') then
      resolvedPath := '/usr/lib/oh-my-mineral/libomm_mineral.so'
    else
      Exit(False);
  end;

  FLibHandle := LoadLibrary(resolvedPath);
  if FLibHandle = NilHandle then Exit(False);

  get_vtable := TOmmPluginGetVTableFn(GetProcedureAddress(FLibHandle, 'omm_plugin_get_vtable'));
  if not Assigned(get_vtable) then
  begin
    UnloadLibrary(FLibHandle);
    FLibHandle := NilHandle;
    Exit(False);
  end;

  FVTable := get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
  if FVTable = nil then
  begin
    UnloadLibrary(FLibHandle);
    FLibHandle := NilHandle;
    Exit(False);
  end;

  FSearchFn := TOmmPluginSearchFn(GetProcedureAddress(FLibHandle, 'omm_plugin_search'));
  FGetMetaFn := TOmmPluginGetTrackMetaFn(GetProcedureAddress(FLibHandle, 'omm_plugin_get_track_meta'));

  Result := True;
end;

function TOmmWatchdog.EnsureLoaded: Boolean;
var
  rc: Int32;
  pCfg: PAnsiChar;
begin
  if (FState = OMM_PLUGIN_LAZY_WAKEUP) or (FState = OMM_PLUGIN_ACTIVE) then
    Exit(True);

  if (FState = OMM_PLUGIN_SUSPENDED) and (FLibHandle <> NilHandle) then
    Exit(Resume);

  if not LoadAndResolveVTable then Exit(False);

  if FileExists(FConfigPath) then
    pCfg := PAnsiChar(FConfigPath)
  else
    pCfg := nil;

  rc := FVTable^.Init(pCfg);
  if rc <> OMM_OK then Exit(False);

  FState := OMM_PLUGIN_LAZY_WAKEUP;
  FIdleSeconds := 0;
  UpdateStatusFromPlugin;
  Result := True;
end;

function TOmmWatchdog.EnsureActive: Boolean;
begin
  if not EnsureLoaded then Exit(False);
  if FState = OMM_PLUGIN_SUSPENDED then
    if not Resume then Exit(False);
  FState := OMM_PLUGIN_ACTIVE;
  Result := True;
end;

function TOmmWatchdog.Suspend: Boolean;
var
  rc: Int32;
begin
  Result := True;
  if FState = OMM_PLUGIN_SUSPENDED then Exit;

  if (FLibHandle <> NilHandle) and (FVTable <> nil) then
  begin
    rc := FVTable^.Suspend();
    if rc = OMM_OK then
    begin
      FState := OMM_PLUGIN_SUSPENDED;
      FActiveStreams := 0;
      UpdateStatusFromPlugin;
    end
    else
      Result := False;
  end
  else
  begin
    FState := OMM_PLUGIN_SUSPENDED;
    FActiveStreams := 0;
  end;
  omm_malloc_trim;
end;

function TOmmWatchdog.Resume: Boolean;
var
  rc: Int32;
begin
  Result := False;
  if (FLibHandle = NilHandle) or (FVTable = nil) then
  begin
    FState := OMM_PLUGIN_UNLOADED;
    Exit(EnsureLoaded);
  end;

  rc := FVTable^.Resume();
  if rc = OMM_OK then
  begin
    FState := OMM_PLUGIN_LAZY_WAKEUP;
    FIdleSeconds := 0;
    UpdateStatusFromPlugin;
    Result := True;
  end;
end;

function TOmmWatchdog.DeepUnload: Boolean;
begin
  Result := True;
  omm_audio_unload_all_idle_codecs;
  if FLibHandle = NilHandle then
  begin
    FState := OMM_PLUGIN_DEEP_UNLOAD;
    Exit;
  end;

  if Assigned(FVTable) and Assigned(FVTable^.Shutdown) then
    FVTable^.Shutdown();

  UnloadLibrary(FLibHandle);
  FLibHandle := NilHandle;
  FVTable := nil;
  FSearchFn := nil;
  FGetMetaFn := nil;
  FState := OMM_PLUGIN_DEEP_UNLOAD;
  FRssBytes := 0;
  FActiveStreams := 0;
  FIdleSeconds := 0;
  omm_malloc_trim;
end;

procedure TOmmWatchdog.RecordActivity;
begin
  FIdleSeconds := 0;
end;

procedure TOmmWatchdog.UpdateStatusFromPlugin;
var
  status: TOmmPluginStatus;
begin
  if Assigned(FVTable) and Assigned(FVTable^.GetStatus) then
  begin
    if FVTable^.GetStatus(@status) = OMM_OK then
    begin
      FState := status.State;
      FRssBytes := status.RssBytes;
      FActiveStreams := status.ActiveStreams;
    end;
  end;
end;

procedure TOmmWatchdog.Tick(DeltaSecs: UInt32);
begin
  // Maintain Dual-Slot Lazy Codec Pool (30-second idle unload)
  omm_audio_tick_codecs(DeltaSecs);

  Inc(FIdleSeconds, DeltaSecs);

  case FState of
    OMM_PLUGIN_ACTIVE:
    begin
      UpdateStatusFromPlugin;
      if (FActiveStreams = 0) and (FIdleSeconds >= PLUGIN_SUSPEND_IDLE_TIMEOUT_SECS) then
        Suspend;
    end;

    OMM_PLUGIN_LAZY_WAKEUP:
    begin
      if FIdleSeconds >= PLUGIN_SUSPEND_IDLE_TIMEOUT_SECS then
        Suspend;
    end;

    OMM_PLUGIN_SUSPENDED:
    begin
      if FIdleSeconds >= PLUGIN_DEEP_UNLOAD_IDLE_TIMEOUT_SECS then
        DeepUnload;
    end;
  end;
end;

function TOmmWatchdog.SearchOnline(const Query: string; OutTracks: POMMCondensedTrack; MaxTracks: SizeUInt; out OutCount: SizeUInt): Int32;
begin
  OutCount := 0;
  if not EnsureActive then Exit(OMM_ERR_GENERIC);
  if not Assigned(FSearchFn) then Exit(OMM_ERR_GENERIC);

  Result := FSearchFn(PAnsiChar(Query), OutTracks, MaxTracks, @OutCount);
  if Result = OMM_OK then
  begin
    FState := OMM_PLUGIN_ACTIVE;
    RecordActivity;
    UpdateStatusFromPlugin;
  end;
end;

function TOmmWatchdog.GetTrackMeta(const URI: string; out OutTrack: TOMMCondensedTrack): Boolean;
begin
  FillChar(OutTrack, SizeOf(OutTrack), 0);
  if not EnsureLoaded then Exit(False);
  if not Assigned(FGetMetaFn) then Exit(False);
  Result := (FGetMetaFn(PAnsiChar(URI), @OutTrack) = OMM_OK);
end;

function TOmmWatchdog.OpenStream(const URI: string; out Handle: TOmmStreamHandle): Int32;
begin
  Handle := nil;
  if not EnsureActive then Exit(OMM_ERR_GENERIC);

  Result := FVTable^.OpenStream(PAnsiChar(URI), @Handle);
  if Result = OMM_OK then
  begin
    FState := OMM_PLUGIN_ACTIVE;
    RecordActivity;
    UpdateStatusFromPlugin;
  end;
end;

function TOmmWatchdog.ReadStream(Handle: TOmmStreamHandle; Buffer: PByte; Count: SizeUInt; out BytesRead: SizeUInt): Int32;
begin
  BytesRead := 0;
  if (FVTable = nil) or (Handle = nil) then Exit(OMM_ERR_INVALID_PARAM);
  Result := FVTable^.ReadStream(Handle, Buffer, Count, @BytesRead);
  if Result = OMM_OK then RecordActivity;
end;

function TOmmWatchdog.SeekStream(Handle: TOmmStreamHandle; Offset: Int64; Whence: Int32; out OutPos: Int64): Int32;
begin
  OutPos := 0;
  if (FVTable = nil) or (Handle = nil) then Exit(OMM_ERR_INVALID_PARAM);
  Result := FVTable^.SeekStream(Handle, Offset, Whence, @OutPos);
  if Result = OMM_OK then RecordActivity;
end;

function TOmmWatchdog.CloseStream(Handle: TOmmStreamHandle): Int32;
begin
  if (FVTable = nil) or (Handle = nil) then Exit(OMM_ERR_INVALID_PARAM);
  Result := FVTable^.CloseStream(Handle);
  UpdateStatusFromPlugin;
end;

function TOmmWatchdog.FetchLyrics(const URI: string; OutBuf: PAnsiChar; BufLen: SizeUInt; out OutLen: SizeUInt): Int32;
begin
  OutLen := 0;
  if not EnsureLoaded then Exit(OMM_ERR_GENERIC);
  Result := FVTable^.FetchLyrics(PAnsiChar(URI), OutBuf, BufLen, @OutLen);
end;

end.
