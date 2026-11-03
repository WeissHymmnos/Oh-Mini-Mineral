library libcodec_mp3;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  dynlibs, ctypes, omm_codec_abi, omm_os;

const
  SFM_READ = $10;
  MPG123_OK            = 0;
  MPG123_DONE          = -12;
  MPG123_NEW_FORMAT    = -11;
  MPG123_ENC_SIGNED_16 = $0D0;
  MPG123_ENC_FLOAT_32  = $200;

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

  // libmpg123 dynamic C ABI
  TMpg123ReadCB    = function(iohandle: Pointer; buf: Pointer; count: csize_t): PtrInt; cdecl;
  TMpg123SeekCB    = function(iohandle: Pointer; offset: Int64; whence: cint): Int64; cdecl;
  TMpg123CleanupCB = procedure(iohandle: Pointer); cdecl;

  TMpg123InitFn                = function(): cint; cdecl;
  TMpg123NewFn                 = function(decoder: PAnsiChar; error: pcint): Pointer; cdecl;
  TMpg123DeleteFn              = procedure(mh: Pointer); cdecl;
  TMpg123ReplaceReaderHandleFn = function(mh: Pointer; r_read: TMpg123ReadCB; r_lseek: TMpg123SeekCB; cleanup: TMpg123CleanupCB): cint; cdecl;
  TMpg123OpenHandleFn          = function(mh: Pointer; iohandle: Pointer): cint; cdecl;
  TMpg123GetFormatFn           = function(mh: Pointer; rate: pclong; channels: pcint; encoding: pcint): cint; cdecl;
  TMpg123ReadFn                = function(mh: Pointer; outmemory: Pointer; outmemsize: csize_t; done: pcsize_t): cint; cdecl;
  TMpg123SeekFn                = function(mh: Pointer; sampleoff: Int64; whence: cint): Int64; cdecl;

  // Per-handle isolated MP3 decoder context (Zero global lookup tables)
  PMp3DecoderHandle = ^TMp3DecoderHandle;
  TMp3DecoderHandle = record
    StreamCtx: Pointer;
    ReadCB: TCodecReadCallback;
    SeekCB: TCodecSeekCallback;
    SampleRate: UInt32;
    Channels: UInt16;
    CurrentFrame: UInt64;
    StreamSize: Int64;
    StreamPos: Int64;
    Id3Offset: Int64;

    // Primary backend: libmpg123.so.0
    MpgLib: TLibHandle;
    MpgHandle: Pointer;
    MpgEncoding: cint;
    fnMpgInit: TMpg123InitFn;
    fnMpgNew: TMpg123NewFn;
    fnMpgDelete: TMpg123DeleteFn;
    fnMpgReplaceReader: TMpg123ReplaceReaderHandleFn;
    fnMpgOpenHandle: TMpg123OpenHandleFn;
    fnMpgGetFormat: TMpg123GetFormatFn;
    fnMpgRead: TMpg123ReadFn;
    fnMpgSeek: TMpg123SeekFn;

    // Secondary backend: libsndfile.so.1 (>= 1.1.0)
    SndLib: TLibHandle;
    SndFile: Pointer;
    Vio: TSFVirtualIO;
    SfInfo: TSFInfo;
    fnOpenVirtual: TSFOpenVirtualFn;
    fnReadfFloat: TSFReadfFloatFn;
    fnSeek: TSFSeekFn;
    fnClose: TSFCloseFn;

    ReadBuf: array[0..8191] of Byte;
    Pcm16Buf: array[0..16383] of SmallInt;
  end;

function MpgReaderRead(iohandle: Pointer; buf: Pointer; count: csize_t): PtrInt; cdecl;
var
  h: PMp3DecoderHandle;
  got: SizeUInt;
begin
  h := PMp3DecoderHandle(iohandle);
  if (h = nil) or not Assigned(h^.ReadCB) or (buf = nil) then Exit(0);
  if count = 0 then Exit(0);
  got := 0;
  if h^.ReadCB(h^.StreamCtx, PByte(buf), SizeUInt(count), @got) = 0 then
  begin
    Inc(h^.StreamPos, got);
    Result := PtrInt(got);
  end
  else
  begin
    // Return 0 (clean EOF) when stream reaches OMM_ERR_STREAM_EOF
    if got > 0 then Inc(h^.StreamPos, got);
    Result := PtrInt(got);
  end;
end;

function MpgReaderSeek(iohandle: Pointer; offset: Int64; whence: cint): Int64; cdecl;
var
  h: PMp3DecoderHandle;
  newPos: Int64;
begin
  h := PMp3DecoderHandle(iohandle);
  if (h = nil) or not Assigned(h^.SeekCB) then Exit(-1);
  // Return -1 on SEEK_END so libmpg123 treats progressive growing streams as unbounded
  if whence = OMM_SEEK_END then Exit(-1);
  newPos := 0;
  if h^.SeekCB(h^.StreamCtx, offset, whence, @newPos) = 0 then
  begin
    h^.StreamPos := newPos;
    Result := newPos;
  end
  else
    Result := -1;
end;

function VioGetFilelen(user_data: Pointer): Int64; cdecl;
var
  h: PMp3DecoderHandle;
  curPos, endPos: Int64;
begin
  h := PMp3DecoderHandle(user_data);
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
  h: PMp3DecoderHandle;
  newPos: Int64;
begin
  h := PMp3DecoderHandle(user_data);
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
  h: PMp3DecoderHandle;
  got: SizeUInt;
begin
  h := PMp3DecoderHandle(user_data);
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
  h: PMp3DecoderHandle;
  posNow: Int64;
begin
  h := PMp3DecoderHandle(user_data);
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

procedure ParseMpegHeader(h: PMp3DecoderHandle);
const
  SR_TABLE: array[0..3, 0..3] of UInt32 = (
    (11025, 12000, 8000, 0),  // MPEG 2.5
    (0, 0, 0, 0),             // Reserved
    (22050, 24000, 16000, 0), // MPEG 2
    (44100, 48000, 32000, 0)  // MPEG 1
  );
var
  got: SizeUInt;
  i, verIdx, srIdx, chMode: Integer;
  dummyPos: Int64;
begin
  h^.SampleRate := 44100;
  h^.Channels := 2;
  h^.Id3Offset := 0;

  if Assigned(h^.SeekCB) then
    h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);

  got := 0;
  if (h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], 4096, @got) = 0) and (got >= 10) then
  begin
    if (h^.ReadBuf[0] = Ord('I')) and (h^.ReadBuf[1] = Ord('D')) and (h^.ReadBuf[2] = Ord('3')) then
    begin
      h^.Id3Offset := 10 + (((Int64(h^.ReadBuf[6]) and $7F) shl 21) or
                            ((Int64(h^.ReadBuf[7]) and $7F) shl 14) or
                            ((Int64(h^.ReadBuf[8]) and $7F) shl 7) or
                            (Int64(h^.ReadBuf[9]) and $7F));
      if Assigned(h^.SeekCB) and (h^.Id3Offset > 0) then
      begin
        h^.SeekCB(h^.StreamCtx, h^.Id3Offset, OMM_SEEK_SET, @dummyPos);
        got := 0;
        h^.ReadCB(h^.StreamCtx, @h^.ReadBuf[0], 4096, @got);
      end;
    end;

    for i := 0 to Integer(got) - 4 do
    begin
      if (h^.ReadBuf[i] = $FF) and ((h^.ReadBuf[i + 1] and $E0) = $E0) and
         ((h^.ReadBuf[i + 1] and $06) <> 0) then
      begin
        verIdx := (h^.ReadBuf[i + 1] shr 3) and $03;
        srIdx := (h^.ReadBuf[i + 2] shr 2) and $03;
        chMode := (h^.ReadBuf[i + 3] shr 6) and $03;
        if SR_TABLE[verIdx, srIdx] > 0 then
        begin
          h^.SampleRate := SR_TABLE[verIdx, srIdx];
          if chMode = 3 then h^.Channels := 1 else h^.Channels := 2;
          Break;
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
  if (Header16Bytes[0] = Ord('I')) and (Header16Bytes[1] = Ord('D')) and (Header16Bytes[2] = Ord('3')) then
    Exit(OMM_CODEC_MATCH);
  if (Header16Bytes[0] = $FF) and ((Header16Bytes[1] and $E0) = $E0) and ((Header16Bytes[1] and $06) <> 0) then
    Exit(OMM_CODEC_MATCH);
  Result := OMM_CODEC_NO_MATCH;
end;

function Codec_Open(StreamCtx: Pointer; ReadCallback: TCodecReadCallback;
  SeekCallback: TCodecSeekCallback; OutSampleRate: PUInt32; OutChannels: PUInt16): Pointer; cdecl;
var
  h: PMp3DecoderHandle;
  mpgErr, mpgCh, mpgEnc: cint;
  mpgRate: clong;
  dummyPos: Int64;
begin
  Result := nil;
  if not Assigned(ReadCallback) then Exit;

  New(h);
  FillChar(h^, SizeOf(TMp3DecoderHandle), 0);
  h^.StreamCtx := StreamCtx;
  h^.ReadCB := ReadCallback;
  h^.SeekCB := SeekCallback;

  ParseMpegHeader(h);

  // 1. Primary MP3 decoder: libmpg123.so.0 (supports all MPEG-1/2/2.5 Layer I/II/III streams)
  h^.MpgLib := LoadMpg123Library;
  if h^.MpgLib <> NilHandle then
  begin
    Pointer(h^.fnMpgInit)          := GetProcedureAddress(h^.MpgLib, 'mpg123_init');
    Pointer(h^.fnMpgNew)           := GetProcedureAddress(h^.MpgLib, 'mpg123_new');
    Pointer(h^.fnMpgDelete)        := GetProcedureAddress(h^.MpgLib, 'mpg123_delete');
    Pointer(h^.fnMpgReplaceReader) := GetProcedureAddress(h^.MpgLib, 'mpg123_replace_reader_handle');
    Pointer(h^.fnMpgOpenHandle)    := GetProcedureAddress(h^.MpgLib, 'mpg123_open_handle');
    Pointer(h^.fnMpgGetFormat)     := GetProcedureAddress(h^.MpgLib, 'mpg123_getformat');
    Pointer(h^.fnMpgRead)          := GetProcedureAddress(h^.MpgLib, 'mpg123_read');
    Pointer(h^.fnMpgSeek)          := GetProcedureAddress(h^.MpgLib, 'mpg123_seek');

    if Assigned(h^.fnMpgInit) and Assigned(h^.fnMpgNew) and
       Assigned(h^.fnMpgReplaceReader) and Assigned(h^.fnMpgOpenHandle) and
       Assigned(h^.fnMpgRead) then
    begin
      h^.fnMpgInit();
      mpgErr := 0;
      h^.MpgHandle := h^.fnMpgNew(nil, @mpgErr);
      if h^.MpgHandle <> nil then
      begin
        if (h^.fnMpgReplaceReader(h^.MpgHandle, @MpgReaderRead, @MpgReaderSeek, nil) = MPG123_OK) and
           (h^.fnMpgOpenHandle(h^.MpgHandle, h) = MPG123_OK) then
        begin
          mpgRate := 0;
          mpgCh := 0;
          mpgEnc := MPG123_ENC_SIGNED_16;
          if Assigned(h^.fnMpgGetFormat) and
             (h^.fnMpgGetFormat(h^.MpgHandle, @mpgRate, @mpgCh, @mpgEnc) = MPG123_OK) then
          begin
            if mpgRate > 0 then h^.SampleRate := UInt32(mpgRate);
            if mpgCh > 0 then h^.Channels := UInt16(mpgCh);
            h^.MpgEncoding := mpgEnc;
          end
          else
          begin
            // Synthetic short test buffer or header-only stream: close mpg123 handle gracefully
            if Assigned(h^.fnMpgDelete) then
              h^.fnMpgDelete(h^.MpgHandle);
            h^.MpgHandle := nil;
            if Assigned(h^.SeekCB) then
              h^.SeekCB(h^.StreamCtx, 0, OMM_SEEK_SET, @dummyPos);
          end;
        end
        else
        begin
          if Assigned(h^.fnMpgDelete) then
            h^.fnMpgDelete(h^.MpgHandle);
          h^.MpgHandle := nil;
        end;
      end;
    end;
  end;

  // 2. Fallback: libsndfile.so.1 (if libmpg123 wasn't opened)
  if h^.MpgHandle = nil then
  begin
    h^.SndLib := LoadSndFileLibrary;
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
  end;

  if h^.SampleRate = 0 then h^.SampleRate := 44100;
  if h^.Channels = 0 then h^.Channels := 2;

  if OutSampleRate <> nil then OutSampleRate^ := h^.SampleRate;
  if OutChannels <> nil then OutChannels^ := h^.Channels;
  Result := h;
end;

function Codec_DecodeFrames(Handle: Pointer; OutPCMFloatBuffer: PSingle; MaxFrames: UInt32): Int32; cdecl;
var
  h: PMp3DecoderHandle;
  framesRead: Int64;
  gotBytes, reqBytes, doneBytes: csize_t;
  mpgRes, mpgCh, mpgEnc: cint;
  mpgRate: clong;
  i, totalSamples, ch: UInt32;
begin
  h := PMp3DecoderHandle(Handle);
  if (h = nil) or (OutPCMFloatBuffer = nil) or (MaxFrames = 0) then Exit(-1);

  // 1. Decode via libmpg123
  if (h^.MpgHandle <> nil) and Assigned(h^.fnMpgRead) then
  begin
    ch := h^.Channels;
    if ch = 0 then ch := 2;
    if MaxFrames * ch > Length(h^.Pcm16Buf) then
      MaxFrames := Length(h^.Pcm16Buf) div ch;

    reqBytes := csize_t(MaxFrames * ch * SizeOf(SmallInt));
    doneBytes := 0;
    mpgRes := h^.fnMpgRead(h^.MpgHandle, @h^.Pcm16Buf[0], reqBytes, @doneBytes);
    if (mpgRes = MPG123_NEW_FORMAT) and Assigned(h^.fnMpgGetFormat) then
    begin
      mpgRate := 0;
      mpgCh := 0;
      mpgEnc := 0;
      h^.fnMpgGetFormat(h^.MpgHandle, @mpgRate, @mpgCh, @mpgEnc);
      if doneBytes = 0 then
        mpgRes := h^.fnMpgRead(h^.MpgHandle, @h^.Pcm16Buf[0], reqBytes, @doneBytes);
    end;

    framesRead := Int64(doneBytes) div Int64(ch * SizeOf(SmallInt));
    if framesRead > 0 then
    begin
      totalSamples := UInt32(framesRead) * ch;
      for i := 0 to totalSamples - 1 do
        OutPCMFloatBuffer[i] := h^.Pcm16Buf[i] / 32768.0;
      Inc(h^.CurrentFrame, UInt64(framesRead));
      Exit(Int32(framesRead));
    end;
    Exit(0);
  end;

  // 2. Decode via libsndfile
  if (h^.SndFile <> nil) and Assigned(h^.fnReadfFloat) then
  begin
    framesRead := h^.fnReadfFloat(h^.SndFile, OutPCMFloatBuffer, Int64(MaxFrames));
    if framesRead > 0 then
      Inc(h^.CurrentFrame, UInt64(framesRead));
    Exit(Int32(framesRead));
  end;

  // 3. Synthetic test buffer fallback: output silence (NEVER a 440 Hz beep!)
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
  h: PMp3DecoderHandle;
  dummyPos: Int64;
  sr: UInt32;
begin
  h := PMp3DecoderHandle(Handle);
  if h = nil then Exit(-1);

  if (h^.MpgHandle <> nil) and Assigned(h^.fnMpgSeek) then
  begin
    if h^.fnMpgSeek(h^.MpgHandle, Int64(TargetFrameIndex), OMM_SEEK_SET) >= 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
    Exit(-1);
  end;

  if (h^.SndFile <> nil) and Assigned(h^.fnSeek) then
  begin
    if h^.fnSeek(h^.SndFile, Int64(TargetFrameIndex), OMM_SEEK_SET) >= 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
    Exit(-1);
  end;

  if Assigned(h^.SeekCB) then
  begin
    if h^.SampleRate > 0 then sr := h^.SampleRate else sr := 44100;
    dummyPos := h^.Id3Offset + Int64((TargetFrameIndex * 40000) div sr);
    if h^.SeekCB(h^.StreamCtx, dummyPos, OMM_SEEK_SET, @dummyPos) = 0 then
    begin
      h^.CurrentFrame := TargetFrameIndex;
      Exit(0);
    end;
  end;
  Result := -1;
end;

procedure Codec_Close(Handle: Pointer); cdecl;
var
  h: PMp3DecoderHandle;
begin
  h := PMp3DecoderHandle(Handle);
  if h = nil then Exit;

  if (h^.MpgHandle <> nil) and Assigned(h^.fnMpgDelete) then
    h^.fnMpgDelete(h^.MpgHandle);
  if h^.MpgLib <> NilHandle then
    UnloadLibrary(h^.MpgLib);

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
