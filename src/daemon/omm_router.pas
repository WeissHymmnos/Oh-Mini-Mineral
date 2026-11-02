unit omm_router;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  SysUtils, Math, omm_ipc, omm_shm, omm_audio, omm_watchdog, omm_library;

const
  OMM_ERR_UNSUPPORTED_SCHEME = OMM_ERR_UNSUPPORTED_URI;

type
  TURIScheme = (usUnsupported, usLocalFile, usMineralStream);

  TOmmRouter = class
  private
    FWatchdog: TOmmWatchdog;
    FLibrary: TOMMLibraryEngine;
    FPShm: POMMSharedMemory;
    FCurrentURI: string;
    FCurrentTrackID: UInt32;
    FPrefetchTrackID: UInt32;
    FPrefetchURI: string;
    FPrefetchActive: Boolean;
    FActiveStreamHandle: TOmmStreamHandle;
    procedure CancelPrefetch;
  public
    constructor Create(AWatchdog: TOmmWatchdog; ALibrary: TOMMLibraryEngine; APShm: POMMSharedMemory);
    destructor Destroy; override;

    function ParseScheme(const URI: string; out CleanTarget: string): TURIScheme;
    function PlayURI(const URI: string; TrackID: UInt32 = 0): Int32;
    function PlayTrackID(TrackID: UInt32): Int32;
    function Pause: Int32;
    function Resume: Int32;
    function Stop: Int32;
    function Seek(TargetMs: UInt32): Int32;
    function SetVolume(Vol: Single): Int32;

    procedure CheckPrefetchTrigger;
    procedure SetNextPrefetch(TrackID: UInt32; const URI: string);

    property CurrentURI: string read FCurrentURI;
    property CurrentTrackID: UInt32 read FCurrentTrackID;
    property PrefetchActive: Boolean read FPrefetchActive;
  end;

var
  GRouterWatchdog: TOmmWatchdog = nil;

function PluginStreamReadBridge(StreamHandle: Pointer; Buffer: PByte; Count: SizeUInt; OutRead: PSizeUInt): Int32; cdecl;
function PluginStreamSeekBridge(StreamHandle: Pointer; Offset: Int64; Whence: Int32; OutPos: PInt64): Int32; cdecl;

implementation

function PluginStreamReadBridge(StreamHandle: Pointer; Buffer: PByte; Count: SizeUInt; OutRead: PSizeUInt): Int32; cdecl;
var
  readBytes: SizeUInt;
  rc: Int32;
begin
  readBytes := 0;
  if GRouterWatchdog = nil then
    Exit(OMM_ERR_GENERIC);

  rc := GRouterWatchdog.ReadStream(StreamHandle, Buffer, Count, readBytes);
  if OutRead <> nil then
    OutRead^ := readBytes;
  Result := rc;
end;

function PluginStreamSeekBridge(StreamHandle: Pointer; Offset: Int64; Whence: Int32; OutPos: PInt64): Int32; cdecl;
var
  newPos: Int64;
  rc: Int32;
begin
  newPos := 0;
  if GRouterWatchdog = nil then
    Exit(OMM_ERR_GENERIC);

  rc := GRouterWatchdog.SeekStream(StreamHandle, Offset, Whence, newPos);
  if OutPos <> nil then
    OutPos^ := newPos;
  Result := rc;
end;

constructor TOmmRouter.Create(AWatchdog: TOmmWatchdog; ALibrary: TOMMLibraryEngine; APShm: POMMSharedMemory);
begin
  inherited Create;
  FWatchdog := AWatchdog;
  FLibrary := ALibrary;
  FPShm := APShm;
  FCurrentURI := '';
  FCurrentTrackID := 0;
  FPrefetchTrackID := 0;
  FPrefetchURI := '';
  FPrefetchActive := False;
  FActiveStreamHandle := nil;
  GRouterWatchdog := AWatchdog;
end;

destructor TOmmRouter.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TOmmRouter.CancelPrefetch;
begin
  FPrefetchActive := False;
  FPrefetchTrackID := 0;
  FPrefetchURI := '';
  omm_audio_cancel_prefetch();
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.PlaybackFlags := FPShm^.PlaybackFlags and (not OMM_FLAG_PREFETCHING);
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

function TOmmRouter.ParseScheme(const URI: string; out CleanTarget: string): TURIScheme;
begin
  CleanTarget := '';
  if Length(URI) = 0 then
    Exit(usUnsupported);

  if Pos('://', URI) = 0 then
    Exit(usUnsupported);

  if Copy(URI, 1, 7) = 'file://' then
  begin
    CleanTarget := Copy(URI, 8, Length(URI) - 7);
    Exit(usLocalFile);
  end;

  if (Copy(URI, 1, 10) = 'mineral://') or
     (Copy(URI, 1, 10) = 'netease://') or
     (Copy(URI, 1, 11) = 'bilibili://') or
     (Copy(URI, 1, 13) = 'applemusic://') or
     (Copy(URI, 1, 5) = 'qq://') then
  begin
    CleanTarget := URI;
    Exit(usMineralStream);
  end;

  Result := usUnsupported;
end;

function TOmmRouter.PlayURI(const URI: string; TrackID: UInt32): Int32;
var
  scheme: TURIScheme;
  cleanTarget: string;
  rc: Int32;
  pRec: POMMTrackRecord;
  metaTrack: TOMMCondensedTrack;
  hasMeta: Boolean;
begin
  scheme := ParseScheme(URI, cleanTarget);
  if scheme = usUnsupported then
    Exit(OMM_ERR_UNSUPPORTED_SCHEME);

  // Invalidate any active prefetch from preceding playback and stop audio thread BEFORE closing stream handle
  CancelPrefetch;
  omm_audio_stop();

  // Close previous stream handle if open
  if FActiveStreamHandle <> nil then
  begin
    if FWatchdog <> nil then
      FWatchdog.CloseStream(FActiveStreamHandle);
    FActiveStreamHandle := nil;
  end;

  FCurrentURI := URI;
  FCurrentTrackID := TrackID;
  FPrefetchActive := False;

  if scheme = usLocalFile then
  begin
    rc := omm_audio_play_file(PAnsiChar(cleanTarget));

    if FPShm <> nil then
    begin
      SeqLockWriteBegin(FPShm^.SeqLock);
      FPShm^.PlaybackState := OMM_STATE_PLAYING;
      FPShm^.PlaybackFlags := FPShm^.PlaybackFlags and (not OMM_FLAG_STREAMING);
      FPShm^.PositionMs := 0;
      if rc <> 0 then
        FPShm^.DurationMs := 210000;
      FPShm^.CurrentTrackID := TrackID;
      FillChar(FPShm^.VirtualURI[0], SizeOf(FPShm^.VirtualURI), 0);
      Move(URI[1], FPShm^.VirtualURI[0], Min(Length(URI), 255));

      if (TrackID > 0) and (FLibrary <> nil) then
      begin
        FLibrary.EnsureFresh;
        pRec := FLibrary.GetRecord(TrackID);
        if pRec <> nil then
        begin
          if (rc <> 0) or (FPShm^.DurationMs = 0) then
            FPShm^.DurationMs := pRec^.DurationMs;
          FillChar(FPShm^.TrackTitle[0], SizeOf(FPShm^.TrackTitle), 0);
          Move(pRec^.Title[0], FPShm^.TrackTitle[0], Min(SizeOf(pRec^.Title), SizeOf(FPShm^.TrackTitle)));

          FillChar(FPShm^.TrackArtist[0], SizeOf(FPShm^.TrackArtist), 0);
          Move(pRec^.Artist[0], FPShm^.TrackArtist[0], Min(SizeOf(pRec^.Artist), SizeOf(FPShm^.TrackArtist)));

          FillChar(FPShm^.TrackAlbum[0], SizeOf(FPShm^.TrackAlbum), 0);
          Move(pRec^.Album[0], FPShm^.TrackAlbum[0], Min(SizeOf(pRec^.Album), SizeOf(FPShm^.TrackAlbum)));
        end;
      end;
      SeqLockWriteEnd(FPShm^.SeqLock);
    end;

    Result := OMM_OK;
  end
  else
  begin
    // usMineralStream
    if FWatchdog = nil then Exit(OMM_ERR_GENERIC);

    hasMeta := FWatchdog.GetTrackMeta(cleanTarget, metaTrack);
    if hasMeta and (TrackID = 0) then
      FCurrentTrackID := metaTrack.TrackID;

    rc := FWatchdog.OpenStream(cleanTarget, FActiveStreamHandle);
    if rc = OMM_OK then
    begin
      omm_audio_play_stream(FActiveStreamHandle, @PluginStreamReadBridge, @PluginStreamSeekBridge);
    end;

    if FPShm <> nil then
    begin
      SeqLockWriteBegin(FPShm^.SeqLock);
      if rc = OMM_OK then
        FPShm^.PlaybackState := OMM_STATE_PLAYING
      else
        FPShm^.PlaybackState := OMM_STATE_STOPPED;
      FPShm^.PlaybackFlags := FPShm^.PlaybackFlags or OMM_FLAG_STREAMING;
      FPShm^.PositionMs := 0;
      if hasMeta and (metaTrack.DurationMs > 0) then
        FPShm^.DurationMs := metaTrack.DurationMs
      else
        FPShm^.DurationMs := 300000;
      if hasMeta and (TrackID = 0) then
        FPShm^.CurrentTrackID := metaTrack.TrackID
      else
        FPShm^.CurrentTrackID := TrackID;
      FPShm^.PluginState := FWatchdog.State;
      FPShm^.PluginRssBytes := FWatchdog.RssBytes;
      FillChar(FPShm^.VirtualURI[0], SizeOf(FPShm^.VirtualURI), 0);
      Move(URI[1], FPShm^.VirtualURI[0], Min(Length(URI), 255));
      if hasMeta then
      begin
        FillChar(FPShm^.TrackTitle[0], SizeOf(FPShm^.TrackTitle), 0);
        Move(metaTrack.Title[0], FPShm^.TrackTitle[0], Min(SizeOf(metaTrack.Title), SizeOf(FPShm^.TrackTitle)));
        FillChar(FPShm^.TrackArtist[0], SizeOf(FPShm^.TrackArtist), 0);
        Move(metaTrack.Artist[0], FPShm^.TrackArtist[0], Min(SizeOf(metaTrack.Artist), SizeOf(FPShm^.TrackArtist)));
        FillChar(FPShm^.TrackAlbum[0], SizeOf(FPShm^.TrackAlbum), 0);
        Move(metaTrack.Album[0], FPShm^.TrackAlbum[0], Min(SizeOf(metaTrack.Album), SizeOf(FPShm^.TrackAlbum)));
      end;
      SeqLockWriteEnd(FPShm^.SeqLock);
    end;

    Result := OMM_OK;
  end;
end;

function TOmmRouter.PlayTrackID(TrackID: UInt32): Int32;
var
  pRec: POMMTrackRecord;
  uriStr: string;
begin
  if FLibrary = nil then
    Exit(OMM_ERR_INVALID_PARAM);
  FLibrary.EnsureFresh;
  if not FLibrary.IsOpen then
    Exit(OMM_ERR_INVALID_PARAM);

  pRec := FLibrary.GetRecord(TrackID);
  if pRec = nil then
    Exit(OMM_ERR_INVALID_PARAM);

  uriStr := StrPas(pRec^.RelativePath);
  if Pos('://', uriStr) = 0 then
    uriStr := 'file://' + uriStr;

  Result := PlayURI(uriStr, TrackID);
end;

function TOmmRouter.Pause: Int32;
begin
  Result := omm_audio_pause();
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.PlaybackState := OMM_STATE_PAUSED;
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

function TOmmRouter.Resume: Int32;
begin
  Result := omm_audio_resume();
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.PlaybackState := OMM_STATE_PLAYING;
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

function TOmmRouter.Stop: Int32;
begin
  CancelPrefetch;
  Result := omm_audio_stop();
  if FActiveStreamHandle <> nil then
  begin
    if FWatchdog <> nil then
      FWatchdog.CloseStream(FActiveStreamHandle);
    FActiveStreamHandle := nil;
  end;
  FCurrentTrackID := 0;
  FCurrentURI := '';

  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.PlaybackState := OMM_STATE_STOPPED;
    FPShm^.PositionMs := 0;
    FPShm^.CurrentTrackID := 0;
    FPShm^.PlaybackFlags := FPShm^.PlaybackFlags and (not OMM_FLAG_PREFETCHING);
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

function TOmmRouter.Seek(TargetMs: UInt32): Int32;
var
  durMs: UInt32;
  inPrefetchZone: Boolean;
begin
  if (FPShm <> nil) and (FPShm^.DurationMs > 0) and (TargetMs > FPShm^.DurationMs) then
    TargetMs := FPShm^.DurationMs;

  durMs := omm_audio_get_duration_ms();
  if durMs > 20000 then
    inPrefetchZone := (TargetMs >= durMs - 20000)
  else if durMs > 0 then
    inPrefetchZone := (TargetMs >= durMs div 2)
  else
    inPrefetchZone := False;

  // If seeking backwards out of the prefetch zone while armed, cancel it
  if FPrefetchActive and not inPrefetchZone then
    CancelPrefetch;

  Result := omm_audio_seek(TargetMs);
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.PositionMs := TargetMs;
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

function TOmmRouter.SetVolume(Vol: Single): Int32;
begin
  if IsNan(Vol) or IsInfinite(Vol) then Vol := 1.0;
  if Vol < 0.0 then Vol := 0.0 else if Vol > 1.0 then Vol := 1.0;
  Result := omm_audio_set_volume(Vol);
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.Volume := Vol;
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

procedure TOmmRouter.SetNextPrefetch(TrackID: UInt32; const URI: string);
begin
  if FPrefetchActive then
    CancelPrefetch;
  FPrefetchTrackID := TrackID;
  FPrefetchURI := URI;
  FPrefetchActive := False;
end;

procedure TOmmRouter.CheckPrefetchTrigger;
var
  posMs, durMs: UInt32;
  scheme: TURIScheme;
  cleanTarget: string;
  pRec: POMMTrackRecord;
  inPrefetchZone: Boolean;
begin
  // 1. Detect if miniaudio transitioned from prefetched track to active playback
  if FPrefetchActive and (FPShm <> nil) and
     ((FPShm^.PlaybackFlags and OMM_FLAG_PREFETCHING) = 0) then
  begin
    if FPShm^.PlaybackState = OMM_STATE_PLAYING then
    begin
      FPrefetchActive := False;
      FCurrentTrackID := FPrefetchTrackID;
      if FPrefetchURI <> '' then
        FCurrentURI := FPrefetchURI;
      FPrefetchTrackID := 0;
      FPrefetchURI := '';

      // Publish new track metadata to shared memory
      SeqLockWriteBegin(FPShm^.SeqLock);
      FPShm^.CurrentTrackID := FCurrentTrackID;
      FillChar(FPShm^.VirtualURI[0], SizeOf(FPShm^.VirtualURI), 0);
      if Length(FCurrentURI) > 0 then
        Move(FCurrentURI[1], FPShm^.VirtualURI[0], Min(Length(FCurrentURI), 255));

      if (FCurrentTrackID > 0) and (FLibrary <> nil) then
      begin
        pRec := FLibrary.GetRecord(FCurrentTrackID);
        if pRec <> nil then
        begin
          if FPShm^.DurationMs = 0 then
            FPShm^.DurationMs := pRec^.DurationMs;
          FillChar(FPShm^.TrackTitle[0], SizeOf(FPShm^.TrackTitle), 0);
          Move(pRec^.Title[0], FPShm^.TrackTitle[0], Min(SizeOf(pRec^.Title), SizeOf(FPShm^.TrackTitle)));

          FillChar(FPShm^.TrackArtist[0], SizeOf(FPShm^.TrackArtist), 0);
          Move(pRec^.Artist[0], FPShm^.TrackArtist[0], Min(SizeOf(pRec^.Artist), SizeOf(FPShm^.TrackArtist)));

          FillChar(FPShm^.TrackAlbum[0], SizeOf(FPShm^.TrackAlbum), 0);
          Move(pRec^.Album[0], FPShm^.TrackAlbum[0], Min(SizeOf(pRec^.Album), SizeOf(FPShm^.TrackAlbum)));
        end;
      end;
      SeqLockWriteEnd(FPShm^.SeqLock);
    end
    else
    begin
      // Playback was stopped or interrupted
      FPrefetchActive := False;
      FPrefetchTrackID := 0;
      FPrefetchURI := '';
    end;
  end;

  // 2. If prefetch is already armed, wait for transition
  if FPrefetchActive then Exit;

  // 3. Only evaluate prefetch trigger during active playback
  if omm_audio_get_state() <> OMM_STATE_PLAYING then Exit;

  posMs := omm_audio_get_position_ms();
  durMs := omm_audio_get_duration_ms();
  if durMs = 0 then Exit;

  if durMs > 20000 then
    inPrefetchZone := (posMs >= durMs - 20000)
  else
    inPrefetchZone := (posMs >= durMs div 2);

  if not inPrefetchZone then Exit;

  // 4. Candidate selection: look up next track in local library
  if (FPrefetchURI = '') and (FCurrentTrackID > 0) and (FLibrary <> nil) then
  begin
    pRec := FLibrary.GetRecord(FCurrentTrackID + 1);
    if pRec <> nil then
    begin
      FPrefetchTrackID := FCurrentTrackID + 1;
      FPrefetchURI := StrPas(pRec^.RelativePath);
      if Pos('://', FPrefetchURI) = 0 then
        FPrefetchURI := 'file://' + FPrefetchURI;
    end;
  end;

  if FPrefetchURI = '' then Exit;

  // 5. Pre-open next track in audio engine
  scheme := ParseScheme(FPrefetchURI, cleanTarget);
  if scheme = usLocalFile then
  begin
    if omm_audio_prefetch_file(PAnsiChar(cleanTarget)) = 0 then
    begin
      FPrefetchActive := True;
      if FPShm <> nil then
      begin
        SeqLockWriteBegin(FPShm^.SeqLock);
        FPShm^.PlaybackFlags := FPShm^.PlaybackFlags or OMM_FLAG_PREFETCHING;
        SeqLockWriteEnd(FPShm^.SeqLock);
      end;
    end;
  end;
end;

end.
