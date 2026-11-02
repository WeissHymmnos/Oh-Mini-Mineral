program StressIPCFPC;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Sockets, SysUtils, omm_ipc;

const
  STRESS_SOCKET_PATH = '/tmp/omm_stress_fpc.sock';

type
  TTestStats = record
    Passed: Integer;
    Failed: Integer;
    Total: Integer;
  end;

var
  Stats: TTestStats;

procedure Check(Condition: Boolean; const Msg: string);
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

// Populate a deterministic test packet
procedure MakeDeterministicPacket(var Pkt: TOMMPacket; Opcode: UInt16; SeqID: UInt32; Seed: Byte);
var
  i: Integer;
begin
  InitPacket(Pkt, Opcode, SeqID, 0);
  for i := 0 to OMM_PAYLOAD_SIZE - 1 do
    Pkt.Payload.Raw[i] := Byte((i * 17 + Seed) and $FF);
end;

// Verify packet byte-by-byte
function VerifyPacketEqual(const Actual, Expected: TOMMPacket): Boolean;
var
  p1, p2: PByte;
  i: Integer;
begin
  p1 := PByte(@Actual);
  p2 := PByte(@Expected);
  for i := 0 to SizeOf(TOMMPacket) - 1 do
  begin
    if p1[i] <> p2[i] then
    begin
      WriteLn(Format('    Mismatch at byte offset %d: expected 0x%02X, got 0x%02X', [i, p2[i], p1[i]]));
      Exit(False);
    end;
  end;
  Result := True;
end;

// Setup signal handling (ignore SIGPIPE)
procedure IgnoreSIGPIPE;
var
  sa: SigActionRec;
begin
  FillChar(sa, SizeOf(sa), 0);
  sa.sa_handler := SigActionHandler(SIG_IGN);
  fpSigAction(SIGPIPE, @sa, nil);
end;

// ============================================================================
// TEST SUITE 1: High-Frequency Connection Churn (Connect & Disconnect)
// ============================================================================
procedure TestHighFrequencyConnectionChurn;
const
  CHURN_COUNT = 150;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  i: Integer;
  successCount: Integer;
  startTime, endTime: QWord;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 1] High-Frequency Connection Churn (', CHURN_COUNT, ' iterations)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation');
  Check(BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 32), 'Server bind and listen');

  startTime := GetTickCount64;
  pid := fpFork;
  if pid < 0 then
  begin
    Check(False, 'fpFork failed for churn test');
    fpClose(ServerFD);
    Exit;
  end;

  if pid = 0 then
  begin
    // CHILD PROCESS: Rapidly connect and close
    for i := 1 to CHURN_COUNT do
    begin
      ClientFD := CreateUnixSocket;
      if ClientFD >= 0 then
      begin
        if ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH) then
        begin
          // Connected successfully, immediately close
          fpClose(ClientFD);
        end
        else
        begin
          fpClose(ClientFD);
          fpExit(1);
        end;
      end
      else
        fpExit(2);
    end;
    fpExit(0);
  end
  else
  begin
    // PARENT PROCESS: Accept and immediately close
    successCount := 0;
    for i := 1 to CHURN_COUNT do
    begin
      ConnFD := AcceptUnixSocket(ServerFD);
      if ConnFD >= 0 then
      begin
        Inc(successCount);
        fpClose(ConnFD);
      end;
    end;

    fpWaitPID(pid, status, 0);
    endTime := GetTickCount64;

    Check(successCount = CHURN_COUNT, Format('Server accepted %d of %d churn connections', [successCount, CHURN_COUNT]));
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'Child process finished without error');
    WriteLn(Format('  -> Elapsed time for %d churns: %u ms (%.2f ops/sec)',
      [CHURN_COUNT, Cardinal(endTime - startTime), (CHURN_COUNT * 1000.0) / (endTime - startTime + 1)]));

    fpClose(ServerFD);
    fpUnlink(STRESS_SOCKET_PATH);
  end;
end;

// ============================================================================
// TEST SUITE 2: Rapid Request / Response Churn (Connect -> Ping -> Pong -> Close)
// ============================================================================
procedure TestRapidPingPongChurn;
const
  PINGPONG_COUNT = 150;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  i: Integer;
  successCount: Integer;
  ReqPkt, RespPkt: TOMMPacket;
  startTime, endTime: QWord;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 2] Rapid Ping-Pong Roundtrips (', PINGPONG_COUNT, ' iterations)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation');
  Check(BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 32), 'Server bind and listen');

  startTime := GetTickCount64;
  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD PROCESS
    for i := 1 to PINGPONG_COUNT do
    begin
      ClientFD := CreateUnixSocket;
      if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then
      begin
        if ClientFD >= 0 then fpClose(ClientFD);
        fpExit(1);
      end;

      InitPacket(ReqPkt, OP_REQ_PING, UInt32(i), 0);
      ReqPkt.Payload.TargetMs := UInt32(i * 10);
      if not SendPacket(ClientFD, ReqPkt) then
      begin
        fpClose(ClientFD);
        fpExit(2);
      end;

      FillChar(RespPkt, SizeOf(RespPkt), 0);
      if not RecvPacket(ClientFD, RespPkt) then
      begin
        fpClose(ClientFD);
        fpExit(3);
      end;

      if (RespPkt.Magic <> OMM_PACKET_MAGIC) or
         (RespPkt.Opcode <> OP_RESP_PONG) or
         (RespPkt.SeqID <> UInt32(i)) or
         (RespPkt.Payload.TargetMs <> UInt32(i * 10)) then
      begin
        fpClose(ClientFD);
        fpExit(4);
      end;

      fpClose(ClientFD);
    end;
    fpExit(0);
  end
  else
  begin
    // PARENT PROCESS
    successCount := 0;
    for i := 1 to PINGPONG_COUNT do
    begin
      ConnFD := AcceptUnixSocket(ServerFD);
      if ConnFD < 0 then Continue;

      FillChar(ReqPkt, SizeOf(ReqPkt), 0);
      if RecvPacket(ConnFD, ReqPkt) then
      begin
        if (ReqPkt.Magic = OMM_PACKET_MAGIC) and (ReqPkt.Opcode = OP_REQ_PING) then
        begin
          InitPacket(RespPkt, OP_RESP_PONG, ReqPkt.SeqID, OMM_OK);
          RespPkt.Payload.TargetMs := ReqPkt.Payload.TargetMs;
          if SendPacket(ConnFD, RespPkt) then
            Inc(successCount);
        end;
      end;
      fpClose(ConnFD);
    end;

    fpWaitPID(pid, status, 0);
    endTime := GetTickCount64;

    Check(successCount = PINGPONG_COUNT, Format('Completed %d of %d roundtrips successfully', [successCount, PINGPONG_COUNT]));
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'Child process finished all roundtrips without error');
    WriteLn(Format('  -> Elapsed time for %d ping-pongs: %u ms (%.2f ops/sec)',
      [PINGPONG_COUNT, Cardinal(endTime - startTime), (PINGPONG_COUNT * 1000.0) / (endTime - startTime + 1)]));

    fpClose(ServerFD);
    fpUnlink(STRESS_SOCKET_PATH);
  end;
end;

// ============================================================================
// TEST SUITE 3: Partial / Fragmented Packet Transmission Stress
// ============================================================================
procedure RunFragmentedSendTest(ChunkSize: Integer; const ScenarioName: string; DelayUs: Integer = 0);
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  SendPkt, RecvPktBuf: TOMMPacket;
  pSrc: PByte;
  offset, writeLen, bytesSent: Integer;
  n: ssize_t;
  tv: timeval;
begin
  WriteLn('  Testing fragmented transmission: ', ScenarioName, ' (ChunkSize=', ChunkSize, ')');

  ServerFD := CreateUnixSocket;
  if (ServerFD < 0) or (not BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 4)) then
  begin
    Check(False, 'Server bind/listen failed for ' + ScenarioName);
    Exit;
  end;

  MakeDeterministicPacket(SendPkt, OP_REQ_PLAY_URI, 7777, Byte(ChunkSize));

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD PROCESS: Fragmented writer
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then
    begin
      if ClientFD >= 0 then fpClose(ClientFD);
      fpExit(1);
    end;

    pSrc := PByte(@SendPkt);
    offset := 0;
    while offset < SizeOf(TOMMPacket) do
    begin
      writeLen := ChunkSize;
      if offset + writeLen > SizeOf(TOMMPacket) then
        writeLen := SizeOf(TOMMPacket) - offset;

      bytesSent := 0;
      while bytesSent < writeLen do
      begin
        n := fpWrite(ClientFD, @pSrc[offset + bytesSent], writeLen - bytesSent);
        if n <= 0 then
        begin
          if (n < 0) and (fpGetErrno = ESysEINTR) then Continue;
          fpClose(ClientFD);
          fpExit(2);
        end;
        Inc(bytesSent, n);
      end;
      Inc(offset, writeLen);

      if DelayUs > 0 then
      begin
        // Microsecond delay via select
        tv.tv_sec := 0;
        tv.tv_usec := DelayUs;
        fpSelect(0, nil, nil, nil, @tv);
      end;
    end;

    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    // PARENT PROCESS: Standard RecvPacket accumulator
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, ScenarioName + ' connection accepted');

    FillChar(RecvPktBuf, SizeOf(RecvPktBuf), 0);
    Check(RecvPacket(ConnFD, RecvPktBuf), ScenarioName + ' RecvPacket returned True');
    Check(VerifyPacketEqual(RecvPktBuf, SendPkt), ScenarioName + ' 512-byte payload byte-for-byte identical');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), ScenarioName + ' child exited cleanly');

    fpClose(ServerFD);
    fpUnlink(STRESS_SOCKET_PATH);
  end;
end;

procedure TestRandomFragmentedPackets(PacketCount: Integer);
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  pktIdx, offset, chunkSize, rem, bytesSent: Integer;
  SendPkts, RecvPkts: array of TOMMPacket;
  pSrc: PByte;
  n: ssize_t;
  allMatch: Boolean;
begin
  WriteLn(Format('  Testing %d packets with randomized chunk sizes (1..128 bytes)', [PacketCount]));

  SetLength(SendPkts, PacketCount);
  SetLength(RecvPkts, PacketCount);
  for pktIdx := 0 to PacketCount - 1 do
    MakeDeterministicPacket(SendPkts[pktIdx], OP_REQ_VIEWPORT, UInt32(3000 + pktIdx), Byte(pktIdx * 7));

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation for random fragmentation');
  Check(BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 4), 'Server bind and listen');

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD PROCESS: Sends PacketCount packets with random chunk sizes
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then
      fpExit(1);

    RandSeed := 1337;
    for pktIdx := 0 to PacketCount - 1 do
    begin
      pSrc := PByte(@SendPkts[pktIdx]);
      offset := 0;
      while offset < SizeOf(TOMMPacket) do
      begin
        rem := SizeOf(TOMMPacket) - offset;
        chunkSize := 1 + Random(128);
        if chunkSize > rem then chunkSize := rem;

        bytesSent := 0;
        while bytesSent < chunkSize do
        begin
          n := fpWrite(ClientFD, @pSrc[offset + bytesSent], chunkSize - bytesSent);
          if n <= 0 then
          begin
            if (n < 0) and (fpGetErrno = ESysEINTR) then Continue;
            fpClose(ClientFD);
            fpExit(2);
          end;
          Inc(bytesSent, n);
        end;
        Inc(offset, chunkSize);
      end;
    end;

    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    // PARENT PROCESS
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, 'Connection accepted for random fragmentation');

    allMatch := True;
    for pktIdx := 0 to PacketCount - 1 do
    begin
      FillChar(RecvPkts[pktIdx], SizeOf(TOMMPacket), 0);
      if not RecvPacket(ConnFD, RecvPkts[pktIdx]) then
      begin
        WriteLn(Format('    RecvPacket failed at packet index %d', [pktIdx]));
        allMatch := False;
        Break;
      end;
      if not VerifyPacketEqual(RecvPkts[pktIdx], SendPkts[pktIdx]) then
      begin
        allMatch := False;
        Break;
      end;
    end;

    Check(allMatch, Format('All %d randomized fragmented packets accumulated without corruption', [PacketCount]));

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'Random fragment child exited cleanly');

    fpClose(ServerFD);
    fpUnlink(STRESS_SOCKET_PATH);
  end;
end;

procedure TestFragmentedPackets;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 3] Partial Packet Transmission Stress');
  WriteLn('------------------------------------------------------------');

  // Pattern A: 1 byte per write (512 iterations)
  RunFragmentedSendTest(1, '1-byte fragments (512 writes)', 10);

  // Pattern B: 7 bytes per write (73 iterations)
  RunFragmentedSendTest(7, '7-byte fragments (73 writes)', 10);

  // Pattern C: 256 bytes per write (2 iterations)
  RunFragmentedSendTest(256, '256-byte fragments (2 writes)', 50);

  // Pattern D: 50 randomly fragmented packets
  TestRandomFragmentedPackets(50);
end;

// ============================================================================
// TEST SUITE 4: Corrupt Magic, Truncated Data & Opcode Injection
// ============================================================================
procedure TestCorruptMagicAndTruncation;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  BadPkt, RecvPkt: TOMMPacket;
  buf: array[0..511] of Byte;
  i: Integer;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 4] Corrupt Magic, Truncation & Opcode Injection');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation for corrupt testing');
  Check(BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 8), 'Server bind and listen');

  // Test 4.1: Corrupt Magic Injection (0xDEADBEEF, 0x00000000, 0xFFFFFFFF)
  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);

    // Send packet with 0xDEADBEEF
    InitPacket(BadPkt, OP_REQ_PLAY, 1, 0);
    BadPkt.Magic := $DEADBEEF;
    SendPacket(ClientFD, BadPkt);

    // Send packet with 0x00000000
    InitPacket(BadPkt, OP_REQ_PLAY, 2, 0);
    BadPkt.Magic := $00000000;
    SendPacket(ClientFD, BadPkt);

    // Send packet with 0xFFFFFFFF
    InitPacket(BadPkt, OP_REQ_PLAY, 3, 0);
    BadPkt.Magic := $FFFFFFFF;
    SendPacket(ClientFD, BadPkt);

    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    // PARENT
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, 'Accepted client for corrupt magic');

    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket rejected Magic=0xDEADBEEF cleanly (returned False)');
    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket rejected Magic=0x00000000 cleanly (returned False)');
    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket rejected Magic=0xFFFFFFFF cleanly (returned False)');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
  end;

  // Test 4.2: Abrupt EOF / Truncation (client closes after partial bytes)
  // Subtest 4.2a: Send only 10 bytes then close
  pid := fpFork;
  if pid = 0 then
  begin
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);
    for i := 0 to 9 do buf[i] := Byte(i);
    fpWrite(ClientFD, @buf[0], 10);
    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket on 10-byte truncated packet returned False (EOF handled)');
    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
  end;

  // Subtest 4.2b: Send 256 bytes then close
  pid := fpFork;
  if pid = 0 then
  begin
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);
    FillChar(buf, SizeOf(buf), $AA);
    fpWrite(ClientFD, @buf[0], 256);
    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket on 256-byte truncated packet returned False (EOF handled)');
    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
  end;

  // Subtest 4.2c: Send 511 bytes (missing exactly 1 byte) then close
  pid := fpFork;
  if pid = 0 then
  begin
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);
    FillChar(buf, SizeOf(buf), $55);
    fpWrite(ClientFD, @buf[0], 511);
    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(not RecvPacket(ConnFD, RecvPkt), 'RecvPacket on 511-byte truncated packet returned False (EOF handled)');
    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
  end;

  // Subtest 4.3: Out-of-spec opcodes (0x0000, 0x00FE, 0x7FFF, 0xFFFF)
  pid := fpFork;
  if pid = 0 then
  begin
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);

    InitPacket(BadPkt, $0000, 100, 0);
    SendPacket(ClientFD, BadPkt);

    InitPacket(BadPkt, $00FE, 101, 0);
    SendPacket(ClientFD, BadPkt);

    InitPacket(BadPkt, $7FFF, 102, 0);
    SendPacket(ClientFD, BadPkt);

    InitPacket(BadPkt, $FFFF, 103, 0);
    SendPacket(ClientFD, BadPkt);

    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    // Server successfully frames packet, but identifies invalid opcode
    Check(RecvPacket(ConnFD, RecvPkt) and (RecvPkt.Opcode = $0000), 'Opcode $0000 framed correctly');
    Check(RecvPacket(ConnFD, RecvPkt) and (RecvPkt.Opcode = $00FE), 'Opcode $00FE framed correctly');
    Check(RecvPacket(ConnFD, RecvPkt) and (RecvPkt.Opcode = $7FFF), 'Opcode $7FFF framed correctly');
    Check(RecvPacket(ConnFD, RecvPkt) and (RecvPkt.Opcode = $FFFF), 'Opcode $FFFF framed correctly');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
  end;

  fpClose(ServerFD);
  fpUnlink(STRESS_SOCKET_PATH);
end;

// ============================================================================
// TEST SUITE 5: Non-Blocking Socket Evaluation
// ============================================================================
procedure TestNonBlockingEvaluation;
var
  ServerFD, ConnFD, ClientFD: cint;
  pid: pid_t;
  status: cint;
  Pkt: TOMMPacket;
  nonBlockRes: cint;
  buf: array[0..63] of Byte;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 5] Non-Blocking Socket Evaluation');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation for non-blocking test');
  Check(BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 4), 'Server bind and listen');

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD
    ClientFD := CreateUnixSocket;
    if (ClientFD < 0) or (not ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH)) then fpExit(1);

    // 1. Send nothing initially, wait for parent to test empty non-blocking read
    Sleep(50);

    // 2. Send complete packet
    InitPacket(Pkt, OP_REQ_GET_STATUS, 501, 0);
    SendPacket(ClientFD, Pkt);
    Sleep(50);

    // 3. Send only 64 bytes (partial packet)
    FillChar(buf, SizeOf(buf), $42);
    fpWrite(ClientFD, @buf[0], 64);
    Sleep(50);

    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    // PARENT
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, 'Accepted client for non-blocking test');
    Check(SetSocketNonBlocking(ConnFD), 'Set accepted socket to non-blocking');

    // 1. Non-blocking recv when no data available
    nonBlockRes := RecvPacketNonBlocking(ConnFD, Pkt);
    Check(nonBlockRes = 0, Format('RecvPacketNonBlocking on empty socket returned 0 (would block), got %d', [nonBlockRes]));

    // 2. Wait for child to send full packet
    Sleep(80);
    nonBlockRes := RecvPacketNonBlocking(ConnFD, Pkt);
    Check(nonBlockRes = 1, Format('RecvPacketNonBlocking with full packet returned 1 (success), got %d', [nonBlockRes]));
    Check((Pkt.Magic = OMM_PACKET_MAGIC) and (Pkt.Opcode = OP_REQ_GET_STATUS), 'Decoded packet matches sent request');

    // 3. Wait for child to send 64 bytes (partial packet on non-blocking socket)
    Sleep(80);
    nonBlockRes := RecvPacketNonBlocking(ConnFD, Pkt);
    WriteLn(Format('  [INFO] RecvPacketNonBlocking with partial 64 bytes on non-blocking socket returned %d', [nonBlockRes]));
    // In current implementation: PollSocket detects POLLIN, but RecvPacket encounters EAGAIN
    // and exits False, resulting in nonBlockRes = -1.
    Check(nonBlockRes = -1, 'RecvPacketNonBlocking returns -1 on non-blocking partial packet due to EAGAIN');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    fpClose(ServerFD);
    fpUnlink(STRESS_SOCKET_PATH);
  end;
end;

// ============================================================================
// TEST SUITE 6: Resource Leak Audit (FDs & Heap Memory)
// ============================================================================
procedure TestResourceLeakAudit;
var
  InitialFDs, FinalFDs, DeltaFD: Integer;
  InitialHeap, FinalHeap, DeltaHeap: Int64;
  heapStatus: TFPCHeapStatus;
  i: Integer;
  ServerFD, ConnFD, ClientFD: cint;
  Pkt: TOMMPacket;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[TEST SUITE 6] Resource Leak Audit (FDs & Memory)');
  WriteLn('------------------------------------------------------------');

  InitialFDs := CountOpenFDs;
  heapStatus := GetFPCHeapStatus;
  InitialHeap := heapStatus.CurrHeapUsed;

  WriteLn(Format('  Initial state: Open FDs = %d, Heap Used = %d bytes', [InitialFDs, InitialHeap]));

  // Run 100 fast local socket open/close and send/recv cycles
  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, STRESS_SOCKET_PATH, 8);

  for i := 1 to 100 do
  begin
    ClientFD := CreateUnixSocket;
    ConnectUnixSocket(ClientFD, STRESS_SOCKET_PATH);
    ConnFD := AcceptUnixSocket(ServerFD);

    InitPacket(Pkt, OP_REQ_PING, UInt32(i), 0);
    SendPacket(ClientFD, Pkt);
    RecvPacket(ConnFD, Pkt);

    InitPacket(Pkt, OP_RESP_PONG, UInt32(i), 0);
    SendPacket(ConnFD, Pkt);
    RecvPacket(ClientFD, Pkt);

    fpClose(ClientFD);
    fpClose(ConnFD);
  end;

  fpClose(ServerFD);
  fpUnlink(STRESS_SOCKET_PATH);

  FinalFDs := CountOpenFDs;
  heapStatus := GetFPCHeapStatus;
  FinalHeap := heapStatus.CurrHeapUsed;

  DeltaFD := FinalFDs - InitialFDs;
  DeltaHeap := FinalHeap - InitialHeap;

  WriteLn(Format('  Final state: Open FDs = %d (Delta = %d), Heap Used = %d bytes (Delta = %d)',
    [FinalFDs, DeltaFD, FinalHeap, DeltaHeap]));

  Check(DeltaFD = 0, Format('Zero file descriptor leaks: Delta FD = %d (expected 0)', [DeltaFD]));
  Check(DeltaHeap = 0, Format('Zero heap memory leaks in steady state: Delta Heap = %d bytes (expected 0)', [DeltaHeap]));
end;

// ============================================================================
// MAIN ENTRY POINT
// ============================================================================
begin
  Stats.Passed := 0;
  Stats.Failed := 0;
  Stats.Total := 0;

  IgnoreSIGPIPE;

  WriteLn('============================================================');
  WriteLn('   Oh-My-Mineral: Empirical IPC Stress & Fuzzing Harness    ');
  WriteLn('   (teamwork_challenger_m1_1)                               ');
  WriteLn('============================================================');

  TestHighFrequencyConnectionChurn;
  TestRapidPingPongChurn;
  TestFragmentedPackets;
  TestCorruptMagicAndTruncation;
  TestNonBlockingEvaluation;
  TestResourceLeakAudit;

  WriteLn('============================================================');
  WriteLn(Format('STRESS TEST SUMMARY: Total=%d, Passed=%d, Failed=%d', [Stats.Total, Stats.Passed, Stats.Failed]));
  WriteLn('============================================================');

  if Stats.Failed > 0 then
    Halt(1)
  else
    Halt(0);
end.
