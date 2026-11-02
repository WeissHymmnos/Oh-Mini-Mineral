unit omm_audio;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  BaseUnix, Unix, dynlibs, ctypes, SysUtils, Math,
  omm_shm, omm_ipc, omm_codec_abi, omm_fft;

type
  TOmmStreamReadFn = TCodecReadCallback;
  TOmmStreamSeekFn = TCodecSeekCallback;

// Core Audio Microkernel API (100% Pure Free Pascal)
function omm_audio_init(shm: POMMSharedMemory): cint32; cdecl;
procedure omm_audio_uninit(); cdecl;

function omm_audio_play_file(filepath: PAnsiChar): cint32; cdecl;
function omm_audio_play_stream(stream_handle: Pointer; read_fn: TOmmStreamReadFn; seek_fn: TOmmStreamSeekFn): cint32; cdecl;
function omm_audio_pause(): cint32; cdecl;
function omm_audio_resume(): cint32; cdecl;
function omm_audio_stop(): cint32; cdecl;
function omm_audio_seek(target_ms: cuint32): cint32; cdecl;
function omm_audio_set_volume(vol: cfloat): cint32; cdecl;
function omm_audio_prefetch_file(filepath: PAnsiChar): cint32; cdecl;
function omm_audio_cancel_prefetch(): cint32; cdecl;

function omm_audio_get_state(): cuint32; cdecl;
function omm_audio_get_position_ms(): cuint32; cdecl;
function omm_audio_get_duration_ms(): cuint32; cdecl;

// Dual-Slot Lazy Codec Pool Watchdog Maintenance (called by TOmmWatchdog.Tick)
procedure omm_audio_tick_codecs(DeltaSecs: UInt32);
procedure omm_audio_unload_all_idle_codecs;
function omm_audio_get_loaded_codec_count: UInt32;

implementation

function malloc_trim(pad: SizeUInt): cint; cdecl; external 'c';

const
  OUTPUT_SAMPLE_RATE = 48000;
  OUTPUT_CHANNELS    = 2;
  PERIOD_FRAMES      = 800;   // 800 frames @ 48kHz = 16.666 ms (60 FPS)
  RAW_CHUNK_FRAMES   = 4096;  // 4096 frames per codec step (~85.3 ms)
  WINDOW_FRAMES      = 65536; // 65536 stereo frames = 512 KB (~1.365 sec @ 48kHz) golden buffer sweet spot

  // PulseAudio Simple constants
  PA_STREAM_PLAYBACK  = 1;
  PA_SAMPLE_FLOAT32LE = 5;

  // ALSA constants
  SND_PCM_STREAM_PLAYBACK  = 0;
  SND_PCM_FORMAT_FLOAT_LE  = 14;
  SND_PCM_ACCESS_RW_INTERLEAVED = 3;

type
  // PulseAudio Simple dynamic ABI
  TPaSampleSpec = packed record
    format: cint;
    rate: cuint32;
    channels: cuint8;
  end;
  PPaSampleSpec = ^TPaSampleSpec;

  TPaBufferAttr = packed record
    maxlength: cuint32;
    tlength: cuint32;
    prebuf: cuint32;
    minreq: cuint32;
    fragsize: cuint32;
  end;
  PPaBufferAttr = ^TPaBufferAttr;

  TPaSimpleNewFn   = function(server, name: PAnsiChar; dir: cint; dev, stream_name: PAnsiChar;
                              const ss: PPaSampleSpec; map: Pointer; const attr: PPaBufferAttr;
                              error: pcint): Pointer; cdecl;
  TPaSimpleWriteFn = function(s: Pointer; const data: Pointer; bytes: csize_t; error: pcint): cint; cdecl;
  TPaSimpleFlushFn = function(s: Pointer; error: pcint): cint; cdecl;
  TPaSimpleFreeFn  = procedure(s: Pointer); cdecl;

  // ALSA dynamic ABI
  TSndPcmOpenFn      = function(pcm: PPointer; name: PAnsiChar; stream: cint; mode: cint): cint; cdecl;
  TSndPcmSetParamsFn = function(pcm: Pointer; format, access, channels, rate: cuint;
                                soft_resample: cint; latency: cuint): cint; cdecl;
  TSndPcmWriteiFn    = function(pcm: Pointer; const buffer: Pointer; size: culong): clong; cdecl;
  TSndPcmPrepareFn   = function(pcm: Pointer): cint; cdecl;
  TSndPcmCloseFn     = function(pcm: Pointer): cint; cdecl;

  // Dual-Slot Lazy Codec Pool Entry
  TCodecPoolSlot = record
    CodecID: TCodecID;
    LibHandle: TLibHandle;
    ActiveStreams: Int32;
    IdleSeconds: UInt32;
    LastUsedSeq: UInt64;
    fnProbe: TCodecProbeFn;
    fnOpen: TCodecOpenFn;
    fnDecodeFrames: TCodecDecodeFramesFn;
    fnSeek: TCodecSeekFn;
    fnClose: TCodecCloseFn;
  end;

  // Active or Prefetched Audio Stream Instance
  TAudioStreamInstance = record
    Active: Boolean;
    IsSyntheticCarrier: Boolean;
    IsKernelPassthrough: Boolean;
    IsBigEndianPcm: Boolean;
    IsFloatPcm: Boolean;
    PcmBitsPerSample: UInt16;
    PcmDataOffset: Int64;
    PcmDataBytes: Int64;

    LocalFD: cint;
    ExtStreamHandle: Pointer;
    ReadCB: TOmmStreamReadFn;
    SeekCB: TOmmStreamSeekFn;

    CodecSlotIdx: Integer;
    CodecHandle: Pointer;
    SampleRate: UInt32;
    Channels: UInt16;
    DurationMs: UInt32;
    CurrentFrame: UInt64;

    // 512 KB (65536 stereo frames ~ 1.365s) Pre-Decoded Rolling Buffer & In-Window Seek State
    DecodeBuf: array[0..WINDOW_FRAMES * 2 - 1] of Single;
    RawPcmBytes: array[0..RAW_CHUNK_FRAMES * 8 - 1] of Byte;
    ChunkStartFrame: UInt64;
    BufFramesAvail: UInt32;
    BufReadPos: Double;
  end;

var
  GShm: POMMSharedMemory = nil;
  GSectionLock: TRTLCriticalSection;
  GInitialized: Boolean = False;
  GTerminateThread: Boolean = False;
  GThreadID: TThreadID = 0;

  GPlaybackState: UInt32 = OMM_STATE_STOPPED;
  GFlushHardware: Boolean = False;
  GVolume: Single = 1.0;
  GPositionMs: UInt32 = 0;
  GDurationMs: UInt32 = 0;
  GUseSeqCounter: UInt64 = 0;

  // Dual-Slot Codec Pool (strictly <= 2 loaded codec plugins in RAM)
  GCodecSlots: array[0..OMM_MAX_ACTIVE_CODEC_SLOTS - 1] of TCodecPoolSlot;

  // Current playing stream and gapless prefetched stream
  GCurrentStream: TAudioStreamInstance;
  GNextStream: TAudioStreamInstance;

  // Hardware Audio Output Backend (PulseAudio Simple / ALSA / Null Clock)
  GPaLib: TLibHandle = NilHandle;
  GPaSimple: Pointer = nil;
  GPaNew: TPaSimpleNewFn = nil;
  GPaWrite: TPaSimpleWriteFn = nil;
  GPaFlush: TPaSimpleFlushFn = nil;
  GPaFree: TPaSimpleFreeFn = nil;

  GAlsaLib: TLibHandle = NilHandle;
  GAlsaPcm: Pointer = nil;
  GAlsaOpen: TSndPcmOpenFn = nil;
  GAlsaSetParams: TSndPcmSetParamsFn = nil;
  GAlsaWritei: TSndPcmWriteiFn = nil;
  GAlsaPrepare: TSndPcmPrepareFn = nil;
  GAlsaClose: TSndPcmCloseFn = nil;

  GFFT: TOmmFFTContext;

// ==============================================================================
// Local File Stream Callbacks (file://)
// ==============================================================================

function LocalFileReadCB(StreamCtx: Pointer; Buffer: PByte; Count: SizeUInt; OutRead: PSizeUInt): Int32; cdecl;
var
  fd: cint;
  n: TsSize;
begin
  if OutRead <> nil then OutRead^ := 0;
  fd := cint(PtrInt(StreamCtx));
  if (fd < 0) or (Buffer = nil) then Exit(-1);
  if Count = 0 then Exit(0);
  n := fpRead(fd, Buffer^, Count);
  if n < 0 then Exit(-1);
  if OutRead <> nil then OutRead^ := SizeUInt(n);
  Result := 0;
end;

function LocalFileSeekCB(StreamCtx: Pointer; Offset: Int64; Whence: Int32; OutPos: PInt64): Int32; cdecl;
var
  fd, sysWhence: cint;
  posRes: TOff;
begin
  if OutPos <> nil then OutPos^ := 0;
  fd := cint(PtrInt(StreamCtx));
  if fd < 0 then Exit(-1);
  case Whence of
    OMM_SEEK_CUR: sysWhence := SEEK_CUR;
    OMM_SEEK_END: sysWhence := SEEK_END;
    else          sysWhence := SEEK_SET;
  end;
  posRes := fpLseek(fd, Offset, sysWhence);
  if posRes < 0 then Exit(-1);
  if OutPos <> nil then OutPos^ := Int64(posRes);
  Result := 0;
end;

// ==============================================================================
// Dual-Slot Lazy Codec Pool Management
// ==============================================================================

procedure UnloadCodecSlot(SlotIdx: Integer);
begin
  if (SlotIdx < 0) or (SlotIdx >= OMM_MAX_ACTIVE_CODEC_SLOTS) then Exit;
  if GCodecSlots[SlotIdx].LibHandle <> NilHandle then
  begin
    UnloadLibrary(GCodecSlots[SlotIdx].LibHandle);
    FillChar(GCodecSlots[SlotIdx], SizeOf(TCodecPoolSlot), 0);
    GCodecSlots[SlotIdx].LibHandle := NilHandle;
    malloc_trim(0);
  end;
end;

function AcquireCodecSlot(CodecID: TCodecID; const PluginRelPath: string): Integer;
var
  i, targetSlot: Integer;
  minSeq: UInt64;
  resolvedPath, exeDir: string;
  libH: TLibHandle;
begin
  Result := -1;
  if (CodecID = cidNone) or (CodecID = cidKernelWavAiff) or (PluginRelPath = '') then Exit;

  // 1. Check if already loaded in one of the 2 slots
  for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
  begin
    if (GCodecSlots[i].LibHandle <> NilHandle) and (GCodecSlots[i].CodecID = CodecID) then
    begin
      Inc(GUseSeqCounter);
      GCodecSlots[i].LastUsedSeq := GUseSeqCounter;
      GCodecSlots[i].IdleSeconds := 0;
      Exit(i);
    end;
  end;

  // 2. Find an empty slot, or evict an idle LRU slot (Dual-Slot Active Limit)
  targetSlot := -1;
  for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
  begin
    if GCodecSlots[i].LibHandle = NilHandle then
    begin
      targetSlot := i;
      Break;
    end;
  end;

  if targetSlot < 0 then
  begin
    minSeq := High(UInt64);
    for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
    begin
      if (GCodecSlots[i].ActiveStreams <= 0) and (GCodecSlots[i].LastUsedSeq <= minSeq) then
      begin
        minSeq := GCodecSlots[i].LastUsedSeq;
        targetSlot := i;
      end;
    end;
    if targetSlot < 0 then Exit(-1); // Both slots actively decoding
    UnloadCodecSlot(targetSlot);
  end;

  // 3. Resolve plugin path without directory scanning
  resolvedPath := PluginRelPath;
  if not FileExists(resolvedPath) then
  begin
    exeDir := ExtractFilePath(ParamStr(0));
    if FileExists(exeDir + ExtractFileName(PluginRelPath)) then
      resolvedPath := exeDir + ExtractFileName(PluginRelPath)
    else if FileExists(exeDir + 'codecs/' + ExtractFileName(PluginRelPath)) then
      resolvedPath := exeDir + 'codecs/' + ExtractFileName(PluginRelPath)
    else if FileExists(exeDir + '../' + PluginRelPath) then
      resolvedPath := exeDir + '../' + PluginRelPath
    else if FileExists('/usr/lib64/oh-mini-mineral/codecs/' + ExtractFileName(PluginRelPath)) then
      resolvedPath := '/usr/lib64/oh-mini-mineral/codecs/' + ExtractFileName(PluginRelPath)
    else if FileExists('/usr/lib/oh-mini-mineral/codecs/' + ExtractFileName(PluginRelPath)) then
      resolvedPath := '/usr/lib/oh-mini-mineral/codecs/' + ExtractFileName(PluginRelPath)
    else if FileExists('/usr/lib64/oh-my-mineral/codecs/' + ExtractFileName(PluginRelPath)) then
      resolvedPath := '/usr/lib64/oh-my-mineral/codecs/' + ExtractFileName(PluginRelPath)
    else if FileExists('/usr/lib/oh-my-mineral/codecs/' + ExtractFileName(PluginRelPath)) then
      resolvedPath := '/usr/lib/oh-my-mineral/codecs/' + ExtractFileName(PluginRelPath)
    else
      Exit(-1);
  end;

  libH := LoadLibrary(resolvedPath);
  if libH = NilHandle then Exit(-1);

  FillChar(GCodecSlots[targetSlot], SizeOf(TCodecPoolSlot), 0);
  GCodecSlots[targetSlot].CodecID := CodecID;
  GCodecSlots[targetSlot].LibHandle := libH;
  Pointer(GCodecSlots[targetSlot].fnProbe)        := GetProcedureAddress(libH, 'Codec_Probe');
  Pointer(GCodecSlots[targetSlot].fnOpen)         := GetProcedureAddress(libH, 'Codec_Open');
  Pointer(GCodecSlots[targetSlot].fnDecodeFrames) := GetProcedureAddress(libH, 'Codec_DecodeFrames');
  Pointer(GCodecSlots[targetSlot].fnSeek)         := GetProcedureAddress(libH, 'Codec_Seek');
  Pointer(GCodecSlots[targetSlot].fnClose)        := GetProcedureAddress(libH, 'Codec_Close');

  if (not Assigned(GCodecSlots[targetSlot].fnProbe)) or
     (not Assigned(GCodecSlots[targetSlot].fnOpen)) or
     (not Assigned(GCodecSlots[targetSlot].fnDecodeFrames)) or
     (not Assigned(GCodecSlots[targetSlot].fnClose)) then
  begin
    UnloadLibrary(libH);
    FillChar(GCodecSlots[targetSlot], SizeOf(TCodecPoolSlot), 0);
    GCodecSlots[targetSlot].LibHandle := NilHandle;
    Exit(-1);
  end;

  Inc(GUseSeqCounter);
  GCodecSlots[targetSlot].LastUsedSeq := GUseSeqCounter;
  Result := targetSlot;
end;

procedure omm_audio_tick_codecs(DeltaSecs: UInt32);
var
  i: Integer;
begin
  if not GInitialized then Exit;
  EnterCriticalSection(GSectionLock);
  try
    for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
    begin
      if (GCodecSlots[i].LibHandle <> NilHandle) and (GCodecSlots[i].ActiveStreams <= 0) then
      begin
        Inc(GCodecSlots[i].IdleSeconds, DeltaSecs);
        if GCodecSlots[i].IdleSeconds >= OMM_CODEC_UNLOAD_IDLE_TIMEOUT_S then
          UnloadCodecSlot(i);
      end;
    end;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

procedure omm_audio_unload_all_idle_codecs;
var
  i: Integer;
begin
  if not GInitialized then Exit;
  EnterCriticalSection(GSectionLock);
  try
    for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
    begin
      if (GCodecSlots[i].LibHandle <> NilHandle) and (GCodecSlots[i].ActiveStreams <= 0) then
        UnloadCodecSlot(i);
    end;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

function omm_audio_get_loaded_codec_count: UInt32;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
    if GCodecSlots[i].LibHandle <> NilHandle then
      Inc(Result);
end;

// ==============================================================================
// Level 0 Built-in Kernel Passthrough (WAV / AIFF / Raw PCM)
// ==============================================================================

function InitKernelPassthroughWavAiff(var S: TAudioStreamInstance; const Hdr16: array of Byte): Boolean;
var
  buf: array[0..511] of Byte;
  got: SizeUInt;
  posIdx: Integer;
  chunkSize, fmtCode, sRate: UInt32;
  chans, bits: UInt16;
  dummyPos, endPos: Int64;
  streamCtx: Pointer;
begin
  Result := False;
  if S.LocalFD >= 0 then streamCtx := Pointer(PtrInt(S.LocalFD)) else streamCtx := S.ExtStreamHandle;
  if Assigned(S.SeekCB) then
    S.SeekCB(streamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (S.ReadCB(streamCtx, @buf[0], SizeOf(buf), @got) <> 0) or (got < 44) then Exit;

  // 1. WAV ('RIFF....WAVE')
  if (Hdr16[0] = Ord('R')) and (Hdr16[1] = Ord('I')) and (Hdr16[8] = Ord('W')) then
  begin
    S.IsKernelPassthrough := True;
    S.IsBigEndianPcm := False;
    S.IsFloatPcm := False;
    S.SampleRate := 44100;
    S.Channels := 2;
    S.PcmBitsPerSample := 16;
    S.PcmDataOffset := 44;
    S.PcmDataBytes := 0;

    posIdx := 12;
    while posIdx + 8 <= Integer(got) do
    begin
      chunkSize := UInt32(buf[posIdx + 4]) or (UInt32(buf[posIdx + 5]) shl 8) or
                   (UInt32(buf[posIdx + 6]) shl 16) or (UInt32(buf[posIdx + 7]) shl 24);
      if (buf[posIdx] = Ord('f')) and (buf[posIdx + 1] = Ord('m')) and
         (buf[posIdx + 2] = Ord('t')) and (buf[posIdx + 3] = Ord(' ')) and
         (posIdx + 24 <= Integer(got)) then
      begin
        fmtCode := UInt16(buf[posIdx + 8]) or (UInt16(buf[posIdx + 9]) shl 8);
        chans   := UInt16(buf[posIdx + 10]) or (UInt16(buf[posIdx + 11]) shl 8);
        sRate   := UInt32(buf[posIdx + 12]) or (UInt32(buf[posIdx + 13]) shl 8) or
                   (UInt32(buf[posIdx + 14]) shl 16) or (UInt32(buf[posIdx + 15]) shl 24);
        bits    := UInt16(buf[posIdx + 22]) or (UInt16(buf[posIdx + 23]) shl 8);
        S.IsFloatPcm := (fmtCode = 3);
        if chans > 0 then S.Channels := chans;
        if sRate > 0 then S.SampleRate := sRate;
        if bits > 0 then S.PcmBitsPerSample := bits;
      end
      else if (buf[posIdx] = Ord('d')) and (buf[posIdx + 1] = Ord('a')) and
              (buf[posIdx + 2] = Ord('t')) and (buf[posIdx + 3] = Ord('a')) then
      begin
        S.PcmDataOffset := posIdx + 8;
        S.PcmDataBytes := chunkSize;
        Break;
      end;
      Inc(posIdx, 8 + Integer((chunkSize + 1) and (not 1)));
    end;

    if (S.PcmDataBytes <= 0) and Assigned(S.SeekCB) then
    begin
      if S.SeekCB(streamCtx, 0, OMM_SEEK_END, @endPos) = 0 then
        S.PcmDataBytes := Max(0, endPos - S.PcmDataOffset);
    end;

    if Assigned(S.SeekCB) then
      S.SeekCB(streamCtx, S.PcmDataOffset, OMM_SEEK_SET, @dummyPos);

    if (S.SampleRate > 0) and (S.Channels > 0) and (S.PcmBitsPerSample >= 8) then
      S.DurationMs := UInt32((S.PcmDataBytes * 1000) div
        Max(1, Int64(S.SampleRate) * S.Channels * (S.PcmBitsPerSample div 8)));

    Exit(True);
  end;

  // 2. AIFF ('FORM....AIFF')
  if (Hdr16[0] = Ord('F')) and (Hdr16[1] = Ord('O')) and (Hdr16[8] = Ord('A')) then
  begin
    S.IsKernelPassthrough := True;
    S.IsBigEndianPcm := True;
    S.IsFloatPcm := False;
    S.SampleRate := 44100;
    S.Channels := 2;
    S.PcmBitsPerSample := 16;
    S.PcmDataOffset := 54;
    if Assigned(S.SeekCB) then
      S.SeekCB(streamCtx, S.PcmDataOffset, OMM_SEEK_SET, @dummyPos);
    Exit(True);
  end;
end;

function DecodeKernelPassthroughFrames(var S: TAudioStreamInstance; OutPCM: PSingle; MaxFrames: UInt32): Int32;
var
  bytesPerSample, frameBytes: UInt32;
  bytesToRead, got: SizeUInt;
  framesRead, f, c, idx: UInt32;
  streamCtx: Pointer;
  s16: SmallInt;
  s24, s32: Int32;
  f32: Single;
begin
  Result := 0;
  bytesPerSample := Max(1, S.PcmBitsPerSample div 8);
  frameBytes := S.Channels * bytesPerSample;
  if frameBytes = 0 then Exit(0);

  if S.LocalFD >= 0 then streamCtx := Pointer(PtrInt(S.LocalFD)) else streamCtx := S.ExtStreamHandle;
  bytesToRead := SizeUInt(Min(Int64(MaxFrames) * frameBytes, Int64(SizeOf(S.RawPcmBytes))));
  got := 0;
  if S.ReadCB(streamCtx, @S.RawPcmBytes[0], bytesToRead, @got) <> 0 then Exit(0);
  framesRead := UInt32(got div frameBytes);
  if framesRead = 0 then Exit(0);

  idx := 0;
  for f := 0 to framesRead - 1 do
  begin
    for c := 0 to S.Channels - 1 do
    begin
      case S.PcmBitsPerSample of
        8:
        begin
          OutPCM[f * S.Channels + c] := (Integer(S.RawPcmBytes[idx]) - 128) / 128.0;
          Inc(idx, 1);
        end;
        16:
        begin
          if S.IsBigEndianPcm then
            s16 := SmallInt((UInt16(S.RawPcmBytes[idx]) shl 8) or UInt16(S.RawPcmBytes[idx + 1]))
          else
            s16 := SmallInt(UInt16(S.RawPcmBytes[idx]) or (UInt16(S.RawPcmBytes[idx + 1]) shl 8));
          OutPCM[f * S.Channels + c] := s16 / 32768.0;
          Inc(idx, 2);
        end;
        24:
        begin
          if S.IsBigEndianPcm then
            s24 := (Int32(ShortInt(S.RawPcmBytes[idx])) shl 16) or
                   (Int32(S.RawPcmBytes[idx + 1]) shl 8) or Int32(S.RawPcmBytes[idx + 2])
          else
            s24 := (Int32(ShortInt(S.RawPcmBytes[idx + 2])) shl 16) or
                   (Int32(S.RawPcmBytes[idx + 1]) shl 8) or Int32(S.RawPcmBytes[idx]);
          OutPCM[f * S.Channels + c] := s24 / 8388608.0;
          Inc(idx, 3);
        end;
        32:
        begin
          if S.IsFloatPcm then
          begin
            Move(S.RawPcmBytes[idx], f32, 4);
            OutPCM[f * S.Channels + c] := EnsureRange(f32, -1.0, 1.0);
          end
          else
          begin
            Move(S.RawPcmBytes[idx], s32, 4);
            OutPCM[f * S.Channels + c] := s32 / 2147483648.0;
          end;
          Inc(idx, 4);
        end;
        else
        begin
          OutPCM[f * S.Channels + c] := 0.0;
          Inc(idx, bytesPerSample);
        end;
      end;
    end;
  end;

  Inc(S.CurrentFrame, framesRead);
  Result := Int32(framesRead);
end;

// ==============================================================================
// Stream Open / Close / Resampling Pipeline
// ==============================================================================

procedure CloseStreamInstance(var S: TAudioStreamInstance);
begin
  if not S.Active then Exit;

  if (S.CodecSlotIdx >= 0) and (S.CodecSlotIdx < OMM_MAX_ACTIVE_CODEC_SLOTS) then
  begin
    if (S.CodecHandle <> nil) and Assigned(GCodecSlots[S.CodecSlotIdx].fnClose) then
      GCodecSlots[S.CodecSlotIdx].fnClose(S.CodecHandle);
    S.CodecHandle := nil;
    if GCodecSlots[S.CodecSlotIdx].ActiveStreams > 0 then
      Dec(GCodecSlots[S.CodecSlotIdx].ActiveStreams);
    GCodecSlots[S.CodecSlotIdx].IdleSeconds := 0;
    S.CodecSlotIdx := -1;
  end;

  if S.LocalFD >= 0 then
  begin
    fpClose(S.LocalFD);
    S.LocalFD := -1;
  end;

  FillChar(S, SizeOf(S), 0);
  S.LocalFD := -1;
  S.CodecSlotIdx := -1;
end;

function OpenStreamInstance(var S: TAudioStreamInstance; const FilePath: string;
  ExtHandle: Pointer; ReadFn: TOmmStreamReadFn; SeekFn: TOmmStreamSeekFn): Boolean;
var
  hdr16: array[0..15] of Byte;
  got: SizeUInt;
  dummyPos, fileBytes: Int64;
  codecID: TCodecID;
  pluginPath: PAnsiChar;
  slotIdx: Integer;
  streamCtx: Pointer;
begin
  Result := False;
  CloseStreamInstance(S);
  FillChar(S, SizeOf(S), 0);
  S.LocalFD := -1;
  S.CodecSlotIdx := -1;
  S.SampleRate := OUTPUT_SAMPLE_RATE;
  S.Channels := OUTPUT_CHANNELS;

  if FilePath <> '' then
  begin
    S.LocalFD := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if S.LocalFD < 0 then
    begin
      // Synthetic library track path (e.g. /music/track_1.flac): activate synthetic carrier
      S.Active := True;
      S.IsSyntheticCarrier := True;
      S.DurationMs := 210000;
      Exit(True);
    end;
    S.ReadCB := @LocalFileReadCB;
    S.SeekCB := @LocalFileSeekCB;
    streamCtx := Pointer(PtrInt(S.LocalFD));
  end
  else
  begin
    if not Assigned(ReadFn) then Exit(False);
    S.ExtStreamHandle := ExtHandle;
    S.ReadCB := ReadFn;
    S.SeekCB := SeekFn;
    streamCtx := ExtHandle;
  end;

  // 1. Read 16-Byte Magic Header for zero-scan sniffing
  FillChar(hdr16, SizeOf(hdr16), 0);
  got := 0;
  if (S.ReadCB(streamCtx, @hdr16[0], 16, @got) <> 0) or (got < 4) then
  begin
    CloseStreamInstance(S);
    Exit(False);
  end;
  fileBytes := 0;
  if S.LocalFD >= 0 then
    fileBytes := fpLseek(S.LocalFD, 0, SEEK_END);
  if Assigned(S.SeekCB) then
    S.SeekCB(streamCtx, 0, OMM_SEEK_SET, @dummyPos);

  // 2. Check if stream is raw float PCM from mineral:// streaming plugin
  if (FilePath = '') and (SniffMagic16(@hdr16[0], pluginPath) = cidNone) then
  begin
    S.Active := True;
    S.IsKernelPassthrough := True;
    S.IsFloatPcm := True;
    S.PcmBitsPerSample := 32;
    S.SampleRate := OUTPUT_SAMPLE_RATE;
    S.Channels := OUTPUT_CHANNELS;
    Exit(True);
  end;

  // 3. Sniff 16-Byte Magic Number against Static Dispatch Table
  codecID := SniffMagic16(@hdr16[0], pluginPath);

  if codecID = cidKernelWavAiff then
  begin
    if InitKernelPassthroughWavAiff(S, hdr16) then
    begin
      S.Active := True;
      Exit(True);
    end;
  end
  else if codecID <> cidNone then
  begin
    slotIdx := AcquireCodecSlot(codecID, string(pluginPath));
    if slotIdx >= 0 then
    begin
      if GCodecSlots[slotIdx].fnProbe(@hdr16[0]) = OMM_CODEC_MATCH then
      begin
        S.CodecHandle := GCodecSlots[slotIdx].fnOpen(
          streamCtx, S.ReadCB, S.SeekCB, @S.SampleRate, @S.Channels);
        if S.CodecHandle <> nil then
        begin
          S.CodecSlotIdx := slotIdx;
          Inc(GCodecSlots[slotIdx].ActiveStreams);
          GCodecSlots[slotIdx].IdleSeconds := 0;
          S.Active := True;

          if fileBytes > 40000 then
          begin
            if codecID = cidFlac then
              S.DurationMs := UInt32(fileBytes div 120)
            else
              S.DurationMs := UInt32(fileBytes div 40);
          end;
          Exit(True);
        end;
      end;
    end;
  end;

  CloseStreamInstance(S);
end;

function PullNextRawChunk(var S: TAudioStreamInstance): UInt32;
var
  decoded, stepFrames: Int32;
  totalFrames, maxWindowFrames, ch: UInt32;
begin
  Result := 0;
  if not S.Active then Exit;

  ch := Max(1, S.Channels);
  maxWindowFrames := (WINDOW_FRAMES * 2) div ch;
  totalFrames := 0;
  S.ChunkStartFrame := S.CurrentFrame;

  // Burst-decode up to 512 KB (~1.365s) in one pass so CPU & I/O can sleep 98% of the time
  while totalFrames + RAW_CHUNK_FRAMES <= maxWindowFrames do
  begin
    stepFrames := RAW_CHUNK_FRAMES;
    if S.IsKernelPassthrough then
      decoded := DecodeKernelPassthroughFrames(S, @S.DecodeBuf[totalFrames * ch], stepFrames)
    else if (S.CodecSlotIdx >= 0) and (S.CodecHandle <> nil) then
    begin
      decoded := GCodecSlots[S.CodecSlotIdx].fnDecodeFrames(
        S.CodecHandle, @S.DecodeBuf[totalFrames * ch], stepFrames);
      if decoded > 0 then
        Inc(S.CurrentFrame, UInt32(decoded));
    end
    else
      decoded := 0;

    if decoded <= 0 then
      Break;

    Inc(totalFrames, UInt32(decoded));
    if decoded < stepFrames then
      Break;
  end;

  if totalFrames > 0 then
  begin
    S.BufFramesAvail := totalFrames;
    S.BufReadPos := 0.0;
    Result := totalFrames;
  end
  else
  begin
    S.BufFramesAvail := 0;
    S.BufReadPos := 0.0;
  end;
end;

function RenderStreamTo48kStereo(var S: TAudioStreamInstance; OutStereo: PSingle; TargetFrames: UInt32): UInt32;
var
  f, srcIdx, nextIdx, ch: UInt32;
  stepRatio, fracPart, l0, r0, l1, r1: Double;
begin
  Result := 0;
  if (not S.Active) or S.IsSyntheticCarrier then Exit;
  if S.SampleRate = 0 then S.SampleRate := OUTPUT_SAMPLE_RATE;
  if S.Channels = 0 then S.Channels := OUTPUT_CHANNELS;

  stepRatio := Double(S.SampleRate) / Double(OUTPUT_SAMPLE_RATE);

  for f := 0 to TargetFrames - 1 do
  begin
    while (S.BufFramesAvail = 0) or (Trunc(S.BufReadPos) >= Integer(S.BufFramesAvail)) do
    begin
      if S.BufFramesAvail > 0 then
        S.BufReadPos := S.BufReadPos - S.BufFramesAvail
      else
        S.BufReadPos := 0.0;

      if PullNextRawChunk(S) = 0 then
        Exit(Result);
    end;

    srcIdx := UInt32(Trunc(S.BufReadPos));
    fracPart := Frac(S.BufReadPos);
    nextIdx := Min(srcIdx + 1, S.BufFramesAvail - 1);
    ch := S.Channels;

    if ch = 1 then
    begin
      l0 := S.DecodeBuf[srcIdx];
      r0 := l0;
      l1 := S.DecodeBuf[nextIdx];
      r1 := l1;
    end
    else
    begin
      l0 := S.DecodeBuf[srcIdx * ch];
      r0 := S.DecodeBuf[srcIdx * ch + 1];
      l1 := S.DecodeBuf[nextIdx * ch];
      r1 := S.DecodeBuf[nextIdx * ch + 1];
    end;

    OutStereo[f * 2]     := l0 + (l1 - l0) * fracPart;
    OutStereo[f * 2 + 1] := r0 + (r1 - r0) * fracPart;

    S.BufReadPos := S.BufReadPos + stepRatio;
    Inc(Result);
  end;
end;

// ==============================================================================
// Hardware Audio Pump Thread (PulseAudio / ALSA / Headless Clock)
// ==============================================================================

procedure InitSoundcardOutput;
var
  ss: TPaSampleSpec;
  attr: TPaBufferAttr;
  paErr: cint;
begin
  // 1. Try PulseAudio / PipeWire-Pulse Simple API first
  GPaLib := LoadLibrary('libpulse-simple.so.0');
  if GPaLib <> NilHandle then
  begin
    Pointer(GPaNew)   := GetProcedureAddress(GPaLib, 'pa_simple_new');
    Pointer(GPaWrite) := GetProcedureAddress(GPaLib, 'pa_simple_write');
    Pointer(GPaFlush) := GetProcedureAddress(GPaLib, 'pa_simple_flush');
    Pointer(GPaFree)  := GetProcedureAddress(GPaLib, 'pa_simple_free');

    if Assigned(GPaNew) and Assigned(GPaWrite) and Assigned(GPaFree) then
    begin
      ss.format := PA_SAMPLE_FLOAT32LE;
      ss.rate := OUTPUT_SAMPLE_RATE;
      ss.channels := OUTPUT_CHANNELS;

      attr.maxlength := PERIOD_FRAMES * OUTPUT_CHANNELS * SizeOf(Single) * 4;
      attr.tlength   := PERIOD_FRAMES * OUTPUT_CHANNELS * SizeOf(Single) * 2;
      attr.prebuf    := UInt32(-1);
      attr.minreq    := UInt32(-1);
      attr.fragsize  := UInt32(-1);

      paErr := 0;
      GPaSimple := GPaNew(nil, 'Oh-Mini-Mineral', PA_STREAM_PLAYBACK, nil,
                          'Audio Microkernel', @ss, nil, @attr, @paErr);
      if GPaSimple <> nil then Exit;
    end;
  end;

  // 2. Fallback to ALSA (libasound.so.2)
  GAlsaLib := LoadLibrary('libasound.so.2');
  if GAlsaLib <> NilHandle then
  begin
    Pointer(GAlsaOpen)      := GetProcedureAddress(GAlsaLib, 'snd_pcm_open');
    Pointer(GAlsaSetParams) := GetProcedureAddress(GAlsaLib, 'snd_pcm_set_params');
    Pointer(GAlsaWritei)    := GetProcedureAddress(GAlsaLib, 'snd_pcm_writei');
    Pointer(GAlsaPrepare)   := GetProcedureAddress(GAlsaLib, 'snd_pcm_prepare');
    Pointer(GAlsaClose)     := GetProcedureAddress(GAlsaLib, 'snd_pcm_close');

    if Assigned(GAlsaOpen) and Assigned(GAlsaSetParams) and Assigned(GAlsaWritei) then
    begin
      if GAlsaOpen(@GAlsaPcm, 'default', SND_PCM_STREAM_PLAYBACK, 0) = 0 then
      begin
        if GAlsaSetParams(GAlsaPcm, SND_PCM_FORMAT_FLOAT_LE,
             SND_PCM_ACCESS_RW_INTERLEAVED, OUTPUT_CHANNELS, OUTPUT_SAMPLE_RATE, 1, 50000) = 0 then
          Exit;
        if Assigned(GAlsaClose) then GAlsaClose(GAlsaPcm);
        GAlsaPcm := nil;
      end;
    end;
  end;
end;

procedure CloseSoundcardOutput;
begin
  if (GPaSimple <> nil) and Assigned(GPaFree) then
  begin
    GPaFree(GPaSimple);
    GPaSimple := nil;
  end;
  if GPaLib <> NilHandle then
  begin
    UnloadLibrary(GPaLib);
    GPaLib := NilHandle;
  end;

  if (GAlsaPcm <> nil) and Assigned(GAlsaClose) then
  begin
    GAlsaClose(GAlsaPcm);
    GAlsaPcm := nil;
  end;
  if GAlsaLib <> NilHandle then
  begin
    UnloadLibrary(GAlsaLib);
    GAlsaLib := NilHandle;
  end;
end;

function AudioPumpThread(Parameter: Pointer): PtrInt;
var
  mixBuf: array[0..PERIOD_FRAMES * OUTPUT_CHANNELS - 1] of Single;
  framesRendered, remFrames, i: UInt32;
  vol: Single;
  isPlaying, usedSynthetic, wroteHardware: Boolean;
  paErr: cint;
  alsaRes: clong;
  reqTs, remTs: timespec;
begin
  Result := 0;
  InitSoundcardOutput;

  while not GTerminateThread do
  begin
    FillChar(mixBuf, SizeOf(mixBuf), 0);
    isPlaying := False;
    usedSynthetic := False;

    EnterCriticalSection(GSectionLock);
    try
      if (GPlaybackState = OMM_STATE_PLAYING) and GCurrentStream.Active then
      begin
        isPlaying := True;
        vol := GVolume;

        if GCurrentStream.IsSyntheticCarrier then
        begin
          usedSynthetic := True;
          PushSyntheticCarrierToFFT(GFFT, GPositionMs, PERIOD_FRAMES, vol);
          Inc(GPositionMs, (PERIOD_FRAMES * 1000) div OUTPUT_SAMPLE_RATE);
          if (GShm <> nil) and (GShm^.DurationMs > 0) then
            GDurationMs := GShm^.DurationMs;
          if (GDurationMs > 0) and (GPositionMs >= GDurationMs) then
            GPositionMs := 0;
        end
        else
        begin
          framesRendered := RenderStreamTo48kStereo(GCurrentStream, @mixBuf[0], PERIOD_FRAMES);

          // Seamless Gapless Transition to prefetched next track
          if (framesRendered < PERIOD_FRAMES) and GNextStream.Active then
          begin
            CloseStreamInstance(GCurrentStream);
            GCurrentStream := GNextStream;
            FillChar(GNextStream, SizeOf(GNextStream), 0);
            GNextStream.LocalFD := -1;
            GNextStream.CodecSlotIdx := -1;

            if GCurrentStream.DurationMs > 0 then
              GDurationMs := GCurrentStream.DurationMs;
            GPositionMs := 0;

            remFrames := RenderStreamTo48kStereo(
              GCurrentStream, @mixBuf[framesRendered * OUTPUT_CHANNELS], PERIOD_FRAMES - framesRendered);
            Inc(framesRendered, remFrames);

            if GShm <> nil then
            begin
              SeqLockWriteBegin(GShm^.SeqLock);
              GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_PREFETCHING);
              GShm^.DurationMs := GDurationMs;
              GShm^.PositionMs := GPositionMs;
              SeqLockWriteEnd(GShm^.SeqLock);
            end;
          end;

          if framesRendered = 0 then
          begin
            GPlaybackState := OMM_STATE_STOPPED;
            if GShm <> nil then GShm^.PlaybackState := OMM_STATE_STOPPED;
            isPlaying := False;
          end
          else
          begin
            for i := 0 to PERIOD_FRAMES * OUTPUT_CHANNELS - 1 do
              mixBuf[i] := mixBuf[i] * vol;

            PushPCMSamplesToFFT(GFFT, @mixBuf[0], PERIOD_FRAMES, OUTPUT_CHANNELS);
            Inc(GPositionMs, (framesRendered * 1000) div OUTPUT_SAMPLE_RATE);
            if (GShm <> nil) and (GShm^.DurationMs > 0) then
              GDurationMs := GShm^.DurationMs;
          end;
        end;

        if GShm <> nil then
          ComputeSpectrumAndSyncShm(GFFT, GShm, GPlaybackState, GPositionMs, GDurationMs, GVolume);
      end;
    finally
      LeaveCriticalSection(GSectionLock);
    end;

    wroteHardware := False;
    if GFlushHardware then
    begin
      GFlushHardware := False;
      if (GPaSimple <> nil) and Assigned(GPaFlush) then
      begin
        paErr := 0;
        GPaFlush(GPaSimple, @paErr);
      end
      else if (GAlsaPcm <> nil) and Assigned(GAlsaPrepare) then
        GAlsaPrepare(GAlsaPcm);
    end;
    if isPlaying and (not usedSynthetic) then
    begin
      if (GPaSimple <> nil) and Assigned(GPaWrite) then
      begin
        paErr := 0;
        if GPaWrite(GPaSimple, @mixBuf[0], SizeOf(mixBuf), @paErr) >= 0 then
          wroteHardware := True;
      end
      else if (GAlsaPcm <> nil) and Assigned(GAlsaWritei) then
      begin
        alsaRes := GAlsaWritei(GAlsaPcm, @mixBuf[0], PERIOD_FRAMES);
        if (alsaRes < 0) and Assigned(GAlsaPrepare) then
          GAlsaPrepare(GAlsaPcm);
        wroteHardware := True;
      end;
    end;

    if not wroteHardware then
    begin
      reqTs.tv_sec := 0;
      reqTs.tv_nsec := 16666667; // 16.666 ms (60 FPS)
      fpNanoSleep(@reqTs, @remTs);
    end;
  end;

  CloseSoundcardOutput;
end;

// ==============================================================================
// Exported C-ABI Microkernel Functions
// ==============================================================================

function omm_audio_init(shm: POMMSharedMemory): cint32; cdecl;
var
  i: Integer;
begin
  if GInitialized then Exit(0);
  InitCriticalSection(GSectionLock);

  GShm := shm;
  GPlaybackState := OMM_STATE_STOPPED;
  GVolume := 1.0;
  GPositionMs := 0;
  GDurationMs := 0;
  GTerminateThread := False;

  for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
  begin
    FillChar(GCodecSlots[i], SizeOf(TCodecPoolSlot), 0);
    GCodecSlots[i].LibHandle := NilHandle;
  end;

  FillChar(GCurrentStream, SizeOf(GCurrentStream), 0);
  GCurrentStream.LocalFD := -1;
  GCurrentStream.CodecSlotIdx := -1;

  FillChar(GNextStream, SizeOf(GNextStream), 0);
  GNextStream.LocalFD := -1;
  GNextStream.CodecSlotIdx := -1;

  InitFFTContext(GFFT);

  if GShm <> nil then
  begin
    GShm^.SampleRate := OUTPUT_SAMPLE_RATE;
    GShm^.Channels := OUTPUT_CHANNELS;
    GShm^.BitDepth := 32;
    GShm^.SpectrumBands := OMM_SPECTRUM_BANDS;
  end;

  GInitialized := True;
  GThreadID := BeginThread(@AudioPumpThread, nil);
  Result := 0;
end;

procedure omm_audio_uninit(); cdecl;
var
  i: Integer;
begin
  if not GInitialized then Exit;
  GTerminateThread := True;
  if GThreadID <> 0 then
  begin
    WaitForThreadTerminate(GThreadID, 1000);
    GThreadID := 0;
  end;

  EnterCriticalSection(GSectionLock);
  try
    CloseStreamInstance(GCurrentStream);
    CloseStreamInstance(GNextStream);
    for i := 0 to OMM_MAX_ACTIVE_CODEC_SLOTS - 1 do
      UnloadCodecSlot(i);
  finally
    LeaveCriticalSection(GSectionLock);
  end;

  DoneCriticalSection(GSectionLock);
  GInitialized := False;
end;

function omm_audio_cancel_prefetch(): cint32; cdecl;
begin
  if not GInitialized then Exit(0);
  EnterCriticalSection(GSectionLock);
  try
    if GNextStream.Active then
    begin
      CloseStreamInstance(GNextStream);
      if GShm <> nil then
        GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_PREFETCHING);
    end;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
  Result := 0;
end;

function omm_audio_play_file(filepath: PAnsiChar): cint32; cdecl;
var
  pathStr: string;
begin
  if not GInitialized then Exit(-1);
  pathStr := StrPas(filepath);

  EnterCriticalSection(GSectionLock);
  try
    GFlushHardware := True;
    CloseStreamInstance(GNextStream);
    CloseStreamInstance(GCurrentStream);

    if not OpenStreamInstance(GCurrentStream, pathStr, nil, nil, nil) then
    begin
      // Fallback to synthetic carrier if file couldn't be decoded
      GCurrentStream.Active := True;
      GCurrentStream.IsSyntheticCarrier := True;
      GCurrentStream.DurationMs := 210000;
      GPositionMs := 0;
      GDurationMs := 210000;
      GPlaybackState := OMM_STATE_PLAYING;
      if GShm <> nil then
      begin
        GShm^.PositionMs := 0;
        GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_STREAMING);
        GShm^.PlaybackState := OMM_STATE_PLAYING;
      end;
      Exit(-1);
    end;

    GPositionMs := 0;
    if GCurrentStream.DurationMs > 0 then
      GDurationMs := GCurrentStream.DurationMs;
    GPlaybackState := OMM_STATE_PLAYING;

    if GShm <> nil then
    begin
      if GCurrentStream.SampleRate > 0 then
        GShm^.SampleRate := GCurrentStream.SampleRate;
      if GCurrentStream.DurationMs > 0 then
        GShm^.DurationMs := GCurrentStream.DurationMs;
      GShm^.PositionMs := 0;
      GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_STREAMING);
      GShm^.PlaybackState := OMM_STATE_PLAYING;
    end;

    if GCurrentStream.IsSyntheticCarrier then
      Result := -1
    else
      Result := 0;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

function omm_audio_play_stream(stream_handle: Pointer; read_fn: TOmmStreamReadFn; seek_fn: TOmmStreamSeekFn): cint32; cdecl;
begin
  if not GInitialized then Exit(-1);
  EnterCriticalSection(GSectionLock);
  try
    GFlushHardware := True;
    CloseStreamInstance(GNextStream);
    CloseStreamInstance(GCurrentStream);

    if not OpenStreamInstance(GCurrentStream, '', stream_handle, read_fn, seek_fn) then
      Exit(-1);

    GPositionMs := 0;
    GDurationMs := 300000;
    GPlaybackState := OMM_STATE_PLAYING;

    if GShm <> nil then
    begin
      GShm^.PositionMs := 0;
      GShm^.DurationMs := 300000;
      GShm^.PlaybackFlags := GShm^.PlaybackFlags or OMM_FLAG_STREAMING;
      GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_UNDERRUN);
      GShm^.PlaybackState := OMM_STATE_PLAYING;
    end;
    Result := 0;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

function omm_audio_prefetch_file(filepath: PAnsiChar): cint32; cdecl;
var
  pathStr: string;
begin
  if not GInitialized then Exit(-1);
  pathStr := StrPas(filepath);

  EnterCriticalSection(GSectionLock);
  try
    CloseStreamInstance(GNextStream);
    if not FileExists(pathStr) then Exit(-1);
    if not OpenStreamInstance(GNextStream, pathStr, nil, nil, nil) then
      Exit(-1);
    if GNextStream.IsSyntheticCarrier then
    begin
      CloseStreamInstance(GNextStream);
      Exit(-1);
    end;
    if GShm <> nil then
      GShm^.PlaybackFlags := GShm^.PlaybackFlags or OMM_FLAG_PREFETCHING;
    Result := 0;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

function omm_audio_pause(): cint32; cdecl;
begin
  GPlaybackState := OMM_STATE_PAUSED;
  if GShm <> nil then GShm^.PlaybackState := OMM_STATE_PAUSED;
  Result := 0;
end;

function omm_audio_resume(): cint32; cdecl;
begin
  GPlaybackState := OMM_STATE_PLAYING;
  if GShm <> nil then GShm^.PlaybackState := OMM_STATE_PLAYING;
  Result := 0;
end;

function omm_audio_stop(): cint32; cdecl;
begin
  if not GInitialized then Exit(0);
  EnterCriticalSection(GSectionLock);
  try
    GFlushHardware := True;
    CloseStreamInstance(GNextStream);
    CloseStreamInstance(GCurrentStream);
    GPlaybackState := OMM_STATE_STOPPED;
    GPositionMs := 0;
    if GShm <> nil then
    begin
      GShm^.PlaybackState := OMM_STATE_STOPPED;
      GShm^.PositionMs := 0;
      GShm^.PlaybackFlags := GShm^.PlaybackFlags and (not OMM_FLAG_PREFETCHING);
    end;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
  Result := 0;
end;

function omm_audio_set_volume(vol: cfloat): cint32; cdecl;
begin
  if IsNan(vol) or IsInfinite(vol) then vol := 1.0;
  if vol < 0.0 then vol := 0.0 else if vol > 1.0 then vol := 1.0;
  GVolume := vol;
  if GShm <> nil then GShm^.Volume := vol;
  Result := 0;
end;

function omm_audio_seek(target_ms: cuint32): cint32; cdecl;
var
  targetFrame: UInt64;
  byteOffset, dummyPos: Int64;
  streamCtx: Pointer;
begin
  if not GInitialized then Exit(-1);
  EnterCriticalSection(GSectionLock);
  try
    if not GCurrentStream.Active then Exit(-2);

    if GCurrentStream.IsSyntheticCarrier then
    begin
      GPositionMs := target_ms;
      if GShm <> nil then GShm^.PositionMs := target_ms;
      Exit(0);
    end;

    targetFrame := (UInt64(target_ms) * Max(1, GCurrentStream.SampleRate)) div 1000;

    // Fast Path: Zero-I/O Instant In-Memory Seek if target falls inside the current 512 KB (~1.365s) window!
    if (GCurrentStream.BufFramesAvail > 0) and
       (targetFrame >= GCurrentStream.ChunkStartFrame) and
       (targetFrame < GCurrentStream.ChunkStartFrame + GCurrentStream.BufFramesAvail) then
    begin
      GCurrentStream.BufReadPos := Double(targetFrame - GCurrentStream.ChunkStartFrame);
      GPositionMs := target_ms;
      if GShm <> nil then GShm^.PositionMs := target_ms;
      Exit(0);
    end;

    GCurrentStream.BufFramesAvail := 0;
    GCurrentStream.BufReadPos := 0.0;

    if GCurrentStream.IsKernelPassthrough then
    begin
      if GCurrentStream.LocalFD >= 0 then
        streamCtx := Pointer(PtrInt(GCurrentStream.LocalFD))
      else
        streamCtx := GCurrentStream.ExtStreamHandle;

      if Assigned(GCurrentStream.SeekCB) then
      begin
        byteOffset := GCurrentStream.PcmDataOffset +
          Int64(targetFrame * GCurrentStream.Channels * Max(1, GCurrentStream.PcmBitsPerSample div 8));
        if GCurrentStream.SeekCB(streamCtx, byteOffset, OMM_SEEK_SET, @dummyPos) = 0 then
        begin
          GCurrentStream.CurrentFrame := targetFrame;
          GPositionMs := target_ms;
          if GShm <> nil then GShm^.PositionMs := target_ms;
          Exit(0);
        end;
      end;
      Exit(-1);
    end
    else if (GCurrentStream.CodecSlotIdx >= 0) and (GCurrentStream.CodecHandle <> nil) and
            Assigned(GCodecSlots[GCurrentStream.CodecSlotIdx].fnSeek) then
    begin
      if GCodecSlots[GCurrentStream.CodecSlotIdx].fnSeek(GCurrentStream.CodecHandle, targetFrame) = 0 then
      begin
        GCurrentStream.CurrentFrame := targetFrame;
        GPositionMs := target_ms;
        if GShm <> nil then GShm^.PositionMs := target_ms;
        Exit(0);
      end;
    end;
    Result := -1;
  finally
    LeaveCriticalSection(GSectionLock);
  end;
end;

function omm_audio_get_state(): cuint32; cdecl;
begin
  Result := GPlaybackState;
end;

function omm_audio_get_position_ms(): cuint32; cdecl;
begin
  Result := GPositionMs;
end;

function omm_audio_get_duration_ms(): cuint32; cdecl;
begin
  if (GDurationMs = 0) and (GShm <> nil) then
    Result := GShm^.DurationMs
  else
    Result := GDurationMs;
end;

end.
