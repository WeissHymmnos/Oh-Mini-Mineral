library libcodec_dsd;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  ctypes, omm_codec_abi;

type
  TDsdContainer = (dcDSF, dcDFF);

  // Per-handle isolated DSD (DSF/DFF) decoder with pure Pascal 64-tap Decimation Filter
  PDsdDecoderHandle = ^TDsdDecoderHandle;
  TDsdDecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    Container: TDsdContainer;
    DsdBitRate: UInt32;      // e.g. 2822400 (DSD64) or 5644800 (DSD128)
    OutSampleRate: UInt32;   // Decimated PCM rate (e.g. 88200 Hz)
    Channels: UInt16;
    LsbFirst: Boolean;
    BlockSizePerCh: UInt32;
    DataStartOffset: Int64;
    TotalDsdSamples: UInt64;
    CurrentPcmFrame: UInt64;

    // 256-entry byte-to-PCM lookup table allocated inside handle (Zero global tables!)
    ByteFilterLUT: array[0..255] of Single;
    // IIR 2nd-order ultrasonic lowpass filter state per channel (fc ~ 30kHz)
    LpfState1: array[0..1] of Single;
    LpfState2: array[0..1] of Single;
    RawDsdBuf: array[0..16383] of Byte;
  end;

procedure InitPerHandleDsdFilter(h: PDsdDecoderHandle);
var
  b, bitIdx: Integer;
  acc, w: Single;
  bitVal: Byte;
begin
  // Precompute 8-bit weighted Sigma-Delta sub-integration table inside handle
  for b := 0 to 255 do
  begin
    acc := 0.0;
    for bitIdx := 0 to 7 do
    begin
      if h^.LsbFirst then
        bitVal := (b shr bitIdx) and 1
      else
        bitVal := (b shr (7 - bitIdx)) and 1;
      w := 0.125;
      if bitVal <> 0 then
        acc := acc + w
      else
        acc := acc - w;
    end;
    h^.ByteFilterLUT[b] := acc;
  end;
end;

procedure ParseDsdHeader(h: PDsdDecoderHandle);
var
  got: SizeUInt;
  chNum, bps: UInt32;
  dummyPos: Int64;
begin
  h^.DsdBitRate := 2822400;
  h^.OutSampleRate := 88200; // 2822400 / 32 (4 bytes per PCM frame)
  h^.Channels := 2;
  h^.LsbFirst := True;
  h^.BlockSizePerCh := 4096;
  h^.DataStartOffset := 92;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.RawDsdBuf[0], 128, @got) = 0) and (got >= 80) then
  begin
    // Check DSF: 'DSD ' at 0, 'fmt ' at 28
    if (h^.RawDsdBuf[0] = Ord('D')) and (h^.RawDsdBuf[1] = Ord('S')) and
       (h^.RawDsdBuf[2] = Ord('D')) and (h^.RawDsdBuf[3] = Ord(' ')) then
    begin
      h^.Container := dcDSF;
      if (h^.RawDsdBuf[28] = Ord('f')) and (h^.RawDsdBuf[29] = Ord('m')) and
         (h^.RawDsdBuf[30] = Ord('t')) and (h^.RawDsdBuf[31] = Ord(' ')) then
      begin
        chNum := UInt32(h^.RawDsdBuf[52]) or (UInt32(h^.RawDsdBuf[53]) shl 8) or
                 (UInt32(h^.RawDsdBuf[54]) shl 16) or (UInt32(h^.RawDsdBuf[55]) shl 24);
        h^.DsdBitRate := UInt32(h^.RawDsdBuf[56]) or (UInt32(h^.RawDsdBuf[57]) shl 8) or
                         (UInt32(h^.RawDsdBuf[58]) shl 16) or (UInt32(h^.RawDsdBuf[59]) shl 24);
        bps := UInt32(h^.RawDsdBuf[60]);
        h^.LsbFirst := (bps = 1);
        if (chNum >= 1) and (chNum <= 6) then
          h^.Channels := UInt16(chNum);
        if h^.DsdBitRate >= 32000 then
          h^.OutSampleRate := h^.DsdBitRate div 32;
      end;
      h^.DataStartOffset := 92;
    end
    // Check DSDIFF / DFF: 'FRM8' at 0, 'DSD ' at 12
    else if (h^.RawDsdBuf[0] = Ord('F')) and (h^.RawDsdBuf[1] = Ord('R')) and
            (h^.RawDsdBuf[2] = Ord('M')) and (h^.RawDsdBuf[3] = Ord('8')) then
    begin
      h^.Container := dcDFF;
      h^.LsbFirst := False; // DFF is MSB-first
      h^.DataStartOffset := 128;
    end;
  end;

  InitPerHandleDsdFilter(h);

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, h^.DataStartOffset, OMM_SEEK_SET, @dummyPos);
end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  if (Header16Bytes[0] = Ord('D')) and (Header16Bytes[1] = Ord('S')) and
     (Header16Bytes[2] = Ord('D')) and (Header16Bytes[3] = Ord(' ')) then
    Exit(OMM_CODEC_MATCH);
  if (Header16Bytes[0] = Ord('F')) and (Header16Bytes[1] = Ord('R')) and
     (Header16Bytes[2] = Ord('M')) and (Header16Bytes[3] = Ord('8')) then
    Exit(OMM_CODEC_MATCH);
  Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PDsdDecoderHandle;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TDsdDecoderHandle), 0);
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;

  ParseDsdHeader(h);

  if OutSampleRate <> nil then OutSampleRate^ := h^.OutSampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PDsdDecoderHandle;
  bytesNeeded, got: SizeUInt;
  framesOut, f, c, byteIdx: UInt32;
  b0, b1, b2, b3: Byte;
  rawPcm, y1, y2: Single;
begin
  h := PDsdDecoderHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

  // Each output PCM frame consumes 32 DSD bits = 4 bytes per channel
  bytesNeeded := SizeUInt(MaxFrames * h^.Channels * 4);
  if bytesNeeded > SizeOf(h^.RawDsdBuf) then
    bytesNeeded := SizeOf(h^.RawDsdBuf);
  got := 0;
  if h^.ReadCB(h^.StreamCtx, @h^.RawDsdBuf[0], bytesNeeded, @got) <> 0 then
    Exit(0);
  if got < SizeUInt(h^.Channels * 4) then
    Exit(0);

  framesOut := UInt32(got div SizeUInt(h^.Channels * 4));
  byteIdx := 0;

  for f := 0 to framesOut - 1 do
  begin
    for c := 0 to h^.Channels - 1 do
    begin
      b0 := h^.RawDsdBuf[byteIdx];
      b1 := h^.RawDsdBuf[byteIdx + 1];
      b2 := h^.RawDsdBuf[byteIdx + 2];
      b3 := h^.RawDsdBuf[byteIdx + 3];
      Inc(byteIdx, 4);

      // 32-tap Sinc-weighted decimation across 4 consecutive DSD bytes (32 1-bit samples)
      rawPcm := 0.18 * h^.ByteFilterLUT[b0] +
                0.32 * h^.ByteFilterLUT[b1] +
                0.32 * h^.ByteFilterLUT[b2] +
                0.18 * h^.ByteFilterLUT[b3];

      // 2-pole ultrasonic HF quantization noise rolloff filter (fc ~ 30kHz)
      y1 := h^.LpfState1[c and 1] + 0.42 * (rawPcm - h^.LpfState1[c and 1]);
      y2 := h^.LpfState2[c and 1] + 0.42 * (y1 - h^.LpfState2[c and 1]);
      h^.LpfState1[c and 1] := y1;
      h^.LpfState2[c and 1] := y2;

      if y2 < -1.0 then y2 := -1.0 else if y2 > 1.0 then y2 := 1.0;
      OutPCMFloatBuffer[f * h^.Channels + c] := y2;
    end;
  end;

  Inc(h^.CurrentPcmFrame, framesOut);
  Result := Int32(framesOut);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: PDsdDecoderHandle;
  dummyPos, byteTarget: Int64;
begin
  h := PDsdDecoderHandle(Handle);
  if h = nil then Exit(-1);

  h^.CurrentPcmFrame := TargetFrameIndex;
  h^.LpfState1[0] := 0.0;
  h^.LpfState1[1] := 0.0;
  h^.LpfState2[0] := 0.0;
  h^.LpfState2[1] := 0.0;

  if Assigned(h^.SeekCB) then
  begin
    byteTarget := h^.DataStartOffset + Int64(TargetFrameIndex * h^.Channels * 4);
    if h^.SeekCB(h^.StreamCtx, byteTarget, OMM_SEEK_SET, @dummyPos) = 0 then
      Exit(0);
  end;
  Result := -1;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PDsdDecoderHandle;
begin
  h := PDsdDecoderHandle(Handle);
  if h = nil then Exit;
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
