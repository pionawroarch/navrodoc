; navro. dokumentacja – automatyczna instalacja wtyczki SketchUp we wszystkich wersjach SketchUpa
!macro customInstall
  SetShellVarContext current
  DetailPrint "Instalacja wtyczki navro. dokumentacja w SketchUp..."
  FindFirst $0 $1 "$APPDATA\SketchUp\SketchUp *"
  navroSkpLoop:
    StrCmp $1 "" navroSkpDone
    IfFileExists "$APPDATA\SketchUp\$1\SketchUp\*.*" 0 navroSkpNext
      CreateDirectory "$APPDATA\SketchUp\$1\SketchUp\Plugins"
      CopyFiles /SILENT "$INSTDIR\resources\sketchup\*.*" "$APPDATA\SketchUp\$1\SketchUp\Plugins"
      DetailPrint "Wtyczka zainstalowana: $1"
    navroSkpNext:
    FindNext $0 $1
    Goto navroSkpLoop
  navroSkpDone:
  FindClose $0
!macroend
