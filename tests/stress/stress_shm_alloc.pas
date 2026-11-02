program StressSHMAlloc;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils, omm_shm;

const
  TEST_SHM_NAME = '/omm_stress_shm_alloc';
  ITERATIONS = 50000;

type
  TLocalReadState = record
    PlaybackState: UInt32;
    PositionMs: UInt32;
    DurationMs: UInt32;
    Volume: Single;
    SpectrumMags: array[0..63] of Single;
  end;

var
  pShm: POMMSharedMemory;
  LocalState: TLocalReadState;
  InitialHeap, SteadyHeapStart, SteadyHeapEnd: SizeUInt;
  i, j: Integer;
  StartSeq: UInt64;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', Msg);
    Halt(1);
  end;
end;

begin
  WriteLn('=== Empirical Test: Steady-State Heap Allocations (50,000 Cycles) ===');

  UnlinkSharedMemory(TEST_SHM_NAME);
  pShm := CreateSharedMemory(TEST_SHM_NAME);
  Check(pShm <> nil, 'CreateSharedMemory failed');

  InitialHeap := GetFPCHeapStatus.CurrHeapUsed;
  WriteLn('Initial Heap Used: ', InitialHeap, ' bytes');

  // Warm-up run
  for i := 1 to 100 do
  begin
    SeqLockWriteBegin(pShm^.SeqLock);
    pShm^.PositionMs := i;
    pShm^.Volume := 0.5;
    for j := 0 to 63 do
      pShm^.SpectrumMags[j] := j * 0.01;
    SeqLockWriteEnd(pShm^.SeqLock);

    repeat
      StartSeq := SeqLockReadBegin(pShm^.SeqLock);
      LocalState.PositionMs := pShm^.PositionMs;
      LocalState.Volume := pShm^.Volume;
      Move(pShm^.SpectrumMags[0], LocalState.SpectrumMags[0], SizeOf(LocalState.SpectrumMags));
    until not SeqLockReadRetry(pShm^.SeqLock, StartSeq);
  end;

  SteadyHeapStart := GetFPCHeapStatus.CurrHeapUsed;
  WriteLn('Steady-State Heap Before ', ITERATIONS, ' Iterations: ', SteadyHeapStart, ' bytes');

  // Perform 50,000 steady-state read & write iterations
  for i := 1 to ITERATIONS do
  begin
    SeqLockWriteBegin(pShm^.SeqLock);
    pShm^.PositionMs := i;
    pShm^.Volume := (i mod 1000) * 0.001;
    for j := 0 to 63 do
      pShm^.SpectrumMags[j] := (i + j) * 0.001;
    SeqLockWriteEnd(pShm^.SeqLock);

    repeat
      StartSeq := SeqLockReadBegin(pShm^.SeqLock);
      LocalState.PositionMs := pShm^.PositionMs;
      LocalState.Volume := pShm^.Volume;
      Move(pShm^.SpectrumMags[0], LocalState.SpectrumMags[0], SizeOf(LocalState.SpectrumMags));
    until not SeqLockReadRetry(pShm^.SeqLock, StartSeq);
  end;

  SteadyHeapEnd := GetFPCHeapStatus.CurrHeapUsed;
  WriteLn('Steady-State Heap After ', ITERATIONS, ' Iterations: ', SteadyHeapEnd, ' bytes');
  WriteLn('Delta Heap: ', PtrInt(SteadyHeapEnd) - PtrInt(SteadyHeapStart), ' bytes');

  Check(SteadyHeapEnd = SteadyHeapStart, 'Steady-state heap delta must be exactly 0 bytes');

  CloseSharedMemory(pShm);
  UnlinkSharedMemory(TEST_SHM_NAME);
  WriteLn('SUCCESS: Zero heap allocations verified over 50,000 steady-state iterations!');
end.
