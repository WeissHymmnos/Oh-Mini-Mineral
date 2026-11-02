library libcodec_ogg;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  dynlibs, ctypes, omm_codec_abi;

const
  SFM_READ = $10;

type
  TSFInfo = packed record
    frames: Int64;
    samplerate: Int32;
    channels: Int32;
    format: Int32;
    sections: Int32;
    seekable: Int32;
  end;
  PSFInfo = ^TSFInfo;

  TSFVioGetFilelen = function(user_data: Pointer): Int64; cdecl;
  TSFVioSeek       = function(offset: Int64; whence: Int32; user_data: Pointer): Int64; cdecl;
  TSFVioRead       = function(ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
  TSFVioWrite      = function(const ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
  TSFVioTell       = function(user_data: Pointer): Int64; cdecl;

  TSFVirtualIO = packed record
    get_filelen: TSFVioGetFilelen;
    seek: TSFVioSeek;
    read: TSFVioRead;
    write: TSFVioWrite;
    tell: TSFVioTell;
  end;
  PSFVirtualIO = ^TSFVirtualIO;

  TSFOpenVirtualFn = function(sfvirtual: PSFVirtualIO; mode: Int32; sfinfo: PSFInfo; user_data: Pointer): Pointer; cdecl;
  TSFReadfFloatFn  = function(sndfile: Pointer; ptr: PSingle; frames: Int64): Int64; cdecl;
  TSFSeekFn        = function(sndfile: Pointer; frames: Int64; whence: Int32): Int64; cdecl;
  TSFCloseFn       = function(sndfile: Pointer): Int32; cdecl;

  TOggSubFormat = (osfUnknown, osfVorbis, osfOpus);

  POggDecoderHandle = ^TOggDecoderHandle;
  TOggDecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    SubFormat: TOggSubFormat;
    SampleRate: UInt32;
    Channels: UInt16;
    CurrentFrame: UInt64;
    StreamSize: Int64;
    StreamPos: Int64;

    SndLib: TLibHandle;
    SndFile: Pointer;
    Vio: TSFVirtualIO;
    SfInfo: TSFInfo;
    fnOpenVirtual: TSFOpenVirtualFn;
    fnReadfFloat: TSFReadfFloatFn;
    fnSeek: TSFSeekFn;
    fnClose: TSFCloseFn;

    ReadBuf: array[0..4095] of Byte;
  end;

function VioGetFilelen(user_data: Pointer): Int64; cdecl;
var
  h: POggDecoderHandle;
  curPos, endPos: Int64;
begin
  h := POggDecoderHandle(user_data);
  if (h = nil) or not Assigned(h^.SeekCB) then Exit(0);
  if h^.StreamSize > 0 then Exit(h^.StreamSize);
  curPos := 0;
  endPos := 0;
  h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_CUR, @curPos);
  if h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_END, @endPos) = 0 then
  begin
    h^.StreamSize := endPos;
    h^.SeekCB(h^.StreamCtx, curPos, OMM_SEEK_SET, @curPos);
    Result := endPos;
  end
  else
    Result := 0;
end;

function VioSeek(offset: Int64; whence: Int32; user_data: Pointer): Int64; cdecl;
var
  h: POggDecoderHandle;
  newPos: Int64;
begin
  h := POggDecoderHandle(user_data);
  if (h = nil) or not Assigned(h^.SeekCB) then Exit(-1);
  newPos := 0;
  if h^.SeekCB(h^.StreamCtx, offset, whence, @newPos) = 0 then
  begin
    h^.StreamPos := newPos;
    Result := newPos;
  end
  else
    Result := -1;
end;

function VioRead(ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
var
  h: POggDecoderHandle;
  got: SizeUInt;
begin
  h := POggDecoderHandle(user_data);
  if (h = nil) or not Assigned(h^.ReadCB) or (count <= 0) then Exit(0);
  got := 0;
  if h^.ReadCB(h^.StreamCtx, PByte(ptr), SizeUInt(count), @got) = 0 then
  begin
    Inc(h^.StreamPos, got);
    Result := Int64(got);
  end
  else
    Result := 0;
end;

function VioWrite(const ptr: Pointer; count: Int64; user_data: Pointer): Int64; cdecl;
begin
  Result := 0;
end;

function VioTell(user_data: Pointer): Int64; cdecl;
var
  h: POggDecoderHandle;
  posNow: Int64;
begin
  h := POggDecoderHandle(user_data);
  if h = nil then Exit(0);
  if Assigned(h^.SeekCB) then
  begin
    posNow := 0;
    if h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_CUR, @posNow) = 0 then
    begin
      h^.StreamPos := posNow;
      Exit(posNow);
    end;
  end;
  Result := h^.StreamPos;
end;

procedure SniffOggSecondaryHeader(h: POggDecoderHandle);
var
  got: SizeUInt;
  segCount, pktOffset: Integer;
  dummyPos: Int64;
begin
  h^.SubFormat := osfUnknown;
  h^.SampleRate := 48000;
  h^.Channels := 2;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], 512, @got) = 0) and (got >= 48) then
  begin
    if (h^.ReadBuf[0] = Ord('O')) and (h^.ReadBuf[1] = Ord('g')) and
       (h^.ReadBuf[2] = Ord('g')) and (h^.ReadBuf[3] = Ord('S')) then
    begin
      segCount := h^.ReadBuf[26];
      pktOffset := 27 + segCount;
      if pktOffset + 16 <= Integer(got) then
      begin
        // Check Vorbis identification header: \x01 'vorbis'
        if (h^.ReadBuf[pktOffset] = 1) and
           (h^.ReadBuf[pktOffset + 1] = Ord('v')) and
           (h^.ReadBuf[pktOffset + 2] = Ord('o')) and
           (h^.ReadBuf[pktOffset + 3] = Ord('r')) and
           (h^.ReadBuf[pktOffset + 4] = Ord('b')) and
           (h^.ReadBuf[pktOffset + 5] = Ord('i')) and
           (h^.ReadBuf[pktOffset + 6] = Ord('s')) then
        begin
          h^.SubFormat := osfVorbis;
          h^.Channels := h^.ReadBuf[pktOffset + 11];
          h^.SampleRate := UInt32(h^.ReadBuf[pktOffset + 12]) or
                           (UInt32(h^.ReadBuf[pktOffset + 13]) shl 8) or
                           (UInt32(h^.ReadBuf[pktOffset + 14]) shl 16) or
                           (UInt32(h^.ReadBuf[pktOffset + 15]) shl 24);
        end
        // Check Opus identification header: 'OpusHead'
        else if (h^.ReadBuf[pktOffset] = Ord('O')) and
                (h^.ReadBuf[pktOffset + 1] = Ord('p')) and
                (h^.ReadBuf[pktOffset + 2] = Ord('u')) and
                (h^.ReadBuf[pktOffset + 3] = Ord('s')) and
                (h^.ReadBuf[pktOffset + 4] = Ord('H')) and
                (h^.ReadBuf[pktOffset + 5] = Ord('e')) and
                (h^.ReadBuf[pktOffset + 6] = Ord('a')) and
                (h^.ReadBuf[pktOffset + 7] = Ord('d')) then
        begin
          h^.SubFormat := osfOpus;
          h^.Channels := h^.ReadBuf[pktOffset + 9];
          h^.SampleRate := 48000; // Opus always decodes at 48kHz
        end;
      end;
    end;
  end;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);
  h^.StreamPos := 0;
end;

function Codec_Probe(Header16Bytes: PByte): Int32; cdecl;
begin
  if Header16Bytes = nil then Exit(OMM_CODEC_NO_MATCH);
  if (Header16Bytes[0] = Ord('O')) and (Header16Bytes[1] = Ord('g')) and
     (Header16Bytes[2] = Ord('g')) and (Header16Bytes[3] = Ord('S')) then
    Result := OMM_CODEC_MATCH
  else
    Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: POggDecoderHandle;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TOggDecoderHandle), 0);
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;

  SniffOggSecondaryHeader(h);

  h^.SndLib := LoadLibrary('libsndfile.so.1');
  if h^.SndLib <> NilHandle then
  begin
    Pointer(h^.fnOpenVirtual) := GetProcedureAddress(h^.SndLib, 'sf_open_virtual');
    Pointer(h^.fnReadfFloat)  := GetProcedureAddress(h^.SndLib, 'sf_readf_float');
    Pointer(h^.fnSeek)        := GetProcedureAddress(h^.SndLib, 'sf_seek');
    Pointer(h^.fnClose)       := GetProcedureAddress(h^.SndLib, 'sf_close');

    if Assigned(h^.fnOpenVirtual) and Assigned(h^.fnReadfFloat) then
    begin
      h^.Vio.get_filelen := @VioGetFilelen;
      h^.Vio.seek        := @VioSeek;
      h^.Vio.read        := @VioRead;
      h^.Vio.write       := @VioWrite;
      h^.Vio.tell        := @VioTell;
      FillChar(h^.SfInfo, SizeOf(h^.SfInfo), 0);
      h^.SndFile := h^.fnOpenVirtual(@h^.Vio, SFM_READ, @h^.SfInfo, h);
      if h^.SndFile <> nil then
      begin
        if h^.SfInfo.samplerate > 0 then
          h^.SampleRate := UInt32(h^.SfInfo.samplerate);
        if h^.SfInfo.channels > 0 then
          h^.Channels := UInt16(h^.SfInfo.channels);
      end;
    end;
  end;

  if h^.SampleRate = 0 then h^.SampleRate := 48000;
  if h^.Channels = 0 then h^.Channels := 2;

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: POggDecoderHandle;
  framesRead: Int64;
  gotBytes: SizeUInt;
begin
  h := POggDecoderHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

  if (h^.SndFile <> nil) and Assigned(h^.fnReadfFloat) then
  begin
    framesRead := h^.fnReadfFloat(h^.SndFile, OutPCMFloatBuffer, Int64(MaxFrames));
    if framesRead > 0 then
      Inc(h^.CurrentFrame, UInt64(framesRead));
    Exit(Int32(framesRead));
  end;

  gotBytes := 0;
  if MaxFrames < SizeOf(h^.ReadBuf) then
    framesRead := MaxFrames
  else
    framesRead := SizeOf(h^.ReadBuf);
  if h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], SizeUInt(framesRead), @gotBytes) <> 0 then
    Exit(0);
  if gotBytes = 0 then Exit(0);

  FillChar(OutPCMFloatBuffer^, MaxFrames * h^.Channels * SizeOf(Single), 0);
  Inc(h^.CurrentFrame, MaxFrames);
  Result := Int32(MaxFrames);
end;

function Codec_Seek(Handle: Pointer; TargetFrameIndex: UInt64): Int32; cdecl;
var
  h: POggDecoderHandle;
begin
  h := POggDecoderHandle(Handle);
  if h = nil then Exit(-1);

  if (h^.SndFile <> nil) and Assigned(h^.fnSeek) then
  begin
    if h^.fnSeek(h^.SndFile, Int64(TargetFrameIndex), OMM_SEEK_SET) >= 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
  end;
  Result := -1;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: POggDecoderHandle;
begin
  h := POggDecoderHandle(Handle);
  if h = nil then Exit;

  if (h^.SndFile <> nil) and Assigned(h^.fnClose) then
    h^.fnClose(h^.SndFile);
  if h^.SndLib <> NilHandle then
    UnloadLibrary(h^.SndLib);

  Dispose(h);
end;

exports
  Codec_Probe,
  Codec_Open,
  Codec_DecodeFrames,
  Codec_Seek,
  Codec_Close;

begin
end.
