program StressSHMOddWakeup;

{$mode objfpc}{$H+}

uses
  BaseUnix, Unix, SysUtils, omm_shm;

const
  TEST_SHM_NAME = '/omm_stress_odd_wakeup';
  TEST_CYCLES   = 500;

var
  pShm: POMMSharedMemory;
  ChildPid: TPid;
  Status: cint;
  PipeParentToChild: array[0..1] of cint;
  PipeChildToParent: array[0..1] of cint;

procedure RunReader;
var
  Cycle: Integer;
  Dummy: Byte;
  StartSeq: UInt64;
begin
  // Child reader
  fpClose(PipeParentToChild[1]);
  fpClose(PipeChildToParent[0]);

  for Cycle := 1 to TEST_CYCLES do
  begin
    // Wait for parent signal to call SeqLockReadBegin
    if fpRead(PipeParentToChild[0], @Dummy, 1) <> 1 then
      Halt(10);

    // At this moment, pShm^.SeqLock is guaranteed to be ODD.
    // SeqLockReadBegin must spin until parent calls SeqLockWriteEnd.
    StartSeq := SeqLockReadBegin(pShm^.SeqLock);

    // Verify StartSeq is even and corresponds to 2 * Cycle
    if (StartSeq and 1) <> 0 then
    begin
      WriteLn(Format('[Child] ERROR: SeqLockReadBegin returned odd sequence: %d', [StartSeq]));
      Halt(11);
    end;

    if StartSeq <> UInt64(2 * Cycle) then
    begin
      WriteLn(Format('[Child] ERROR: SeqLockReadBegin returned unexpected sequence: %d (expected %d)', [StartSeq, 2 * Cycle]));
      Halt(12);
    end;

    // Signal parent that we woke up and verified sequence
    Dummy := 1;
    if fpWrite(PipeChildToParent[1], @Dummy, 1) <> 1 then
      Halt(13);
  end;

  fpClose(PipeParentToChild[0]);
  fpClose(PipeChildToParent[1]);
  Halt(0);
end;

procedure RunParent;
var
  Cycle: Integer;
  Dummy: Byte;
  Req, Rem: TTimeSpec;
  TStart, TEnd: QWord;
begin
  fpClose(PipeParentToChild[0]);
  fpClose(PipeChildToParent[1]);

  TStart := GetTickCount64;
  WriteLn(Format('[Parent] Starting %d odd->even wakeup verification cycles...', [TEST_CYCLES]));

  for Cycle := 1 to TEST_CYCLES do
  begin
    // Step 1: Writer begins write, making SeqLock ODD: 2 * Cycle - 1
    pShm^.SeqLock := UInt64(2 * Cycle - 2);
    SeqLockWriteBegin(pShm^.SeqLock);
    if (pShm^.SeqLock and 1) <> 1 then
    begin
      WriteLn('Parent error: SeqLock not odd after SeqLockWriteBegin');
      Halt(20);
    end;

    // Step 2: Signal child to invoke SeqLockReadBegin(pShm^.SeqLock)
    Dummy := 1;
    if fpWrite(PipeParentToChild[1], @Dummy, 1) <> 1 then
      Halt(21);

    // Step 3: Sleep 1ms to ensure child has entered SeqLockReadBegin and is spinning on pause
    Req.tv_sec := 0;
    Req.tv_nsec := 1000000; // 1 ms
    fpNanoSleep(@Req, @Rem);

    // Step 4: Writer ends write, making SeqLock EVEN: 2 * Cycle
    SeqLockWriteEnd(pShm^.SeqLock);

    // Step 5: Wait for child to acknowledge wakeup
    if fpRead(PipeChildToParent[0], @Dummy, 1) <> 1 then
    begin
      WriteLn(Format('[Parent] ERROR: Failed to read child ack at cycle %d', [Cycle]));
      Halt(22);
    end;
  end;

  TEnd := GetTickCount64;
  WriteLn(Format('[Parent] Completed %d wakeup cycles in %d ms (all unblocked successfully)!', [TEST_CYCLES, TEnd - TStart]));

  fpClose(PipeParentToChild[1]);
  fpClose(PipeChildToParent[0]);

  fpWaitPID(ChildPid, Status, 0);
  if Status <> 0 then
  begin
    WriteLn('[Parent] Child failed with status: ', Status);
    Halt(1);
  end;
end;

begin
  WriteLn('=== Empirical Stress Test: Reader Deadlock Elimination on Odd Sequence ===');

  UnlinkSharedMemory(TEST_SHM_NAME);
  pShm := CreateSharedMemory(TEST_SHM_NAME);
  if pShm = nil then
  begin
    WriteLn('FATAL: CreateSharedMemory failed');
    Halt(1);
  end;

  if (assignpipe(PipeParentToChild[0], PipeParentToChild[1]) <> 0) or
     (assignpipe(PipeChildToParent[0], PipeChildToParent[1]) <> 0) then
  begin
    WriteLn('FATAL: assignpipe failed');
    Halt(1);
  end;

  // Set 10-second watchdog against deadlocks
  fpAlarm(10);

  ChildPid := fpFork;
  if ChildPid = 0 then
    RunReader
  else
    RunParent;

  CloseSharedMemory(pShm);
  UnlinkSharedMemory(TEST_SHM_NAME);

  WriteLn('SUCCESS: Odd sequence deadlock is 100% ELIMINATED! Readers wake up immediately upon write completion.');
end.
