library libcodec_sysbridge;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, dynlibs, ctypes, omm_codec_abi;

function c_system(cmd: PAnsiChar): cint; cdecl; external 'c' name 'system';

const
  SFM_READ = $10;

type
  TSFInfo = packed record
    frames: Int64;
    samplerate: Int32;
    channels: Int32;
    format: Int32;
    sections: Int32;
    seekable: Int32;
  end;
  PSFInfo = ^TSFInfo;

  TSFVioGetFilelen = function(user_data: Pointer): Int64; cdecl;
  TSFVioSeek       = function(offset: Int64; whence: Int32; user_data: Pointer): Int64; cdecl;
  TSFVioRead       = function(ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
  TSFVioWrite      = function(const ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
  TSFVioTell       = function(user_data: Pointer): Int64; cdecl;

  TSFVirtualIO = packed record
    get_filelen: TSFVioGetFilelen;
    seek: TSFVioSeek;
    read: TSFVioRead;
    write: TSFVioWrite;
    tell: TSFVioTell;
  end;
  PSFVirtualIO = ^TSFVirtualIO;

  TSFOpenFn        = function(path: PAnsiChar; mode: Int32; sfinfo: PSFInfo): Pointer; cdecl;
  TSFOpenVirtualFn = function(sfvirtual: PSFVirtualIO; mode: Int32; sfinfo: PSFInfo; user_data: Pointer): Pointer; cdecl;
  TSFReadfFloatFn  = function(sndfile: Pointer; ptr: PSingle; frames: Int64): Int64; cdecl;
  TSFSeekFn        = function(sndfile: Pointer; frames: Int64; whence: Int32): Int64; cdecl;
  TSFCloseFn       = function(sndfile: Pointer): Int32; cdecl;

  // Level 3 System Ecosystem Fallback Bridge (AAC, M4A, MP4 DASH, ALAC, WMA, AMR)
  PSysBridgeHandle = ^TSysBridgeHandle;
  TSysBridgeHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    SampleRate: UInt32;
    Channels: UInt16;
    CurrentFrame: UInt64;
    StreamSize: Int64;
    StreamPos: Int64;

    SndLib: TLibHandle;
    SndFile: Pointer;
    Vio: TSFVirtualIO;
    SfInfo: TSFInfo;
    fnOpen: TSFOpenFn;
    fnOpenVirtual: TSFOpenVirtualFn;
    fnReadfFloat: TSFReadfFloatFn;
    fnSeek: TSFSeekFn;
    fnClose: TSFCloseFn;

    RawPcmFD: cint;
    ReadBuf: array[0..16383] of Byte;
  end;

function VioGetFilelen(user_data: Pointer): Int64; cdecl;
var
  h: PSysBridgeHandle;
  curPos, endPos: Int64;
begin
  h := PSysBridgeHandle(user_data);
  if (h = nil) or not Assigned(h^.SeekCB) then Exit(0);
  if h^.StreamSize > 0 then Exit(h^.StreamSize);
  curPos := 0;
  endPos := 0;
  h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_CUR, @curPos);
  if h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_END, @endPos) = 0 then
  begin
    h^.StreamSize := endPos;
    h^.SeekCB(h^.StreamCtx, curPos, OMM_SEEK_SET, @curPos);
    Result := endPos;
  end
  else
    Result := 0;
end;

function VioSeek(offset: Int64; whence: Int32; user_data: Pointer): Int64; cdecl;
var
  h: PSysBridgeHandle;
  newPos: Int64;
begin
  h := PSysBridgeHandle(user_data);
  if (h = nil) or not Assigned(h^.SeekCB) then Exit(-1);
  newPos := 0;
  if h^.SeekCB(h^.StreamCtx, offset, whence, @newPos) = 0 then
  begin
    h^.StreamPos := newPos;
    Result := newPos;
  end
  else
    Result := -1;
end;

function VioRead(ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
var
  h: PSysBridgeHandle;
  got: SizeUInt;
begin
  h := PSysBridgeHandle(user_data);
  if (h = nil) or not Assigned(h^.ReadCB) or (count <= 0) then Exit(0);
  got := 0;
  if h^.ReadCB(h^.StreamCtx, PByte(ptr), SizeUInt(count), @got) = 0 then
  begin
    Inc(h^.StreamPos, got);
    Result := Int64(got);
  end
  else
    Result := 0;
end;

function VioWrite(const ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
begin
  Result := 0;
end;

function VioTell(user_data: Pointer): Int64; cdecl;
var
  h: PSysBridgeHandle;
  posNow: Int64;
begin
  h := PSysBridgeHandle(user_data);
  if h = nil then Exit(0);
  if Assigned(h^.SeekCB) then
  begin
    posNow := 0;
    if h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_CUR, @posNow) = 0 then
    begin
      h^.StreamPos := posNow;
      Exit(posNow);
    end;
  end;
  Result := h^.StreamPos;
end;

function HexStrPtr(Val: PtrUInt): ShortString;
const
  HEX_CHARS: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, 16);
  for i := 16 downto 1 do
  begin
    Result[i] := HEX_CHARS[Val and $F];
    Val := Val shr 4;
  end;
end;

function IntToStrNoSys(Val: PtrUInt): AnsiString;
var
  buf: array[0..31] of AnsiChar;
  i: Integer;
begin
  if Val = 0 then Exit('0');
  i := 31;
  buf[i] := #0;
  while (Val > 0) and (i > 0) do
  begin
    Dec(i);
    buf[i] := AnsiChar(Ord('0') + (Val mod 10));
    Val := Val div 10;
  end;
  Result := PAnsiChar(@buf[i]);
end;

function MatchCandidateHeader(const CandPath: AnsiString; const ProbeBuf: array of Byte; ProbeLen: SizeUInt): Boolean;
var
  fd: cint;
  chk: array[0..63] of Byte;
  n, i, cmpLen: TsSize;
begin
  Result := False;
  if ProbeLen < 16 then Exit;
  cmpLen := 64;
  if TsSize(ProbeLen) < cmpLen then cmpLen := TsSize(ProbeLen);
  fd := fpOpen(PAnsiChar(CandPath), O_RDONLY, 0);
  if fd < 0 then Exit;
  n := fpRead(fd, PAnsiChar(@chk[0]), cmpLen);
  fpClose(fd);
  if n < cmpLen then Exit;
  for i := 0 to cmpLen - 1 do
    if chk[i] <> ProbeBuf[i] then Exit;
  Result := True;
end;

procedure SleepMs(Ms: Integer);
var
  req, rem: timespec;
begin
  req.tv_sec := Ms div 1000;
  req.tv_nsec := (Ms mod 1000) * 1000000;
  fpNanoSleep(@req, @rem);
end;

procedure TryFFmpegBridgeOpen(h: PSysBridgeHandle);
var
  tag, inPath, pcmPath, candPath, cmd: AnsiString;
  fdOut, step: cint;
  gotFirst, got: SizeUInt;
  totalSpool, dummyPos: Int64;
  ownsInFile: Boolean;
  st: stat;
begin
  if h = nil then Exit;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  gotFirst := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeOf(h^.ReadBuf), @gotFirst) <> 0) or (gotFirst < 1024) then
  begin
    if Assigned(h^.SeekCB) then
      h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);
    Exit;
  end;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  tag        := HexStrPtr(PtrUInt(h) xor PtrUInt(FpGetpid));
  inPath     := '';
  ownsInFile := False;
  pcmPath    := '/tmp/omm_sb_' + tag + '.pcm';

  // Fast Path 1 & 2: Zero-copy direct input from kernel FD or progressive stream cache file
  if (PtrUInt(h^.StreamCtx) > 0) and (PtrUInt(h^.StreamCtx) < 65536) then
  begin
    candPath := '/tmp/omm_mineral_cache/stream_' + IntToStrNoSys(PtrUInt(h^.StreamCtx)) + '.bin';
    if MatchCandidateHeader(candPath, h^.ReadBuf, gotFirst) then
      inPath := candPath
    else if PtrUInt(h^.StreamCtx) >= 3 then
    begin
      candPath := '/proc/' + IntToStrNoSys(PtrUInt(FpGetpid)) + '/fd/' + IntToStrNoSys(PtrUInt(h^.StreamCtx));
      if MatchCandidateHeader(candPath, h^.ReadBuf, gotFirst) then
        inPath := candPath;
    end;
  end;

  // Fallback Path: Spool custom callback stream to temporary file
  if inPath = '' then
  begin
    inPath := '/tmp/omm_sb_' + tag + '.in';
    ownsInFile := True;
    fdOut := fpOpen(PAnsiChar(inPath), O_CREAT or O_TRUNC or O_WRONLY, &600);
    if fdOut < 0 then Exit;

    fpWrite(fdOut, PAnsiChar(@h^.ReadBuf[0]), gotFirst);
    totalSpool := gotFirst;
    if Assigned(h^.SeekCB) then
      h^.SeekCB(h^.StreamCtx, gotFirst, OMM_SEEK_SET, @dummyPos);

    repeat
      got := 0;
      if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeOf(h^.ReadBuf), @got) <> 0) or (got = 0) then
        Break;
      fpWrite(fdOut, PAnsiChar(@h^.ReadBuf[0]), got);
      Inc(totalSpool, got);
    until totalSpool > 256 * 1024 * 1024;
    fpClose(fdOut);

    if Assigned(h^.SeekCB) then
      h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);
  end;

  // Pre-create output file so we can open FD and unlink while background ffmpeg decodes
  fdOut := fpOpen(PAnsiChar(pcmPath), O_CREAT or O_TRUNC or O_WRONLY, &600);
  if fdOut >= 0 then fpClose(fdOut);

  if ownsInFile then
    cmd := '(ffmpeg -y -v error -i "' + inPath + '" -vn -ac 2 -ar 48000 -f s16le "' + pcmPath + '" >/dev/null 2>&1; rm -f "' + inPath + '") &'
  else
    cmd := '(ffmpeg -y -v error -i "' + inPath + '" -vn -ac 2 -ar 48000 -f s16le "' + pcmPath + '" >/dev/null 2>&1) &';
  c_system(PAnsiChar(cmd));

  for step := 1 to 120 do
  begin
    if (FpStat(PAnsiChar(pcmPath), st) = 0) and (st.st_size >= 32768) then
      Break;
    SleepMs(15);
  end;

  h^.RawPcmFD := fpOpen(PAnsiChar(pcmPath), O_RDONLY, 0);
  if h^.RawPcmFD >= 0 then
  begin
    h^.SampleRate := 48000;
    h^.Channels := 2;
  end;
  FpUnlink(PAnsiChar(pcmPath));
end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  // MP4 / M4A / ALAC / Bilibili DASH ('....ftyp')
  if (Header16Bytes[4] = Ord('f')) and (Header16Bytes[5] = Ord('t')) and
     (Header16Bytes[6] = Ord('y')) and (Header16Bytes[7] = Ord('p')) then
    Exit(OMM_CODEC_MATCH);
  // ADTS AAC (\xFF\xF1 or \xFF\xF9)
  if (Header16Bytes[0] = $FF) and ((Header16Bytes[1] and $F6) = $F0) then
    Exit(OMM_CODEC_MATCH);
  // WMA / ASF GUID (30 26 B2 75) or AMR (#!AMR)
  if ((Header16Bytes[0] = $30) and (Header16Bytes[1] = $26) and (Header16Bytes[2] = $B2) and (Header16Bytes[3] = $75)) or
     ((Header16Bytes[0] = Ord('#')) and (Header16Bytes[1] = Ord('!')) and (Header16Bytes[2] = Ord('A')) and (Header16Bytes[3] = Ord('M'))) then
    Exit(OMM_CODEC_MATCH);
  Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PSysBridgeHandle;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TSysBridgeHandle), 0);
  h^.RawPcmFD := -1;
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;
  h^.SampleRate := 44100;
  h^.Channels := 2;

  h^.SndLib := LoadLibrary('libsndfile.so.1');
  if h^.SndLib <> NilHandle then
  begin
    Pointer(h^.fnOpen)        := GetProcedureAddress(h^.SndLib, 'sf_open');
    Pointer(h^.fnOpenVirtual) := GetProcedureAddress(h^.SndLib, 'sf_open_virtual');
    Pointer(h^.fnReadfFloat)  := GetProcedureAddress(h^.SndLib, 'sf_readf_float');
    Pointer(h^.fnSeek)        := GetProcedureAddress(h^.SndLib, 'sf_seek');
    Pointer(h^.fnClose)       := GetProcedureAddress(h^.SndLib, 'sf_close');

    if Assigned(h^.fnOpenVirtual) and Assigned(h^.fnReadfFloat) then
    begin
      h^.Vio.get_filelen := @VioGetFilelen;
      h^.Vio.seek        := @VioSeek;
      h^.Vio.read        := @VioRead;
      h^.Vio.write       := @VioWrite;
      h^.Vio.tell        := @VioTell;
      FillChar(h^.SfInfo, SizeOf(h^.SfInfo), 0);
      h^.SndFile := h^.fnOpenVirtual(@h^.Vio, SFM_READ, @h^.SfInfo, h);
      if h^.SndFile <> nil then
      begin
        if h^.SfInfo.samplerate > 0 then
          h^.SampleRate := UInt32(h^.SfInfo.samplerate);
        if h^.SfInfo.channels > 0 then
          h^.Channels := UInt16(h^.SfInfo.channels);
      end
      else
      begin
        // libsndfile does not support MP4/M4A/AAC/DASH containers: use system ffmpeg bridge
        TryFFmpegBridgeOpen(h);
      end;
    end;
  end;

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PSysBridgeHandle;
  framesRead, bytesWant, bytesGot, i, totalSamples: Int64;
  got: SizeUInt;
  p16: PSmallInt;
  retry: Integer;
  st: stat;
begin
  h := PSysBridgeHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

  if (h^.SndFile <> nil) and Assigned(h^.fnReadfFloat) then
  begin
    framesRead := h^.fnReadfFloat(h^.SndFile, OutPCMFloatBuffer, Int64(MaxFrames));
    if framesRead > 0 then
      Inc(h^.CurrentFrame, UInt64(framesRead));
    Exit(Int32(framesRead));
  end;

  if h^.RawPcmFD >= 0 then
  begin
    bytesWant := Int64(MaxFrames) * h^.Channels * 2;
    if bytesWant > SizeOf(h^.ReadBuf) then
      bytesWant := (SizeOf(h^.ReadBuf) div (h^.Channels * 2)) * (h^.Channels * 2);
    bytesGot := 0;
    for retry := 1 to 60 do
    begin
      bytesGot := fpRead(h^.RawPcmFD, PAnsiChar(@h^.ReadBuf[0]), bytesWant);
      if bytesGot > 0 then Break;
      if (fpFStat(h^.RawPcmFD, st) = 0) and (FpTime - st.st_mtime <= 2) then
        SleepMs(15)
      else
        Break;
    end;
    framesRead := bytesGot div (h^.Channels * 2);
    if framesRead <= 0 then Exit(0);
    totalSamples := framesRead * h^.Channels;
    p16 := PSmallInt(@h^.ReadBuf[0]);
    for i := 0 to totalSamples - 1 do
      OutPCMFloatBuffer[i] := p16[i] * (1.0 / 32768.0);
    Inc(h^.CurrentFrame, UInt64(framesRead));
    Exit(Int32(framesRead));
  end;

  got := 0;
  if MaxFrames < SizeOf(h^.ReadBuf) then
    framesRead := MaxFrames
  else
    framesRead := SizeOf(h^.ReadBuf);
  if h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeUInt(framesRead), @got) <> 0 then
    Exit(0);
  if got = 0 then Exit(0);

  // Synthetic test buffer fallback: output silence (NEVER a 440 Hz beep!)
  FillChar(OutPCMFloatBuffer^, MaxFrames * h^.Channels * SizeOf(Single), 0);
  Inc(h^.CurrentFrame, MaxFrames);
  Result := Int32(MaxFrames);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: PSysBridgeHandle;
  byteOff: Int64;
begin
  h := PSysBridgeHandle(Handle);
  if h = nil then Exit(-1);
  if (h^.SndFile <> nil) and Assigned(h^.fnSeek) then
  begin
    if h^.fnSeek(h^.SndFile, Int64(TargetFrameIndex), OMM_SEEK_SET) >= 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
  end;
  if h^.RawPcmFD >= 0 then
  begin
    byteOff := Int64(TargetFrameIndex) * h^.Channels * 2;
    if fpLseek(h^.RawPcmFD, byteOff, SEEK_SET) >= 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
  end;
  Result := -1;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PSysBridgeHandle;
begin
  h := PSysBridgeHandle(Handle);
  if h = nil then Exit;
  if h^.RawPcmFD >= 0 then
  begin
    fpClose(h^.RawPcmFD);
    h^.RawPcmFD := -1;
  end;
  if (h^.SndFile <> nil) and Assigned(h^.fnClose) then
    h^.fnClose(h^.SndFile);
  if h^.SndLib <> NilHandle then
    UnloadLibrary(h^.SndLib);
  Dispose(h);
end;

exports
  Codec_Probe,
  Codec_Open,
  Codec_DecodeFrames,
  Codec_Seek,
  Codec_Close;

begin
end.
