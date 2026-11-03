unit omm_codec_abi;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  ctypes;

const
  OMM_CODEC_ABI_VERSION = 1;
  OMM_CODEC_MATCH       = 1;
  OMM_CODEC_NO_MATCH    = 0;

  // Streaming chunk size per decode call (frames)
  OMM_CODEC_CHUNK_FRAMES = 4096;

  // Dual-slot active codec limit and watchdog idle unload timeout
  OMM_MAX_ACTIVE_CODEC_SLOTS       = 2;
  OMM_CODEC_UNLOAD_IDLE_TIMEOUT_S  = 30;

  // Seek whence constants
  OMM_SEEK_SET = 0;
  OMM_SEEK_CUR = 1;
  OMM_SEEK_END = 2;

  {$IFDEF LINUX}
  CODEC_EXT = '.so';
  {$ENDIF}
  {$IFDEF DARWIN}
  CODEC_EXT = '.dylib';
  {$ENDIF}
  {$IFDEF WINDOWS}
  CODEC_EXT = '.dll';
  {$ENDIF}

type
  // Underlying byte-stream callbacks (compatible with file:// and mineral:// ring buffers)
  TCodecReadCallback = function(StreamCtx: Pointer; Buffer: PByte; Count: SizeUInt; OutRead: PSizeUInt): Int32; cdecl;
  TCodecSeekCallback = function(StreamCtx: Pointer; Offset: Int64; Whence: Int32; OutPos: PInt64): Int32; cdecl;

  // 5 Standard Exported Functions for bin/codecs/libcodec_*.so
  TCodecProbeFn        = function(Header16Bytes: PByte): Int32; cdecl;
  TCodecOpenFn         = function(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
                                  SeekCallback: TCodecSeekCallback;
                                  OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
  TCodecDecodeFramesFn = function(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
  TCodecSeekFn         = function(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
  TCodecCloseFn        = procedure(Handle: Pointer); cdecl;

  // Four-tier decoding architecture classification
  TCodecTier = (
    ctKernelPassthrough = 0, // Level 0: WAV, AIFF, Raw PCM (Built into omm_audio.pas, 0 KB)
    ctMainstreamPure    = 1, // Level 1: FLAC, MP3, OGG Vorbis, Opus
    ctAudiophileRetro   = 2, // Level 2: APE, WavPack, DSD (DSF/DFF), MOD/XM/IT
    ctSystemBridge      = 3  // Level 3: AAC, M4A, ALAC, WMA, AMR
  );

  TCodecID = (
    cidNone          = 0,
    cidKernelWavAiff = 1,
    cidFlac          = 2,
    cidMp3           = 3,
    cidOgg           = 4,
    cidApe           = 5,
    cidWavPack       = 6,
    cidDsd           = 7,
    cidTracker       = 8,
    cidSysBridge     = 9
  );

  // Compile-time static magic dispatch entry (< 64 bytes per entry, < 512 bytes total table)
  TCodecDispatchEntry = packed record
    CodecID: TCodecID;
    Tier: TCodecTier;
    MagicOffset: UInt8;
    MagicLen: UInt8;
    MagicBytes: array[0..7] of Byte;
    PluginPath: PAnsiChar;
    FormatName: PAnsiChar;
  end;

const
  // Static Magic-Number Dispatch Table (< 512 bytes in rodata, 0 ms startup cost)
  CODEC_DISPATCH_TABLE: array[0..11] of TCodecDispatchEntry = (
    // Level 0: Kernel Passthrough (WAV / AIFF)
    (CodecID: cidKernelWavAiff; Tier: ctKernelPassthrough; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('R'), Ord('I'), Ord('F'), Ord('F'), 0, 0, 0, 0);
     PluginPath: ''; FormatName: 'WAV/PCM'),
    (CodecID: cidKernelWavAiff; Tier: ctKernelPassthrough; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('F'), Ord('O'), Ord('R'), Ord('M'), 0, 0, 0, 0);
     PluginPath: ''; FormatName: 'AIFF/PCM'),

    // Level 1: Mainstream Pure Pascal Plugins
    (CodecID: cidFlac; Tier: ctMainstreamPure; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('f'), Ord('L'), Ord('a'), Ord('C'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_flac' + CODEC_EXT; FormatName: 'FLAC'),
    (CodecID: cidMp3; Tier: ctMainstreamPure; MagicOffset: 0; MagicLen: 3;
     MagicBytes: (Ord('I'), Ord('D'), Ord('3'), 0, 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_mp3' + CODEC_EXT; FormatName: 'MP3'),
    (CodecID: cidOgg; Tier: ctMainstreamPure; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('O'), Ord('g'), Ord('g'), Ord('S'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_ogg' + CODEC_EXT; FormatName: 'OGG/Opus'),

    // Level 2: Audiophile Lossless & Retro Tracker Plugins
    (CodecID: cidApe; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('M'), Ord('A'), Ord('C'), Ord(' '), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_ape' + CODEC_EXT; FormatName: 'APE'),
    (CodecID: cidWavPack; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('w'), Ord('v'), Ord('p'), Ord('k'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_wv' + CODEC_EXT; FormatName: 'WavPack'),
    (CodecID: cidDsd; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('D'), Ord('S'), Ord('D'), Ord(' '), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_dsd' + CODEC_EXT; FormatName: 'DSD/DSF'),
    (CodecID: cidDsd; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('F'), Ord('R'), Ord('M'), Ord('8'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_dsd' + CODEC_EXT; FormatName: 'DSD/DFF'),
    (CodecID: cidTracker; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 4;
     MagicBytes: (Ord('I'), Ord('M'), Ord('P'), Ord('M'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_tracker' + CODEC_EXT; FormatName: 'Tracker'),
    (CodecID: cidTracker; Tier: ctAudiophileRetro; MagicOffset: 0; MagicLen: 8;
     MagicBytes: (Ord('E'), Ord('x'), Ord('t'), Ord('e'), Ord('n'), Ord('d'), Ord('e'), Ord('d'));
     PluginPath: 'bin/codecs/libcodec_tracker' + CODEC_EXT; FormatName: 'XM/MOD'),

    // Level 3: System Ecosystem Bridge (M4A / ALAC / AAC / WMA / AMR)
    (CodecID: cidSysBridge; Tier: ctSystemBridge; MagicOffset: 4; MagicLen: 4;
     MagicBytes: (Ord('f'), Ord('t'), Ord('y'), Ord('p'), 0, 0, 0, 0);
     PluginPath: 'bin/codecs/libcodec_sysbridge' + CODEC_EXT; FormatName: 'M4A/ALAC/AAC')
  );

function SniffMagic16(Header16: PByte; out OutPluginPath: PAnsiChar): TCodecID;
function GetCodecPluginPath(CodecID: TCodecID): PAnsiChar;

implementation

function GetCodecPluginPath(CodecID: TCodecID): PAnsiChar;
begin
  case CodecID of
    cidFlac:      Result := 'bin/codecs/libcodec_flac' + CODEC_EXT;
    cidMp3:       Result := 'bin/codecs/libcodec_mp3' + CODEC_EXT;
    cidOgg:       Result := 'bin/codecs/libcodec_ogg' + CODEC_EXT;
    cidApe:       Result := 'bin/codecs/libcodec_ape' + CODEC_EXT;
    cidWavPack:   Result := 'bin/codecs/libcodec_wv' + CODEC_EXT;
    cidDsd:       Result := 'bin/codecs/libcodec_dsd' + CODEC_EXT;
    cidTracker:   Result := 'bin/codecs/libcodec_tracker' + CODEC_EXT;
    cidSysBridge: Result := 'bin/codecs/libcodec_sysbridge' + CODEC_EXT;
    else          Result := '';
  end;
end;

function SniffMagic16(Header16: PByte; out OutPluginPath: PAnsiChar): TCodecID;
var
  i, k: Integer;
  matched: Boolean;
begin
  OutPluginPath := '';
  Result := cidNone;
  if Header16 = nil then Exit;

  // Special check: RIFF....WAVE vs other RIFF containers
  if (Header16[0] = Ord('R')) and (Header16[1] = Ord('I')) and
     (Header16[2] = Ord('F')) and (Header16[3] = Ord('F')) and
     (Header16[8] = Ord('W')) and (Header16[9] = Ord('A')) and
     (Header16[10] = Ord('V')) and (Header16[11] = Ord('E')) then
  begin
    Exit(cidKernelWavAiff);
  end;

  // Special check: FORM....AIFF or FORM....AIFC
  if (Header16[0] = Ord('F')) and (Header16[1] = Ord('O')) and
     (Header16[2] = Ord('R')) and (Header16[3] = Ord('M')) and
     (Header16[8] = Ord('A')) and (Header16[9] = Ord('I')) and
     (Header16[10] = Ord('F')) and ((Header16[11] = Ord('F')) or (Header16[11] = Ord('C'))) then
  begin
    Exit(cidKernelWavAiff);
  end;

  // Scan static dispatch table
  for i := 2 to High(CODEC_DISPATCH_TABLE) do
  begin
    matched := True;
    for k := 0 to CODEC_DISPATCH_TABLE[i].MagicLen - 1 do
    begin
      if Header16[CODEC_DISPATCH_TABLE[i].MagicOffset + k] <> CODEC_DISPATCH_TABLE[i].MagicBytes[k] then
      begin
        matched := False;
        Break;
      end;
    end;
    if matched then
    begin
      OutPluginPath := CODEC_DISPATCH_TABLE[i].PluginPath;
      Exit(CODEC_DISPATCH_TABLE[i].CodecID);
    end;
  end;

  // Check raw MPEG syncword (\xFF\xFB, \xFF\xFA, \xFF\xF3, \xFF\xF2, \xFF\xE3) vs ADTS AAC (\xFF\xF1, \xFF\xF9)
  if (Header16[0] = $FF) and ((Header16[1] and $E0) = $E0) then
  begin
    if (Header16[1] and $06) = 0 then
    begin
      // Layer 00 in MPEG header => ADTS AAC
      OutPluginPath := 'bin/codecs/libcodec_sysbridge' + CODEC_EXT;
      Exit(cidSysBridge);
    end
    else
    begin
      OutPluginPath := 'bin/codecs/libcodec_mp3' + CODEC_EXT;
      Exit(cidMp3);
    end;
  end;

  // Check WMA / ASF GUID (30 26 B2 75 8E 66 CF 11) or AMR (#!AMR)
  if ((Header16[0] = $30) and (Header16[1] = $26) and (Header16[2] = $B2) and (Header16[3] = $75)) or
     ((Header16[0] = Ord('#')) and (Header16[1] = Ord('!')) and (Header16[2] = Ord('A')) and (Header16[3] = Ord('M'))) then
  begin
    OutPluginPath := 'bin/codecs/libcodec_sysbridge.so';
    Exit(cidSysBridge);
  end;
end;

end.
