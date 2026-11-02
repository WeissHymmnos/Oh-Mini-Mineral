program StressCrossFPCServer;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Unix, Sockets, SysUtils, omm_ipc;

const
  CROSS_SOCK_PATH = '/tmp/omm_stress_cross.sock';
  C_CLIENT_BIN    = './tests/stress/stress_cross_c_client';

var
  g_passed: Integer = 0;
  g_failed: Integer = 0;
  g_total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(g_total);
  if Cond then
  begin
    Inc(g_passed);
    WriteLn('  [PASS] ', Msg);
  end
  else
  begin
    Inc(g_failed);
    WriteLn('  [FAIL] ', Msg);
  end;
end;

procedure TestCrossLanguageChurn;
var
  ServerFD, ConnFD: cint;
  pid: pid_t;
  status: cint;
  accepted, i: Integer;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[CROSS TEST 1] Cross-Language Churn: C Client -> FPC Server (100 connects)');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation');
  Check(BindAndListenUnixSocket(ServerFD, CROSS_SOCK_PATH, 32), 'Server bind and listen');

  pid := fpFork;
  if pid = 0 then
  begin
    fpExit(fpSystem(PChar(C_CLIENT_BIN + ' ' + CROSS_SOCK_PATH + ' churn 100')));
  end
  else
  begin
    accepted := 0;
    for i := 1 to 100 do
    begin
      ConnFD := AcceptUnixSocket(ServerFD);
      if ConnFD >= 0 then
      begin
        Inc(accepted);
        fpClose(ConnFD);
      end;
    end;

    fpWaitPID(pid, status, 0);
    Check(accepted = 100, Format('FPC server accepted %d of 100 connections from C client', [accepted]));
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'C client churn process exited with code 0');

    fpClose(ServerFD);
    fpUnlink(CROSS_SOCK_PATH);
  end;
end;

procedure TestCrossLanguageFragmentation;
var
  ServerFD, ConnFD: cint;
  pid: pid_t;
  status: cint;
  ReqPkt, RespPkt: TOMMPacket;
  i: Integer;
  payloadMatch: Boolean;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[CROSS TEST 2] Cross-Language Fragmented Write: C Client (1-byte writes) -> FPC Server');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation');
  Check(BindAndListenUnixSocket(ServerFD, CROSS_SOCK_PATH, 4), 'Server bind and listen');

  pid := fpFork;
  if pid = 0 then
  begin
    fpExit(fpSystem(PChar(C_CLIENT_BIN + ' ' + CROSS_SOCK_PATH + ' frag')));
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, 'Accepted connection from C client');

    FillChar(ReqPkt, SizeOf(ReqPkt), 0);
    Check(RecvPacket(ConnFD, ReqPkt), 'FPC RecvPacket accumulated 512 bytes from 1-byte C writes');

    Check(ReqPkt.Magic = OMM_PACKET_MAGIC, 'Magic matches OMM_PACKET_MAGIC ($4F4D4D50)');
    Check(ReqPkt.Opcode = OP_REQ_PLAY_URI, 'Opcode matches OP_REQ_PLAY_URI');
    Check(ReqPkt.SeqID = 8888, 'SeqID matches 8888');

    // Verify payload bytes
    payloadMatch := True;
    for i := 64 to OMM_PAYLOAD_SIZE - 1 do
    begin
      if ReqPkt.Payload.Raw[i] <> Byte(i xor $3C) then
      begin
        payloadMatch := False;
        Break;
      end;
    end;
    Check(payloadMatch, 'Cross-language payload payload.raw[64..495] matched byte-for-byte');

    // Send response back to C client
    InitPacket(RespPkt, OP_RESP_OK, 8888, OMM_OK);
    Check(SendPacket(ConnFD, RespPkt), 'FPC Server replied with OP_RESP_OK to C client');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'C client verified response and exited with code 0');

    fpClose(ServerFD);
    fpUnlink(CROSS_SOCK_PATH);
  end;
end;

procedure TestCrossLanguageCorrupt;
var
  ServerFD, ConnFD: cint;
  pid: pid_t;
  status: cint;
  RecvPkt: TOMMPacket;
begin
  WriteLn('------------------------------------------------------------');
  WriteLn('[CROSS TEST 3] Cross-Language Corrupt Magic: C Client (0xCAFEBABE) -> FPC Server');
  WriteLn('------------------------------------------------------------');

  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'Server socket creation');
  Check(BindAndListenUnixSocket(ServerFD, CROSS_SOCK_PATH, 4), 'Server bind and listen');

  pid := fpFork;
  if pid = 0 then
  begin
    fpExit(fpSystem(PChar(C_CLIENT_BIN + ' ' + CROSS_SOCK_PATH + ' corrupt')));
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);
    Check(ConnFD >= 0, 'Accepted connection from C client');

    Check(not RecvPacket(ConnFD, RecvPkt), 'FPC RecvPacket safely rejected C corrupt magic 0xCAFEBABE');

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    Check(WIFEXITED(status) and (WEXITSTATUS(status) = 0), 'C client exited with code 0');

    fpClose(ServerFD);
    fpUnlink(CROSS_SOCK_PATH);
  end;
end;

begin
  WriteLn('============================================================');
  WriteLn('   Oh-My-Mineral: Cross-Language (C/FPC) IPC Stress Test   ');
  WriteLn('============================================================');

  TestCrossLanguageChurn;
  TestCrossLanguageFragmentation;
  TestCrossLanguageCorrupt;

  WriteLn('============================================================');
  WriteLn(Format('CROSS-LANG SUMMARY: Total=%d, Passed=%d, Failed=%d', [g_total, g_passed, g_failed]));
  WriteLn('============================================================');

  if g_failed > 0 then Halt(1) else Halt(0);
end.
