unit omm_fft;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  Math, omm_shm;

const
  OMM_FFT_SIZE = 1024;
  OMM_FFT_LOG2 = 10;

type
  TOmmFFTContext = record
    Initialized: Boolean;
    WaveformHistory: array[0..OMM_FFT_SIZE - 1] of Single;
    WaveformWriteIdx: UInt32;
    Window: array[0..OMM_FFT_SIZE - 1] of Single;
    BitRev: array[0..OMM_FFT_SIZE - 1] of UInt16;
    CosTable: array[0..(OMM_FFT_SIZE div 2) - 1] of Single;
    SinTable: array[0..(OMM_FFT_SIZE div 2) - 1] of Single;
    BandMap: array[0..OMM_SPECTRUM_BANDS - 1, 0..1] of UInt16;
    PeakHold: array[0..OMM_SPECTRUM_BANDS - 1] of Single;
    Xr: array[0..OMM_FFT_SIZE - 1] of Single;
    Xi: array[0..OMM_FFT_SIZE - 1] of Single;
  end;

procedure InitFFTContext(var Ctx: TOmmFFTContext);
procedure PushPCMSamplesToFFT(var Ctx: TOmmFFTContext; pPCM: PSingle; FrameCount, Channels: UInt32);
procedure PushSyntheticCarrierToFFT(var Ctx: TOmmFFTContext; PositionMs, FrameCount: UInt32; Volume: Single);
procedure ComputeSpectrumAndSyncShm(var Ctx: TOmmFFTContext; pShm: POMMSharedMemory;
  PlaybackState, PositionMs, DurationMs: UInt32; Volume: Single);

implementation

function ReverseBits(x: UInt16; bits: Integer): UInt16; inline;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to bits - 1 do
  begin
    Result := (Result shl 1) or (x and 1);
    x := x shr 1;
  end;
end;

procedure InitFFTContext(var Ctx: TOmmFFTContext);
var
  i, b, binStart, binEnd: Integer;
  angle, minFreq, maxFreq, binHz, fLow, fHigh: Single;
begin
  FillChar(Ctx, SizeOf(Ctx), 0);

  for i := 0 to OMM_FFT_SIZE - 1 do
  begin
    Ctx.Window[i] := 0.5 * (1.0 - Cos(2.0 * Pi * i / (OMM_FFT_SIZE - 1)));
    Ctx.BitRev[i] := ReverseBits(UInt16(i), OMM_FFT_LOG2);
  end;

  for i := 0 to (OMM_FFT_SIZE div 2) - 1 do
  begin
    angle := -2.0 * Pi * i / OMM_FFT_SIZE;
    Ctx.CosTable[i] := Cos(angle);
    Ctx.SinTable[i] := Sin(angle);
  end;

  minFreq := 45.0;
  maxFreq := 18000.0;
  binHz := 48000.0 / OMM_FFT_SIZE;

  for b := 0 to OMM_SPECTRUM_BANDS - 1 do
  begin
    fLow := minFreq * Power(maxFreq / minFreq, b / OMM_SPECTRUM_BANDS);
    fHigh := minFreq * Power(maxFreq / minFreq, (b + 1) / OMM_SPECTRUM_BANDS);
    binStart := Trunc(fLow / binHz);
    binEnd := Trunc(fHigh / binHz);
    if binStart < b + 1 then binStart := b + 1;
    if binEnd <= binStart then binEnd := binStart + 1;
    if binEnd > 511 then binEnd := 511;
    Ctx.BandMap[b, 0] := UInt16(binStart);
    Ctx.BandMap[b, 1] := UInt16(binEnd);
    Ctx.PeakHold[b] := 0.0;
  end;

  Ctx.Initialized := True;
end;

procedure PushPCMSamplesToFFT(var Ctx: TOmmFFTContext; pPCM: PSingle; FrameCount, Channels: UInt32);
var
  f, c: UInt32;
  mono: Single;
begin
  if (pPCM = nil) or (FrameCount = 0) or (Channels = 0) then Exit;
  if not Ctx.Initialized then InitFFTContext(Ctx);

  for f := 0 to FrameCount - 1 do
  begin
    mono := 0.0;
    for c := 0 to Channels - 1 do
      mono := mono + pPCM[f * Channels + c];
    mono := mono / Channels;

    Ctx.WaveformHistory[Ctx.WaveformWriteIdx] := mono;
    Ctx.WaveformWriteIdx := (Ctx.WaveformWriteIdx + 1) and (OMM_FFT_SIZE - 1);
  end;
end;

procedure PushSyntheticCarrierToFFT(var Ctx: TOmmFFTContext; PositionMs, FrameCount: UInt32; Volume: Single);
var
  f: UInt32;
  tBase, t, env1, env2, env3, env4, mono: Single;
begin
  if FrameCount = 0 then Exit;
  if not Ctx.Initialized then InitFFTContext(Ctx);

  tBase := PositionMs * 0.001;
  for f := 0 to FrameCount - 1 do
  begin
    t := tBase + f / 48000.0;
    env1 := 0.55 + 0.45 * Sin(t * 4.2);
    env2 := 0.50 + 0.50 * Cos(t * 6.8);
    env3 := 0.45 + 0.55 * Sin(t * 9.5);
    env4 := 0.40 + 0.60 * Cos(t * 13.1);
    mono := Volume * 1.15 * (
      0.70 * env1 * Sin(2.0 * Pi * 93.7 * t) +
      0.85 * env2 * Sin(2.0 * Pi * 187.5 * t) +
      0.75 * env3 * Sin(2.0 * Pi * 328.1 * t) +
      0.90 * env1 * Sin(2.0 * Pi * 515.6 * t) +
      0.65 * env4 * Sin(2.0 * Pi * 750.0 * t) +
      0.80 * env2 * Sin(2.0 * Pi * 1078.1 * t) +
      0.70 * env3 * Sin(2.0 * Pi * 1500.0 * t) +
      0.85 * env4 * Sin(2.0 * Pi * 2156.2 * t) +
      0.60 * env1 * Sin(2.0 * Pi * 3046.8 * t) +
      0.75 * env2 * Sin(2.0 * Pi * 4312.5 * t) +
      0.55 * env3 * Sin(2.0 * Pi * 6093.7 * t) +
      0.65 * env4 * Sin(2.0 * Pi * 8625.0 * t) +
      0.45 * env1 * Sin(2.0 * Pi * 12187.5 * t)
    );
    Ctx.WaveformHistory[Ctx.WaveformWriteIdx] := mono;
    Ctx.WaveformWriteIdx := (Ctx.WaveformWriteIdx + 1) and (OMM_FFT_SIZE - 1);
  end;
end;

procedure ComputeSpectrumAndSyncShm(var Ctx: TOmmFFTContext; pShm: POMMSharedMemory;
  PlaybackState, PositionMs, DurationMs: UInt32; Volume: Single);
const
  DECAY_FACTOR = 0.92;
  INV_LN17     = 0.352956123; // 1.0 / Ln(1.0 + 16.0)
var
  i, s, m, m2, step, k, j, tableIdx, uIdx, tIdx, b, bin, startBin, endBin: Integer;
  start, idx, tapStart: UInt32;
  rev: UInt16;
  cVal, sVal, tr, ti, maxMagSq, magSq, mag, tilted, boostMag: Single;
  barVal, peakVal: Integer;
  mags: array[0..OMM_SPECTRUM_BANDS - 1] of Single;
  peaks: array[0..OMM_SPECTRUM_BANDS - 1] of Single;
  qbars: array[0..OMM_SPECTRUM_BANDS - 1] of UInt8;
  qpeaks: array[0..OMM_SPECTRUM_BANDS - 1] of UInt8;
  oscTap: array[0..511] of Single;
begin
  if pShm = nil then Exit;
  if not Ctx.Initialized then InitFFTContext(Ctx);

  start := Ctx.WaveformWriteIdx;
  for i := 0 to OMM_FFT_SIZE - 1 do
  begin
    idx := (start + UInt32(i)) and (OMM_FFT_SIZE - 1);
    rev := Ctx.BitRev[i];
    Ctx.Xr[rev] := Ctx.WaveformHistory[idx] * Ctx.Window[i];
    Ctx.Xi[rev] := 0.0;
  end;

  for s := 1 to OMM_FFT_LOG2 do
  begin
    m := 1 shl s;
    m2 := m shr 1;
    step := OMM_FFT_SIZE shr s;
    k := 0;
    while k < OMM_FFT_SIZE do
    begin
      for j := 0 to m2 - 1 do
      begin
        tableIdx := j * step;
        cVal := Ctx.CosTable[tableIdx];
        sVal := Ctx.SinTable[tableIdx];

        uIdx := k + j;
        tIdx := uIdx + m2;

        tr := cVal * Ctx.Xr[tIdx] - sVal * Ctx.Xi[tIdx];
        ti := sVal * Ctx.Xr[tIdx] + cVal * Ctx.Xi[tIdx];

        Ctx.Xr[tIdx] := Ctx.Xr[uIdx] - tr;
        Ctx.Xi[tIdx] := Ctx.Xi[uIdx] - ti;
        Ctx.Xr[uIdx] := Ctx.Xr[uIdx] + tr;
        Ctx.Xi[uIdx] := Ctx.Xi[uIdx] + ti;
      end;
      Inc(k, m);
    end;
  end;

  for b := 0 to OMM_SPECTRUM_BANDS - 1 do
  begin
    startBin := Ctx.BandMap[b, 0];
    endBin := Ctx.BandMap[b, 1];
    maxMagSq := 0.0;

    for bin := startBin to endBin - 1 do
    begin
      magSq := Ctx.Xr[bin] * Ctx.Xr[bin] + Ctx.Xi[bin] * Ctx.Xi[bin];
      if magSq > maxMagSq then
        maxMagSq := magSq;
    end;

    mag := Sqrt(maxMagSq) / OMM_FFT_SIZE * 2.0;
    tilted := mag * (1.0 + 0.08 * b);
    boostMag := Ln(1.0 + 95.0 * tilted) * INV_LN17;
    if boostMag < 0.0 then boostMag := 0.0;
    if boostMag > 1.0 then boostMag := 1.0;

    mags[b] := boostMag;
    if boostMag >= Ctx.PeakHold[b] then
      Ctx.PeakHold[b] := boostMag
    else
      Ctx.PeakHold[b] := Ctx.PeakHold[b] * DECAY_FACTOR;
    peaks[b] := Ctx.PeakHold[b];

    barVal := Round(boostMag * 64.0);
    if barVal < 0 then barVal := 0 else if barVal > 64 then barVal := 64;
    qbars[b] := UInt8(barVal);

    peakVal := Round(Ctx.PeakHold[b] * 64.0);
    if peakVal < 0 then peakVal := 0 else if peakVal > 64 then peakVal := 64;
    qpeaks[b] := UInt8(peakVal);
  end;

  tapStart := (Ctx.WaveformWriteIdx + OMM_FFT_SIZE - 512) and (OMM_FFT_SIZE - 1);
  for i := 0 to 511 do
    oscTap[i] := Ctx.WaveformHistory[(tapStart + UInt32(i)) and (OMM_FFT_SIZE - 1)];

  SeqLockWriteBegin(pShm^.SeqLock);
  pShm^.PlaybackState := PlaybackState;
  pShm^.PositionMs := PositionMs;
  if DurationMs > 0 then
    pShm^.DurationMs := DurationMs;
  pShm^.Volume := Volume;
  Inc(pShm^.SpectrumSeq);
  Move(mags[0], pShm^.SpectrumMags[0], SizeOf(mags));
  Move(peaks[0], pShm^.SpectrumPeaks[0], SizeOf(peaks));
  Move(qbars[0], pShm^.QuantizedBars[0], SizeOf(qbars));
  Move(qpeaks[0], pShm^.QuantizedPeaks[0], SizeOf(qpeaks));
  Move(oscTap[0], pShm^.OscilloscopeTap[0], SizeOf(oscTap));
  SeqLockWriteEnd(pShm^.SeqLock);
end;

end.
