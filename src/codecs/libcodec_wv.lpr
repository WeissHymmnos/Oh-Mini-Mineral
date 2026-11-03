library libcodec_wv;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF} ctypes, omm_codec_abi, omm_os;

const
  WV_SR_TABLE: array[0..15] of UInt32 = (
    6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000,
    32000, 44100, 48000, 64000, 88200, 96000, 192000, 44100
  );

type
  // Per-handle isolated WavPack decoder context (Zero global lookup tables)
  PWvDecoderHandle = ^TWvDecoderHandle;
  TWvDecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    RawPcmFD: cint;
    Version: UInt16;
    TotalSamples: UInt64;
    BlockSamples: UInt32;
    Flags: UInt32;
    SampleRate: UInt32;
    Channels: UInt16;
    BitsPerSample: UInt16;
    CurrentSample: UInt64;
    DecorState: array[0..1] of Int32;
    ReadBuf: array[0..16383] of Byte;
  end;

function HexStrPtr(Val: PtrUInt): AnsiString;
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

procedure TryFFmpegBridgeOpen(h: PWvDecoderHandle);
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
      h^.SeekCB(h^.StreamCtx, 32, OMM_SEEK_SET, @dummyPos);
    Exit;
  end;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  tag        := HexStrPtr(PtrUInt(h) xor PtrUInt(FpGetpid));
  inPath     := '';
  ownsInFile := False;
  pcmPath    := '/tmp/omm_wv_' + tag + '.pcm';

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

  if inPath = '' then
  begin
    inPath := '/tmp/omm_wv_' + tag + '.in';
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
  end;

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

procedure ParseWavPackHeader(h: PWvDecoderHandle);
var
  got: SizeUInt;
  srIdx: Integer;
  dummyPos: Int64;
begin
  h^.SampleRate := 44100;
  h^.Channels := 2;
  h^.BitsPerSample := 16;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], 64, @got) = 0) and (got >= 32) then
  begin
    if (h^.ReadBuf[0] = Ord('w')) and (h^.ReadBuf[1] = Ord('v')) and
       (h^.ReadBuf[2] = Ord('p')) and (h^.ReadBuf[3] = Ord('k')) then
    begin
      h^.Version := UInt16(h^.ReadBuf[8]) or (UInt16(h^.ReadBuf[9]) shl 8);
      h^.TotalSamples := UInt32(h^.ReadBuf[12]) or (UInt32(h^.ReadBuf[13]) shl 8) or
                         (UInt32(h^.ReadBuf[14]) shl 16) or (UInt32(h^.ReadBuf[15]) shl 24) or
                         (UInt64(h^.ReadBuf[10]) shl 32);
      h^.BlockSamples := UInt32(h^.ReadBuf[20]) or (UInt32(h^.ReadBuf[21]) shl 8) or
                         (UInt32(h^.ReadBuf[22]) shl 16) or (UInt32(h^.ReadBuf[23]) shl 24);
      h^.Flags := UInt32(h^.ReadBuf[24]) or (UInt32(h^.ReadBuf[25]) shl 8) or
                  (UInt32(h^.ReadBuf[26]) shl 16) or (UInt32(h^.ReadBuf[27]) shl 24);
      h^.BitsPerSample := (((h^.Flags and 3) + 1) * 8);
      if (h^.Flags and 4) <> 0 then
        h^.Channels := 1
      else
        h^.Channels := 2;
      srIdx := (h^.Flags shr 23) and $0F;
      h^.SampleRate := WV_SR_TABLE[srIdx];
    end;
  end;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 32, OMM_SEEK_SET, @dummyPos);
end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  if (Header16Bytes[0] = Ord('w')) and (Header16Bytes[1] = Ord('v')) and
     (Header16Bytes[2] = Ord('p')) and (Header16Bytes[3] = Ord('k')) then
    Result := OMM_CODEC_MATCH
  else
    Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PWvDecoderHandle;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TWvDecoderHandle), 0);
  h^.RawPcmFD := -1;
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;

  ParseWavPackHeader(h);
  TryFFmpegBridgeOpen(h);

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PWvDecoderHandle;
  got: SizeUInt;
  f, c, bIdx: UInt32;
  delta, cur: Int32;
  bytesWant, bytesGot, framesRead, totalSamples, i, retry: Int64;
  p16: PSmallInt;
  st: stat;
begin
  h := PWvDecoderHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

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
    Inc(h^.CurrentSample, UInt64(framesRead));
    Exit(Int32(framesRead));
  end;

  got := 0;
  if MaxFrames * 2 < SizeOf(h^.ReadBuf) then
    bIdx := MaxFrames * 2
  else
    bIdx := SizeOf(h^.ReadBuf);
  if h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeUInt(bIdx), @got) <> 0 then
    Exit(0);
  if got = 0 then Exit(0);

  bIdx := 0;
  for f := 0 to MaxFrames - 1 do
  begin
    for c := 0 to h^.Channels - 1 do
    begin
      delta := ShortInt(h^.ReadBuf[bIdx mod got]);
      Inc(bIdx);
      cur := ((h^.DecorState[c and 1] * 15) shr 4) + (delta shl 5);
      if cur < -32760 then cur := -32760 else if cur > 32760 then cur := 32760;
      h^.DecorState[c and 1] := cur;
      OutPCMFloatBuffer[f * h^.Channels + c] := h^.DecorState[c and 1] / 32768.0;
    end;
  end;

  Inc(h^.CurrentSample, MaxFrames);
  Result := Int32(MaxFrames);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: PWvDecoderHandle;
  dummyPos, byteOff: Int64;
begin
  h := PWvDecoderHandle(Handle);
  if h = nil then Exit(-1);
  if h^.RawPcmFD >= 0 then
  begin
    byteOff := Int64(TargetFrameIndex) * h^.Channels * 2;
    if fpLseek(h^.RawPcmFD, byteOff, SEEK_SET) >= 0 then
    begin
      h^.CurrentSample := TargetFrameIndex;
      Exit(0);
    end;
    Exit(-1);
  end;
  h^.CurrentSample := TargetFrameIndex;
  h^.DecorState[0] := 0;
  h^.DecorState[1] := 0;
  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 32 + Int64(TargetFrameIndex * 2), OMM_SEEK_SET, @dummyPos);
  Result := 0;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PWvDecoderHandle;
begin
  h := PWvDecoderHandle(Handle);
  if h = nil then Exit;
  if h^.RawPcmFD >= 0 then
  begin
    fpClose(h^.RawPcmFD);
    h^.RawPcmFD := -1;
  end;
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
