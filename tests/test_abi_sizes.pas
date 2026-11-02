program TestABISizes;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  BaseUnix, Sockets, SysUtils, omm_ipc, omm_shm;

const
  TEST_SOCKET_PATH = '/tmp/test_omm_loopback.sock';
  TEST_SHM_NAME    = '/omm_test_shm_m1';

var
  Pkt: TOMMPacket;
  Shm: TOMMSharedMemory;
  Rec: TOMMTrackRecord;
  Stat: TOmmPluginStatus;
  Vt: TOmmPluginVTable;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ASSERTION FAILED: ', Msg);
    Halt(1);
  end;
end;

procedure TestSizesAndOffsets;
begin
  WriteLn('=== FPC ABI Sizes & Offsets Verification ===');

  // 1. Structure Sizes
  WriteLn('[1] Checking Structure Sizes...');
  WriteLn('  SizeOf(TOMMCondensedTrack) = ', SizeOf(TOMMCondensedTrack), ' (expected 480)');
  Check(SizeOf(TOMMCondensedTrack) = 480, 'SizeOf(TOMMCondensedTrack) = 480');

  WriteLn('  SizeOf(TOMMPacketPayload)  = ', SizeOf(TOMMPacketPayload), ' (expected 496)');
  Check(SizeOf(TOMMPacketPayload) = 496, 'SizeOf(TOMMPacketPayload) = 496');

  WriteLn('  SizeOf(TOMMPacket)         = ', SizeOf(TOMMPacket), ' (expected 512)');
  Check(SizeOf(TOMMPacket) = 512, 'SizeOf(TOMMPacket) = 512');

  WriteLn('  SizeOf(TOMMSharedMemory)   = ', SizeOf(TOMMSharedMemory), ' (expected 65536)');
  Check(SizeOf(TOMMSharedMemory) = 65536, 'SizeOf(TOMMSharedMemory) = 65536');

  WriteLn('  SizeOf(TOMMTrackRecord)    = ', SizeOf(TOMMTrackRecord), ' (expected 512)');
  Check(SizeOf(TOMMTrackRecord) = 512, 'SizeOf(TOMMTrackRecord) = 512');

  WriteLn('  SizeOf(TOmmPluginStatus)   = ', SizeOf(TOmmPluginStatus), ' (expected 24)');
  Check(SizeOf(TOmmPluginStatus) = 24, 'SizeOf(TOmmPluginStatus) = 24');

  WriteLn('  SizeOf(TOmmPluginVTable)   = ', SizeOf(TOmmPluginVTable), ' (expected 96)');
  Check(SizeOf(TOmmPluginVTable) = 96, 'SizeOf(TOmmPluginVTable) = 96');

  WriteLn('  SizeOf(TOmmPluginGetVTableFn) = ', SizeOf(TOmmPluginGetVTableFn), ' (expected ', SizeOf(Pointer), ')');
  Check(SizeOf(TOmmPluginGetVTableFn) = SizeOf(Pointer), 'SizeOf(TOmmPluginGetVTableFn) = SizeOf(Pointer)');

  // 2. Packet Offsets
  WriteLn('[2] Checking TOMMPacket Offsets...');
  Check((PtruInt(@Pkt.Magic) - PtruInt(@Pkt)) = 0, 'Pkt.Magic offset = 0');
  Check((PtruInt(@Pkt.Version) - PtruInt(@Pkt)) = 4, 'Pkt.Version offset = 4');
  Check((PtruInt(@Pkt.Opcode) - PtruInt(@Pkt)) = 6, 'Pkt.Opcode offset = 6');
  Check((PtruInt(@Pkt.SeqID) - PtruInt(@Pkt)) = 8, 'Pkt.SeqID offset = 8');
  Check((PtruInt(@Pkt.StatusCode) - PtruInt(@Pkt)) = 12, 'Pkt.StatusCode offset = 12');
  Check((PtruInt(@Pkt.Payload) - PtruInt(@Pkt)) = 16, 'Pkt.Payload offset = 16');
  Check((PtruInt(@Pkt.Payload.SimilarTrackID) - PtruInt(@Pkt.Payload)) = 0, 'Payload.SimilarTrackID offset = 0');
  Check((PtruInt(@Pkt.Payload.SimilarReturnedCount) - PtruInt(@Pkt.Payload)) = 4, 'Payload.SimilarReturnedCount offset = 4');

  // 3. Shared Memory Offsets
  WriteLn('[3] Checking TOMMSharedMemory Offsets...');
  Check((PtruInt(@Shm.Magic) - PtruInt(@Shm)) = $0000, 'Shm.Magic offset = 0x0000');
  Check((PtruInt(@Shm.Version) - PtruInt(@Shm)) = $0004, 'Shm.Version offset = 0x0004');
  Check((PtruInt(@Shm.SeqLock) - PtruInt(@Shm)) = $0008, 'Shm.SeqLock offset = 0x0008');
  Check((PtruInt(@Shm.PlaybackState) - PtruInt(@Shm)) = $0010, 'Shm.PlaybackState offset = 0x0010');
  Check((PtruInt(@Shm.PlaybackFlags) - PtruInt(@Shm)) = $0014, 'Shm.PlaybackFlags offset = 0x0014');
  Check((PtruInt(@Shm.CurrentTrackID) - PtruInt(@Shm)) = $0018, 'Shm.CurrentTrackID offset = 0x0018');
  Check((PtruInt(@Shm.PositionMs) - PtruInt(@Shm)) = $001C, 'Shm.PositionMs offset = 0x001C');
  Check((PtruInt(@Shm.DurationMs) - PtruInt(@Shm)) = $0020, 'Shm.DurationMs offset = 0x0020');
  Check((PtruInt(@Shm.Volume) - PtruInt(@Shm)) = $0024, 'Shm.Volume offset = 0x0024');
  Check((PtruInt(@Shm.SampleRate) - PtruInt(@Shm)) = $0028, 'Shm.SampleRate offset = 0x0028');
  Check((PtruInt(@Shm.Channels) - PtruInt(@Shm)) = $002C, 'Shm.Channels offset = 0x002C');
  Check((PtruInt(@Shm.BitDepth) - PtruInt(@Shm)) = $002E, 'Shm.BitDepth offset = 0x002E');
  Check((PtruInt(@Shm.BufferFillRatio) - PtruInt(@Shm)) = $0030, 'Shm.BufferFillRatio offset = 0x0030');
  Check((PtruInt(@Shm.UnderrunCounter) - PtruInt(@Shm)) = $0034, 'Shm.UnderrunCounter offset = 0x0034');
  Check((PtruInt(@Shm.PluginState) - PtruInt(@Shm)) = $0038, 'Shm.PluginState offset = 0x0038');
  Check((PtruInt(@Shm.PluginIdleSecs) - PtruInt(@Shm)) = $003C, 'Shm.PluginIdleSecs offset = 0x003C');
  Check((PtruInt(@Shm.PluginRssBytes) - PtruInt(@Shm)) = $0040, 'Shm.PluginRssBytes offset = 0x0040');
  Check((PtruInt(@Shm.DaemonPID) - PtruInt(@Shm)) = $0048, 'Shm.DaemonPID offset = 0x0048');
  Check((PtruInt(@Shm.DaemonUptimeSecs) - PtruInt(@Shm)) = $004C, 'Shm.DaemonUptimeSecs offset = 0x004C');
  Check((PtruInt(@Shm.TotalTracks) - PtruInt(@Shm)) = $0050, 'Shm.TotalTracks offset = 0x0050');
  Check((PtruInt(@Shm.ReservedHeader) - PtruInt(@Shm)) = $0054, 'Shm.ReservedHeader offset = 0x0054');
  Check((PtruInt(@Shm.TrackTitle) - PtruInt(@Shm)) = $0080, 'Shm.TrackTitle offset = 0x0080');
  Check((PtruInt(@Shm.TrackArtist) - PtruInt(@Shm)) = $0100, 'Shm.TrackArtist offset = 0x0100');
  Check((PtruInt(@Shm.TrackAlbum) - PtruInt(@Shm)) = $0180, 'Shm.TrackAlbum offset = 0x0180');
  Check((PtruInt(@Shm.VirtualURI) - PtruInt(@Shm)) = $0200, 'Shm.VirtualURI offset = 0x0200');
  Check((PtruInt(@Shm.LyricCurrent) - PtruInt(@Shm)) = $0300, 'Shm.LyricCurrent offset = 0x0300');
  Check((PtruInt(@Shm.LyricNext) - PtruInt(@Shm)) = $0400, 'Shm.LyricNext offset = 0x0400');
  Check((PtruInt(@Shm.LyricTranslation) - PtruInt(@Shm)) = $0500, 'Shm.LyricTranslation offset = 0x0500');
  Check((PtruInt(@Shm.LyricTimestampMs) - PtruInt(@Shm)) = $0600, 'Shm.LyricTimestampMs offset = 0x0600');
  Check((PtruInt(@Shm.LyricLineIdx) - PtruInt(@Shm)) = $0604, 'Shm.LyricLineIdx offset = 0x0604');
  Check((PtruInt(@Shm.ReservedLyric) - PtruInt(@Shm)) = $0608, 'Shm.ReservedLyric offset = 0x0608');
  Check((PtruInt(@Shm.SpectrumBands) - PtruInt(@Shm)) = $0700, 'Shm.SpectrumBands offset = 0x0700');
  Check((PtruInt(@Shm.SpectrumSeq) - PtruInt(@Shm)) = $0704, 'Shm.SpectrumSeq offset = 0x0704');
  Check((PtruInt(@Shm.ReservedSpec) - PtruInt(@Shm)) = $0708, 'Shm.ReservedSpec offset = 0x0708');
  Check((PtruInt(@Shm.SpectrumMags) - PtruInt(@Shm)) = $0800, 'Shm.SpectrumMags offset = 0x0800');
  Check((PtruInt(@Shm.SpectrumPeaks) - PtruInt(@Shm)) = $0900, 'Shm.SpectrumPeaks offset = 0x0900');
  Check((PtruInt(@Shm.QuantizedBars) - PtruInt(@Shm)) = $0A00, 'Shm.QuantizedBars offset = 0x0A00');
  Check((PtruInt(@Shm.QuantizedPeaks) - PtruInt(@Shm)) = $0A40, 'Shm.QuantizedPeaks offset = 0x0A40');
  Check((PtruInt(@Shm.ReservedPad) - PtruInt(@Shm)) = $0A80, 'Shm.ReservedPad offset = 0x0A80');
  Check((PtruInt(@Shm.OscilloscopeTap) - PtruInt(@Shm)) = $0B00, 'Shm.OscilloscopeTap offset = 0x0B00');
  Check((PtruInt(@Shm.ReservedPayload) - PtruInt(@Shm)) = $1300, 'Shm.ReservedPayload offset = 0x1300');

  // 4. Track Record Offsets
  WriteLn('[4] Checking TOMMTrackRecord Offsets...');
  Check((PtruInt(@Rec.TrackID) - PtruInt(@Rec)) = 0, 'Rec.TrackID offset = 0');
  Check((PtruInt(@Rec.DurationMs) - PtruInt(@Rec)) = 4, 'Rec.DurationMs offset = 4');
  Check((PtruInt(@Rec.Year) - PtruInt(@Rec)) = 8, 'Rec.Year offset = 8');
  Check((PtruInt(@Rec.TrackNo) - PtruInt(@Rec)) = 10, 'Rec.TrackNo offset = 10');
  Check((PtruInt(@Rec.BitrateKbps) - PtruInt(@Rec)) = 12, 'Rec.BitrateKbps offset = 12');
  Check((PtruInt(@Rec.FormatTag) - PtruInt(@Rec)) = 14, 'Rec.FormatTag offset = 14');
  Check((PtruInt(@Rec.Title) - PtruInt(@Rec)) = 16, 'Rec.Title offset = 16');
  Check((PtruInt(@Rec.Artist) - PtruInt(@Rec)) = 144, 'Rec.Artist offset = 144');
  Check((PtruInt(@Rec.Album) - PtruInt(@Rec)) = 240, 'Rec.Album offset = 240');
  Check((PtruInt(@Rec.RelativePath) - PtruInt(@Rec)) = 336, 'Rec.RelativePath offset = 336');
  Check((PtruInt(@Rec.TfIdfVector) - PtruInt(@Rec)) = 464, 'Rec.TfIdfVector offset = 464');
  Check((PtruInt(@Rec.VectorNorm) - PtruInt(@Rec)) = 496, 'Rec.VectorNorm offset = 496');
  Check((PtruInt(@Rec.Reserved) - PtruInt(@Rec)) = 500, 'Rec.Reserved offset = 500');

  // 5. Plugin Status & VTable Offsets
  WriteLn('[5] Checking TOmmPluginStatus & TOmmPluginVTable Offsets...');
  Check((PtruInt(@Stat.ProtocolVersion) - PtruInt(@Stat)) = 0, 'Stat.ProtocolVersion offset = 0');
  Check((PtruInt(@Stat.State) - PtruInt(@Stat)) = 4, 'Stat.State offset = 4');
  Check((PtruInt(@Stat.RssBytes) - PtruInt(@Stat)) = 8, 'Stat.RssBytes offset = 8');
  Check((PtruInt(@Stat.ActiveStreams) - PtruInt(@Stat)) = 16, 'Stat.ActiveStreams offset = 16');
  Check((PtruInt(@Stat.IdleSeconds) - PtruInt(@Stat)) = 20, 'Stat.IdleSeconds offset = 20');

  Check((PtruInt(@Vt.ProtocolVersion) - PtruInt(@Vt)) = 0, 'Vt.ProtocolVersion offset = 0');
  Check((PtruInt(@Vt.Init) - PtruInt(@Vt)) = 8, 'Vt.Init offset = 8');
  Check((PtruInt(@Vt.FetchLyrics) - PtruInt(@Vt)) = 88, 'Vt.FetchLyrics offset = 88');

  WriteLn('ALL FPC ABI STATIC ASSERTIONS PASSED!');
end;

procedure TestUDSLoopback;
var
  ServerFD, ClientFD, ConnFD: cint;
  ReqPkt, RespPkt: TOMMPacket;
begin
  WriteLn('[6] Testing Unix Domain Socket Loopback (omm_ipc)...');
  
  ServerFD := CreateUnixSocket;
  Check(ServerFD >= 0, 'CreateUnixSocket (server) failed');

  Check(BindAndListenUnixSocket(ServerFD, TEST_SOCKET_PATH, 4), 'BindAndListenUnixSocket failed');

  ClientFD := CreateUnixSocket;
  Check(ClientFD >= 0, 'CreateUnixSocket (client) failed');

  Check(ConnectUnixSocket(ClientFD, TEST_SOCKET_PATH), 'ConnectUnixSocket failed');

  ConnFD := AcceptUnixSocket(ServerFD);
  Check(ConnFD >= 0, 'AcceptUnixSocket failed');

  // Client prepares and sends PING request
  InitPacket(ReqPkt, OP_REQ_PING, 1001, 0);
  ReqPkt.Payload.TargetMs := 42000;
  Check(SendPacket(ClientFD, ReqPkt), 'Client SendPacket failed');

  // Server receives request
  FillChar(RespPkt, SizeOf(RespPkt), 0);
  Check(RecvPacket(ConnFD, RespPkt), 'Server RecvPacket failed');

  Check(RespPkt.Magic = OMM_PACKET_MAGIC, 'Server received invalid magic');
  Check(RespPkt.Opcode = OP_REQ_PING, 'Server received invalid opcode');
  Check(RespPkt.SeqID = 1001, 'Server received invalid SeqID');
  Check(RespPkt.Payload.TargetMs = 42000, 'Server received invalid payload TargetMs');
  WriteLn('  [PASS] Server received valid PING packet (magic, opcode, seq, target_ms).');

  // Server replies with PONG response
  InitPacket(RespPkt, OP_RESP_PONG, 1001, OMM_OK);
  RespPkt.Payload.TargetMs := 42000;
  Check(SendPacket(ConnFD, RespPkt), 'Server SendPacket reply failed');

  // Client receives response
  FillChar(ReqPkt, SizeOf(ReqPkt), 0);
  Check(RecvPacket(ClientFD, ReqPkt), 'Client RecvPacket failed');

  Check(ReqPkt.Magic = OMM_PACKET_MAGIC, 'Client received invalid magic');
  Check(ReqPkt.Opcode = OP_RESP_PONG, 'Client received invalid opcode');
  Check(ReqPkt.SeqID = 1001, 'Client received invalid SeqID');
  Check(ReqPkt.StatusCode = OMM_OK, 'Client received invalid status code');
  WriteLn('  [PASS] Client received valid PONG packet (magic, opcode, seq, status).');

  fpClose(ConnFD);
  fpClose(ClientFD);
  fpClose(ServerFD);
  fpUnlink(PChar(TEST_SOCKET_PATH));
  WriteLn('  [PASS] UDS loopback completed and cleaned up.');
end;

procedure TestSHMAndSeqlock;
var
  pServerShm, pClientShm: POMMSharedMemory;
  StartSeq: UInt64;
  ObservedState, ObservedPos, ObservedDur: UInt32;
  ObservedVol, ObservedMag: Single;
  ObservedTitle: string;
begin
  WriteLn('[7] Testing POSIX Shared Memory & Atomic Seqlock (omm_shm)...');

  // Ensure clean start
  UnlinkSharedMemory(TEST_SHM_NAME);

  pServerShm := CreateSharedMemory(TEST_SHM_NAME);
  Check(pServerShm <> nil, 'CreateSharedMemory failed');
  WriteLn('  [PASS] CreateSharedMemory succeeded.');

  pClientShm := OpenSharedMemory(TEST_SHM_NAME, True);
  Check(pClientShm <> nil, 'OpenSharedMemory (read-only) failed');
  WriteLn('  [PASS] OpenSharedMemory (read-only) succeeded.');

  // Server updates state within Seqlock transaction
  SeqLockWriteBegin(pServerShm^.SeqLock);
  pServerShm^.PlaybackState := OMM_STATE_PLAYING;
  pServerShm^.PlaybackFlags := OMM_FLAG_STREAMING;
  pServerShm^.PositionMs := 15420;
  pServerShm^.DurationMs := 240000;
  pServerShm^.Volume := 0.85;
  pServerShm^.SpectrumMags[0] := 0.92;
  pServerShm^.SpectrumMags[63] := 0.15;
  pServerShm^.QuantizedBars[0] := 58;
  Move('Test Track Title'#0, pServerShm^.TrackTitle[0], 17);
  SeqLockWriteEnd(pServerShm^.SeqLock);
  WriteLn('  [PASS] Server completed Seqlock write transaction.');

  // Client reads state atomically using Seqlock pattern
  repeat
    StartSeq := SeqLockReadBegin(pClientShm^.SeqLock);
    ObservedState := pClientShm^.PlaybackState;
    ObservedPos := pClientShm^.PositionMs;
    ObservedDur := pClientShm^.DurationMs;
    ObservedVol := pClientShm^.Volume;
    ObservedMag := pClientShm^.SpectrumMags[0];
    ObservedTitle := PAnsiChar(@pClientShm^.TrackTitle[0]);
  until not SeqLockReadRetry(pClientShm^.SeqLock, StartSeq);

  Check(ObservedState = OMM_STATE_PLAYING, 'ObservedState match');
  Check(ObservedPos = 15420, 'ObservedPos match');
  Check(ObservedDur = 240000, 'ObservedDur match');
  Check(Abs(ObservedVol - 0.85) <= 0.001, 'ObservedVol match');
  Check(Abs(ObservedMag - 0.92) <= 0.001, 'ObservedMag match');
  Check(ObservedTitle = 'Test Track Title', 'ObservedTitle match');
  WriteLn('  [PASS] Client verified consistent atomic read: Title="', ObservedTitle, '", Pos=', ObservedPos, ', Vol=', ObservedVol:0:2);

  CloseSharedMemory(pClientShm);
  CloseSharedMemory(pServerShm);
  UnlinkSharedMemory(TEST_SHM_NAME);
  WriteLn('  [PASS] SHM closed and unlinked successfully.');
end;

begin
  TestSizesAndOffsets;
  TestUDSLoopback;
  TestSHMAndSeqlock;
  WriteLn('========================================');
  WriteLn('  ALL ABI, IPC & SHM VERIFICATIONS PASSED! ');
  WriteLn('========================================');
end.
