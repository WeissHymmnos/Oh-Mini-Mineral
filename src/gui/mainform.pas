unit mainform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls, LCLType, LCLIntf,
  Math, {$IFDEF UNIX}BaseUnix, Unix,{$ENDIF} ctypes, omm_os, omm_ipc, omm_shm, omm_library;

const
  MAX_CACHE_ITEMS = 128;
  ROW_HEIGHT      = 23;
  LYRIC_LINE_H    = 22;
  MINI_H_THRESH   = 185;
  RIGHT_PANE_MINW = 680;

type
  TGuiLyricLine = record
    TimestampMs: UInt32;
    Text: string;
  end;

  { TMainForm }
  TMainForm = class(TForm)
    pbMac: TPaintBox;
    tmrIPC: TTimer;
    tmrStatus: TTimer;
    tmrSpectrum: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyPress(Sender: TObject; var Key: char);
    procedure FormResize(Sender: TObject);
    procedure pbMacDblClick(Sender: TObject);
    procedure pbMacMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure pbMacMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbMacMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure pbMacMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure pbMacPaint(Sender: TObject);
    procedure tmrIPCTimer(Sender: TObject);
    procedure tmrSpectrumTimer(Sender: TObject);
    procedure tmrStatusTimer(Sender: TObject);
  private
    FBackBuffer: TBitmap;
    FEdtFilter: TEdit;
    FFilteredIndices: array of Cardinal;
    FSocketFD: cint;
    FPShm: POMMSharedMemory;
    FLibEngine: TOMMLibraryEngine;
    FSeqCounter: UInt32;
    FLastSpectrumSeq: UInt32;

    // Window drag / resize / state
    FIsDraggingWin: Boolean;
    FIsResizingWin: Boolean;
    FDragStartMouse: TPoint;
    FDragStartBounds: TRect;
    FSavedNormalBounds: TRect;
    FIsMiniMode: Boolean;
    FIsMaximizedMode: Boolean;
    FLastBoundsTick: Int64;

    // UI Interaction States
    FIsDraggingSeek: Boolean;
    FIsUpdatingSeekUI: Boolean;
    FIsDraggingVol: Boolean;
    FIsDraggingScroll: Boolean;
    FActivePressedBtn: Integer;
    FLastClickX, FLastClickY: Integer;
    FLastClickedRow: Integer;
    FLastRowClickTick: Int64;

    // CLI & Test Flags
    FTestTimeoutSecs: Integer;
    FHeadlessTestMode: Boolean;
    FStartTimeTick: Int64;
    FSocketPath: string;
    FShmPath: string;
    FMusicDirPath: string;

    // Viewport Cache
    FTotalTracks: Integer;
    FCacheStart: Integer;
    FCacheCount: Integer;
    FReceivingItemsRemaining: Integer;
    FCacheSlice: array[0..MAX_CACHE_ITEMS - 1] of TOMMCondensedTrack;

    // Virtual List State
    FTopRowIndex: Integer;
    FSelectedRowIndex: Integer;
    FFilterText: string;
    FFilterActive: Boolean;
    FIsOnlineSearchMode: Boolean;
    FMineralSourceIdx: Integer; // 0=Local, 1=NetEase, 2=Bilibili, 3=AppleMusic(AM), 4=QQ
    FSourceMenuOpen: Boolean;
    FSourceMenuHoverIdx: Integer;
    FOnlineQuery: string;
    FOnlineTracks: array of TOMMCondensedTrack;
    FOscilloscopeMode: Boolean;
    FLastSyncedTrackID: UInt32;

    // Cached SHM State
    FPlayState: UInt32;
    FPlayFlags: UInt32;
    FCurrentTrackID: UInt32;
    FPosMs: UInt32;
    FDurMs: UInt32;
    FVolume: Single;
    FSeekRatio: Single;
    FPluginState: UInt32;
    FPluginIdleSecs: UInt32;
    FPluginRssBytes: UInt64;
    FSampleRate: UInt32;
    FChannels: UInt16;
    FBitDepth: UInt16;
    FTitleStr: string;
    FArtistStr: string;
    FAlbumStr: string;
    FLocalMags: array[0..63] of Single;
    FLocalPeaks: array[0..63] of Single;
    FLocalOsc: array[0..511] of Single;
    FLastLibCheckTick: Int64;

    // Hit-test Rectangles
    FRectCloseBox, FRectMinBox, FRectMaxBox, FRectGrowBox: TRect;
    FRectBtnPrev, FRectBtnPlay, FRectBtnPause, FRectBtnStop, FRectBtnNext: TRect;
    FRectBtnFile: TRect;
    FRectVolSlider, FRectSeekSlider, FRectCRT: TRect;
    FRectFilterBox, FRectBtnNetSearch, FRectFilterClear: TRect;
    FRectSourceDropdown, FRectSourcePopup: TRect;
    FRectTrackList, FRectScrollUp, FRectScrollDown, FRectScrollTrack: TRect;
    FRectPluginWake, FRectPluginStream, FRectPluginUnload: TRect;

    // Mineral Account Login & Settings Modal State
    FSettingsOpen: Boolean;
    FSettingsTab: Integer; // 0 = NetEase (WY), 1 = Bilibili, 2 = QQ Music, 3 = Apple Music (AM)
    FNeteaseLoggedIn: Boolean;
    FBilibiliLoggedIn: Boolean;
    FQqLoggedIn: Boolean;
    FAmLoggedIn: Boolean;
    FNeteaseUID: string;
    FNeteaseTokenMask: string;
    FBilibiliUID: string;
    FBilibiliTokenMask: string;
    FQqUID: string;
    FQqTokenMask: string;
    FQqPtQrToken: Int32;
    FAmStorefront: string;
    FAmTokenMask: string;
    FQrActive: Boolean;
    FQrStatusText: string;
    FQrGridW, FQrGridH: Integer;
    FQrGrid: array[0..63, 0..63] of Boolean;
    FRectBtnSettings: TRect;
    FRectSetModal, FRectSetClose: TRect;
    FRectSetTabWY, FRectSetTabBili, FRectSetTabQQ, FRectSetTabAM: TRect;
    FRectSetBtnQR, FRectSetBtnCookie, FRectSetBtnLogout: TRect;

    // Right Sidebar Toggleable Lyrics / Track Information State
    FLyricsMode: Boolean;
    FLastLrcGen: UInt32;
    FLastOnlineLrcReqTrackID: UInt32;
    FGuiLyrics: array of TGuiLyricLine;
    FGuiLyricCount: Integer;
    FActiveLyricIdx: Integer;
    FLyricScrollY: Single;
    FLyricTargetScrollY: Single;
    FLyricManualScrollTick: Int64;
    FLyricCurFallback: string;
    FLyricNextFallback: string;
    FRectRightHeader: TRect;
    FRectDetailsCard: TRect;

    // Ultra-Low-Memory 42x42 Album Cover Thumbnail (5.2 KB static buffer)
    FCoverBmp: TBitmap;
    FHasCoverBmp: Boolean;
    FCoverLoadedPath: string;

    procedure EnsureCoverThumbLoaded(const ATrackPath: string);
    procedure ParseGuiLrcText(const RawLrc: string);
    procedure UpdateActiveLyricLine(PosMs: UInt32; ImmediateJump: Boolean = False);
    procedure RequestOnlineLyricsForCurrentTrack;
    procedure ConnectIPC;
    procedure DisconnectIPC;
    function SendSafePacket(const Packet: TOMMPacket): Boolean;
    procedure PlayTrack(TrackID: UInt32);
    procedure PlayRowAtIndex(RowIdx: Integer);
    procedure PlayURI(const AURI: string);
    procedure TriggerMineralOnlineSearch(const AQuery: string);
    procedure SelectMineralSource(ASourceIdx: Integer);
    function GetMineralSourceLabel(ASourceIdx: Integer; Compact: Boolean = False): string;
    function GetMineralSourcePrefix(ASourceIdx: Integer): string;
    function GetMineralConfigDir: string;
    procedure ReloadMineralAuthStatus;
    procedure StartMineralQRLogin;
    procedure StopMineralQRLogin;
    procedure PollMineralQRLogin;
    procedure PromptManualCookieInput;
    procedure ClearMineralLogout;
    procedure DrawMineralSettingsModal(C: TCanvas; W, H: Integer);
    procedure SendCommand(Opcode: UInt16);
    procedure SendSeekMs(TargetMs: UInt32);
    procedure SendVolume(Vol: Single);
    procedure RequestViewportPage(Offset, Limit: Integer);
    procedure RebuildFilteredList;
    procedure EdtFilterChange(Sender: TObject);
    procedure EdtFilterKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleIncomingPacket(const Packet: TOMMPacket);
    procedure GetTrackDetailsAtRow(RowIdx: Integer; out TID: UInt32;
      out ATitle, AArtist, AAlbum, ATime, AFmt, APath: string;
      out AYear, ATrackNo, ABitrate: UInt16; out ADurMs: UInt32);
    function VisibleTrackRows: Integer;
    procedure ScrollToRow(NewTopRow: Integer);
    procedure PromptScanDirectory;
    procedure ToggleMiniPlayer;
    procedure ToggleMaximizeWindow;
    function FormatDuration(Ms: UInt32): string;
    function FormatFormatTag(ATag: UInt16): string;

    procedure DrawMacTitleBar(C: TCanvas; W: Integer; const ATitle: string);
    procedure DrawMacButton(C: TCanvas; const R: TRect; const ACaption: string; IsDefault, IsPressed: Boolean);
    procedure DrawMacSunkenPanel(C: TCanvas; const R: TRect; BgColor: TColor);
    procedure DrawVinylDiscIcon(C: TCanvas; X, Y: Integer; IsSpinning: Boolean);
  public
  end;

var
  frmMain: TMainForm;

implementation

{$R *.lfm}

{$IFDEF LINUX}
function gdk_pixbuf_new_from_file_at_scale(filename: PAnsiChar; width, height: cint; preserve_aspect_ratio: LongBool; error: Pointer): Pointer; cdecl; external 'libgdk_pixbuf-2.0.so.0';
function gdk_pixbuf_get_pixels(pixbuf: Pointer): PByte; cdecl; external 'libgdk_pixbuf-2.0.so.0';
function gdk_pixbuf_get_rowstride(pixbuf: Pointer): cint; cdecl; external 'libgdk_pixbuf-2.0.so.0';
function gdk_pixbuf_get_n_channels(pixbuf: Pointer): cint; cdecl; external 'libgdk_pixbuf-2.0.so.0';
function gdk_pixbuf_get_width(pixbuf: Pointer): cint; cdecl; external 'libgdk_pixbuf-2.0.so.0';
function gdk_pixbuf_get_height(pixbuf: Pointer): cint; cdecl; external 'libgdk_pixbuf-2.0.so.0';
procedure g_object_unref(obj: Pointer); cdecl; external 'libgobject-2.0.so.0';
function malloc_trim(pad: csize_t): cint; cdecl; external 'libc.so.6';
{$ENDIF}

function SanitizeSingle(Val: Single; MinVal, MaxVal, DefVal: Single): Single;
begin
  if IsNan(Val) or IsInfinite(Val) then Exit(DefVal);
  if Val < MinVal then Exit(MinVal);
  if Val > MaxVal then Exit(MaxVal);
  Result := Val;
end;

function FitTextToWidth(C: TCanvas; const S: string; MaxPx: Integer): string;
var
  len: Integer;
begin
  if (S = '') or (MaxPx <= 8) then Exit('');
  if C.TextWidth(S) <= MaxPx then Exit(S);
  len := Length(S);
  while (len > 1) and (C.TextWidth(Copy(S, 1, len) + '...') > MaxPx) do
  begin
    while (len > 1) and ((Ord(S[len]) and $C0) = $80) do
      Dec(len);
    Dec(len);
  end;
  Result := Copy(S, 1, len) + '...';
end;

function TMainForm.FormatDuration(Ms: UInt32): string;
var
  Sec, Min: UInt32;
begin
  Sec := Ms div 1000;
  Min := Sec div 60;
  Sec := Sec mod 60;
  Result := Format('%.2d:%.2d', [Min, Sec]);
end;

function TMainForm.FormatFormatTag(ATag: UInt16): string;
begin
  case ATag of
    OMM_FORMAT_FLAC: Result := 'FLAC';
    OMM_FORMAT_MP3:  Result := 'MP3';
    OMM_FORMAT_OGG:  Result := 'OGG';
    OMM_FORMAT_WAV:  Result := 'WAV';
    OMM_FORMAT_AAC:  Result := 'M4A';
    6:               Result := 'APE';
    7:               Result := 'WV';
    8:               Result := 'DSD';
    9:               Result := 'MOD';
    else             Result := 'PCM';
  end;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  i: Integer;
  param: string;
begin
  BorderStyle := bsNone;
  DoubleBuffered := True;
  FBackBuffer := TBitmap.Create;
  FBackBuffer.PixelFormat := pf24bit;

  FCoverBmp := TBitmap.Create;
  FCoverBmp.PixelFormat := pf24bit;
  FCoverBmp.SetSize(42, 42);
  FHasCoverBmp := False;
  FCoverLoadedPath := '';

  FSocketFD := -1;
  FPShm := nil;
  FLibEngine := nil;
  FSeqCounter := 1;
  FLastSpectrumSeq := 0;

  FIsDraggingWin := False;
  FIsResizingWin := False;
  FIsMiniMode := False;
  FIsMaximizedMode := False;
  FSavedNormalBounds := Bounds(Left, Top, 980, 640);

  FIsDraggingSeek := False;
  FIsUpdatingSeekUI := False;
  FIsDraggingVol := False;
  FIsDraggingScroll := False;
  FActivePressedBtn := 0;
  FLastClickedRow := -1;
  FLastRowClickTick := 0;

  FTestTimeoutSecs := 0;
  FHeadlessTestMode := False;
  FStartTimeTick := GetTickCount64;

  FSocketPath := OMM_DEFAULT_SOCKET_PATH;
  FShmPath := OMM_SHM_NAME;
  FMusicDirPath := '';

  if DirectoryExists(GetEnvironmentVariable('HOME') + '/.cache/mineral/audio/netease') then
    FMusicDirPath := GetEnvironmentVariable('HOME') + '/.cache/mineral/audio/netease'
  else if DirectoryExists(GetEnvironmentVariable('HOME') + '/.cache/mineral/audio') then
    FMusicDirPath := GetEnvironmentVariable('HOME') + '/.cache/mineral/audio';

  FTotalTracks := 0;
  FCacheStart := -1;
  FCacheCount := 0;
  FReceivingItemsRemaining := 0;

  FTopRowIndex := 0;
  FSelectedRowIndex := 0;
  FFilterText := '';
  FFilterActive := False;
  FOscilloscopeMode := False;
  FLastSyncedTrackID := 0;

  FLyricsMode := False;
  FLastLrcGen := 0;
  FLastOnlineLrcReqTrackID := 0;
  FGuiLyricCount := 0;
  FActiveLyricIdx := 0;
  FLyricScrollY := 0.0;
  FLyricTargetScrollY := 0.0;
  FLyricManualScrollTick := 0;
  FLyricCurFallback := '';
  FLyricNextFallback := '';
  SetLength(FGuiLyrics, 0);
  FRectRightHeader := Rect(0, 0, 0, 0);
  FRectDetailsCard := Rect(0, 0, 0, 0);

  FSettingsOpen := False;
  FSettingsTab := 0;
  FNeteaseLoggedIn := False;
  FBilibiliLoggedIn := False;
  FNeteaseUID := '';
  FNeteaseTokenMask := '';
  FBilibiliUID := '';
  FBilibiliTokenMask := '';
  FQrActive := False;
  FQrStatusText := 'Ready — Select QR Login or Paste Cookie';
  FQrGridW := 0;
  FQrGridH := 0;
  FillChar(FQrGrid, SizeOf(FQrGrid), 0);
  ReloadMineralAuthStatus;

  FPlayState := OMM_STATE_STOPPED;
  FPlayFlags := 0;
  FCurrentTrackID := 0;
  FPosMs := 0;
  FDurMs := 0;
  FVolume := 1.0;
  FSeekRatio := 0.0;
  FPluginState := OMM_PLUGIN_UNLOADED;
  FPluginIdleSecs := 0;
  FPluginRssBytes := 0;
  FSampleRate := 48000;
  FChannels := 2;
  FBitDepth := 32;
  FTitleStr := 'Ready — Select a Track';
  FArtistStr := 'Oh-Mini-Mineral Classic Macintosh Deck';
  FAlbumStr := '';

  FillChar(FLocalMags, SizeOf(FLocalMags), 0);
  FillChar(FLocalPeaks, SizeOf(FLocalPeaks), 0);
  FillChar(FLocalOsc, SizeOf(FLocalOsc), 0);

  for i := 1 to ParamCount do
  begin
    param := ParamStr(i);
    if (param = '--headless-test') or (param = '--test-mode') then
    begin
      FHeadlessTestMode := True;
      if FTestTimeoutSecs = 0 then FTestTimeoutSecs := 1;
    end
    else if (param = '--test-timeout') and (i < ParamCount) then
      FTestTimeoutSecs := StrToIntDef(ParamStr(i + 1), 2)
    else if (param = '--socket') and (i < ParamCount) then
      FSocketPath := ParamStr(i + 1)
    else if (param = '--shm') and (i < ParamCount) then
      FShmPath := ParamStr(i + 1);
  end;

  FEdtFilter := TEdit.Create(Self);
  FEdtFilter.Parent := Self;
  FEdtFilter.BorderStyle := bsNone;
  FEdtFilter.SetBounds(-500, -500, 120, 22);
  FEdtFilter.Color := clWhite;
  FEdtFilter.Font.Name := 'Sans';
  FEdtFilter.Font.Size := 8;
  FEdtFilter.Font.Color := clBlack;
  FEdtFilter.TextHint := 'Search tracks...';
  FEdtFilter.OnChange := @EdtFilterChange;
  FEdtFilter.OnKeyDown := @EdtFilterKeyDown;

  FPShm := OpenSharedMemory(FShmPath, True);
  ConnectIPC;
  if (FSocketFD < 0) and (not FHeadlessTestMode) and (FSocketPath = OMM_DEFAULT_SOCKET_PATH) then
  begin
    if FileExists(ExtractFilePath(ParamStr(0)) + 'omm_daemon' + {$IFDEF WINDOWS}'.exe'{$ELSE}''{$ENDIF}) then
      SpawnDaemonBackground(ExtractFilePath(ParamStr(0)) + 'omm_daemon' + {$IFDEF WINDOWS}'.exe'{$ELSE}''{$ENDIF})
    else if FileExists('/usr/bin/omm_daemon') then
      SpawnDaemonBackground('/usr/bin/omm_daemon');
    for i := 1 to 15 do
    begin
      Sleep(25);
      ConnectIPC;
      if FSocketFD >= 0 then Break;
    end;
    if FPShm = nil then
      FPShm := OpenSharedMemory(FShmPath, True);
  end;

  FLibEngine := TOMMLibraryEngine.Create(FMusicDirPath, OMM_DEFAULT_LIBRARY_PATH);
  FLibEngine.OpenLibrary;
  RebuildFilteredList;

  RequestViewportPage(0, MAX_CACHE_ITEMS);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  StopMineralQRLogin;
  DisconnectIPC;
  if FPShm <> nil then
  begin
    CloseSharedMemory(FPShm);
    FPShm := nil;
  end;
  if FLibEngine <> nil then
  begin
    FLibEngine.Free;
    FLibEngine := nil;
  end;
  if FBackBuffer <> nil then
  begin
    FBackBuffer.Free;
    FBackBuffer := nil;
  end;
  if FCoverBmp <> nil then
  begin
    FCoverBmp.Free;
    FCoverBmp := nil;
  end;
end;

procedure TMainForm.FormResize(Sender: TObject);
begin
  pbMac.Invalidate;
end;

function ExtractJsonField(const S, Key: string): string; forward;

function ExtractAudioCoverToFile(const AudioPath, OutImgPath: string): Boolean;
{$IFDEF UNIX}
var
  fdIn, fdOut: cint;
  hdr: array[0..9] of Byte;
  chunk: array[0..4095] of Byte;
  apicHdr: array[0..255] of Byte;
  tagSize, scanPos, scanEnd, apicPos, imgOffset, frameSize, copyRem: Int64;
  nRead, i, headRead, toRead: cint;
  ver: Byte;
  b0, b1, b2, b3: UInt32;
  isLastBlock: Boolean;
{$ENDIF}
begin
  Result := False;
  {$IFDEF UNIX}
  fdIn := fpOpen(PChar(AudioPath), O_RDONLY);
  if fdIn < 0 then Exit;
  try
    if fpRead(fdIn, hdr[0], 10) <> 10 then Exit;

    // 1. ID3v2 (MP3 / TrueHD / etc.) with zero-heap 4 KB stack chunk scanner
    if (hdr[0] = Ord('I')) and (hdr[1] = Ord('D')) and (hdr[2] = Ord('3')) then
    begin
      ver := hdr[3];
      tagSize := ((Int64(hdr[6]) and $7F) shl 21) or
                 ((Int64(hdr[7]) and $7F) shl 14) or
                 ((Int64(hdr[8]) and $7F) shl 7) or
                 (Int64(hdr[9]) and $7F);
      if tagSize <= 32 then Exit;

      scanEnd := 10 + Min(tagSize, 131072);
      scanPos := 10;
      apicPos := -1;
      while scanPos < scanEnd do
      begin
        if fpLseek(fdIn, scanPos, SEEK_SET) < 0 then Break;
        nRead := fpRead(fdIn, chunk[0], Min(Int64(SizeOf(chunk)), scanEnd - scanPos));
        if nRead < 8 then Break;
        for i := 0 to nRead - 5 do
        begin
          if (chunk[i] = Ord('A')) and (chunk[i + 1] = Ord('P')) and
             (chunk[i + 2] = Ord('I')) and (chunk[i + 3] = Ord('C')) then
          begin
            apicPos := scanPos + i;
            Break;
          end;
        end;
        if apicPos >= 0 then Break;
        Inc(scanPos, nRead - 4);
      end;

      if apicPos >= 10 then
      begin
        if fpLseek(fdIn, apicPos, SEEK_SET) < 0 then Exit;
        headRead := fpRead(fdIn, apicHdr[0], SizeOf(apicHdr));
        if headRead < 24 then Exit;

        b0 := apicHdr[4]; b1 := apicHdr[5]; b2 := apicHdr[6]; b3 := apicHdr[7];
        if ver = 4 then
        begin
          frameSize := ((b0 and $7F) shl 21) or ((b1 and $7F) shl 14) or ((b2 and $7F) shl 7) or (b3 and $7F);
          if (frameSize < 64) or (apicPos + 10 + frameSize > 10 + tagSize) then
            frameSize := (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3;
        end
        else
          frameSize := (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3;

        if (frameSize <= 32) or (frameSize > 8388608) then
          frameSize := (10 + tagSize) - (apicPos + 10);

        imgOffset := -1;
        for i := 10 to headRead - 4 do
        begin
          if ((apicHdr[i] = $FF) and (apicHdr[i + 1] = $D8) and (apicHdr[i + 2] = $FF)) or
             ((apicHdr[i] = $89) and (apicHdr[i + 1] = Ord('P')) and (apicHdr[i + 2] = Ord('N')) and (apicHdr[i + 3] = Ord('G'))) then
          begin
            imgOffset := apicPos + i;
            Break;
          end;
        end;

        if imgOffset > apicPos then
        begin
          copyRem := Min((10 + tagSize) - imgOffset, frameSize - (imgOffset - (apicPos + 10)));
          if (copyRem > 32) and (copyRem <= 8388608) then
          begin
            if fpLseek(fdIn, imgOffset, SEEK_SET) >= 0 then
            begin
              fdOut := fpOpen(PChar(OutImgPath), O_WRONLY or O_CREAT or O_TRUNC, &600);
              if fdOut >= 0 then
              begin
                while copyRem > 0 do
                begin
                  toRead := Min(Int64(SizeOf(chunk)), copyRem);
                  nRead := fpRead(fdIn, chunk[0], toRead);
                  if nRead <= 0 then Break;
                  fpWrite(fdOut, chunk[0], nRead);
                  Dec(copyRem, nRead);
                end;
                fpClose(fdOut);
                Result := True;
              end;
            end;
          end;
        end;
      end;
    end
    // 2. FLAC METADATA_BLOCK_PICTURE (Block Type 6)
    else if (hdr[0] = Ord('f')) and (hdr[1] = Ord('L')) and (hdr[2] = Ord('a')) and (hdr[3] = Ord('C')) then
    begin
      scanPos := 4;
      isLastBlock := False;
      while (not isLastBlock) and (scanPos < 8388608) do
      begin
        if fpLseek(fdIn, scanPos, SEEK_SET) < 0 then Break;
        if fpRead(fdIn, hdr[0], 4) <> 4 then Break;
        isLastBlock := (hdr[0] and $80) <> 0;
        ver := hdr[0] and $7F;
        frameSize := (Int64(hdr[1]) shl 16) or (Int64(hdr[2]) shl 8) or Int64(hdr[3]);
        if (ver = 6) and (frameSize > 64) and (frameSize <= 8388608) then
        begin
          headRead := fpRead(fdIn, apicHdr[0], SizeOf(apicHdr));
          imgOffset := -1;
          for i := 0 to headRead - 4 do
          begin
            if ((apicHdr[i] = $FF) and (apicHdr[i + 1] = $D8) and (apicHdr[i + 2] = $FF)) or
               ((apicHdr[i] = $89) and (apicHdr[i + 1] = Ord('P')) and (apicHdr[i + 2] = Ord('N')) and (apicHdr[i + 3] = Ord('G'))) then
            begin
              imgOffset := scanPos + 4 + i;
              Break;
            end;
          end;
          if imgOffset > scanPos then
          begin
            copyRem := (scanPos + 4 + frameSize) - imgOffset;
            if fpLseek(fdIn, imgOffset, SEEK_SET) >= 0 then
            begin
              fdOut := fpOpen(PChar(OutImgPath), O_WRONLY or O_CREAT or O_TRUNC, &600);
              if fdOut >= 0 then
              begin
                while copyRem > 0 do
                begin
                  toRead := Min(Int64(SizeOf(chunk)), copyRem);
                  nRead := fpRead(fdIn, chunk[0], toRead);
                  if nRead <= 0 then Break;
                  fpWrite(fdOut, chunk[0], nRead);
                  Dec(copyRem, nRead);
                end;
                fpClose(fdOut);
                Result := True;
              end;
            end;
          end;
          Break;
        end;
        Inc(scanPos, 4 + frameSize);
      end;
    end;
  finally
    fpClose(fdIn);
  end;
  {$ENDIF}
end;

procedure TMainForm.EnsureCoverThumbLoaded(const ATrackPath: string);
{$IFDEF UNIX}
var
  cleanPath, cacheFn, tmpImgFn, songId: string;
  hVal: QWord;
  i, x, y, fd, idx: cint;
  rgbBuf: array[0..5291] of Byte;
  {$IFDEF LINUX}
  rowstride, nchan, w, h: cint;
  pixbuf: Pointer;
  pixels, pRow: PByte;
  {$ENDIF}
{$ENDIF}
begin
  if ATrackPath = FCoverLoadedPath then Exit;
  FCoverLoadedPath := ATrackPath;
  FHasCoverBmp := False;
  if (ATrackPath = '') or (FCoverBmp = nil) then Exit;

  {$IFDEF UNIX}
  cleanPath := ATrackPath;
  if Copy(cleanPath, 1, 7) = 'file://' then
    cleanPath := Copy(cleanPath, 8, Length(cleanPath) - 7);

  // Compute 64-bit FNV-1a hash for 5,292-byte raw RGB thumbnail cache in /tmp
  hVal := QWord($CBF29CE484222325);
  for i := 1 to Length(cleanPath) do
  begin
    hVal := hVal xor QWord(Ord(cleanPath[i]));
    hVal := hVal * QWord($100000001B3);
  end;
  cacheFn := '/tmp/omm_cov_' + IntToHex(hVal, 16) + '.rgb';

  // Fast Path: Read 5,292-byte raw 42x42 RGB24 cache directly with zero image decoding!
  if FileExists(cacheFn) then
  begin
    fd := fpOpen(PChar(cacheFn), O_RDONLY);
    if fd >= 0 then
    begin
      if fpRead(fd, rgbBuf[0], SizeOf(rgbBuf)) = SizeOf(rgbBuf) then
      begin
        fpClose(fd);
        idx := 0;
        for y := 0 to 41 do
          for x := 0 to 41 do
          begin
            FCoverBmp.Canvas.Pixels[x, y] := RGBToColor(rgbBuf[idx], rgbBuf[idx + 1], rgbBuf[idx + 2]);
            Inc(idx, 3);
          end;
        FHasCoverBmp := True;
        Exit;
      end;
      fpClose(fd);
    end;
  end;

  tmpImgFn := '/tmp/omm_cov_extract.img';
  DeleteFile(tmpImgFn);

  if FileExists(cleanPath) then
  begin
    if not ExtractAudioCoverToFile(cleanPath, tmpImgFn) then
    begin
      if FileExists(ExtractFilePath(cleanPath) + 'cover.jpg') then
        tmpImgFn := ExtractFilePath(cleanPath) + 'cover.jpg'
      else if FileExists(ChangeFileExt(cleanPath, '.jpg')) then
        tmpImgFn := ChangeFileExt(cleanPath, '.jpg');
    end;
  end
  else if Pos('netease://', cleanPath) = 1 then
  begin
    songId := Copy(cleanPath, 11, 64);
    if Pos('track/', songId) = 1 then
      songId := Copy(songId, 7, 64);
    if songId <> '' then
      fpSystem('u=$(curl -sL --max-time 3 "https://music.163.com/api/song/detail/?id=' + songId + '&ids=%5B' + songId + '%5D" | grep -oE ''"picUrl":"https?://[^"]+"'' | grep -v "5639395138885805" | tail -n 1 | cut -d''"'' -f4); [ -n "$u" ] && curl -sL --max-time 3 -o "' + tmpImgFn + '" "${u}?param=84y84" >/dev/null 2>&1');
  end
  else if Pos('bilibili://', cleanPath) = 1 then
  begin
    songId := Copy(cleanPath, 12, 64);
    if songId <> '' then
      fpSystem('u=$(curl -sL --max-time 3 "https://api.bilibili.com/x/web-interface/view?bvid=' + songId + '" | grep -oE ''"pic":"https?://[^"]+"'' | head -n 1 | cut -d''"'' -f4); [ -n "$u" ] && curl -sL --max-time 3 -o "' + tmpImgFn + '" "${u}@84w_84h.jpg" >/dev/null 2>&1');
  end
  else if Pos('qq://', cleanPath) = 1 then
  begin
    songId := Copy(cleanPath, 6, 64);
    if Pos('track/', songId) = 1 then
      songId := Copy(songId, 7, 64);
    if songId <> '' then
      fpSystem('m=$(curl -sL --max-time 3 "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=' + songId + '&tpl=yqq_song_detail&format=json" | grep -oE ''"album":\{[^}]*"mid":"[^"]+"'' | head -n 1 | grep -oE ''"mid":"[^"]+"'' | cut -d''"'' -f4); [ -n "$m" ] && curl -sL --max-time 3 -o "' + tmpImgFn + '" "https://y.gtimg.cn/music/photo_new/T002R90x90M000${m}.jpg" >/dev/null 2>&1');
  end
  else if Pos('applemusic://', cleanPath) = 1 then
  begin
    songId := Copy(cleanPath, 14, 64);
    if songId <> '' then
      fpSystem('u=$(curl -sL --max-time 3 "https://itunes.apple.com/lookup?id=' + songId + '" | grep -oE ''"artworkUrl100":"https?://[^"]+"'' | head -n 1 | cut -d''"'' -f4); [ -n "$u" ] && curl -sL --max-time 3 -o "' + tmpImgFn + '" "$u" >/dev/null 2>&1');
  end;

  if FileExists(tmpImgFn) then
  begin
    {$IFDEF LINUX}
    // Decode at 42x42 scale directly via gdk-pixbuf DCT scaling in C heap, then trim
    pixbuf := gdk_pixbuf_new_from_file_at_scale(PAnsiChar(tmpImgFn), 42, 42, False, nil);
    if pixbuf <> nil then
    begin
      pixels := gdk_pixbuf_get_pixels(pixbuf);
      rowstride := gdk_pixbuf_get_rowstride(pixbuf);
      nchan := gdk_pixbuf_get_n_channels(pixbuf);
      w := gdk_pixbuf_get_width(pixbuf);
      h := gdk_pixbuf_get_height(pixbuf);
      if (pixels <> nil) and (w >= 42) and (h >= 42) and (nchan >= 3) then
      begin
        idx := 0;
        for y := 0 to 41 do
        begin
          pRow := pixels + (y * rowstride);
          for x := 0 to 41 do
          begin
            rgbBuf[idx]     := pRow[x * nchan];
            rgbBuf[idx + 1] := pRow[x * nchan + 1];
            rgbBuf[idx + 2] := pRow[x * nchan + 2];
            FCoverBmp.Canvas.Pixels[x, y] := RGBToColor(rgbBuf[idx], rgbBuf[idx + 1], rgbBuf[idx + 2]);
            Inc(idx, 3);
          end;
        end;
        fd := fpOpen(PChar(cacheFn), O_WRONLY or O_CREAT or O_TRUNC, &600);
        if fd >= 0 then
        begin
          fpWrite(fd, rgbBuf[0], SizeOf(rgbBuf));
          fpClose(fd);
        end;
        FHasCoverBmp := True;
      end;
      g_object_unref(pixbuf);
    end;
    if tmpImgFn = '/tmp/omm_cov_extract.img' then
      DeleteFile(tmpImgFn);
    malloc_trim(0);
    {$ELSE}
    fpSystem('ffmpeg -y -v error -i "' + tmpImgFn + '" -vf scale=42:42 -frames:v 1 -f rawvideo -pix_fmt rgb24 "' + cacheFn + '" >/dev/null 2>&1');
    if tmpImgFn = '/tmp/omm_cov_extract.img' then
      DeleteFile(tmpImgFn);
    if FileExists(cacheFn) then
    begin
      fd := fpOpen(PChar(cacheFn), O_RDONLY);
      if fd >= 0 then
      begin
        if fpRead(fd, rgbBuf[0], SizeOf(rgbBuf)) = SizeOf(rgbBuf) then
        begin
          idx := 0;
          for y := 0 to 41 do
            for x := 0 to 41 do
            begin
              FCoverBmp.Canvas.Pixels[x, y] := RGBToColor(rgbBuf[idx], rgbBuf[idx + 1], rgbBuf[idx + 2]);
              Inc(idx, 3);
            end;
          FHasCoverBmp := True;
        end;
        fpClose(fd);
      end;
    end;
    {$ENDIF}
  end;
  {$ENDIF}
end;

procedure TMainForm.ParseGuiLrcText(const RawLrc: string);
var
  lineStart, lineEnd, n, p, closePos, colonPos, dotPos: Integer;
  lineStr, tagStr, minStr, secStr, fracStr, textPart: string;
  mins, secs, frac, code: Integer;
  tsMs: UInt32;
  hasTs: Boolean;
begin
  FGuiLyricCount := 0;
  SetLength(FGuiLyrics, 0);
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
    if lineStr = '' then Continue;

    hasTs := False;
    tsMs := 0;
    p := 1;
    while (p <= Length(lineStr)) and (lineStr[p] = '[') do
    begin
      closePos := Pos(']', Copy(lineStr, p, Length(lineStr) - p + 1));
      if closePos <= 1 then Break;
      tagStr := Copy(lineStr, p + 1, closePos - 2);
      colonPos := Pos(':', tagStr);
      if colonPos > 1 then
      begin
        minStr := Copy(tagStr, 1, colonPos - 1);
        Val(minStr, mins, code);
        if code = 0 then
        begin
          dotPos := Pos('.', tagStr);
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
            if Length(fracStr) = 1 then frac := frac * 100
            else if Length(fracStr) = 2 then frac := frac * 10
            else if Length(fracStr) > 3 then
              while frac >= 1000 do frac := frac div 10;
            tsMs := UInt32(Max(0, mins)) * 60000 + UInt32(Max(0, secs)) * 1000 + UInt32(Max(0, frac));
            hasTs := True;
            p := p + closePos;
            Continue;
          end;
        end;
      end;
      p := p + closePos;
    end;

    if hasTs then
    begin
      textPart := Trim(Copy(lineStr, p, Length(lineStr) - p + 1));
      if textPart <> '' then
      begin
        if FGuiLyricCount >= Length(FGuiLyrics) then
          SetLength(FGuiLyrics, Max(32, Length(FGuiLyrics) * 2));
        FGuiLyrics[FGuiLyricCount].TimestampMs := tsMs;
        FGuiLyrics[FGuiLyricCount].Text := textPart;
        Inc(FGuiLyricCount);
      end;
    end;
  end;

  if (FGuiLyricCount > 0) and (FGuiLyrics[0].TimestampMs >= 8000) then
  begin
    if FGuiLyricCount >= Length(FGuiLyrics) then
      SetLength(FGuiLyrics, FGuiLyricCount + 8);
    for p := FGuiLyricCount downto 1 do
      FGuiLyrics[p] := FGuiLyrics[p - 1];
    FGuiLyrics[0].TimestampMs := 0;
    FGuiLyrics[0].Text := '♫ Instrumental Intro...';
    Inc(FGuiLyricCount);
  end;

  FActiveLyricIdx := 0;
  FLyricScrollY := 0.0;
  FLyricTargetScrollY := 0.0;
end;

procedure TMainForm.UpdateActiveLyricLine(PosMs: UInt32; ImmediateJump: Boolean);
var
  i, idx, visH, centerOff, maxScroll: Integer;
begin
  if FGuiLyricCount <= 0 then
  begin
    FActiveLyricIdx := 0;
    FLyricTargetScrollY := 0.0;
    FLyricScrollY := 0.0;
    Exit;
  end;

  idx := 0;
  for i := 0 to FGuiLyricCount - 1 do
  begin
    if FGuiLyrics[i].TimestampMs <= PosMs then
      idx := i
    else
      Break;
  end;

  FActiveLyricIdx := idx;
  if GetTickCount64 - FLyricManualScrollTick > 2500 then
  begin
    visH := Max(88, FRectDetailsCard.Height - 12);
    centerOff := Max(0, (visH - LYRIC_LINE_H) div 2);
    maxScroll := Max(0, FGuiLyricCount * LYRIC_LINE_H - visH);
    FLyricTargetScrollY := EnsureRange(idx * LYRIC_LINE_H - centerOff, 0, maxScroll);
  end;

  if ImmediateJump then
    FLyricScrollY := FLyricTargetScrollY;
end;

procedure TMainForm.RequestOnlineLyricsForCurrentTrack;
var
  pkt: TOMMPacket;
begin
  if (FCurrentTrackID = 0) or (FCurrentTrackID = FLastOnlineLrcReqTrackID) then Exit;
  FLastOnlineLrcReqTrackID := FCurrentTrackID;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_PLUGIN_WAKE, FSeqCounter);
  pkt.Payload.Raw[0] := 1; // Trigger Router.RefreshLyricsIfNeeded
  SendSafePacket(pkt);
end;

procedure TMainForm.ConnectIPC;
begin
  if FSocketFD >= 0 then DisconnectIPC;
  FSocketFD := CreateUnixSocket;
  if FSocketFD >= 0 then
  begin
    if ConnectUnixSocket(FSocketFD, FSocketPath) then
      SetSocketNonBlocking(FSocketFD)
    else
    begin
      fpClose(FSocketFD);
      FSocketFD := -1;
    end;
  end;
end;

procedure TMainForm.DisconnectIPC;
begin
  if FSocketFD >= 0 then
  begin
    fpClose(FSocketFD);
    FSocketFD := -1;
  end;
end;

function TMainForm.SendSafePacket(const Packet: TOMMPacket): Boolean;
begin
  Result := False;
  if FSocketFD < 0 then ConnectIPC;
  if FSocketFD >= 0 then
  begin
    Result := SendPacket(FSocketFD, Packet);
    if not Result then
    begin
      DisconnectIPC;
      ConnectIPC;
      if FSocketFD >= 0 then
      begin
        Result := SendPacket(FSocketFD, Packet);
        if not Result then DisconnectIPC;
      end;
    end;
  end;
end;

procedure TMainForm.PlayTrack(TrackID: UInt32);
var
  pkt: TOMMPacket;
begin
  if TrackID = 0 then Exit;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_PLAY_TRACK_ID, FSeqCounter);
  pkt.Payload.TrackID := TrackID;
  SendSafePacket(pkt);
end;

procedure TMainForm.PlayRowAtIndex(RowIdx: Integer);
var
  tid: UInt32;
  tTitle, tArtist, tAlbum, tTime, tFmt, tPath: string;
  tYear, tTrackNo, tBitrate: UInt16;
  tDurMs: UInt32;
  visRows: Integer;
begin
  if (RowIdx < 0) or (RowIdx >= FTotalTracks) then Exit;
  FSelectedRowIndex := RowIdx;
  visRows := VisibleTrackRows;
  if FSelectedRowIndex < FTopRowIndex then
    FTopRowIndex := FSelectedRowIndex
  else if FSelectedRowIndex >= FTopRowIndex + visRows then
    FTopRowIndex := Max(0, FSelectedRowIndex - visRows + 1);

  GetTrackDetailsAtRow(RowIdx, tid, tTitle, tArtist, tAlbum, tTime, tFmt, tPath, tYear, tTrackNo, tBitrate, tDurMs);
  if tid > 0 then
  begin
    FLastRowClickTick := GetTickCount64;
    FCurrentTrackID := tid;
    FLastSyncedTrackID := tid;
    FTitleStr := tTitle;
    FArtistStr := tArtist;
    FAlbumStr := tAlbum;
    if tDurMs > 0 then FDurMs := tDurMs;
    FPosMs := 0;
    FSeekRatio := 0.0;
    FPlayState := OMM_STATE_PLAYING;
    if Pos('://', tPath) > 0 then
      PlayURI(tPath)
    else
      PlayTrack(tid);
    pbMac.Invalidate;
  end;
end;

function TMainForm.GetMineralSourceLabel(ASourceIdx: Integer; Compact: Boolean): string;
begin
  case ASourceIdx of
    1: if Compact then Result := 'NetEase (WY)' else Result := 'NetEase Cloud (WY)';
    2: if Compact then Result := 'Bilibili'     else Result := 'Bilibili Audio (BILI)';
    3: if Compact then Result := 'Apple Music'  else Result := 'Apple Music (AM)';
    4: if Compact then Result := 'QQ Music'     else Result := 'QQ Music (QQ)';
    5: if Compact then Result := 'AList Drive'  else Result := 'AList / WebDAV (ALIST)';
    else
      if Compact then Result := 'Local Library' else Result := 'Local Library (LOCAL)';
  end;
end;

function TMainForm.GetMineralSourcePrefix(ASourceIdx: Integer): string;
begin
  case ASourceIdx of
    1: Result := 'netease:';
    2: Result := 'bilibili:';
    3: Result := 'am:';
    4: Result := 'qq:';
    else Result := '';
  end;
end;

procedure TMainForm.SelectMineralSource(ASourceIdx: Integer);
begin
  FMineralSourceIdx := EnsureRange(ASourceIdx, 0, 5);
  FSourceMenuOpen := False;
  FSourceMenuHoverIdx := -1;
  if FMineralSourceIdx = 0 then
    RebuildFilteredList
  else if FMineralSourceIdx = 5 then
    PromptScanDirectory
  else
  begin
    FIsOnlineSearchMode := True;
    if Trim(FFilterText) <> '' then
      TriggerMineralOnlineSearch(FFilterText)
    else
    begin
      FOnlineQuery := '';
      SetLength(FOnlineTracks, 0);
      FTotalTracks := 0;
      FSelectedRowIndex := -1;
      if (FEdtFilter <> nil) and FEdtFilter.Visible and FEdtFilter.CanFocus then
        FEdtFilter.SetFocus;
    end;
  end;
  pbMac.Invalidate;
end;

procedure TMainForm.TriggerMineralOnlineSearch(const AQuery: string);
var
  pkt: TOMMPacket;
  q, fullQuery: string;
  len: Integer;
begin
  q := Trim(AQuery);
  if Pos('netease:', q) = 1 then
  begin
    FMineralSourceIdx := 1;
    q := Trim(Copy(q, 9, 255));
  end
  else if Pos('bilibili:', q) = 1 then
  begin
    FMineralSourceIdx := 2;
    q := Trim(Copy(q, 10, 255));
  end
  else if Pos('am:', q) = 1 then
  begin
    FMineralSourceIdx := 3;
    q := Trim(Copy(q, 4, 255));
  end
  else if Pos('qq:', q) = 1 then
  begin
    FMineralSourceIdx := 4;
    q := Trim(Copy(q, 4, 255));
  end
  else if FMineralSourceIdx = 0 then
    FMineralSourceIdx := 1;

  if q = '' then
  begin
    FIsOnlineSearchMode := True;
    if (FEdtFilter <> nil) and FEdtFilter.Visible and FEdtFilter.CanFocus then
      FEdtFilter.SetFocus;
    pbMac.Invalidate;
    Exit;
  end;
  FOnlineQuery := q;
  FFilterText := q;
  if (FEdtFilter <> nil) and (FEdtFilter.Text <> q) then
    FEdtFilter.Text := q;
  FIsOnlineSearchMode := True;
  SetLength(FOnlineTracks, 0);
  FTotalTracks := 0;
  FReceivingItemsRemaining := -1;
  fullQuery := GetMineralSourcePrefix(FMineralSourceIdx) + q;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_MINERAL_SEARCH, FSeqCounter);
  len := Min(Length(fullQuery), 479);
  Move(fullQuery[1], pkt.Payload.URI[0], len);
  SendSafePacket(pkt);
  pbMac.Invalidate;
end;

procedure TMainForm.RebuildFilteredList;
var
  i, n, matchCount: Cardinal;
  q, sTitle, sArtist, sAlbum: string;
  pRec: POMMTrackRecord;
begin
  FIsOnlineSearchMode := False;
  SetLength(FOnlineTracks, 0);
  if (FLibEngine = nil) or (not FLibEngine.IsOpen) then
  begin
    SetLength(FFilteredIndices, 0);
    FTotalTracks := 0;
    Exit;
  end;
  n := FLibEngine.TrackCount;
  q := LowerCase(Trim(FFilterText));
  SetLength(FFilteredIndices, n);
  matchCount := 0;
  if n > 0 then
  begin
    for i := 0 to n - 1 do
    begin
      if q = '' then
      begin
        FFilteredIndices[matchCount] := i;
        Inc(matchCount);
      end
      else
      begin
        pRec := FLibEngine.GetRecordByIndex(i);
        if pRec <> nil then
        begin
          sTitle  := LowerCase(StrPas(@pRec^.Title[0]));
          sArtist := LowerCase(StrPas(@pRec^.Artist[0]));
          sAlbum  := LowerCase(StrPas(@pRec^.Album[0]));
          if (Pos(q, sTitle) > 0) or (Pos(q, sArtist) > 0) or (Pos(q, sAlbum) > 0) then
          begin
            FFilteredIndices[matchCount] := i;
            Inc(matchCount);
          end;
        end;
      end;
    end;
  end;
  SetLength(FFilteredIndices, matchCount);
  FTotalTracks := Integer(matchCount);
  FTopRowIndex := 0;
  if FTotalTracks > 0 then
  begin
    FSelectedRowIndex := 0;
    if FCurrentTrackID > 0 then
    begin
      for i := 0 to matchCount - 1 do
      begin
        pRec := FLibEngine.GetRecordByIndex(FFilteredIndices[i]);
        if (pRec <> nil) and (pRec^.TrackID = FCurrentTrackID) then
        begin
          FSelectedRowIndex := Integer(i);
          if Integer(i) >= VisibleTrackRows then
            FTopRowIndex := Max(0, Integer(i) - 6);
          Break;
        end;
      end;
    end;
  end
  else
    FSelectedRowIndex := -1;
end;

procedure TMainForm.EdtFilterChange(Sender: TObject);
begin
  if FEdtFilter = nil then Exit;
  FFilterText := FEdtFilter.Text;
  if FMineralSourceIdx in [1..4] then
    FIsOnlineSearchMode := True
  else
    RebuildFilteredList;
  pbMac.Invalidate;
end;

procedure TMainForm.EdtFilterKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    if FEdtFilter <> nil then FEdtFilter.Text := '';
    FFilterText := '';
    if not (FMineralSourceIdx in [1..4]) then
      RebuildFilteredList;
    pbMac.Invalidate;
    Key := 0;
  end
  else if Key = VK_RETURN then
  begin
    if (Trim(FFilterText) <> '') and ((FMineralSourceIdx in [1..4]) or (FTotalTracks = 0) or FIsOnlineSearchMode) then
      TriggerMineralOnlineSearch(FFilterText)
    else if FSelectedRowIndex >= 0 then
      PlayRowAtIndex(FSelectedRowIndex);
    Key := 0;
  end
  else if Key = VK_DOWN then
  begin
    if FSelectedRowIndex < FTotalTracks - 1 then
    begin
      Inc(FSelectedRowIndex);
      if FSelectedRowIndex >= FTopRowIndex + VisibleTrackRows then
        ScrollToRow(FSelectedRowIndex - VisibleTrackRows + 1);
      pbMac.Invalidate;
    end;
    Key := 0;
  end
  else if Key = VK_UP then
  begin
    if FSelectedRowIndex > 0 then
    begin
      Dec(FSelectedRowIndex);
      if FSelectedRowIndex < FTopRowIndex then ScrollToRow(FSelectedRowIndex);
      pbMac.Invalidate;
    end;
    Key := 0;
  end;
end;

procedure TMainForm.PlayURI(const AURI: string);
var
  pkt: TOMMPacket;
  len: Integer;
begin
  if AURI = '' then Exit;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_PLAY_URI, FSeqCounter);
  len := Min(Length(AURI), 479);
  Move(AURI[1], pkt.Payload.URI[0], len);
  SendSafePacket(pkt);
end;

procedure TMainForm.SendCommand(Opcode: UInt16);
var
  pkt: TOMMPacket;
begin
  Inc(FSeqCounter);
  InitPacket(pkt, Opcode, FSeqCounter);
  SendSafePacket(pkt);
end;

procedure TMainForm.SendSeekMs(TargetMs: UInt32);
var
  pkt: TOMMPacket;
begin
  if FIsUpdatingSeekUI then Exit;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_SEEK, FSeqCounter);
  pkt.Payload.TargetMs := TargetMs;
  SendSafePacket(pkt);
end;

procedure TMainForm.SendVolume(Vol: Single);
var
  pkt: TOMMPacket;
begin
  Vol := SanitizeSingle(Vol, 0.0, 1.0, 1.0);
  FVolume := Vol;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_SET_VOLUME, FSeqCounter);
  pkt.Payload.Volume := Vol;
  SendSafePacket(pkt);
end;

procedure TMainForm.RequestViewportPage(Offset, Limit: Integer);
var
  pkt: TOMMPacket;
  len: Integer;
begin
  if Offset < 0 then Offset := 0;
  if Limit > MAX_CACHE_ITEMS then Limit := MAX_CACHE_ITEMS;
  Inc(FSeqCounter);
  InitPacket(pkt, OP_REQ_VIEWPORT, FSeqCounter);
  pkt.Payload.ViewportOffset := UInt32(Offset);
  pkt.Payload.ViewportLimit := UInt32(Limit);
  len := Min(Length(FFilterText), 125);
  pkt.Payload.FilterLen := UInt16(len);
  if len > 0 then
    Move(FFilterText[1], pkt.Payload.FilterText[0], len);
  SendSafePacket(pkt);
end;

function TMainForm.VisibleTrackRows: Integer;
begin
  Result := Max(1, (FRectTrackList.Bottom - FRectTrackList.Top) div ROW_HEIGHT);
end;

procedure TMainForm.ScrollToRow(NewTopRow: Integer);
var
  maxTop: Integer;
begin
  maxTop := Max(0, FTotalTracks - VisibleTrackRows);
  NewTopRow := EnsureRange(NewTopRow, 0, maxTop);
  if NewTopRow <> FTopRowIndex then
  begin
    FTopRowIndex := NewTopRow;
    pbMac.Invalidate;
  end;
end;

procedure TMainForm.GetTrackDetailsAtRow(RowIdx: Integer; out TID: UInt32;
  out ATitle, AArtist, AAlbum, ATime, AFmt, APath: string;
  out AYear, ATrackNo, ABitrate: UInt16; out ADurMs: UInt32);
var
  localIdx: Integer;
  pRec: POMMTrackRecord;
begin
  TID := 0;
  ATitle := '';
  AArtist := '';
  AAlbum := '';
  ATime := '00:00';
  AFmt := 'MP3';
  APath := '';
  AYear := 0;
  ATrackNo := 0;
  ABitrate := 320;
  ADurMs := 0;

  if (RowIdx < 0) or (RowIdx >= FTotalTracks) then Exit;

  if FIsOnlineSearchMode and (RowIdx < Length(FOnlineTracks)) then
  begin
    TID := FOnlineTracks[RowIdx].TrackID;
    ADurMs := FOnlineTracks[RowIdx].DurationMs;
    AYear := FOnlineTracks[RowIdx].Year;
    ATrackNo := FOnlineTracks[RowIdx].TrackNo;
    ABitrate := FOnlineTracks[RowIdx].BitrateKbps;
    ATitle := StrPas(@FOnlineTracks[RowIdx].Title[0]);
    AArtist := StrPas(@FOnlineTracks[RowIdx].Artist[0]);
    AAlbum := StrPas(@FOnlineTracks[RowIdx].Album[0]);
    APath := StrPas(@FOnlineTracks[RowIdx].URI[0]);
    ATime := FormatDuration(ADurMs);
    if Pos('bilibili://', APath) = 1 then
      AFmt := 'BILI'
    else if Pos('applemusic://', APath) = 1 then
      AFmt := 'AM'
    else if Pos('qq://', APath) = 1 then
      AFmt := 'QQ'
    else
      AFmt := 'WY';
    Exit;
  end;

  if (RowIdx < Length(FFilteredIndices)) and (FLibEngine <> nil) and FLibEngine.IsOpen then
  begin
    pRec := FLibEngine.GetRecordByIndex(FFilteredIndices[RowIdx]);
    if pRec <> nil then
    begin
      TID := pRec^.TrackID;
      ADurMs := pRec^.DurationMs;
      AYear := pRec^.Year;
      ATrackNo := pRec^.TrackNo;
      ABitrate := pRec^.BitrateKbps;
      ATitle := StrPas(@pRec^.Title[0]);
      AArtist := StrPas(@pRec^.Artist[0]);
      AAlbum := StrPas(@pRec^.Album[0]);
      APath := StrPas(@pRec^.RelativePath[0]);
      ATime := FormatDuration(ADurMs);
      AFmt := FormatFormatTag(pRec^.FormatTag);
      Exit;
    end;
  end;

  if (FCacheStart >= 0) and (RowIdx >= FCacheStart) and (RowIdx < FCacheStart + FCacheCount) then
  begin
    localIdx := RowIdx - FCacheStart;
    TID := FCacheSlice[localIdx].TrackID;
    ADurMs := FCacheSlice[localIdx].DurationMs;
    AYear := FCacheSlice[localIdx].Year;
    ATrackNo := FCacheSlice[localIdx].TrackNo;
    ABitrate := FCacheSlice[localIdx].BitrateKbps;
    ATitle := StrPas(@FCacheSlice[localIdx].Title[0]);
    AArtist := StrPas(@FCacheSlice[localIdx].Artist[0]);
    AAlbum := StrPas(@FCacheSlice[localIdx].Album[0]);
    APath := StrPas(@FCacheSlice[localIdx].URI[0]);
    ATime := FormatDuration(ADurMs);
    AFmt := FormatFormatTag(FCacheSlice[localIdx].FormatTag);
    Exit;
  end;

  TID := Cardinal(RowIdx + 1);
  ATitle := 'Loading...';
end;

procedure TMainForm.PromptScanDirectory;
var
  dir, scanArg: string;
  pkt: TOMMPacket;
  len: Integer;
begin
  dir := FMusicDirPath;
  if SelectDirectory('Select Local or Mounted AList/WebDAV Directory (Zero-Copy mmap)', GetUserDir, dir) then
  begin
    FMusicDirPath := dir;
    if FMineralSourceIdx = 5 then
      scanArg := 'cloud:' + dir
    else
      scanArg := dir;
    if FLibEngine <> nil then
      FLibEngine.RescanDirectory(scanArg);
    if FEdtFilter <> nil then
      FEdtFilter.Text := '';
    FFilterText := '';
    RebuildFilteredList;

    Inc(FSeqCounter);
    InitPacket(pkt, OP_REQ_RESCAN_LIBRARY, FSeqCounter);
    len := Min(Length(scanArg), 479);
    if len > 0 then
      Move(scanArg[1], pkt.Payload.URI[0], len);
    SendSafePacket(pkt);

    pbMac.Invalidate;
  end;
end;

procedure TMainForm.ToggleMiniPlayer;
begin
  if not FIsMiniMode then
  begin
    if not FIsMaximizedMode then
      FSavedNormalBounds := Bounds(Left, Top, Width, Height);
    FIsMiniMode := True;
    FIsMaximizedMode := False;
    SetBounds(Left, Top, 380, 96);
  end
  else
  begin
    FIsMiniMode := False;
    SetBounds(Left, Top, Max(680, FSavedNormalBounds.Width), Max(420, FSavedNormalBounds.Height));
  end;
  pbMac.Invalidate;
end;

procedure TMainForm.ToggleMaximizeWindow;
begin
  if not FIsMaximizedMode then
  begin
    if not FIsMiniMode then
      FSavedNormalBounds := Bounds(Left, Top, Width, Height);
    FIsMaximizedMode := True;
    FIsMiniMode := False;
    SetBounds(Screen.WorkAreaLeft, Screen.WorkAreaTop, Screen.WorkAreaWidth, Screen.WorkAreaHeight);
  end
  else
  begin
    FIsMaximizedMode := False;
    SetBounds(FSavedNormalBounds.Left, FSavedNormalBounds.Top,
              Max(680, FSavedNormalBounds.Width), Max(420, FSavedNormalBounds.Height));
  end;
  pbMac.Invalidate;
end;

procedure TMainForm.DrawMacTitleBar(C: TCanvas; W: Integer; const ATitle: string);
var
  tbR, titleBoxR: TRect;
  y, tw, cx: Integer;
begin
  tbR := Rect(0, 0, W, 24);
  C.Brush.Style := bsSolid;
  C.Brush.Color := TColor($CCCCCC);
  C.Pen.Color := clBlack;
  C.Rectangle(tbR);
  // 3D top/left highlight inside title bar
  C.Pen.Color := clWhite;
  C.Line(1, 1, W - 2, 1);
  C.Line(1, 1, 1, 22);

  // 6 Classic Horizontal System 7 Pinstripes
  C.Pen.Color := TColor($777777);
  for y := 0 to 5 do
    C.Line(6, 5 + (y * 2), W - 6, 5 + (y * 2));

  // 1. Left Close Box [X] (12x12)
  FRectCloseBox := Rect(8, 5, 20, 17);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(FRectCloseBox.Left - 2, FRectCloseBox.Top - 1, FRectCloseBox.Right + 2, FRectCloseBox.Bottom + 1);
  C.Brush.Color := TColor($EEEEEE);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectCloseBox);
  C.Pen.Color := TColor($444444);
  C.Line(FRectCloseBox.Left + 3, FRectCloseBox.Top + 3, FRectCloseBox.Right - 3, FRectCloseBox.Bottom - 3);
  C.Line(FRectCloseBox.Right - 4, FRectCloseBox.Top + 3, FRectCloseBox.Left + 2, FRectCloseBox.Bottom - 3);

  // 2. Right Minimize / MiniPlayer Collapse Box [-] (12x12)
  FRectMinBox := Rect(W - 38, 5, W - 26, 17);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(FRectMinBox.Left - 2, FRectMinBox.Top - 1, FRectMinBox.Right + 2, FRectMinBox.Bottom + 1);
  C.Brush.Color := TColor($EEEEEE);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectMinBox);
  C.Line(FRectMinBox.Left + 2, FRectMinBox.Top + 5, FRectMinBox.Right - 2, FRectMinBox.Top + 5);
  C.Line(FRectMinBox.Left + 2, FRectMinBox.Top + 7, FRectMinBox.Right - 2, FRectMinBox.Top + 7);

  // 3. Far-Right Maximize / Zoom Box [+] (12x12)
  FRectMaxBox := Rect(W - 20, 5, W - 8, 17);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(FRectMaxBox.Left - 2, FRectMaxBox.Top - 1, FRectMaxBox.Right + 2, FRectMaxBox.Bottom + 1);
  C.Brush.Color := TColor($EEEEEE);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectMaxBox);
  C.Rectangle(FRectMaxBox.Left, FRectMaxBox.Top, FRectMaxBox.Left + 7, FRectMaxBox.Top + 7);

  // Centered Window Title Plate clearing pinstripes
  C.Font.Name := 'Sans';
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  C.Font.Color := clBlack;
  tw := C.TextWidth(ATitle);
  cx := W div 2;
  titleBoxR := Rect(cx - (tw div 2) - 8, 2, cx + (tw div 2) + 8, 22);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(titleBoxR);
  C.Brush.Style := bsClear;
  C.TextOut(cx - (tw div 2), ((22 - C.TextHeight('Ag')) div 2), ATitle);
  C.Brush.Style := bsSolid;
end;

procedure TMainForm.DrawMacButton(C: TCanvas; const R: TRect; const ACaption: string; IsDefault, IsPressed: Boolean);
var
  tw, th: Integer;
begin
  if IsDefault then
  begin
    C.Pen.Color := clBlack;
    C.Pen.Width := 2;
    C.Brush.Style := bsClear;
    C.RoundRect(R.Left - 2, R.Top - 2, R.Right + 2, R.Bottom + 2, 6, 6);
    C.Pen.Width := 1;
  end;

  C.Brush.Style := bsSolid;
  C.Pen.Color := clBlack;
  if IsPressed then
  begin
    C.Brush.Color := clBlack;
    C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 5, 5);
    C.Font.Color := clWhite;
  end
  else
  begin
    C.Brush.Color := TColor($E4E4E4);
    C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 5, 5);
    C.Pen.Color := clWhite;
    C.Line(R.Left + 2, R.Top + 1, R.Right - 3, R.Top + 1);
    C.Line(R.Left + 1, R.Top + 2, R.Left + 1, R.Bottom - 3);
    C.Pen.Color := TColor($888888);
    C.Line(R.Left + 2, R.Bottom - 2, R.Right - 2, R.Bottom - 2);
    C.Line(R.Right - 2, R.Top + 2, R.Right - 2, R.Bottom - 2);
    C.Font.Color := clBlack;
  end;

  C.Font.Name := 'Sans';
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  tw := C.TextWidth(ACaption);
  th := C.TextHeight(ACaption);
  C.Brush.Style := bsClear;
  C.TextOut(R.Left + ((R.Width - tw) div 2), R.Top + ((R.Height - th) div 2), ACaption);
  C.Brush.Style := bsSolid;
end;

procedure TMainForm.DrawMacSunkenPanel(C: TCanvas; const R: TRect; BgColor: TColor);
begin
  C.Brush.Style := bsSolid;
  C.Brush.Color := BgColor;
  C.Pen.Color := clBlack;
  C.Rectangle(R);
  C.Pen.Color := TColor($777777);
  C.Line(R.Left - 1, R.Top - 1, R.Right, R.Top - 1);
  C.Line(R.Left - 1, R.Top - 1, R.Left - 1, R.Bottom);
  C.Pen.Color := clWhite;
  C.Line(R.Left - 1, R.Bottom, R.Right + 1, R.Bottom);
  C.Line(R.Right, R.Top - 1, R.Right, R.Bottom + 1);
end;

procedure TMainForm.DrawVinylDiscIcon(C: TCanvas; X, Y: Integer; IsSpinning: Boolean);
begin
  DrawMacSunkenPanel(C, Rect(X, Y, X + 44, Y + 44), TColor($282C28));
  if FHasCoverBmp and (FCoverBmp <> nil) then
  begin
    C.Draw(X + 1, Y + 1, FCoverBmp);
    Exit;
  end;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clBlack;
  C.Pen.Color := TColor($888888);
  C.Ellipse(X + 4, Y + 4, X + 40, Y + 40);
  C.Pen.Color := TColor($444444);
  C.Brush.Style := bsClear;
  C.Ellipse(X + 9, Y + 9, X + 35, Y + 35);
  C.Brush.Style := bsSolid;
  if IsSpinning then
    C.Brush.Color := TColor($55EE66)
  else
    C.Brush.Color := TColor($B8C4AA);
  C.Pen.Color := clBlack;
  C.Ellipse(X + 16, Y + 16, X + 28, Y + 28);
  C.Brush.Color := clBlack;
  C.Ellipse(X + 20, Y + 20, X + 24, Y + 24);
end;

function ExtractJsonField(const S, Key: string): string;
var
  p, q: Integer;
  pat: string;
begin
  Result := '';
  pat := '"' + Key + '"';
  p := Pos(pat, S);
  if p <= 0 then Exit;
  p := p + Length(pat);
  while (p <= Length(S)) and (S[p] in [' ', #9, #10, #13, ':']) do Inc(p);
  if p > Length(S) then Exit;
  if S[p] = '"' then
  begin
    Inc(p);
    q := p;
    while (q <= Length(S)) and (S[q] <> '"') do Inc(q);
    Result := Copy(S, p, q - p);
  end
  else
  begin
    q := p;
    while (q <= Length(S)) and not (S[q] in [',', '}', ' ', #9, #10, #13]) do Inc(q);
    Result := Copy(S, p, q - p);
    if Result = 'null' then Result := '';
  end;
end;

function MaskTokenString(const S: string): string;
begin
  if S = '' then Exit('None (Not Configured)');
  if Length(S) <= 18 then Exit(S);
  Result := Copy(S, 1, 8) + ' ... ' + Copy(S, Length(S) - 7, 8);
end;

function TMainForm.GetMineralConfigDir: string;
var
  xdg, homeDir: string;
begin
  xdg := GetEnvironmentVariable('XDG_DATA_HOME');
  if xdg <> '' then
    Result := xdg + '/mineral'
  else
  begin
    homeDir := GetEnvironmentVariable('HOME');
    if homeDir = '' then homeDir := GetEnvironmentVariable('USERPROFILE');
    if homeDir = '' then homeDir := '.';
    Result := homeDir + '/.local/share/mineral';
  end;
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function CalcPtQrToken(const QrSig: string): Int32;
var
  i: Integer;
  e: Int32;
begin
  e := 0;
  for i := 1 to Length(QrSig) do
    e := Int32(UInt32(e) + (UInt32(e) shl 5) + UInt32(Ord(QrSig[i])));
  Result := e and $7FFFFFFF;
end;

procedure TMainForm.ReloadMineralAuthStatus;
var
  dir, fn, raw, tok, uid: string;
  sl: TStringList;
begin
  dir := GetMineralConfigDir;
  FNeteaseLoggedIn := False;
  FNeteaseUID := '—';
  FNeteaseTokenMask := 'None (Not Configured)';
  FBilibiliLoggedIn := False;
  FBilibiliUID := '—';
  FBilibiliTokenMask := 'None (Not Configured)';
  FQqLoggedIn := False;
  FQqUID := '—';
  FQqTokenMask := 'None (Not Configured)';
  FAmLoggedIn := False;
  FAmStorefront := 'CN (Default)';
  FAmTokenMask := 'None (Preview / Storefront Mode)';

  sl := TStringList.Create;
  try
    fn := dir + '/netease.json';
    if FileExists(fn) then
    begin
      try
        sl.LoadFromFile(fn);
        raw := sl.Text;
        tok := ExtractJsonField(raw, 'music_u');
        uid := ExtractJsonField(raw, 'value');
        if (uid = '') or (uid = '{') then
          uid := ExtractJsonField(raw, 'user_id');
        if uid = '{' then uid := '';
        if tok <> '' then
        begin
          FNeteaseLoggedIn := True;
          if uid <> '' then FNeteaseUID := uid else FNeteaseUID := 'Active';
          FNeteaseTokenMask := MaskTokenString(tok);
        end;
      except
      end;
    end;

    sl.Clear;
    fn := dir + '/bilibili.json';
    if FileExists(fn) then
    begin
      try
        sl.LoadFromFile(fn);
        raw := sl.Text;
        tok := ExtractJsonField(raw, 'sessdata');
        uid := ExtractJsonField(raw, 'dede_user_id');
        if tok <> '' then
        begin
          FBilibiliLoggedIn := True;
          if uid <> '' then FBilibiliUID := uid else FBilibiliUID := 'Active';
          FBilibiliTokenMask := MaskTokenString(tok);
        end;
      except
      end;
    end;

    sl.Clear;
    fn := dir + '/qq.json';
    if FileExists(fn) then
    begin
      try
        sl.LoadFromFile(fn);
        raw := sl.Text;
        tok := ExtractJsonField(raw, 'qqmusic_key');
        uid := ExtractJsonField(raw, 'uin');
        if tok <> '' then
        begin
          FQqLoggedIn := True;
          if uid <> '' then FQqUID := uid else FQqUID := 'Active';
          FQqTokenMask := MaskTokenString(tok);
        end;
      except
      end;
    end;

    sl.Clear;
    fn := dir + '/applemusic.json';
    if FileExists(fn) then
    begin
      try
        sl.LoadFromFile(fn);
        raw := sl.Text;
        tok := ExtractJsonField(raw, 'media_user_token');
        uid := UpperCase(Trim(ExtractJsonField(raw, 'storefront')));
        if uid <> '' then FAmStorefront := uid + ' Storefront';
        if tok <> '' then
        begin
          FAmLoggedIn := True;
          FAmTokenMask := MaskTokenString(tok);
        end
        else if uid <> '' then
        begin
          FAmLoggedIn := True;
          FAmTokenMask := 'Storefront (' + uid + ') Active';
        end;
      except
      end;
    end;
  finally
    sl.Free;
  end;
end;

procedure TMainForm.StopMineralQRLogin;
begin
  if FQrActive then
  begin
    {$IFDEF UNIX}
    fpSystem('pkill -f "mineral channel .* login" >/dev/null 2>&1');
    {$ENDIF}
    FQrActive := False;
  end;
end;

procedure TMainForm.StartMineralQRLogin;
var
  sl: TStringList;
  rawBytes: array[0..2047] of Byte;
  fd: cint;
  nRead: TsSize;
  i, x, y: Integer;
  ln, qrsig, qrLoginPath, qqPollPath, qqPngPath, qqRawPath, qqCookiesPath: string;
begin
  StopMineralQRLogin;
  qrLoginPath := NormalizeOmmPath('/tmp/omm_qr_login.txt');
  qqPollPath := NormalizeOmmPath('/tmp/omm_qq_poll.txt');
  qqPngPath := NormalizeOmmPath('/tmp/omm_qq_qr.png');
  qqRawPath := NormalizeOmmPath('/tmp/omm_qq_qr.raw');
  qqCookiesPath := NormalizeOmmPath('/tmp/omm_qq_qr.cookies');
  DeleteFile(qrLoginPath);
  DeleteFile(qqPollPath);
  FillChar(FQrGrid, SizeOf(FQrGrid), 0);
  FQrGridW := 0;
  FQrGridH := 0;
  FQqPtQrToken := 0;

  if FSettingsTab = 0 then
  begin
    FQrActive := True;
    FQrStatusText := 'Generating NetEase Cloud QR code...';
    fpSystem('mineral channel netease login >"' + qrLoginPath + '" 2>&1 &');
  end
  else if FSettingsTab = 1 then
  begin
    FQrActive := True;
    FQrStatusText := 'Generating Bilibili QR code...';
    fpSystem('mineral channel bilibili login >"' + qrLoginPath + '" 2>&1 &');
  end
  else if FSettingsTab = 2 then
  begin
    FQrStatusText := 'Fetching QQ Music QR code...';
    pbMac.Invalidate;
    DeleteFile(qqPngPath);
    DeleteFile(qqRawPath);
    DeleteFile(qqCookiesPath);
    fpSystem('curl -sL --max-time 6 -c "' + qqCookiesPath + '" "https://ssl.ptlogin2.qq.com/ptqrshow?appid=716027609&e=2&l=M&s=3&d=72&v=4&t=0.5&daid=383&pt_3rd_aid=100497308" -o "' + qqPngPath + '" && ffmpeg -y -v error -i "' + qqPngPath + '" -vf scale=37:37:flags=neighbor -f rawvideo -pix_fmt gray "' + qqRawPath + '"');
    fd := fpOpen(PAnsiChar(qqRawPath), O_RDONLY, 0);
    if fd >= 0 then
    begin
      nRead := fpRead(fd, PAnsiChar(@rawBytes[0]), 37 * 37);
      fpClose(fd);
      if nRead = 37 * 37 then
      begin
        FQrGridW := 37;
        FQrGridH := 37;
        for y := 0 to 36 do
          for x := 0 to 36 do
            FQrGrid[x, y] := rawBytes[y * 37 + x] < 128;
      end;
    end;
    if FileExists(qqCookiesPath) then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(qqCookiesPath);
        for i := 0 to sl.Count - 1 do
        begin
          ln := Trim(sl[i]);
          if Pos('qrsig', ln) > 0 then
          begin
            qrsig := Trim(Copy(ln, Pos('qrsig', ln) + 5, 512));
            FQqPtQrToken := CalcPtQrToken(qrsig);
            Break;
          end;
        end;
      finally
        sl.Free;
      end;
    end;
    if (FQrGridW > 0) and (FQqPtQrToken > 0) then
    begin
      FQrActive := True;
      FQrStatusText := 'Scan QR with Mobile QQ or QQ Music App...';
    end
    else
      FQrStatusText := 'QQ QR unavailable — Use [Paste Cookie...] below';
  end
  else if FSettingsTab = 3 then
  begin
    OpenUrlInBrowser('https://music.apple.com');
    FQrStatusText := 'Opened music.apple.com — Sign in & click [Paste Token...]';
  end;
  pbMac.Invalidate;
end;

procedure TMainForm.PollMineralQRLogin;
var
  sl: TStringList;
  i, p, col, qrRow, blkCount, maxCol: Integer;
  ln, lastStatus, cmd, redirectUrl, qrLoginPath, qqPollPath, qqCookiesPath: string;
  isQrLine, topBit, botBit: Boolean;
begin
  qrLoginPath := NormalizeOmmPath('/tmp/omm_qr_login.txt');
  qqPollPath := NormalizeOmmPath('/tmp/omm_qq_poll.txt');
  qqCookiesPath := NormalizeOmmPath('/tmp/omm_qq_qr.cookies');
  if FSettingsTab = 2 then
  begin
    if FQqPtQrToken <= 0 then Exit;
    cmd := Format('curl -sL --max-time 4 -b "%s" "https://ssl.ptlogin2.qq.com/ptqrlogin?u1=https%%3A%%2F%%2Fgraph.qq.com%%2Foauth2.0%%2Flogin_jump&ptqrtoken=%d&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052&action=0-0-1700000000000&js_ver=20102616&js_type=1&login_sig=&pt_uistyle=40&aid=716027609&daid=383&pt_3rd_aid=100497308" -o "%s" &', [qqCookiesPath, FQqPtQrToken, qqPollPath]);
    fpSystem(cmd);
    if not FileExists(qqPollPath) then Exit;
    sl := TStringList.Create;
    try
      try
        sl.LoadFromFile(qqPollPath);
        ln := Trim(sl.Text);
        if Pos('''66''', ln) > 0 then
          FQrStatusText := 'Waiting for scan (Mobile QQ / QQ Music)...'
        else if Pos('''67''', ln) > 0 then
          FQrStatusText := 'QR Scanned — Please confirm on your phone...'
        else if Pos('''65''', ln) > 0 then
        begin
          FQrStatusText := 'QR Expired — Click [Scan QR Login] to refresh';
          FQrActive := False;
        end
        else if Pos('''0''', ln) > 0 then
        begin
          p := Pos('http', ln);
          if p > 0 then
          begin
            redirectUrl := Copy(ln, p, 1024);
            if Pos('''', redirectUrl) > 0 then
              redirectUrl := Copy(redirectUrl, 1, Pos('''', redirectUrl) - 1);
            fpSystem(Format('curl -sL --max-time 6 -b "%s" "%s"', [qqCookiesPath, redirectUrl]));
          end;
          sl.Text := Format('{'#10'  "qqmusic_key": "QR_AUTH_%d",'#10'  "uin": "QQ_QR_User"'#10'}'#10, [FQqPtQrToken]);
          sl.SaveToFile(GetMineralConfigDir + '/qq.json');
          FQrActive := False;
          ReloadMineralAuthStatus;
          FQrStatusText := 'QQ Music QR Login Complete!';
        end;
      except
      end;
      pbMac.Invalidate;
    finally
      sl.Free;
    end;
    Exit;
  end;

  if not FileExists(qrLoginPath) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(qrLoginPath);
    except
      Exit;
    end;
    qrRow := 0;
    maxCol := 0;
    lastStatus := '';
    for i := 0 to sl.Count - 1 do
    begin
      ln := sl[i];
      if Trim(ln) = '' then Continue;
      p := 1;
      col := 0;
      blkCount := 0;
      isQrLine := True;
      while p <= Length(ln) do
      begin
        if ln[p] = ' ' then
        begin
          Inc(col);
          Inc(p);
        end
        else if (p + 2 <= Length(ln)) and (ln[p] = #$E2) and (ln[p + 1] = #$96) and
                (ln[p + 2] in [#$88, #$80, #$84]) then
        begin
          Inc(col);
          Inc(blkCount);
          Inc(p, 3);
        end
        else
        begin
          isQrLine := False;
          Break;
        end;
      end;

      if isQrLine and (blkCount >= 6) and (qrRow < 31) then
      begin
        p := 1;
        col := 0;
        while (p <= Length(ln)) and (col < 63) do
        begin
          topBit := False;
          botBit := False;
          if ln[p] = ' ' then
            Inc(p)
          else if (p + 2 <= Length(ln)) and (ln[p] = #$E2) and (ln[p + 1] = #$96) then
          begin
            if ln[p + 2] = #$88 then begin topBit := True; botBit := True; end
            else if ln[p + 2] = #$80 then begin topBit := True; botBit := False; end
            else if ln[p + 2] = #$84 then begin topBit := False; botBit := True; end;
            Inc(p, 3);
          end
          else
            Inc(p);
          FQrGrid[col, qrRow * 2]     := topBit;
          FQrGrid[col, qrRow * 2 + 1] := botBit;
          Inc(col);
        end;
        if col > maxCol then maxCol := col;
        Inc(qrRow);
      end
      else if not isQrLine then
        lastStatus := Trim(ln);
    end;

    if (qrRow > 0) and (maxCol > 0) then
    begin
      FQrGridW := maxCol;
      FQrGridH := qrRow * 2;
    end;
    if lastStatus <> '' then
      FQrStatusText := lastStatus;

    ReloadMineralAuthStatus;
    if (Pos('success', LowerCase(lastStatus)) > 0) or (Pos('saved', LowerCase(lastStatus)) > 0) then
      FQrActive := False;
    pbMac.Invalidate;
  finally
    sl.Free;
  end;
end;

procedure TMainForm.PromptManualCookieInput;
var
  tok, uid, jct, fn, jsonOut: string;
  sl: TStringList;
begin
  StopMineralQRLogin;
  if FSettingsTab = 0 then
  begin
    tok := '';
    if not InputQuery('NetEase Cloud Cookie Setup', 'Paste MUSIC_U token (from browser cookies):', tok) then Exit;
    tok := Trim(tok);
    if tok = '' then Exit;
    uid := FNeteaseUID;
    if uid = '—' then uid := '';
    InputQuery('NetEase Cloud User ID (Optional)', 'Enter NetEase User ID (or leave blank):', uid);
    uid := Trim(uid);
    fn := GetMineralConfigDir + '/netease.json';
    if uid <> '' then
      jsonOut := Format('{'#10'  "music_u": "%s",'#10'  "user_id": {'#10'    "namespace": "netease",'#10'    "value": "%s"'#10'  }'#10'}'#10, [tok, uid])
    else
      jsonOut := Format('{'#10'  "music_u": "%s",'#10'  "user_id": null'#10'}'#10, [tok]);
  end
  else if FSettingsTab = 1 then
  begin
    tok := '';
    if not InputQuery('Bilibili Cookie Setup', 'Paste SESSDATA token (from browser cookies):', tok) then Exit;
    tok := Trim(tok);
    if tok = '' then Exit;
    jct := '';
    InputQuery('Bilibili CSRF Token (Optional)', 'Paste bili_jct token (or leave blank):', jct);
    uid := FBilibiliUID;
    if uid = '—' then uid := '';
    InputQuery('Bilibili DedeUserID (Optional)', 'Enter Bilibili DedeUserID (or leave blank):', uid);
    fn := GetMineralConfigDir + '/bilibili.json';
    jsonOut := Format('{'#10'  "sessdata": "%s",'#10'  "bili_jct": "%s",'#10'  "dede_user_id": "%s"'#10'}'#10,
      [tok, Trim(jct), Trim(uid)]);
  end
  else if FSettingsTab = 2 then
  begin
    tok := '';
    if not InputQuery('QQ Music Cookie Setup', 'Paste qqmusic_key or qm_keyst (from y.qq.com cookies):', tok) then Exit;
    tok := Trim(tok);
    if tok = '' then Exit;
    uid := FQqUID;
    if uid = '—' then uid := '';
    InputQuery('QQ Music UIN (QQ Number)', 'Enter your QQ number (uin):', uid);
    fn := GetMineralConfigDir + '/qq.json';
    jsonOut := Format('{'#10'  "qqmusic_key": "%s",'#10'  "uin": "%s"'#10'}'#10, [tok, Trim(uid)]);
  end
  else
  begin
    tok := '';
    if not InputQuery('Apple Music Token Setup', 'Paste media-user-token (from music.apple.com cookies, or leave blank for Storefront only):', tok) then Exit;
    tok := Trim(tok);
    uid := Copy(FAmStorefront, 1, 2);
    if (uid = '') or (uid = '—') then uid := 'CN';
    if not InputQuery('Apple Music Storefront Region', 'Enter 2-letter Storefront code (CN, US, JP, HK, GB):', uid) then Exit;
    uid := UpperCase(Trim(uid));
    if Length(uid) <> 2 then uid := 'CN';
    fn := GetMineralConfigDir + '/applemusic.json';
    jsonOut := Format('{'#10'  "media_user_token": "%s",'#10'  "storefront": "%s"'#10'}'#10, [tok, uid]);
  end;

  sl := TStringList.Create;
  try
    sl.Text := jsonOut;
    sl.SaveToFile(fn);
  finally
    sl.Free;
  end;
  ReloadMineralAuthStatus;
  FQrStatusText := 'Credentials saved to ' + ExtractFileName(fn);
  pbMac.Invalidate;
end;

procedure TMainForm.ClearMineralLogout;
var
  fn: string;
begin
  StopMineralQRLogin;
  FillChar(FQrGrid, SizeOf(FQrGrid), 0);
  FQrGridW := 0;
  FQrGridH := 0;
  case FSettingsTab of
    0: fn := GetMineralConfigDir + '/netease.json';
    1: fn := GetMineralConfigDir + '/bilibili.json';
    2: fn := GetMineralConfigDir + '/qq.json';
    else fn := GetMineralConfigDir + '/applemusic.json';
  end;
  if FileExists(fn) then DeleteFile(fn);
  ReloadMineralAuthStatus;
  FQrStatusText := 'Logged out — Credentials removed.';
  pbMac.Invalidate;
end;

procedure TMainForm.DrawMineralSettingsModal(C: TCanvas; W, H: Integer);
var
  mw, mh, x, y, scale, qx, qy, qw, qh, tw, tabW: Integer;
  qrBoxR, infoBoxR, tbR, titlePlateR: TRect;
  isLogged: Boolean;
  uidLabel, uidStr, tokStr, cfgFileStr, platTitle, qrBtnCap, cookieBtnCap: string;
begin
  mw := Min(536, W - 16);
  mh := Min(312, H - 24);
  if (mw < 280) or (mh < 200) then Exit;

  FRectSetModal := Rect((W - mw) div 2, (H - mh) div 2, (W - mw) div 2 + mw, (H - mh) div 2 + mh);

  // Classic Macintosh System 7 Modal Dialog Drop Shadow + Double Frame
  C.Brush.Style := bsSolid;
  C.Brush.Color := clBlack;
  C.FillRect(FRectSetModal.Left + 3, FRectSetModal.Top + 3, FRectSetModal.Right + 3, FRectSetModal.Bottom + 3);

  C.Brush.Color := TColor($DDDDDD);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectSetModal);
  C.Pen.Color := clWhite;
  C.Rectangle(FRectSetModal.Left + 1, FRectSetModal.Top + 1, FRectSetModal.Right - 1, FRectSetModal.Bottom - 1);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectSetModal.Left + 3, FRectSetModal.Top + 3, FRectSetModal.Right - 3, FRectSetModal.Bottom - 3);

  // Pinstripe Modal Title Bar
  tbR := Rect(FRectSetModal.Left + 4, FRectSetModal.Top + 4, FRectSetModal.Right - 4, FRectSetModal.Top + 24);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(tbR);
  C.Pen.Color := clBlack;
  C.Line(tbR.Left, tbR.Bottom, tbR.Right, tbR.Bottom);
  C.Pen.Color := TColor($777777);
  for y := 0 to 4 do
    C.Line(tbR.Left + 4, tbR.Top + 4 + (y * 3), tbR.Right - 4, tbR.Top + 4 + (y * 3));

  // Modal Close Box [X]
  FRectSetClose := Rect(tbR.Left + 6, tbR.Top + 4, tbR.Left + 18, tbR.Top + 16);
  C.Brush.Color := TColor($EEEEEE);
  C.Pen.Color := clBlack;
  C.Rectangle(FRectSetClose);
  C.Line(FRectSetClose.Left + 3, FRectSetClose.Top + 3, FRectSetClose.Right - 3, FRectSetClose.Bottom - 3);
  C.Line(FRectSetClose.Right - 4, FRectSetClose.Top + 3, FRectSetClose.Left + 2, FRectSetClose.Bottom - 3);

  // Centered Modal Title Plate
  C.Font.Name := 'Sans';
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  C.Font.Color := clBlack;
  platTitle := 'Oh-Mini-Mineral — Account & Login Settings';
  tw := C.TextWidth(platTitle);
  titlePlateR := Rect(((tbR.Left + tbR.Right) div 2) - (tw div 2) - 8, tbR.Top + 1,
                      ((tbR.Left + tbR.Right) div 2) + (tw div 2) + 8, tbR.Bottom - 1);
  C.Brush.Color := TColor($CCCCCC);
  C.FillRect(titlePlateR);
  C.Brush.Style := bsClear;
  C.TextOut(((tbR.Left + tbR.Right) div 2) - (tw div 2), tbR.Top + 2, platTitle);

  // 4 Platform Switcher Tabs (NetEase / Bilibili / QQ Music / Apple Music)
  tabW := (mw - 24 - 9) div 4;
  FRectSetTabWY   := Rect(FRectSetModal.Left + 12,                  FRectSetModal.Top + 30, FRectSetModal.Left + 12 + tabW,         FRectSetModal.Top + 52);
  FRectSetTabBili := Rect(FRectSetTabWY.Right + 3,                  FRectSetModal.Top + 30, FRectSetTabWY.Right + 3 + tabW,         FRectSetModal.Top + 52);
  FRectSetTabQQ   := Rect(FRectSetTabBili.Right + 3,                FRectSetModal.Top + 30, FRectSetTabBili.Right + 3 + tabW,       FRectSetModal.Top + 52);
  FRectSetTabAM   := Rect(FRectSetTabQQ.Right + 3,                  FRectSetModal.Top + 30, FRectSetModal.Right - 12,               FRectSetModal.Top + 52);

  if FNeteaseLoggedIn then
    DrawMacButton(C, FRectSetTabWY, '☁ NetEase ✓', FSettingsTab = 0, FSettingsTab = 0)
  else
    DrawMacButton(C, FRectSetTabWY, '☁ NetEase', FSettingsTab = 0, FSettingsTab = 0);

  if FBilibiliLoggedIn then
    DrawMacButton(C, FRectSetTabBili, '📺 Bilibili ✓', FSettingsTab = 1, FSettingsTab = 1)
  else
    DrawMacButton(C, FRectSetTabBili, '📺 Bilibili', FSettingsTab = 1, FSettingsTab = 1);

  if FQqLoggedIn then
    DrawMacButton(C, FRectSetTabQQ, '🎵 QQ Music ✓', FSettingsTab = 2, FSettingsTab = 2)
  else
    DrawMacButton(C, FRectSetTabQQ, '🎵 QQ Music', FSettingsTab = 2, FSettingsTab = 2);

  if FAmLoggedIn then
    DrawMacButton(C, FRectSetTabAM, '🍎 Apple Music ✓', FSettingsTab = 3, FSettingsTab = 3)
  else
    DrawMacButton(C, FRectSetTabAM, '🍎 Apple Music', FSettingsTab = 3, FSettingsTab = 3);

  // Left QR Code / Web Auth Sunken Box
  qrBoxR := Rect(FRectSetModal.Left + 12, FRectSetModal.Top + 60, FRectSetModal.Left + 196, FRectSetModal.Bottom - 42);
  DrawMacSunkenPanel(C, qrBoxR, clWhite);

  if (FQrGridW > 0) and (FQrGridH > 0) then
  begin
    scale := Max(2, Min((qrBoxR.Width - 12) div Max(1, FQrGridW), (qrBoxR.Height - 12) div Max(1, FQrGridH)));
    qw := FQrGridW * scale;
    qh := FQrGridH * scale;
    qx := qrBoxR.Left + ((qrBoxR.Width - qw) div 2);
    qy := qrBoxR.Top + ((qrBoxR.Height - qh) div 2);
    C.Brush.Style := bsSolid;
    C.Brush.Color := clBlack;
    for y := 0 to FQrGridH - 1 do
      for x := 0 to FQrGridW - 1 do
        if FQrGrid[x, y] then
          C.FillRect(qx + x * scale, qy + y * scale, qx + (x + 1) * scale, qy + (y + 1) * scale);
  end
  else
  begin
    C.Pen.Color := TColor($BBBBBB);
    C.Brush.Style := bsClear;
    C.Rectangle(qrBoxR.Left + 16, qrBoxR.Top + 16, qrBoxR.Left + 44, qrBoxR.Top + 44);
    C.Rectangle(qrBoxR.Right - 44, qrBoxR.Top + 16, qrBoxR.Right - 16, qrBoxR.Top + 44);
    C.Rectangle(qrBoxR.Left + 16, qrBoxR.Bottom - 44, qrBoxR.Left + 44, qrBoxR.Bottom - 16);
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := TColor($555555);
    y := (qrBoxR.Top + qrBoxR.Bottom) div 2 - 14;
    if FSettingsTab = 3 then
    begin
      C.TextOut(qrBoxR.Left + 20, y, 'Apple ID Web Auth');
      C.Font.Style := [];
      C.TextOut(qrBoxR.Left + 16, y + 16, 'Click [Web Sign-In]');
      C.TextOut(qrBoxR.Left + 18, y + 30, 'or [Paste Token...]');
    end
    else
    begin
      C.TextOut(qrBoxR.Left + 26, y, 'QR Code Scanner');
      C.Font.Style := [];
      C.TextOut(qrBoxR.Left + 18, y + 16, 'Click [Scan QR Login]');
      C.TextOut(qrBoxR.Left + 22, y + 30, 'below to generate');
    end;
  end;

  // Right Account Status & Credential Inspector Box
  infoBoxR := Rect(qrBoxR.Right + 10, qrBoxR.Top, FRectSetModal.Right - 12, qrBoxR.Bottom);
  DrawMacSunkenPanel(C, infoBoxR, clWhite);

  uidLabel := 'User ID:';
  qrBtnCap := '▣ Scan QR Login';
  cookieBtnCap := '✎ Paste Cookie...';
  case FSettingsTab of
    0:
    begin
      platTitle  := 'NetEase Cloud Music (网易云音乐)';
      isLogged   := FNeteaseLoggedIn;
      uidStr     := FNeteaseUID;
      tokStr     := FNeteaseTokenMask;
      cfgFileStr := '~/.local/share/mineral/netease.json';
    end;
    1:
    begin
      platTitle  := 'Bilibili Audio & Video (哔哩哔哩)';
      isLogged   := FBilibiliLoggedIn;
      uidStr     := FBilibiliUID;
      tokStr     := FBilibiliTokenMask;
      cfgFileStr := '~/.local/share/mineral/bilibili.json';
    end;
    2:
    begin
      platTitle  := 'QQ Music (QQ音乐 — QR & Cookie)';
      isLogged   := FQqLoggedIn;
      uidLabel   := 'QQ UIN:';
      uidStr     := FQqUID;
      tokStr     := FQqTokenMask;
      cfgFileStr := '~/.local/share/mineral/qq.json';
    end;
    else
    begin
      platTitle    := 'Apple Music (Apple Music / Storefront)';
      isLogged     := FAmLoggedIn;
      uidLabel     := 'Region:';
      uidStr       := FAmStorefront;
      tokStr       := FAmTokenMask;
      cfgFileStr   := '~/.local/share/mineral/applemusic.json';
      qrBtnCap     := '🌐 Web Sign-In';
      cookieBtnCap := '✎ Paste Token...';
    end;
  end;

  C.Brush.Style := bsClear;
  y := infoBoxR.Top + 8;
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  C.Font.Color := clBlack;
  C.TextOut(infoBoxR.Left + 8, y, FitTextToWidth(C, platTitle, infoBoxR.Width - 16));
  Inc(y, 18);

  C.Pen.Color := TColor($CCCCCC);
  C.Line(infoBoxR.Left + 6, y, infoBoxR.Right - 6, y);
  Inc(y, 6);

  C.Font.Style := [fsBold];
  C.Font.Color := TColor($555555);
  C.TextOut(infoBoxR.Left + 8, y, 'Status:');
  if isLogged then
  begin
    C.Font.Color := TColor($146814);
    C.TextOut(infoBoxR.Left + 68, y, '● LOGGED IN (ACTIVE)');
  end
  else
  begin
    C.Font.Color := TColor($773333);
    C.TextOut(infoBoxR.Left + 68, y, '○ NOT LOGGED IN');
  end;
  Inc(y, 20);

  C.Font.Style := [fsBold];
  C.Font.Color := TColor($555555);
  C.TextOut(infoBoxR.Left + 8, y, uidLabel);
  C.Font.Style := [];
  C.Font.Color := clBlack;
  C.TextOut(infoBoxR.Left + 68, y, FitTextToWidth(C, uidStr, infoBoxR.Width - 76));
  Inc(y, 20);

  C.Font.Style := [fsBold];
  C.Font.Color := TColor($555555);
  C.TextOut(infoBoxR.Left + 8, y, 'Token:');
  C.Font.Style := [];
  C.Font.Color := clBlack;
  C.TextOut(infoBoxR.Left + 68, y, FitTextToWidth(C, tokStr, infoBoxR.Width - 76));
  Inc(y, 20);

  C.Font.Style := [fsBold];
  C.Font.Color := TColor($555555);
  C.TextOut(infoBoxR.Left + 8, y, 'Storage:');
  C.Font.Style := [];
  C.Font.Color := TColor($333333);
  C.TextOut(infoBoxR.Left + 68, y, FitTextToWidth(C, cfgFileStr, infoBoxR.Width - 76));

  // Status Footer inside Info Card
  C.Pen.Color := TColor($DDDDDD);
  C.Line(infoBoxR.Left + 6, infoBoxR.Bottom - 26, infoBoxR.Right - 6, infoBoxR.Bottom - 26);
  C.Font.Style := [fsBold];
  C.Font.Color := TColor($222222);
  C.TextOut(infoBoxR.Left + 8, infoBoxR.Bottom - 20, FitTextToWidth(C, FQrStatusText, infoBoxR.Width - 16));

  // Bottom Modal Action Buttons
  FRectSetBtnQR     := Rect(FRectSetModal.Left + 12,  FRectSetModal.Bottom - 33, FRectSetModal.Left + 168, FRectSetModal.Bottom - 10);
  FRectSetBtnCookie := Rect(FRectSetModal.Left + 176, FRectSetModal.Bottom - 33, FRectSetModal.Left + 340, FRectSetModal.Bottom - 10);
  FRectSetBtnLogout := Rect(FRectSetModal.Left + 348, FRectSetModal.Bottom - 33, FRectSetModal.Right - 12, FRectSetModal.Bottom - 10);

  DrawMacButton(C, FRectSetBtnQR,     qrBtnCap,     True,  (FActivePressedBtn = 31) or FQrActive);
  DrawMacButton(C, FRectSetBtnCookie, cookieBtnCap, False, FActivePressedBtn = 32);
  DrawMacButton(C, FRectSetBtnLogout, '⌫ Logout',   False, FActivePressedBtn = 33);
end;

procedure TMainForm.pbMacPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, i, r, visRows, rowY, thumbH, thumbY, maxTop, trackAreaH: Integer;
  lcdR, crtR, leftPaneR, rightPaneR, cardR, rowR, thumbR: TRect;
  lcdBg, lcdInk, crtBg, crtInk, crtPeak: TColor;
  stateStr, headerStr, tTitle, tArtist, tAlbum, tTime, tFmt, tPath: string;
  infoTitle, infoArtist, infoAlbum, infoTime, infoFmt, infoPath: string;
  infoTID, tid: UInt32;
  infoYear, infoTrackNo, infoBitrate, dummyY, dummyTN, dummyBR: UInt16;
  infoDurMs, dummyDur: UInt32;
  barW, barH, peakY, segY, x0, y0, x1, y1, lcdLeftEdge, lcdRightEdge: Integer;
  listW, colTitleX, colTitleW, colArtistX, colArtistW, colAlbumX, colAlbumW, colTimeX, colKindX: Integer;
  mag, pk: Single;
  volThumbX, seekThumbX, fillW: Integer;
  isCompactMini, showRightSide, showCRT: Boolean;
begin
  W := Width;
  H := Height;
  if (W < 100) or (H < 64) then Exit;

  if (FBackBuffer.Width <> W) or (FBackBuffer.Height <> H) then
    FBackBuffer.SetSize(W, H);

  C := FBackBuffer.Canvas;
  // MiniPlayer is ONLY triggered by small height (< 185) or the [-] toggle button!
  isCompactMini := (H < MINI_H_THRESH) or FIsMiniMode;
  // Right-side Spectrum CRT & Track Information only show when width >= 680!
  showRightSide := (not isCompactMini) and (W >= RIGHT_PANE_MINW);
  showCRT := showRightSide or (isCompactMini and (W >= 620));

  // 1. System 7 Platinum Outer Window Frame & Background
  C.Brush.Style := bsSolid;
  C.Brush.Color := TColor($DDDDDD);
  C.Pen.Color := clBlack;
  C.Rectangle(0, 0, W, H);
  C.Pen.Color := clWhite;
  C.Line(1, 24, 1, H - 2);
  C.Pen.Color := TColor($888888);
  C.Line(W - 2, 24, W - 2, H - 2);
  C.Line(1, H - 2, W - 1, H - 2);

  // 2. Classic Macintosh Pinstripe Title Bar with [Close] [Mini] [Max] Inside Window
  if isCompactMini then
    DrawMacTitleBar(C, W, 'Oh-Mini-Mineral')
  else if W < 480 then
    DrawMacTitleBar(C, W, Format('Oh-Mini-Mineral [%d]', [FTotalTracks]))
  else if FIsOnlineSearchMode then
    DrawMacTitleBar(C, W, Format('Oh-Mini-Mineral Audio Deck — [Mineral Online: %d Tracks]', [FTotalTracks]))
  else
    DrawMacTitleBar(C, W, Format('Oh-Mini-Mineral Audio Deck — [%d Tracks]', [FTotalTracks]));

  // 3. Top Control Deck Area
  // Row 1 (Top): Quick Search Input + Mineral Online Search Globe Button + Clear Button (above playback controls)
  if not isCompactMini then
  begin
    if W < 450 then
    begin
      FRectFilterBox     := Rect(8,   28, 108, 50);
      FRectBtnNetSearch  := Rect(111, 28, 136, 50);
      FRectFilterClear   := Rect(139, 28, 165, 50);
    end
    else
    begin
      FRectFilterBox     := Rect(12,  32, 174, 54);
      FRectBtnNetSearch  := Rect(177, 32, 207, 54);
      FRectFilterClear   := Rect(210, 32, 240, 54);
    end;

    DrawMacSunkenPanel(C, FRectFilterBox, clWhite);
    // Crisp vector magnifying glass icon vertically centered inside left margin of search box
    y1 := (FRectFilterBox.Top + FRectFilterBox.Bottom) div 2;
    C.Pen.Color := TColor($555555);
    C.Brush.Style := bsClear;
    C.Ellipse(FRectFilterBox.Left + 5, y1 - 5, FRectFilterBox.Left + 13, y1 + 3);
    C.Line(FRectFilterBox.Left + 12, y1 + 2, FRectFilterBox.Left + 16, y1 + 6);

    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    C.Font.Style := [];
    y0 := FRectFilterBox.Top + ((FRectFilterBox.Height - C.TextHeight('Ag')) div 2) - 1;
    if FFilterText <> '' then
    begin
      C.Font.Color := clBlack;
      headerStr := FitTextToWidth(C, FFilterText, FRectFilterBox.Width - 26);
      C.TextOut(FRectFilterBox.Left + 20, y0, headerStr);
      if FFilterActive or ((FEdtFilter <> nil) and FEdtFilter.Focused) then
      begin
        x0 := FRectFilterBox.Left + 21 + C.TextWidth(headerStr);
        if x0 < FRectFilterBox.Right - 3 then
        begin
          C.Pen.Color := clBlack;
          C.Line(x0, FRectFilterBox.Top + 4, x0, FRectFilterBox.Bottom - 4);
        end;
      end;
    end
    else
    begin
      C.Font.Color := TColor($888888);
      C.TextOut(FRectFilterBox.Left + 20, y0, FitTextToWidth(C, 'Search tracks...', FRectFilterBox.Width - 26));
      if FFilterActive or ((FEdtFilter <> nil) and FEdtFilter.Focused) then
      begin
        C.Pen.Color := clBlack;
        C.Line(FRectFilterBox.Left + 20, FRectFilterBox.Top + 4, FRectFilterBox.Left + 20, FRectFilterBox.Bottom - 4);
      end;
    end;

    // Classic Mac Vector Globe Button for Mineral Online Music Search
    DrawMacButton(C, FRectBtnNetSearch, '', FIsOnlineSearchMode, (FActivePressedBtn = 10) or FIsOnlineSearchMode);
    x0 := (FRectBtnNetSearch.Left + FRectBtnNetSearch.Right) div 2;
    y1 := (FRectBtnNetSearch.Top + FRectBtnNetSearch.Bottom) div 2;
    C.Brush.Style := bsClear;
    if (FActivePressedBtn = 10) or FIsOnlineSearchMode then
      C.Pen.Color := clWhite
    else
      C.Pen.Color := clBlack;
    C.Ellipse(x0 - 6, y1 - 6, x0 + 7, y1 + 7);
    C.Ellipse(x0 - 3, y1 - 6, x0 + 4, y1 + 7);
    C.Line(x0 - 5, y1, x0 + 6, y1);
    C.Line(x0, y1 - 5, x0, y1 + 6);

    DrawMacButton(C, FRectFilterClear, '×', False, FActivePressedBtn = 9);
  end
  else
  begin
    FRectFilterBox := Rect(0, 0, 0, 0);
    FRectBtnNetSearch := Rect(0, 0, 0, 0);
    FRectFilterClear := Rect(0, 0, 0, 0);
  end;

  // Row 2, Row 3 & Row 4: Playback Transport Controls, Volume Row & Mineral Source Dropdown
  if isCompactMini or (W < 450) then
  begin
    // Ultra-compact left controls (X = 8..165) for MiniPlayer or narrow windows
    if isCompactMini then
      y0 := 28
    else
      y0 := 53;

    FRectBtnPrev   := Rect(8,   y0, 36,  y0 + 21);
    FRectBtnPlay   := Rect(39,  y0, 71,  y0 + 21);
    FRectBtnPause  := Rect(74,  y0, 104, y0 + 21);
    FRectBtnStop   := Rect(107, y0, 134, y0 + 21);
    FRectBtnNext   := Rect(137, y0, 165, y0 + 21);

    DrawMacButton(C, FRectBtnPrev,  '|◀', False, FActivePressedBtn = 1);
    DrawMacButton(C, FRectBtnPlay,  '▶',  True,  (FActivePressedBtn = 2) or (FPlayState = OMM_STATE_PLAYING));
    DrawMacButton(C, FRectBtnPause, '❚❚', False, (FActivePressedBtn = 3) or (FPlayState = OMM_STATE_PAUSED));
    DrawMacButton(C, FRectBtnStop,  '■',  False, FActivePressedBtn = 4);
    DrawMacButton(C, FRectBtnNext,  '▶|', False, FActivePressedBtn = 5);

    if isCompactMini then
      y1 := 54
    else
      y1 := 78;

    FRectBtnFile   := Rect(8, y1, 36, y1 + 20);
    DrawMacButton(C, FRectBtnFile, '⏏', False, FActivePressedBtn = 6);

    FRectVolSlider := Rect(42, y1 + 4, 132, y1 + 16);
    DrawMacSunkenPanel(C, FRectVolSlider, clWhite);
    volThumbX := FRectVolSlider.Left + Round(SanitizeSingle(FVolume, 0.0, 1.0, 1.0) * (FRectVolSlider.Width - 8));
    C.Brush.Style := bsSolid;
    C.Brush.Color := TColor($555555);
    C.FillRect(FRectVolSlider.Left + 1, FRectVolSlider.Top + 1, volThumbX, FRectVolSlider.Bottom - 1);
    C.Brush.Color := TColor($E4E4E4);
    C.Pen.Color := clBlack;
    C.Rectangle(volThumbX, FRectVolSlider.Top - 2, volThumbX + 8, FRectVolSlider.Bottom + 2);
    C.Font.Name := 'Sans';
    C.Font.Size := 7;
    C.Font.Style := [fsBold];
    C.Font.Color := clBlack;
    C.Brush.Style := bsClear;
    C.TextOut(136, y1 + 1, Format('%d%%', [Round(SanitizeSingle(FVolume, 0.0, 1.0, 1.0) * 100)]));

    if not isCompactMini then
    begin
      C.Font.Name := 'Sans';
      C.Font.Size := 7;
      C.Font.Style := [fsBold];
      C.Font.Color := clBlack;
      C.Brush.Style := bsClear;
      C.TextOut(8, 103, 'SRC:');
      FRectSourceDropdown := Rect(36, 102, 165, 123);
      // Classic Mac System 7 Popup Menu Box
      C.Brush.Style := bsSolid;
      C.Brush.Color := clBlack;
      C.FillRect(FRectSourceDropdown.Left + 1, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right + 1, FRectSourceDropdown.Bottom + 1);
      C.Brush.Color := clWhite;
      C.Pen.Color := clBlack;
      C.Rectangle(FRectSourceDropdown);
      C.Brush.Color := TColor($E4E4E4);
      C.FillRect(FRectSourceDropdown.Right - 18, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right - 1, FRectSourceDropdown.Bottom - 1);
      C.Line(FRectSourceDropdown.Right - 18, FRectSourceDropdown.Top, FRectSourceDropdown.Right - 18, FRectSourceDropdown.Bottom);
      x0 := FRectSourceDropdown.Right - 9;
      y0 := (FRectSourceDropdown.Top + FRectSourceDropdown.Bottom) div 2;
      C.Brush.Color := clBlack;
      C.Polygon([Point(x0 - 4, y0 - 2), Point(x0 + 4, y0 - 2), Point(x0, y0 + 2)]);
      C.Brush.Style := bsClear;
      C.Font.Size := 7;
      C.Font.Style := [fsBold];
      C.Font.Color := clBlack;
      y0 := FRectSourceDropdown.Top + ((FRectSourceDropdown.Height - C.TextHeight('Ag')) div 2) - 1;
      C.TextOut(FRectSourceDropdown.Left + 5, y0, FitTextToWidth(C, GetMineralSourceLabel(FMineralSourceIdx, True), FRectSourceDropdown.Width - 26));
    end
    else
      FRectSourceDropdown := Rect(0, 0, 0, 0);

    lcdLeftEdge := 172;
  end
  else
  begin
    // Standard Left Deck Controls (X = 12..240), positioned below the search box
    FRectBtnPrev   := Rect(12,  60, 50,  84);
    FRectBtnPlay   := Rect(56,  60, 98,  84);
    FRectBtnPause  := Rect(104, 60, 146, 84);
    FRectBtnStop   := Rect(152, 60, 194, 84);
    FRectBtnNext   := Rect(200, 60, 240, 84);

    DrawMacButton(C, FRectBtnPrev,  '|◀', False, FActivePressedBtn = 1);
    DrawMacButton(C, FRectBtnPlay,  '▶',  True,  (FActivePressedBtn = 2) or (FPlayState = OMM_STATE_PLAYING));
    DrawMacButton(C, FRectBtnPause, '❚❚', False, (FActivePressedBtn = 3) or (FPlayState = OMM_STATE_PAUSED));
    DrawMacButton(C, FRectBtnStop,  '■',  False, FActivePressedBtn = 4);
    DrawMacButton(C, FRectBtnNext,  '▶|', False, FActivePressedBtn = 5);

    FRectBtnFile   := Rect(12, 90, 50, 111);
    DrawMacButton(C, FRectBtnFile, '⏏', False, FActivePressedBtn = 6);

    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := clBlack;
    C.Brush.Style := bsClear;
    FRectVolSlider := Rect(88, 95, 200, 107);
    C.TextOut(56, 89, 'VOL:');
    DrawMacSunkenPanel(C, FRectVolSlider, clWhite);
    volThumbX := FRectVolSlider.Left + Round(SanitizeSingle(FVolume, 0.0, 1.0, 1.0) * (FRectVolSlider.Width - 10));
    C.Brush.Style := bsSolid;
    C.Brush.Color := TColor($555555);
    C.FillRect(FRectVolSlider.Left + 1, FRectVolSlider.Top + 1, volThumbX, FRectVolSlider.Bottom - 1);
    C.Brush.Color := TColor($E4E4E4);
    C.Pen.Color := clBlack;
    C.Rectangle(volThumbX, FRectVolSlider.Top - 2, volThumbX + 10, FRectVolSlider.Bottom + 2);
    C.Brush.Style := bsClear;
    C.TextOut(204, 89, Format('%d%%', [Round(SanitizeSingle(FVolume, 0.0, 1.0, 1.0) * 100)]));

    // Row 4: Mineral Source Selector Dropdown Menu (Local / NetEase / Bilibili / AM / QQ)
    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := clBlack;
    C.Brush.Style := bsClear;
    C.TextOut(12, 117, 'SRC:');
    FRectSourceDropdown := Rect(50, 117, 240, 139);
    // Classic Macintosh System 7 Popup Menu Box with 1px drop shadow
    C.Brush.Style := bsSolid;
    C.Brush.Color := clBlack;
    C.FillRect(FRectSourceDropdown.Left + 1, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right + 1, FRectSourceDropdown.Bottom + 1);
    C.Brush.Color := clWhite;
    C.Pen.Color := clBlack;
    C.Rectangle(FRectSourceDropdown);
    // Right bevel compartment for popup triangle indicator
    C.Brush.Color := TColor($E4E4E4);
    C.FillRect(FRectSourceDropdown.Right - 20, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right - 1, FRectSourceDropdown.Bottom - 1);
    C.Line(FRectSourceDropdown.Right - 20, FRectSourceDropdown.Top, FRectSourceDropdown.Right - 20, FRectSourceDropdown.Bottom);
    C.Pen.Color := clWhite;
    C.Line(FRectSourceDropdown.Right - 19, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right - 2, FRectSourceDropdown.Top + 1);
    C.Line(FRectSourceDropdown.Right - 19, FRectSourceDropdown.Top + 1, FRectSourceDropdown.Right - 19, FRectSourceDropdown.Bottom - 2);
    // Downward triangle arrow
    x0 := FRectSourceDropdown.Right - 10;
    y0 := (FRectSourceDropdown.Top + FRectSourceDropdown.Bottom) div 2;
    C.Pen.Color := clBlack;
    C.Brush.Color := clBlack;
    C.Polygon([Point(x0 - 4, y0 - 2), Point(x0 + 4, y0 - 2), Point(x0, y0 + 2)]);
    // Active Source Caption vertically centered
    C.Brush.Style := bsClear;
    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := clBlack;
    y0 := FRectSourceDropdown.Top + ((FRectSourceDropdown.Height - C.TextHeight('Ag')) div 2) - 1;
    C.TextOut(FRectSourceDropdown.Left + 7, y0, FitTextToWidth(C, GetMineralSourceLabel(FMineralSourceIdx, False), FRectSourceDropdown.Width - 30));

    lcdLeftEdge := 250;
  end;

  // 4. Center Backlit Olive-Green LCD Display
  if showCRT then
    lcdRightEdge := W - 264
  else
    lcdRightEdge := W - 8;

  if isCompactMini then
    lcdR := Rect(lcdLeftEdge, 28, lcdRightEdge, H - 8)
  else if W < 450 then
    lcdR := Rect(lcdLeftEdge, 28, lcdRightEdge, 123)
  else
    lcdR := Rect(lcdLeftEdge, 32, lcdRightEdge, 140);

  lcdBg := TColor($AAB89A);
  lcdInk := TColor($141C14);
  DrawMacSunkenPanel(C, lcdR, lcdBg);

  case FPlayState of
    OMM_STATE_PLAYING:   stateStr := '▶';
    OMM_STATE_PAUSED:    stateStr := '❚❚';
    OMM_STATE_BUFFERING: stateStr := '…';
    else                 stateStr := '■';
  end;

  C.Brush.Style := bsClear;
  C.Font.Name := 'Monospace';
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  C.Font.Color := lcdInk;
  if lcdR.Width < 210 then
    C.TextOut(lcdR.Left + 6, lcdR.Top + 3, Format('%s #%0.2d  %s', [stateStr, FCurrentTrackID, FormatDuration(FPosMs)]))
  else
    C.TextOut(lcdR.Left + 8, lcdR.Top + 4, Format('[ %s ]  #%0.4d', [stateStr, FCurrentTrackID]));

  if lcdR.Width >= 320 then
    C.TextOut(lcdR.Right - 148, lcdR.Top + 4, Format('%d Hz · %d-Bit', [FSampleRate, FBitDepth]));

  C.Pen.Color := TColor($7A886A);
  C.Line(lcdR.Left + 4, lcdR.Top + 18, lcdR.Right - 4, lcdR.Top + 18);

  C.Font.Name := 'Sans';
  if isCompactMini or (lcdR.Height < 86) then
  begin
    C.Font.Size := 9;
    C.Font.Style := [fsBold];
    C.Font.Color := lcdInk;
    C.TextOut(lcdR.Left + 6, lcdR.Top + 21, FitTextToWidth(C, FTitleStr, lcdR.Width - 12));

    FRectSeekSlider := Rect(lcdR.Left + 6, lcdR.Bottom - 14, lcdR.Right - 6, lcdR.Bottom - 5);
    C.Brush.Style := bsSolid;
    C.Brush.Color := TColor($8E9C80);
    C.Pen.Color := lcdInk;
    C.Rectangle(FRectSeekSlider);
    fillW := Round(SanitizeSingle(FSeekRatio, 0.0, 1.0, 0.0) * Max(1, FRectSeekSlider.Width - 2));
    if fillW > 0 then
    begin
      C.Brush.Color := lcdInk;
      C.FillRect(FRectSeekSlider.Left + 1, FRectSeekSlider.Top + 1, FRectSeekSlider.Left + 1 + fillW, FRectSeekSlider.Bottom - 1);
    end;
    seekThumbX := EnsureRange(FRectSeekSlider.Left + fillW - 3, FRectSeekSlider.Left, FRectSeekSlider.Right - 6);
    C.Brush.Color := clWhite;
    C.Rectangle(seekThumbX, FRectSeekSlider.Top - 1, seekThumbX + 6, FRectSeekSlider.Bottom + 1);
  end
  else
  begin
    C.Font.Size := 10;
    C.Font.Style := [fsBold];
    C.Font.Color := lcdInk;
    C.TextOut(lcdR.Left + 8, lcdR.Top + 23, FitTextToWidth(C, FTitleStr, lcdR.Width - 16));

    C.Font.Size := 8;
    C.Font.Style := [];
    if FAlbumStr <> '' then
      headerStr := FArtistStr + '  —  ' + FAlbumStr
    else
      headerStr := FArtistStr;
    C.TextOut(lcdR.Left + 8, lcdR.Top + 44, FitTextToWidth(C, headerStr, lcdR.Width - 16));

    FRectSeekSlider := Rect(lcdR.Left + 46, lcdR.Bottom - 19, lcdR.Right - 46, lcdR.Bottom - 7);
    C.Brush.Style := bsSolid;
    C.Brush.Color := TColor($8E9C80);
    C.Pen.Color := lcdInk;
    C.Rectangle(FRectSeekSlider);
    fillW := Round(SanitizeSingle(FSeekRatio, 0.0, 1.0, 0.0) * Max(1, FRectSeekSlider.Width - 2));
    if fillW > 0 then
    begin
      C.Brush.Color := lcdInk;
      C.FillRect(FRectSeekSlider.Left + 1, FRectSeekSlider.Top + 1, FRectSeekSlider.Left + 1 + fillW, FRectSeekSlider.Bottom - 1);
    end;
    seekThumbX := EnsureRange(FRectSeekSlider.Left + fillW - 4, FRectSeekSlider.Left, FRectSeekSlider.Right - 8);
    C.Brush.Color := clWhite;
    C.Rectangle(seekThumbX, FRectSeekSlider.Top - 2, seekThumbX + 8, FRectSeekSlider.Bottom + 2);

    C.Brush.Style := bsClear;
    C.Font.Name := 'Monospace';
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := lcdInk;
    C.TextOut(lcdR.Left + 6, lcdR.Bottom - 20, FormatDuration(FPosMs));
    C.TextOut(lcdR.Right - 42, lcdR.Bottom - 20, FormatDuration(FDurMs));
  end;

  // 5. Right 64-Band Segmented Spectrum / Oscilloscope CRT (Only shown when wide enough!)
  if showCRT then
  begin
    if isCompactMini then
      crtR := Rect(W - 254, 28, W - 8, H - 8)
    else
      crtR := Rect(W - 254, 32, W - 8, 140);
    FRectCRT := crtR;
    crtBg := TColor($141C14);
    crtInk := TColor($55EE66);
    crtPeak := TColor($CCFFDD);
    DrawMacSunkenPanel(C, crtR, crtBg);

    C.Brush.Style := bsClear;
    C.Font.Name := 'Monospace';
    C.Font.Size := 7;
    C.Font.Style := [fsBold];
    C.Font.Color := crtPeak;
    if not FOscilloscopeMode then
      C.TextOut(crtR.Left + 6, crtR.Top + 3, '64-BAND FFT SPECTRUM [CLICK]')
    else
      C.TextOut(crtR.Left + 6, crtR.Top + 3, '512-SAMPLE OSCILLOSCOPE [CLICK]');

    if not FOscilloscopeMode then
    begin
      barW := 2;
      for i := 0 to 58 do
      begin
        mag := SanitizeSingle(FLocalMags[i], 0.0, 1.0, 0.0);
        pk  := SanitizeSingle(FLocalPeaks[i], 0.0, 1.0, 0.0);
        barH := Trunc(mag * (crtR.Height - 22));
        x0 := crtR.Left + 5 + (i * 4);
        if x0 + barW > crtR.Right - 3 then Break;

        C.Brush.Style := bsSolid;
        C.Brush.Color := crtInk;
        segY := crtR.Bottom - 4;
        while segY >= crtR.Bottom - 4 - barH do
        begin
          if segY > crtR.Top + 16 then
            C.FillRect(x0, segY - 2, x0 + barW, segY);
          Dec(segY, 3);
        end;

        peakY := crtR.Bottom - 4 - Trunc(pk * (crtR.Height - 22));
        if (peakY > crtR.Top + 16) and (peakY < crtR.Bottom - 4) then
        begin
          C.Brush.Color := crtPeak;
          C.FillRect(x0, peakY - 2, x0 + barW, peakY);
        end;
      end;
    end
    else
    begin
      C.Pen.Color := crtInk;
      for i := 0 to Min(230, crtR.Width - 12) do
      begin
        x0 := crtR.Left + 5 + i;
        x1 := x0 + 1;
        y0 := ((crtR.Top + 16 + crtR.Bottom - 4) div 2) - Round(SanitizeSingle(FLocalOsc[i * 2], -1.0, 1.0, 0.0) * ((crtR.Height - 24) div 2));
        y1 := ((crtR.Top + 16 + crtR.Bottom - 4) div 2) - Round(SanitizeSingle(FLocalOsc[i * 2 + 2], -1.0, 1.0, 0.0) * ((crtR.Height - 24) div 2));
        C.Line(x0, EnsureRange(y0, crtR.Top + 16, crtR.Bottom - 4),
               x1, EnsureRange(y1, crtR.Top + 16, crtR.Bottom - 4));
      end;
    end;
  end
  else
    FRectCRT := Rect(0, 0, 0, 0);

  // 6. Track List & Optional Right Track Information Sidebar
  if not isCompactMini then
  begin
    if W < 450 then
      y0 := 130
    else
      y0 := 148;

    C.Pen.Color := clBlack;
    C.Line(1, y0, W - 1, y0);

    if showRightSide then
    begin
      leftPaneR  := Rect(2, y0 + 1, W - 262, H - 20);
      rightPaneR := Rect(W - 261, y0 + 1, W - 2, H - 20);
      C.Line(leftPaneR.Right, y0 + 1, leftPaneR.Right, H - 20);
    end
    else
    begin
      // Narrow-Tall Mode: Track List takes 100% of the width!
      leftPaneR  := Rect(2, y0 + 1, W - 2, H - 20);
      rightPaneR := Rect(0, 0, 0, 0);
    end;

    // 6A. Finder Track List (Responsive Columns!)
    C.Brush.Style := bsSolid;
    C.Brush.Color := clWhite;
    C.FillRect(leftPaneR);

    // Column Header Strip
    C.Brush.Color := TColor($E6E6E6);
    C.FillRect(leftPaneR.Left, leftPaneR.Top, leftPaneR.Right - 16, leftPaneR.Top + 20);
    C.Pen.Color := clBlack;
    C.Line(leftPaneR.Left, leftPaneR.Top + 20, leftPaneR.Right, leftPaneR.Top + 20);

    FRectTrackList := Rect(leftPaneR.Left, leftPaneR.Top + 21, leftPaneR.Right - 16, leftPaneR.Bottom);
    listW := FRectTrackList.Width;

    if listW >= 540 then
    begin
      colTitleX  := leftPaneR.Left + 52;
      colTitleW  := Round((listW - 144) * 0.38);
      colArtistX := colTitleX + colTitleW + 8;
      colArtistW := Round((listW - 144) * 0.26);
      colAlbumX  := colArtistX + colArtistW + 8;
      colAlbumW  := Max(40, (FRectTrackList.Right - 92) - colAlbumX);
      colTimeX   := FRectTrackList.Right - 86;
      colKindX   := FRectTrackList.Right - 38;
    end
    else if listW >= 360 then
    begin
      colTitleX  := leftPaneR.Left + 48;
      colTitleW  := Round((listW - 100) * 0.56);
      colArtistX := colTitleX + colTitleW + 8;
      colArtistW := Max(40, (FRectTrackList.Right - 48) - colArtistX);
      colAlbumX  := 0; colAlbumW := 0;
      colTimeX   := FRectTrackList.Right - 44;
      colKindX   := 0;
    end
    else
    begin
      colTitleX  := leftPaneR.Left + 46;
      colTitleW  := Max(40, (FRectTrackList.Right - 48) - colTitleX);
      colArtistX := 0; colArtistW := 0;
      colAlbumX  := 0; colAlbumW := 0;
      colTimeX   := FRectTrackList.Right - 44;
      colKindX   := 0;
    end;

    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    C.Font.Style := [fsBold];
    C.Font.Color := clBlack;
    C.Brush.Style := bsClear;
    y0 := leftPaneR.Top + ((20 - C.TextHeight('Ag')) div 2) - 1;
    C.TextOut(leftPaneR.Left + 6, y0, '#');
    C.TextOut(colTitleX, y0, 'Title');
    if colArtistW > 0 then C.TextOut(colArtistX, y0, 'Artist');
    if colAlbumW > 0  then C.TextOut(colAlbumX,  y0, 'Album');
    C.TextOut(colTimeX, y0, 'Time');
    if colKindX > 0   then C.TextOut(colKindX,   y0, 'Kind');

    visRows := VisibleTrackRows;
    for r := 0 to visRows - 1 do
    begin
      i := FTopRowIndex + r;
      if i >= FTotalTracks then Break;
      rowY := FRectTrackList.Top + (r * ROW_HEIGHT);
      rowR := Rect(FRectTrackList.Left, rowY, FRectTrackList.Right, rowY + ROW_HEIGHT);

      GetTrackDetailsAtRow(i, tid, tTitle, tArtist, tAlbum, tTime, tFmt, tPath, dummyY, dummyTN, dummyBR, dummyDur);

      if i = FSelectedRowIndex then
      begin
        C.Brush.Style := bsSolid;
        C.Brush.Color := clBlack;
        C.FillRect(rowR);
        C.Font.Color := clWhite;
      end
      else
      begin
        C.Brush.Style := bsSolid;
        if (i and 1) = 1 then C.Brush.Color := TColor($F5F5F5) else C.Brush.Color := clWhite;
        C.FillRect(rowR);
        C.Font.Color := clBlack;
      end;

      C.Font.Size := 8;
      if tid = FCurrentTrackID then C.Font.Style := [fsBold] else C.Font.Style := [];
      C.Brush.Style := bsClear;
      y0 := rowY + ((ROW_HEIGHT - C.TextHeight('Ag')) div 2) - 1;
      if tid = FCurrentTrackID then
        C.TextOut(rowR.Left + 5, y0, Format('▶ %d', [IfThen(tid > 10000, Integer(tid) - 10000, Integer(tid))]))
      else
        C.TextOut(rowR.Left + 6, y0, Format('▷ %d', [IfThen(tid > 10000, Integer(tid) - 10000, Integer(tid))]));

      C.TextOut(colTitleX, y0, FitTextToWidth(C, tTitle, colTitleW));
      if colArtistW > 0 then
        C.TextOut(colArtistX, y0, FitTextToWidth(C, tArtist, colArtistW));
      if colAlbumW > 0 then
        C.TextOut(colAlbumX, y0, FitTextToWidth(C, tAlbum, colAlbumW));
      C.TextOut(colTimeX, y0, tTime);
      if colKindX > 0 then
        C.TextOut(colKindX, y0, tFmt);

      if i <> FSelectedRowIndex then
      begin
        C.Pen.Color := TColor($E8E8E8);
        C.Line(rowR.Left, rowR.Bottom - 1, rowR.Right, rowR.Bottom - 1);
      end;
    end;

    // Fast Scrollbar Track
    FRectScrollUp    := Rect(leftPaneR.Right - 16, leftPaneR.Top, leftPaneR.Right, leftPaneR.Top + 16);
    FRectScrollDown  := Rect(leftPaneR.Right - 16, leftPaneR.Bottom - 16, leftPaneR.Right, leftPaneR.Bottom);
    FRectScrollTrack := Rect(leftPaneR.Right - 16, leftPaneR.Top + 16, leftPaneR.Right, leftPaneR.Bottom - 16);

    C.Brush.Style := bsSolid;
    C.Brush.Color := TColor($CCCCCC);
    C.Pen.Color := clBlack;
    C.Rectangle(FRectScrollTrack);
    DrawMacButton(C, FRectScrollUp,   '▲', False, FActivePressedBtn = 20);
    DrawMacButton(C, FRectScrollDown, '▼', False, FActivePressedBtn = 21);

    maxTop := Max(1, FTotalTracks - visRows);
    trackAreaH := Max(20, FRectScrollTrack.Height);
    thumbH := Max(20, Min(trackAreaH div 4, 48));
    thumbY := FRectScrollTrack.Top + Round((FTopRowIndex / maxTop) * (trackAreaH - thumbH));
    thumbR := Rect(FRectScrollTrack.Left + 1, thumbY, FRectScrollTrack.Right - 1, thumbY + thumbH);
    C.Brush.Color := clWhite;
    C.Pen.Color := clBlack;
    C.Rectangle(thumbR);
    C.Line(thumbR.Left + 3, (thumbR.Top + thumbR.Bottom) div 2 - 2, thumbR.Right - 3, (thumbR.Top + thumbR.Bottom) div 2 - 2);
    C.Line(thumbR.Left + 3, (thumbR.Top + thumbR.Bottom) div 2,     thumbR.Right - 3, (thumbR.Top + thumbR.Bottom) div 2);
    C.Line(thumbR.Left + 3, (thumbR.Top + thumbR.Bottom) div 2 + 2, thumbR.Right - 3, (thumbR.Top + thumbR.Bottom) div 2 + 2);

    // 6B. Right Sidebar: Track Information / Synchronized Lyrics Inspector (Only shown when showRightSide is True!)
    if showRightSide then
    begin
      C.Brush.Style := bsSolid;
      C.Brush.Color := TColor($ECECEC);
      C.FillRect(rightPaneR);

      FRectRightHeader := Rect(rightPaneR.Left, rightPaneR.Top, rightPaneR.Right, rightPaneR.Top + 20);
      C.Brush.Color := clBlack;
      C.FillRect(FRectRightHeader);
      C.Font.Size := 8;
      C.Font.Color := clWhite;
      C.Font.Style := [fsBold];
      C.Brush.Style := bsClear;
      if not FLyricsMode then
        C.TextOut(rightPaneR.Left + 8, rightPaneR.Top + ((20 - C.TextHeight('Ag')) div 2) - 1, 'Track Information')
      else
        C.TextOut(rightPaneR.Left + 8, rightPaneR.Top + ((20 - C.TextHeight('Ag')) div 2) - 1, 'Synchronized Lyrics');

      // Classic Mac Header Mode Toggle Pill ([ ♪ Lyrics ] / [ ℹ Details ])
      thumbR := Rect(rightPaneR.Right - 72, rightPaneR.Top + 2, rightPaneR.Right - 4, rightPaneR.Top + 18);
      C.Brush.Style := bsSolid;
      C.Brush.Color := TColor($333333);
      C.Pen.Color := TColor($BBBBBB);
      C.Rectangle(thumbR);
      C.Brush.Style := bsClear;
      C.Font.Size := 7;
      C.Font.Style := [fsBold];
      C.Font.Color := TColor($CCFFDD);
      if not FLyricsMode then
        headerStr := '♪ Lyrics'
      else
        headerStr := 'ℹ Details';
      C.TextOut(thumbR.Left + ((thumbR.Width - C.TextWidth(headerStr)) div 2),
                thumbR.Top + ((thumbR.Height - C.TextHeight('Ag')) div 2) - 1, headerStr);
      C.Font.Size := 8;

      if (FSelectedRowIndex >= 0) and (FSelectedRowIndex < FTotalTracks) then
        GetTrackDetailsAtRow(FSelectedRowIndex, infoTID, infoTitle, infoArtist, infoAlbum, infoTime, infoFmt, infoPath, infoYear, infoTrackNo, infoBitrate, infoDurMs)
      else
        GetTrackDetailsAtRow(0, infoTID, infoTitle, infoArtist, infoAlbum, infoTime, infoFmt, infoPath, infoYear, infoTrackNo, infoBitrate, infoDurMs);

      if (infoPath = '') and (FPShm <> nil) then
        infoPath := StrPas(@FPShm^.VirtualURI[0]);

      EnsureCoverThumbLoaded(infoPath);
      DrawVinylDiscIcon(C, rightPaneR.Left + 10, rightPaneR.Top + 28, (FPlayState = OMM_STATE_PLAYING) and (infoTID = FCurrentTrackID));
      C.Font.Color := clBlack;
      C.Font.Style := [fsBold];
      C.Brush.Style := bsClear;
      if (FPlayState = OMM_STATE_PLAYING) and (infoTID = FCurrentTrackID) then
        C.TextOut(rightPaneR.Left + 62, rightPaneR.Top + 30, Format('▶ NOW PLAYING (#%d)', [IfThen(infoTID > 10000, Integer(infoTID) - 10000, Integer(infoTID))]))
      else
        C.TextOut(rightPaneR.Left + 62, rightPaneR.Top + 30, Format('SELECTED TRACK (#%d)', [IfThen(infoTID > 10000, Integer(infoTID) - 10000, Integer(infoTID))]));

      C.Font.Style := [];
      if FLyricsMode and (FTitleStr <> '') then
        C.TextOut(rightPaneR.Left + 62, rightPaneR.Top + 48,
          FitTextToWidth(C, FTitleStr + ' — ' + FArtistStr, rightPaneR.Width - 68))
      else
        C.TextOut(rightPaneR.Left + 62, rightPaneR.Top + 48,
          FitTextToWidth(C, Format('%s · %d kbps · %d Hz', [infoFmt, infoBitrate, FSampleRate]), rightPaneR.Width - 68));

      // Sunken Metadata / Auto-Scrolling Lyrics Card with strict vertical bounds checking (Zero Overflow!)
      cardR := Rect(rightPaneR.Left + 8, rightPaneR.Top + 80, rightPaneR.Right - 8, rightPaneR.Bottom - 32);
      FRectDetailsCard := cardR;
      if cardR.Bottom > cardR.Top + 24 then
      begin
        DrawMacSunkenPanel(C, cardR, clWhite);

        if not FLyricsMode then
        begin
          y0 := cardR.Top + 8;
          C.Brush.Style := bsClear;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Title:');
            C.Font.Style := [fsBold]; C.Font.Color := clBlack;
            C.TextOut(cardR.Left + 8, y0 + 15, FitTextToWidth(C, infoTitle, cardR.Width - 16));
            Inc(y0, 38);
          end;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Artist:');
            C.Font.Style := []; C.Font.Color := clBlack;
            C.TextOut(cardR.Left + 8, y0 + 15, FitTextToWidth(C, infoArtist, cardR.Width - 16));
            Inc(y0, 38);
          end;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Album:');
            C.Font.Style := []; C.Font.Color := clBlack;
            C.TextOut(cardR.Left + 8, y0 + 15, FitTextToWidth(C, infoAlbum, cardR.Width - 16));
            Inc(y0, 38);
          end;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Year / Track #:');
            C.Font.Style := []; C.Font.Color := clBlack;
            C.TextOut(cardR.Left + 8, y0 + 15, Format('%d   ·   Track #%d   (%s)', [infoYear, infoTrackNo, infoTime]));
            Inc(y0, 38);
          end;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Audio Specs:');
            C.Font.Style := []; C.Font.Color := TColor($333333);
            C.TextOut(cardR.Left + 8, y0 + 15,
              FitTextToWidth(C, Format('%s · %d kbps · %d Hz / %d-Bit', [infoFmt, infoBitrate, FSampleRate, FBitDepth]), cardR.Width - 16));
            Inc(y0, 38);
          end;

          if y0 + 32 <= cardR.Bottom - 4 then
          begin
            C.Font.Style := [fsBold]; C.Font.Color := TColor($555555);
            C.TextOut(cardR.Left + 8, y0, 'Source File:');
            C.Font.Style := []; C.Font.Color := TColor($333333);
            C.TextOut(cardR.Left + 8, y0 + 15, FitTextToWidth(C, ExtractFileName(infoPath), cardR.Width - 16));
          end;
        end
        else
        begin
          // Auto-Scrolling Synchronized Lyrics View inside cardR (Top-anchored, center-scrolling)
          if (FGuiLyricCount = 0) and (FPShm <> nil) and (FPShm^.LrcTextLen > 0) then
          begin
            FLastLrcGen := FPShm^.LrcGeneration;
            ParseGuiLrcText(StrPas(@FPShm^.LrcRawText[0]));
            UpdateActiveLyricLine(FPosMs, True);
          end;

          y1 := (cardR.Top + cardR.Bottom) div 2;
          if FGuiLyricCount > 0 then
          begin
            for i := 0 to FGuiLyricCount - 1 do
            begin
              rowY := cardR.Top + 6 + Round(i * LYRIC_LINE_H - FLyricScrollY);
              if (rowY < cardR.Top + 3) or (rowY + LYRIC_LINE_H > cardR.Bottom - 3) then
                Continue;

              if i = FActiveLyricIdx then
              begin
                rowR := Rect(cardR.Left + 3, rowY, cardR.Right - 7, rowY + LYRIC_LINE_H - 1);
                C.Brush.Style := bsSolid;
                C.Brush.Color := TColor($DCE8D0);
                C.FillRect(rowR);
                C.Brush.Color := TColor($244824);
                C.FillRect(rowR.Left, rowR.Top, rowR.Left + 3, rowR.Bottom);

                C.Brush.Style := bsClear;
                C.Font.Size := 8;
                C.Font.Style := [fsBold];
                C.Font.Color := TColor($102010);
                headerStr := FitTextToWidth(C, '♪ ' + FGuiLyrics[i].Text, cardR.Width - 20);
                x0 := cardR.Left + Max(8, (cardR.Width - 6 - C.TextWidth(headerStr)) div 2);
                C.TextOut(x0, rowY + ((LYRIC_LINE_H - C.TextHeight('Ag')) div 2) - 1, headerStr);
              end
              else
              begin
                C.Brush.Style := bsClear;
                C.Font.Size := 8;
                C.Font.Style := [];
                if Abs(i - FActiveLyricIdx) = 1 then
                  C.Font.Color := TColor($444444)
                else if Abs(i - FActiveLyricIdx) = 2 then
                  C.Font.Color := TColor($777777)
                else
                  C.Font.Color := TColor($9A9A9A);
                headerStr := FitTextToWidth(C, FGuiLyrics[i].Text, cardR.Width - 20);
                x0 := cardR.Left + Max(8, (cardR.Width - 6 - C.TextWidth(headerStr)) div 2);
                C.TextOut(x0, rowY + ((LYRIC_LINE_H - C.TextHeight('Ag')) div 2) - 1, headerStr);
              end;
            end;

            // Subtle progress indicator bar on right inner edge of cardR
            trackAreaH := Max(16, cardR.Height - 8);
            thumbH := Max(12, trackAreaH div Max(2, FGuiLyricCount));
            thumbY := cardR.Top + 4 + Round((EnsureRange(FActiveLyricIdx, 0, Max(1, FGuiLyricCount - 1)) / Max(1, FGuiLyricCount - 1)) * (trackAreaH - thumbH));
            C.Brush.Style := bsSolid;
            C.Brush.Color := TColor($E8E8E8);
            C.FillRect(cardR.Right - 5, cardR.Top + 3, cardR.Right - 2, cardR.Bottom - 3);
            C.Brush.Color := TColor($6A886A);
            C.FillRect(cardR.Right - 5, thumbY, cardR.Right - 2, thumbY + thumbH);
          end
          else if FLyricCurFallback <> '' then
          begin
            C.Brush.Style := bsClear;
            C.Font.Size := 8;
            C.Font.Style := [fsBold];
            C.Font.Color := clBlack;
            headerStr := FitTextToWidth(C, '♪ ' + FLyricCurFallback, cardR.Width - 16);
            x0 := cardR.Left + Max(8, (cardR.Width - C.TextWidth(headerStr)) div 2);
            C.TextOut(x0, cardR.Top + 16, headerStr);
            if FLyricNextFallback <> '' then
            begin
              C.Font.Style := [];
              C.Font.Color := TColor($666666);
              headerStr := FitTextToWidth(C, FLyricNextFallback, cardR.Width - 16);
              x0 := cardR.Left + Max(8, (cardR.Width - C.TextWidth(headerStr)) div 2);
              C.TextOut(x0, cardR.Top + 40, headerStr);
            end;
          end
          else
          begin
            C.Brush.Style := bsClear;
            C.Font.Size := 8;
            C.Font.Style := [fsBold];
            C.Font.Color := TColor($555555);
            headerStr := '♪ No Synchronized Lyrics';
            C.TextOut(cardR.Left + Max(8, (cardR.Width - C.TextWidth(headerStr)) div 2), cardR.Top + 16, headerStr);
            C.Font.Style := [];
            C.Font.Color := TColor($888888);
            headerStr := 'Play a track to load LRC lyrics';
            C.TextOut(cardR.Left + Max(8, (cardR.Width - C.TextWidth(headerStr)) div 2), cardR.Top + 38, headerStr);
          end;
        end;
      end;

      // Flat Classic Mac Mineral Login & Settings Button at Bottom of Track Information Panel
      FRectBtnSettings := Rect(rightPaneR.Left + 8, rightPaneR.Bottom - 25, rightPaneR.Right - 8, rightPaneR.Bottom - 5);
      DrawMacButton(C, FRectBtnSettings, '⚙ Mineral Login & Settings', FSettingsOpen, (FActivePressedBtn = 30) or FSettingsOpen);
    end
    else
    begin
      FRectRightHeader := Rect(0, 0, 0, 0);
      FRectDetailsCard := Rect(0, 0, 0, 0);
      FRectBtnSettings := Rect(W - 88, H - 19, W - 18, H - 2);
    end;

    FRectPluginWake   := Rect(0, 0, 0, 0);
    FRectPluginStream := Rect(0, 0, 0, 0);
    FRectPluginUnload := Rect(0, 0, 0, 0);

    // 7. Bottom Window Status Bar
    C.Pen.Color := clBlack;
    C.Line(1, H - 20, W - 1, H - 20);
    C.Font.Size := 8;
    C.Font.Style := [];
    C.Font.Color := clBlack;
    C.Brush.Style := bsClear;
    if FIsOnlineSearchMode then
      C.TextOut(8, (H - 20) + ((19 - C.TextHeight('Ag')) div 2) - 1,
        FitTextToWidth(C, Format('Mineral Online Search: "%s" (%d tracks)   ·   Click row to stream   ·   Click [×] for Local Library', [FOnlineQuery, FTotalTracks]), IfThen(showRightSide, W - 28, W - 96)))
    else
      C.TextOut(8, (H - 20) + ((19 - C.TextHeight('Ag')) div 2) - 1,
        FitTextToWidth(C, Format('%d tracks   ·   Click row to play   ·   Click Globe button to search Mineral Online', [FTotalTracks]), IfThen(showRightSide, W - 28, W - 96)));

    if not showRightSide then
      DrawMacButton(C, FRectBtnSettings, '⚙ Login', FSettingsOpen, (FActivePressedBtn = 30) or FSettingsOpen);
  end
  else
  begin
    FRectBtnSettings := Rect(0, 0, 0, 0);
    FRectTrackList := Rect(0, 0, 0, 0);
    FRectScrollUp := Rect(0, 0, 0, 0);
    FRectScrollDown := Rect(0, 0, 0, 0);
    FRectScrollTrack := Rect(0, 0, 0, 0);
    FRectPluginWake := Rect(0, 0, 0, 0);
    FRectPluginStream := Rect(0, 0, 0, 0);
    FRectPluginUnload := Rect(0, 0, 0, 0);
  end;

  // Classic Macintosh Bottom-Right Resize Grow Box
  FRectGrowBox := Rect(W - 15, H - 15, W, H);
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWhite;
  C.Pen.Color := clBlack;
  C.Rectangle(W - 14, H - 14, W - 1, H - 1);
  C.Rectangle(W - 11, H - 11, W - 5, H - 5);
  C.Rectangle(W - 8,  H - 8,  W - 2, H - 2);

  // 8. Floating Classic Macintosh System 7 Mineral Source Dropdown Popup Menu
  if FSourceMenuOpen and (not isCompactMini) and (FRectSourceDropdown.Width > 0) then
  begin
    FRectSourcePopup := Rect(
      FRectSourceDropdown.Left,
      FRectSourceDropdown.Bottom + 1,
      Max(FRectSourceDropdown.Right, FRectSourceDropdown.Left + 190),
      FRectSourceDropdown.Bottom + 1 + 6 * 22
    );
    // 2px Classic Mac Drop Shadow
    C.Brush.Style := bsSolid;
    C.Brush.Color := clBlack;
    C.FillRect(FRectSourcePopup.Left + 2, FRectSourcePopup.Top + 2, FRectSourcePopup.Right + 2, FRectSourcePopup.Bottom + 2);
    // Crisp White Popup Box with 1px Black Border
    C.Brush.Color := clWhite;
    C.Pen.Color := clBlack;
    C.Rectangle(FRectSourcePopup);

    C.Font.Name := 'Sans';
    C.Font.Size := 8;
    for i := 0 to 5 do
    begin
      rowR := Rect(
        FRectSourcePopup.Left + 1,
        FRectSourcePopup.Top + 1 + (i * 22),
        FRectSourcePopup.Right - 1,
        FRectSourcePopup.Top + 1 + ((i + 1) * 22)
      );
      if (i = FSourceMenuHoverIdx) or ((FSourceMenuHoverIdx < 0) and (i = FMineralSourceIdx)) then
      begin
        C.Brush.Style := bsSolid;
        C.Brush.Color := clBlack;
        C.FillRect(rowR);
        C.Font.Color := clWhite;
      end
      else
      begin
        C.Brush.Style := bsSolid;
        C.Brush.Color := clWhite;
        C.FillRect(rowR);
        C.Font.Color := clBlack;
      end;
      C.Brush.Style := bsClear;
      y0 := rowR.Top + ((22 - C.TextHeight('Ag')) div 2) - 1;
      if i = FMineralSourceIdx then
      begin
        C.Font.Style := [fsBold];
        C.TextOut(rowR.Left + 6, y0, '✓');
      end
      else
        C.Font.Style := [];
      C.TextOut(rowR.Left + 22, y0, GetMineralSourceLabel(i, False));
    end;
  end
  else
    FRectSourcePopup := Rect(0, 0, 0, 0);

  // 9. Lightweight Classic Macintosh System 7 Mineral Account & Login Modal
  if FSettingsOpen and (not isCompactMini) then
    DrawMineralSettingsModal(C, W, H)
  else
  begin
    FRectSetModal := Rect(0, 0, 0, 0);
    FRectSetClose := Rect(0, 0, 0, 0);
  end;

  pbMac.Canvas.Draw(0, 0, FBackBuffer);
end;

procedure TMainForm.pbMacMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  pt: TPoint;
  clickedRow: Integer;
  tid: UInt32;
  tTitle, tArtist, tAlbum, tTime, tFmt, tPath: string;
  dummyY, dummyTN, dummyBR: UInt16;
  dummyDur: UInt32;
  ratio: Single;
begin
  if Button <> mbLeft then Exit;
  pt := Point(X, Y);
  FLastClickX := X;
  FLastClickY := Y;
  FFilterActive := False;

  // 0A. If Mineral Login & Settings Modal is open, handle modal interactions first!
  if FSettingsOpen then
  begin
    if PtInRect(FRectSetClose, pt) then
    begin
      StopMineralQRLogin;
      FSettingsOpen := False;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSetTabWY, pt) then
    begin
      if FSettingsTab <> 0 then
      begin
        StopMineralQRLogin;
        FillChar(FQrGrid, SizeOf(FQrGrid), 0);
        FQrGridW := 0; FQrGridH := 0;
        FSettingsTab := 0;
        FQrStatusText := 'Ready — Select QR Login or Paste Cookie';
        ReloadMineralAuthStatus;
      end;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSetTabBili, pt) then
    begin
      if FSettingsTab <> 1 then
      begin
        StopMineralQRLogin;
        FillChar(FQrGrid, SizeOf(FQrGrid), 0);
        FQrGridW := 0; FQrGridH := 0;
        FSettingsTab := 1;
        FQrStatusText := 'Ready — Select QR Login or Paste Cookie';
        ReloadMineralAuthStatus;
      end;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSetTabQQ, pt) then
    begin
      if FSettingsTab <> 2 then
      begin
        StopMineralQRLogin;
        FillChar(FQrGrid, SizeOf(FQrGrid), 0);
        FQrGridW := 0; FQrGridH := 0;
        FSettingsTab := 2;
        FQrStatusText := 'Ready — Click [Scan QR Login] or [Paste Cookie...]';
        ReloadMineralAuthStatus;
      end;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSetTabAM, pt) then
    begin
      if FSettingsTab <> 3 then
      begin
        StopMineralQRLogin;
        FillChar(FQrGrid, SizeOf(FQrGrid), 0);
        FQrGridW := 0; FQrGridH := 0;
        FSettingsTab := 3;
        FQrStatusText := 'Ready — Click [Web Sign-In] or [Paste Token...]';
        ReloadMineralAuthStatus;
      end;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSetBtnQR, pt) then
    begin
      FActivePressedBtn := 31;
      StartMineralQRLogin;
      Exit;
    end
    else if PtInRect(FRectSetBtnCookie, pt) then
    begin
      FActivePressedBtn := 32;
      PromptManualCookieInput;
      FActivePressedBtn := 0;
      Exit;
    end
    else if PtInRect(FRectSetBtnLogout, pt) then
    begin
      FActivePressedBtn := 33;
      ClearMineralLogout;
      Exit;
    end
    else if PtInRect(FRectBtnSettings, pt) then
    begin
      StopMineralQRLogin;
      FSettingsOpen := False;
      pbMac.Invalidate;
      Exit;
    end
    else if not PtInRect(FRectSetModal, pt) then
    begin
      StopMineralQRLogin;
      FSettingsOpen := False;
      pbMac.Invalidate;
      Exit;
    end
    else
      Exit;
  end;

  // 0. If Mineral Source Dropdown Popup Menu is open, handle menu item selection first!
  if FSourceMenuOpen then
  begin
    if PtInRect(FRectSourcePopup, pt) then
    begin
      clickedRow := (Y - FRectSourcePopup.Top - 1) div 22;
      if (clickedRow >= 0) and (clickedRow <= 5) then
        SelectMineralSource(clickedRow)
      else
        FSourceMenuOpen := False;
      pbMac.Invalidate;
      Exit;
    end
    else if PtInRect(FRectSourceDropdown, pt) then
    begin
      FSourceMenuOpen := False;
      pbMac.Invalidate;
      Exit;
    end
    else
      FSourceMenuOpen := False;
  end;

  // 1. In-Window Close / Minimize (MiniPlayer) / Maximize Buttons
  if PtInRect(FRectCloseBox, pt) then
  begin
    Close;
    Exit;
  end;
  if PtInRect(FRectMinBox, pt) then
  begin
    ToggleMiniPlayer;
    Exit;
  end;
  if PtInRect(FRectMaxBox, pt) then
  begin
    ToggleMaximizeWindow;
    Exit;
  end;

  // 2. Bottom-Right Resize Grow Box or Right/Bottom Window Edges
  if PtInRect(FRectGrowBox, pt) or (X >= pbMac.ClientWidth - 6) or (Y >= pbMac.ClientHeight - 6) then
  begin
    FIsResizingWin := True;
    FDragStartMouse := Mouse.CursorPos;
    FDragStartBounds := Bounds(Left, Top, Width, Height);
    FLastBoundsTick := GetTickCount64;
    Exit;
  end;

  // 3. Title Bar Drag to Move Window
  if Y < 24 then
  begin
    FIsDraggingWin := True;
    FDragStartMouse := Mouse.CursorPos;
    FDragStartBounds := Bounds(Left, Top, Width, Height);
    FLastBoundsTick := GetTickCount64;
    Exit;
  end;

  // 4. Transport & Control Deck Buttons
  if PtInRect(FRectBtnPrev, pt) then
  begin
    FActivePressedBtn := 1;
    if FSelectedRowIndex > 0 then
      PlayRowAtIndex(FSelectedRowIndex - 1)
    else if FTotalTracks > 0 then
      PlayRowAtIndex(0);
  end
  else if PtInRect(FRectBtnPlay, pt) then
  begin
    FActivePressedBtn := 2;
    if (FSelectedRowIndex >= 0) and (FSelectedRowIndex < FTotalTracks) then
    begin
      GetTrackDetailsAtRow(FSelectedRowIndex, tid, tTitle, tArtist, tAlbum, tTime, tFmt, tPath, dummyY, dummyTN, dummyBR, dummyDur);
      if (FPlayState = OMM_STATE_PAUSED) and (tid = FCurrentTrackID) then
        SendCommand(OP_REQ_RESUME)
      else
        PlayRowAtIndex(FSelectedRowIndex);
    end
    else if FTotalTracks > 0 then
      PlayRowAtIndex(0)
    else
      SendCommand(OP_REQ_PLAY);
  end
  else if PtInRect(FRectBtnPause, pt) then
  begin
    FActivePressedBtn := 3;
    if FPlayState = OMM_STATE_PAUSED then SendCommand(OP_REQ_RESUME) else SendCommand(OP_REQ_PAUSE);
  end
  else if PtInRect(FRectBtnStop, pt) then
  begin
    FActivePressedBtn := 4;
    SendCommand(OP_REQ_STOP);
  end
  else if PtInRect(FRectBtnNext, pt) then
  begin
    FActivePressedBtn := 5;
    if (FSelectedRowIndex >= 0) and (FSelectedRowIndex < FTotalTracks - 1) then
      PlayRowAtIndex(FSelectedRowIndex + 1)
    else if FTotalTracks > 0 then
      PlayRowAtIndex(0);
  end
  else if PtInRect(FRectBtnFile, pt) then
  begin
    FActivePressedBtn := 6;
    PromptScanDirectory;
  end
  else if PtInRect(FRectBtnNetSearch, pt) then
  begin
    FActivePressedBtn := 10;
    TriggerMineralOnlineSearch(FFilterText);
  end
  else if PtInRect(FRectFilterClear, pt) then
  begin
    FActivePressedBtn := 9;
    if FEdtFilter <> nil then FEdtFilter.Text := '';
    FFilterText := '';
    FMineralSourceIdx := 0;
    RebuildFilteredList;
  end
  else if PtInRect(FRectSourceDropdown, pt) then
  begin
    FSourceMenuOpen := not FSourceMenuOpen;
    FSourceMenuHoverIdx := FMineralSourceIdx;
  end
  else if PtInRect(FRectFilterBox, pt) then
  begin
    FFilterActive := True;
    if (FEdtFilter <> nil) and FEdtFilter.Visible and FEdtFilter.CanFocus then
      FEdtFilter.SetFocus;
  end
  else if PtInRect(FRectCRT, pt) then
  begin
    FOscilloscopeMode := not FOscilloscopeMode;
  end
  else if PtInRect(FRectRightHeader, pt) or PtInRect(FRectDetailsCard, pt) then
  begin
    FLyricsMode := not FLyricsMode;
    if FLyricsMode then
    begin
      if (FGuiLyricCount = 0) and (FCurrentTrackID > 0) then
        RequestOnlineLyricsForCurrentTrack;
      UpdateActiveLyricLine(FPosMs, True);
    end;
  end
  else if PtInRect(FRectVolSlider, pt) then
  begin
    FIsDraggingVol := True;
    ratio := EnsureRange((X - FRectVolSlider.Left) / Max(1, FRectVolSlider.Width), 0.0, 1.0);
    SendVolume(ratio);
  end
  else if PtInRect(FRectSeekSlider, pt) then
  begin
    FIsDraggingSeek := True;
    FSeekRatio := EnsureRange((X - FRectSeekSlider.Left) / Max(1, FRectSeekSlider.Width), 0.0, 1.0);
  end
  else if PtInRect(FRectBtnSettings, pt) then
  begin
    FActivePressedBtn := 30;
    FSourceMenuOpen := False;
    FSettingsOpen := not FSettingsOpen;
    if FSettingsOpen then
    begin
      case FMineralSourceIdx of
        1: FSettingsTab := 0; // NetEase
        2: FSettingsTab := 1; // Bilibili
        3: FSettingsTab := 3; // Apple Music
        4: FSettingsTab := 2; // QQ Music
      end;
      ReloadMineralAuthStatus;
    end
    else
      StopMineralQRLogin;
  end
  else if PtInRect(FRectScrollUp, pt) then
  begin
    FActivePressedBtn := 20;
    ScrollToRow(FTopRowIndex - 3);
  end
  else if PtInRect(FRectScrollDown, pt) then
  begin
    FActivePressedBtn := 21;
    ScrollToRow(FTopRowIndex + 3);
  end
  else if PtInRect(FRectScrollTrack, pt) then
  begin
    FIsDraggingScroll := True;
    ratio := EnsureRange((Y - FRectScrollTrack.Top) / Max(1, FRectScrollTrack.Height), 0.0, 1.0);
    ScrollToRow(Round(ratio * Max(0, FTotalTracks - VisibleTrackRows)));
  end
  else if PtInRect(FRectTrackList, pt) then
  begin
    clickedRow := FTopRowIndex + ((Y - FRectTrackList.Top) div ROW_HEIGHT);
    if (clickedRow >= 0) and (clickedRow < FTotalTracks) then
    begin
      if (clickedRow <> FLastClickedRow) or (GetTickCount64 - FLastRowClickTick > 400) or (FPlayState <> OMM_STATE_PLAYING) then
        PlayRowAtIndex(clickedRow);
      FLastClickedRow := clickedRow;
    end;
  end;

  pbMac.Invalidate;
end;

procedure TMainForm.pbMacMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  ratio: Single;
  curMouse: TPoint;
  newW, newH: Integer;
  nowTick: Int64;
begin
  if FSourceMenuOpen then
  begin
    if PtInRect(FRectSourcePopup, Point(X, Y)) then
    begin
      newH := (Y - FRectSourcePopup.Top - 1) div 22;
      if (newH >= 0) and (newH <= 5) and (newH <> FSourceMenuHoverIdx) then
      begin
        FSourceMenuHoverIdx := newH;
        pbMac.Invalidate;
      end;
    end;
    Exit;
  end;

  if FIsDraggingWin then
  begin
    nowTick := GetTickCount64;
    if nowTick - FLastBoundsTick >= 14 then
    begin
      FLastBoundsTick := nowTick;
      curMouse := Mouse.CursorPos;
      SetBounds(FDragStartBounds.Left + (curMouse.X - FDragStartMouse.X),
                FDragStartBounds.Top + (curMouse.Y - FDragStartMouse.Y),
                Width, Height);
    end;
    Exit;
  end;

  if FIsResizingWin then
  begin
    nowTick := GetTickCount64;
    if nowTick - FLastBoundsTick >= 14 then
    begin
      FLastBoundsTick := nowTick;
      curMouse := Mouse.CursorPos;
      newW := Max(320, FDragStartBounds.Width + (curMouse.X - FDragStartMouse.X));
      newH := Max(88,  FDragStartBounds.Height + (curMouse.Y - FDragStartMouse.Y));
      FIsMiniMode := (newH < MINI_H_THRESH);
      SetBounds(Left, Top, newW, newH);
    end;
    Exit;
  end;

  if (X >= pbMac.ClientWidth - 16) and (Y >= pbMac.ClientHeight - 16) then
    pbMac.Cursor := crSizeNWSE
  else if X >= pbMac.ClientWidth - 6 then
    pbMac.Cursor := crSizeWE
  else if Y >= pbMac.ClientHeight - 6 then
    pbMac.Cursor := crSizeNS
  else
    pbMac.Cursor := crDefault;

  if FIsDraggingSeek then
  begin
    FSeekRatio := EnsureRange((X - FRectSeekSlider.Left) / Max(1, FRectSeekSlider.Width), 0.0, 1.0);
    if FLyricsMode and (FDurMs > 0) then
      UpdateActiveLyricLine(Trunc(FSeekRatio * FDurMs), True);
    pbMac.Invalidate;
  end
  else if FIsDraggingVol then
  begin
    ratio := EnsureRange((X - FRectVolSlider.Left) / Max(1, FRectVolSlider.Width), 0.0, 1.0);
    SendVolume(ratio);
    pbMac.Invalidate;
  end
  else if FIsDraggingScroll then
  begin
    ratio := EnsureRange((Y - FRectScrollTrack.Top) / Max(1, FRectScrollTrack.Height), 0.0, 1.0);
    ScrollToRow(Round(ratio * Max(0, FTotalTracks - VisibleTrackRows)));
  end;
end;

procedure TMainForm.pbMacMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FIsDraggingWin := False;
  FIsResizingWin := False;
  if FIsDraggingSeek then
  begin
    FIsDraggingSeek := False;
    if FDurMs > 0 then
      SendSeekMs(Trunc(SanitizeSingle(FSeekRatio, 0.0, 1.0, 0.0) * FDurMs));
  end;
  FIsDraggingVol := False;
  FIsDraggingScroll := False;
  FActivePressedBtn := 0;
  pbMac.Invalidate;
end;

procedure TMainForm.pbMacDblClick(Sender: TObject);
begin
  if FLastClickY < 24 then
    ToggleMiniPlayer;
end;

procedure TMainForm.pbMacMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  Handled := True;
  if FLyricsMode and PtInRect(FRectDetailsCard, MousePos) and (FGuiLyricCount > 0) then
  begin
    FLyricManualScrollTick := GetTickCount64;
    if WheelDelta > 0 then
      FLyricTargetScrollY := Max(0.0, FLyricTargetScrollY - 2 * LYRIC_LINE_H)
    else if WheelDelta < 0 then
      FLyricTargetScrollY := Min(Single((FGuiLyricCount - 1) * LYRIC_LINE_H), FLyricTargetScrollY + 2 * LYRIC_LINE_H);
    FLyricScrollY := FLyricTargetScrollY;
    pbMac.Invalidate;
    Exit;
  end;
  if WheelDelta > 0 then ScrollToRow(FTopRowIndex - 4)
  else if WheelDelta < 0 then ScrollToRow(FTopRowIndex + 4);
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    if FSettingsOpen then
    begin
      StopMineralQRLogin;
      FSettingsOpen := False;
      pbMac.Invalidate;
      Key := 0;
      Exit;
    end;
    if FSourceMenuOpen then
    begin
      FSourceMenuOpen := False;
      pbMac.Invalidate;
      Key := 0;
      Exit;
    end;
  end;
  if (FEdtFilter <> nil) and FEdtFilter.Focused then Exit;
  case Key of
    VK_UP:
    begin
      if FSelectedRowIndex > 0 then
        PlayRowAtIndex(FSelectedRowIndex - 1);
      Key := 0;
    end;
    VK_DOWN:
    begin
      if FSelectedRowIndex < FTotalTracks - 1 then
        PlayRowAtIndex(FSelectedRowIndex + 1);
      Key := 0;
    end;
    VK_RETURN:
    begin
      if FSelectedRowIndex >= 0 then
        PlayRowAtIndex(FSelectedRowIndex);
      Key := 0;
    end;
    VK_SPACE:
    begin
      if not FFilterActive then
      begin
        if FPlayState = OMM_STATE_PLAYING then SendCommand(OP_REQ_PAUSE)
        else if FPlayState = OMM_STATE_PAUSED then SendCommand(OP_REQ_RESUME)
        else SendCommand(OP_REQ_PLAY);
        Key := 0;
      end;
    end;
    VK_BACK:
    begin
      if (Length(FFilterText) > 0) and (FEdtFilter <> nil) then
      begin
        FEdtFilter.Text := Copy(FFilterText, 1, Length(FFilterText) - 1);
        Key := 0;
      end;
    end;
  end;
end;

procedure TMainForm.FormKeyPress(Sender: TObject; var Key: char);
begin
  if (FEdtFilter <> nil) and FEdtFilter.Focused then Exit;
  if (Key >= #33) and (Key <= #126) and (FEdtFilter <> nil) and FEdtFilter.Visible then
  begin
    if Length(FEdtFilter.Text) < 48 then
      FEdtFilter.Text := FEdtFilter.Text + Key;
  end;
end;

procedure TMainForm.tmrSpectrumTimer(Sender: TObject);
var
  seq: UInt64;
  i: Integer;
  hasResidual, isCompactMini, showCRT: Boolean;
begin
  isCompactMini := (Height < MINI_H_THRESH) or FIsMiniMode;
  showCRT := ((not isCompactMini) and (Width >= RIGHT_PANE_MINW)) or (isCompactMini and (Width >= 620));
  if not showCRT then Exit;

  if (FPShm = nil) or (FPlayState <> OMM_STATE_PLAYING) then
  begin
    hasResidual := False;
    for i := 0 to 63 do
    begin
      if (FLocalMags[i] > 0.005) or (FLocalPeaks[i] > 0.005) then
      begin
        FLocalMags[i]  := FLocalMags[i] * 0.72;
        FLocalPeaks[i] := FLocalPeaks[i] * 0.82;
        if FLocalMags[i] <= 0.005 then FLocalMags[i] := 0.0;
        if FLocalPeaks[i] <= 0.005 then FLocalPeaks[i] := 0.0;
        hasResidual := True;
      end;
    end;
    if FLyricsMode and (Abs(FLyricTargetScrollY - FLyricScrollY) > 0.3) then
    begin
      FLyricScrollY := FLyricScrollY + (FLyricTargetScrollY - FLyricScrollY) * 0.28;
      hasResidual := True;
    end;
    if hasResidual then pbMac.Invalidate;
    Exit;
  end;

  if FPShm^.SpectrumSeq = FLastSpectrumSeq then Exit;
  FLastSpectrumSeq := FPShm^.SpectrumSeq;

  repeat
    seq := SeqLockReadBegin(FPShm^.SeqLock);
    FPosMs := FPShm^.PositionMs;
    Move(FPShm^.SpectrumMags[0], FLocalMags[0], SizeOf(FLocalMags));
    Move(FPShm^.SpectrumPeaks[0], FLocalPeaks[0], SizeOf(FLocalPeaks));
    Move(FPShm^.OscilloscopeTap[0], FLocalOsc[0], SizeOf(FLocalOsc));
  until not SeqLockReadRetry(FPShm^.SeqLock, seq);

  if FLyricsMode and (FGuiLyricCount > 0) then
  begin
    UpdateActiveLyricLine(FPosMs, False);
    if Abs(FLyricTargetScrollY - FLyricScrollY) > 0.3 then
      FLyricScrollY := FLyricScrollY + (FLyricTargetScrollY - FLyricScrollY) * 0.28
    else
      FLyricScrollY := FLyricTargetScrollY;
  end;

  pbMac.Invalidate;
end;

procedure TMainForm.tmrStatusTimer(Sender: TObject);
var
  seq: UInt64;
  tTitle, tArtist, tAlbum, rawLrc: string;
  vol: Single;
  oldState, oldTrack, oldPosSec, oldPlugin, lrcGen: UInt32;
  oldLyricIdx: Integer;
  pRec: POMMTrackRecord;
  r: Integer;
  nowTick: Int64;
begin
  nowTick := GetTickCount64;
  if (FTestTimeoutSecs > 0) and (nowTick - FStartTimeTick >= Int64(FTestTimeoutSecs) * 1000) then
  begin
    Application.Terminate;
    Exit;
  end;

  if (FLibEngine <> nil) and (nowTick - FLastLibCheckTick >= 1500) then
  begin
    FLastLibCheckTick := nowTick;
    if FLibEngine.EnsureFresh then
    begin
      RebuildFilteredList;
      pbMac.Invalidate;
    end;
  end;

  if FSettingsOpen and FQrActive then
    PollMineralQRLogin;

  if FileExists('/tmp/omm_capture.cmd') then
  begin
    with TStringList.Create do
    try
      LoadFromFile('/tmp/omm_capture.cmd');
      DeleteFile('/tmp/omm_capture.cmd');
      if Count >= 4 then
      begin
        FIsMiniMode := (StrToIntDef(Strings[1], Height) < MINI_H_THRESH);
        SetBounds(Left, Top, StrToIntDef(Strings[0], Width), StrToIntDef(Strings[1], Height));
        pbMac.SetBounds(0, 0, Width, Height);
        if Count >= 5 then
          FOscilloscopeMode := (Strings[4] = '1');
        FSourceMenuOpen := (Count >= 6) and (Strings[5] = '1');
        FSettingsOpen := (Count >= 6) and ((Strings[5] = '2') or (Strings[5] = '3') or (Strings[5] = '4') or (Strings[5] = '5'));
        FLyricsMode := (Count >= 6) and (Strings[5] = '6');
        if FSettingsOpen then
        begin
          if Strings[5] = '4' then FSettingsTab := 2
          else if Strings[5] = '5' then FSettingsTab := 3
          else FSettingsTab := 0;
          ReloadMineralAuthStatus;
          if (Strings[5] = '3') or (Strings[5] = '4') then
          begin
            StartMineralQRLogin;
            for r := 1 to 35 do
            begin
              Sleep(60);
              PollMineralQRLogin;
              if FQrGridW > 0 then Break;
            end;
            StopMineralQRLogin;
          end;
        end;
        if FSourceMenuOpen then
          FSourceMenuHoverIdx := FMineralSourceIdx;
        if (Copy(Strings[2], 1, 4) = 'net:') or
           (Copy(Strings[2], 1, 8) = 'netease:') or
           (Copy(Strings[2], 1, 9) = 'bilibili:') or
           (Copy(Strings[2], 1, 3) = 'am:') or
           (Copy(Strings[2], 1, 3) = 'qq:') then
        begin
          if Copy(Strings[2], 1, 4) = 'net:' then
            TriggerMineralOnlineSearch(Copy(Strings[2], 5, 255))
          else
            TriggerMineralOnlineSearch(Strings[2]);
          for r := 1 to 60 do
          begin
            Sleep(50);
            tmrIPCTimer(Self);
            if (Length(FOnlineTracks) > 0) and (FReceivingItemsRemaining = 0) then
              Break;
          end;
        end
        else
        begin
          FMineralSourceIdx := 0;
          if FEdtFilter <> nil then
            FEdtFilter.Text := Strings[2];
          FFilterText := Strings[2];
          RebuildFilteredList;
        end;
        if FLyricsMode then
        begin
          if (FGuiLyricCount = 0) and (FCurrentTrackID > 0) then
          begin
            RequestOnlineLyricsForCurrentTrack;
            Sleep(400);
          end;
          if FPShm <> nil then
          begin
            FLastLrcGen := FPShm^.LrcGeneration;
            ParseGuiLrcText(StrPas(@FPShm^.LrcRawText[0]));
            UpdateActiveLyricLine(FPShm^.PositionMs, True);
          end;
        end;
        pbMacPaint(Self);
        with TPortableNetworkGraphic.Create do
        try
          Assign(FBackBuffer);
          SaveToFile(Strings[3]);
        finally
          Free;
        end;
      end;
    finally
      Free;
    end;
  end;

  if FPShm = nil then
  begin
    FPShm := OpenSharedMemory(FShmPath, True);
    if FPShm = nil then Exit;
  end;

  oldState    := FPlayState;
  oldTrack    := FCurrentTrackID;
  oldPosSec   := FPosMs div 500;
  oldPlugin   := FPluginState;
  oldLyricIdx := FActiveLyricIdx;

  repeat
    seq := SeqLockReadBegin(FPShm^.SeqLock);
    FPlayFlags         := FPShm^.PlaybackFlags;
    vol                := FPShm^.Volume;
    FPluginState       := FPShm^.PluginState;
    FPluginIdleSecs    := FPShm^.PluginIdleSecs;
    FPluginRssBytes    := FPShm^.PluginRssBytes;
    FSampleRate        := FPShm^.SampleRate;
    FChannels          := FPShm^.Channels;
    FBitDepth          := FPShm^.BitDepth;
    lrcGen             := FPShm^.LrcGeneration;
    FLyricCurFallback  := StrPas(@FPShm^.LyricCurrent[0]);
    FLyricNextFallback := StrPas(@FPShm^.LyricNext[0]);
    if (FLastSyncedTrackID > 0) and (FPShm^.CurrentTrackID <> FLastSyncedTrackID) and
       (GetTickCount64 - FLastRowClickTick < 3500) then
    begin
      // Keep user-selected track state while daemon is switching / buffering the new stream
      tTitle  := '';
      tArtist := '';
      tAlbum  := '';
    end
    else
    begin
      FPlayState      := FPShm^.PlaybackState;
      FCurrentTrackID := FPShm^.CurrentTrackID;
      FPosMs          := FPShm^.PositionMs;
      FDurMs          := FPShm^.DurationMs;
      tTitle          := StrPas(@FPShm^.TrackTitle[0]);
      tArtist         := StrPas(@FPShm^.TrackArtist[0]);
      tAlbum          := StrPas(@FPShm^.TrackAlbum[0]);
    end;
  until not SeqLockReadRetry(FPShm^.SeqLock, seq);

  if lrcGen <> FLastLrcGen then
  begin
    FLastLrcGen := lrcGen;
    rawLrc := '';
    repeat
      seq := SeqLockReadBegin(FPShm^.SeqLock);
      rawLrc := StrPas(@FPShm^.LrcRawText[0]);
    until not SeqLockReadRetry(FPShm^.SeqLock, seq);
    ParseGuiLrcText(rawLrc);
    UpdateActiveLyricLine(FPosMs, True);
    if FLyricsMode and (FGuiLyricCount = 0) and (FCurrentTrackID > 0) then
      RequestOnlineLyricsForCurrentTrack;
    pbMac.Invalidate;
  end
  else if FGuiLyricCount > 0 then
    UpdateActiveLyricLine(FPosMs, False);

  if not FIsDraggingVol then
    FVolume := SanitizeSingle(vol, 0.0, 1.0, 1.0);

  if (FCurrentTrackID > 0) and (FCurrentTrackID < 10000) and (FLibEngine <> nil) and FLibEngine.IsOpen then
  begin
    pRec := FLibEngine.GetRecord(FCurrentTrackID);
    if pRec <> nil then
    begin
      FTitleStr  := StrPas(@pRec^.Title[0]);
      FArtistStr := StrPas(@pRec^.Artist[0]);
      FAlbumStr  := StrPas(@pRec^.Album[0]);
    end;
  end
  else
  begin
    if tTitle <> '' then FTitleStr := tTitle;
    if tArtist <> '' then FArtistStr := tArtist;
    if tAlbum <> '' then FAlbumStr := tAlbum;
  end;

  if (FCurrentTrackID > 0) and (FCurrentTrackID <> FLastSyncedTrackID) then
  begin
    FLastSyncedTrackID := FCurrentTrackID;
    if FIsOnlineSearchMode then
    begin
      for r := 0 to Length(FOnlineTracks) - 1 do
      begin
        if FOnlineTracks[r].TrackID = FCurrentTrackID then
        begin
          FSelectedRowIndex := r;
          if (r < FTopRowIndex) or (r >= FTopRowIndex + VisibleTrackRows) then
            FTopRowIndex := Max(0, r - 6);
          Break;
        end;
      end;
    end
    else
    begin
      for r := 0 to Length(FFilteredIndices) - 1 do
      begin
        pRec := FLibEngine.GetRecordByIndex(FFilteredIndices[r]);
        if (pRec <> nil) and (pRec^.TrackID = FCurrentTrackID) then
        begin
          FSelectedRowIndex := r;
          if (r < FTopRowIndex) or (r >= FTopRowIndex + VisibleTrackRows) then
            FTopRowIndex := Max(0, r - 6);
          Break;
        end;
      end;
    end;
  end;

  if (not FIsDraggingSeek) and (FDurMs > 0) then
  begin
    FIsUpdatingSeekUI := True;
    try
      FSeekRatio := EnsureRange(FPosMs / FDurMs, 0.0, 1.0);
    finally
      FIsUpdatingSeekUI := False;
    end;
  end;

  if (oldState <> FPlayState) or (oldTrack <> FCurrentTrackID) or
     (oldPosSec <> (FPosMs div 500)) or (oldPlugin <> FPluginState) or
     (oldLyricIdx <> FActiveLyricIdx) then
    pbMac.Invalidate;
end;

procedure TMainForm.tmrIPCTimer(Sender: TObject);
var
  pkt: TOMMPacket;
  res: cint;
begin
  if FSocketFD < 0 then Exit;
  repeat
    res := RecvPacketNonBlocking(FSocketFD, pkt);
    if res = 1 then HandleIncomingPacket(pkt)
    else if res < 0 then
    begin
      DisconnectIPC;
      Break;
    end;
  until res <= 0;
end;

procedure TMainForm.HandleIncomingPacket(const Packet: TOMMPacket);
var
  idx: Integer;
begin
  case Packet.Opcode of
    OP_RESP_VIEWPORT_HEADER:
    begin
      FTotalTracks := Packet.Payload.FilteredTracks;
      FCacheStart := Packet.Payload.PageOffset;
      FCacheCount := 0;
      FReceivingItemsRemaining := Packet.Payload.ReturnedCount;
      if FReceivingItemsRemaining = 0 then pbMac.Invalidate;
    end;

    OP_RESP_VIEWPORT_ITEM:
    begin
      if FCacheCount < MAX_CACHE_ITEMS then
      begin
        Move(Packet.Payload.TrackItem, FCacheSlice[FCacheCount], SizeOf(TOMMCondensedTrack));
        Inc(FCacheCount);
      end;
      if FReceivingItemsRemaining > 0 then Dec(FReceivingItemsRemaining);
      if FReceivingItemsRemaining = 0 then pbMac.Invalidate;
    end;

    OP_RESP_MINERAL_SEARCH_HEADER:
    begin
      FIsOnlineSearchMode := True;
      FTotalTracks := Packet.Payload.ReturnedCount;
      SetLength(FOnlineTracks, 0);
      FTopRowIndex := 0;
      if FTotalTracks > 0 then FSelectedRowIndex := 0 else FSelectedRowIndex := -1;
      FReceivingItemsRemaining := Packet.Payload.ReturnedCount;
      if FReceivingItemsRemaining = 0 then pbMac.Invalidate;
    end;

    OP_RESP_MINERAL_SEARCH_ITEM:
    begin
      idx := Length(FOnlineTracks);
      SetLength(FOnlineTracks, idx + 1);
      Move(Packet.Payload.TrackItem, FOnlineTracks[idx], SizeOf(TOMMCondensedTrack));
      if FReceivingItemsRemaining > 0 then Dec(FReceivingItemsRemaining);
      if FReceivingItemsRemaining = 0 then pbMac.Invalidate;
    end;
  end;
end;

end.
