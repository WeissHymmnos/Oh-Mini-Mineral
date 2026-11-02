program TestSigPipeEmpirical;
{$mode objfpc}{$H+}
uses
  BaseUnix, Sockets, SysUtils, omm_ipc;

const
  TEST_SOCK = '/tmp/omm_sigpipe_test.sock';

var
  ServerFD, ClientFD, ConnFD: cint;
  pid: pid_t;
  status: cint;
  pkt: TOMMPacket;
begin
  ServerFD := CreateUnixSocket;
  BindAndListenUnixSocket(ServerFD, TEST_SOCK, 2);

  pid := fpFork;
  if pid = 0 then
  begin
    // CHILD: Server that does NOT ignore SIGPIPE, attempts SendPacket to closed client
    ConnFD := AcceptUnixSocket(ServerFD);
    // Wait for client to close its end
    Sleep(100);
    InitPacket(pkt, OP_RESP_OK, 1, 0);
    // First write might send into kernel buffer or succeed, second write will hit broken pipe
    SendPacket(ConnFD, pkt);
    SendPacket(ConnFD, pkt);
    fpClose(ConnFD);
    fpExit(0);
  end
  else
  begin
    // PARENT: Connects, then immediately terminates / closes socket
    ClientFD := CreateUnixSocket;
    ConnectUnixSocket(ClientFD, TEST_SOCK);
    // Immediate close and shutdown
    fpShutdown(ClientFD, SHUT_RDWR);
    fpClose(ClientFD);

    fpWaitPID(pid, status, 0);
    if WIFSIGNALED(status) then
    begin
      WriteLn(Format('CHILD WAS TERMINATED BY SIGNAL: %d (SIGPIPE=%d)', [WTERMSIG(status), SIGPIPE]));
    end
    else
    begin
      WriteLn(Format('CHILD EXITED WITH CODE: %d', [WEXITSTATUS(status)]));
    end;

    fpClose(ServerFD);
    fpUnlink(TEST_SOCK);
  end;
end.
