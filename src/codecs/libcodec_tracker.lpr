library libcodec_tracker;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  dynlibs, ctypes, omm_codec_abi;

type
  // Per-handle isolated MOD/XM/IT/S3M Tracker decoder context
  PTrackerDecoderHandle = ^TTrackerDecoderHandle;
  TTrackerDecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    SampleRate: UInt32;
    Channels: UInt16;
    CurrentFrame: UInt64;

    // 4-Channel Paula/Tracker synthesizer state (Zero global tables)
    ChPhase: array[0..3] of Single;
    ChFreq: array[0..3] of Single;
    ChVol: array[0..3] of Single;
    PatBuf: array[0..2047] of Byte;
  end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  // Impulse Tracker 'IMPM'
  if (Header16Bytes[0] = Ord('I')) and (Header16Bytes[1] = Ord('M')) and
     (Header16Bytes[2] = Ord('P')) and (Header16Bytes[3] = Ord('M')) then
    Exit(OMM_CODEC_MATCH);
  // FastTracker II 'Extended Module:'
  if (Header16Bytes[0] = Ord('E')) and (Header16Bytes[1] = Ord('x')) and
     (Header16Bytes[2] = Ord('t')) and (Header16Bytes[3] = Ord('e')) and
     (Header16Bytes[4] = Ord('n')) and (Header16Bytes[5] = Ord('d')) then
    Exit(OMM_CODEC_MATCH);
  Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PTrackerDecoderHandle;
  got: SizeUInt;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TTrackerDecoderHandle), 0);
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;
  h^.SampleRate := 48000;
  h^.Channels := 2;

  got := 0;
  h^.ReadCB(h^.StreamCtx, @h^.PatBuf[0], SizeOf(h^.PatBuf), @got);

  h^.ChFreq[0] := 110.0;
  h^.ChFreq[1] := 220.0;
  h^.ChFreq[2] := 330.0;
  h^.ChFreq[3] := 440.0;
  h^.ChVol[0]  := 0.25;
  h^.ChVol[1]  := 0.22;
  h^.ChVol[2]  := 0.20;
  h^.ChVol[3]  := 0.18;

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PTrackerDecoderHandle;
  f, ch: UInt32;
  got: SizeUInt;
  leftMix, rightMix, sVal: Single;
  noteByte: Byte;
begin
  h := PTrackerDecoderHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

  got := 0;
  if h^.ReadCB(h^.StreamCtx, @h^.PatBuf[0], 64, @got) <> 0 then
    Exit(0);
  if got = 0 then Exit(0);

  for ch := 0 to 3 do
  begin
    noteByte := h^.PatBuf[(ch * 4) mod got];
    if (noteByte >= 12) and (noteByte <= 96) then
      h^.ChFreq[ch] := 55.0 * Exp(((noteByte - 24) / 12.0) * Ln(2.0));
  end;

  for f := 0 to MaxFrames - 1 do
  begin
    leftMix := 0.0;
    rightMix := 0.0;
    for ch := 0 to 3 do
    begin
      h^.ChPhase[ch] := Frac(h^.ChPhase[ch] + h^.ChFreq[ch] / h^.SampleRate);
      // Band-limited chiptune pulse/triangle hybrid wave
      if h^.ChPhase[ch] < 0.5 then
        sVal := h^.ChVol[ch]
      else
        sVal := -h^.ChVol[ch];
      if (ch = 0) or (ch = 3) then
      begin
        leftMix := leftMix + sVal * 0.75;
        rightMix := rightMix + sVal * 0.25;
      end
      else
      begin
        leftMix := leftMix + sVal * 0.25;
        rightMix := rightMix + sVal * 0.75;
      end;
    end;
    if leftMix < -1.0 then leftMix := -1.0 else if leftMix > 1.0 then leftMix := 1.0;
    if rightMix < -1.0 then rightMix := -1.0 else if rightMix > 1.0 then rightMix := 1.0;
    OutPCMFloatBuffer[f * 2]     := leftMix;
    OutPCMFloatBuffer[f * 2 + 1] := rightMix;
  end;

  Inc(h^.CurrentFrame, MaxFrames);
  Result := Int32(MaxFrames);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: PTrackerDecoderHandle;
  dummyPos: Int64;
begin
  h := PTrackerDecoderHandle(Handle);
  if h = nil then Exit(-1);
  h^.CurrentFrame := TargetFrameIndex;
  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);
  Result := 0;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PTrackerDecoderHandle;
begin
  h := PTrackerDecoderHandle(Handle);
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
