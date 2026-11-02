unit omm_shm;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  BaseUnix, Unix, ctypes;

const
  OMM_SHM_NAME       = '/omm_shm';
  OMM_SHM_SIZE       = 65536; // 64 KB exact
  OMM_SHM_MAGIC      = $4F4D4D53; // 'OMMS' in ASCII little-endian
  OMM_SHM_VERSION    = 1;
  OMM_TRACK_MAGIC    = $4F4D4D4C; // 'OMML' in ASCII little-endian
  OMM_TRACK_SIZE     = 512;
  OMM_SPECTRUM_BANDS = 64;
  OMM_PLUGIN_PROTOCOL_VERSION = $00010000;

  // Playback States
  OMM_STATE_STOPPED   = 0;
  OMM_STATE_PLAYING   = 1;
  OMM_STATE_PAUSED    = 2;
  OMM_STATE_BUFFERING = 3;
  OMM_STATE_ERROR     = 4;

  // Playback Flags (Bitmask)
  OMM_FLAG_MUTED       = $0001;
  OMM_FLAG_PREFETCHING = $0002;
  OMM_FLAG_UNDERRUN    = $0004;
  OMM_FLAG_STREAMING   = $0008;

  // Plugin Lifecycle States
  OMM_PLUGIN_UNLOADED    = 0;
  OMM_PLUGIN_LAZY_WAKEUP = 1;
  OMM_PLUGIN_ACTIVE      = 2;
  OMM_PLUGIN_SUSPENDED   = 3;
  OMM_PLUGIN_DEEP_UNLOAD = 4;

// POSIX Shared Memory Libc Bindings
function shm_open(name: PChar; oflag: cint; mode: mode_t): cint; cdecl; external 'c';
function shm_unlink(name: PChar): cint; cdecl; external 'c';

type
  // Exactly 65,536 bytes (64 KB)
  TOMMSharedMemory = packed record
    // 0x0000 - 0x000F: Header & Atomic Seqlock
    Magic: UInt32;                      // 4 bytes: 0x4F4D4D53 ('OMMS')
    Version: UInt32;                    // 4 bytes: Protocol version (1)
    SeqLock: UInt64;                    // 8 bytes: 64-bit atomic sequence lock (even=stable, odd=writing)

    // 0x0010 - 0x0027: Playback State
    PlaybackState: UInt32;              // 4 bytes: 0=Stopped, 1=Playing, 2=Paused, 3=Buffering, 4=Error
    PlaybackFlags: UInt32;              // 4 bytes: Bitmask (Muted, Prefetching, Underrun, Streaming)
    CurrentTrackID: UInt32;             // 4 bytes: 1-based Track ID in library.bin (0 if stream)
    PositionMs: UInt32;                 // 4 bytes: Playback offset in ms
    DurationMs: UInt32;                 // 4 bytes: Total track duration in ms
    Volume: Single;                     // 4 bytes: Volume scalar 0.0 to 1.0

    // 0x0028 - 0x0037: Audio Hardware & Buffer Metrics
    SampleRate: UInt32;                 // 4 bytes: Audio sample rate (e.g. 44100, 48000)
    Channels: UInt16;                   // 2 bytes: Channel count (1=Mono, 2=Stereo)
    BitDepth: UInt16;                   // 2 bytes: Bits per sample (16, 24, 32)
    BufferFillRatio: Single;            // 4 bytes: Ring buffer fill fraction (0.0 .. 1.0)
    UnderrunCounter: UInt32;            // 4 bytes: Total audio underrun occurrences

    // 0x0038 - 0x004F: Plugin Lifecycle & Daemon Status
    PluginState: UInt32;                // 4 bytes: 0=Unloaded, 1=Wakeup, 2=Active, 3=Suspend, 4=DeepUnload
    PluginIdleSecs: UInt32;             // 4 bytes: Seconds since last streaming I/O
    PluginRssBytes: UInt64;             // 8 bytes: Physical RSS in bytes of plugin dynamic library
    DaemonPID: UInt32;                  // 4 bytes: Process ID of omm_daemon
    DaemonUptimeSecs: UInt32;           // 4 bytes: Daemon total uptime in seconds

    // 0x0050 - 0x007F: Library Summary & Padding
    TotalTracks: UInt32;                // 4 bytes: Total tracks indexed in library.bin
    ReservedHeader: array[0..43] of Byte; // 44 bytes: Alignment pad to 0x0080

    // 0x0080 - 0x01FF: Track Metadata Strings (UTF-8, Null-terminated)
    TrackTitle: array[0..127] of AnsiChar;  // 128 bytes (0x0080 - 0x00FF)
    TrackArtist: array[0..127] of AnsiChar; // 128 bytes (0x0100 - 0x017F)
    TrackAlbum: array[0..127] of AnsiChar;  // 128 bytes (0x0180 - 0x01FF)

    // 0x0200 - 0x02FF: Active Virtual URI
    VirtualURI: array[0..255] of AnsiChar;  // 256 bytes: 'file://...' or 'mineral://...'

    // 0x0300 - 0x05FF: Synchronized Lyrics
    LyricCurrent: array[0..255] of AnsiChar;     // 256 bytes (0x0300 - 0x03FF): Active lyric line
    LyricNext: array[0..255] of AnsiChar;        // 256 bytes (0x0400 - 0x04FF): Next lyric line
    LyricTranslation: array[0..255] of AnsiChar; // 256 bytes (0x0500 - 0x05FF): Translated lyric line

    // 0x0600 - 0x06FF: Lyric Timing & Reserved
    LyricTimestampMs: UInt32;           // 4 bytes: Timestamp of LyricCurrent in ms
    LyricLineIdx: UInt32;               // 4 bytes: Index of active lyric line
    ReservedLyric: array[0..247] of Byte; // 248 bytes: Alignment pad to 0x0700

    // 0x0700 - 0x07FF: Spectrum Configuration & Frame Counter
    SpectrumBands: UInt32;              // 4 bytes: FFT spectrum band count (constant 64)
    SpectrumSeq: UInt32;                // 4 bytes: Frame sequence counter (increments every frame)
    ReservedSpec: array[0..247] of Byte; // 248 bytes: Alignment pad to 0x0800

    // 0x0800 - 0x0AFF: 64-Band Spectrum Data
    SpectrumMags: array[0..63] of Single;   // 256 bytes (0x0800 - 0x08FF): Normalized magnitudes (0.0 .. 1.0)
    SpectrumPeaks: array[0..63] of Single;  // 256 bytes (0x0900 - 0x09FF): Peak-hold magnitudes (0.0 .. 1.0)
    QuantizedBars: array[0..63] of UInt8;   // 64 bytes (0x0A00 - 0x0A3F): Quantized bar heights (0 .. 64) for TUI
    QuantizedPeaks: array[0..63] of UInt8;  // 64 bytes (0x0A40 - 0x0A7F): Quantized peak heights (0 .. 64) for TUI
    ReservedPad: array[0..127] of Byte;     // 128 bytes: Alignment pad to 0x0B00

    // 0x0B00 - 0x12FF: Oscilloscope Waveform Tap
    OscilloscopeTap: array[0..511] of Single; // 2048 bytes: Circular PCM waveform sample buffer

    // 0x1300 - 0xFFFF: Reserved Segment Padding
    ReservedPayload: array[0..60671] of Byte; // 60672 bytes: Pad to exactly 65,536 bytes (64 KB)
  end;
  POMMSharedMemory = ^TOMMSharedMemory;

  // Exactly 512 bytes (sector-aligned library track record)
  TOMMTrackRecord = packed record
    TrackID: UInt32;                  // 4 bytes: Unique track ID
    DurationMs: UInt32;               // 4 bytes: Duration in ms
    Year: UInt16;                     // 2 bytes: Release year
    TrackNo: UInt16;                  // 2 bytes: Track number
    BitrateKbps: UInt16;              // 2 bytes: Bitrate in kbps
    FormatTag: UInt16;                // 2 bytes: 1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC
    Title: array[0..127] of AnsiChar; // 128 bytes: UTF-8 Title
    Artist: array[0..95] of AnsiChar; // 96 bytes: UTF-8 Artist
    Album: array[0..95] of AnsiChar;  // 96 bytes: UTF-8 Album
    RelativePath: array[0..127] of AnsiChar; // 128 bytes: Relative file path
    TfIdfVector: array[0..31] of ShortInt;   // 32 bytes: 32-dim quantized TF-IDF vector
    VectorNorm: Single;               // 4 bytes: Precomputed Euclidean L2 norm
    Reserved: array[0..11] of Byte;   // 12 bytes: Padding to exactly 512 bytes
  end;
  POMMTrackRecord = ^TOMMTrackRecord;

  // 24 bytes Plugin Status
  TOmmPluginStatus = packed record
    ProtocolVersion: UInt32; // 4 bytes
    State: UInt32;           // 4 bytes (0=Unloaded, 1=Wakeup, 2=Active, 3=Suspend, 4=DeepUnload)
    RssBytes: UInt64;        // 8 bytes
    ActiveStreams: UInt32;   // 4 bytes
    IdleSeconds: UInt32;     // 4 bytes
  end;
  POmmPluginStatus = ^TOmmPluginStatus;

  // Opaque stream handle
  TOmmStreamHandle = Pointer;

  // 96 bytes C-ABI Plugin VTable
  TOmmPluginVTable = record
    ProtocolVersion: UInt32;
    Init: function(ConfigPath: PAnsiChar): Int32; cdecl;
    Shutdown: function(): Int32; cdecl;
    GetStatus: function(OutStatus: POmmPluginStatus): Int32; cdecl;
    Suspend: function(): Int32; cdecl;
    Resume: function(): Int32; cdecl;
    CanHandle: function(URI: PAnsiChar): Int32; cdecl;
    OpenStream: function(URI: PAnsiChar; OutHandle: Pointer): Int32; cdecl;
    ReadStream: function(Handle: TOmmStreamHandle; Buffer: PByte; Count: SizeUInt; OutRead: PSizeUInt): Int32; cdecl;
    SeekStream: function(Handle: TOmmStreamHandle; Offset: Int64; Whence: Int32; OutPos: PInt64): Int32; cdecl;
    CloseStream: function(Handle: TOmmStreamHandle): Int32; cdecl;
    FetchLyrics: function(URI: PAnsiChar; OutBuf: PAnsiChar; BufLen: SizeUInt; OutLen: PSizeUInt): Int32; cdecl;
  end;
  POmmPluginVTable = ^TOmmPluginVTable;

  // C-ABI export entry function pointer
  TOmmPluginGetVTableFn = function(ProtocolVersion: UInt32): POmmPluginVTable; cdecl;

// 64-Bit Atomic Seqlock Routines
procedure SeqLockWriteBegin(var Seq: UInt64);
procedure SeqLockWriteEnd(var Seq: UInt64);
function SeqLockReadBegin(constref Seq: UInt64): UInt64;
function SeqLockReadRetry(constref Seq: UInt64; StartSeq: UInt64): Boolean;

// POSIX Shared Memory Routines
function CreateSharedMemory(const ShmName: string = OMM_SHM_NAME): POMMSharedMemory;
function OpenSharedMemory(const ShmName: string = OMM_SHM_NAME; ReadOnly: Boolean = True): POMMSharedMemory;
function CloseSharedMemory(pShm: POMMSharedMemory): Boolean;
function UnlinkSharedMemory(const ShmName: string = OMM_SHM_NAME): Boolean;

implementation

procedure SeqLockWriteBegin(var Seq: UInt64);
begin
  // Increment sequence counter to make it ODD (write in progress)
  InterlockedIncrement64(Int64(Seq));
  WriteBarrier;
  asm
    sfence
  end;
end;

procedure SeqLockWriteEnd(var Seq: UInt64);
begin
  WriteBarrier;
  asm
    sfence
  end;
  // Increment sequence counter to make it EVEN (write completed, stable state)
  InterlockedIncrement64(Int64(Seq));
end;

function SeqLockReadBegin(constref Seq: UInt64): UInt64;
var
  CurrentSeq: UInt64;
  pSeq: PUInt64;
begin
  pSeq := @Seq;
  repeat
    CurrentSeq := pSeq^;
    while (CurrentSeq and 1) <> 0 do
    begin
      asm
        pause
      end;
      CurrentSeq := pSeq^;
    end;
    ReadBarrier;
    asm
      lfence
    end;
    CurrentSeq := pSeq^;
  until (CurrentSeq and 1) = 0;
  Result := CurrentSeq;
end;

function SeqLockReadRetry(constref Seq: UInt64; StartSeq: UInt64): Boolean;
var
  pSeq: PUInt64;
begin
  pSeq := @Seq;
  ReadBarrier;
  asm
    lfence
  end;
  Result := (pSeq^ <> StartSeq);
end;

function CreateSharedMemory(const ShmName: string): POMMSharedMemory;
var
  fd: cint;
  pShm: POMMSharedMemory;
begin
  Result := nil;
  fd := shm_open(PChar(ShmName), O_RDWR or O_CREAT, &666);
  if fd < 0 then Exit;

  if fpfTruncate(fd, OMM_SHM_SIZE) <> 0 then
  begin
    fpClose(fd);
    Exit;
  end;

  pShm := POMMSharedMemory(fpMMap(nil, OMM_SHM_SIZE, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0));
  fpClose(fd);

  if (pShm = nil) or (pShm = POMMSharedMemory(Pointer(-1))) then
    Exit;

  FillChar(pShm^, OMM_SHM_SIZE, 0);
  pShm^.Magic := OMM_SHM_MAGIC;
  pShm^.Version := OMM_SHM_VERSION;
  pShm^.SpectrumBands := OMM_SPECTRUM_BANDS;
  pShm^.DaemonPID := fpGetPID;

  Result := pShm;
end;

function OpenSharedMemory(const ShmName: string; ReadOnly: Boolean): POMMSharedMemory;
var
  fd: cint;
  oflag: cint;
  prot: cint;
  pShm: POMMSharedMemory;
begin
  Result := nil;
  if ReadOnly then
  begin
    oflag := O_RDONLY;
    prot := PROT_READ;
  end
  else
  begin
    oflag := O_RDWR;
    prot := PROT_READ or PROT_WRITE;
  end;

  fd := shm_open(PChar(ShmName), oflag, 0);
  if fd < 0 then
  begin
    fd := fpOpen(PChar(ShmName), oflag, 0);
    if fd < 0 then Exit;
  end;

  pShm := POMMSharedMemory(fpMMap(nil, OMM_SHM_SIZE, prot, MAP_SHARED, fd, 0));
  fpClose(fd);

  if (pShm = nil) or (pShm = POMMSharedMemory(Pointer(-1))) then
    Exit;

  if (pShm^.Magic <> OMM_SHM_MAGIC) or (pShm^.Version <> OMM_SHM_VERSION) then
  begin
    fpMUnmap(pShm, OMM_SHM_SIZE);
    Exit(nil);
  end;

  Result := pShm;
end;

function CloseSharedMemory(pShm: POMMSharedMemory): Boolean;
begin
  if (pShm <> nil) and (pShm <> POMMSharedMemory(Pointer(-1))) then
    Result := (fpMUnmap(pShm, OMM_SHM_SIZE) = 0)
  else
    Result := False;
end;

function UnlinkSharedMemory(const ShmName: string): Boolean;
begin
  Result := (shm_unlink(PChar(ShmName)) = 0);
end;

end.
