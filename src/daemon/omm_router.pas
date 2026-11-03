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

  TLyricEntry = record
    TimestampMs: UInt32;
    Text: string;
  end;

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
    FLyrics: array of TLyricEntry;
    FLyricCount: Integer;
    FLastLyricIdx: Integer;
    procedure CancelPrefetch;
    procedure ClearLyrics;
    procedure ParseLrcContent(const RawLrc: string);
    procedure LoadLyricsForTrack(Scheme: TURIScheme; const CleanTarget: string);
    procedure SyncLyricsToSHM(PosMs: UInt32; ForceUpdate: Boolean = False);
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
    procedure RefreshLyricsIfNeeded;

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
  FLyricCount := 0;
  FLastLyricIdx := -1;
  SetLength(FLyrics, 0);
  GRouterWatchdog := AWatchdog;
end;

destructor TOmmRouter.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TOmmRouter.ClearLyrics;
begin
  FLyricCount := 0;
  FLastLyricIdx := -1;
  SetLength(FLyrics, 0);
  if FPShm <> nil then
  begin
    SeqLockWriteBegin(FPShm^.SeqLock);
    FillChar(FPShm^.LyricCurrent[0], SizeOf(FPShm^.LyricCurrent), 0);
    FillChar(FPShm^.LyricNext[0], SizeOf(FPShm^.LyricNext), 0);
    FPShm^.LyricTimestampMs := 0;
    FPShm^.LyricLineIdx := 0;
    FPShm^.LrcLineCount := 0;
    FPShm^.LrcTextLen := 0;
    FillChar(FPShm^.LrcRawText[0], SizeOf(FPShm^.LrcRawText), 0);
    Inc(FPShm^.LrcGeneration);
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;
end;

procedure TOmmRouter.ParseLrcContent(const RawLrc: string);
var
  lineStart, lineEnd, i, n, p, closePos, colonPos, dotPos: Integer;
  lineStr, tagStr, minStr, secStr, fracStr, textPart: string;
  mins, secs, frac, code: Integer;
  tsMs: UInt32;
  lineTimestamps: array[0..15] of UInt32;
  tsCount, j, k: Integer;
  tmpEntry: TLyricEntry;
begin
  FLyricCount := 0;
  FLastLyricIdx := -1;
  SetLength(FLyrics, 0);

  n := Length(RawLrc);
  lineStart := 1;
  while lineStart <= n do
  begin
    lineEnd := lineStart;
    while (lineEnd <= n) and not (RawLrc[lineEnd] in [#10, #13]) do
      Inc(lineEnd);

    lineStr := Trim(Copy(RawLrc, lineStart, lineEnd - lineStart));
    lineStart := lineEnd + 1;
    if (lineStart <= n) and (RawLrc[lineEnd] = #13) and (RawLrc[lineStart] = #10) then
      Inc(lineStart);

    if lineStr = '' then
      Continue;

    tsCount := 0;
    p := 1;
    while (p <= Length(lineStr)) and (lineStr[p] = '[') do
    begin
      closePos := Pos(']', Copy(lineStr, p, Length(lineStr) - p + 1));
      if closePos <= 1 then
        Break;
      tagStr := Copy(lineStr, p + 1, closePos - 2);
      colonPos := Pos(':', tagStr);
      if colonPos > 1 then
      begin
        minStr := Copy(tagStr, 1, colonPos - 1);
        Val(minStr, mins, code);
        if code = 0 then
        begin
          dotPos := Pos('.', tagStr);
          if dotPos = 0 then
            dotPos := Pos(':', Copy(tagStr, colonPos + 1, Length(tagStr)));
          if dotPos > colonPos then
          begin
            secStr := Copy(tagStr, colonPos + 1, dotPos - colonPos - 1);
            fracStr := Copy(tagStr, dotPos + 1, Length(tagStr) - dotPos);
          end
          else
          begin
            secStr := Copy(tagStr, colonPos + 1, Length(tagStr) - colonPos);
            fracStr := '0';
          end;
          Val(secStr, secs, code);
          if code = 0 then
          begin
            Val(fracStr, frac, code);
            if code <> 0 then frac := 0;
            if Length(fracStr) = 1 then
              frac := frac * 100
            else if Length(fracStr) = 2 then
              frac := frac * 10
            else if Length(fracStr) > 3 then
              while frac >= 1000 do frac := frac div 10;

            tsMs := UInt32(Max(0, mins)) * 60000 + UInt32(Max(0, secs)) * 1000 + UInt32(Max(0, frac));
            if tsCount < Length(lineTimestamps) then
            begin
              lineTimestamps[tsCount] := tsMs;
              Inc(tsCount);
            end;
            p := p + closePos;
            Continue;
          end;
        end;
      end;
      // Non-timestamp metadata tag like [ar:...], [ti:...]
      p := p + closePos;
    end;

    if tsCount > 0 then
    begin
      textPart := Trim(Copy(lineStr, p, Length(lineStr) - p + 1));
      if textPart <> '' then
      begin
        for i := 0 to tsCount - 1 do
        begin
          if FLyricCount >= Length(FLyrics) then
            SetLength(FLyrics, Max(32, Length(FLyrics) * 2));
          FLyrics[FLyricCount].TimestampMs := lineTimestamps[i];
          FLyrics[FLyricCount].Text := textPart;
          Inc(FLyricCount);
        end;
      end;
    end;
  end;

  // Insertion sort by TimestampMs
  for j := 1 to FLyricCount - 1 do
  begin
    tmpEntry := FLyrics[j];
    k := j - 1;
    while (k >= 0) and (FLyrics[k].TimestampMs > tmpEntry.TimestampMs) do
    begin
      FLyrics[k + 1] := FLyrics[k];
      Dec(k);
    end;
    FLyrics[k + 1] := tmpEntry;
  end;
end;

procedure TOmmRouter.LoadLyricsForTrack(Scheme: TURIScheme; const CleanTarget: string);
var
  lrcPath, rawLrc, searchQuery, tTitle, tArtist, canonLrc: string;
  f: File;
  fileSz: Int64;
  bytesRead, bytesWritten: SizeInt;
  lrcBuf: array[0..32767] of Byte;
  outLen: SizeUInt;
  i, mins, secs, csecs: Integer;
begin
  ClearLyrics;
  rawLrc := '';

  if Scheme = usLocalFile then
  begin
    lrcPath := ChangeFileExt(CleanTarget, '.lrc');
    if not FileExists(lrcPath) then
      lrcPath := ChangeFileExt(CleanTarget, '.LRC');
    if FileExists(lrcPath) then
    begin
      AssignFile(f, lrcPath);
      {$I-}
      FileMode := fmOpenRead;
      Reset(f, 1);
      {$I+}
      if IOResult = 0 then
      begin
        fileSz := FileSize(f);
        if (fileSz > 0) and (fileSz <= 65536) then
        begin
          SetLength(rawLrc, fileSz);
          BlockRead(f, rawLrc[1], fileSz, bytesRead);
          if bytesRead < fileSz then
            SetLength(rawLrc, bytesRead);
        end;
        CloseFile(f);
      end;
    end
    else if (FWatchdog <> nil) and (FWatchdog.State <> OMM_PLUGIN_UNLOADED) and (FPShm <> nil) then
    begin
      // If plugin is already awake, auto-resolve lyrics by Title + Artist and cache .lrc sidecar
      tTitle := Trim(StrPas(@FPShm^.TrackTitle[0]));
      tArtist := Trim(StrPas(@FPShm^.TrackArtist[0]));
      if tTitle <> '' then
      begin
        if tArtist <> '' then
          searchQuery := 'search://' + tTitle + ' ' + tArtist
        else
          searchQuery := 'search://' + tTitle;
        outLen := 0;
        FillChar(lrcBuf[0], SizeOf(lrcBuf), 0);
        if (FWatchdog.FetchLyrics(searchQuery, @lrcBuf[0], SizeOf(lrcBuf) - 1, outLen) = OMM_OK) and
           (outLen > 0) then
        begin
          if outLen >= SizeOf(lrcBuf) then
            outLen := SizeOf(lrcBuf) - 1;
          SetLength(rawLrc, outLen);
          Move(lrcBuf[0], rawLrc[1], outLen);
          lrcPath := ChangeFileExt(CleanTarget, '.lrc');
          AssignFile(f, lrcPath);
          {$I-}
          Rewrite(f, 1);
          {$I+}
          if IOResult = 0 then
          begin
            BlockWrite(f, rawLrc[1], Length(rawLrc), bytesWritten);
            CloseFile(f);
          end;
        end;
      end;
    end;
  end
  else if (Scheme = usMineralStream) and (FWatchdog <> nil) then
  begin
    outLen := 0;
    FillChar(lrcBuf[0], SizeOf(lrcBuf), 0);
    if (FWatchdog.FetchLyrics(CleanTarget, @lrcBuf[0], SizeOf(lrcBuf) - 1, outLen) = OMM_OK) and
       (outLen > 0) then
    begin
      if outLen >= SizeOf(lrcBuf) then
        outLen := SizeOf(lrcBuf) - 1;
      SetLength(rawLrc, outLen);
      Move(lrcBuf[0], rawLrc[1], outLen);
    end;
  end;

  if rawLrc <> '' then
    ParseLrcContent(rawLrc);

  if (FPShm <> nil) and (FLyricCount > 0) then
  begin
    canonLrc := '';
    for i := 0 to FLyricCount - 1 do
    begin
      mins := (FLyrics[i].TimestampMs div 1000) div 60;
      secs := (FLyrics[i].TimestampMs div 1000) mod 60;
      csecs := (FLyrics[i].TimestampMs mod 1000) div 10;
      canonLrc := canonLrc + Format('[%.2d:%.2d.%.2d]%s'#10, [mins, secs, csecs, FLyrics[i].Text]);
      if Length(canonLrc) >= SizeOf(FPShm^.LrcRawText) - 256 then
        Break;
    end;

    SeqLockWriteBegin(FPShm^.SeqLock);
    FPShm^.LrcLineCount := UInt32(FLyricCount);
    FPShm^.LrcTextLen := UInt32(Min(Length(canonLrc), SizeOf(FPShm^.LrcRawText) - 1));
    FillChar(FPShm^.LrcRawText[0], SizeOf(FPShm^.LrcRawText), 0);
    if FPShm^.LrcTextLen > 0 then
      Move(canonLrc[1], FPShm^.LrcRawText[0], FPShm^.LrcTextLen);
    Inc(FPShm^.LrcGeneration);
    SeqLockWriteEnd(FPShm^.SeqLock);
  end;

  SyncLyricsToSHM(omm_audio_get_position_ms(), True);
end;

procedure TOmmRouter.RefreshLyricsIfNeeded;
var
  scheme: TURIScheme;
  cleanTarget: string;
begin
  if (FLyricCount > 0) or (FCurrentURI = '') then Exit;
  scheme := ParseScheme(FCurrentURI, cleanTarget);
  if scheme <> usUnsupported then
    LoadLyricsForTrack(scheme, cleanTarget);
end;

procedure TOmmRouter.SyncLyricsToSHM(PosMs: UInt32; ForceUpdate: Boolean);
var
  idx, i: Integer;
  curStr, nextStr: string;
begin
  if FPShm = nil then Exit;

  if FLyricCount <= 0 then
  begin
    if ForceUpdate then
    begin
      SeqLockWriteBegin(FPShm^.SeqLock);
      FillChar(FPShm^.LyricCurrent[0], SizeOf(FPShm^.LyricCurrent), 0);
      FillChar(FPShm^.LyricNext[0], SizeOf(FPShm^.LyricNext), 0);
      FPShm^.LyricTimestampMs := 0;
      FPShm^.LyricLineIdx := 0;
      SeqLockWriteEnd(FPShm^.SeqLock);
    end;
    Exit;
  end;

  idx := 0;
  for i := 0 to FLyricCount - 1 do
  begin
    if FLyrics[i].TimestampMs <= PosMs then
      idx := i
    else
      Break;
  end;

  if (not ForceUpdate) and (idx = FLastLyricIdx) then
    Exit;

  FLastLyricIdx := idx;
  curStr := FLyrics[idx].Text;
  if idx + 1 < FLyricCount then
    nextStr := FLyrics[idx + 1].Text
  else
    nextStr := '';

  SeqLockWriteBegin(FPShm^.SeqLock);
  FPShm^.LyricLineIdx := UInt32(idx);
  FPShm^.LyricTimestampMs := FLyrics[idx].TimestampMs;
  FillChar(FPShm^.LyricCurrent[0], SizeOf(FPShm^.LyricCurrent), 0);
  if curStr <> '' then
    Move(curStr[1], FPShm^.LyricCurrent[0], Min(Length(curStr), SizeOf(FPShm^.LyricCurrent) - 1));
  FillChar(FPShm^.LyricNext[0], SizeOf(FPShm^.LyricNext), 0);
  if nextStr <> '' then
    Move(nextStr[1], FPShm^.LyricNext[0], Min(Length(nextStr), SizeOf(FPShm^.LyricNext) - 1));
  SeqLockWriteEnd(FPShm^.SeqLock);
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

    LoadLyricsForTrack(scheme, cleanTarget);
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

    LoadLyricsForTrack(scheme, cleanTarget);
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
  ClearLyrics;

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
  SyncLyricsToSHM(TargetMs, True);
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

      scheme := ParseScheme(FCurrentURI, cleanTarget);
      if scheme <> usUnsupported then
        LoadLyricsForTrack(scheme, cleanTarget);
    end
    else
    begin
      // Playback was stopped or interrupted
      FPrefetchActive := False;
      FPrefetchTrackID := 0;
      FPrefetchURI := '';
    end;
  end;

  // Synchronize LRC lyrics with current playback timestamp
  if omm_audio_get_state() = OMM_STATE_PLAYING then
  begin
    posMs := omm_audio_get_position_ms();
    SyncLyricsToSHM(posMs, False);
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
