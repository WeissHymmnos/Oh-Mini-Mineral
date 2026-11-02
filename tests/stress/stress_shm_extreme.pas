program StressSHMExtreme;

{$mode objfpc}{$H+}

uses
  BaseUnix, Unix, SysUtils, omm_shm;

const
  TEST_SHM_NAME = '/omm_stress_shm_extreme';
  TOTAL_WRITES  = 50000;
  NUM_READERS   = 4;

type
  TLocalMags = array[0..63] of Single;

var
  pShm: POMMSharedMemory;
  ReaderPIDs: array[1..NUM_READERS] of TPid;
  WriterPID: TPid;
  i: Integer;
  Status: cint;

function FixedSeqLockReadBegin(constref Seq: UInt64): UInt64;
var
  CurrentSeq: UInt64;
begin
  repeat
    CurrentSeq := Seq;
    while (CurrentSeq and 1) <> 0 do
    begin
      asm
        pause
      end;
      CurrentSeq := Seq;
    end;
    ReadBarrier;
    asm
      lfence
    end;
  until (CurrentSeq and 1) = 0;
  Result := CurrentSeq;
end;

function FixedSeqLockReadRetry(constref Seq: UInt64; StartSeq: UInt64): Boolean;
begin
  ReadBarrier;
  asm
    lfence
  end;
  Result := (Seq <> StartSeq);
end;

procedure RunWriter;
var
  Frame, b: Integer;
  TStart, TEnd: QWord;
  ElapsedMs: Int64;
  Fps: Double;
begin
  TStart := GetTickCount64;
  WriteLn('[Writer] Starting 50,000 updates at extreme unthrottled rate...');
  for Frame := 1 to TOTAL_WRITES do
  begin
    SeqLockWriteBegin(pShm^.SeqLock);
    pShm^.PositionMs := Frame;
    pShm^.Volume := Single((Frame mod 1000) / 1000.0);
    for b := 0 to 63 do
      pShm^.SpectrumMags[b] := Single((Frame + b) mod 1000);
    SeqLockWriteEnd(pShm^.SeqLock);
  end;
  TEnd := GetTickCount64;
  ElapsedMs := TEnd - TStart;
  if ElapsedMs <= 0 then ElapsedMs := 1;
  Fps := (TOTAL_WRITES * 1000.0) / ElapsedMs;
  WriteLn(Format('[Writer] Completed 50,000 updates in %d ms (%.1f FPS)', [ElapsedMs, Fps]));
  Halt(0);
end;

procedure RunReader(ReaderID: Integer);
var
  ReadCount, TornCount, RetryCount: UInt64;
  StartSeq: UInt64;
  Pos: UInt32;
  Vol, ExpectedVol, ExpectedMag: Single;
  LocalMags: TLocalMags;
  b: Integer;
  IsTorn: Boolean;
begin
  ReadCount := 0;
  TornCount := 0;
  RetryCount := 0;

  // Unthrottled tight polling loop
  while pShm^.PositionMs < TOTAL_WRITES do
  begin
    repeat
      StartSeq := FixedSeqLockReadBegin(pShm^.SeqLock);
      Pos := pShm^.PositionMs;
      Vol := pShm^.Volume;
      Move(pShm^.SpectrumMags[0], LocalMags[0], SizeOf(LocalMags));
      if FixedSeqLockReadRetry(pShm^.SeqLock, StartSeq) then
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
      ExpectedVol := Single((Pos mod 1000) / 1000.0);
      if Abs(Vol - ExpectedVol) > 0.0001 then
        IsTorn := True;

      for b := 0 to 63 do
      begin
        ExpectedMag := Single((Pos + b) mod 1000);
        if LocalMags[b] <> ExpectedMag then
        begin
          IsTorn := True;
          Break;
        end;
      end;

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
  WriteLn('=== Extreme Contention SHM Seqlock Stress Test ===');

  UnlinkSharedMemory(TEST_SHM_NAME);
  pShm := CreateSharedMemory(TEST_SHM_NAME);
  if pShm = nil then
  begin
    WriteLn('FATAL: CreateSharedMemory failed');
    Halt(1);
  end;

  // Set 30-second watchdog timer
  fpAlarm(30);

  // Fork 4 readers
  for i := 1 to NUM_READERS do
  begin
    ReaderPIDs[i] := fpFork;
    if ReaderPIDs[i] = 0 then
      RunReader(i);
  end;

  // Fork 1 writer
  WriterPID := fpFork;
  if WriterPID = 0 then
    RunWriter;

  // Wait for writer to finish
  fpWaitPID(WriterPID, Status, 0);
  WriteLn('[Parent] Writer process finished with status: ', Status);

  // Wait for readers
  for i := 1 to NUM_READERS do
  begin
    fpWaitPID(ReaderPIDs[i], Status, 0);
    WriteLn('[Parent] Reader ', i, ' finished with status: ', Status);
    if Status <> 0 then
    begin
      WriteLn('Reader ', i, ' FAILED with status ', Status);
      Halt(1);
    end;
  end;

  CloseSharedMemory(pShm);
  UnlinkSharedMemory(TEST_SHM_NAME);
  WriteLn('SUCCESS: Extreme contention test passed with ZERO TORN READS across all readers!');
end.
