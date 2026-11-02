program StressSeqLockWrap;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils, omm_shm;

var
  Seq: UInt64;
  StartSeq: UInt64;
  Retry: Boolean;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', Msg);
    Halt(1);
  end;
end;

begin
  WriteLn('=== Empirical Test: 64-bit Atomic Seqlock Counter Wrap-Around ===');

  // Test 1: Wrap around High(Int64) ($7FFFFFFFFFFFFFFF -> $8000000000000000)
  Seq := UInt64($7FFFFFFFFFFFFFFE); // even
  WriteLn('[1] Starting near High(Int64): Seq = $', HexStr(Seq, 16));
  
  SeqLockWriteBegin(Seq);
  WriteLn('  After WriteBegin: Seq = $', HexStr(Seq, 16));
  Check(Seq = UInt64($7FFFFFFFFFFFFFFF), 'WriteBegin reached $7FFFFFFFFFFFFFFF (odd)');
  Check((Seq and 1) = 1, 'Seq is odd');

  SeqLockWriteEnd(Seq);
  WriteLn('  After WriteEnd: Seq = $', HexStr(Seq, 16));
  Check(Seq = UInt64($8000000000000000), 'WriteEnd wrapped into $8000000000000000 (even)');
  Check((Seq and 1) = 0, 'Seq is even');

  // Test 2: Wrap around High(UInt64) ($FFFFFFFFFFFFFFFF -> 0)
  Seq := UInt64($FFFFFFFFFFFFFFFE); // even
  WriteLn('[2] Starting near High(UInt64): Seq = $', HexStr(Seq, 16));

  SeqLockWriteBegin(Seq);
  WriteLn('  After WriteBegin: Seq = $', HexStr(Seq, 16));
  Check(Seq = UInt64($FFFFFFFFFFFFFFFF), 'WriteBegin reached $FFFFFFFFFFFFFFFF (odd)');
  Check((Seq and 1) = 1, 'Seq is odd');

  SeqLockWriteEnd(Seq);
  WriteLn('  After WriteEnd: Seq = $', HexStr(Seq, 16));
  Check(Seq = 0, 'WriteEnd wrapped to 0 (even)');
  Check((Seq and 1) = 0, 'Seq is even (0)');

  // Test 3: Read Retry behavior across wrap-around
  StartSeq := UInt64($FFFFFFFFFFFFFFFE);
  Seq := 0;
  Retry := SeqLockReadRetry(Seq, StartSeq);
  WriteLn('[3] Read retry across wrap: StartSeq = $', HexStr(StartSeq, 16), ', CurrentSeq = 0, Retry = ', Retry);
  Check(Retry = True, 'Retry must be True when Seq wrapped across transaction');

  WriteLn('SUCCESS: All 64-bit wrap-around assertions passed!');
end.
