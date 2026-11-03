program omm_tui;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  {$IFDEF UNIX}BaseUnix, Unix, Termio,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  ctypes, SysUtils, Math,
  omm_os, omm_ipc, omm_shm, omm_library;

const
  {$IFDEF UNIX}
  STDIN_FILENO  = 0;
  STDOUT_FILENO = 1;
  STDERR_FILENO = 2;
  {$ENDIF}

  APP_VERSION = '1.0.0';
  FRAME_INTERVAL_MS = 16; // ~60 FPS
  MAX_FRAME_BUF = 65536;

  // ANSI Escape Sequences
  CSI_ALT_SCREEN_ON  = #27'[?1049h';
  CSI_ALT_SCREEN_OFF = #27'[?1049l';
  CSI_AUTOWRAP_OFF   = #27'[?7l';
  CSI_AUTOWRAP_ON    = #27'[?7h';
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
    {$IFDEF UNIX}
    OrigTermios: TermIOS;
    RawTermios: TermIOS;
    {$ENDIF}
    {$IFDEF WINDOWS}
    OrigInMode: DWORD;
    OrigOutMode: DWORD;
    {$ENDIF}
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

  TInputMode = (imNone, imLocalFilter, imOnlineSearch);
  TVirtualKey = (vkNone, vkUp, vkDown, vkLeft, vkRight, vkPgUp, vkPgDn, vkHome, vkEnd, vkDelete);

const
  MAX_ONLINE_TRACKS = 256;
  MAX_FILTERED_TRACKS = 65536;

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
  GInputMode: TInputMode = imNone;
  GFilterBuf: array[0..127] of AnsiChar;
  GFilterLen: Integer = 0;
  GSearchBuf: array[0..127] of AnsiChar;
  GSearchLen: Integer = 0;
  GSourceIdx: Integer = 0; // 0=Local, 1=NetEase, 2=Bilibili, 3=AppleMusic, 4=QQMusic
  GIsOnlineMode: Boolean = False;
  GOnlineSearching: Boolean = False;
  GOnlineTracks: array[0..MAX_ONLINE_TRACKS - 1] of TOMMCondensedTrack;
  GOnlineTrackCount: Cardinal = 0;
  GFilteredIndices: array of Cardinal;
  GFilteredCount: Cardinal = 0;
  GSelectedTrackIdx: Cardinal = 0;
  GViewportTopIdx: Cardinal = 0;
  GLastPlayedOnlineIdx: Integer = -1;
  GStatusMsg: string = '';
  GStatusExpireTick: Int64 = 0;
  GSeqCounter: UInt32 = 100;
  FSocketFD: cint = -1;
  FPShm: POMMSharedMemory = nil;
  FLibEngine: TOMMLibraryEngine = nil;
  GStartTick: Int64 = 0;

// =============================================================================
// Frame Buffer & UTF-8 Display Column Routines (Zero-Truncation, Zero-Heap)
// =============================================================================

procedure BufClear(var Buf: TFrameBuffer); inline;
begin
  Buf.Len := 0;
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

function IsWideCodePoint(cp: Cardinal): Boolean; inline;
begin
  Result := (cp >= $1100) and (
    (cp <= $115F) or
    (cp = $2329) or (cp = $232A) or
    ((cp >= $2E80) and (cp <= $A4CF) and (cp <> $303F)) or
    ((cp >= $AC00) and (cp <= $D7A3)) or
    ((cp >= $F900) and (cp <= $FAFF)) or
    ((cp >= $FE10) and (cp <= $FE6F)) or
    ((cp >= $FF00) and (cp <= $FF60)) or
    ((cp >= $FFE0) and (cp <= $FFE6)) or
    (cp >= $1F000)
  );
end;

function DecodeUtf8At(P: PAnsiChar; Idx, MaxBytes: Integer; out SeqLen, ColWidth: Integer): Boolean;
var
  b0, b1, b2, b3, cp: Cardinal;
begin
  Result := False;
  SeqLen := 1;
  ColWidth := 0;
  if (P = nil) or (Idx >= MaxBytes) or (P[Idx] = #0) then Exit;

  b0 := Ord(P[Idx]);
  if b0 < $80 then
  begin
    SeqLen := 1;
    ColWidth := 1;
    Result := True;
  end
  else if (b0 and $E0) = $C0 then
  begin
    if (Idx + 2 <= MaxBytes) and (P[Idx + 1] <> #0) and ((Ord(P[Idx + 1]) and $C0) = $80) then
    begin
      SeqLen := 2;
      ColWidth := 1;
      Result := True;
    end;
  end
  else if (b0 and $F0) = $E0 then
  begin
    if (Idx + 3 <= MaxBytes) and
       (P[Idx + 1] <> #0) and ((Ord(P[Idx + 1]) and $C0) = $80) and
       (P[Idx + 2] <> #0) and ((Ord(P[Idx + 2]) and $C0) = $80) then
    begin
      b1 := Ord(P[Idx + 1]) and $3F;
      b2 := Ord(P[Idx + 2]) and $3F;
      cp := ((b0 and $0F) shl 12) or (b1 shl 6) or b2;
      SeqLen := 3;
      if IsWideCodePoint(cp) then ColWidth := 2 else ColWidth := 1;
      Result := True;
    end;
  end
  else if (b0 and $F8) = $F0 then
  begin
    if (Idx + 4 <= MaxBytes) and
       (P[Idx + 1] <> #0) and ((Ord(P[Idx + 1]) and $C0) = $80) and
       (P[Idx + 2] <> #0) and ((Ord(P[Idx + 2]) and $C0) = $80) and
       (P[Idx + 3] <> #0) and ((Ord(P[Idx + 3]) and $C0) = $80) then
    begin
      b1 := Ord(P[Idx + 1]) and $3F;
      b2 := Ord(P[Idx + 2]) and $3F;
      b3 := Ord(P[Idx + 3]) and $3F;
      cp := ((b0 and $07) shl 18) or (b1 shl 12) or (b2 shl 6) or b3;
      SeqLen := 4;
      if IsWideCodePoint(cp) then ColWidth := 2 else ColWidth := 1;
      Result := True;
    end;
  end;
end;

function Utf8DisplayCols(const S: string): Integer;
var
  idx, maxB, seqLen, colW: Integer;
begin
  Result := 0;
  maxB := Length(S);
  if maxB = 0 then Exit;
  idx := 0;
  while idx < maxB do
  begin
    if DecodeUtf8At(PAnsiChar(S), idx, maxB, seqLen, colW) then
    begin
      Inc(Result, colW);
      Inc(idx, seqLen);
    end
    else
      Inc(idx);
  end;
end;

procedure BufAppendUtf8Cols(var Buf: TFrameBuffer; P: PAnsiChar; MaxBytes, MaxCols: Integer);
var
  idx, usedCols, seqLen, colW: Integer;
begin
  if (P = nil) or (MaxBytes <= 0) or (MaxCols <= 0) then Exit;
  idx := 0;
  usedCols := 0;
  while (idx < MaxBytes) and (P[idx] <> #0) do
  begin
    if DecodeUtf8At(P, idx, MaxBytes, seqLen, colW) then
    begin
      if usedCols + colW > MaxCols then
        Break;
      if Buf.Len + seqLen > MAX_FRAME_BUF then
        Break;
      if (seqLen = 1) and (Ord(P[idx]) < 32) then
        BufAppendChar(Buf, ' ')
      else
      begin
        Move(P[idx], Buf.Data[Buf.Len], seqLen);
        Inc(Buf.Len, seqLen);
      end;
      Inc(usedCols, colW);
      Inc(idx, seqLen);
    end
    else
    begin
      // Skip invalid or truncated trailing UTF-8 byte without emitting broken sequence
      Inc(idx);
    end;
  end;
end;

procedure BufAppendPChar(var Buf: TFrameBuffer; P: PAnsiChar; MaxCols: Integer);
begin
  BufAppendUtf8Cols(Buf, P, 256, MaxCols);
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
{$IFDEF UNIX}
var
  ws: TWinSize;
{$ENDIF}
{$IFDEF WINDOWS}
var
  csbi: CONSOLE_SCREEN_BUFFER_INFO;
{$ENDIF}
begin
  {$IFDEF UNIX}
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
  {$ENDIF}
  {$IFDEF WINDOWS}
  if Term.IsTTY and GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), csbi) and
     (csbi.srWindow.Right >= csbi.srWindow.Left) and (csbi.srWindow.Bottom >= csbi.srWindow.Top) then
  begin
    Term.Cols := Word(csbi.srWindow.Right - csbi.srWindow.Left + 1);
    Term.Rows := Word(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
  end
  else
  begin
    Term.Rows := 24;
    Term.Cols := 80;
  end;
  {$ENDIF}
end;

procedure TermInit(var Term: TTerminalState);
{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;
  ENABLE_VIRTUAL_TERMINAL_INPUT      = $0200;
var
  hIn, hOut: THandle;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Term.IsTTY := (TCGetAttr(STDIN_FILENO, Term.OrigTermios) = 0);
  if Term.IsTTY then
  begin
    Term.RawTermios := Term.OrigTermios;
    CFMakeRaw(Term.RawTermios);
    // Keep output post-processing (ONLCR) enabled so LF never staircase-steps
    Term.RawTermios.c_oflag := Term.OrigTermios.c_oflag;
    // Non-blocking single byte read via fpPoll
    Term.RawTermios.c_cc[VMIN] := 0;
    Term.RawTermios.c_cc[VTIME] := 0;
    TCSetAttr(STDIN_FILENO, TCSANOW, Term.RawTermios);

    // Switch to alternate screen, disable line wrap (DECAWM), clear, and hide cursor
    BufClear(GFrameBuf);
    BufAppendStr(GFrameBuf, CSI_ALT_SCREEN_ON + CSI_AUTOWRAP_OFF + CSI_CLEAR_ALL + CSI_HOME + CSI_CURSOR_HIDE);
    BufFlush(GFrameBuf);
  end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  hIn := GetStdHandle(STD_INPUT_HANDLE);
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  Term.OrigInMode := 0;
  Term.OrigOutMode := 0;
  Term.IsTTY := GetConsoleMode(hIn, Term.OrigInMode) and GetConsoleMode(hOut, Term.OrigOutMode);
  if Term.IsTTY then
  begin
    SetConsoleOutputCP(65001);
    SetConsoleCP(65001);
    SetConsoleMode(hOut, Term.OrigOutMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    SetConsoleMode(hIn, (Term.OrigInMode and (not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT))) or ENABLE_VIRTUAL_TERMINAL_INPUT);
    BufClear(GFrameBuf);
    BufAppendStr(GFrameBuf, CSI_ALT_SCREEN_ON + CSI_AUTOWRAP_OFF + CSI_CLEAR_ALL + CSI_HOME + CSI_CURSOR_HIDE);
    BufFlush(GFrameBuf);
  end;
  {$ENDIF}
  TermUpdateSize(Term);
end;

procedure TermRestore(var Term: TTerminalState);
begin
  if Term.IsTTY then
  begin
    BufClear(GFrameBuf);
    BufAppendStr(GFrameBuf, CSI_CURSOR_SHOW + CSI_AUTOWRAP_ON + CSI_ALT_SCREEN_OFF + CSI_RESET);
    BufFlush(GFrameBuf);
    {$IFDEF UNIX}
    TCSetAttr(STDIN_FILENO, TCSANOW, Term.OrigTermios);
    {$ENDIF}
    {$IFDEF WINDOWS}
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), Term.OrigInMode);
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), Term.OrigOutMode);
    {$ENDIF}
  end;
end;

procedure SetStatusMessage(const Msg: string; DurationMs: Int64 = 4000);
begin
  GStatusMsg := Msg;
  GStatusExpireTick := GetTickCount64 + DurationMs;
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

function GetSourceLabel(ASourceIdx: Integer): string;
begin
  case ASourceIdx of
    1: Result := 'NetEase Cloud (WY)';
    2: Result := 'Bilibili Audio (BILI)';
    3: Result := 'Apple Music (AM)';
    4: Result := 'QQ Music (QQ)';
    else Result := 'Local Library';
  end;
end;

function GetSourcePrefix(ASourceIdx: Integer): string;
begin
  case ASourceIdx of
    1: Result := 'netease:';
    2: Result := 'bilibili:';
    3: Result := 'am:';
    4: Result := 'qq:';
    else Result := '';
  end;
end;

procedure RebuildFilteredList(Lib: TOMMLibraryEngine);
var
  i, n, matchCount: Cardinal;
  q, sTitle, sArtist, sAlbum: string;
  pRec: POMMTrackRecord;
begin
  if (Lib = nil) or (not Lib.IsOpen) then
  begin
    SetLength(GFilteredIndices, 0);
    GFilteredCount := 0;
    Exit;
  end;
  n := Lib.TrackCount;
  q := LowerCase(Trim(StrPas(@GFilterBuf[0])));
  SetLength(GFilteredIndices, n);
  matchCount := 0;
  if n > 0 then
  begin
    for i := 0 to n - 1 do
    begin
      if q = '' then
      begin
        GFilteredIndices[matchCount] := i;
        Inc(matchCount);
      end
      else
      begin
        pRec := Lib.GetRecordByIndex(i);
        if pRec <> nil then
        begin
          sTitle  := LowerCase(StrPas(@pRec^.Title[0]));
          sArtist := LowerCase(StrPas(@pRec^.Artist[0]));
          sAlbum  := LowerCase(StrPas(@pRec^.Album[0]));
          if (Pos(q, sTitle) > 0) or (Pos(q, sArtist) > 0) or (Pos(q, sAlbum) > 0) then
          begin
            GFilteredIndices[matchCount] := i;
            Inc(matchCount);
          end;
        end;
      end;
    end;
  end;
  SetLength(GFilteredIndices, matchCount);
  GFilteredCount := matchCount;
  if GSelectedTrackIdx >= GFilteredCount then
    GSelectedTrackIdx := 0;
  if GViewportTopIdx >= GFilteredCount then
    GViewportTopIdx := 0;
end;

procedure PollSocketPackets;
var
  pkt: TOMMPacket;
  res: cint;
begin
  if FSocketFD < 0 then Exit;
  repeat
    res := RecvPacketNonBlocking(FSocketFD, pkt);
    if res = 1 then
    begin
      case pkt.Opcode of
        OP_RESP_MINERAL_SEARCH_HEADER:
        begin
          GIsOnlineMode := True;
          GOnlineSearching := False;
          GOnlineTrackCount := 0;
          GSelectedTrackIdx := 0;
          GViewportTopIdx := 0;
          GLastPlayedOnlineIdx := -1;
          if pkt.StatusCode < 0 then
            SetStatusMessage('Search error (' + IntToStr(pkt.StatusCode) + ') on ' + GetSourceLabel(GSourceIdx), 5000)
          else if pkt.Payload.ReturnedCount = 0 then
            SetStatusMessage('No tracks found for "' + StrPas(@GSearchBuf[0]) + '" on ' + GetSourceLabel(GSourceIdx), 4000)
          else
            SetStatusMessage('Found ' + IntToStr(pkt.Payload.ReturnedCount) + ' tracks on ' + GetSourceLabel(GSourceIdx), 3000);
        end;
        OP_RESP_MINERAL_SEARCH_ITEM:
        begin
          GIsOnlineMode := True;
          GOnlineSearching := False;
          if GOnlineTrackCount < MAX_ONLINE_TRACKS then
          begin
            Move(pkt.Payload.TrackItem, GOnlineTracks[GOnlineTrackCount], SizeOf(TOMMCondensedTrack));
            Inc(GOnlineTrackCount);
          end;
        end;
        OP_RESP_ERROR:
        begin
          if pkt.Payload.ErrorCode = OMM_ERR_AUTH_REQUIRED then
            SetStatusMessage('Auth required (VIP/Cookie needed for this stream)', 5000)
          else
            SetStatusMessage('Playback/IPC Error (' + IntToStr(pkt.Payload.ErrorCode) + ')', 4000);
        end;
      end;
    end
    else if res < 0 then
    begin
      fpClose(FSocketFD);
      FSocketFD := -1;
      Break;
    end;
  until res <= 0;
end;

function SendSafePacket(const Packet: TOMMPacket): Boolean;
begin
  Result := False;
  if FSocketFD < 0 then
    ConnectToDaemon;
  if FSocketFD >= 0 then
  begin
    PollSocketPackets;
    Result := SendPacket(FSocketFD, Packet);
    if not Result then
    begin
      if ConnectToDaemon then
        Result := SendPacket(FSocketFD, Packet);
    end;
  end;
end;

procedure SendCommand(Opcode: UInt16);
var
  pkt: TOMMPacket;
begin
  Inc(GSeqCounter);
  InitPacket(pkt, Opcode, GSeqCounter);
  SendSafePacket(pkt);
end;

procedure SendPlayTrack(TrackID: UInt32);
var
  pkt: TOMMPacket;
begin
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_PLAY_TRACK_ID, GSeqCounter);
  pkt.Payload.TrackID := TrackID;
  SendSafePacket(pkt);
end;

procedure SendPlayURI(const AURI: string);
var
  pkt: TOMMPacket;
  len: Integer;
begin
  if AURI = '' then Exit;
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_PLAY_URI, GSeqCounter);
  len := Min(Length(AURI), 479);
  Move(AURI[1], pkt.Payload.URI[0], len);
  SendSafePacket(pkt);
end;

procedure RenderFrame(const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine); forward;

procedure SendMineralOnlineSearch(const AQuery: string; const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  pkt: TOMMPacket;
  q, fullQuery: string;
  len: Integer;
begin
  q := Trim(AQuery);
  if Pos('netease:', q) = 1 then
  begin
    GSourceIdx := 1;
    q := Trim(Copy(q, 9, 255));
  end
  else if Pos('bilibili:', q) = 1 then
  begin
    GSourceIdx := 2;
    q := Trim(Copy(q, 10, 255));
  end
  else if Pos('am:', q) = 1 then
  begin
    GSourceIdx := 3;
    q := Trim(Copy(q, 4, 255));
  end
  else if Pos('qq:', q) = 1 then
  begin
    GSourceIdx := 4;
    q := Trim(Copy(q, 4, 255));
  end
  else if GSourceIdx = 0 then
    GSourceIdx := 1;

  if q = '' then Exit;

  len := Min(Length(q), 125);
  Move(q[1], GSearchBuf[0], len);
  GSearchBuf[len] := #0;
  GSearchLen := len;

  GIsOnlineMode := True;
  GOnlineSearching := True;
  GOnlineTrackCount := 0;
  GSelectedTrackIdx := 0;
  GViewportTopIdx := 0;
  GLastPlayedOnlineIdx := -1;
  SetStatusMessage('Searching ' + GetSourceLabel(GSourceIdx) + ' for "' + q + '"...', 10000);

  // Immediately render searching state before blocking daemon request completes
  if GTerm.IsTTY then
  begin
    TermUpdateSize(GTerm);
    RenderFrame(Snap, Lib);
  end;

  fullQuery := GetSourcePrefix(GSourceIdx) + q;
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_MINERAL_SEARCH, GSeqCounter);
  len := Min(Length(fullQuery), 479);
  Move(fullQuery[1], pkt.Payload.URI[0], len);
  SendSafePacket(pkt);
end;

procedure SendSeek(TargetMs: UInt32);
var
  pkt: TOMMPacket;
begin
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_SEEK, GSeqCounter);
  pkt.Payload.TargetMs := TargetMs;
  SendSafePacket(pkt);
end;

procedure SendSetVolume(Vol: Single);
var
  pkt: TOMMPacket;
begin
  Inc(GSeqCounter);
  InitPacket(pkt, OP_REQ_SET_VOLUME, GSeqCounter);
  pkt.Payload.Volume := Vol;
  SendSafePacket(pkt);
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
// Screen Rendering (Explicit Row-by-Row Positioning, Zero Scroll, Zero Ghost)
// =============================================================================

procedure BufGotoXY(var Buf: TFrameBuffer; Row, Col: Integer);
begin
  if Row < 1 then Row := 1;
  if Col < 1 then Col := 1;
  BufAppendStr(Buf, #27'[');
  BufAppendInt(Buf, Row, 1);
  BufAppendChar(Buf, ';');
  BufAppendInt(Buf, Col, 1);
  BufAppendChar(Buf, 'H');
end;

procedure BufGotoCol(var Buf: TFrameBuffer; Col: Integer);
begin
  if Col < 1 then Col := 1;
  BufAppendStr(Buf, #27'[');
  BufAppendInt(Buf, Col, 1);
  BufAppendChar(Buf, 'G');
end;

procedure BufStartRow(var Buf: TFrameBuffer; Row: Integer; const LeftBorder: string = '│ ');
begin
  BufGotoXY(Buf, Row, 1);
  BufAppendStr(Buf, CSI_RESET + CSI_CLEAR_EOL + LeftBorder);
end;

procedure BufEndRow(var Buf: TFrameBuffer; Row, Width: Integer; const RightBorder: string = '│');
begin
  BufGotoXY(Buf, Row, Width);
  BufAppendStr(Buf, CSI_RESET + RightBorder);
end;

procedure BufDrawHorizRule(var Buf: TFrameBuffer; Count: Integer);
var
  i: Integer;
begin
  for i := 1 to Count do
    BufAppendStr(Buf, '─');
end;

procedure BufDrawSectionDivider(var Buf: TFrameBuffer; Row: Integer; const Title: string; Width: Integer);
var
  titleCols, prefixCols, remainCols: Integer;
begin
  BufGotoXY(Buf, Row, 1);
  BufAppendStr(Buf, CSI_RESET + CSI_CLEAR_EOL);
  if Title = '' then
  begin
    BufAppendStr(Buf, '├');
    BufDrawHorizRule(Buf, Max(1, Width - 2));
    BufGotoXY(Buf, Row, Width);
    BufAppendStr(Buf, '┤');
  end
  else
  begin
    BufAppendStr(Buf, '├────── ' + CSI_BOLD_CYAN + Title + CSI_RESET + ' ');
    titleCols := Utf8DisplayCols(Title);
    prefixCols := 9 + titleCols;
    remainCols := Max(1, Width - prefixCols - 1);
    BufDrawHorizRule(Buf, remainCols);
    BufGotoXY(Buf, Row, Width);
    BufAppendStr(Buf, '┤');
  end;
end;

procedure RenderSpectrumRow(var Buf: TFrameBuffer; TermRow: Integer; const Snap: TLocalPlaybackSnapshot;
  SpecBandRow, SpecTotalRows, Width: Integer; AsciiMode: Boolean);
var
  b, numBands, bandIdx: Integer;
  barVal, peakVal, rowThreshold, nextThreshold, stepSize: Integer;
  colorCode: string;
begin
  numBands := Max(16, Width - 4);
  stepSize := Max(1, 64 div Max(1, SpecTotalRows));
  rowThreshold := SpecBandRow * stepSize;
  nextThreshold := (SpecBandRow + 1) * stepSize;

  if SpecBandRow * 4 >= SpecTotalRows * 3 then colorCode := CSI_BOLD_RED
  else if SpecBandRow * 2 >= SpecTotalRows then colorCode := CSI_BOLD_YELLOW
  else if SpecBandRow * 4 >= SpecTotalRows then colorCode := CSI_CYAN
  else colorCode := CSI_GREEN;

  BufStartRow(Buf, TermRow, '│ ' + colorCode);

  for b := 0 to numBands - 1 do
  begin
    bandIdx := (b * 64) div numBands;
    if bandIdx > 63 then bandIdx := 63;
    barVal := Snap.QuantizedBars[bandIdx];
    peakVal := Snap.QuantizedPeaks[bandIdx];

    if AsciiMode then
    begin
      if barVal >= nextThreshold then
        BufAppendChar(Buf, '#')
      else if barVal > rowThreshold then
        BufAppendChar(Buf, '*')
      else if (peakVal >= rowThreshold) and (peakVal < nextThreshold) then
        BufAppendChar(Buf, '-')
      else
        BufAppendChar(Buf, ' ');
    end
    else
    begin
      if barVal >= nextThreshold then
        BufAppendStr(Buf, UTF8_BARS[8])
      else if barVal > rowThreshold then
        BufAppendStr(Buf, UTF8_BARS[EnsureRange(((barVal - rowThreshold) * 8) div stepSize, 1, 8)])
      else if (peakVal >= rowThreshold) and (peakVal < nextThreshold) then
        BufAppendStr(Buf, CSI_BOLD_WHITE + UTF8_PEAK + colorCode)
      else
        BufAppendChar(Buf, ' ');
    end;
  end;

  BufEndRow(Buf, TermRow, Width);
end;

procedure RenderProgressBar(var Buf: TFrameBuffer; TermRow: Integer; PosMs, DurMs: UInt32; Width: Integer);
var
  barWidth, filled, i: Integer;
  pct: Integer;
begin
  BufStartRow(Buf, TermRow, '│ [');
  barWidth := Max(10, Width - 28);
  if DurMs > 0 then
    pct := Min(100, (Int64(PosMs) * 100) div DurMs)
  else
    pct := 0;

  filled := (pct * barWidth) div 100;
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
  BufAppendChar(Buf, '%');
  BufEndRow(Buf, TermRow, Width);
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

function ViewportActiveCount(Lib: TOMMLibraryEngine): Cardinal;
begin
  if GIsOnlineMode then
    Result := GOnlineTrackCount
  else
  begin
    if (Lib <> nil) and Lib.IsOpen and (GFilterLen = 0) and (GFilteredCount <> Lib.TrackCount) then
      RebuildFilteredList(Lib);
    Result := GFilteredCount;
  end;
end;

procedure RenderFrame(const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  cols, rows, specRows, maxLibRows, curRow, r: Integer;
  titleMaxLen, artistCol, albumCol, durCol, artistMaxLen, albumMaxLen: Integer;
  pRec: POMMTrackRecord;
  pOnline: ^TOMMCondensedTrack;
  tCount, trackIdx, displayID, rowDurMs: Cardinal;
  pTitle, pArtist, pAlbum: PAnsiChar;
  isPlayingRow: Boolean;
  stateStr, pluginStr, srcStr, vpTitle, hdrLeft, hdrRight: string;
  dashCols: Integer;
begin
  BufClear(GFrameBuf);

  cols := Max(60, Integer(GTerm.Cols));
  rows := Max(20, Integer(GTerm.Rows));
  if rows >= 26 then
    specRows := 8
  else
    specRows := Max(2, rows - 18);

  maxLibRows := Max(2, rows - 14 - specRows);
  curRow := 1;

  // Row 1: Top Header Border
  hdrLeft := ' Oh-Mini-Mineral Stateless Terminal Client v' + APP_VERSION + ' ';
  hdrRight := ' [SHM 60 FPS] ';
  dashCols := Max(2, cols - 4 - Utf8DisplayCols(hdrLeft) - Utf8DisplayCols(hdrRight));
  BufGotoXY(GFrameBuf, curRow, 1);
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + CSI_BOLD_CYAN + '┌──' + hdrLeft);
  BufDrawHorizRule(GFrameBuf, dashCols);
  BufGotoXY(GFrameBuf, curRow, Max(1, cols - Utf8DisplayCols(hdrRight) - 2));
  BufAppendStr(GFrameBuf, hdrRight + '──┐' + CSI_RESET);
  Inc(curRow);

  // Row 2: Track Title
  BufStartRow(GFrameBuf, curRow, '│ Title : ' + CSI_BOLD_WHITE);
  if Snap.TrackTitle[0] <> #0 then
    BufAppendUtf8Cols(GFrameBuf, @Snap.TrackTitle[0], 128, Max(20, cols - 12))
  else
    BufAppendStr(GFrameBuf, 'No track active');
  BufEndRow(GFrameBuf, curRow, cols);
  Inc(curRow);

  // Row 3: Artist & Album
  BufStartRow(GFrameBuf, curRow, '│ Artist: ' + CSI_CYAN);
  if Snap.TrackArtist[0] <> #0 then
    BufAppendUtf8Cols(GFrameBuf, @Snap.TrackArtist[0], 128, Max(14, (cols - 28) div 2))
  else
    BufAppendStr(GFrameBuf, 'Unknown Artist');
  BufGotoCol(GFrameBuf, Max(28, cols div 2));
  BufAppendStr(GFrameBuf, CSI_RESET + ' Album: ' + CSI_YELLOW);
  if Snap.TrackAlbum[0] <> #0 then
    BufAppendUtf8Cols(GFrameBuf, @Snap.TrackAlbum[0], 128, Max(14, (cols div 2) - 11))
  else
    BufAppendStr(GFrameBuf, 'Unknown Album');
  BufEndRow(GFrameBuf, curRow, cols);
  Inc(curRow);

  // Row 4: Progress Bar
  RenderProgressBar(GFrameBuf, curRow, Snap.PositionMs, Snap.DurationMs, cols);
  Inc(curRow);

  // Row 5: Status, Volume, Source, and Plugin State
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

  srcStr := GetSourceLabel(GSourceIdx);

  BufStartRow(GFrameBuf, curRow, '│ State: [' + CSI_BOLD + stateStr + CSI_RESET + ']  ');
  RenderVolumeBar(GFrameBuf, Snap.Volume);
  BufAppendStr(GFrameBuf, '  Source: [' + CSI_BOLD_YELLOW + srcStr + CSI_RESET + ']  Plugin: [' + CSI_CYAN + pluginStr + CSI_RESET + ']');
  BufEndRow(GFrameBuf, curRow, cols);
  Inc(curRow);

  // Row 6: Spectrum Divider
  BufDrawSectionDivider(GFrameBuf, curRow, '64-Band Real-Time Spectrum', cols);
  Inc(curRow);

  // Spectrum Rows
  for r := specRows - 1 downto 0 do
  begin
    RenderSpectrumRow(GFrameBuf, curRow, Snap, r, specRows, cols, GAsciiMode);
    Inc(curRow);
  end;

  // Synchronized Lyrics Divider & 2 Rows
  BufDrawSectionDivider(GFrameBuf, curRow, 'Synchronized Lyrics', cols);
  Inc(curRow);

  BufStartRow(GFrameBuf, curRow, '│ ♪ ' + CSI_BOLD_WHITE);
  if Snap.LyricCurrent[0] <> #0 then
    BufAppendUtf8Cols(GFrameBuf, @Snap.LyricCurrent[0], 256, Max(20, cols - 8))
  else
    BufAppendStr(GFrameBuf, '(...)');
  BufEndRow(GFrameBuf, curRow, cols);
  Inc(curRow);

  BufStartRow(GFrameBuf, curRow, '│   ' + CSI_DIM);
  if Snap.LyricNext[0] <> #0 then
    BufAppendUtf8Cols(GFrameBuf, @Snap.LyricNext[0], 256, Max(20, cols - 8));
  BufEndRow(GFrameBuf, curRow, cols);
  Inc(curRow);

  // Viewport Divider
  tCount := ViewportActiveCount(Lib);
  if GIsOnlineMode then
  begin
    vpTitle := 'Online Search - ' + GetSourceLabel(GSourceIdx);
    if GSearchLen > 0 then
      vpTitle := vpTitle + ' [' + IntToStr(tCount) + ' results]';
  end
  else
  begin
    vpTitle := 'Library Viewport - Local Library';
    if GFilterLen > 0 then
      vpTitle := vpTitle + ' [Filter: ' + IntToStr(tCount) + ' matches]'
    else
      vpTitle := vpTitle + ' [' + IntToStr(tCount) + ' tracks]';
  end;
  if (GStatusMsg <> '') and (GetTickCount64 < GStatusExpireTick) then
    vpTitle := vpTitle + ' (' + GStatusMsg + ')';
  BufDrawSectionDivider(GFrameBuf, curRow, vpTitle, cols);
  Inc(curRow);

  // Clamp selection and viewport scroll offset
  if (tCount > 0) and (GSelectedTrackIdx >= tCount) then
    GSelectedTrackIdx := tCount - 1;
  if tCount = 0 then
  begin
    GSelectedTrackIdx := 0;
    GViewportTopIdx := 0;
  end
  else
  begin
    if GSelectedTrackIdx >= GViewportTopIdx + Cardinal(maxLibRows) then
      GViewportTopIdx := GSelectedTrackIdx - Cardinal(maxLibRows) + 1;
    if GSelectedTrackIdx < GViewportTopIdx then
      GViewportTopIdx := GSelectedTrackIdx;
  end;

  durCol := cols - 7;
  if cols >= 100 then
  begin
    albumCol := cols - 34;
    artistCol := cols - 58;
    titleMaxLen := Max(14, artistCol - 13);
    artistMaxLen := Max(10, albumCol - artistCol - 2);
    albumMaxLen := Max(10, durCol - albumCol - 2);
  end
  else
  begin
    albumCol := 0;
    artistCol := Max(34, cols - 30);
    titleMaxLen := Max(12, artistCol - 13);
    artistMaxLen := Max(8, durCol - artistCol - 2);
    albumMaxLen := 0;
  end;

  if GIsOnlineMode and GOnlineSearching then
  begin
    BufStartRow(GFrameBuf, curRow, '│ ' + CSI_BOLD_YELLOW + '[Searching ' + GetSourceLabel(GSourceIdx) + ' for "' + StrPas(@GSearchBuf[0]) + '"...]' + CSI_RESET);
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    for r := 1 to maxLibRows - 1 do
    begin
      BufStartRow(GFrameBuf, curRow, '│');
      BufEndRow(GFrameBuf, curRow, cols);
      Inc(curRow);
    end;
  end
  else if GIsOnlineMode and (tCount = 0) then
  begin
    BufStartRow(GFrameBuf, curRow, '│ [Online Mode (' + CSI_BOLD_YELLOW + GetSourceLabel(GSourceIdx) + CSI_RESET + ') - press ' +
      CSI_BOLD_CYAN + '''s''' + CSI_RESET + ' to search online tracks, or ' +
      CSI_BOLD_CYAN + '''m''' + CSI_RESET + ' to switch source]');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    for r := 1 to maxLibRows - 1 do
    begin
      BufStartRow(GFrameBuf, curRow, '│');
      BufEndRow(GFrameBuf, curRow, cols);
      Inc(curRow);
    end;
  end
  else if (not GIsOnlineMode) and ((Lib = nil) or (tCount = 0)) then
  begin
    if GFilterLen > 0 then
      BufStartRow(GFrameBuf, curRow, '│ [No local tracks match filter "' + CSI_BOLD_YELLOW + StrPas(@GFilterBuf[0]) + CSI_RESET + '" - press ' + CSI_BOLD_CYAN + '''/''' + CSI_RESET + ' then Esc to clear]')
    else
      BufStartRow(GFrameBuf, curRow, '│ [No library.bin found - press ' + CSI_BOLD_YELLOW + '''r''' + CSI_RESET + ' to rescan local library, or ' + CSI_BOLD_CYAN + '''s''' + CSI_RESET + ' for online search]');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    for r := 1 to maxLibRows - 1 do
    begin
      BufStartRow(GFrameBuf, curRow, '│');
      BufEndRow(GFrameBuf, curRow, cols);
      Inc(curRow);
    end;
  end
  else
  begin
    for r := 0 to maxLibRows - 1 do
    begin
      trackIdx := GViewportTopIdx + Cardinal(r);
      if trackIdx < tCount then
      begin
        pTitle := nil;
        pArtist := nil;
        pAlbum := nil;
        displayID := trackIdx + 1;
        rowDurMs := 0;
        isPlayingRow := False;

        if GIsOnlineMode then
        begin
          pOnline := @GOnlineTracks[trackIdx];
          if pOnline^.TrackID > 10000 then
            displayID := pOnline^.TrackID - 10000
          else if pOnline^.TrackID > 0 then
            displayID := pOnline^.TrackID;
          pTitle := @pOnline^.Title[0];
          pArtist := @pOnline^.Artist[0];
          pAlbum := @pOnline^.Album[0];
          rowDurMs := pOnline^.DurationMs;
          isPlayingRow := (Snap.PlaybackState in [1, 2]) and
            ((Integer(trackIdx) = GLastPlayedOnlineIdx) or
             ((Snap.CurrentTrackID > 0) and (pOnline^.TrackID = Snap.CurrentTrackID)));
        end
        else
        begin
          pRec := Lib.GetRecordByIndex(GFilteredIndices[trackIdx]);
          if pRec <> nil then
          begin
            displayID := pRec^.TrackID;
            pTitle := @pRec^.Title[0];
            pArtist := @pRec^.Artist[0];
            pAlbum := @pRec^.Album[0];
            rowDurMs := pRec^.DurationMs;
            isPlayingRow := (Snap.PlaybackState in [1, 2]) and (Snap.CurrentTrackID = pRec^.TrackID);
          end;
        end;

        if trackIdx = GSelectedTrackIdx then
        begin
          BufStartRow(GFrameBuf, curRow, '│ ' + CSI_REVERSE + CSI_BOLD_CYAN);
          BufAppendSpaces(GFrameBuf, Max(1, cols - 3));
          BufGotoXY(GFrameBuf, curRow, 3);
          if isPlayingRow then
            BufAppendStr(GFrameBuf, '▶ ')
          else
            BufAppendStr(GFrameBuf, '> ');
          BufAppendInt(GFrameBuf, displayID, 4);
          BufAppendStr(GFrameBuf, '. ');
          if pTitle <> nil then
            BufAppendUtf8Cols(GFrameBuf, pTitle, 128, titleMaxLen);
          BufGotoXY(GFrameBuf, curRow, artistCol);
          if pArtist <> nil then
            BufAppendUtf8Cols(GFrameBuf, pArtist, 96, artistMaxLen);
          if albumCol > 0 then
          begin
            BufGotoXY(GFrameBuf, curRow, albumCol);
            if pAlbum <> nil then
              BufAppendUtf8Cols(GFrameBuf, pAlbum, 96, albumMaxLen);
          end;
          BufGotoXY(GFrameBuf, curRow, durCol);
          BufAppendTime(GFrameBuf, rowDurMs);
          BufEndRow(GFrameBuf, curRow, cols);
        end
        else
        begin
          if isPlayingRow then
            BufStartRow(GFrameBuf, curRow, '│ ' + CSI_BOLD_GREEN + '♪ ')
          else
            BufStartRow(GFrameBuf, curRow, '│   ');
          BufAppendInt(GFrameBuf, displayID, 4);
          BufAppendStr(GFrameBuf, '. ');
          if pTitle <> nil then
            BufAppendUtf8Cols(GFrameBuf, pTitle, 128, titleMaxLen);
          BufGotoXY(GFrameBuf, curRow, artistCol);
          if isPlayingRow then
            BufAppendStr(GFrameBuf, CSI_BOLD_GREEN)
          else
            BufAppendStr(GFrameBuf, CSI_DIM);
          if pArtist <> nil then
            BufAppendUtf8Cols(GFrameBuf, pArtist, 96, artistMaxLen);
          if albumCol > 0 then
          begin
            BufGotoXY(GFrameBuf, curRow, albumCol);
            if pAlbum <> nil then
              BufAppendUtf8Cols(GFrameBuf, pAlbum, 96, albumMaxLen);
          end;
          BufGotoXY(GFrameBuf, curRow, durCol);
          if not isPlayingRow then
            BufAppendStr(GFrameBuf, CSI_RESET);
          BufAppendTime(GFrameBuf, rowDurMs);
          BufEndRow(GFrameBuf, curRow, cols);
        end;
      end
      else
      begin
        BufStartRow(GFrameBuf, curRow, '│');
        BufEndRow(GFrameBuf, curRow, cols);
      end;
      Inc(curRow);
    end;
  end;

  // Controls Footer (Pinned to bottom 4 rows: rows - 3 .. rows)
  curRow := rows - 3;
  BufDrawSectionDivider(GFrameBuf, curRow, '', cols);
  Inc(curRow);

  if GInputMode = imOnlineSearch then
  begin
    BufStartRow(GFrameBuf, curRow, '│ Online Search (' + CSI_BOLD_CYAN + GetSourceLabel(IfThen(GSourceIdx = 0, 1, GSourceIdx)) + CSI_RESET + '): ' +
      CSI_BOLD_YELLOW + StrPas(@GSearchBuf[0]) + '_' + CSI_RESET + '  [Enter] Search  [Esc] Cancel');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    BufStartRow(GFrameBuf, curRow, '│ Tip: Prefix with netease: / bilibili: / am: / qq: or press [m] after Esc to switch platform');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
  end
  else if GInputMode = imLocalFilter then
  begin
    BufStartRow(GFrameBuf, curRow, '│ Local Filter: ' + CSI_BOLD_YELLOW + StrPas(@GFilterBuf[0]) + '_' + CSI_RESET + '  [Enter] Confirm  [Esc] Clear Filter');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    BufStartRow(GFrameBuf, curRow, '│ Type to filter local library in real-time by Title, Artist, or Album  [↑/↓] Select Track');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
  end
  else
  begin
    BufStartRow(GFrameBuf, curRow, '│ [Space] Play/Pause  [s] Search  [m] Source  [x] Stop  [Enter] Play  [n/p] Next/Prev  [←/→] Seek  [+/-] Vol');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
    BufStartRow(GFrameBuf, curRow, '│ [↑/↓ or j/k] Navigate  [PgUp/PgDn] Page  [/] Filter  [r] Rescan  [w] Wake  [z] Suspend  [q] Quit');
    BufEndRow(GFrameBuf, curRow, cols);
    Inc(curRow);
  end;

  // Final Row (Row = rows): Bottom Border without newline so terminal never scrolls!
  BufGotoXY(GFrameBuf, rows, 1);
  BufAppendStr(GFrameBuf, CSI_RESET + CSI_CLEAR_EOL + CSI_BOLD_CYAN + '└');
  BufDrawHorizRule(GFrameBuf, Max(1, cols - 2));
  BufGotoXY(GFrameBuf, rows, cols);
  BufAppendStr(GFrameBuf, '┘' + CSI_RESET);

  BufFlush(GFrameBuf);
end;

// =============================================================================
// Input Processing
// =============================================================================

procedure PopUtf8Char(var Buf: array of AnsiChar; var Len: Integer);
begin
  if Len <= 0 then Exit;
  while (Len > 0) and ((Ord(Buf[Len - 1]) and $C0) = $80) do
    Dec(Len);
  if Len > 0 then
    Dec(Len);
  Buf[Len] := #0;
end;

procedure PlayTrackAtIndex(Idx: Cardinal; const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  tCount: Cardinal;
  pRec: POMMTrackRecord;
  uri, titleStr: string;
begin
  tCount := ViewportActiveCount(Lib);
  if (tCount = 0) or (Idx >= tCount) then Exit;
  GSelectedTrackIdx := Idx;

  if GIsOnlineMode then
  begin
    uri := StrPas(@GOnlineTracks[Idx].URI[0]);
    titleStr := StrPas(@GOnlineTracks[Idx].Title[0]);
    if uri <> '' then
    begin
      GLastPlayedOnlineIdx := Integer(Idx);
      SetStatusMessage('Loading stream: ' + titleStr, 4000);
      if GTerm.IsTTY then
      begin
        TermUpdateSize(GTerm);
        RenderFrame(Snap, Lib);
      end;
      SendPlayURI(uri);
    end;
  end
  else if Lib <> nil then
  begin
    pRec := Lib.GetRecordByIndex(GFilteredIndices[Idx]);
    if pRec <> nil then
    begin
      SetStatusMessage('Playing: ' + StrPas(@pRec^.Title[0]), 3000);
      SendPlayTrack(pRec^.TrackID);
    end;
  end;
end;

procedure ProcessVirtualKey(VKey: TVirtualKey; const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  tCount: Cardinal;
begin
  tCount := ViewportActiveCount(Lib);
  case VKey of
    vkUp:
      if GSelectedTrackIdx > 0 then Dec(GSelectedTrackIdx);
    vkDown:
      if (tCount > 0) and (GSelectedTrackIdx < tCount - 1) then Inc(GSelectedTrackIdx);
    vkPgUp:
      if GSelectedTrackIdx > 10 then Dec(GSelectedTrackIdx, 10) else GSelectedTrackIdx := 0;
    vkPgDn:
      if (tCount > 0) and (GSelectedTrackIdx + 10 < tCount) then
        Inc(GSelectedTrackIdx, 10)
      else if tCount > 0 then
        GSelectedTrackIdx := tCount - 1
      else
        GSelectedTrackIdx := 0;
    vkHome:
      GSelectedTrackIdx := 0;
    vkEnd:
      if tCount > 0 then GSelectedTrackIdx := tCount - 1 else GSelectedTrackIdx := 0;
    vkLeft:
      if GInputMode = imNone then
      begin
        if Snap.PositionMs > 5000 then
          SendSeek(Snap.PositionMs - 5000)
        else
          SendSeek(0);
      end;
    vkRight:
      if GInputMode = imNone then
      begin
        if Snap.DurationMs > Snap.PositionMs + 5000 then
          SendSeek(Snap.PositionMs + 5000)
        else if Snap.DurationMs > 0 then
          SendSeek(Snap.DurationMs);
      end;
    vkDelete:
      if GInputMode = imOnlineSearch then
        PopUtf8Char(GSearchBuf, GSearchLen)
      else if GInputMode = imLocalFilter then
      begin
        PopUtf8Char(GFilterBuf, GFilterLen);
        RebuildFilteredList(Lib);
      end;
  end;
end;

procedure ProcessKey(Key: Char; const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  tCount: Cardinal;
begin
  tCount := ViewportActiveCount(Lib);

  if GInputMode = imOnlineSearch then
  begin
    if (Key = #13) or (Key = #10) then
    begin
      GInputMode := imNone;
      if GSearchLen > 0 then
        SendMineralOnlineSearch(StrPas(@GSearchBuf[0]), Snap, Lib);
    end
    else if Key = #27 then
    begin
      GInputMode := imNone;
    end
    else if (Key = #8) or (Key = #127) then
    begin
      PopUtf8Char(GSearchBuf, GSearchLen);
    end
    else if (Ord(Key) >= 32) and (Ord(Key) <> 127) and (GSearchLen < 125) then
    begin
      GSearchBuf[GSearchLen] := Key;
      Inc(GSearchLen);
      GSearchBuf[GSearchLen] := #0;
    end;
    Exit;
  end;

  if GInputMode = imLocalFilter then
  begin
    if (Key = #13) or (Key = #10) then
    begin
      GInputMode := imNone;
    end
    else if Key = #27 then
    begin
      GInputMode := imNone;
      GFilterLen := 0;
      GFilterBuf[0] := #0;
      RebuildFilteredList(Lib);
    end
    else if (Key = #8) or (Key = #127) then
    begin
      PopUtf8Char(GFilterBuf, GFilterLen);
      RebuildFilteredList(Lib);
    end
    else if (Ord(Key) >= 32) and (Ord(Key) <> 127) and (GFilterLen < 125) then
    begin
      GFilterBuf[GFilterLen] := Key;
      Inc(GFilterLen);
      GFilterBuf[GFilterLen] := #0;
      RebuildFilteredList(Lib);
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
      else if tCount > 0 then
        PlayTrackAtIndex(GSelectedTrackIdx, Snap, Lib)
      else
        SendCommand(OP_REQ_PLAY);
    end;

    's': // Online Search
    begin
      if GSourceIdx = 0 then
        GSourceIdx := 1;
      GIsOnlineMode := True;
      GInputMode := imOnlineSearch;
      GSearchLen := 0;
      GSearchBuf[0] := #0;
    end;

    'm', 'M': // Switch Source (0=Local -> 1=NetEase -> 2=Bilibili -> 3=AppleMusic -> 4=QQMusic)
    begin
      GSourceIdx := (GSourceIdx + 1) mod 5;
      if GSourceIdx = 0 then
      begin
        GIsOnlineMode := False;
        GOnlineSearching := False;
        RebuildFilteredList(Lib);
        GSelectedTrackIdx := 0;
        GViewportTopIdx := 0;
        SetStatusMessage('Switched to Local Library', 2500);
      end
      else
      begin
        GIsOnlineMode := True;
        SetStatusMessage('Switched source to ' + GetSourceLabel(GSourceIdx), 2500);
        if GSearchLen > 0 then
          SendMineralOnlineSearch(StrPas(@GSearchBuf[0]), Snap, Lib)
        else
        begin
          GOnlineTrackCount := 0;
          GSelectedTrackIdx := 0;
          GViewportTopIdx := 0;
        end;
      end;
    end;

    'x', 'X', 'S': // Stop
    begin
      SendCommand(OP_REQ_STOP);
      SetStatusMessage('Playback stopped', 2000);
    end;

    #13, #10: // Enter: Play highlighted track
      PlayTrackAtIndex(GSelectedTrackIdx, Snap, Lib);

    'n', 'N', ']': // Next track
    begin
      if (tCount > 0) and (GSelectedTrackIdx + 1 < tCount) then
        PlayTrackAtIndex(GSelectedTrackIdx + 1, Snap, Lib)
      else if tCount > 0 then
        PlayTrackAtIndex(0, Snap, Lib);
    end;

    'p', 'P', '[': // Previous track
    begin
      if (tCount > 0) and (GSelectedTrackIdx > 0) then
        PlayTrackAtIndex(GSelectedTrackIdx - 1, Snap, Lib)
      else if tCount > 0 then
        PlayTrackAtIndex(tCount - 1, Snap, Lib);
    end;

    'j': // Down
      ProcessVirtualKey(vkDown, Snap, Lib);

    'k': // Up
      ProcessVirtualKey(vkUp, Snap, Lib);

    'g': // First track
      ProcessVirtualKey(vkHome, Snap, Lib);

    'G': // Last track
      ProcessVirtualKey(vkEnd, Snap, Lib);

    'h': // Seek backward 5s
      ProcessVirtualKey(vkLeft, Snap, Lib);

    'l': // Seek forward 5s
      ProcessVirtualKey(vkRight, Snap, Lib);

    '+', '=', '0': // Volume up 5%
      SendSetVolume(Min(1.0, Snap.Volume + 0.05));

    '-', '_', '9': // Volume down 5%
      SendSetVolume(Max(0.0, Snap.Volume - 0.05));

    'r', 'R': // Rescan
    begin
      GSourceIdx := 0;
      GIsOnlineMode := False;
      SetStatusMessage('Rescanning local music library...', 3000);
      SendCommand(OP_REQ_RESCAN_LIBRARY);
    end;

    'w', 'W': // Wake plugin
    begin
      SetStatusMessage('Waking up Mineral plugin...', 2500);
      SendCommand(OP_REQ_PLUGIN_WAKE);
    end;

    'z', 'Z': // Suspend plugin
    begin
      SetStatusMessage('Suspending Mineral plugin (<0.3 MB)...', 2500);
      SendCommand(OP_REQ_PLUGIN_SUSPEND);
    end;

    '/': // Local Filter
    begin
      GSourceIdx := 0;
      GIsOnlineMode := False;
      GInputMode := imLocalFilter;
      GFilterLen := 0;
      GFilterBuf[0] := #0;
      RebuildFilteredList(Lib);
    end;
  end;
end;

procedure HandleInput(const Snap: TLocalPlaybackSnapshot; Lib: TOMMLibraryEngine);
var
  ch, c2, c3: AnsiChar;
  n: {$IFDEF UNIX}ssize_t{$ELSE}TsSize{$ENDIF};
  numCode: Integer;
begin
  n := fpRead(STDIN_FILENO, @ch, 1);
  while n > 0 do
  begin
    {$IFDEF WINDOWS}
    if (ch = #0) or (ch = #$E0) then
    begin
      if fpRead(STDIN_FILENO, @c2, 1) = 1 then
      begin
        case Ord(c2) of
          72: ProcessVirtualKey(vkUp, Snap, Lib);
          80: ProcessVirtualKey(vkDown, Snap, Lib);
          77: ProcessVirtualKey(vkRight, Snap, Lib);
          75: ProcessVirtualKey(vkLeft, Snap, Lib);
          71: ProcessVirtualKey(vkHome, Snap, Lib);
          79: ProcessVirtualKey(vkEnd, Snap, Lib);
          73: ProcessVirtualKey(vkPgUp, Snap, Lib);
          81: ProcessVirtualKey(vkPgDn, Snap, Lib);
          83: ProcessVirtualKey(vkDelete, Snap, Lib);
        end;
      end;
      n := fpRead(STDIN_FILENO, @ch, 1);
      Continue;
    end;
    {$ENDIF}
    if ch = #27 then // Escape or CSI/SS3 sequence
    begin
      if fpRead(STDIN_FILENO, @c2, 1) = 1 then
      begin
        if (c2 = '[') or (c2 = 'O') then
        begin
          if fpRead(STDIN_FILENO, @c3, 1) = 1 then
          begin
            case c3 of
              'A': ProcessVirtualKey(vkUp, Snap, Lib);
              'B': ProcessVirtualKey(vkDown, Snap, Lib);
              'C': ProcessVirtualKey(vkRight, Snap, Lib);
              'D': ProcessVirtualKey(vkLeft, Snap, Lib);
              'H': ProcessVirtualKey(vkHome, Snap, Lib);
              'F': ProcessVirtualKey(vkEnd, Snap, Lib);
              '0'..'9':
              begin
                numCode := Ord(c3) - Ord('0');
                while fpRead(STDIN_FILENO, @c3, 1) = 1 do
                begin
                  if (c3 >= '0') and (c3 <= '9') then
                    numCode := numCode * 10 + (Ord(c3) - Ord('0'))
                  else if (c3 >= '@') and (c3 <= '~') then
                    Break;
                end;
                case numCode of
                  1, 7: ProcessVirtualKey(vkHome, Snap, Lib);
                  3:    ProcessVirtualKey(vkDelete, Snap, Lib);
                  4, 8: ProcessVirtualKey(vkEnd, Snap, Lib);
                  5:    ProcessVirtualKey(vkPgUp, Snap, Lib);
                  6:    ProcessVirtualKey(vkPgDn, Snap, Lib);
                end;
              end;
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
  pollFds: array[0..1] of {$IFDEF UNIX}TPollFD{$ELSE}pollfd{$ENDIF};
  lastTick, nowTick, sleepMs: Int64;
  pipeBuf: array[0..255] of AnsiChar;
  pipeRead: {$IFDEF UNIX}ssize_t{$ELSE}TsSize{$ENDIF};
  waitIter: Integer;

begin
  ParseCommandLine;

  if GVerifyOnly then
  begin
    Halt(RunVerification);
  end;

  GStartTick := GetTickCount64;

  // Open shared memory
  FPShm := OpenSharedMemory(GShmPath, True);

  // Connect to IPC socket (auto-launch daemon if not running in interactive mode)
  if (not ConnectToDaemon) and (not GOnceOnly) and (GTestTimeoutSec = 0) and (GSocketPath = OMM_DEFAULT_SOCKET_PATH) then
  begin
    if FileExists(ExtractFilePath(ParamStr(0)) + 'omm_daemon' + {$IFDEF WINDOWS}'.exe'{$ELSE}''{$ENDIF}) then
      SpawnDaemonBackground(ExtractFilePath(ParamStr(0)) + 'omm_daemon' + {$IFDEF WINDOWS}'.exe'{$ELSE}''{$ENDIF})
    else if FileExists('/usr/bin/omm_daemon') then
      SpawnDaemonBackground('/usr/bin/omm_daemon');
    for waitIter := 1 to 15 do
    begin
      Sleep(25);
      if ConnectToDaemon then Break;
    end;
    if FPShm = nil then
      FPShm := OpenSharedMemory(GShmPath, True);
  end;

  // Open library engine
  FLibEngine := TOMMLibraryEngine.Create('', GLibraryFile);
  FLibEngine.OpenLibrary;
  RebuildFilteredList(FLibEngine);

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
    begin
      if FLibEngine.EnsureFresh then
        RebuildFilteredList(FLibEngine);
      if FSocketFD < 0 then
        ConnectToDaemon;
    end;

    // Poll incoming IPC packets (e.g. online search results)
    if FSocketFD >= 0 then
      PollSocketPackets;

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

    // Non-blocking poll on stdin and IPC socket
    pollFds[0].fd := STDIN_FILENO;
    pollFds[0].events := POLLIN;
    pollFds[0].revents := 0;

    if FSocketFD >= 0 then
    begin
      pollFds[1].fd := FSocketFD;
      pollFds[1].events := POLLIN;
      pollFds[1].revents := 0;
      if fpPoll(@pollFds[0], 2, sleepMs) > 0 then
      begin
        if (pollFds[1].revents and POLLIN) <> 0 then
          PollSocketPackets;
        if (pollFds[0].revents and POLLIN) <> 0 then
          HandleInput(snap, FLibEngine);
        if (pollFds[0].revents and (POLLHUP or POLLERR)) <> 0 then
          Break;
      end;
    end
    else
    begin
      if fpPoll(@pollFds[0], 1, sleepMs) > 0 then
      begin
        if (pollFds[0].revents and POLLIN) <> 0 then
          HandleInput(snap, FLibEngine);
        if (pollFds[0].revents and (POLLHUP or POLLERR)) <> 0 then
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
