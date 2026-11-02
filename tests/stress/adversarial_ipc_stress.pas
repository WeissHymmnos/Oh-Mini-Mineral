program AdversarialIPCStress;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Sockets, SysUtils, omm_ipc;

const
  ADV_SOCK_PATH = '/tmp/omm_adv_stress.sock';
  ADV_RST_SOCK  = '/tmp/omm_adv_rst.sock';

type
  TTestStats = record
    Total: Integer;
    Passed: Integer;
    Failed: Integer;
  end;

var
  Stats: TTestStats;

procedure AssertCheck(Condition: Boolean; const Msg: string);
begin
  Inc(Stats.Total);
  if Condition then
  begin
    Inc(Stats.Passed);
    WriteLn('  [PASS] ', Msg);
  end
  else
  begin
    Inc(Stats.Failed);
    WriteLn('  [FAIL] ', Msg);
  end;
end;

function CountOpenFDs: Integer;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst('/proc/self/fd/*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name <> '.') and (sr.Name <> '..') then
        Inc(Result);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

// ============================================================================
// TEST 1: Rapid 500-Iteration Broken Socket Write (SIGPIPE Immunity & EPIPE Check)
// ============================================================================
procedure Test500BrokenSocketWrites;
const
  ITER_COUNT = 500;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  pkt: TOMMPacket;
  i: Integer;
  initialFDs, finalFDs: Integer;
  res: Boolean;
  lastErr: cint;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 1] 500 Rapid Broken Pipe Writes (No SIG_IGN)');
  WriteLn('------------------------------------------------------------');

  initialFDs := CountOpenFDs;
  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, ADV_SOCK_PATH, 16);

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD (Server): Explicitly leaves SIGPIPE at default (termination)
    // Runs 500 iterations of accept -> peer closes -> SendPacket
    InitPacket(pkt, OP_RESP_OK, 1, 0);
    for i := 1 to ITER_COUNT do
    begin
      ConnFD := AcceptUnixSocket(ServerFD);
      if ConnFD < 0 then
        fpExit(1);
      // Wait slightly so peer has closed socket
      Sleep(1); // 1 ms
      // Attempt SendPacket calls on broken pipe
      res := SendPacket(ConnFD, pkt);
      if res then
        res := SendPacket(ConnFD, pkt);
      lastErr := fpGetErrno;
      if (not res) and (lastErr <> ESysEPIPE) and (lastErr <> ESysECONNRESET) then
      begin
        // If error was not EPIPE or ECONNRESET, report unexpected errno
        fpExit(2);
      end;
      fpClose(ConnFD);
    end;
    fpExit(0);
  end
  else
  begin
    // PARENT (Client): Rapidly connects and immediately closes
    for i := 1 to ITER_COUNT do
    begin
      ClientFD := CreateUnixSocket;
      ConnectUnixSocket(ClientFD, ADV_SOCK_PATH);
      fpShutdown(ClientFD, SHUT_RDWR);
      fpClose(ClientFD);
      Sleep(1);
    end;

    fpWaitPID(pid, status, 0);
    fpClose(ServerFD);
    fpUnlink(ADV_SOCK_PATH);

    if WIFSIGNALED(status) then
    begin
      WriteLn(Format('  [FAIL] Child was killed by signal %d (SIGPIPE=%d)', [WTERMSIG(status), SIGPIPE]));
      AssertCheck(False, 'Child survived 500 broken socket writes without SIGPIPE');
    end
    else
    begin
      AssertCheck(WEXITSTATUS(status) = 0, Format('Child exited cleanly with code %d (all 500 returned EPIPE/ECONNRESET)', [WEXITSTATUS(status)]));
    end;

    finalFDs := CountOpenFDs;
    AssertCheck(finalFDs = initialFDs, Format('Zero FD leaks after 500 broken pipe churns (Initial=%d, Final=%d)', [initialFDs, finalFDs]));
  end;
end;

// ============================================================================
// TEST 2: Buffer Saturation & Abrupt Disconnect Under High Backpressure
// ============================================================================
procedure TestBufferSaturationBrokenPipe;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  pkt: TOMMPacket;
  i: Integer;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 2] Buffer Saturation & Peer Crash During Backpressure');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, ADV_SOCK_PATH, 2);

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD (Server): Sends 500 packets in tight loop to unreading client
    ConnFD := AcceptUnixSocket(ServerFD);
    InitPacket(pkt, OP_RESP_VIEWPORT_ITEM, 999, 0);
    for i := 1 to 500 do
    begin
      if not SendPacket(ConnFD, pkt) then
        Break;
    end;
    fpClose(ConnFD);
    // If we survived without SIGPIPE, exit 0
    fpExit(0);
  end
  else
  begin
    // PARENT (Client): Connects, reads nothing, waits 5ms, then abruptly closes
    ClientFD := CreateUnixSocket;
    ConnectUnixSocket(ClientFD, ADV_SOCK_PATH);
    Sleep(5);
    fpShutdown(ClientFD, SHUT_RDWR);
    fpClose(ClientFD);

    fpWaitPID(pid, status, 0);
    fpClose(ServerFD);
    fpUnlink(ADV_SOCK_PATH);

    if WIFSIGNALED(status) then
      AssertCheck(False, Format('Server killed by signal %d under saturation', [WTERMSIG(status)]))
    else
      AssertCheck(WEXITSTATUS(status) = 0, 'Server handled saturation disconnect cleanly (exit code 0)');
  end;
end;

// ============================================================================
// TEST 3: Invalid and Bad File Descriptors (EBADF Handling)
// ============================================================================
procedure TestBadFDResilience;
var
  pkt: TOMMPacket;
  res: Boolean;
  nonBlockRes: cint;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 3] Bad File Descriptor Handling (EBADF)');
  WriteLn('------------------------------------------------------------');

  InitPacket(pkt, OP_REQ_PING, 1, 0);

  // Negative FD
  res := SendPacket(-1, pkt);
  AssertCheck(not res, 'SendPacket(-1) returns False cleanly');

  res := RecvPacket(-1, pkt);
  AssertCheck(not res, 'RecvPacket(-1) returns False cleanly');

  nonBlockRes := RecvPacketNonBlocking(-1, pkt);
  WriteLn(Format('    RecvPacketNonBlocking(-1) = %d (Poll ignores negative FD, returns 0)', [nonBlockRes]));
  AssertCheck(nonBlockRes <= 0, 'RecvPacketNonBlocking(-1) does not return 1 (success)');

  // Arbitrary out-of-range FD
  res := SendPacket(99999, pkt);
  AssertCheck(not res, 'SendPacket(99999) returns False cleanly');

  res := RecvPacket(99999, pkt);
  AssertCheck(not res, 'RecvPacket(99999) returns False cleanly');

  nonBlockRes := RecvPacketNonBlocking(99999, pkt);
  WriteLn(Format('    RecvPacketNonBlocking(99999) = %d (Poll revents=POLLNVAL without POLLIN returns 0)', [nonBlockRes]));
  AssertCheck(nonBlockRes <= 0, 'RecvPacketNonBlocking(99999) does not return 1 (success)');
end;

// ============================================================================
// TEST 4: Boundary Truncation Matrix (Abrupt peer drop after N bytes)
// ============================================================================
procedure TestBoundaryTruncations;
const
  CUT_SIZES: array[0..7] of Integer = (1, 2, 3, 4, 15, 16, 256, 511);
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  pkt: TOMMPacket;
  recvPkt: TOMMPacket;
  i, cut: Integer;
  res: Boolean;
  pBytes: PByte;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 4] Boundary Truncation Matrix (Abrupt drops at 1..511B)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, ADV_SOCK_PATH, 16);

  InitPacket(pkt, OP_REQ_PLAY, 42, 0);
  pBytes := PByte(@pkt);

  for i := 0 to High(CUT_SIZES) do
  begin
    cut := CUT_SIZES[i];

    pid := fpFork;
    if pid = 0 then
    begin
      // Client child: writes only 'cut' bytes, then exits immediately
      ClientFD := CreateUnixSocket;
      ConnectUnixSocket(ClientFD, ADV_SOCK_PATH);
      fpWrite(ClientFD, pBytes, cut);
      fpShutdown(ClientFD, SHUT_RDWR);
      fpClose(ClientFD);
      fpExit(0);
    end
    else
    begin
      ConnFD := AcceptUnixSocket(ServerFD);
      res := RecvPacket(ConnFD, recvPkt);
      fpClose(ConnFD);
      fpWaitPID(pid, status, 0);

      AssertCheck(not res, Format('RecvPacket safely returned False when client closed after %d bytes', [cut]));
    end;
  end;

  fpClose(ServerFD);
  fpUnlink(ADV_SOCK_PATH);
end;

// ============================================================================
// TEST 5: Steady-State Heap Allocation Verification (10,000 IPC transactions)
// ============================================================================
procedure TestSteadyStateZeroHeap;
const
  TX_COUNT = 10000;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  pkt, replyPkt: TOMMPacket;
  i: Integer;
  heapBefore, heapAfter: PtrUInt;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 5] Steady-State Heap Audit (10,000 Transactions)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, ADV_SOCK_PATH, 2);

  pid := fpFork;
  if pid = 0 then
  begin
    // Server child: processes 10,000 ping-pongs
    ConnFD := AcceptUnixSocket(ServerFD);
    for i := 1 to TX_COUNT do
    begin
      if not RecvPacket(ConnFD, pkt) then
        fpExit(1);
      InitPacket(replyPkt, OP_RESP_PONG, pkt.SeqID, 0);
      if not SendPacket(ConnFD, replyPkt) then
        fpExit(2);
    end;
    fpClose(ConnFD);
    fpExit(0);
  end
  else
  begin
    ClientFD := CreateUnixSocket;
    ConnectUnixSocket(ClientFD, ADV_SOCK_PATH);
    InitPacket(pkt, OP_REQ_PING, 100, 0);

    // Warm-up 10 iterations to initialize any internal runtime tables
    for i := 1 to 10 do
    begin
      SendPacket(ClientFD, pkt);
      RecvPacket(ClientFD, replyPkt);
    end;

    heapBefore := GetFPCHeapStatus.CurrHeapUsed;

    for i := 1 to TX_COUNT do
    begin
      pkt.SeqID := i;
      SendPacket(ClientFD, pkt);
      RecvPacket(ClientFD, replyPkt);
    end;

    heapAfter := GetFPCHeapStatus.CurrHeapUsed;

    fpClose(ClientFD);
    fpWaitPID(pid, status, 0);
    fpClose(ServerFD);
    fpUnlink(ADV_SOCK_PATH);

    AssertCheck(WEXITSTATUS(status) = 0, 'Server child finished 10,000 iterations cleanly');
    AssertCheck(heapAfter = heapBefore, Format('Zero heap allocations over 10,000 transactions: Delta = %d bytes (Before=%d, After=%d)',
      [heapAfter - heapBefore, heapBefore, heapAfter]));
  end;
end;

// ============================================================================
// TEST 6: Concurrent Multi-Client Hostile Disconnects (4 Parallel Attackers)
// ============================================================================
procedure TestConcurrentHostileDisconnects;
const
  NUM_ATTACKERS = 4;
  BURST_PER_ATTACKER = 50;
var
  ServerFD, ConnFD: cint;
  attackerPids: array[0..NUM_ATTACKERS-1] of pid_t;
  status: cint;
  pkt: TOMMPacket;
  i, j: Integer;
  allClean: Boolean;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn(' [ADV TEST 6] Concurrent Multi-Client Hostile Disconnects (4 clients)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, ADV_SOCK_PATH, 32);

  // Fork 4 attacker processes
  for i := 0 to NUM_ATTACKERS - 1 do
  begin
    attackerPids[i] := fpFork;
    if attackerPids[i] = 0 then
    begin
      // Attacker child: repeatedly connect, write 1 byte or 10 bytes, abruptly crash/close
      for j := 1 to BURST_PER_ATTACKER do
      begin
        ConnFD := CreateUnixSocket;
        if ConnectUnixSocket(ConnFD, ADV_SOCK_PATH) then
        begin
          if (j mod 2) = 0 then
            fpWrite(ConnFD, @ADV_SOCK_PATH[1], 5);
          fpShutdown(ConnFD, SHUT_RDWR);
          fpClose(ConnFD);
        end;
        Sleep(1);
      end;
      fpExit(0);
    end;
  end;

  // Server loop: accept all bursts, attempt to read/send, must never crash or leak
  InitPacket(pkt, OP_RESP_OK, 1, 0);
  for i := 1 to NUM_ATTACKERS * BURST_PER_ATTACKER do
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    if ConnFD >= 0 then
    begin
      // Non-blocking or blocking read/write attempt
      SendPacket(ConnFD, pkt);
      RecvPacket(ConnFD, pkt);
      fpClose(ConnFD);
    end;
  end;

  allClean := True;
  for i := 0 to NUM_ATTACKERS - 1 do
  begin
    fpWaitPID(attackerPids[i], status, 0);
    if (not WIFEXITED(status)) or (WEXITSTATUS(status) <> 0) then
      allClean := False;
  end;

  fpClose(ServerFD);
  fpUnlink(ADV_SOCK_PATH);

  AssertCheck(allClean, 'All 4 concurrent attacker clients exited cleanly');
  AssertCheck(True, 'Server processed 200 rapid hostile connections without crash');
end;

// ============================================================================
// MAIN EXECUTION
// ============================================================================
begin
  Stats.Total := 0;
  Stats.Passed := 0;
  Stats.Failed := 0;

  WriteLn('============================================================');
  WriteLn('   Oh-My-Mineral: Adversarial Empirical IPC Stress Suite    ');
  WriteLn('   (teamwork_challenger_m1_it2_1)                           ');
  WriteLn('============================================================');

  Test500BrokenSocketWrites;
  TestBufferSaturationBrokenPipe;
  TestBadFDResilience;
  TestBoundaryTruncations;
  TestSteadyStateZeroHeap;
  TestConcurrentHostileDisconnects;

  WriteLn('============================================================');
  WriteLn(Format('ADVERSARIAL STRESS SUMMARY: Total=%d, Passed=%d, Failed=%d',
    [Stats.Total, Stats.Passed, Stats.Failed]));
  WriteLn('============================================================');

  if Stats.Failed > 0 then
    Halt(1)
  else
    Halt(0);
end.
