program TestTimeout;
{$mode objfpc}{$H+}
uses
  BaseUnix, Sockets, SysUtils, omm_ipc;

const
  TEST_SOCK = '/tmp/omm_timeout_test.sock';

var
  ServerFD, ClientFD, ConnFD: cint;
  pid: pid_t;
  status: cint;
  pkt: TOMMPacket;
  tv: timeval;
  startTime, endTime: QWord;
  recvRes: Boolean;
begin
  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, TEST_SOCK, 2);

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD: Client connects, sends 10 bytes, then sleeps
    ClientFD := CreateUnixSocket;
    ConnectUnixSocket(ClientFD, TEST_SOCK);
    fpWrite(ClientFD, PChar('0123456789'), 10);
    Sleep(500); // Wait longer than server timeout
    fpClose(ClientFD);
    fpExit(0);
  end
  else
  begin
    ConnFD := AcceptUnixSocket(ServerFD);

    // Set SO_RCVTIMEO to 100ms
    tv.tv_sec := 0;
    tv.tv_usec := 100000; // 100ms
    fpSetSockOpt(ConnFD, SOL_SOCKET, SO_RCVTIMEO, @tv, SizeOf(tv));

    startTime := GetTickCount64;
    recvRes := RecvPacket(ConnFD, pkt);
    endTime := GetTickCount64;

    WriteLn(Format('RecvPacket returned: %s, Elapsed: %d ms, Errno: %d (EAGAIN=%d)',
      [BoolToStr(recvRes, True), Cardinal(endTime - startTime), fpGetErrno, ESysEAGAIN]));

    fpClose(ConnFD);
    fpWaitPID(pid, status, 0);
    fpClose(ServerFD);
    fpUnlink(TEST_SOCK);
  end;
end.
