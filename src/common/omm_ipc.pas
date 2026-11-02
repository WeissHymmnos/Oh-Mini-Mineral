unit omm_ipc;

{$mode objfpc}{$H+}
{$PACKRECORDS C}
{$pointermath on}

interface

uses
  BaseUnix, Sockets, ctypes;

const
  OMM_DEFAULT_SOCKET_PATH = '/tmp/omm.sock';
  OMM_PACKET_MAGIC        = $4F4D4D50; // 'OMMP' in ASCII little-endian
  OMM_PROTOCOL_VERSION    = 1;
  OMM_PACKET_SIZE         = 512;
  OMM_PAYLOAD_SIZE        = 496;
  MSG_NOSIGNAL            = $4000; // Do not generate SIGPIPE if peer closed socket

  // Request Opcodes (0x0001 - 0x00FF)
  OP_REQ_PING              = $0001;
  OP_REQ_GET_STATUS        = $0002;
  OP_REQ_PLAY              = $0003;
  OP_REQ_PAUSE             = $0004;
  OP_REQ_RESUME            = $0005;
  OP_REQ_STOP              = $0006;
  OP_REQ_SEEK              = $0007; // Payload: TargetMs: UInt32
  OP_REQ_SET_VOLUME        = $0008; // Payload: Volume: Single (0.0 .. 1.0)
  OP_REQ_PLAY_URI          = $0009; // Payload: URI: array[0..479] of AnsiChar
  OP_REQ_PLAY_TRACK_ID     = $000A; // Payload: TrackID: UInt32
  OP_REQ_VIEWPORT          = $0010; // Payload: ViewportOffset, ViewportLimit: UInt32, FilterLen: UInt16, FilterText: array[0..125] of AnsiChar
  OP_REQ_QUERY_SIMILAR     = $0011; // Payload: TrackID: UInt32, Limit: UInt32
  OP_REQ_RESCAN_LIBRARY    = $0012;
  OP_REQ_PLUGIN_WAKE       = $0020;
  OP_REQ_PLUGIN_SUSPEND    = $0021;
  OP_REQ_PLUGIN_UNLOAD     = $0022;
  OP_REQ_MINERAL_SEARCH    = $0023; // Payload: URI: array[0..479] of AnsiChar (UTF-8 search query)
  OP_REQ_GET_LYRICS        = $0030; // Payload: TrackID: UInt32

  // Response Opcodes (0x8001 - 0x80FF)
  OP_RESP_PONG             = $8001;
  OP_RESP_STATUS           = $8002;
  OP_RESP_OK               = $8003;
  OP_RESP_ERROR            = $8004; // Payload: ErrorCode: Int32, Message: array[0..255] of AnsiChar
  OP_RESP_VIEWPORT_HEADER  = $8010; // Payload: TotalTracks, FilteredTracks, Offset, ReturnedCount: UInt32
  OP_RESP_VIEWPORT_ITEM    = $8011; // Payload: TrackItem: TOMMCondensedTrack, Reserved: array[0..15] of Byte
  OP_RESP_SIMILAR_HEADER   = $8012; // Payload: TrackID, ReturnedCount: UInt32
  OP_RESP_SIMILAR_ITEM     = $8013; // Payload: SimilarScore: Single, SimilarTrack: TOMMCondensedTrack, Reserved: array[0..11] of Byte
  OP_RESP_MINERAL_SEARCH_HEADER = $8023; // Payload: TotalTracks, FilteredTracks, PageOffset, ReturnedCount: UInt32
  OP_RESP_MINERAL_SEARCH_ITEM   = $8024; // Payload: TrackItem: TOMMCondensedTrack, Reserved: array[0..15] of Byte
  OP_RESP_LYRICS_LINE      = $8030; // Payload: TimestampMs: UInt32, LineText: array[0..255] of AnsiChar

  // Audio Format Tags
  OMM_FORMAT_UNKNOWN = 0;
  OMM_FORMAT_FLAC    = 1;
  OMM_FORMAT_MP3     = 2;
  OMM_FORMAT_OGG     = 3;
  OMM_FORMAT_WAV     = 4;
  OMM_FORMAT_AAC     = 5;

  // Standard Error Codes
  OMM_OK                   =  0;
  OMM_ERR_GENERIC          = -1;
  OMM_ERR_INVALID_PARAM    = -2;
  OMM_ERR_BUFFER_TOO_SMALL = -3;
  OMM_ERR_UNSUPPORTED_URI  = -4;
  OMM_ERR_NETWORK_FAILURE  = -5;
  OMM_ERR_STREAM_EOF       = -6;
  OMM_ERR_STREAM_TIMEOUT   = -7;
  OMM_ERR_SUSPENDED        = -8;
  OMM_ERR_AUTH_REQUIRED    = -9;
  OMM_ERR_DECODE_FAILURE   = -10;
  OMM_ERR_PANIC            = -999;

type
  // 480-byte condensed track record for viewport responses
  TOMMCondensedTrack = packed record
    TrackID: UInt32;                  // 4 bytes: 1-based unique track ID
    DurationMs: UInt32;               // 4 bytes: Duration in milliseconds
    Year: UInt16;                     // 2 bytes: Release year
    TrackNo: UInt16;                  // 2 bytes: Track number on album
    BitrateKbps: UInt16;              // 2 bytes: Encoded bitrate in kbps
    FormatTag: UInt16;                // 2 bytes: 1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC
    Title: array[0..127] of AnsiChar; // 128 bytes: Null-terminated UTF-8
    Artist: array[0..95] of AnsiChar; // 96 bytes: Null-terminated UTF-8
    Album: array[0..95] of AnsiChar;  // 96 bytes: Null-terminated UTF-8
    URI: array[0..143] of AnsiChar;   // 144 bytes: Null-terminated UTF-8 URI
  end; // Total: 4 + 4 + 2 + 2 + 2 + 2 + 128 + 96 + 96 + 144 = 480 bytes
  POMMCondensedTrack = ^TOMMCondensedTrack;

  // 496-byte packet payload union
  TOMMPacketPayload = packed record
    case Integer of
      0: ( Raw: array[0..495] of Byte );
      1: ( TargetMs: UInt32 ); // Seek command
      2: ( Volume: Single );   // Volume command (0.0 .. 1.0)
      3: ( URI: array[0..479] of AnsiChar ); // Play URI command
      4: ( TrackID: UInt32 );  // Play Track ID / Lyric request
      5: ( // Viewport request
           ViewportOffset: UInt32;
           ViewportLimit: UInt32;
           FilterLen: UInt16;
           FilterText: array[0..125] of AnsiChar;
         );
      6: ( // Viewport header response
           TotalTracks: UInt32;
           FilteredTracks: UInt32;
           PageOffset: UInt32;
           ReturnedCount: UInt32;
         );
      7: ( // Viewport item response (480 + 16 = 496 bytes)
           TrackItem: TOMMCondensedTrack;
           TrackReserved: array[0..15] of Byte;
         );
      8: ( // Query similar request
           QueryTrackID: UInt32;
           QueryLimit: UInt32;
         );
      9: ( // Similar item response (4 + 480 + 12 = 496 bytes)
           SimilarScore: Single;
           SimilarTrack: TOMMCondensedTrack;
           SimilarReserved: array[0..11] of Byte;
         );
      10: ( // Error response
            ErrorCode: Int32;
            ErrorMessage: array[0..255] of AnsiChar;
            ErrorReserved: array[0..235] of Byte;
          );
      11: ( // Lyrics response line
            LyricTimestampMs: UInt32;
            LyricText: array[0..255] of AnsiChar;
            LyricReserved: array[0..235] of Byte;
          );
      12: ( // Similar header response
            SimilarTrackID: UInt32;
            SimilarReturnedCount: UInt32;
          );
  end;

  // Exactly 512 bytes
  TOMMPacket = packed record
    Magic: UInt32;              // 0x0000 (4 bytes): 0x4F4D4D50 ('OMMP')
    Version: UInt16;            // 0x0004 (2 bytes): Protocol version (1)
    Opcode: UInt16;             // 0x0006 (2 bytes): Command or response opcode
    SeqID: UInt32;              // 0x0008 (4 bytes): Packet sequence number
    StatusCode: Int32;          // 0x000C (4 bytes): Status code (0 for requests, <= 0 for error responses)
    Payload: TOMMPacketPayload; // 0x0010 (496 bytes): Payload union
  end; // Total: 512 bytes
  POMMPacket = ^TOMMPacket;

// Helper Routines
procedure InitPacket(var Packet: TOMMPacket; Opcode: UInt16; SeqID: UInt32; StatusCode: Int32 = 0);
function CreateUnixSocket: cint;
function SetSocketNonBlocking(SocketFD: cint): Boolean;
function BindAndListenUnixSocket(SocketFD: cint; const SocketPath: string = OMM_DEFAULT_SOCKET_PATH; Backlog: cint = 16): Boolean;
function ConnectUnixSocket(SocketFD: cint; const SocketPath: string = OMM_DEFAULT_SOCKET_PATH): Boolean;
function AcceptUnixSocket(ServerFD: cint): cint;
function PollSocket(SocketFD: cint; Events: cshort; TimeoutMs: cint): cint;
function SendPacket(SocketFD: cint; const Packet: TOMMPacket): Boolean;
function RecvPacket(SocketFD: cint; var Packet: TOMMPacket): Boolean;
function RecvPacketNonBlocking(SocketFD: cint; var Packet: TOMMPacket): cint;

implementation

procedure InitPacket(var Packet: TOMMPacket; Opcode: UInt16; SeqID: UInt32; StatusCode: Int32);
begin
  FillChar(Packet, SizeOf(TOMMPacket), 0);
  Packet.Magic := OMM_PACKET_MAGIC;
  Packet.Version := OMM_PROTOCOL_VERSION;
  Packet.Opcode := Opcode;
  Packet.SeqID := SeqID;
  Packet.StatusCode := StatusCode;
end;

function CreateUnixSocket: cint;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
end;

function SetSocketNonBlocking(SocketFD: cint): Boolean;
var
  flags: cint;
begin
  flags := fpFCNTL(SocketFD, F_GETFL, 0);
  if flags < 0 then Exit(False);
  Result := (fpFCNTL(SocketFD, F_SETFL, flags or O_NONBLOCK) = 0);
end;

function BindAndListenUnixSocket(SocketFD: cint; const SocketPath: string; Backlog: cint): Boolean;
var
  addr: sockaddr_un;
  pathLen: Integer;
begin
  Result := False;
  if SocketFD < 0 then Exit;

  fpUnlink(PChar(SocketPath));
  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;

  pathLen := Length(SocketPath);
  if pathLen > 0 then
  begin
    if pathLen > 107 then pathLen := 107;
    Move(SocketPath[1], addr.sun_path[0], pathLen);
  end;

  if fpBind(SocketFD, @addr, SizeOf(addr)) <> 0 then Exit;
  if fpListen(SocketFD, Backlog) <> 0 then Exit;

  Result := True;
end;

function ConnectUnixSocket(SocketFD: cint; const SocketPath: string): Boolean;
var
  addr: sockaddr_un;
  pathLen: Integer;
begin
  Result := False;
  if SocketFD < 0 then Exit;

  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;

  pathLen := Length(SocketPath);
  if pathLen > 0 then
  begin
    if pathLen > 107 then pathLen := 107;
    Move(SocketPath[1], addr.sun_path[0], pathLen);
  end;

  Result := (fpConnect(SocketFD, @addr, SizeOf(addr)) = 0);
end;

function AcceptUnixSocket(ServerFD: cint): cint;
begin
  Result := fpAccept(ServerFD, nil, nil);
end;

function PollSocket(SocketFD: cint; Events: cshort; TimeoutMs: cint): cint;
var
  pfd: TPollFD;
  res: cint;
begin
  pfd.fd := SocketFD;
  pfd.events := Events;
  pfd.revents := 0;
  res := fpPoll(@pfd, 1, TimeoutMs);
  if res > 0 then
    Result := pfd.revents
  else
    Result := res;
end;

function SendPacket(SocketFD: cint; const Packet: TOMMPacket): Boolean;
var
  total, n: ssize_t;
  buf: PByte;
begin
  total := 0;
  buf := PByte(@Packet);
  while total < SizeOf(TOMMPacket) do
  begin
    n := fpSend(SocketFD, @buf[total], SizeOf(TOMMPacket) - total, MSG_NOSIGNAL);
    if n <= 0 then
    begin
      if (n < 0) and (fpGetErrno = ESysEINTR) then
        Continue;
      Exit(False);
    end;
    Inc(total, n);
  end;
  Result := True;
end;

function RecvPacket(SocketFD: cint; var Packet: TOMMPacket): Boolean;
var
  total, n: ssize_t;
  buf: PByte;
begin
  total := 0;
  buf := PByte(@Packet);
  while total < SizeOf(TOMMPacket) do
  begin
    n := fpRead(SocketFD, @buf[total], SizeOf(TOMMPacket) - total);
    if n <= 0 then
    begin
      if (n < 0) and (fpGetErrno = ESysEINTR) then
        Continue;
      Exit(False);
    end;
    Inc(total, n);
  end;
  Result := (Packet.Magic = OMM_PACKET_MAGIC);
end;

function RecvPacketNonBlocking(SocketFD: cint; var Packet: TOMMPacket): cint;
var
  pollRes: cint;
begin
  pollRes := PollSocket(SocketFD, POLLIN, 0);
  if pollRes < 0 then
    Exit(-1); // Socket error
  if (pollRes and POLLIN) = 0 then
    Exit(0);  // Would block, no data ready

  if RecvPacket(SocketFD, Packet) then
    Result := 1
  else
    Result := -1; // Peer disconnected or malformed packet
end;

end.
