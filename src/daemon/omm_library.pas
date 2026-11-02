unit omm_library;

{$mode objfpc}{$H+}
{$asmmode intel}
{$PACKRECORDS C}
{$pointermath on}

interface

uses
  BaseUnix, Unix, SysUtils, Classes, Math, omm_shm, omm_ipc;

const
  OMM_LIBRARY_MAGIC   = $4F4D4D4C; // 'OMML'
  OMM_LIBRARY_VERSION = 1;
  OMM_RECORD_SIZE     = 512;
  OMM_DEFAULT_LIBRARY_PATH = 'library.bin';

type
  // Sector-aligned 512-byte library header
  TOMMLibraryHeader = packed record
    Magic: UInt32;                  // 0x0000 (4 B): 0x4F4D4D4C ('OMML')
    Version: UInt32;                // 0x0004 (4 B): Protocol version (1)
    RecordSize: UInt32;             // 0x0008 (4 B): Record size (512)
    RecordCount: UInt32;            // 0x000C (4 B): Total indexed track records
    CreatedTimestamp: UInt64;       // 0x0010 (8 B): Unix epoch seconds at library creation
    LastRescanTimestamp: UInt64;    // 0x0018 (8 B): Unix epoch seconds at last rescan
    Reserved: array[0..479] of Byte;// 0x0020 (480 B): Pad to exactly 512 bytes
  end;
  PTOMMLibraryHeader = ^TOMMLibraryHeader;

  TInt8Vector = array[0..31] of ShortInt;
  PInt8Vector = ^TInt8Vector;

  TTopCandidate = record
    TrackID: UInt32;
    Score: Single;
  end;

  TTop20List = record
    Count: Integer;
    Items: array[0..19] of TTopCandidate;
  end;

  TOMMLibraryEngine = class
  private
    FBasePtr: PByte;
    FFileSize: Int64;
    FHeader: PTOMMLibraryHeader;
    FRecords: POMMTrackRecord;
    FTrackCount: Cardinal;
    FIsOpen: Boolean;
    FFileInode: QWord;
    FFileMTime: Int64;
    FMusicDir: string;
    FLibraryFile: string;
  public
    constructor Create(const AMusicDir: string = ''; const ALibraryFile: string = '');
    destructor Destroy; override;

    function OpenLibrary: Boolean;
    procedure CloseLibrary;
    function EnsureFresh: Boolean;
    function RescanDirectory(const AMusicDir: string = ''): Boolean;
    procedure CreateDefaultSyntheticLibrary(TrackCount: Cardinal = 5000);

    function GetRecord(TrackID: Cardinal): POMMTrackRecord; inline;
    function GetRecordByIndex(Index: Cardinal): POMMTrackRecord; inline;
    function GetViewportPage(Offset, Limit: Cardinal; const Filter: string;
                             out Total, Filtered, OutCount: Cardinal;
                             OutTracks: POMMCondensedTrack; MaxOut: Cardinal): Boolean;

    property TrackCount: Cardinal read FTrackCount;
    property IsOpen: Boolean read FIsOpen;
    property LibraryFile: string read FLibraryFile;
    property MusicDir: string read FMusicDir write FMusicDir;
  end;

// Recommendation & Similarity Math
function ComputeVectorNormInt8(pVec: PShortInt): Single;
function DotProductInt8SSE(pA, pB: Pointer): LongInt;
function DotProductInt8Scalar(pA, pB: Pointer): LongInt;
function CalculateCosineSimilarity(constref Q, C: TOMMTrackRecord): Single;
procedure InsertTopCandidate(var List: TTop20List; TrackID: UInt32; Score: Single);
function QueryTopSimilar(Engine: TOMMLibraryEngine; QueryTrackID: UInt32; Limit: Integer = 20): TTop20List;
procedure GenerateTrackFeatureVector(const Title, Artist, Album: string; var Vec: TInt8Vector);

implementation

function ComputeVectorNormInt8(pVec: PShortInt): Single;
var
  i: Integer;
  sumSq: UInt32;
  v: LongInt;
begin
  sumSq := 0;
  for i := 0 to 31 do
  begin
    v := pVec[i];
    Inc(sumSq, v * v);
  end;
  Result := Sqrt(sumSq);
end;

function DotProductInt8SSE(pA, pB: Pointer): LongInt;
assembler; nostackframe;
asm
  movdqu xmm0, [rdi]        // A[0..15]
  movdqu xmm1, [rsi]        // B[0..15]
  movdqu xmm2, [rdi + 16]   // A[16..31]
  movdqu xmm3, [rsi + 16]   // B[16..31]

  pmovsxbw xmm4, xmm0       // A[0..7] as 16-bit words
  psrldq xmm0, 8
  pmovsxbw xmm5, xmm0       // A[8..15] as 16-bit words

  pmovsxbw xmm6, xmm1       // B[0..7] as 16-bit words
  psrldq xmm1, 8
  pmovsxbw xmm7, xmm1       // B[8..15] as 16-bit words

  pmaddwd xmm4, xmm6        // 4 x 32-bit sums
  pmaddwd xmm5, xmm7        // 4 x 32-bit sums
  paddd xmm4, xmm5

  pmovsxbw xmm0, xmm2       // A[16..23]
  psrldq xmm2, 8
  pmovsxbw xmm5, xmm2       // A[24..31]

  pmovsxbw xmm1, xmm3       // B[16..23]
  psrldq xmm3, 8
  pmovsxbw xmm7, xmm3       // B[24..31]

  pmaddwd xmm0, xmm1
  pmaddwd xmm5, xmm7
  paddd xmm0, xmm5
  paddd xmm4, xmm0

  movhlps xmm0, xmm4
  paddd xmm4, xmm0
  pshufd xmm0, xmm4, 1
  paddd xmm4, xmm0
  movd eax, xmm4
end;

function DotProductInt8Scalar(pA, pB: Pointer): LongInt;
var
  A: PShortInt;
  B: PShortInt;
  i: Integer;
  sum: LongInt;
begin
  A := PShortInt(pA);
  B := PShortInt(pB);
  sum := 0;
  for i := 0 to 31 do
    Inc(sum, LongInt(A[i]) * B[i]);
  Result := sum;
end;

function CalculateCosineSimilarity(constref Q, C: TOMMTrackRecord): Single;
var
  dot: LongInt;
  normProd: Single;
begin
  if (Q.VectorNorm <= 1e-6) or (C.VectorNorm <= 1e-6) then
    Exit(0.0);
  dot := DotProductInt8SSE(@Q.TfIdfVector[0], @C.TfIdfVector[0]);
  normProd := Q.VectorNorm * C.VectorNorm;
  Result := dot / normProd;
end;

procedure InsertTopCandidate(var List: TTop20List; TrackID: UInt32; Score: Single);
var
  i, j: Integer;
begin
  if List.Count < 20 then
  begin
    i := 0;
    while (i < List.Count) and (List.Items[i].Score >= Score) do
      Inc(i);
    for j := List.Count downto i + 1 do
      List.Items[j] := List.Items[j - 1];
    List.Items[i].TrackID := TrackID;
    List.Items[i].Score := Score;
    Inc(List.Count);
  end
  else if Score > List.Items[19].Score then
  begin
    i := 18;
    while (i >= 0) and (List.Items[i].Score < Score) do
    begin
      List.Items[i + 1] := List.Items[i];
      Dec(i);
    end;
    List.Items[i + 1].TrackID := TrackID;
    List.Items[i + 1].Score := Score;
  end;
end;

function QueryTopSimilar(Engine: TOMMLibraryEngine; QueryTrackID: UInt32; Limit: Integer): TTop20List;
var
  pQuery: POMMTrackRecord;
  pCand: POMMTrackRecord;
  i: Cardinal;
  sim: Single;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Engine = nil) or not Engine.IsOpen then Exit;
  pQuery := Engine.GetRecord(QueryTrackID);
  if pQuery = nil then Exit;

  if Limit > 20 then Limit := 20;
  if Limit <= 0 then Exit;

  if Engine.TrackCount > 0 then
  begin
    for i := 0 to Engine.TrackCount - 1 do
    begin
      pCand := Engine.GetRecordByIndex(i);
      if pCand^.TrackID = QueryTrackID then Continue; // Skip self

      sim := CalculateCosineSimilarity(pQuery^, pCand^);
      InsertTopCandidate(Result, pCand^.TrackID, sim);
    end;
  end;
end;

function FNV1aHash(const S: string): Cardinal;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Byte(S[i]);
    Result := Result * 16777619;
  end;
end;

procedure GenerateTrackFeatureVector(const Title, Artist, Album: string; var Vec: TInt8Vector);
var
  accum: array[0..31] of Integer;
  i, maxAbs: Integer;
  scale: Double;

  procedure ProcessString(const S: string; Weight: Integer);
  var
    tok: string;
    p, len: Integer;
    h, bucket: Cardinal;
    signVal: Integer;
  begin
    p := 1;
    len := Length(S);
    while p <= len do
    begin
      while (p <= len) and (S[p] in [' ', #9, #10, #13, '-', '_', '.', ',', '(', ')', '[', ']', '/', '\']) do
        Inc(p);
      tok := '';
      while (p <= len) and not (S[p] in [' ', #9, #10, #13, '-', '_', '.', ',', '(', ')', '[', ']', '/', '\']) do
      begin
        tok := tok + LowerCase(S[p]);
        Inc(p);
      end;
      if Length(tok) > 0 then
      begin
        h := FNV1aHash(tok);
        bucket := h mod 32;
        if (h and $80000000) <> 0 then signVal := 1 else signVal := -1;
        Inc(accum[bucket], Weight * signVal);
      end;
    end;
  end;

begin
  FillChar(Vec, SizeOf(Vec), 0);
  FillChar(accum, SizeOf(accum), 0);

  ProcessString(Artist, 3);
  ProcessString(Title, 2);
  ProcessString(Album, 1);

  maxAbs := 0;
  for i := 0 to 31 do
    if Abs(accum[i]) > maxAbs then maxAbs := Abs(accum[i]);

  if maxAbs > 0 then
  begin
    scale := 127.0 / maxAbs;
    for i := 0 to 31 do
      Vec[i] := ShortInt(Round(accum[i] * scale));
  end;
end;

constructor TOMMLibraryEngine.Create(const AMusicDir, ALibraryFile: string);
begin
  inherited Create;
  FBasePtr := nil;
  FFileSize := 0;
  FHeader := nil;
  FRecords := nil;
  FTrackCount := 0;
  FIsOpen := False;
  FMusicDir := AMusicDir;
  if ALibraryFile <> '' then
    FLibraryFile := ALibraryFile
  else
    FLibraryFile := OMM_DEFAULT_LIBRARY_PATH;
end;

destructor TOMMLibraryEngine.Destroy;
begin
  CloseLibrary;
  inherited Destroy;
end;

function TOMMLibraryEngine.OpenLibrary: Boolean;
var
  fd: cint;
  st: stat;
begin
  Result := False;
  CloseLibrary;

  if not FileExists(FLibraryFile) then
  begin
    if (FMusicDir <> '') and DirectoryExists(FMusicDir) then
      Exit(RescanDirectory(FMusicDir));
    // If library file does not exist, build synthetic library to provide ready-to-run state
    CreateDefaultSyntheticLibrary(5000);
  end;

  fd := fpOpen(PChar(FLibraryFile), O_RDONLY, 0);
  if fd < 0 then Exit;

  if (fpFStat(fd, st) <> 0) or (st.st_size < SizeOf(TOMMLibraryHeader)) or
     ((st.st_size mod OMM_RECORD_SIZE) <> 0) then
  begin
    fpClose(fd);
    Exit;
  end;

  FFileSize := st.st_size;
  FFileInode := st.st_ino;
  FFileMTime := st.st_mtime;
  FBasePtr := PByte(fpMMap(nil, FFileSize, PROT_READ, MAP_SHARED, fd, 0));
  fpClose(fd);

  if (FBasePtr = nil) or (FBasePtr = PByte(Pointer(-1))) then
  begin
    FBasePtr := nil;
    Exit;
  end;

  FHeader := PTOMMLibraryHeader(FBasePtr);
  if (FHeader^.Magic <> OMM_LIBRARY_MAGIC) or (FHeader^.Version <> OMM_LIBRARY_VERSION) or
     (FHeader^.RecordSize <> OMM_RECORD_SIZE) then
  begin
    CloseLibrary;
    Exit;
  end;

  FTrackCount := FHeader^.RecordCount;
  FRecords := POMMTrackRecord(FBasePtr + SizeOf(TOMMLibraryHeader));
  FIsOpen := True;
  Result := True;
end;

function TOMMLibraryEngine.EnsureFresh: Boolean;
var
  st: stat;
begin
  Result := False;
  if fpStat(PChar(FLibraryFile), st) = 0 then
  begin
    if (not FIsOpen) or (st.st_ino <> FFileInode) or (st.st_mtime <> FFileMTime) or (st.st_size <> FFileSize) then
      Result := OpenLibrary;
  end;
end;

procedure TOMMLibraryEngine.CloseLibrary;
begin
  if FIsOpen and (FBasePtr <> nil) then
  begin
    fpMUnmap(FBasePtr, FFileSize);
    FBasePtr := nil;
    FHeader := nil;
    FRecords := nil;
    FTrackCount := 0;
    FFileSize := 0;
    FIsOpen := False;
  end;
end;

function TOMMLibraryEngine.GetRecord(TrackID: Cardinal): POMMTrackRecord;
begin
  if (not FIsOpen) or (TrackID = 0) or (TrackID > FTrackCount) then
    Exit(nil);
  Result := @FRecords[TrackID - 1];
end;

function TOMMLibraryEngine.GetRecordByIndex(Index: Cardinal): POMMTrackRecord;
begin
  if (not FIsOpen) or (Index >= FTrackCount) then
    Exit(nil);
  Result := @FRecords[Index];
end;

function TOMMLibraryEngine.GetViewportPage(Offset, Limit: Cardinal; const Filter: string;
  out Total, Filtered, OutCount: Cardinal;
  OutTracks: POMMCondensedTrack; MaxOut: Cardinal): Boolean;
var
  i: Cardinal;
  pRec: POMMTrackRecord;
  matches: Boolean;
  filterLower, tTitle, tArtist: string;
  passedFilterCount, matchedIdx: Cardinal;
  pOut: POMMCondensedTrack;
begin
  Result := False;
  Total := FTrackCount;
  Filtered := 0;
  OutCount := 0;

  if (not FIsOpen) or (FTrackCount = 0) then
  begin
    Total := 0;
    Exit(True);
  end;

  // Clamp Limit to buffer capacity MaxOut if a destination buffer is supplied
  if (OutTracks <> nil) and (Limit > MaxOut) then
    Limit := MaxOut;

  filterLower := LowerCase(Trim(Filter));

  if filterLower = '' then
  begin
    // Fast path: no filter
    Filtered := FTrackCount;
    if (Limit = 0) or (Offset >= FTrackCount) then
    begin
      OutCount := 0;
      Exit(True);
    end;

    OutCount := FTrackCount - Offset;
    if OutCount > Limit then OutCount := Limit;
    if (OutTracks <> nil) and (OutCount > MaxOut) then OutCount := MaxOut;

    if (OutTracks <> nil) and (OutCount > 0) then
    begin
      for i := 0 to OutCount - 1 do
      begin
        pRec := @FRecords[Offset + i];
        pOut := @OutTracks[i];
        FillChar(pOut^, SizeOf(TOMMCondensedTrack), 0);
        pOut^.TrackID := pRec^.TrackID;
        pOut^.DurationMs := pRec^.DurationMs;
        pOut^.Year := pRec^.Year;
        pOut^.TrackNo := pRec^.TrackNo;
        pOut^.BitrateKbps := pRec^.BitrateKbps;
        pOut^.FormatTag := pRec^.FormatTag;
        Move(pRec^.Title[0], pOut^.Title[0], SizeOf(pOut^.Title));
        Move(pRec^.Artist[0], pOut^.Artist[0], SizeOf(pOut^.Artist));
        Move(pRec^.Album[0], pOut^.Album[0], SizeOf(pOut^.Album));
        Move(pRec^.RelativePath[0], pOut^.URI[0], SizeOf(pOut^.URI));
      end;
    end;
    Exit(True);
  end;

  // Filtered path
  passedFilterCount := 0;
  matchedIdx := 0;
  for i := 0 to FTrackCount - 1 do
  begin
    pRec := @FRecords[i];
    tTitle := LowerCase(StrPas(pRec^.Title));
    tArtist := LowerCase(StrPas(pRec^.Artist));

    matches := (Pos(filterLower, tTitle) > 0) or (Pos(filterLower, tArtist) > 0);
    if matches then
    begin
      if (passedFilterCount >= Offset) and (matchedIdx < Limit) then
      begin
        if (OutTracks <> nil) and (matchedIdx < MaxOut) then
        begin
          pOut := @OutTracks[matchedIdx];
          FillChar(pOut^, SizeOf(TOMMCondensedTrack), 0);
          pOut^.TrackID := pRec^.TrackID;
          pOut^.DurationMs := pRec^.DurationMs;
          pOut^.Year := pRec^.Year;
          pOut^.TrackNo := pRec^.TrackNo;
          pOut^.BitrateKbps := pRec^.BitrateKbps;
          pOut^.FormatTag := pRec^.FormatTag;
          Move(pRec^.Title[0], pOut^.Title[0], SizeOf(pOut^.Title));
          Move(pRec^.Artist[0], pOut^.Artist[0], SizeOf(pOut^.Artist));
          Move(pRec^.Album[0], pOut^.Album[0], SizeOf(pOut^.Album));
          Move(pRec^.RelativePath[0], pOut^.URI[0], SizeOf(pOut^.URI));
        end;
        Inc(matchedIdx);
      end;
      Inc(passedFilterCount);
    end;
  end;

  Filtered := passedFilterCount;
  if (OutTracks <> nil) and (matchedIdx > MaxOut) then
    OutCount := MaxOut
  else
    OutCount := matchedIdx;
  Result := True;
end;

procedure TOMMLibraryEngine.CreateDefaultSyntheticLibrary(TrackCount: Cardinal);
const
  CURATED_TITLES: array[0..19] of string = (
    '5:15 (2011 Mix)',
    'Run to the Hills',
    'Me and Mrs. Jones',
    'Nocturne #5 In F Sharp, Op. 15/2',
    '5:15 (Live)',
    '5:15 am',
    'Bohemian Rhapsody',
    'Killer Queen',
    'Time',
    'Comfortably Numb',
    'Sultans of Swing',
    'Clair de Lune',
    'Paranoid Android',
    'Everything In Its Right Place',
    'Starless',
    '21st Century Schizoid Man',
    'Hallowed Be Thy Name',
    'Baba O''Riley',
    'Won''t Get Fooled Again',
    'Space Oddity'
  );
  CURATED_ARTISTS: array[0..19] of string = (
    'The Who',
    'Iron Maiden',
    'Sun City Girls',
    'Frederic Chopin',
    'The Who',
    'Mark Knopfler',
    'Queen',
    'Queen',
    'Pink Floyd',
    'Pink Floyd',
    'Dire Straits',
    'Claude Debussy',
    'Radiohead',
    'Radiohead',
    'King Crimson',
    'King Crimson',
    'Iron Maiden',
    'The Who',
    'The Who',
    'David Bowie'
  );
  CURATED_ALBUMS: array[0..19] of string = (
    'The Best Of',
    'The Number of the Beast',
    'Midnight Cowboys from Ipanema',
    'This Is Classic - The Universe''s Best',
    'Live in NY - Part One (Live)',
    'Shangri-La',
    'Greatest Hits',
    'Absolute Greatest',
    'The Dark Side of the Moon',
    'The Wall',
    'Brothers in Arms',
    'Suite bergamasque',
    'OK Computer',
    'Kid A',
    'Red',
    'In the Court of the Crimson King',
    'The Number of the Beast',
    'Who''s Next',
    'Who''s Next',
    'The Rise and Fall of Ziggy Stardust'
  );
  CURATED_DURATIONS: array[0..19] of Cardinal = (
    293000, 233000, 280000, 203000, 464000,
    354000, 355000, 181000, 413000, 382000,
    348000, 303000, 383000, 251000, 738000,
    444000, 431000, 300000, 513000, 315000
  );
var
  tmpFile: string;
  fd: cint;
  hdr: TOMMLibraryHeader;
  rec: TOMMTrackRecord;
  i, idx: Cardinal;
  title, artist, album, relPath: string;
begin
  tmpFile := FLibraryFile + '.tmp';
  fd := fpOpen(PChar(tmpFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  if fd < 0 then Exit;

  FillChar(hdr, SizeOf(hdr), 0);
  hdr.Magic := OMM_LIBRARY_MAGIC;
  hdr.Version := OMM_LIBRARY_VERSION;
  hdr.RecordSize := OMM_RECORD_SIZE;
  hdr.RecordCount := TrackCount;
  hdr.CreatedTimestamp := fpTime;
  hdr.LastRescanTimestamp := hdr.CreatedTimestamp;

  fpWrite(fd, hdr, SizeOf(hdr));

  for i := 1 to TrackCount do
  begin
    FillChar(rec, SizeOf(rec), 0);
    idx := (i - 1) mod 20;
    rec.TrackID := i;
    rec.DurationMs := CURATED_DURATIONS[idx];
    rec.Year := 1971 + (i mod 53);
    rec.TrackNo := (i mod 12) + 1;
    rec.BitrateKbps := 960;
    rec.FormatTag := 1; // FLAC

    if i <= 20 then
    begin
      title := CURATED_TITLES[idx];
      artist := CURATED_ARTISTS[idx];
      album := CURATED_ALBUMS[idx];
    end
    else
    begin
      case (i div 20) mod 6 of
        0: title := CURATED_TITLES[idx] + ' (BBC Session #' + IntToStr(i) + ')';
        1: title := CURATED_TITLES[idx] + ' (Vinyl Master #' + IntToStr(i) + ')';
        2: title := CURATED_TITLES[idx] + ' (Live Bootleg #' + IntToStr(i) + ')';
        3: title := CURATED_TITLES[idx] + ' (Acoustic Mix #' + IntToStr(i) + ')';
        4: title := CURATED_TITLES[idx] + ' (Deluxe Take #' + IntToStr(i) + ')';
        else title := CURATED_TITLES[idx] + ' (Outtake #' + IntToStr(i) + ')';
      end;
      artist := CURATED_ARTISTS[idx];
      album := CURATED_ALBUMS[(idx + (i div 20)) mod 20] + ' Vol.' + IntToStr((i mod 9) + 1);
    end;
    relPath := 'file:///music/track_' + IntToStr(i) + '.flac';

    Move(title[1], rec.Title[0], Min(Length(title), 127));
    Move(artist[1], rec.Artist[0], Min(Length(artist), 95));
    Move(album[1], rec.Album[0], Min(Length(album), 95));
    Move(relPath[1], rec.RelativePath[0], Min(Length(relPath), 127));

    if i <= 20 then
      GenerateTrackFeatureVector(
        'British Classic Rock Guitar Anthem Studio Master 1970s ' + CURATED_ARTISTS[idx],
        'British Classic Rock Studio Master ' + CURATED_ARTISTS[idx],
        'British Classic Rock Guitar Anthem 1970s ' + CURATED_TITLES[idx],
        rec.TfIdfVector)
    else
      GenerateTrackFeatureVector(
        'Archive Vault Take_' + IntToStr(i * 7) + ' ' + title,
        'Vault_' + IntToStr(i * 13) + ' ' + artist,
        'BoxSet_' + IntToStr(i * 19) + ' ' + album,
        rec.TfIdfVector);
    rec.VectorNorm := ComputeVectorNormInt8(@rec.TfIdfVector[0]);

    fpWrite(fd, rec, SizeOf(rec));
  end;

  fpFSync(fd);
  fpClose(fd);

  fpRename(PChar(tmpFile), PChar(FLibraryFile));
end;

function TOMMLibraryEngine.RescanDirectory(const AMusicDir: string): Boolean;
var
  scanDir: string;
  tmpFile: string;
  fd: cint;
  hdr: TOMMLibraryHeader;
  rec: TOMMTrackRecord;
  trackIdCounter: Cardinal;
  fastZeroOpenMode: Boolean;
  tProbeStart: QWord;

  function DetectCloudOrFuseMount(const APath: string): Boolean;
  var
    lowP, line, mp, fsType: string;
    mfd: cint;
    buf: array[0..16383] of AnsiChar;
    nRead, p1, p2: Integer;
    mountsTxt: string;
  begin
    lowP := LowerCase(APath);
    if (Pos('alist', lowP) > 0) or (Pos('webdav', lowP) > 0) or
       (Pos('rclone', lowP) > 0) or (Pos('/gvfs/', lowP) > 0) or
       (Pos('dav:', lowP) > 0) or (Pos('cloud', lowP) > 0) then
      Exit(True);

    Result := False;
    mfd := fpOpen('/proc/mounts', O_RDONLY, 0);
    if mfd >= 0 then
    begin
      nRead := fpRead(mfd, buf[0], SizeOf(buf) - 1);
      fpClose(mfd);
      if nRead > 0 then
      begin
        buf[nRead] := #0;
        mountsTxt := StrPas(@buf[0]);
        while mountsTxt <> '' do
        begin
          p1 := Pos(#10, mountsTxt);
          if p1 > 0 then
          begin
            line := Copy(mountsTxt, 1, p1 - 1);
            Delete(mountsTxt, 1, p1);
          end
          else
          begin
            line := mountsTxt;
            mountsTxt := '';
          end;
          // Format: device mountpoint fstype options ...
          p1 := Pos(' ', line);
          if p1 > 0 then
          begin
            Delete(line, 1, p1);
            p2 := Pos(' ', line);
            if p2 > 0 then
            begin
              mp := Copy(line, 1, p2 - 1);
              Delete(line, 1, p2);
              p1 := Pos(' ', line);
              if p1 > 0 then fsType := LowerCase(Copy(line, 1, p1 - 1)) else fsType := LowerCase(line);
              if (mp <> '/') and (Length(mp) > 1) and (Pos(mp, APath) = 1) then
              begin
                if (Pos('fuse', fsType) > 0) or (Pos('dav', fsType) > 0) or
                   (Pos('rclone', fsType) > 0) or (Pos('cifs', fsType) > 0) or
                   (Pos('nfs', fsType) > 0) or (Pos('smb', fsType) > 0) then
                  Exit(True);
              end;
            end;
          end;
        end;
      end;
    end;
  end;

  procedure ParseID3v2File(const FilePath: string; FileBytes: Int64;
    var ATitle, AArtist, AAlbum: string; var AYear, ATrackNo: UInt16; var ADurMs: UInt32);
  var
    mfd: cint;
    buf: array[0..8191] of Byte;
    nRead, posIdx, limitIdx, fSize, id3Total, k: Integer;
    ver, enc: Byte;
    fid, valStr: string;
    yrVal, trkVal, slashPos: Integer;
  begin
    mfd := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if mfd < 0 then Exit;
    nRead := fpRead(mfd, buf[0], SizeOf(buf));
    fpClose(mfd);
    if (nRead < 14) or (buf[0] <> Ord('I')) or (buf[1] <> Ord('D')) or (buf[2] <> Ord('3')) then
    begin
      if FileBytes > 40000 then
        ADurMs := Cardinal(FileBytes div 40);
      Exit;
    end;

    ver := buf[3];
    id3Total := ((buf[6] and $7F) shl 21) or ((buf[7] and $7F) shl 14) or
                ((buf[8] and $7F) shl 7)  or (buf[9] and $7F);
    if FileBytes > id3Total + 8000 then
      ADurMs := Cardinal((FileBytes - id3Total) div 40);

    limitIdx := Min(nRead, 10 + id3Total);
    posIdx := 10;
    while posIdx + 10 <= limitIdx do
    begin
      if not ((buf[posIdx] in [Ord('A')..Ord('Z'), Ord('0')..Ord('9')]) and
              (buf[posIdx+1] in [Ord('A')..Ord('Z'), Ord('0')..Ord('9')])) then Break;
      SetLength(fid, 4);
      fid[1] := Chr(buf[posIdx]);
      fid[2] := Chr(buf[posIdx+1]);
      fid[3] := Chr(buf[posIdx+2]);
      fid[4] := Chr(buf[posIdx+3]);
      if ver >= 4 then
        fSize := ((buf[posIdx+4] and $7F) shl 21) or ((buf[posIdx+5] and $7F) shl 14) or
                 ((buf[posIdx+6] and $7F) shl 7)  or (buf[posIdx+7] and $7F)
      else
        fSize := (buf[posIdx+4] shl 24) or (buf[posIdx+5] shl 16) or
                 (buf[posIdx+6] shl 8)  or buf[posIdx+7];

      if (fSize <= 1) or (posIdx + 10 + fSize > limitIdx) then
      begin
        if fSize <= 0 then Break;
        Inc(posIdx, 10 + fSize);
        Continue;
      end;

      enc := buf[posIdx + 10];
      if enc in [0, 3] then
      begin
        valStr := '';
        for k := posIdx + 11 to posIdx + 10 + fSize - 1 do
        begin
          if buf[k] = 0 then
          begin
            if (k < posIdx + 10 + fSize - 1) and (buf[k+1] <> 0) then
              valStr := valStr + ' / ';
          end
          else if (enc = 0) and (buf[k] >= $80) then
            valStr := valStr + Chr($C0 or (buf[k] shr 6)) + Chr($80 or (buf[k] and $3F))
          else
            valStr := valStr + Chr(buf[k]);
        end;
        valStr := Trim(valStr);
        if valStr <> '' then
        begin
          if fid = 'TIT2' then ATitle := valStr
          else if fid = 'TPE1' then AArtist := valStr
          else if fid = 'TALB' then AAlbum := valStr
          else if (fid = 'TDRC') or (fid = 'TYER') then
          begin
            yrVal := StrToIntDef(Copy(valStr, 1, 4), 0);
            if (yrVal >= 1700) and (yrVal <= 2100) then AYear := yrVal;
          end
          else if fid = 'TRCK' then
          begin
            slashPos := Pos('/', valStr);
            if slashPos > 0 then valStr := Copy(valStr, 1, slashPos - 1);
            trkVal := StrToIntDef(valStr, 0);
            if (trkVal >= 1) and (trkVal <= 999) then ATrackNo := trkVal;
          end;
        end;
      end;
      Inc(posIdx, 10 + fSize);
    end;
  end;

  procedure ParseFlacFile(const FilePath: string; FileBytes: Int64;
    var ATitle, AArtist, AAlbum: string; var AYear, ATrackNo, ABitrate: UInt16; var ADurMs: UInt32);
  var
    mfd: cint;
    buf: array[0..16383] of Byte;
    nRead, posIdx, blkLen, vPos, vEnd, vendorLen, cCount, cIdx, cLen, eqPos, slashPos, yrVal, trkVal: Integer;
    isLast: Boolean;
    blkType: Byte;
    sRate: Cardinal;
    totSamples: QWord;
    kvStr, kStr, vStr: string;
  begin
    mfd := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if mfd < 0 then Exit;
    nRead := fpRead(mfd, buf[0], SizeOf(buf));
    fpClose(mfd);
    if (nRead < 42) or (buf[0] <> Ord('f')) or (buf[1] <> Ord('L')) or
       (buf[2] <> Ord('a')) or (buf[3] <> Ord('C')) then Exit;

    posIdx := 4;
    isLast := False;
    while (not isLast) and (posIdx + 4 <= nRead) do
    begin
      isLast := (buf[posIdx] and $80) <> 0;
      blkType := buf[posIdx] and $7F;
      blkLen := (buf[posIdx+1] shl 16) or (buf[posIdx+2] shl 8) or buf[posIdx+3];
      if (blkLen <= 0) or (posIdx + 4 + blkLen > nRead) then
      begin
        if blkType = 0 then Break;
        Inc(posIdx, 4 + Max(0, blkLen));
        Continue;
      end;

      if (blkType = 0) and (blkLen >= 18) then
      begin
        sRate := (Cardinal(buf[posIdx+14]) shl 12) or (Cardinal(buf[posIdx+15]) shl 4) or (Cardinal(buf[posIdx+16]) shr 4);
        totSamples := (QWord(buf[posIdx+17] and $0F) shl 32) or
                      (QWord(buf[posIdx+18]) shl 24) or
                      (QWord(buf[posIdx+19]) shl 16) or
                      (QWord(buf[posIdx+20]) shl 8)  or
                      QWord(buf[posIdx+21]);
        if (sRate > 0) and (totSamples > 0) then
        begin
          ADurMs := Cardinal((totSamples * 1000) div sRate);
          if ADurMs > 0 then
            ABitrate := EnsureRange((FileBytes * 8) div ADurMs, 64, 9999);
        end;
      end
      else if (blkType = 4) and (blkLen >= 8) then
      begin
        vPos := posIdx + 4;
        vEnd := posIdx + 4 + blkLen;
        vendorLen := buf[vPos] or (buf[vPos+1] shl 8) or (buf[vPos+2] shl 16) or (buf[vPos+3] shl 24);
        Inc(vPos, 4 + vendorLen);
        if vPos + 4 <= vEnd then
        begin
          cCount := buf[vPos] or (buf[vPos+1] shl 8) or (buf[vPos+2] shl 16) or (buf[vPos+3] shl 24);
          Inc(vPos, 4);
          for cIdx := 1 to Min(cCount, 64) do
          begin
            if vPos + 4 > vEnd then Break;
            cLen := buf[vPos] or (buf[vPos+1] shl 8) or (buf[vPos+2] shl 16) or (buf[vPos+3] shl 24);
            Inc(vPos, 4);
            if (cLen <= 0) or (vPos + cLen > vEnd) then Break;
            SetLength(kvStr, cLen);
            Move(buf[vPos], kvStr[1], cLen);
            Inc(vPos, cLen);
            eqPos := Pos('=', kvStr);
            if eqPos > 1 then
            begin
              kStr := UpperCase(Trim(Copy(kvStr, 1, eqPos - 1)));
              vStr := Trim(Copy(kvStr, eqPos + 1, Length(kvStr)));
              if vStr <> '' then
              begin
                if kStr = 'TITLE' then ATitle := vStr
                else if kStr = 'ARTIST' then AArtist := vStr
                else if (kStr = 'ALBUMARTIST') and ((AArtist = '') or (AArtist = 'Unknown Artist')) then AArtist := vStr
                else if kStr = 'ALBUM' then AAlbum := vStr
                else if (kStr = 'DATE') or (kStr = 'YEAR') then
                begin
                  yrVal := StrToIntDef(Copy(vStr, 1, 4), 0);
                  if (yrVal >= 1700) and (yrVal <= 2100) then AYear := yrVal;
                end
                else if kStr = 'TRACKNUMBER' then
                begin
                  slashPos := Pos('/', vStr);
                  if slashPos > 0 then vStr := Copy(vStr, 1, slashPos - 1);
                  trkVal := StrToIntDef(vStr, 0);
                  if (trkVal >= 1) and (trkVal <= 999) then ATrackNo := trkVal;
                end;
              end;
            end;
          end;
        end;
      end;

      Inc(posIdx, 4 + blkLen);
    end;
  end;

  procedure ParseWavAiffFile(const FilePath: string; FileBytes: Int64;
    var ABitrate: UInt16; var ADurMs: UInt32);
  var
    mfd: cint;
    buf: array[0..511] of Byte;
    nRead, posIdx: Integer;
    chunkSize, byteRate, sRate, numFrames: Cardinal;
    chans, bits: UInt16;
  begin
    mfd := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if mfd < 0 then Exit;
    nRead := fpRead(mfd, buf[0], SizeOf(buf));
    fpClose(mfd);
    if nRead < 44 then Exit;

    if (buf[0] = Ord('R')) and (buf[1] = Ord('I')) and (buf[2] = Ord('F')) and (buf[3] = Ord('F')) and
       (buf[8] = Ord('W')) and (buf[9] = Ord('A')) and (buf[10] = Ord('V')) and (buf[11] = Ord('E')) then
    begin
      byteRate := 176400;
      posIdx := 12;
      while posIdx + 8 <= nRead do
      begin
        chunkSize := Cardinal(buf[posIdx+4]) or (Cardinal(buf[posIdx+5]) shl 8) or
                     (Cardinal(buf[posIdx+6]) shl 16) or (Cardinal(buf[posIdx+7]) shl 24);
        if (buf[posIdx] = Ord('f')) and (buf[posIdx+1] = Ord('m')) and
           (buf[posIdx+2] = Ord('t')) and (buf[posIdx+3] = Ord(' ')) and (posIdx + 24 <= nRead) then
        begin
          chans := UInt16(buf[posIdx+10]) or (UInt16(buf[posIdx+11]) shl 8);
          sRate := Cardinal(buf[posIdx+12]) or (Cardinal(buf[posIdx+13]) shl 8) or
                   (Cardinal(buf[posIdx+14]) shl 16) or (Cardinal(buf[posIdx+15]) shl 24);
          byteRate := Cardinal(buf[posIdx+16]) or (Cardinal(buf[posIdx+17]) shl 8) or
                      (Cardinal(buf[posIdx+18]) shl 16) or (Cardinal(buf[posIdx+19]) shl 24);
          bits := UInt16(buf[posIdx+22]) or (UInt16(buf[posIdx+23]) shl 8);
          if (byteRate = 0) and (sRate > 0) and (chans > 0) and (bits >= 8) then
            byteRate := sRate * chans * (bits div 8);
          if byteRate > 0 then
            ABitrate := EnsureRange((byteRate * 8) div 1000, 64, 9999);
        end
        else if (buf[posIdx] = Ord('d')) and (buf[posIdx+1] = Ord('a')) and
                (buf[posIdx+2] = Ord('t')) and (buf[posIdx+3] = Ord('a')) then
        begin
          if (byteRate > 0) and (chunkSize > 0) then
            ADurMs := Cardinal((QWord(chunkSize) * 1000) div byteRate);
          Break;
        end;
        Inc(posIdx, 8 + Integer((chunkSize + 1) and (not 1)));
      end;
      if (ADurMs = 210000) and (byteRate > 0) and (FileBytes > 44) then
        ADurMs := Cardinal(((FileBytes - 44) * 1000) div byteRate);
    end
    else if (buf[0] = Ord('F')) and (buf[1] = Ord('O')) and (buf[2] = Ord('R')) and (buf[3] = Ord('M')) and
            (buf[8] = Ord('A')) and (buf[9] = Ord('I')) and (buf[10] = Ord('F')) then
    begin
      if (buf[12] = Ord('C')) and (buf[13] = Ord('O')) and (buf[14] = Ord('M')) and (buf[15] = Ord('M')) then
      begin
        numFrames := (Cardinal(buf[22]) shl 24) or (Cardinal(buf[23]) shl 16) or
                     (Cardinal(buf[24]) shl 8) or Cardinal(buf[25]);
        if numFrames > 0 then
          ADurMs := Cardinal((QWord(numFrames) * 1000) div 44100);
        ABitrate := 1411;
      end;
    end;
  end;

  procedure ParseOggFile(const FilePath: string; FileBytes: Int64;
    var ATitle, AArtist, AAlbum: string; var AYear, ATrackNo, ABitrate: UInt16; var ADurMs: UInt32);
  var
    mfd: cint;
    buf: array[0..8191] of Byte;
    nRead, segCount, pktOff, p: Integer;
    sRate: Cardinal;
    granulePos: QWord;
  begin
    mfd := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if mfd < 0 then Exit;
    nRead := fpRead(mfd, buf[0], 1024);
    sRate := 48000;
    if (nRead >= 48) and (buf[0] = Ord('O')) and (buf[1] = Ord('g')) and
       (buf[2] = Ord('g')) and (buf[3] = Ord('S')) then
    begin
      segCount := buf[26];
      pktOff := 27 + segCount;
      if pktOff + 16 <= nRead then
      begin
        if (buf[pktOff] = 1) and (buf[pktOff+1] = Ord('v')) and (buf[pktOff+2] = Ord('o')) then
        begin
          sRate := Cardinal(buf[pktOff+12]) or (Cardinal(buf[pktOff+13]) shl 8) or
                   (Cardinal(buf[pktOff+14]) shl 16) or (Cardinal(buf[pktOff+15]) shl 24);
        end
        else if (buf[pktOff] = Ord('O')) and (buf[pktOff+1] = Ord('p')) and (buf[pktOff+2] = Ord('u')) then
          sRate := 48000;
      end;
    end;

    // Jump to tail of file via fpLseek to read final OggS page granule position
    if FileBytes > 128 then
    begin
      fpLseek(mfd, Max(0, FileBytes - SizeOf(buf)), SEEK_SET);
      nRead := fpRead(mfd, buf[0], SizeOf(buf));
      for p := nRead - 27 downto 0 do
      begin
        if (buf[p] = Ord('O')) and (buf[p+1] = Ord('g')) and
           (buf[p+2] = Ord('g')) and (buf[p+3] = Ord('S')) then
        begin
          granulePos := QWord(buf[p+6]) or (QWord(buf[p+7]) shl 8) or
                        (QWord(buf[p+8]) shl 16) or (QWord(buf[p+9]) shl 24) or
                        (QWord(buf[p+10]) shl 32) or (QWord(buf[p+11]) shl 40) or
                        (QWord(buf[p+12]) shl 48) or (QWord(buf[p+13]) shl 56);
          if (granulePos > 0) and (granulePos <> High(QWord)) and (sRate > 0) then
          begin
            ADurMs := Cardinal((granulePos * 1000) div sRate);
            if ADurMs > 0 then
              ABitrate := EnsureRange((FileBytes * 8) div ADurMs, 32, 1000);
            Break;
          end;
        end;
      end;
    end;
    fpClose(mfd);
  end;

  procedure ParseApeWvDsdFile(const FilePath: string; FileBytes: Int64; Fmt: UInt16;
    var ABitrate: UInt16; var ADurMs: UInt32);
  const
    WV_SR: array[0..15] of Cardinal = (
      6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000,
      32000, 44100, 48000, 64000, 88200, 96000, 192000, 44100
    );
  var
    mfd: cint;
    buf: array[0..127] of Byte;
    nRead, hdrOff: Integer;
    sRate, blocksPerFrame, finalBlocks, totFrames, wvFlags: Cardinal;
    totSamples: QWord;
  begin
    mfd := fpOpen(PChar(FilePath), O_RDONLY, 0);
    if mfd < 0 then Exit;
    nRead := fpRead(mfd, buf[0], SizeOf(buf));
    fpClose(mfd);
    if nRead < 32 then Exit;

    if (Fmt = 6) and (buf[0] = Ord('M')) and (buf[1] = Ord('A')) and (buf[2] = Ord('C')) then
    begin
      hdrOff := Integer(Cardinal(buf[8]) or (Cardinal(buf[9]) shl 8));
      if (hdrOff >= 52) and (hdrOff + 24 <= nRead) then
      begin
        blocksPerFrame := Cardinal(buf[hdrOff+4]) or (Cardinal(buf[hdrOff+5]) shl 8) or
                          (Cardinal(buf[hdrOff+6]) shl 16) or (Cardinal(buf[hdrOff+7]) shl 24);
        finalBlocks    := Cardinal(buf[hdrOff+8]) or (Cardinal(buf[hdrOff+9]) shl 8) or
                          (Cardinal(buf[hdrOff+10]) shl 16) or (Cardinal(buf[hdrOff+11]) shl 24);
        totFrames      := Cardinal(buf[hdrOff+12]) or (Cardinal(buf[hdrOff+13]) shl 8) or
                          (Cardinal(buf[hdrOff+14]) shl 16) or (Cardinal(buf[hdrOff+15]) shl 24);
        sRate          := Cardinal(buf[hdrOff+20]) or (Cardinal(buf[hdrOff+21]) shl 8) or
                          (Cardinal(buf[hdrOff+22]) shl 16) or (Cardinal(buf[hdrOff+23]) shl 24);
        if (totFrames > 0) and (sRate > 0) then
        begin
          totSamples := QWord(totFrames - 1) * QWord(blocksPerFrame) + QWord(finalBlocks);
          ADurMs := Cardinal((totSamples * 1000) div sRate);
          if ADurMs > 0 then
            ABitrate := EnsureRange((FileBytes * 8) div ADurMs, 128, 9999);
        end;
      end;
    end
    else if (Fmt = 7) and (buf[0] = Ord('w')) and (buf[1] = Ord('v')) and (buf[2] = Ord('p')) then
    begin
      totSamples := Cardinal(buf[12]) or (Cardinal(buf[13]) shl 8) or
                    (Cardinal(buf[14]) shl 16) or (Cardinal(buf[15]) shl 24);
      wvFlags    := Cardinal(buf[24]) or (Cardinal(buf[25]) shl 8) or
                    (Cardinal(buf[26]) shl 16) or (Cardinal(buf[27]) shl 24);
      sRate := WV_SR[(wvFlags shr 23) and $0F];
      if (totSamples > 0) and (sRate > 0) then
      begin
        ADurMs := Cardinal((totSamples * 1000) div sRate);
        if ADurMs > 0 then
          ABitrate := EnsureRange((FileBytes * 8) div ADurMs, 128, 9999);
      end;
    end
    else if (Fmt = 8) and (nRead >= 80) and (buf[0] = Ord('D')) and (buf[1] = Ord('S')) and (buf[2] = Ord('D')) then
    begin
      sRate := Cardinal(buf[56]) or (Cardinal(buf[57]) shl 8) or
               (Cardinal(buf[58]) shl 16) or (Cardinal(buf[59]) shl 24);
      totSamples := QWord(buf[64]) or (QWord(buf[65]) shl 8) or
                    (QWord(buf[66]) shl 16) or (QWord(buf[67]) shl 24) or
                    (QWord(buf[68]) shl 32) or (QWord(buf[69]) shl 40);
      if (totSamples > 0) and (sRate > 0) then
      begin
        ADurMs := Cardinal((totSamples * 1000) div sRate);
        if ADurMs > 0 then
          ABitrate := EnsureRange((FileBytes * 8) div ADurMs, 256, 9999);
      end;
    end;
  end;

  function SafeUTF8CopyLen(const S: string; MaxBytes: Integer): Integer;
  begin
    Result := Min(Length(S), MaxBytes);
    while (Result > 0) and (Result < Length(S)) and ((Ord(S[Result + 1]) and $C0) = $80) do
      Dec(Result);
  end;

  procedure ScanRecursive(const Dir: string);
  var
    info: TSearchRec;
    fullPath, storePath, ext, fn: string;
    fmt: UInt16;
    title, artist, album: string;
    dashPos: Integer;
  begin
    if FindFirst(Dir + '/*', faAnyFile, info) = 0 then
    begin
      repeat
        if (info.Name = '.') or (info.Name = '..') then
          Continue;

        fullPath := Dir + '/' + info.Name;
        if (info.Attr and faDirectory) <> 0 then
        begin
          ScanRecursive(fullPath);
        end
        else
        begin
          ext := LowerCase(ExtractFileExt(info.Name));
          fmt := 0;
          if ext = '.flac' then fmt := 1
          else if ext = '.mp3' then fmt := 2
          else if (ext = '.ogg') or (ext = '.opus') then fmt := 3
          else if (ext = '.wav') or (ext = '.aif') or (ext = '.aiff') or (ext = '.pcm') then fmt := 4
          else if (ext = '.aac') or (ext = '.m4a') or (ext = '.alac') or (ext = '.wma') or (ext = '.amr') then fmt := 5
          else if ext = '.ape' then fmt := 6
          else if ext = '.wv' then fmt := 7
          else if (ext = '.dsf') or (ext = '.dff') then fmt := 8
          else if (ext = '.mod') or (ext = '.xm') or (ext = '.it') or (ext = '.s3m') then fmt := 9;

          if fmt > 0 then
          begin
            Inc(trackIdCounter);
            FillChar(rec, SizeOf(rec), 0);
            rec.TrackID := trackIdCounter;
            rec.DurationMs := 210000; // 3.5m default
            rec.Year := 2024;
            rec.TrackNo := trackIdCounter mod 20 + 1;
            if fmt in [1, 4, 6, 7, 8] then rec.BitrateKbps := 960 else rec.BitrateKbps := 320;
            rec.FormatTag := fmt;

            fn := ChangeFileExt(info.Name, '');
            dashPos := Pos(' - ', fn);
            if dashPos > 0 then
            begin
              artist := Copy(fn, 1, dashPos - 1);
              title := Copy(fn, dashPos + 3, Length(fn));
              if (Length(artist) <= 5) and (artist[1] in ['0'..'9']) then
                artist := 'Unknown Artist';
            end
            else
            begin
              artist := 'Unknown Artist';
              title := fn;
            end;
            album := ExtractFileName(Dir);
            if (album = '') or (album = '_unknown') or (album = 'exhigh') or (album = 'lossless') then
              album := 'Local Library';

            if not fastZeroOpenMode then
            begin
              tProbeStart := GetTickCount64;
              case fmt of
                1:
                begin
                  if info.Size > 100000 then
                    rec.DurationMs := Cardinal(info.Size div 120);
                  ParseFlacFile(fullPath, info.Size, title, artist, album, rec.Year, rec.TrackNo, rec.BitrateKbps, rec.DurationMs);
                end;
                2: ParseID3v2File(fullPath, info.Size, title, artist, album, rec.Year, rec.TrackNo, rec.DurationMs);
                3: ParseOggFile(fullPath, info.Size, title, artist, album, rec.Year, rec.TrackNo, rec.BitrateKbps, rec.DurationMs);
                4: ParseWavAiffFile(fullPath, info.Size, rec.BitrateKbps, rec.DurationMs);
                6, 7, 8: ParseApeWvDsdFile(fullPath, info.Size, fmt, rec.BitrateKbps, rec.DurationMs);
              end;
              // If reading a single file header takes >= 15ms (remote cloud / WebDAV / slow FUSE mount),
              // automatically switch to Zero-Open fast directory-only indexing for the rest of the scan!
              if (GetTickCount64 - tProbeStart) >= 15 then
                fastZeroOpenMode := True;
            end
            else
            begin
              // Zero-Open Cloud Mount Mode (AList / rclone / WebDAV): estimate duration purely from stat size!
              if info.Size > 40000 then
              begin
                if fmt in [1, 4, 6, 7, 8] then
                  rec.DurationMs := Cardinal(info.Size div 120)
                else
                  rec.DurationMs := Cardinal(info.Size div 40);
              end;
            end;

            storePath := fullPath;
            if Length(storePath) > 127 then
            begin
              fpMkDir('/tmp/omm_links', &755);
              storePath := '/tmp/omm_links/trk_' + IntToStr(trackIdCounter) + ext;
              fpUnlink(PChar(storePath));
              fpSymlink(PChar(fullPath), PChar(storePath));
            end;

            if title <> '' then
              Move(title[1], rec.Title[0], SafeUTF8CopyLen(title, 127));
            if artist <> '' then
              Move(artist[1], rec.Artist[0], SafeUTF8CopyLen(artist, 95));
            if album <> '' then
              Move(album[1], rec.Album[0], SafeUTF8CopyLen(album, 95));
            if storePath <> '' then
              Move(storePath[1], rec.RelativePath[0], SafeUTF8CopyLen(storePath, 127));

            GenerateTrackFeatureVector(title, artist, album, rec.TfIdfVector);
            rec.VectorNorm := ComputeVectorNormInt8(@rec.TfIdfVector[0]);

            fpWrite(fd, rec, SizeOf(rec));
          end;
        end;
      until FindNext(info) <> 0;
      FindClose(info);
    end;
  end;

begin
  Result := False;
  fastZeroOpenMode := False;
  if AMusicDir <> '' then
    scanDir := AMusicDir
  else
    scanDir := FMusicDir;

  if Copy(scanDir, 1, 6) = 'cloud:' then
  begin
    fastZeroOpenMode := True;
    scanDir := Copy(scanDir, 7, Length(scanDir) - 6);
  end;

  if (scanDir = '') or not DirectoryExists(scanDir) then
  begin
    // Fall back to synthetic library if no music dir configured
    CreateDefaultSyntheticLibrary(5000);
    Exit(OpenLibrary);
  end;

  if not fastZeroOpenMode then
    fastZeroOpenMode := DetectCloudOrFuseMount(scanDir);

  tmpFile := FLibraryFile + '.tmp';
  fd := fpOpen(PChar(tmpFile), O_WRONLY or O_CREAT or O_TRUNC, &644);
  if fd < 0 then Exit;

  // Placeholder header
  FillChar(hdr, SizeOf(hdr), 0);
  hdr.Magic := OMM_LIBRARY_MAGIC;
  hdr.Version := OMM_LIBRARY_VERSION;
  hdr.RecordSize := OMM_RECORD_SIZE;
  hdr.CreatedTimestamp := fpTime;
  fpWrite(fd, hdr, SizeOf(hdr));

  trackIdCounter := 0;
  ScanRecursive(scanDir);

  // Rewind and write finalized header
  hdr.RecordCount := trackIdCounter;
  hdr.LastRescanTimestamp := fpTime;
  fpLseek(fd, 0, SEEK_SET);
  fpWrite(fd, hdr, SizeOf(hdr));

  fpFSync(fd);
  fpClose(fd);

  CloseLibrary;
  fpRename(PChar(tmpFile), PChar(FLibraryFile));
  Result := OpenLibrary;
end;

end.
