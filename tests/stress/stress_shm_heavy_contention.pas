program StressSHMHeavyContention;

{$mode objfpc}{$H+}

uses
  BaseUnix, Unix, SysUtils, omm_shm;

const
  TEST_SHM_NAME = '/omm_stress_shm_heavy';
  TOTAL_WRITES  = 50000;
  NUM_READERS   = 8;

type
  TLocalMags  = array[0..63] of Single;
  TLocalPeaks = array[0..63] of Single;
  TLocalTitle = array[0..127] of AnsiChar;

var
  pShm: POMMSharedMemory;
  ReaderPIDs: array[1..NUM_READERS] of TPid;
  WriterPID: TPid;
  i: Integer;
  Status: cint;

procedure RunWriter;
var
  Frame, b: Integer;
  TStart, TEnd: QWord;
  ElapsedMs: Int64;
  Fps: Double;
  TitleStr: string;
begin
  TStart := GetTickCount64;
  WriteLn(Format('[Writer] Starting %d updates at unthrottled speed with %d concurrent readers...', [TOTAL_WRITES, NUM_READERS]));

  for Frame := 1 to TOTAL_WRITES do
  begin
    SeqLockWriteBegin(pShm^.SeqLock);

    pShm^.PositionMs := Frame;
    pShm^.DurationMs := Frame * 2;
    pShm^.SpectrumSeq := Frame;
    pShm^.Volume := Single((Frame mod 1000) / 1000.0);

    for b := 0 to 63 do
    begin
      pShm^.SpectrumMags[b] := Single((Frame + b) mod 1000);
      pShm^.SpectrumPeaks[b] := Single(((Frame * 3) + b) mod 1000);
    end;

    TitleStr := Format('Track_%08d', [Frame]);
    Move(TitleStr[1], pShm^.TrackTitle[0], Length(TitleStr));
    pShm^.TrackTitle[Length(TitleStr)] := #0;

    SeqLockWriteEnd(pShm^.SeqLock);
  end;

  TEnd := GetTickCount64;
  ElapsedMs := TEnd - TStart;
  if ElapsedMs <= 0 then ElapsedMs := 1;
  Fps := (TOTAL_WRITES * 1000.0) / ElapsedMs;
  WriteLn(Format('[Writer] Finished %d updates in %d ms (%.1f FPS)', [TOTAL_WRITES, ElapsedMs, Fps]));
  Halt(0);
end;

procedure RunReader(ReaderID: Integer);
var
  ReadCount, TornCount, RetryCount: UInt64;
  StartSeq: UInt64;
  Pos, Dur, SpecSeq: UInt32;
  Vol, ExpectedVol, ExpectedMag, ExpectedPeak: Single;
  LocalMags: TLocalMags;
  LocalPeaks: TLocalPeaks;
  LocalTitle: TLocalTitle;
  b: Integer;
  IsTorn: Boolean;
  ExpectedTitle: string;
begin
  ReadCount := 0;
  TornCount := 0;
  RetryCount := 0;

  // Unthrottled tight polling loop until writer completes
  while pShm^.PositionMs < TOTAL_WRITES do
  begin
    repeat
      StartSeq := SeqLockReadBegin(pShm^.SeqLock);

      Pos := pShm^.PositionMs;
      Dur := pShm^.DurationMs;
      SpecSeq := pShm^.SpectrumSeq;
      Vol := pShm^.Volume;
      Move(pShm^.SpectrumMags[0], LocalMags[0], SizeOf(LocalMags));
      Move(pShm^.SpectrumPeaks[0], LocalPeaks[0], SizeOf(LocalPeaks));
      Move(pShm^.TrackTitle[0], LocalTitle[0], 16);

      if SeqLockReadRetry(pShm^.SeqLock, StartSeq) then
      begin
        Inc(RetryCount);
        Continue;
      end;
      Break;
    until False;

    Inc(ReadCount);

    if Pos > 0 then
    begin
      IsTorn := False;

      // Invariant 1: DurationMs = Pos * 2
      if Dur <> Pos * 2 then
        IsTorn := True;

      // Invariant 2: SpectrumSeq = Pos
      if SpecSeq <> Pos then
        IsTorn := True;

      // Invariant 3: Volume
      ExpectedVol := Single((Pos mod 1000) / 1000.0);
      if Abs(Vol - ExpectedVol) > 0.0001 then
        IsTorn := True;

      // Invariant 4: SpectrumMags & SpectrumPeaks
      for b := 0 to 63 do
      begin
        ExpectedMag := Single((Pos + b) mod 1000);
        if LocalMags[b] <> ExpectedMag then
        begin
          IsTorn := True;
          Break;
        end;

        ExpectedPeak := Single(((Pos * 3) + b) mod 1000);
        if LocalPeaks[b] <> ExpectedPeak then
        begin
          IsTorn := True;
          Break;
        end;
      end;

      // Invariant 5: TrackTitle
      ExpectedTitle := Format('Track_%08d', [Pos]);
      if StrLComp(PAnsiChar(@LocalTitle[0]), PAnsiChar(ExpectedTitle), Length(ExpectedTitle)) <> 0 then
        IsTorn := True;

      if IsTorn then
        Inc(TornCount);
    end;
  end;

  WriteLn(Format('[Reader %d] Done: Reads=%d, Retries=%d, TornReads=%d', [ReaderID, ReadCount, RetryCount, TornCount]));
  if TornCount > 0 then
    Halt(2)
  else
    Halt(0);
end;

begin
  WriteLn('=== Empirical Stress Test: 8-Reader Heavy Contention with Invariant Verification ===');

  UnlinkSharedMemory(TEST_SHM_NAME);
  pShm := CreateSharedMemory(TEST_SHM_NAME);
  if pShm = nil then
  begin
    WriteLn('FATAL: CreateSharedMemory failed');
    Halt(1);
  end;

  // Set 30-second watchdog
  fpAlarm(30);

  // Fork 8 unthrottled readers
  for i := 1 to NUM_READERS do
  begin
    ReaderPIDs[i] := fpFork;
    if ReaderPIDs[i] = 0 then
      RunReader(i);
  end;

  // Fork 1 unthrottled writer
  WriterPID := fpFork;
  if WriterPID = 0 then
    RunWriter;

  // Wait for writer
  fpWaitPID(WriterPID, Status, 0);
  WriteLn('[Parent] Writer finished with status: ', Status);
  if Status <> 0 then Halt(1);

  // Wait for all 8 readers
  for i := 1 to NUM_READERS do
  begin
    fpWaitPID(ReaderPIDs[i], Status, 0);
    WriteLn(Format('[Parent] Reader %d finished with status: %d', [i, Status]));
    if Status <> 0 then
    begin
      WriteLn(Format('FATAL: Reader %d failed with status %d', [i, Status]));
      Halt(2);
    end;
  end;

  CloseSharedMemory(pShm);
  UnlinkSharedMemory(TEST_SHM_NAME);

  WriteLn('SUCCESS: 8 readers under unthrottled contention completed with ZERO TORN READS!');
end.
