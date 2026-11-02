program StressSeqLockHangMinimal;

{$mode objfpc}{$H+}

uses
  BaseUnix, Unix, SysUtils, omm_shm;

var
  OddSeq: UInt64;
  Res: UInt64;

begin
  WriteLn('=== Minimal Empirical POC: SeqLockReadBegin Hang on Odd Sequence ===');
  OddSeq := 1; // odd sequence (write in progress)
  
  // Set alarm for 1 second: if it deadlocks, SIGALRM will terminate with code 142
  fpAlarm(1);
  WriteLn('Calling SeqLockReadBegin(OddSeq = 1)...');
  Res := SeqLockReadBegin(OddSeq);
  WriteLn('Unexpected success: ', Res);
end.
