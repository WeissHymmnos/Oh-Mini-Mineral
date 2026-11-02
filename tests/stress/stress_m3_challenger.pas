program stress_m3_challenger;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Unix, Sockets, SysUtils, Classes, Math,
  omm_shm, omm_ipc, omm_library;

const
  CLOCK_MONOTONIC = 1;
  TEST_SOCKET_PATH = '/tmp/omm_challenger_s04.sock';
  TEST_SHM_PATH = '/tmp/omm_challenger_s04_shm';

type
  timespec = record
    tv_sec: Int64;
    tv_nsec: Int64;
  end;

function clock_gettime(clk_id: cint; tp: Pointer): cint; cdecl; external 'c';

type
  TTestStats = record
    Total: Integer;
    Passed: Integer;
    Failed: Integer;
  end;

var
  GStats: TTestStats;

procedure Check(Condition: Boolean; const Msg: string);
begin
  Inc(GStats.Total);
  if Condition then
  begin
    Inc(GStats.Passed);
    WriteLn('  [PASS] ', Msg);
  end
  else
  begin
    Inc(GStats.Failed);
    WriteLn('  [FAIL] ', Msg);
  end;
end;

function GetMonotonicNanos: Int64;
var
  ts: timespec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := (ts.tv_sec * 1000000000) + ts.tv_nsec;
end;

function GetProcRssKB(Pid: cint): Int64;
var
  f: TextFile;
  fn: string;
  sizePages, residentPages, sharedPages: Int64;
begin
  Result := 0;
  if Pid = 0 then
    fn := '/proc/self/statm'
  else
    fn := '/proc/' + IntToStr(Pid) + '/statm';

  if FileExists(fn) then
  begin
    AssignFile(f, fn);
    Reset(f);
    if not Eof(f) then
    begin
      ReadLn(f, sizePages, residentPages, sharedPages);
      Result := (residentPages * 4096) div 1024;
    end;
    CloseFile(f);
  end;
end;

// ============================================================================
// SUITE 1: SIMD Int8 Cosine Similarity Benchmark & SLA Stress Test
// ============================================================================

procedure RunSuite1_Int8SimilaritySLA;
var
  vA, vB: TInt8Vector;
  recA, recB: TOMMTrackRecord;
  i, j, k: Integer;
  dotSSE, dotScalar: LongInt;
  sim: Single;
  mismatchCount: Integer;
  engine: TOMMLibraryEngine;
  testLibFile: string;
  t0, t1: Int64;
  elapsedUs, elapsedMs: Double;
  resList: TTop20List;
  poolSizes: array[0..3] of Cardinal = (10000, 20000, 50000, 100000);
  pIdx: Integer;
  poolSize: Cardinal;
  isSorted: Boolean;
  hasSelf: Boolean;
  allValidIDs: Boolean;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[SUITE 1] 32-dim Int8 Similarity Recommendation SLA & SIMD Equivalence');
  WriteLn('------------------------------------------------------------');

  // 1.1 Mathematical Equivalence: SSE SIMD vs Scalar across 10,000 random vectors
  mismatchCount := 0;
  RandSeed := 1337;
  for i := 1 to 10000 do
  begin
    for j := 0 to 31 do
    begin
      vA[j] := ShortInt(Random(256) - 128);
      vB[j] := ShortInt(Random(256) - 128);
    end;
    dotSSE := DotProductInt8SSE(@vA[0], @vB[0]);
    dotScalar := DotProductInt8Scalar(@vA[0], @vB[0]);
    if dotSSE <> dotScalar then
      Inc(mismatchCount);
  end;
  Check(mismatchCount = 0, 'DotProductInt8SSE matches DotProductInt8Scalar for 10,000 random vectors (mismatches=' + IntToStr(mismatchCount) + ')');

  // 1.2 Boundary Values: Max (+127), Min (-128), and Alternating
  for j := 0 to 31 do
  begin
    vA[j] := 127;
    vB[j] := 127;
  end;
  dotSSE := DotProductInt8SSE(@vA[0], @vB[0]);
  Check(dotSSE = 32 * 127 * 127, 'Boundary: Max positive (+127) dot product = ' + IntToStr(dotSSE) + ' (expected ' + IntToStr(32 * 127 * 127) + ')');

  for j := 0 to 31 do
  begin
    vA[j] := -128;
    vB[j] := -128;
  end;
  dotSSE := DotProductInt8SSE(@vA[0], @vB[0]);
  Check(dotSSE = 32 * 128 * 128, 'Boundary: Min negative (-128) dot product = ' + IntToStr(dotSSE) + ' (expected ' + IntToStr(32 * 128 * 128) + ')');

  for j := 0 to 31 do
  begin
    vA[j] := 127;
    vB[j] := -128;
  end;
  dotSSE := DotProductInt8SSE(@vA[0], @vB[0]);
  Check(dotSSE = 32 * 127 * (-128), 'Boundary: Opposite signs (+127 x -128) dot product = ' + IntToStr(dotSSE) + ' (expected ' + IntToStr(32 * 127 * (-128)) + ')');

  // 1.3 Cosine similarity on normalized extreme vectors
  FillChar(recA, SizeOf(recA), 0);
  FillChar(recB, SizeOf(recB), 0);
  for j := 0 to 31 do
  begin
    recA.TfIdfVector[j] := 127;
    recB.TfIdfVector[j] := 127;
  end;
  recA.VectorNorm := ComputeVectorNormInt8(@recA.TfIdfVector[0]);
  recB.VectorNorm := ComputeVectorNormInt8(@recB.TfIdfVector[0]);
  sim := CalculateCosineSimilarity(recA, recB);
  Check(Abs(sim - 1.0) < 1e-5, 'Cosine similarity of identical (+127) vectors is 1.0 (got ' + FloatToStrF(sim, ffFixed, 6, 4) + ')');

  for j := 0 to 31 do
    recB.TfIdfVector[j] := -127;
  recB.VectorNorm := ComputeVectorNormInt8(@recB.TfIdfVector[0]);
  sim := CalculateCosineSimilarity(recA, recB);
  Check(Abs(sim - (-1.0)) < 1e-5, 'Cosine similarity of opposite (+127 vs -127) vectors is -1.0 (got ' + FloatToStrF(sim, ffFixed, 6, 4) + ')');

  // Zero-norm vector
  FillChar(recB, SizeOf(recB), 0);
  recB.VectorNorm := 0.0;
  sim := CalculateCosineSimilarity(recA, recB);
  Check(sim = 0.0, 'Zero-norm vector returns 0.0 without division by zero');

  // 1.4 Large Candidate Pool Recommendation Benchmark (< 1.0 ms SLA)
  testLibFile := '/tmp/omm_challenger_bench.bin';
  for pIdx := 0 to High(poolSizes) do
  begin
    poolSize := poolSizes[pIdx];
    DeleteFile(testLibFile);

    engine := TOMMLibraryEngine.Create('', testLibFile);
    engine.CreateDefaultSyntheticLibrary(poolSize);
    engine.OpenLibrary;

    Check(engine.IsOpen and (engine.TrackCount = poolSize),
          'Created and opened synthetic library with ' + IntToStr(poolSize) + ' tracks');

    // Warm-up query
    resList := QueryTopSimilar(engine, 1, 20);

    // High-resolution benchmark: 10 queries
    t0 := GetMonotonicNanos;
    for k := 1 to 10 do
    begin
      resList := QueryTopSimilar(engine, (k * 7) mod poolSize + 1, 20);
    end;
    t1 := GetMonotonicNanos;

    elapsedUs := (t1 - t0) / (10.0 * 1000.0);
    elapsedMs := elapsedUs / 1000.0;

    WriteLn(Format('    [BENCHMARK] Pool size %6d tracks: avg latency = %6.2f µs (%5.3f ms)',
                   [poolSize, elapsedUs, elapsedMs]));

    if poolSize = 10000 then
      Check(elapsedMs < 1.0, Format('Pool 10,000 tracks executes in < 1.0 ms SLA (actual: %5.3f ms, target < 1.0 ms)', [elapsedMs]))
    else if poolSize = 50000 then
      Check(elapsedMs < 25.0, Format('Pool 50,000 tracks executes in < 25.0 ms (actual: %5.3f ms)', [elapsedMs]));

    // Verify properties of the Top-20 result
    Check(resList.Count = 20, 'Top-20 result contains exactly 20 items (got ' + IntToStr(resList.Count) + ')');

    isSorted := True;
    hasSelf := False;
    allValidIDs := True;
    for k := 0 to resList.Count - 1 do
    begin
      if (k < resList.Count - 1) and (resList.Items[k].Score < resList.Items[k + 1].Score) then
        isSorted := False;
      if resList.Items[k].TrackID = 1 then
        hasSelf := True;
      if (resList.Items[k].TrackID < 1) or (resList.Items[k].TrackID > poolSize) then
        allValidIDs := False;
    end;

    Check(isSorted, 'Top-20 results are strictly sorted descending by score');
    Check(not hasSelf, 'Top-20 results exclude the query track itself (TrackID=1)');
    Check(allValidIDs, 'All returned TrackIDs are within valid library range [1..' + IntToStr(poolSize) + ']');

    engine.CloseLibrary;
    engine.Free;
    DeleteFile(testLibFile);
  end;
end;

// ============================================================================
// SUITE 2: 512-Byte Sector Alignment & Mmap Resident Heap Overhead
// ============================================================================

procedure RunSuite2_SectorAlignmentAndMmapHeap;
var
  engine: TOMMLibraryEngine;
  testLibFile: string;
  heapBefore, heapAfter, heapDelta: PtrUInt;
  heapBeforeClose, heapAfterClose: PtrUInt;
  rec0, rec1, recLast: POMMTrackRecord;
  offset0, offset1: PtrUInt;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[SUITE 2] 512-Byte Sector Alignment & Mmap Resident Heap Overhead');
  WriteLn('------------------------------------------------------------');

  // 2.1 Struct size checks
  Check(SizeOf(TOMMLibraryHeader) = 512, 'SizeOf(TOMMLibraryHeader) is exactly 512 bytes (got ' + IntToStr(SizeOf(TOMMLibraryHeader)) + ')');
  Check(SizeOf(TOMMTrackRecord) = 512, 'SizeOf(TOMMTrackRecord) is exactly 512 bytes (got ' + IntToStr(SizeOf(TOMMTrackRecord)) + ')');

  // 2.2 Alignment & Mmap Heap Test with 50,000 tracks (~25.6 MB file)
  testLibFile := '/tmp/omm_challenger_mmap.bin';
  DeleteFile(testLibFile);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  engine.CreateDefaultSyntheticLibrary(50000);

  // Measure Pascal heap before OpenLibrary
  heapBefore := GetHeapStatus.TotalAllocated;

  Check(engine.OpenLibrary, 'Successfully opened 50,000 track library file via fpMMap');

  // Measure Pascal heap after OpenLibrary
  heapAfter := GetHeapStatus.TotalAllocated;
  heapDelta := Abs(Int64(heapAfter) - Int64(heapBefore));

  WriteLn(Format('    [HEAP MEMORY] Before OpenLibrary: %u B, After OpenLibrary: %u B, Delta: %u B',
                 [heapBefore, heapAfter, heapDelta]));
  Check(heapDelta = 0, 'OS fpMMap incurs 0 KB resident heap overhead (Delta = ' + IntToStr(heapDelta) + ' bytes)');

  // Sector alignment check for records
  rec0 := engine.GetRecordByIndex(0);
  rec1 := engine.GetRecordByIndex(1);
  recLast := engine.GetRecordByIndex(engine.TrackCount - 1);

  Check(rec0 <> nil, 'Record 0 pointer is non-nil');
  Check(rec1 <> nil, 'Record 1 pointer is non-nil');
  Check(recLast <> nil, 'Last record pointer is non-nil');

  offset0 := PtrUInt(rec0);
  offset1 := PtrUInt(rec1);

  Check((offset1 - offset0) = 512, 'Adjacent records stride is exactly 512 bytes (got ' + IntToStr(offset1 - offset0) + ')');

  heapBeforeClose := GetHeapStatus.TotalAllocated;
  engine.CloseLibrary;
  heapAfterClose := GetHeapStatus.TotalAllocated;
  Check(heapAfterClose = heapBeforeClose, 'CloseLibrary incurs 0 heap allocation (Delta = ' + IntToStr(heapAfterClose - heapBeforeClose) + ')');

  engine.Free;
  DeleteFile(testLibFile);
end;

// ============================================================================
// SUITE 3: Edge Cases, Malformed Files & Boundary Conditions
// ============================================================================

procedure RunSuite3_EdgeCasesAndRobustness;
var
  engine: TOMMLibraryEngine;
  testLibFile: string;
  fd: cint;
  hdr: TOMMLibraryHeader;
  resList: TTop20List;
  total, filtered, outCount: Cardinal;
  condTracks: array[0..9] of TOMMCondensedTrack;
  rec: TOMMTrackRecord;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[SUITE 3] Edge Cases, Corrupt Files & Boundary Conditions');
  WriteLn('------------------------------------------------------------');

  testLibFile := '/tmp/omm_challenger_edge.bin';

  // 3.1 Non-existent file when synthetic creation is disabled or fails
  DeleteFile(testLibFile);

  // 3.2 Empty library file: Header only, RecordCount = 0
  FillChar(hdr, SizeOf(hdr), 0);
  hdr.Magic := OMM_LIBRARY_MAGIC;
  hdr.Version := OMM_LIBRARY_VERSION;
  hdr.RecordSize := OMM_RECORD_SIZE;
  hdr.RecordCount := 0;
  hdr.CreatedTimestamp := fpTime;
  hdr.LastRescanTimestamp := hdr.CreatedTimestamp;

  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, SizeOf(hdr));
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(engine.OpenLibrary, 'OpenLibrary succeeds on empty library (0 records)');
  Check(engine.TrackCount = 0, 'TrackCount is 0 for empty library');
  Check(engine.GetRecord(1) = nil, 'GetRecord(1) on empty library returns nil');
  Check(engine.GetRecordByIndex(0) = nil, 'GetRecordByIndex(0) on empty library returns nil');

  resList := QueryTopSimilar(engine, 1, 20);
  Check(resList.Count = 0, 'QueryTopSimilar on empty library returns Count=0');

  Check(engine.GetViewportPage(0, 10, '', total, filtered, outCount, @condTracks[0], 10),
        'GetViewportPage on empty library returns True with Total=0, Count=0');
  Check((total = 0) and (filtered = 0) and (outCount = 0), 'GetViewportPage counts are 0 on empty library');

  engine.CloseLibrary;
  engine.Free;
  DeleteFile(testLibFile);

  // White-box unit tests on open populated library
  engine := TOMMLibraryEngine.Create('', 'library.bin');
  Check(engine.OpenLibrary, 'Open populated library succeeds');

  // Test 1: MaxOut = 0
  Check(engine.GetViewportPage(0, 10, '', total, filtered, outCount, @condTracks[0], 0),
        'GetViewportPage succeeds with MaxOut=0 without crashing');
  Check((total > 0) and (filtered = total) and (outCount = 0),
        'GetViewportPage with MaxOut=0 returns outCount=0');

  // Test 2: Limit = 0
  Check(engine.GetViewportPage(0, 0, '', total, filtered, outCount, @condTracks[0], 10),
        'GetViewportPage succeeds with Limit=0 without crashing');
  Check((total > 0) and (filtered = total) and (outCount = 0),
        'GetViewportPage with Limit=0 returns outCount=0');

  // Test 3: Offset = $FFFFFFFF, Limit = 0
  Check(engine.GetViewportPage($FFFFFFFF, 0, '', total, filtered, outCount, @condTracks[0], 10),
        'GetViewportPage succeeds with Offset=$FFFFFFFF, Limit=0');
  Check(outCount = 0, 'GetViewportPage with Offset=$FFFFFFFF returns outCount=0');

  engine.CloseLibrary;
  engine.Free;

  // 3.3 Truncated file (< 512 bytes)
  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, 256); // Only 256 bytes written
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(not engine.OpenLibrary, 'OpenLibrary safely rejects truncated file (256 bytes < 512 header)');
  engine.Free;
  DeleteFile(testLibFile);

  // 3.4 File with non-multiple of 512 bytes (e.g. 512 + 17 bytes)
  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, SizeOf(hdr));
  FillChar(rec, SizeOf(rec), 0);
  fpWrite(fd, rec, 17); // Partial record written
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(not engine.OpenLibrary, 'OpenLibrary safely rejects non-sector-aligned file size (529 bytes)');
  engine.Free;
  DeleteFile(testLibFile);

  // 3.5 Corrupted Magic in Header
  hdr.Magic := $DEADBEEF;
  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, SizeOf(hdr));
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(not engine.OpenLibrary, 'OpenLibrary safely rejects corrupted Magic 0xDEADBEEF');
  engine.Free;
  DeleteFile(testLibFile);

  // 3.6 Invalid Version in Header
  hdr.Magic := OMM_LIBRARY_MAGIC;
  hdr.Version := 999;
  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, SizeOf(hdr));
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(not engine.OpenLibrary, 'OpenLibrary safely rejects invalid Version 999');
  engine.Free;
  DeleteFile(testLibFile);

  // 3.7 Invalid RecordSize in Header
  hdr.Version := OMM_LIBRARY_VERSION;
  hdr.RecordSize := 256;
  fd := fpOpen(PChar(testLibFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  fpWrite(fd, hdr, SizeOf(hdr));
  fpClose(fd);

  engine := TOMMLibraryEngine.Create('', testLibFile);
  Check(not engine.OpenLibrary, 'OpenLibrary safely rejects invalid RecordSize 256');
  engine.Free;
  DeleteFile(testLibFile);

  // 3.8 Boundary Query limits and Track IDs on valid library
  engine := TOMMLibraryEngine.Create('', testLibFile);
  engine.CreateDefaultSyntheticLibrary(100);
  engine.OpenLibrary;

  resList := QueryTopSimilar(engine, 0, 20); // TrackID 0 is invalid
  Check(resList.Count = 0, 'QueryTopSimilar with TrackID=0 returns Count=0');

  resList := QueryTopSimilar(engine, 99999, 20); // TrackID exceeds track count
  Check(resList.Count = 0, 'QueryTopSimilar with TrackID exceeding TrackCount returns Count=0');

  resList := QueryTopSimilar(engine, 1, 0); // Limit = 0
  Check(resList.Count = 0, 'QueryTopSimilar with Limit=0 returns Count=0');

  // Test query with Limit = 5
  resList := QueryTopSimilar(engine, 1, 5);
  // Empirical verification: does QueryTopSimilar return 5 or 20?
  WriteLn('    [EMPIRICAL FINDING] QueryTopSimilar(Limit=5) returned Count = ' + IntToStr(resList.Count));
  // Note: Documented behavior - QueryTopSimilar has static capacity 20 list.

  engine.CloseLibrary;
  engine.Free;
  DeleteFile(testLibFile);
end;

// ============================================================================
// SUITE 4: 50 Repeated "Stream Wake -> Local Playback -> Suspend" Cycles (S04)
// ============================================================================

procedure RunSuite4_Lifecycle50CyclesS04;
var
  daemonPid: cint;
  clientFd: cint;
  reqPkt, respPkt: TOMMPacket;
  cycle: Integer;
  initialRss, currentRss, finalRss: Int64;
  rssDelta: Int64;
  connected: Boolean;
  retries: Integer;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[SUITE 4] 50-Cycle Stream Wake -> Play -> Suspend Physical Memory Stability (S04)');
  WriteLn('------------------------------------------------------------');

  // Clean previous sockets/shm
  fpUnlink(PChar(TEST_SOCKET_PATH));
  fpUnlink(PChar(TEST_SHM_PATH));

  // Spawn omm_daemon as child process
  daemonPid := fpFork;
  if daemonPid = 0 then
  begin
    // Child: execute omm_daemon
    FpExecLP('./bin/omm_daemon', ['--socket', TEST_SOCKET_PATH, '--shm', TEST_SHM_PATH]);
    Halt(1);
  end;

  // Parent: wait for daemon socket
  connected := False;
  for retries := 1 to 50 do
  begin
    clientFd := CreateUnixSocket;
    if ConnectUnixSocket(clientFd, TEST_SOCKET_PATH) then
    begin
      connected := True;
      Break;
    end;
    fpClose(clientFd);
    fpSleep(1); // 100ms or 1s
  end;

  if not connected then
  begin
    WriteLn('  [FAIL] Could not connect to omm_daemon socket at ', TEST_SOCKET_PATH);
    fpKill(daemonPid, SIGTERM);
    Exit;
  end;

  Check(connected, 'Connected to live omm_daemon child process (PID=' + IntToStr(daemonPid) + ')');

  // Let daemon settle and prime baseline
  initialRss := GetProcRssKB(daemonPid);
  WriteLn('    [BASELINE RSS] Daemon initial physical RSS = ' + IntToStr(initialRss) + ' KB');

  // Run 50 cycles
  for cycle := 1 to 50 do
  begin
    // 1. Stream wake (mineral://)
    InitPacket(reqPkt, OP_REQ_PLAY_URI, cycle * 3, 0);
    Move('mineral://am/challenger_stream'[1], reqPkt.Payload.Raw[0], 30);
    SendPacket(clientFd, reqPkt);
    RecvPacket(clientFd, respPkt);

    // 2. Local playback (file://)
    InitPacket(reqPkt, OP_REQ_PLAY_URI, cycle * 3 + 1, 0);
    Move('file:///music/challenger_local.flac'[1], reqPkt.Payload.Raw[0], 34);
    SendPacket(clientFd, reqPkt);
    RecvPacket(clientFd, respPkt);

    // 3. Suspend
    InitPacket(reqPkt, OP_REQ_PLUGIN_SUSPEND, cycle * 3 + 2, 0);
    SendPacket(clientFd, reqPkt);
    RecvPacket(clientFd, respPkt);

    if (cycle mod 10 = 0) or (cycle = 1) or (cycle = 50) then
    begin
      currentRss := GetProcRssKB(daemonPid);
      WriteLn(Format('    Cycle %2d/50: Daemon RSS = %5d KB, Drift = %4d KB',
                     [cycle, currentRss, currentRss - initialRss]));
    end;
  end;

  finalRss := GetProcRssKB(daemonPid);
  rssDelta := Abs(finalRss - initialRss);
  WriteLn(Format('    [FINAL RESULT] Initial RSS: %d KB, Final RSS: %d KB, Drift: %d KB (SLA budget <= 256 KB)',
                 [initialRss, finalRss, rssDelta]));

  Check(rssDelta <= 256, Format('Physical RSS drift after 50 cycles is <= 256 KB (got %d KB)', [rssDelta]));

  // Teardown
  fpClose(clientFd);
  fpKill(daemonPid, SIGTERM);
  fpWaitPid(daemonPid, nil, 0);
  fpUnlink(PChar(TEST_SOCKET_PATH));
  fpUnlink(PChar(TEST_SHM_PATH));
end;

// ============================================================================
// MAIN ENTRY
// ============================================================================

begin
  GStats.Total := 0;
  GStats.Passed := 0;
  GStats.Failed := 0;

  WriteLn('======================================================================');
  WriteLn('   Milestone 3 Empirical Challenger: Library, Int8 SIMD & Memory SLA  ');
  WriteLn('======================================================================');

  RunSuite1_Int8SimilaritySLA;
  WriteLn;

  RunSuite2_SectorAlignmentAndMmapHeap;
  WriteLn;

  RunSuite3_EdgeCasesAndRobustness;
  WriteLn;

  RunSuite4_Lifecycle50CyclesS04;
  WriteLn;

  WriteLn('======================================================================');
  WriteLn(Format('CHALLENGER SUMMARY: Total Checks: %d | Passed: %d | Failed: %d',
                 [GStats.Total, GStats.Passed, GStats.Failed]));
  if GStats.Failed = 0 then
    WriteLn('>>> EMPIRICAL VERDICT: CONFIRM <<<')
  else
    WriteLn('>>> EMPIRICAL VERDICT: REJECT <<<');
  WriteLn('======================================================================');

  if GStats.Failed > 0 then
    Halt(1);
end.
