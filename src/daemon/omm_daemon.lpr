program omm_daemon;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Unix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  ctypes, SysUtils, Classes, Math,
  omm_os, omm_ipc, omm_shm, omm_codec_abi, omm_fft, omm_audio, omm_library, omm_watchdog, omm_router;

var
  GTerminated: Boolean = False;
  GSocketPath: string = OMM_DEFAULT_SOCKET_PATH;
  GShmPath: string = OMM_SHM_NAME;
  GMusicDir: string = '';
  GLibraryFile: string = OMM_DEFAULT_LIBRARY_PATH;
  GPluginPath: string = PLUGIN_DEFAULT_LIB_PATH;

{$IFDEF UNIX}
procedure SigHandler(Sig: cint); cdecl;
begin
  if (Sig = SIGINT) or (Sig = SIGTERM) then
    GTerminated := True;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function WinCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  GTerminated := True;
  Result := True;
end;
{$ENDIF}

procedure ParseCommandLine;
var
  i: Integer;
  arg: string;
begin
  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if (arg = '--socket') and (i < ParamCount) then
    begin
      Inc(i);
      GSocketPath := ParamStr(i);
    end
    else if (arg = '--shm') and (i < ParamCount) then
    begin
      Inc(i);
      GShmPath := ParamStr(i);
    end
    else if (arg = '--music-dir') and (i < ParamCount) then
    begin
      Inc(i);
      GMusicDir := ParamStr(i);
    end
    else if (arg = '--library') and (i < ParamCount) then
    begin
      Inc(i);
      GLibraryFile := ParamStr(i);
    end
    else if (arg = '--plugin') and (i < ParamCount) then
    begin
      Inc(i);
      GPluginPath := ParamStr(i);
    end;
    Inc(i);
  end;

  if (GMusicDir = '') and (GLibraryFile = OMM_DEFAULT_LIBRARY_PATH) then
  begin
    if DirectoryExists(GetEnvironmentVariable('HOME') + '/.cache/mineral/audio/netease') then
      GMusicDir := GetEnvironmentVariable('HOME') + '/.cache/mineral/audio/netease'
    else if DirectoryExists(GetEnvironmentVariable('HOME') + '/.cache/mineral/audio') then
      GMusicDir := GetEnvironmentVariable('HOME') + '/.cache/mineral/audio'
    else if DirectoryExists(GetEnvironmentVariable('HOME') + '/Music') then
      GMusicDir := GetEnvironmentVariable('HOME') + '/Music';
  end;
end;

procedure TerminateOldPidIfAlive(OldPid: TPid);
var
  w: Integer;
begin
  if (OldPid <= 1) or (OldPid = fpGetPID) then Exit;
  if fpKill(OldPid, 0) <> 0 then Exit;
  fpKill(OldPid, SIGTERM);
  for w := 1 to 15 do
  begin
    Sleep(10);
    if fpKill(OldPid, 0) <> 0 then Exit;
  end;
  fpKill(OldPid, SIGKILL);
  Sleep(10);
end;

procedure EnsureSingleDaemonInstance(const SocketPath, ShmTarget: string);
var
  pidFile, pidStr: string;
  sl: TStringList;
  oldPid: TPid;
  existingShm: POMMSharedMemory;
begin
  pidFile := NormalizeOmmPath(SocketPath + '.pid');
  if FileExists(pidFile) then
  begin
    sl := TStringList.Create;
    try
      try
        sl.LoadFromFile(pidFile);
        oldPid := StrToIntDef(Trim(sl.Text), 0);
        TerminateOldPidIfAlive(oldPid);
      except
      end;
    finally
      sl.Free;
    end;
  end;

  existingShm := OpenSharedMemory(ShmTarget, True);
  if existingShm <> nil then
  begin
    if (existingShm^.Magic = OMM_SHM_MAGIC) and (existingShm^.DaemonPID > 1) then
      TerminateOldPidIfAlive(TPid(existingShm^.DaemonPID));
    CloseSharedMemory(existingShm);
  end;

  sl := TStringList.Create;
  try
    pidStr := IntToStr(FpGetpid);
    sl.Text := pidStr;
    try
      sl.SaveToFile(pidFile);
    except
    end;
  finally
    sl.Free;
  end;
end;

function SetupSharedMemory(const ShmTarget: string): POMMSharedMemory;
var
  {$IFDEF UNIX}
  fd: cint;
  isRegularFile: Boolean;
  {$ENDIF}
  pShm: POMMSharedMemory;
begin
  Result := nil;
  {$IFDEF UNIX}
  // POSIX shm names start with a single slash and contain no other slashes (e.g. /omm_shm)
  isRegularFile := (Pos('/', Copy(ShmTarget, 2, Length(ShmTarget))) > 0) or
                   ((Length(ShmTarget) > 0) and (ShmTarget[1] <> '/'));

  if isRegularFile then
  begin
    fd := fpOpen(PChar(ShmTarget), O_RDWR or O_CREAT, &666);
    if fd < 0 then Exit;
    if fpfTruncate(fd, OMM_SHM_SIZE) <> 0 then
    begin
      fpClose(fd);
      Exit;
    end;
    pShm := POMMSharedMemory(fpMMap(nil, OMM_SHM_SIZE, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0));
    fpClose(fd);
  end
  else
  begin
    pShm := CreateSharedMemory(ShmTarget);
  end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  pShm := CreateSharedMemory(ShmTarget);
  {$ENDIF}

  if (pShm = nil) or (pShm = POMMSharedMemory(Pointer(-1))) then
    Exit(nil);

  FillChar(pShm^, OMM_SHM_SIZE, 0);
  pShm^.Magic := OMM_SHM_MAGIC;
  pShm^.Version := OMM_SHM_VERSION;
  pShm^.SpectrumBands := OMM_SPECTRUM_BANDS;
  pShm^.DaemonPID := FpGetpid;
  pShm^.Volume := 1.0;

  Result := pShm;
end;

procedure ProcessClientRequest(ClientFD: cint; const Req: TOMMPacket;
  pShm: POMMSharedMemory; LibEngine: TOMMLibraryEngine; Watchdog: TOmmWatchdog; Router: TOmmRouter);
var
  resp: TOMMPacket;
  st, posMs, durMs, targetMs, trackID, queryLimit, vOffset, vLimit: UInt32;
  total, filtered, outCount, i: Cardinal;
  onlineCount: SizeUInt;
  vol: Single;
  uri, filter, lineStr: string;
  rc: Int32;
  simList: TTop20List;
  pRec: POMMTrackRecord;
  viewportTracks: array[0..127] of TOMMCondensedTrack;
begin
  if Req.Magic <> OMM_PACKET_MAGIC then
  begin
    InitPacket(resp, OP_RESP_ERROR, Req.SeqID, OMM_ERR_INVALID_PARAM);
    resp.Payload.ErrorCode := OMM_ERR_INVALID_PARAM;
    SendPacket(ClientFD, resp);
    Exit;
  end;

  case Req.Opcode of
    OP_REQ_PING:
    begin
      InitPacket(resp, OP_RESP_PONG, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_GET_STATUS:
    begin
      InitPacket(resp, OP_RESP_STATUS, Req.SeqID, OMM_OK);
      st := omm_audio_get_state;
      posMs := omm_audio_get_position_ms;
      durMs := omm_audio_get_duration_ms;
      if pShm <> nil then vol := pShm^.Volume else vol := 1.0;

      Move(st, resp.Payload.Raw[0], 4);
      Move(posMs, resp.Payload.Raw[4], 4);
      Move(durMs, resp.Payload.Raw[8], 4);
      Move(vol, resp.Payload.Raw[12], 4);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLAY:
    begin
      if (Router.CurrentTrackID = 0) and (LibEngine <> nil) and (LibEngine.TrackCount > 0) then
        Router.PlayTrackID(1)
      else
        Router.Resume;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PAUSE:
    begin
      Router.Pause;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_RESUME:
    begin
      Router.Resume;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_STOP:
    begin
      Router.Stop;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_SEEK:
    begin
      Move(Req.Payload.Raw[0], targetMs, 4);
      Router.Seek(targetMs);
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_SET_VOLUME:
    begin
      Move(Req.Payload.Raw[0], vol, 4);
      Router.SetVolume(vol);
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLAY_URI:
    begin
      uri := StrPas(PAnsiChar(@Req.Payload.Raw[0]));
      rc := Router.PlayURI(uri);
      if rc = OMM_OK then
        InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK)
      else
      begin
        InitPacket(resp, OP_RESP_ERROR, Req.SeqID, rc);
        resp.Payload.ErrorCode := rc;
      end;
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLAY_TRACK_ID:
    begin
      Move(Req.Payload.Raw[0], trackID, 4);
      rc := Router.PlayTrackID(trackID);
      if rc = OMM_OK then
        InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK)
      else
      begin
        InitPacket(resp, OP_RESP_ERROR, Req.SeqID, rc);
        resp.Payload.ErrorCode := rc;
      end;
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_VIEWPORT:
    begin
      LibEngine.EnsureFresh;
      vOffset := Req.Payload.ViewportOffset;
      vLimit := Req.Payload.ViewportLimit;
      if vLimit > 128 then vLimit := 128;
      filter := '';
      if Req.Payload.FilterLen > 0 then
        filter := StrPas(Req.Payload.FilterText);

      LibEngine.GetViewportPage(vOffset, vLimit, filter,
                              total, filtered, outCount, @viewportTracks[0], 128);

      InitPacket(resp, OP_RESP_VIEWPORT_HEADER, Req.SeqID, OMM_OK);
      resp.Payload.TotalTracks := total;
      resp.Payload.FilteredTracks := filtered;
      resp.Payload.PageOffset := vOffset;
      resp.Payload.ReturnedCount := outCount;
      SendPacket(ClientFD, resp);

      if outCount > 0 then
      begin
        for i := 0 to outCount - 1 do
        begin
          InitPacket(resp, OP_RESP_VIEWPORT_ITEM, Req.SeqID, OMM_OK);
          Move(viewportTracks[i], resp.Payload.TrackItem, SizeOf(TOMMCondensedTrack));
          SendPacket(ClientFD, resp);
        end;
      end;
    end;

    OP_REQ_QUERY_SIMILAR:
    begin
      LibEngine.EnsureFresh;
      Move(Req.Payload.Raw[0], trackID, 4);
      Move(Req.Payload.Raw[4], queryLimit, 4);
      simList := QueryTopSimilar(LibEngine, trackID, queryLimit);

      InitPacket(resp, OP_RESP_SIMILAR_HEADER, Req.SeqID, OMM_OK);
      resp.Payload.SimilarTrackID := trackID;
      resp.Payload.SimilarReturnedCount := simList.Count;
      SendPacket(ClientFD, resp);

      if simList.Count > 0 then
      begin
        for i := 0 to simList.Count - 1 do
        begin
          pRec := LibEngine.GetRecord(simList.Items[i].TrackID);
          if pRec <> nil then
          begin
            InitPacket(resp, OP_RESP_SIMILAR_ITEM, Req.SeqID, OMM_OK);
            resp.Payload.SimilarScore := simList.Items[i].Score;
            FillChar(resp.Payload.SimilarTrack, SizeOf(TOMMCondensedTrack), 0);
            resp.Payload.SimilarTrack.TrackID := pRec^.TrackID;
            resp.Payload.SimilarTrack.DurationMs := pRec^.DurationMs;
            resp.Payload.SimilarTrack.Year := pRec^.Year;
            resp.Payload.SimilarTrack.TrackNo := pRec^.TrackNo;
            resp.Payload.SimilarTrack.BitrateKbps := pRec^.BitrateKbps;
            resp.Payload.SimilarTrack.FormatTag := pRec^.FormatTag;
            Move(pRec^.Title[0], resp.Payload.SimilarTrack.Title[0], SizeOf(resp.Payload.SimilarTrack.Title));
            Move(pRec^.Artist[0], resp.Payload.SimilarTrack.Artist[0], SizeOf(resp.Payload.SimilarTrack.Artist));
            Move(pRec^.Album[0], resp.Payload.SimilarTrack.Album[0], SizeOf(resp.Payload.SimilarTrack.Album));
            Move(pRec^.RelativePath[0], resp.Payload.SimilarTrack.URI[0], SizeOf(resp.Payload.SimilarTrack.URI));
            SendPacket(ClientFD, resp);
          end;
        end;
      end;
    end;

    OP_REQ_RESCAN_LIBRARY:
    begin
      uri := StrPas(PAnsiChar(@Req.Payload.Raw[0]));
      if (uri <> '') and DirectoryExists(uri) then
      begin
        GMusicDir := uri;
        LibEngine.MusicDir := uri;
        if not LibEngine.EnsureFresh then
          LibEngine.RescanDirectory(GMusicDir);
      end
      else
        LibEngine.RescanDirectory(GMusicDir);
      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.TotalTracks := LibEngine.TrackCount;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLUGIN_WAKE:
    begin
      Watchdog.EnsureActive;
      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.PluginState := OMM_PLUGIN_ACTIVE;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLUGIN_SUSPEND:
    begin
      Watchdog.Suspend;
      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.PluginState := OMM_PLUGIN_SUSPENDED;
        pShm^.PlaybackFlags := pShm^.PlaybackFlags and (not OMM_FLAG_STREAMING);
        pShm^.PluginRssBytes := Watchdog.RssBytes;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;
      omm_malloc_trim;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_PLUGIN_UNLOAD:
    begin
      Watchdog.DeepUnload;
      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.PluginState := OMM_PLUGIN_DEEP_UNLOAD;
        pShm^.PlaybackFlags := pShm^.PlaybackFlags and (not OMM_FLAG_STREAMING);
        pShm^.PluginRssBytes := 0;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;
      omm_malloc_trim;
      InitPacket(resp, OP_RESP_OK, Req.SeqID, OMM_OK);
      SendPacket(ClientFD, resp);
    end;

    OP_REQ_MINERAL_SEARCH:
    begin
      uri := StrPas(PAnsiChar(@Req.Payload.Raw[0]));
      onlineCount := 0;
      rc := Watchdog.SearchOnline(uri, @viewportTracks[0], 48, onlineCount);
      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.PluginState := Watchdog.State;
        pShm^.PluginRssBytes := Watchdog.RssBytes;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;

      InitPacket(resp, OP_RESP_MINERAL_SEARCH_HEADER, Req.SeqID, rc);
      resp.Payload.TotalTracks := Cardinal(onlineCount);
      resp.Payload.FilteredTracks := Cardinal(onlineCount);
      resp.Payload.PageOffset := 0;
      resp.Payload.ReturnedCount := Cardinal(onlineCount);
      SendPacket(ClientFD, resp);

      if onlineCount > 0 then
      begin
        for i := 0 to Cardinal(onlineCount) - 1 do
        begin
          InitPacket(resp, OP_RESP_MINERAL_SEARCH_ITEM, Req.SeqID, OMM_OK);
          Move(viewportTracks[i], resp.Payload.TrackItem, SizeOf(TOMMCondensedTrack));
          SendPacket(ClientFD, resp);
        end;
      end;
    end;

    OP_REQ_GET_LYRICS:
    begin
      InitPacket(resp, OP_RESP_LYRICS_LINE, Req.SeqID, OMM_OK);
      resp.Payload.LyricTimestampMs := 12000;
      lineStr := 'Oh-My-Mineral Synchronized Lyrics Test Line';
      Move(lineStr[1], resp.Payload.LyricText[0], Length(lineStr));
      SendPacket(ClientFD, resp);
    end;

    else
    begin
      InitPacket(resp, OP_RESP_ERROR, Req.SeqID, OMM_ERR_INVALID_PARAM);
      resp.Payload.ErrorCode := OMM_ERR_INVALID_PARAM;
      SendPacket(ClientFD, resp);
    end;
  end;
end;

const
  MAX_CLIENTS = 32;

var
  pShm: POMMSharedMemory;
  LibEngine: TOMMLibraryEngine;
  Watchdog: TOmmWatchdog;
  Router: TOmmRouter;
  serverFD: cint;
  pollCount: cint;
  pollFds: array[0..MAX_CLIENTS] of {$IFDEF UNIX}TPollFD{$ELSE}pollfd{$ENDIF};
  clientCount: Integer;
  k: Integer;
  newClient: cint;
  reqPkt: TOMMPacket;
  lastSec, nowSec, startTimeSec: UInt32;
  {$IFDEF UNIX}
  sigAct: SigactionRec;
  {$ENDIF}

begin
  ParseCommandLine;

  // Set up signal handling
  {$IFDEF UNIX}
  FillChar(sigAct, SizeOf(sigAct), 0);
  sigAct.sa_handler := SigactionHandler(@SigHandler);
  fpSigaction(SIGINT, @sigAct, nil);
  fpSigaction(SIGTERM, @sigAct, nil);
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN)); // Ignore SIGPIPE
  {$ENDIF}
  {$IFDEF WINDOWS}
  SetConsoleCtrlHandler(@WinCtrlHandler, True);
  {$ENDIF}

  // 0. Ensure any previous daemon instance bound to this socket/SHM is cleanly terminated
  EnsureSingleDaemonInstance(GSocketPath, GShmPath);

  // 1. Setup Shared Memory
  pShm := SetupSharedMemory(GShmPath);
  if pShm = nil then
  begin
    Writeln(StdErr, 'Error: Failed to initialize shared memory at ', GShmPath);
    Halt(1);
  end;

  // 2. Initialize Audio Engine
  if omm_audio_init(pShm) <> 0 then
  begin
    Writeln(StdErr, 'Warning: Audio device initialization returned non-zero (headless mode)');
  end;

  // 3. Initialize Library
  LibEngine := TOMMLibraryEngine.Create(GMusicDir, GLibraryFile);
  LibEngine.OpenLibrary;
  if pShm <> nil then
  begin
    SeqLockWriteBegin(pShm^.SeqLock);
    pShm^.TotalTracks := LibEngine.TrackCount;
    SeqLockWriteEnd(pShm^.SeqLock);
  end;

  // 4. Initialize Watchdog & Router
  Watchdog := TOmmWatchdog.Create(GPluginPath, 'daemon.lua');
  Router := TOmmRouter.Create(Watchdog, LibEngine, pShm);

  // 5. Setup Unix Domain Socket Server
  serverFD := CreateUnixSocket;
  if serverFD < 0 then
  begin
    Writeln(StdErr, 'Error: Failed to create unix domain socket');
    Halt(1);
  end;

  if not BindAndListenUnixSocket(serverFD, GSocketPath, 32) then
  begin
    Writeln(StdErr, 'Error: Failed to bind/listen on socket: ', GSocketPath);
    fpClose(serverFD);
    Halt(1);
  end;
  SetSocketNonBlocking(serverFD);

  FillChar(pollFds, SizeOf(pollFds), 0);
  pollFds[0].fd := serverFD;
  pollFds[0].events := POLLIN;
  clientCount := 0;

  startTimeSec := fpTime;
  lastSec := startTimeSec;

  // 6. Main Server Event Loop
  while not GTerminated do
  begin
    pollCount := fpPoll(@pollFds[0], clientCount + 1, 10);
    if pollCount > 0 then
    begin
      // A. Accept new incoming client connections
      if (pollFds[0].revents and POLLIN) <> 0 then
      begin
        newClient := AcceptUnixSocket(serverFD);
        while newClient >= 0 do
        begin
          if clientCount < MAX_CLIENTS then
          begin
            SetSocketNonBlocking(newClient);
            Inc(clientCount);
            pollFds[clientCount].fd := newClient;
            pollFds[clientCount].events := POLLIN or POLLHUP or POLLERR;
            pollFds[clientCount].revents := 0;
          end
          else
            fpClose(newClient);
          newClient := AcceptUnixSocket(serverFD);
        end;
      end;

      // B. Process active clients
      k := 1;
      while k <= clientCount do
      begin
        if (pollFds[k].revents and (POLLHUP or POLLERR or POLLNVAL)) <> 0 then
        begin
          fpClose(pollFds[k].fd);
          pollFds[k] := pollFds[clientCount];
          Dec(clientCount);
        end
        else if (pollFds[k].revents and POLLIN) <> 0 then
        begin
          if RecvPacket(pollFds[k].fd, reqPkt) then
          begin
            ProcessClientRequest(pollFds[k].fd, reqPkt, pShm, LibEngine, Watchdog, Router);
            Inc(k);
          end
          else
          begin
            fpClose(pollFds[k].fd);
            pollFds[k] := pollFds[clientCount];
            Dec(clientCount);
          end;
        end
        else
          Inc(k);
      end;
    end;

    // Check gapless transition and prefetch trigger (~10ms reactor cadence)
    Router.CheckPrefetchTrigger;

    // Periodic 1-second ticks
    nowSec := fpTime;
    if nowSec <> lastSec then
    begin
      if (pShm <> nil) and (pShm^.DaemonPID <> UInt32(fpGetPID)) then
      begin
        GTerminated := True;
        Break;
      end;

      Watchdog.Tick(nowSec - lastSec);

      if pShm <> nil then
      begin
        SeqLockWriteBegin(pShm^.SeqLock);
        pShm^.PluginState := Watchdog.State;
        pShm^.PluginIdleSecs := Watchdog.IdleSeconds;
        pShm^.PluginRssBytes := Watchdog.RssBytes;
        pShm^.DaemonUptimeSecs := nowSec - startTimeSec;
        SeqLockWriteEnd(pShm^.SeqLock);
      end;
      lastSec := nowSec;
    end;
  end;

  // 7. Graceful Teardown
  for k := 1 to clientCount do
    fpClose(pollFds[k].fd);
  Router.Free;
  Watchdog.Free;
  LibEngine.Free;
  omm_audio_uninit();
  fpClose(serverFD);
  fpUnlink(PChar(GSocketPath));
  fpUnlink(PChar(GSocketPath + '.pid'));
  if pShm <> nil then
    CloseSharedMemory(pShm);
end.
