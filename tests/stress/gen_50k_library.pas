program gen_50k_library;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  SysUtils, omm_library;

var
  outPath: string;
  lib: TOMMLibraryEngine;
  trackCount: Cardinal;
begin
  if ParamCount >= 1 then
    outPath := ParamStr(1)
  else
    outPath := 'library_50k.bin';

  trackCount := 50000;
  if ParamCount >= 2 then
    trackCount := StrToIntDef(ParamStr(2), 50000);

  Writeln('Generating synthetic library with ', trackCount, ' tracks to ', outPath, '...');
  lib := TOMMLibraryEngine.Create('', outPath);
  try
    lib.CreateDefaultSyntheticLibrary(trackCount);
    if lib.OpenLibrary then
    begin
      Writeln('Successfully created and opened library: ', lib.TrackCount, ' tracks.');
      lib.CloseLibrary;
    end
    else
    begin
      Writeln(StdErr, 'Error: Failed to verify generated library.');
      Halt(1);
    end;
  finally
    lib.Free;
  end;
end.
