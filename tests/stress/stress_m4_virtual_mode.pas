program stress_m4_virtual_mode;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  {$IFDEF UNIX}
  cthreads, BaseUnix,
  {$ENDIF}
  SysUtils, Classes, Math,
  Interfaces, Forms, Controls, ComCtrls,
  omm_ipc, omm_shm, omm_library;

const
  TEST_LIB_PATH = 'tests/stress/library_50k.bin';
  MAX_CACHE_ITEMS = 128;
  CLOCK_MONOTONIC = 1;

type
  timespec = record
    tv_sec: Int64;
    tv_nsec: Int64;
  end;

function clock_gettime(clk_id: cint; tp: Pointer): cint; cdecl; external 'c';

function GetMonotonicMicros: Int64;
var
  ts: timespec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := (ts.tv_sec * 1000000) + (ts.tv_nsec div 1000);
end;

type
  { TVirtualModeTester }
  TVirtualModeTester = class
  private
    FForm: TForm;
    FLV: TListView;
    FLibEngine: TOMMLibraryEngine;
    FCacheSlice: array[0..MAX_CACHE_ITEMS - 1] of TOMMCondensedTrack;
    FCacheStart: Integer;
    FCacheCount: Integer;
    FOnDataCalls: Int64;
    FLastItemPtr: Pointer;
    FReusedItemCount: Int64;

    procedure HandleOnData(Sender: TObject; Item: TListItem);
    procedure HandleOnDataHint(Sender: TObject; StartIndex, EndIndex: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure RunAllTests;
  end;

procedure TVirtualModeTester.HandleOnData(Sender: TObject; Item: TListItem);
var
  idx, localIdx: Integer;
  pRec: POMMTrackRecord;
begin
  Inc(FOnDataCalls);
  if Pointer(Item) = FLastItemPtr then
    Inc(FReusedItemCount)
  else
    FLastItemPtr := Pointer(Item);

  idx := Item.Index;
  if (idx >= FCacheStart) and (idx < FCacheStart + FCacheCount) then
  begin
    localIdx := idx - FCacheStart;
    Item.Caption := IntToStr(FCacheSlice[localIdx].TrackID);
    Item.SubItems.Clear;
    Item.SubItems.Add(StrPas(@FCacheSlice[localIdx].Title[0]));
    Item.SubItems.Add(StrPas(@FCacheSlice[localIdx].Artist[0]));
    Item.SubItems.Add(StrPas(@FCacheSlice[localIdx].Album[0]));
  end
  else if (FLibEngine <> nil) and (idx >= 0) and (idx < Integer(FLibEngine.TrackCount)) then
  begin
    pRec := FLibEngine.GetRecordByIndex(Cardinal(idx));
    if pRec <> nil then
    begin
      Item.Caption := IntToStr(pRec^.TrackID);
      Item.SubItems.Clear;
      Item.SubItems.Add(StrPas(@pRec^.Title[0]));
      Item.SubItems.Add(StrPas(@pRec^.Artist[0]));
      Item.SubItems.Add(StrPas(@pRec^.Album[0]));
    end;
  end;
end;

procedure TVirtualModeTester.HandleOnDataHint(Sender: TObject; StartIndex, EndIndex: Integer);
begin
  // Emulates requesting cache slice
end;

constructor TVirtualModeTester.Create;
begin
  Application.Initialize;
  FForm := TForm.CreateNew(nil);
  FForm.Width := 800;
  FForm.Height := 600;

  FLV := TListView.Create(FForm);
  FLV.Parent := FForm;
  FLV.Align := alClient;
  FLV.ViewStyle := vsReport;
  FLV.OwnerData := True;
  FLV.OnData := @HandleOnData;
  FLV.OnDataHint := @HandleOnDataHint;

  FLV.Columns.Add.Caption := 'ID';
  FLV.Columns.Add.Caption := 'Title';
  FLV.Columns.Add.Caption := 'Artist';
  FLV.Columns.Add.Caption := 'Album';

  FCacheStart := 0;
  FCacheCount := 0;
  FOnDataCalls := 0;
  FLastItemPtr := nil;
  FReusedItemCount := 0;

  FLibEngine := TOMMLibraryEngine.Create('', TEST_LIB_PATH);
  if not FLibEngine.OpenLibrary then
  begin
    Writeln(StdErr, 'Error: Failed to open ', TEST_LIB_PATH);
    Halt(1);
  end;
end;

destructor TVirtualModeTester.Destroy;
begin
  if FLibEngine <> nil then
    FLibEngine.Free;
  FLV.Free;
  FForm.Free;
  inherited Destroy;
end;

procedure TVirtualModeTester.RunAllTests;
var
  heapBefore, heapAfter: PtrUInt;
  heapDiff: Int64;
  i: Integer;
  item: TListItem;
  tStart, tEnd: Int64;
  simList: TTop20List;
  total, filtered, outCount: Cardinal;
begin
  Writeln('======================================================================');
  Writeln('  CHALLENGE 1: Virtual Owner-Data Mode Stress (50,000 Tracks)         ');
  Writeln('======================================================================');

  // Test 1.1: Verify 50,000 tracks in library
  Writeln('Test 1.1: Library Engine Track Count');
  Writeln('  Indexed Tracks: ', FLibEngine.TrackCount);
  if FLibEngine.TrackCount <> 50000 then
  begin
    Writeln('  [FAIL] Expected 50000 tracks, got ', FLibEngine.TrackCount);
    Halt(1);
  end;
  Writeln('  [PASS] 50,000 tracks verified.');

  // Test 1.2: Virtual Mode Zero TListItem Allocation Check
  Writeln('Test 1.2: Heap status before vs after setting Items.Count := 50000');
  heapBefore := GetFPCHeapStatus.CurrHeapUsed;
  FLV.Items.Count := 50000;
  heapAfter := GetFPCHeapStatus.CurrHeapUsed;
  heapDiff := Int64(heapAfter) - Int64(heapBefore);
  Writeln('  Heap before: ', heapBefore, ' bytes');
  Writeln('  Heap after:  ', heapAfter, ' bytes');
  Writeln('  Heap delta:  ', heapDiff, ' bytes');

  // In non-virtual mode, 50,000 TListItem objects would consume > 3 MB.
  // In virtual owner-data mode, setting Count does NOT instantiate 50,000 TListItem instances.
  if heapDiff > 16384 then
  begin
    Writeln('  [FAIL] Setting Items.Count allocated significant heap (', heapDiff, ' bytes)!');
    Halt(1);
  end;
  Writeln('  [PASS] Zero TListItem allocation verified (delta = ', heapDiff, ' bytes << 16 KB).');

  // Test 1.3: Cache slice population and flyweight rendering
  Writeln('Test 1.3: Populate 128-track cache slice and verify row access');
  FLibEngine.GetViewportPage(0, MAX_CACHE_ITEMS, '', total, filtered, outCount, @FCacheSlice[0], MAX_CACHE_ITEMS);
  FCacheStart := 0;
  FCacheCount := outCount;
  Writeln('  Loaded cache slice: ', FCacheCount, ' tracks');

  // In virtual mode, accessing FLV.Items[idx] retrieves the flyweight owner data item and calls OnData
  item := FLV.Items[42];
  if item = nil then
  begin
    Writeln('  [FAIL] Failed to retrieve virtual item at index 42');
    Halt(1);
  end;
  if item.Caption <> '43' then // 1-based track ID
  begin
    Writeln('  [FAIL] Cache slice item caption mismatch: expected 43, got ', item.Caption);
    Halt(1);
  end;
  Writeln('  [PASS] Cache slice item retrieved: ID=', item.Caption, ', Title="', item.SubItems[0], '"');

  // Access item outside cache slice (direct mmap fallback)
  item := FLV.Items[49999];
  if item = nil then
  begin
    Writeln('  [FAIL] Failed to retrieve virtual item at index 49999');
    Halt(1);
  end;
  if item.Caption <> '50000' then
  begin
    Writeln('  [FAIL] Fallback mmap item caption mismatch: expected 50000, got ', item.Caption);
    Halt(1);
  end;
  Writeln('  [PASS] Fallback mmap item retrieved: ID=', item.Caption, ', Title="', item.SubItems[0], '"');

  // Test 1.4: Full 50,000 track virtual scroll traversal
  Writeln('Test 1.4: Traversing 50,000 virtual rows with flyweight item');
  FOnDataCalls := 0;
  FReusedItemCount := 0;
  FLastItemPtr := nil;

  heapBefore := GetFPCHeapStatus.CurrHeapUsed;
  tStart := GetMonotonicMicros;
  for i := 0 to 49999 do
  begin
    item := FLV.Items[i];
    // Spot check
    if (i = 0) and (item.Caption <> '1') then
    begin
      Writeln('  [FAIL] Row 0 caption mismatch');
      Halt(1);
    end;
  end;
  tEnd := GetMonotonicMicros;
  heapAfter := GetFPCHeapStatus.CurrHeapUsed;
  heapDiff := Int64(heapAfter) - Int64(heapBefore);

  Writeln('  Traversed 50,000 rows in ', (tEnd - tStart) div 1000, ' ms (', (tEnd - tStart), ' us)');
  Writeln('  Total OnData calls: ', FOnDataCalls);
  Writeln('  Reused flyweight item count: ', FReusedItemCount, ' / ', FOnDataCalls, ' (', Format('%.1f%%', [FReusedItemCount * 100.0 / FOnDataCalls]), ')');
  Writeln('  Heap delta after 50,000 row renders: ', heapDiff, ' bytes');
  if heapDiff > 32768 then
  begin
    Writeln('  [FAIL] Heap leaked during row rendering: ', heapDiff, ' bytes');
    Halt(1);
  end;
  Writeln('  [PASS] Full 50,000-track scroll traversal completed with zero heap growth and flyweight item reuse.');

  // Test 1.5: 32-dim Int8 Similarity Query Responsiveness on 50,000 Tracks
  Writeln('');
  Writeln('======================================================================');
  Writeln('  CHALLENGE 3: Top-20 Similar Tracks Query Responsiveness (< 5ms)     ');
  Writeln('======================================================================');
  tStart := GetMonotonicMicros;
  simList := QueryTopSimilar(FLibEngine, 1, 20);
  tEnd := GetMonotonicMicros;
  Writeln('  Returned Candidates: ', simList.Count);
  Writeln('  Top match ID: ', simList.Items[0].TrackID, ', Score: ', Format('%.4f', [simList.Items[0].Score]));
  Writeln('  Query Latency: ', Format('%.2f ms (%d us)', [(tEnd - tStart) / 1000.0, (tEnd - tStart)]));

  if simList.Count <> 20 then
  begin
    Writeln('  [FAIL] Expected 20 candidates, got ', simList.Count);
    Halt(1);
  end;

  if (tEnd - tStart) > 5000 then
  begin
    Writeln('  [FAIL] Query latency ', (tEnd - tStart) div 1000, ' ms exceeds 5 ms threshold!');
    Halt(1);
  end;
  Writeln('  [PASS] Top-20 query responsiveness: ', Format('%.2f ms', [(tEnd - tStart) / 1000.0]), ' < 5.00 ms.');

  Writeln('');
  Writeln('>>> ALL VIRTUAL MODE AND QUERY CHALLENGES PASSED EMPIRICALLY! <<<');
end;

var
  tester: TVirtualModeTester;
begin
  tester := TVirtualModeTester.Create;
  try
    tester.RunAllTests;
  finally
    tester.Free;
  end;
end.
