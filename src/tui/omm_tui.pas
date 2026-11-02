program omm_tui;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Termio, SysUtils, Math,
  omm_ipc, omm_shm, omm_library;

const
  STDIN_FILENO  = 0;
  STDOUT_FILENO = 1;
  STDERR_FILENO = 2;

  APP_VERSION = '1.0.0';
  FRAME_INTERVAL_MS = 16; // ~60 FPS
  MAX_FRAME_BUF = 65536;

  // ANSI Escape Sequences
  CSI_ALT_SCREEN_ON  = #27'[?1049h';
  CSI_ALT_SCREEN_OFF = #27'[?1049l';
  CSI_CURSOR_HIDE    = #27'[?25l';
  CSI_CURSOR_SHOW    = #27'[?25h';
  CSI_HOME           = #27'[H';
  CSI_CLEAR_EOL      = #27'[K';
  CSI_CLEAR_ALL      = #27'[2J';
  CSI_RESET          = #27'[0m';
  CSI_BOLD           = #27'[1m';
  CSI_DIM            = #27'[2m';
  CSI_REVERSE        = #27'[7m';
  CSI_RED            = #27'[31m';
  CSI_GREEN          = #27'[32m';
  CSI_YELLOW         = #27'[33m';
  CSI_BLUE           = #27'[34m';
  CSI_MAGENTA        = #27'[35m';
  CSI_CYAN           = #27'[36m';
  CSI_WHITE          = #27'[37m';
  CSI_BOLD_WHITE     = #27'[1;37m';
  CSI_BOLD_CYAN      = #27'[1;36m';
  CSI_BOLD_GREEN     = #27'[1;32m';
  CSI_BOLD_YELLOW    = #27'[1;33m';
  CSI_BOLD_RED       = #27'[1;31m';

  // UTF-8 Spectrum sub-level glyphs (1/8 through 8/8)
  UTF8_BARS: array[0..8] of string = (
    ' ',
    #$E2#$96#$81, #$E2#$96#$82, #$E2#$96#$83, #$E2#$96#$84,
    #$E2#$96#$85, #$E2#$96#$86, #$E2#$96#$87, #$E2#$96#$88
  );
  UTF8_PEAK = #$E2#$96#$94; // ▔ (upper 1/8 bar)

type
  TFrameBuffer = record
    Data: array[0..MAX_FRAME_BUF - 1] of AnsiChar;
    Len: Integer;
  end;

  TTerminalState = record
    OrigTermios: TermIOS;
    RawTermios: TermIOS;
    IsTTY: Boolean;
    Rows: Word;
    Cols: Word;
  end;

  TLocalPlaybackSnapshot = record
    PlaybackState: UInt32;
    PlaybackFlags: UInt32;
    CurrentTrackID: UInt32;
    PositionMs: UInt32;
    DurationMs: UInt32;
    Volume: Single;
    PluginState: UInt32;
    PluginRssBytes: UInt64;
    UnderrunCounter: UInt32;
    TotalTracks: UInt32;
    TrackTitle: array[0..127] of AnsiChar;
    TrackArtist: array[0..127] of AnsiChar;
    TrackAlbum: array[0..127] of AnsiChar;
    LyricCurrent: array[0..255] of AnsiChar;
    LyricNext: array[0..255] of AnsiChar;
    QuantizedBars: array[0..63] of UInt8;
    QuantizedPeaks: array[0..63] of UInt8;
  end;

var
  GTerm: TTerminalState;
  GFrameBuf: TFrameBuffer;
  GSocketPath: string = OMM_DEFAULT_SOCKET_PATH;
  GShmPath: string = OMM_SHM_NAME;
  GLibraryFile: string = OMM_DEFAULT_LIBRARY_PATH;
  GAsciiMode: Boolean = False;
  GVerifyOnly: Boolean = False;
  GOnceOnly: Boolean = False;
  GTestTimeoutSec: Integer = 0;
  GTerminated: Boolean = False;
  GFilterActive: Boolean = False;
  GFilterBuf: array[0..127] of AnsiChar;
  GFilterLen: Integer = 0;
  GSelectedTrackIdx: Cardinal = 0;
  GViewportTopIdx: Cardinal = 0;
  GSeqCounter: UInt32 = 100;
  FSocketFD: cint = -1;
  FPShm: POMMSharedMemory = nil;
  FLibEngine: TOMMLibraryEngine = nil;
  GStartTick: Int64 = 0;

// =============================================================================
// Frame Buffer Zero-Heap Routines
// =============================================================================

procedure BufClear(var Buf: TFrameBuffer); inline;
begin
  Buf.Len := 0;
end;

procedure BufAppendPChar(var Buf: TFrameBuffer; P: PAnsiChar; MaxLen: Integer);
var
  len: Integer;
begin
  if (P = nil) or (MaxLen <= 0) then Exit;
  len := 0;
  while (len < MaxLen) and (P[len] <> #0) do
    Inc(len);
  if Buf.Len + len > MAX_FRAME_BUF then
    len := MAX_FRAME_BUF - Buf.Len;
  if len > 0 then
  begin
    Move(P[0], Buf.Data[Buf.Len], len);
    Inc(Buf.Len, len);
  end;
end;

procedure BufAppendStr(var Buf: TFrameBuffer; const S: string);
var
  len: Integer;
begin
  len := Length(S);
  if len = 0 then Exit;
  if Buf.Len + len > MAX_FRAME_BUF then
    len := MAX_FRAME_BUF - Buf.Len;
  if len > 0 then
  begin
    Move(S[1], Buf.Data[Buf.Len], len);
    Inc(Buf.Len, len);
  end;
end;

procedure BufAppendChar(var Buf: TFrameBuffer; C: AnsiChar); inline;
begin
  if Buf.Len < MAX_FRAME_BUF then
  begin
    Buf.Data[Buf.Len] := C;
    Inc(Buf.Len);
  end;
end;

procedure BufAppendSpaces(var Buf: TFrameBuffer; Count: Integer);
var
  i, n: Integer;
begin
  if Count <= 0 then Exit;
  n := Count;
  if Buf.Len + n > MAX_FRAME_BUF then
    n := MAX_FRAME_BUF - Buf.Len;
  for i := 0 to n - 1 do
    Buf.Data[Buf.Len + i] := ' ';
  Inc(Buf.Len, n);
end;

procedure BufAppendInt(var Buf: TFrameBuffer; Val: Int64; MinDigits: Integer = 1);
var
  tmp: array[0..31] of AnsiChar;
  pos, d, len: Integer;
  isNeg: Boolean;
  v: Int64;
begin
  if Val = 0 then
  begin
    for pos := 1 to Max(1, MinDigits) do
      BufAppendChar(Buf, '0');
    Exit;
  end;

  isNeg := (Val < 0);
  if isNeg then v := -Val else v := Val;

  pos := 0;
  while (v > 0) or (pos < MinDigits) do
  begin
    d := v mod 10;
    tmp[pos] := AnsiChar(Ord('0') + d);
    Inc(pos);
    v := v div 10;
  end;
  if isNeg then
  begin
    tmp[pos] := '-';
    Inc(pos);
  end;

  // Reverse copy
  len := pos;
  if Buf.Len + len > MAX_FRAME_BUF then
    len := MAX_FRAME_BUF - Buf.Len;
  for pos := 0 to len - 1 do
    Buf.Data[Buf.Len + pos] := tmp[len - 1 - pos];
  Inc(Buf.Len, len);
end;

procedure BufAppendTime(var Buf: TFrameBuffer; Ms: UInt32);
var
  totSec, m, s: UInt32;
begin
  totSec := Ms div 1000;
  m := totSec div 60;
  s := totSec mod 60;
  BufAppendInt(Buf, m, 2);
  BufAppendChar(Buf, ':');
  BufAppendInt(Buf, s, 2);
end;

procedure BufFlush(var Buf: TFrameBuffer);
begin
  if Buf.Len > 0 then
  begin
    fpWrite(STDOUT_FILENO, @Buf.Data[0], Buf.Len);
    Buf.Len := 0;
  end;
end;

// =============================================================================
// Terminal Setup and Teardown
// =============================================================================

procedure TermUpdateSize(var Term: TTerminalState);
var
  ws: TWinSize;
begin
  if Term.IsTTY and (FpIOCtl(STDOUT_FILENO, TIOCGWINSZ, @ws) = 0) and
     (ws.ws_row > 0) and (ws.ws_col > 0) then
  begin
    Term.Rows := ws.ws_row;
    Term.Cols := ws.ws_col;
  end
  else
  begin
    Term.Rows := 24;
    Term.Cols := 80;
  end;
end;

procedure TermInit(var Term: TTerminalState);
begin
  Term.IsTTY := (TCGetAttr(STDIN_FILENO, Term.OrigTermios) = 0);
  if Term.IsTTY then
  begin
    Term.RawTermios := Term.OrigTermios;
    CFMakeRaw(Term.RawTermios);
    // Non-blocking single byte read via fpPoll
    Term.RawTermios.c_cc[VMIN] := 0;
    Term.RawTermios.c_cc[VTIME] := 0;
    TCSetAttr(STDIN_FILENO, TCSANOW, Term.RawTermios);

    // Switch to alternate screen and hide cursor
    BufClear(GFrameBuf);
    BufAppendStr(GFrameBuf, CSI_ALT_SCREEN_ON + CSI_CURSOR_HIDE);
    BufFlush(GFrameBuf);
  end;
  TermUpdateSize(Term);
end;

procedure TermRestore(var Term: TTerminalState);
begin
  if Term.IsTTY then
  begin
    BufClear(GFrameBuf);
    BufAppendStr(GFrameBuf, CSI_CURSOR_SHOW + CSI_ALT_SCREEN_OFF + CSI_RESET);
    BufFlush(GFrameBuf);
    TCSetAttr(STDIN_FILENO, TCSANOW, Term.OrigTermios);
  end;
end;

// =============================================================================
// IPC & Shared Memory Client
// =============================================================================

function ConnectToDaemon: Boolean;
begin
  if FSocketFD >= 0 then
  begin
    fpClose(FSocketFD);
    FSocketFD := -1;
  end;
  FSocketFD := CreateUnixSocket;
  if FSocketFD < 0 then Exit(False);

  if ConnectUnixSocket(FSocketFD, GSocketPath) then
  begin
    SetSocketNonBlocking(FSocketFD);
    Result := True;
  end
  else
  begin
    fpClose(FSocketFD);
    FSocketFD := -1;
    Result := False;
  end;
end;

procedure DrainSocketReplies;
var
  drainBuf: array[0..1055] of Byte;
begin
  if FSocketFD < 0 then Exit;
  while fpRead(FSocketFD, @drainBuf[0], SizeOf(drainBuf)) > 0 do ;
end;

procedure SendCommand(Opcode: UInt16);
var
  pkt: TOMMPacket;
begin
  if FSocketFD < 0 then
    if not ConnectToDaemon then Exit;
  DrainSocketReplies;
  Inc(GSeqCounter);
  InitPacket(pkt, Opcode, GSeqCounter);
  SendPacket(FSocketFD, pkt);
end;

procedure SendPlayTrack(TrackID: UInt32);
var
  pkt: TOMMPacket;
begin
  if FSocketFD < 0 then
    if not ConnectToDaemon then Exit;
  DrainSocketReplies;
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_PLAY_TRACK_ID, GSeqCounter);
  pkt.Payload.TrackID := TrackID;
  SendPacket(FSocketFD, pkt);
end;

procedure SendSeek(TargetMs: UInt32);
var
  pkt: TOMMPacket;
begin
  if FSocketFD < 0 then
    if not ConnectToDaemon then Exit;
  DrainSocketReplies;
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_SEEK, GSeqCounter);
  pkt.Payload.TargetMs := TargetMs;
  SendPacket(FSocketFD, pkt);
end;

procedure SendSetVolume(Vol: Single);
var
  pkt: TOMMPacket;
begin
  if FSocketFD < 0 then
    if not ConnectToDaemon then Exit;
  DrainSocketReplies;
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_SET_VOLUME, GSeqCounter);
  pkt.Payload.Volume := Vol;
  SendPacket(FSocketFD, pkt);
end;

function ReadSHMSnapshot(pShm: POMMSharedMemory; out Snap: TLocalPlaybackSnapshot): Boolean;
var
  startSeq: UInt64;
  retries: Integer;
begin
  Result := False;
  if pShm = nil then Exit;
  if (pShm^.Magic <> OMM_SHM_MAGIC) or (pShm^.Version <> OMM_SHM_VERSION) then Exit;

  retries := 0;
  repeat
    startSeq := SeqLockReadBegin(pShm^.SeqLock);

    Snap.PlaybackState := pShm^.PlaybackState;
    Snap.PlaybackFlags := pShm^.PlaybackFlags;
    Snap.CurrentTrackID := pShm^.CurrentTrackID;
    Snap.PositionMs := pShm^.PositionMs;
    Snap.DurationMs := pShm^.DurationMs;
    Snap.Volume := pShm^.Volume;
    Snap.PluginState := pShm^.PluginState;
    Snap.PluginRssBytes := pShm^.PluginRssBytes;
    Snap.UnderrunCounter := pShm^.UnderrunCounter;
    Snap.TotalTracks := pShm^.TotalTracks;

    Move(pShm^.TrackTitle[0], Snap.TrackTitle[0], 128);
    Move(pShm^.TrackArtist[0], Snap.TrackArtist[0], 128);
    Move(pShm^.TrackAlbum[0], Snap.TrackAlbum[0], 128);
    Move(pShm^.LyricCurrent[0], Snap.LyricCurrent[0], 256);
    Move(pShm^.LyricNext[0], Snap.LyricNext[0], 256);
    Move(pShm^.QuantizedBars[0], Snap.QuantizedBars[0], 64);
    Move(pShm^.QuantizedPeaks[0], Snap.QuantizedPeaks[0], 64);

    Inc(retries);
    if not SeqLockReadRetry(pShm^.SeqLock, startSeq) then
      Exit(True);

    if retries > 8 then
    begin
      asm
        pause
      end;
    end;
  until retries >= 16;
end;

// =============================================================================
// Screen Rendering
// =============================================================================

procedure RenderSpectrumRow(var Buf: TFrameBuffer; const Snap: TLocalPlaybackSnapshot;
  Row: Integer; Width: Integer; AsciiMode: Boolean);
var
  b, numBands, bandIdx: Integer;
  barVal, peakVal: Integer;
  colorCode: string;
begin
  numBands := Min(64, Width - 4);
  if numBands < 10 then numBands := 10;

  // Vertical color gradient
  if Row >= 6 then colorCode := CSI_BOLD_RED
  else if Row >= 4 then colorCode := CSI_BOLD_YELLOW
  else if Row >= 2 then colorCode := CSI_CYAN
  else colorCode := CSI_GREEN;

  BufAppendStr(Buf, ' │ ' + colorCode);

  for b := 0 to numBands - 1 do
  begin
    bandIdx := (b * 64) div numBands;
    barVal := Snap.QuantizedBars[bandIdx];
    peakVal := Snap.QuantizedPeaks[bandIdx];

    if AsciiMode then
    begin
      if barVal >= (Row + 1) * 8 then
        BufAppendChar(Buf, '#')
      else if barVal > Row * 8 then
        BufAppendChar(Buf, '*')
      else if (peakVal >= Row * 8) and (peakVal < (Row + 1) * 8) then
        BufAppendChar(Buf, '-')
      else
        BufAppendChar(Buf, ' ');
    end
    else
    begin
      if barVal >= (Row + 1) * 8 then
        BufAppendStr(Buf, UTF8_BARS[8])
      else if barVal > Row * 8 then
        BufAppendStr(Buf, UTF8_BARS[barVal - Row * 8])
      else if (peakVal >= Row * 8) and (peakVal < (Row + 1) * 8) then
        BufAppendStr(Buf, CSI_BOLD_WHITE + UTF8_PEAK + colorCode)
      else
        BufAppendChar(Buf, ' ');
    end;
  end;

  BufAppendStr(Buf, CSI_RESET + ' │' + CSI_CLEAR_EOL + #10);
end;

procedure RenderProgressBar(var Buf: TFrameBuffer; PosMs, DurMs: UInt32; Width: Integer);
var
  barWidth, filled, i: Integer;
  pct: Integer;
begin
  barWidth := Max(10, Width - 32);
  if DurMs > 0 then
    pct := Min(100, (PosMs * 100) div DurMs)
  else
    pct := 0;

  filled := (pct * barWidth) div 100;
  BufAppendStr(Buf, ' [');
  BufAppendTime(Buf, PosMs);
  BufAppendStr(Buf, ' / ');
  BufAppendTime(Buf, DurMs);
  BufAppendStr(Buf, '] [');
  BufAppendStr(Buf, CSI_BOLD_CYAN);
  for i := 0 to filled - 1 do
    BufAppendChar(Buf, '=');
  BufAppendStr(Buf, CSI_RESET);
  for i := filled to barWidth - 1 do
    BufAppendChar(Buf, '-');
  BufAppendStr(Buf, '] ');
  BufAppendInt(Buf, pct, 2);
  BufAppendStr(Buf, '%' + CSI_CLEAR_EOL + #10);
end;

procedure RenderVolumeBar(var Buf: TFrameBuffer; Vol: Single);
var
  volPct, filled, i: Integer;
begin
  volPct := Round(Vol * 100.0);
  if volPct < 0 then volPct := 0;
  if volPct > 100 then volPct := 100;
  filled := volPct div 10;

  BufAppendStr(Buf, 'Vol: [');
  BufAppendStr(Buf, CSI_BOLD_GREEN);
  for i := 0 to filled - 1 do
    BufAppendChar(Buf, '#');
  BufAppendStr(Buf, CSI_RESET);
  for i := filled to 9 do
    BufAppendChar(Buf, '-');
  BufAppendStr(Buf, '] ');
  BufAppendInt(Buf, volPct, 3);
  BufAppendChar(Buf, '%');
end;

procedure RenderFrame(const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  cols, rows, maxLibRows, r: Integer;
  pRec: POMMTrackRecord;
  tCount, trackIdx: Cardinal;
  stateStr, pluginStr: string;
begin
  BufClear(GFrameBuf);
  BufAppendStr(GFrameBuf, CSI_HOME);

  cols := GTerm.Cols;
  rows := GTerm.Rows;

  // Header line
  BufAppendStr(GFrameBuf, CSI_BOLD_CYAN + '┌── Oh-Mini-Mineral Stateless Terminal Client v' + APP_VERSION + ' ──');
  BufAppendSpaces(GFrameBuf, Max(0, cols - 56));
  BufAppendStr(GFrameBuf, '[SHM 60 FPS] ──┐' + CSI_RESET + CSI_CLEAR_EOL + #10);

  // Track metadata
  BufAppendStr(GFrameBuf, '│ Title : ' + CSI_BOLD_WHITE);
  if Snap.TrackTitle[0] <> #0 then
    BufAppendPChar(GFrameBuf, @Snap.TrackTitle[0], 128)
  else
    BufAppendStr(GFrameBuf, 'No track active');
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + #10);

  BufAppendStr(GFrameBuf, '│ Artist: ' + CSI_CYAN);
  if Snap.TrackArtist[0] <> #0 then
    BufAppendPChar(GFrameBuf, @Snap.TrackArtist[0], 96)
  else
    BufAppendStr(GFrameBuf, 'Unknown Artist');
  BufAppendStr(GFrameBuf, CSI_RESET + '  Album: ' + CSI_YELLOW);
  if Snap.TrackAlbum[0] <> #0 then
    BufAppendPChar(GFrameBuf, @Snap.TrackAlbum[0], 96)
  else
    BufAppendStr(GFrameBuf, 'Unknown Album');
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + #10);

  // Progress Bar
  BufAppendStr(GFrameBuf, '│');
  RenderProgressBar(GFrameBuf, Snap.PositionMs, Snap.DurationMs, cols);

  // Status and State Line
  case Snap.PlaybackState of
    0: stateStr := 'STOPPED';
    1: stateStr := 'PLAYING';
    2: stateStr := 'PAUSED';
    3: stateStr := 'BUFFERING';
    else stateStr := 'IDLE';
  end;

  case Snap.PluginState of
    OMM_PLUGIN_UNLOADED:    pluginStr := 'Unloaded (0 MB)';
    OMM_PLUGIN_LAZY_WAKEUP: pluginStr := 'Wakeup';
    OMM_PLUGIN_ACTIVE:      pluginStr := 'Active (' + FloatToStrF(Snap.PluginRssBytes / 1048576.0, ffFixed, 4, 1) + ' MB)';
    OMM_PLUGIN_SUSPENDED:   pluginStr := 'Suspended (<0.3 MB)';
    OMM_PLUGIN_DEEP_UNLOAD: pluginStr := 'Deep Unload';
    else pluginStr := 'None';
  end;

  BufAppendStr(GFrameBuf, '│ State: [' + CSI_BOLD + stateStr + CSI_RESET + ']   ');
  RenderVolumeBar(GFrameBuf, Snap.Volume);
  BufAppendStr(GFrameBuf, '   Plugin: [' + CSI_CYAN + pluginStr + CSI_RESET + ']');
  BufAppendStr(GFrameBuf, CSI_CLEAR_EOL + #10);

  // 64-Band Real-Time Spectrum
  BufAppendStr(GFrameBuf, '├────── 64-Band Real-Time Spectrum ────────────────────────────────────────────┤' + CSI_CLEAR_EOL + #10);
  for r := 7 downto 0 do
    RenderSpectrumRow(GFrameBuf, Snap, r, cols, GAsciiMode);

  // Synchronized Lyrics Panel
  BufAppendStr(GFrameBuf, '├────── Synchronized Lyrics ───────────────────────────────────────────────────┤' + CSI_CLEAR_EOL + #10);
  BufAppendStr(GFrameBuf, '│ ♪ ' + CSI_BOLD_WHITE);
  if Snap.LyricCurrent[0] <> #0 then
    BufAppendPChar(GFrameBuf, @Snap.LyricCurrent[0], 255)
  else
    BufAppendStr(GFrameBuf, '(...)');
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + #10);

  BufAppendStr(GFrameBuf, '│   ' + CSI_DIM);
  if Snap.LyricNext[0] <> #0 then
    BufAppendPChar(GFrameBuf, @Snap.LyricNext[0], 255);
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + #10);

  // Viewport Tracks
  BufAppendStr(GFrameBuf, '├────── Library Viewport ──────────────────────────────────────────────────────┤' + CSI_CLEAR_EOL + #10);

  tCount := 0;
  if Lib <> nil then tCount := Lib.TrackCount;

  maxLibRows := Max(3, rows - 20);
  if GSelectedTrackIdx >= GViewportTopIdx + Cardinal(maxLibRows) then
    GViewportTopIdx := GSelectedTrackIdx - Cardinal(maxLibRows) + 1;
  if GSelectedTrackIdx < GViewportTopIdx then
    GViewportTopIdx := GSelectedTrackIdx;

  if (Lib = nil) or (tCount = 0) then
  begin
    BufAppendStr(GFrameBuf, '│ [No library.bin found — press ' + CSI_BOLD_YELLOW + '''r''' + CSI_RESET + ' to trigger daemon rescan]' + CSI_CLEAR_EOL + #10);
    for r := 1 to maxLibRows - 1 do
      BufAppendStr(GFrameBuf, '│' + CSI_CLEAR_EOL + #10);
  end
  else
  begin
    for r := 0 to maxLibRows - 1 do
    begin
      trackIdx := GViewportTopIdx + Cardinal(r);
      if trackIdx < tCount then
      begin
        pRec := Lib.GetRecordByIndex(trackIdx);
        if trackIdx = GSelectedTrackIdx then
        begin
          BufAppendStr(GFrameBuf, '│ ' + CSI_REVERSE + CSI_BOLD_CYAN + '> ');
          BufAppendInt(GFrameBuf, pRec^.TrackID, 4);
          BufAppendStr(GFrameBuf, '. ');
          BufAppendPChar(GFrameBuf, @pRec^.Title[0], 30);
          BufAppendSpaces(GFrameBuf, Max(1, 32 - StrLen(pRec^.Title)));
          BufAppendPChar(GFrameBuf, @pRec^.Artist[0], 20);
          BufAppendSpaces(GFrameBuf, Max(1, 22 - StrLen(pRec^.Artist)));
          BufAppendTime(GFrameBuf, pRec^.DurationMs);
          BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + #10);
        end
        else
        begin
          BufAppendStr(GFrameBuf, '│   ');
          BufAppendInt(GFrameBuf, pRec^.TrackID, 4);
          BufAppendStr(GFrameBuf, '. ');
          BufAppendPChar(GFrameBuf, @pRec^.Title[0], 30);
          BufAppendSpaces(GFrameBuf, Max(1, 32 - StrLen(pRec^.Title)));
          BufAppendStr(GFrameBuf, CSI_DIM);
          BufAppendPChar(GFrameBuf, @pRec^.Artist[0], 20);
          BufAppendStr(GFrameBuf, CSI_RESET);
          BufAppendSpaces(GFrameBuf, Max(1, 22 - StrLen(pRec^.Artist)));
          BufAppendTime(GFrameBuf, pRec^.DurationMs);
          BufAppendStr(GFrameBuf, CSI_CLEAR_EOL + #10);
        end;
      end
      else
        BufAppendStr(GFrameBuf, '│' + CSI_CLEAR_EOL + #10);
    end;
  end;

  // Controls Footer
  BufAppendStr(GFrameBuf, '├──────────────────────────────────────────────────────────────────────────────┤' + CSI_CLEAR_EOL + #10);
  if GFilterActive then
  begin
    BufAppendStr(GFrameBuf, '│ Search: ' + CSI_BOLD_YELLOW + StrPas(@GFilterBuf[0]) + '_' + CSI_RESET + ' [Enter/Esc]' + CSI_CLEAR_EOL + #10);
  end
  else
  begin
    BufAppendStr(GFrameBuf, '│ [Space] Play/Pause [s] Stop [Enter] Play Track [←/→] Seek [↑/↓] Vol' + CSI_CLEAR_EOL + #10);
    BufAppendStr(GFrameBuf, '│ [j/k] Navigate [/] Filter [r] Rescan [w] Wake [z] Suspend [q] Quit' + CSI_CLEAR_EOL + #10);
  end;
  BufAppendStr(GFrameBuf, '└──────────────────────────────────────────────────────────────────────────────┘' + CSI_CLEAR_EOL);

  BufFlush(GFrameBuf);
end;

// =============================================================================
// Input Processing
// =============================================================================

procedure ProcessKey(Key: Char; const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  tCount: Cardinal;
begin
  tCount := 0;
  if Lib <> nil then tCount := Lib.TrackCount;

  if GFilterActive then
  begin
    if (Key = #13) or (Key = #27) then // Enter or Esc closes search
    begin
      GFilterActive := False;
    end
    else if (Key = #8) or (Key = #127) then // Backspace
    begin
      if GFilterLen > 0 then
      begin
        Dec(GFilterLen);
        GFilterBuf[GFilterLen] := #0;
      end;
    end
    else if (Key >= ' ') and (Key <= '~') and (GFilterLen < 125) then
    begin
      GFilterBuf[GFilterLen] := Key;
      Inc(GFilterLen);
      GFilterBuf[GFilterLen] := #0;
    end;
    Exit;
  end;

  case Key of
    'q', 'Q', #3: // Quit
      GTerminated := True;

    ' ': // Play/Pause toggle
    begin
      if Snap.PlaybackState = 1 then
        SendCommand(OP_REQ_PAUSE)
      else if Snap.PlaybackState = 2 then
        SendCommand(OP_REQ_RESUME)
      else
        SendCommand(OP_REQ_PLAY);
    end;

    's', 'S': // Stop
      SendCommand(OP_REQ_STOP);

    #13: // Enter: Play highlighted track
    begin
      if (Lib <> nil) and (tCount > 0) and (GSelectedTrackIdx < tCount) then
      begin
        if Lib.GetRecordByIndex(GSelectedTrackIdx) <> nil then
          SendPlayTrack(Lib.GetRecordByIndex(GSelectedTrackIdx)^.TrackID)
        else
          SendPlayTrack(GSelectedTrackIdx + 1);
      end;
    end;

    'j', 'B': // Down
    begin
      if (tCount > 0) and (GSelectedTrackIdx < tCount - 1) then
        Inc(GSelectedTrackIdx);
    end;

    'k', 'A': // Up
    begin
      if GSelectedTrackIdx > 0 then
        Dec(GSelectedTrackIdx);
    end;

    'h', 'D': // Seek backward 5s
    begin
      if Snap.PositionMs > 5000 then
        SendSeek(Snap.PositionMs - 5000)
      else
        SendSeek(0);
    end;

    'l', 'C': // Seek forward 5s
    begin
      if Snap.DurationMs > Snap.PositionMs + 5000 then
        SendSeek(Snap.PositionMs + 5000)
      else if Snap.DurationMs > 0 then
        SendSeek(Snap.DurationMs);
    end;

    '+', '=': // Volume up 5%
    begin
      SendSetVolume(Min(1.0, Snap.Volume + 0.05));
    end;

    '-', '_': // Volume down 5%
    begin
      SendSetVolume(Max(0.0, Snap.Volume - 0.05));
    end;

    'r', 'R': // Rescan
      SendCommand(OP_REQ_RESCAN_LIBRARY);

    'w', 'W': // Wake plugin
      SendCommand(OP_REQ_PLUGIN_WAKE);

    'z', 'Z': // Suspend plugin
      SendCommand(OP_REQ_PLUGIN_SUSPEND);

    '/': // Search filter
    begin
      GFilterActive := True;
      GFilterLen := 0;
      GFilterBuf[0] := #0;
    end;
  end;
end;

procedure HandleInput(const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  ch: AnsiChar;
  seq: array[0..3] of AnsiChar;
  n: ssize_t;
begin
  n := fpRead(STDIN_FILENO, @ch, 1);
  while n > 0 do
  begin
    if ch = #27 then // Escape sequence
    begin
      n := fpRead(STDIN_FILENO, @seq[0], 2);
      if n = 2 then
      begin
        if seq[0] = '[' then
        begin
          case seq[1] of
            'A': ProcessKey('A', Snap, Lib); // Up
            'B': ProcessKey('B', Snap, Lib); // Down
            'C': ProcessKey('C', Snap, Lib); // Right
            'D': ProcessKey('D', Snap, Lib); // Left
            '5': // Page Up
            begin
              fpRead(STDIN_FILENO, @seq[2], 1); // consume ~
              if GSelectedTrackIdx > 10 then Dec(GSelectedTrackIdx, 10) else GSelectedTrackIdx := 0;
            end;
            '6': // Page Down
            begin
              fpRead(STDIN_FILENO, @seq[2], 1); // consume ~
              if (Lib <> nil) and (GSelectedTrackIdx + 10 < Lib.TrackCount) then
                Inc(GSelectedTrackIdx, 10)
              else if (Lib <> nil) and (Lib.TrackCount > 0) then
                GSelectedTrackIdx := Lib.TrackCount - 1
              else
                GSelectedTrackIdx := 0;
            end;
          end;
        end;
      end
      else
        ProcessKey(#27, Snap, Lib);
    end
    else
      ProcessKey(ch, Snap, Lib);

    n := fpRead(STDIN_FILENO, @ch, 1);
  end;
end;

// =============================================================================
// Command-Line Parsing
// =============================================================================

procedure ParseCommandLine;
var
  i: Integer;
  arg: string;
begin
  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if (arg = '--socket') and (i < ParamCount) then
    begin
      Inc(i);
      GSocketPath := ParamStr(i);
    end
    else if (arg = '--shm') and (i < ParamCount) then
    begin
      Inc(i);
      GShmPath := ParamStr(i);
    end
    else if (arg = '--library') and (i < ParamCount) then
    begin
      Inc(i);
      GLibraryFile := ParamStr(i);
    end
    else if arg = '--ascii' then
      GAsciiMode := True
    else if arg = '--verify' then
      GVerifyOnly := True
    else if arg = '--once' then
      GOnceOnly := True
    else if (arg = '--test-timeout') and (i < ParamCount) then
    begin
      Inc(i);
      GTestTimeoutSec := StrToIntDef(ParamStr(i), 2);
    end;
    Inc(i);
  end;
end;

// =============================================================================
// Headless / Verification Routine
// =============================================================================

function RunVerification: Integer;
var
  snap: TLocalPlaybackSnapshot;
  connOk, shmOk: Boolean;
begin
  Writeln('=== OMM Stateless Terminal Client Verification ===');

  // Check socket
  connOk := ConnectToDaemon;
  if connOk then
    Writeln('  [PASS] IPC Socket connected at: ', GSocketPath)
  else
    Writeln('  [WARN] Daemon socket not found at: ', GSocketPath);

  // Check SHM
  FPShm := OpenSharedMemory(GShmPath, True);
  shmOk := (FPShm <> nil) and (FPShm^.Magic = OMM_SHM_MAGIC);
  if shmOk then
  begin
    Writeln('  [PASS] Shared memory segment mapped: ', GShmPath);
    if ReadSHMSnapshot(FPShm, snap) then
      Writeln('  [PASS] Atomic Seqlock read succeeded (Tracks: ', snap.TotalTracks, ')')
    else
      Writeln('  [FAIL] Seqlock read contention');
  end
  else
    Writeln('  [WARN] Shared memory not available at: ', GShmPath);

  Writeln('Verification complete.');
  Result := 0;
end;

// =============================================================================
// Main Program
// =============================================================================

var
  snap: TLocalPlaybackSnapshot;
  pollFds: array[0..1] of TPollFD;
  lastTick, nowTick, sleepMs: Int64;
  pipeBuf: array[0..255] of AnsiChar;
  pipeRead: ssize_t;

begin
  ParseCommandLine;

  if GVerifyOnly then
  begin
    Halt(RunVerification);
  end;

  GStartTick := GetTickCount64;

  // Open shared memory
  FPShm := OpenSharedMemory(GShmPath, True);

  // Connect to IPC socket
  ConnectToDaemon;

  // Open library engine
  FLibEngine := TOMMLibraryEngine.Create('', GLibraryFile);
  FLibEngine.OpenLibrary;

  // Initialize Terminal
  TermInit(GTerm);

  // If non-TTY piped mode, check if stdin already has 'q' or EOF
  if not GTerm.IsTTY then
  begin
    pipeRead := fpRead(STDIN_FILENO, @pipeBuf[0], SizeOf(pipeBuf));
    if (pipeRead <= 0) or (pipeBuf[0] = 'q') or (pipeBuf[0] = 'Q') then
    begin
      // Immediate clean exit on piped 'q' or EOF
      TermRestore(GTerm);
      if FLibEngine <> nil then FLibEngine.Free;
      if FPShm <> nil then CloseSharedMemory(FPShm);
      if FSocketFD >= 0 then fpClose(FSocketFD);
      Halt(0);
    end;
  end;

  if GOnceOnly then
  begin
    FillChar(snap, SizeOf(snap), 0);
    if FPShm <> nil then ReadSHMSnapshot(FPShm, snap);
    RenderFrame(snap, FLibEngine);
    TermRestore(GTerm);
    if FLibEngine <> nil then FLibEngine.Free;
    if FPShm <> nil then CloseSharedMemory(FPShm);
    if FSocketFD >= 0 then fpClose(FSocketFD);
    Halt(0);
  end;

  lastTick := GetTickCount64;

  // Main 60 FPS Event Loop (adaptive idle sleep when paused/stopped)
  while not GTerminated do
  begin
    nowTick := GetTickCount64;

    // Timeout check
    if (GTestTimeoutSec > 0) and (nowTick - GStartTick >= Int64(GTestTimeoutSec) * 1000) then
      Break;

    if (FLibEngine <> nil) and ((nowTick - GStartTick) mod 2000 < FRAME_INTERVAL_MS * 2) then
      FLibEngine.EnsureFresh;

    // Read SHM snapshot
    FillChar(snap, SizeOf(snap), 0);
    if FPShm <> nil then
      ReadSHMSnapshot(FPShm, snap)
    else
    begin
      FPShm := OpenSharedMemory(GShmPath, True);
      if FPShm <> nil then ReadSHMSnapshot(FPShm, snap);
    end;

    // Render frame
    TermUpdateSize(GTerm);
    RenderFrame(snap, FLibEngine);

    // Calculate sleep to maintain ~60 FPS when playing, or ~12 FPS when idle/paused
    nowTick := GetTickCount64;
    if snap.PlaybackState = 1 then
      sleepMs := FRAME_INTERVAL_MS - (nowTick - lastTick)
    else
      sleepMs := 80;
    if sleepMs < 1 then sleepMs := 1;
    if (snap.PlaybackState = 1) and (sleepMs > FRAME_INTERVAL_MS) then sleepMs := FRAME_INTERVAL_MS;

    // Non-blocking poll on stdin
    pollFds[0].fd := STDIN_FILENO;
    pollFds[0].events := POLLIN;
    pollFds[0].revents := 0;

    if fpPoll(@pollFds[0], 1, sleepMs) > 0 then
    begin
      if (pollFds[0].revents and POLLIN) <> 0 then
      begin
        HandleInput(snap, FLibEngine);
      end;
      if (pollFds[0].revents and (POLLHUP or POLLERR)) <> 0 then
      begin
        // Stdin pipe closed
        Break;
      end;
    end;

    lastTick := GetTickCount64;
  end;

  // Cleanup
  TermRestore(GTerm);
  if FLibEngine <> nil then
  begin
    FLibEngine.Free;
    FLibEngine := nil;
  end;
  if FPShm <> nil then
  begin
    CloseSharedMemory(FPShm);
    FPShm := nil;
  end;
  if FSocketFD >= 0 then
  begin
    fpClose(FSocketFD);
    FSocketFD := -1;
  end;
end.
