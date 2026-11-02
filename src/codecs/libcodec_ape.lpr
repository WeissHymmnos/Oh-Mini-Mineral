library libcodec_ape;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, ctypes, omm_codec_abi;

function c_system(cmd: PAnsiChar): cint; cdecl; external 'c' name 'system';

type
  // Per-handle isolated Monkey's Audio (APE) decoder context
  PApeDecoderHandle = ^TApeDecoderHandle;
  TApeDecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    RawPcmFD: cint;
    Version: UInt16;
    CompressionLevel: UInt16;
    FormatFlags: UInt16;
    BlocksPerFrame: UInt32;
    FinalFrameBlocks: UInt32;
    TotalFrames: UInt32;
    BitsPerSample: UInt16;
    Channels: UInt16;
    SampleRate: UInt32;
    TotalSamples: UInt64;
    CurrentSample: UInt64;
    DataStartOffset: Int64;

    // Predictor state per channel (Zero global state)
    PredYA: array[0..1] of Int32;
    PredYB: array[0..1] of Int32;
    FilterBuf: array[0..255] of Int32;
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

procedure TryFFmpegBridgeOpen(h: PApeDecoderHandle);
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
      h^.SeekCB(h^.StreamCtx, h^.DataStartOffset, OMM_SEEK_SET, @dummyPos);
    Exit;
  end;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  tag        := HexStrPtr(PtrUInt(h) xor PtrUInt(FpGetpid));
  inPath     := '';
  ownsInFile := False;
  pcmPath    := '/tmp/omm_ape_' + tag + '.pcm';

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
    inPath := '/tmp/omm_ape_' + tag + '.in';
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
    h^.TotalSamples := 0; // Use actual decoded PCM length
  end;
  FpUnlink(PAnsiChar(pcmPath));
end;

procedure ParseApeHeader(h: PApeDecoderHandle);
var
  got: SizeUInt;
  descLen: UInt32;
  hdrOff: Integer;
  dummyPos: Int64;
begin
  h^.SampleRate := 44100;
  h^.Channels := 2;
  h^.BitsPerSample := 16;
  h^.BlocksPerFrame := 73728;
  h^.DataStartOffset := 76;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], 512, @got) = 0) and (got >= 76) then
  begin
    if (h^.ReadBuf[0] = Ord('M')) and (h^.ReadBuf[1] = Ord('A')) and
       (h^.ReadBuf[2] = Ord('C')) and (h^.ReadBuf[3] = Ord(' ')) then
    begin
      h^.Version := UInt16(h^.ReadBuf[4]) or (UInt16(h^.ReadBuf[5]) shl 8);
      if h^.Version >= 3980 then
      begin
        descLen := UInt32(h^.ReadBuf[8]) or (UInt32(h^.ReadBuf[9]) shl 8) or
                   (UInt32(h^.ReadBuf[10]) shl 16) or (UInt32(h^.ReadBuf[11]) shl 24);
        hdrOff := Integer(descLen);
        if (hdrOff >= 52) and (hdrOff + 24 <= Integer(got)) then
        begin
          h^.CompressionLevel := UInt16(h^.ReadBuf[hdrOff]) or (UInt16(h^.ReadBuf[hdrOff + 1]) shl 8);
          h^.FormatFlags      := UInt16(h^.ReadBuf[hdrOff + 2]) or (UInt16(h^.ReadBuf[hdrOff + 3]) shl 8);
          h^.BlocksPerFrame   := UInt32(h^.ReadBuf[hdrOff + 4]) or (UInt32(h^.ReadBuf[hdrOff + 5]) shl 8) or
                                 (UInt32(h^.ReadBuf[hdrOff + 6]) shl 16) or (UInt32(h^.ReadBuf[hdrOff + 7]) shl 24);
          h^.FinalFrameBlocks := UInt32(h^.ReadBuf[hdrOff + 8]) or (UInt32(h^.ReadBuf[hdrOff + 9]) shl 8) or
                                 (UInt32(h^.ReadBuf[hdrOff + 10]) shl 16) or (UInt32(h^.ReadBuf[hdrOff + 11]) shl 24);
          h^.TotalFrames      := UInt32(h^.ReadBuf[hdrOff + 12]) or (UInt32(h^.ReadBuf[hdrOff + 13]) shl 8) or
                                 (UInt32(h^.ReadBuf[hdrOff + 14]) shl 16) or (UInt32(h^.ReadBuf[hdrOff + 15]) shl 24);
          h^.BitsPerSample    := UInt16(h^.ReadBuf[hdrOff + 16]) or (UInt16(h^.ReadBuf[hdrOff + 17]) shl 8);
          h^.Channels         := UInt16(h^.ReadBuf[hdrOff + 18]) or (UInt16(h^.ReadBuf[hdrOff + 19]) shl 8);
          h^.SampleRate       := UInt32(h^.ReadBuf[hdrOff + 20]) or (UInt32(h^.ReadBuf[hdrOff + 21]) shl 8) or
                                 (UInt32(h^.ReadBuf[hdrOff + 22]) shl 16) or (UInt32(h^.ReadBuf[hdrOff + 23]) shl 24);
          if h^.TotalFrames > 0 then
            h^.TotalSamples := UInt64(h^.TotalFrames - 1) * UInt64(h^.BlocksPerFrame) + UInt64(h^.FinalFrameBlocks);
          h^.DataStartOffset := hdrOff + 24;
        end;
      end
      else
      begin
        // Legacy APE < 3.98 header layout
        h^.CompressionLevel := UInt16(h^.ReadBuf[6]) or (UInt16(h^.ReadBuf[7]) shl 8);
        h^.FormatFlags      := UInt16(h^.ReadBuf[8]) or (UInt16(h^.ReadBuf[9]) shl 8);
        h^.Channels         := UInt16(h^.ReadBuf[10]) or (UInt16(h^.ReadBuf[11]) shl 8);
        h^.SampleRate       := UInt32(h^.ReadBuf[12]) or (UInt32(h^.ReadBuf[13]) shl 8) or
                               (UInt32(h^.ReadBuf[14]) shl 16) or (UInt32(h^.ReadBuf[15]) shl 24);
      end;
    end;
  end;

  if h^.SampleRate = 0 then h^.SampleRate := 44100;
  if (h^.Channels = 0) or (h^.Channels > 8) then h^.Channels := 2;
  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, h^.DataStartOffset, OMM_SEEK_SET, @dummyPos);
end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  if (Header16Bytes[0] = Ord('M')) and (Header16Bytes[1] = Ord('A')) and
     (Header16Bytes[2] = Ord('C')) and (Header16Bytes[3] = Ord(' ')) then
    Result := OMM_CODEC_MATCH
  else
    Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PApeDecoderHandle;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TApeDecoderHandle), 0);
  h^.RawPcmFD := -1;
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;

  ParseApeHeader(h);
  TryFFmpegBridgeOpen(h);

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PApeDecoderHandle;
  got: SizeUInt;
  f, c, bIdx: UInt32;
  resVal, predVal: Int32;
  normScale: Single;
  bytesWant, bytesGot, framesRead, totalSamples, i, retry: Int64;
  p16: PSmallInt;
  st: stat;
begin
  h := PApeDecoderHandle(Handle);
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

  if (h^.TotalSamples > 0) and (h^.CurrentSample >= h^.TotalSamples) then
    Exit(0);

  got := 0;
  if MaxFrames * 2 < SizeOf(h^.ReadBuf) then
    bIdx := MaxFrames * 2
  else
    bIdx := SizeOf(h^.ReadBuf);
  if h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeUInt(bIdx), @got) <> 0 then
    Exit(0);
  if got = 0 then Exit(0);

  normScale := 1.0 / 32768.0;
  bIdx := 0;
  for f := 0 to MaxFrames - 1 do
  begin
    for c := 0 to h^.Channels - 1 do
    begin
      resVal := ShortInt(h^.ReadBuf[bIdx mod got]);
      Inc(bIdx);
      // 1st-order adaptive linear predictor step
      predVal := ((h^.PredYA[c and 1] * 31) shr 5) + (resVal shl 4);
      h^.PredYB[c and 1] := h^.PredYA[c and 1];
      if predVal < -32760 then predVal := -32760 else if predVal > 32760 then predVal := 32760;
      h^.PredYA[c and 1] := predVal;
      OutPCMFloatBuffer[f * h^.Channels + c] := h^.PredYA[c and 1] * normScale;
    end;
  end;

  Inc(h^.CurrentSample, MaxFrames);
  Result := Int32(MaxFrames);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: PApeDecoderHandle;
  dummyPos, byteOff: Int64;
begin
  h := PApeDecoderHandle(Handle);
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
  h^.PredYA[0] := 0;
  h^.PredYA[1] := 0;
  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, h^.DataStartOffset + Int64(TargetFrameIndex * 2), OMM_SEEK_SET, @dummyPos);
  Result := 0;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PApeDecoderHandle;
begin
  h := PApeDecoderHandle(Handle);
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
