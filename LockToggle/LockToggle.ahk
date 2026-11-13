#Requires AutoHotkey v2.0
; LockToggle - desktop button for the screen auto-lock (secure screensaver): ON/OFF, or OFF for three
; user-set durations (default 1 / 7 / 24 h), tray icon. While OFF it keeps the display on and the PC awake.
; Runs on AutoHotkey v2 (passes Smart App Control). Drawing: GDI+ flat API + UpdateLayeredWindow.
; Installs itself (--install), starts at logon (Task Scheduler + Run key), updates itself daily from GitHub windows-widgets.
#SingleInstance Off
#NoTrayIcon
Persistent
DetectHiddenWindows true
CoordMode "Mouse", "Screen"

global APP_NAME := "LockToggle", APP_TITLE := "Блокировка экрана", APP_VER := "1.5"
global RUN_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
global UNINST_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\LockToggle"
global DESKTOP_KEY := "HKCU\Control Panel\Desktop"
global INSTALL_DIR := EnvGet("LOCALAPPDATA") "\Programs\LockToggle"
global INSTALLED_SCRIPT := INSTALL_DIR "\LockToggle.ahk"
global SETTINGS_DIR := A_AppData "\LockToggle"
global SETTINGS_FILE := SETTINGS_DIR "\settings.ini"
global DEFAULT_SLOTS := [60, 420, 1440]   ; timer buttons, minutes (1 h / 7 h / 24 h); each can be changed by right-click
global MAX_SLOT_MIN := 30 * 1440
global MAX_TR := 95
global BTN_NONE := -1, BTN_MAIN := 0, BTN_SLIDER := 4
global TICKS_1601 := 504911232000000000
; ---- install / autostart / daily update (same in every widget) ----
global REPO_RAW := "https://raw.githubusercontent.com/777rigaoffice777-hash/windows-widgets/main/"
global UPDATE_URL := REPO_RAW APP_NAME "/" APP_NAME ".ahk"
global TASK_NAME := "WindowsWidgets " APP_NAME
global UPDATE_HOUR := 8            ; check GitHub once a day, from 08:00 (or at the first start after 08:00)
global MUTEX_HANDLE := 0
global FORCE_UPDATE_CHECK := false ; --update-check: check right away (for testing)

; ======================= entry point =======================
Main()

Main() {
    global MUTEX_HANDLE, FORCE_UPDATE_CHECK
    portable := false, wantUninstall := false, cmd := ""
    for a in A_Args {
        if (a = "--uninstall")
            wantUninstall := true
        else if (a = "--install")
            cmd := "install"
        else if (a = "--update-check")
            FORCE_UPDATE_CHECK := true
        else if (a = "--portable")
            portable := true
        else if (a = "--on")
            cmd := "on"
        else if (a = "--state")
            cmd := "state"
    }
    if wantUninstall {
        Uninstall(true)
        ExitApp
    }
    if (cmd = "on") {
        LockTurnOn()
        ExitApp
    }
    if (cmd = "state")
        ExitApp(LockIsOn() ? 1 : 0)
    if (cmd = "install") {                     ; silent install (used by install.ps1): no questions
        err := Install()
        if (err = "")
            Run('"' A_AhkPath '" "' INSTALLED_SCRIPT '"')
        ExitApp(err = "" ? 0 : 1)
    }

    if (!portable && A_ScriptFullPath != INSTALLED_SCRIPT) {
        r := MsgBox("Установить кнопку «Блокировка экрана» на этот компьютер?`n`n"
            . "Она скопируется в вашу папку программ и будет сама запускаться при входе в Windows.`n`n"
            . "«Нет» — просто открыть без установки.", APP_TITLE, "YesNoCancel Icon?")
        if (r = "Cancel")
            ExitApp
        if (r = "Yes") {
            err := Install()
            if (err = "") {
                Run('"' A_AhkPath '" "' INSTALLED_SCRIPT '"')
                MsgBox("Готово. Кнопка установлена и будет запускаться вместе с Windows.`n`n"
                    . "Перетаскивайте её мышкой за край. Настройки — правой кнопкой мыши.", APP_TITLE, "Iconi")
            } else
                MsgBox("Не удалось установить:`n" err, APP_TITLE, "Iconx")
            ExitApp
        }
    }

    MUTEX_HANDLE := DllCall("CreateMutex", "Ptr", 0, "Int", 1, "Str", "Local\LockToggle.SingleInstance", "Ptr")
    if (A_LastError = 183)   ; ERROR_ALREADY_EXISTS
        ExitApp
    Widget.Start()
}

; ======================= Windows setting =======================
SPI_Get(action) {
    v := 0
    DllCall("SystemParametersInfo", "UInt", action, "UInt", 0, "Int*", &v, "UInt", 0)
    return v
}
SPI_Set(action, param) => DllCall("SystemParametersInfo", "UInt", action, "UInt", param, "Ptr", 0, "UInt", 3)

ExpandEnv(s) {
    buf := Buffer(2048 * 2)
    DllCall("ExpandEnvironmentStrings", "Str", s, "Ptr", buf, "UInt", 2048)
    return StrGet(buf)
}

ScreenSaverExe() => Trim(RegRead(DESKTOP_KEY, "SCRNSAVE.EXE", ""))

LockIsOn() {
    exe := ScreenSaverExe()
    return SPI_Get(0x10) != 0 && SPI_Get(0x76) != 0 && exe != "" && FileExist(ExpandEnv(exe)) != ""
}

LockTimeoutMinutes() {
    s := SPI_Get(0x0E)
    return s <= 0 ? 0 : Max(1, (s + 59) // 60)
}

LockTurnOn() {
    exe := ScreenSaverExe()
    if (exe = "" || !FileExist(ExpandEnv(exe)))
        RegWrite(A_WinDir "\system32\scrnsave.scr", "REG_SZ", DESKTOP_KEY, "SCRNSAVE.EXE")
    if (SPI_Get(0x0E) <= 0)
        SPI_Set(0x0F, 300)
    SPI_Set(0x77, 1)   ; SPI_SETSCREENSAVESECURE
    SPI_Set(0x11, 1)   ; SPI_SETSCREENSAVEACTIVE
    LockReleaseAwake()
}

LockTurnOff() {
    SPI_Set(0x11, 0)
    LockKeepAwake()
}

LockKeepAwake() => DllCall("SetThreadExecutionState", "UInt", 0x80000003)
LockReleaseAwake() => DllCall("SetThreadExecutionState", "UInt", 0x80000000)

; ======================= install / autostart / daily update (same block in every widget) =======================
CloseOtherInstances() {
    me := DllCall("GetCurrentProcessId")
    while ProcessExist(APP_NAME ".exe") {           ; the old C# build
        ProcessClose(APP_NAME ".exe")
        Sleep 200
        if (A_Index > 20)
            break
    }
    for h in WinGetList(APP_TITLE " ahk_class AutoHotkeyGUI") {
        pid := WinGetPID(h)
        if (pid != me) {
            ProcessClose(pid)
            ProcessWaitClose(pid, 5)
        }
    }
}

Install() {
    try {
        CloseOtherInstances()
        DirCreate(INSTALL_DIR)
        if (A_ScriptFullPath != INSTALLED_SCRIPT)
            FileCopy(A_ScriptFullPath, INSTALLED_SCRIPT, 1)
        try FileDelete(INSTALL_DIR "\" APP_NAME ".exe")   ; leftover of the C# build
        SetAutostart(true)
        RegWrite(APP_TITLE, "REG_SZ", UNINST_KEY, "DisplayName")
        RegWrite(APP_VER, "REG_SZ", UNINST_KEY, "DisplayVersion")
        RegWrite("windows-widgets", "REG_SZ", UNINST_KEY, "Publisher")
        RegWrite(A_AhkPath, "REG_SZ", UNINST_KEY, "DisplayIcon")
        RegWrite(INSTALL_DIR, "REG_SZ", UNINST_KEY, "InstallLocation")
        RegWrite('"' A_AhkPath '" "' INSTALLED_SCRIPT '" --uninstall', "REG_SZ", UNINST_KEY, "UninstallString")
        RegWrite(1, "REG_DWORD", UNINST_KEY, "NoModify")
        RegWrite(1, "REG_DWORD", UNINST_KEY, "NoRepair")
        RegWrite(64, "REG_DWORD", UNINST_KEY, "EstimatedSize")
        return ""
    } catch as e
        return e.Message
}

XmlEsc(s) => StrReplace(StrReplace(StrReplace(StrReplace(StrReplace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), '"', "&quot;"), "'", "&apos;")

TaskFolder() {
    svc := ComObject("Schedule.Service")
    svc.Connect()
    return svc.GetFolder("\")
}

TaskExists() {
    try {
        TaskFolder().GetTask(TASK_NAME)
        return true
    }
    return false
}

; Task Scheduler "at logon" starts within seconds after logon; the Run key is processed last (1-2 minutes later).
; No admin rights needed: the task belongs to the current user and runs with normal rights.
RegisterLogonTask() {
    user := EnvGet("USERDOMAIN") "\" A_UserName
    xml := '<?xml version="1.0" encoding="UTF-16"?>'
        . '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        . '<RegistrationInfo><Description>' XmlEsc(APP_TITLE) ' - start at logon (windows-widgets)</Description></RegistrationInfo>'
        . '<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>' XmlEsc(user) '</UserId></LogonTrigger></Triggers>'
        . '<Principals><Principal id="Author"><UserId>' XmlEsc(user) '</UserId><LogonType>InteractiveToken</LogonType>'
        . '<RunLevel>LeastPrivilege</RunLevel></Principal></Principals>'
        . '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        . '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        . '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>4</Priority>'
        . '<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled></Settings>'
        . '<Actions Context="Author"><Exec><Command>' XmlEsc(A_AhkPath) '</Command>'
        . '<Arguments>' XmlEsc('"' INSTALLED_SCRIPT '"') '</Arguments></Exec></Actions></Task>'
    TaskFolder().RegisterTask(TASK_NAME, xml, 6, "", "", 3)   ; 6 = create or update, 3 = interactive token
}

DeleteLogonTask() {
    try TaskFolder().DeleteTask(TASK_NAME, 0)
}

IsAutostart() => RegRead(RUN_KEY, APP_NAME, "") != ""

; Both the Run key (always works) and the logon task (fast). The second copy to start exits (single-instance mutex).
SetAutostart(on) {
    target := FileExist(INSTALLED_SCRIPT) ? INSTALLED_SCRIPT : A_ScriptFullPath
    if on {
        RegWrite('"' A_AhkPath '" "' target '"', "REG_SZ", RUN_KEY, APP_NAME)
        if (target = INSTALLED_SCRIPT)
            try RegisterLogonTask()
    } else {
        if IsAutostart()
            RegDelete(RUN_KEY, APP_NAME)
        DeleteLogonTask()
    }
}

class Updater {
    static Start() {
        if (A_ScriptFullPath != INSTALLED_SCRIPT)
            return
        if (IsAutostart() && !TaskExists())    ; installs made before the logon task existed
            try RegisterLogonTask()
        if FORCE_UPDATE_CHECK
            SetTimer(ObjBindMethod(this, "Check"), -3000)
        SetTimer(ObjBindMethod(this, "Tick"), -60000)        ; a minute after start
        SetTimer(ObjBindMethod(this, "Tick"), 600000)        ; then every 10 minutes
    }

    static Tick() {
        if (A_Hour < UPDATE_HOUR)
            return
        if (Cfg.LastUpdateCheck = Integer(FormatTime(, "yyyyMMdd")))
            return
        this.Check()
    }

    ; Downloads the widget from GitHub; installs it and restarts when the version there is newer.
    static Check(*) {
        tmp := A_Temp "\" APP_NAME "-update.ahk"
        try {
            try FileDelete(tmp)
            Download(UPDATE_URL "?t=" A_TickCount, tmp)
            txt := FileRead(tmp, "UTF-8")
        } catch
            return                                   ; no internet: next try in 10 minutes
        Cfg.LastUpdateCheck := Integer(FormatTime(, "yyyyMMdd"))
        Cfg.Save()
        if (SubStr(txt, 1, 23) != "#Requires AutoHotkey v2"
            || !InStr(txt, 'APP_NAME := "' APP_NAME '"')
            || !RegExMatch(txt, 'APP_VER := "(\d+(?:\.\d+)*)"', &m))
            return
        if (VerCompare(m[1], APP_VER) <= 0)
            return
        if (RunWait('"' A_AhkPath '" /ErrorStdOut /validate "' tmp '"', , "Hide") != 0)
            return                                   ; broken file on GitHub: keep the current version
        FileCopy(tmp, INSTALLED_SCRIPT, 1)
        try RegWrite(m[1], "REG_SZ", UNINST_KEY, "DisplayVersion")
        try {
            DirCreate(SETTINGS_DIR)
            f := FileOpen(SETTINGS_DIR "\updated.txt", "w", "UTF-8-RAW"), f.Write(m[1]), f.Close()
        }
        if MUTEX_HANDLE
            DllCall("CloseHandle", "Ptr", MUTEX_HANDLE)
        Reload()
    }

    ; Version we were just updated to ("" if none); the marker is removed.
    static TakeUpdatedMarker() {
        p := SETTINGS_DIR "\updated.txt"
        if !FileExist(p)
            return ""
        v := ""
        try v := Trim(FileRead(p, "UTF-8"))
        try FileDelete(p)
        return v
    }
}

Uninstall(ask) {
    if (ask && MsgBox("Удалить кнопку «Блокировка экрана» с этого компьютера?`n`nАвтоблокировка экрана будет включена.",
        APP_TITLE, "YesNo Icon?") != "Yes")
        return
    CloseOtherInstances()
    try LockTurnOn()
    try SetAutostart(false)
    try RegDeleteKey(UNINST_KEY)
    try DirDelete(SETTINGS_DIR, true)
    if DirExist(INSTALL_DIR)
        Run(A_ComSpec ' /c ping -n 3 127.0.0.1 >nul & rd /s /q "' INSTALL_DIR '"', , "Hide")
    if ask
        MsgBox("Кнопка удалена, автоблокировка включена.", APP_TITLE, "Iconi")
}

; ======================= settings (same file format as the C# build) =======================
class Cfg {
    static Transparency := 30, X := -2147483648, Y := -2147483648, TopMost := false
    static OffUntilUtc := 0, OffSlot := 0, LastUpdateCheck := 0, TrayPromoted := 0
    static OffBoot := 0            ; boot stamp (UTC yyyyMMddHHmm) of the Windows session in which the lock was switched off
    static RelockAfterBoot := 1    ; after a restart the lock always comes back on
    static Slots := [DEFAULT_SLOTS[1], DEFAULT_SLOTS[2], DEFAULT_SLOTS[3]]

    static Load() {
        try {
            if !FileExist(SETTINGS_FILE)
                return
            Loop Parse FileRead(SETTINGS_FILE), "`n", "`r" {
                p := InStr(A_LoopField, "=")
                if !p
                    continue
                k := Trim(SubStr(A_LoopField, 1, p - 1)), v := Trim(SubStr(A_LoopField, p + 1))
                if !IsInteger(v)
                    continue
                switch k {
                    case "Transparency": this.Transparency := Max(0, Min(MAX_TR, Integer(v)))
                    case "X": this.X := Integer(v)
                    case "Y": this.Y := Integer(v)
                    case "TopMost": this.TopMost := (v = "1")
                    case "OffUntilUtc": this.OffUntilUtc := Integer(v)
                    case "OffSlot": this.OffSlot := Integer(v)
                    case "LastUpdateCheck": this.LastUpdateCheck := Integer(v)
                    case "TrayPromoted": this.TrayPromoted := Integer(v)
                    case "OffBoot": this.OffBoot := Integer(v)
                    case "RelockAfterBoot": this.RelockAfterBoot := Integer(v)
                    case "Slot1", "Slot2", "Slot3":
                        n := Integer(v)
                        if (n >= 1 && n <= MAX_SLOT_MIN)
                            this.Slots[Integer(SubStr(k, 5))] := n
                }
            }
        }
    }

    static Save() {
        try {
            DirCreate(SETTINGS_DIR)
            f := FileOpen(SETTINGS_FILE, "w", "UTF-8-RAW")
            f.Write("Transparency=" this.Transparency "`r`nX=" this.X "`r`nY=" this.Y "`r`nTopMost=" (this.TopMost ? "1" : "0")
                . "`r`nOffUntilUtc=" this.OffUntilUtc "`r`nOffSlot=" this.OffSlot
                . "`r`nSlot1=" this.Slots[1] "`r`nSlot2=" this.Slots[2] "`r`nSlot3=" this.Slots[3]
                . "`r`nLastUpdateCheck=" this.LastUpdateCheck "`r`nTrayPromoted=" this.TrayPromoted
                . "`r`nOffBoot=" this.OffBoot "`r`nRelockAfterBoot=" this.RelockAfterBoot "`r`n")
            f.Close()
        }
    }
}

; ======================= time helpers (.NET ticks, UTC) =======================
UtcTicksNow() => DateDiff(A_NowUTC, "16010101000000", "Seconds") * 10000000 + TICKS_1601
UtcOffsetSec() => Round(DateDiff(A_Now, A_NowUTC, "Seconds") / 60) * 60
TicksToLocal(t) => DateAdd(DateAdd("16010101000000", (t - TICKS_1601) // 10000000, "Seconds"), UtcOffsetSec(), "Seconds")

Left2(sec) {
    if (sec < 0)
        sec := 0
    mins := Ceil(sec / 60)
    return (mins // 60) ":" Format("{:02}", Mod(mins, 60))
}

; ---------- timer-button durations ----------
SlotLabel(m) {          ; short text on the button
    if (m < 60)
        return m " мин"
    if (Mod(m, 60) = 0)
        return (m // 60) " ч"
    return (m // 60) ":" Format("{:02}", Mod(m, 60)) " ч"
}

SlotLong(m) {           ; text for menus and the input box
    h := m // 60, mm := Mod(m, 60), s := ""
    if h
        s := h " ч"
    if mm
        s .= (s ? " " : "") mm " мин"
    return s
}

; C# Math.Round (banker's rounding), so sizes match the exe pixel for pixel.
RoundEven(x) {
    f := Floor(x), d := x - f
    if (d > 0.5)
        return f + 1
    if (d < 0.5)
        return f
    return Mod(f, 2) = 0 ? f : f + 1
}

; ======================= GDI+ helpers =======================
ARGB(a, r, g, b) => ((Integer(a) & 0xFF) << 24) | (Integer(r) << 16) | (Integer(g) << 8) | Integer(b)
ARGBc(a, c) => ARGB(a, c[1], c[2], c[3])

class Gp {
    static Start() {
        DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
        si := Buffer(24, 0), NumPut("UInt", 1, si, 0)
        tok := 0
        DllCall("gdiplus\GdiplusStartup", "UPtr*", &tok, "Ptr", si, "Ptr", 0)
    }
    static Rounded(x, y, w, h, r) {
        p := 0, d := r * 2
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &p)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
        DllCall("gdiplus\GdipClosePathFigure", "Ptr", p)
        return p
    }
    static Brush(argb) {
        b := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
        return b
    }
    static Pen(argb, w, round := false) {
        p := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", w, "Int", 0, "Ptr*", &p)
        if round {
            DllCall("gdiplus\GdipSetPenStartCap", "Ptr", p, "Int", 2)
            DllCall("gdiplus\GdipSetPenEndCap", "Ptr", p, "Int", 2)
        }
        return p
    }
    static FillRounded(g, argb, x, y, w, h, r) {
        p := this.Rounded(x, y, w, h, r), b := this.Brush(argb)
        DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", b, "Ptr", p)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b), DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    }
    static DrawRounded(g, argb, width, x, y, w, h, r) {
        p := this.Rounded(x, y, w, h, r), pn := this.Pen(argb, width)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pn, "Ptr", p)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pn), DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    }
    static Line(g, pen, x1, y1, x2, y2) => DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pen, "Float", x1, "Float", y1, "Float", x2, "Float", y2)
    static Arc(g, pen, x, y, w, h, s, sw) => DllCall("gdiplus\GdipDrawArc", "Ptr", g, "Ptr", pen, "Float", x, "Float", y, "Float", w, "Float", h, "Float", s, "Float", sw)
    static FillEllipse(g, argb, x, y, w, h) {
        b := this.Brush(argb)
        DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", b, "Float", x, "Float", y, "Float", w, "Float", h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
    }
    static Font(name, px) {
        fam := 0, f := 0
        if DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", name, "Ptr", 0, "Ptr*", &fam) != 0 {
            DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam)
            style := InStr(name, "Semibold") ? 1 : 0
        } else
            style := 0
        DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", style, "Int", 2, "Ptr*", &f)
        return f
    }
    static Text(g, s, font, color, x, y, w, h, align, shadow) {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", &fmt)   ; NoWrap
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", fmt, "Int", 3)            ; EllipsisCharacter
        rc := Buffer(16)
        sb := this.Brush(ARGB(110, 0, 0, 0))
        NumPut("Float", x + shadow, "Float", y + shadow, "Float", w, "Float", h, rc)
        DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", s, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", sb)
        b := this.Brush(color)
        NumPut("Float", x, "Float", y, "Float", w, "Float", h, rc)
        DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", s, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", b)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", sb), DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
        DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    }
}

; ======================= the widget =======================
class Widget {
    static gui := 0, hwnd := 0, sc := 1, W := 0, H := 0
    static isOn := true, hover := -1, pressed := -1, sliding := false, tracking := false
    static rMain := [0, 0, 0, 0], rHours := [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], rSlider := [0, 0, 0, 0]
    static trackX0 := 0, trackX1 := 0
    static fMain := 0, fSub := 0, fBtn := 0

    static S(v) => v * this.sc

    static Start() {
        Cfg.Load()
        Gp.Start()
        this.sc := A_ScreenDPI / 96
        this.W := RoundEven(272 * this.sc), this.H := RoundEven(134 * this.sc)   ; same width as the week calendar
        this.fMain := Gp.Font("Segoe UI Semibold", 15 * this.sc)
        this.fSub := Gp.Font("Segoe UI", 12 * this.sc)
        this.fBtn := Gp.Font("Segoe UI Semibold", 13 * this.sc)

        g := Gui("-Caption +ToolWindow +E0x80000 -DPIScale" (Cfg.TopMost ? " +AlwaysOnTop" : ""), APP_TITLE)
        this.gui := g, this.hwnd := g.Hwnd

        ; position: saved one if it is on some screen, else bottom-right of the primary work area
        x := Cfg.X, y := Cfg.Y, visible := false
        if (Cfg.X != -2147483648) {
            Loop MonitorGetCount() {
                MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
                if (x + 20 >= l && x + 20 < r && y + 20 >= t && y + 20 < b) {
                    visible := true
                    x := Max(l, Min(x, r - this.W)), y := Max(t, Min(y, b - this.H))   ; keep fully inside the work area
                }
            }
        }
        if !visible {
            MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
            x := r - this.W - Integer(16 * this.sc), y := b - this.H - Integer(16 * this.sc)
        }
        relocked := this.RelockIfRestarted(FileExist(SETTINGS_DIR "\updated.txt") != "")
        this.Check()
        g.Show("NA x" x " y" y " w" this.W " h" this.H)
        this.Render()
        A_IconHidden := false
        this.UpdateTray(true)
        Updater.Start()
        v := Updater.TakeUpdatedMarker()
        if (v != "")
            TrayTip("Обновлено до версии " v, APP_TITLE, "Iconi")
        else if relocked
            TrayTip("Блокировка снова включена после перезагрузки.", APP_TITLE, "Iconi")
        SetTimer(ObjBindMethod(this, "PromoteTrayIcon"), -10000)
        SetTimer(ObjBindMethod(this, "PromoteTrayIcon"), -60000)

        OnMessage(0x201, ObjBindMethod(this, "OnLDown"))
        OnMessage(0x202, ObjBindMethod(this, "OnLUp"))
        OnMessage(0x200, ObjBindMethod(this, "OnMove"))
        OnMessage(0x2A3, ObjBindMethod(this, "OnLeave"))
        OnMessage(0x20A, ObjBindMethod(this, "OnWheel"))
        OnMessage(0x205, ObjBindMethod(this, "OnRUp"))
        OnMessage(0x20, ObjBindMethod(this, "OnSetCursor"))
        OnMessage(0x218, ObjBindMethod(this, "OnSystemChange"))   ; WM_POWERBROADCAST
        OnMessage(0x1E, ObjBindMethod(this, "OnSystemChange"))    ; WM_TIMECHANGE
        OnMessage(0x7E, ObjBindMethod(this, "OnSystemChange"))    ; WM_DISPLAYCHANGE
        SetTimer(ObjBindMethod(this, "Tick"), 5000)
    }

    static Tick() {
        this.Check()
        this.Render()
    }

    static OnSystemChange(wParam, lParam, msg, hwnd) {
        SetTimer(ObjBindMethod(this, "Tick"), -200)
    }

    ; Reads the live Windows state; turns the lock back on when the timer has run out.
    static Check() {
        this.isOn := LockIsOn()
        if (!this.isOn && Cfg.OffUntilUtc > 0 && UtcTicksNow() >= Cfg.OffUntilUtc) {
            LockTurnOn()
            this.isOn := LockIsOn()
        }
        if this.isOn {
            if (Cfg.OffUntilUtc != 0 || Cfg.OffSlot != 0) {
                Cfg.OffUntilUtc := 0, Cfg.OffSlot := 0
                Cfg.Save()
            }
            LockReleaseAwake()
        } else
            LockKeepAwake()
    }

    static DoOn() {
        LockTurnOn()
        Cfg.OffUntilUtc := 0, Cfg.OffSlot := 0, Cfg.OffBoot := 0
        Cfg.Save()
        this.Check(), this.Render()
    }

    ; When Windows was started (UTC, to the minute). GetTickCount64 keeps counting during sleep,
    ; so the stamp only changes after a real restart.
    static BootStamp() {
        up := DllCall("GetTickCount64", "Int64") // 1000
        return Integer(FormatTime(DateAdd(A_NowUTC, -up, "Seconds"), "yyyyMMddHHmm"))
    }

    static SameBoot(stamp) => stamp > 0 && Abs(DateDiff(stamp "00", this.BootStamp() "00", "Minutes")) <= 2

    ; Lock is off but was switched off before the last restart (or outside the widget): switch it back on.
    ; A restart of the widget itself (daily update, «Закрыть» and start again) keeps the lock as it was.
    static RelockIfRestarted(justUpdated := false) {
        if (!Cfg.RelockAfterBoot || LockIsOn() || this.SameBoot(Cfg.OffBoot))
            return false
        if (justUpdated && Cfg.OffBoot = 0) {     ; switched off by an older version (no stamp) and just updated: same session
            Cfg.OffBoot := this.BootStamp()
            Cfg.Save()
            return false
        }
        LockTurnOn()
        Cfg.OffUntilUtc := 0, Cfg.OffSlot := 0, Cfg.OffBoot := 0
        Cfg.Save()
        return true
    }

    static ToggleRelock() {
        Cfg.RelockAfterBoot := Cfg.RelockAfterBoot ? 0 : 1
        if (Cfg.RelockAfterBoot && !LockIsOn())
            Cfg.OffBoot := this.BootStamp()     ; current switch-off still counts for this session
        Cfg.Save()
    }

    ; slot 0 = no time limit; slot 1..3 = timer button
    static DoOff(slot) {
        Cfg.OffBoot := this.BootStamp()
        Cfg.OffSlot := slot
        Cfg.OffUntilUtc := slot > 0 ? UtcTicksNow() + Cfg.Slots[slot] * 600000000 : 0
        Cfg.Save()
        LockTurnOff()
        this.Check(), this.Render()
    }

    ; ---------- custom time for a timer button (right-click on it) ----------
    ; Dialog: a number + "минуты" / "часы". Opened by right-click on a timer button or from the menu.
    static slotDlg := 0

    static EditSlot(i, *) {     ; * : menu callbacks pass extra arguments
        if this.slotDlg {
            try this.slotDlg.Destroy()
            this.slotDlg := 0
        }
        self := this                      ; used inside the nested functions below
        cur := Cfg.Slots[i]
        inHours := Mod(cur, 60) = 0
        d := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", APP_TITLE " — кнопка " i)
        this.slotDlg := d
        d.SetFont("s10", "Segoe UI")
        d.MarginX := 16, d.MarginY := 14
        d.AddText("xm", "Кнопка " i " сейчас снимает блокировку на " SlotLong(cur) ".")
        d.AddText("xm y+12", "На сколько снимать:")
        num := d.AddEdit("xm y+6 w90 Number Limit5", inHours ? cur // 60 : cur)
        d.AddUpDown("Range1-43200 0x80", inHours ? cur // 60 : cur)     ; 0x80 = no thousands separator
        rMin := d.AddRadio("x+14 yp+4" (inHours ? "" : " Checked"), "минуты")
        rHour := d.AddRadio("x+12 yp" (inHours ? " Checked" : ""), "часы")
        err := d.AddText("xm y+14 w300 cC03030", "")
        ok := d.AddButton("xm y+6 w100 Default", "ОК")
        cancel := d.AddButton("x+10 yp w100", "Отмена")

        close := (*) => (self.slotDlg := 0, d.Destroy())
        save(*) {
            n := IsInteger(num.Value) ? Integer(num.Value) : 0
            mins := rHour.Value ? n * 60 : n
            if (n < 1) {
                err.Value := "Введите число больше нуля."
                return
            }
            if (mins > MAX_SLOT_MIN) {
                err.Value := "Не больше 30 дней (720 часов)."
                return
            }
            Cfg.Slots[i] := mins
            Cfg.Save()
            close()
            self.Render()
        }
        ok.OnEvent("Click", save)
        cancel.OnEvent("Click", close)
        d.OnEvent("Escape", close)
        d.OnEvent("Close", close)
        d.Show("AutoSize Center")
        num.Focus()
        SendMessage(0xB1, 0, -1, num)   ; EM_SETSEL: select the number so typing replaces it
    }

    static ResetSlots() {
        Loop 3
            Cfg.Slots[A_Index] := DEFAULT_SLOTS[A_Index]
        Cfg.Save()
        this.Render()
    }

    ; ---------- tray icon ----------
    static trayKey := ""

    static StatusText() {
        if this.isOn
            return "включена"
        if (Cfg.OffUntilUtc > 0)
            return "выключена до " FormatTime(TicksToLocal(Cfg.OffUntilUtc), "HH:mm")
        return "выключена без срока"
    }

    static UpdateTray(force := false) {
        if A_IconHidden
            return
        A_IconTip := APP_TITLE ": " this.StatusText()
        key := this.isOn "|" Cfg.OffSlot "|" Cfg.Slots[1] "|" Cfg.Slots[2] "|" Cfg.Slots[3]
        if (!force && key = this.trayKey)
            return
        this.trayKey := key
        TraySetIcon("HICON:" this.MakeIcon(this.isOn))
        m := A_TrayMenu
        m.Delete()
        m.Add("Показать поверх окон", (*) => this.BringToFront())
        m.Default := "Показать поверх окон"
        m.ClickCount := 1
        m.Add()
        if this.isOn
            m.Add("Выключить блокировку (без срока)", (*) => this.DoOff(0))
        else
            m.Add("Включить блокировку", (*) => this.DoOn())
        Loop 3 {
            i := A_Index
            name := "Снять на " SlotLong(Cfg.Slots[i]) Format("{:" i "}", "")   ; trailing spaces keep equal names apart
            m.Add(name, this.TraySlot.Bind(this, i))
            if (!this.isOn && Cfg.OffSlot = i)
                m.Check(name)
        }
        m.Add()
        m.Add("Закрыть кнопку (до следующего входа)", (*) => ExitApp())
    }

    static TraySlot(i, *) => this.DoOff(i)

    ; Windows 11 hides new tray icons under "^": show ours on the taskbar once (the user may hide it again later).
    static PromoteTrayIcon() {
        if Cfg.TrayPromoted
            return
        Loop Reg "HKCU\Control Panel\NotifyIconSettings", "K" {
            k := A_LoopRegKey "\" A_LoopRegName
            if (RegRead(k, "ExecutablePath", "") = A_AhkPath) {
                try RegWrite(1, "REG_DWORD", k, "IsPromoted")
                Cfg.TrayPromoted := 1
            }
        }
        if Cfg.TrayPromoted
            Cfg.Save()
    }

    static BringToFront() {
        h := this.hwnd
        WinShow(h)
        DllCall("SetWindowPos", "Ptr", h, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)   ; HWND_TOPMOST
        if !Cfg.TopMost
            DllCall("SetWindowPos", "Ptr", h, "Ptr", -2, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13) ; back to normal, stays on top of the others
        try WinActivate(h)
        this.Render()
    }

    ; small rounded square, green (lock on) or red (off), with a white padlock
    static MakeIcon(on) {
        n := Max(16, DllCall("GetSystemMetrics", "Int", 49))   ; SM_CXSMICON
        k := n / 16
        bmp := 0, g := 0, hicon := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", n, "Int", n, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0)
        Gp.FillRounded(g, on ? ARGB(255, 38, 160, 92) : ARGB(255, 214, 64, 64), 0, 0, n, n, 3.5 * k)
        white := ARGB(255, 255, 255, 255)
        bw := 9 * k, bh := 7 * k, bx := (n - bw) / 2, by := 7.5 * k
        sw := 5.6 * k, sx := bx + (bw - sw) / 2, top := 2.6 * k
        if !on
            sx += 3.2 * k
        p := Gp.Pen(white, 1.7 * k, true)
        Gp.Arc(g, p, sx, top, sw, sw, 180, 180)
        Gp.Line(g, p, sx + sw, top + sw / 2, sx + sw, by)
        Gp.Line(g, p, sx, top + sw / 2, sx, on ? by : by - 2 * k)
        DllCall("gdiplus\GdipDeletePen", "Ptr", p)
        Gp.FillRounded(g, white, bx, by, bw, bh, 1.5 * k)
        DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", bmp, "Ptr*", &hicon)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
        return hicon
    }

    static SetTransparency(t) {
        Cfg.Transparency := Max(0, Min(MAX_TR, t))
        Cfg.Save()
        this.Render()
    }

    ; ---------- menu ----------
    static OnRUp(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        hit := this.HitTest(x, y)
        if (hit >= 1 && hit <= 3)
            SetTimer(this.EditSlot.Bind(this, hit), -1)
        else
            SetTimer(ObjBindMethod(this, "ShowMenu"), -1)
        return 0
    }

    static ShowMenu() {
        m := Menu()
        m.Add("Включить блокировку сейчас", (*) => this.DoOn())
        m.Add("Снять блокировку без срока", (*) => this.DoOff(0))
        if this.isOn
            m.Disable("Включить блокировку сейчас")
        if !(this.isOn || Cfg.OffUntilUtc != 0)
            m.Disable("Снять блокировку без срока")
        m.Add()
        tr := Menu()
        for lv in [0, 20, 40, 60, 80, 95] {
            name := lv "%" (lv = 0 ? " (непрозрачный)" : lv = 95 ? " (почти невидимый)" : "")
            tr.Add(name, this.MenuTr.Bind(this, lv))
            if (Cfg.Transparency = lv)
                tr.Check(name)
        }
        tr.Add()
        tr.Add("Плавно: Ctrl + колесо мыши", (*) => 0)
        tr.Disable("Плавно: Ctrl + колесо мыши")
        m.Add("Прозрачность фона", tr)
        sl := Menu()
        Loop 3
            sl.Add("Кнопка " A_Index ": " SlotLong(Cfg.Slots[A_Index]) " — изменить…", this.EditSlot.Bind(this, A_Index))
        sl.Add()
        sl.Add("Вернуть 1 ч / 7 ч / 24 ч", (*) => this.ResetSlots())
        sl.Add("Подсказка: правая кнопка мыши по кнопке времени", (*) => 0)
        sl.Disable("Подсказка: правая кнопка мыши по кнопке времени")
        m.Add("Время кнопок", sl)
        m.Add("Включать блокировку после перезагрузки", (*) => this.ToggleRelock())
        if Cfg.RelockAfterBoot
            m.Check("Включать блокировку после перезагрузки")
        m.Add("Поверх всех окон", (*) => this.ToggleTop())
        if Cfg.TopMost
            m.Check("Поверх всех окон")
        m.Add("Запускать вместе с Windows", (*) => this.ToggleAuto())
        if IsAutostart()
            m.Check("Запускать вместе с Windows")
        m.Add()
        m.Add("Закрыть (до следующего входа в Windows)", (*) => ExitApp())
        if FileExist(INSTALLED_SCRIPT)
            m.Add("Удалить с компьютера…", (*) => this.MenuUninstall())
        m.Show()
    }

    static MenuTr(lv, *) => this.SetTransparency(lv)

    static ToggleTop() {
        Cfg.TopMost := !Cfg.TopMost
        WinSetAlwaysOnTop(Cfg.TopMost ? 1 : 0, this.hwnd)
        Cfg.Save()
    }

    static ToggleAuto() {
        try SetAutostart(!IsAutostart())
        catch as e
            MsgBox(e.Message, APP_TITLE)
    }

    static MenuUninstall() {
        if (MsgBox("Удалить кнопку «Блокировка экрана» с этого компьютера?`n`nАвтоблокировка экрана будет включена.",
            APP_TITLE, "YesNo Icon?") = "Yes") {
            Uninstall(false)
            ExitApp
        }
    }

    ; ---------- mouse ----------
    static In(r, x, y) => x >= r[1] && x < r[1] + r[3] && y >= r[2] && y < r[2] + r[4]

    static HitTest(x, y) {
        if this.In(this.rMain, x, y)
            return BTN_MAIN
        Loop 3
            if this.In(this.rHours[A_Index], x, y)
                return A_Index
        if this.In(this.rSlider, x, y)
            return BTN_SLIDER
        return BTN_NONE
    }

    static XY(lParam, &x, &y) {
        x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
        if (x > 0x7FFF)
            x -= 0x10000
        if (y > 0x7FFF)
            y -= 0x10000
    }

    static SlideTo(x) {
        if (this.trackX1 <= this.trackX0)
            return
        f := Max(0, Min(1, (x - this.trackX0) / (this.trackX1 - this.trackX0)))
        t := RoundEven(f * MAX_TR)
        if (t != Cfg.Transparency) {
            Cfg.Transparency := t
            this.Render()
        }
    }

    static OnLDown(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        hit := this.HitTest(x, y)
        if (hit = BTN_SLIDER) {
            this.sliding := true
            DllCall("SetCapture", "Ptr", this.hwnd)
            this.SlideTo(x)
            return 0
        }
        if (hit != BTN_NONE) {
            this.pressed := hit
            DllCall("SetCapture", "Ptr", this.hwnd)
            this.Render()
            return 0
        }
        ; drag the window by any empty spot
        DllCall("ReleaseCapture")
        DllCall("SendMessage", "Ptr", this.hwnd, "UInt", 0xA1, "Ptr", 2, "Ptr", 0)
        WinGetPos(&wx, &wy, , , this.hwnd)
        Cfg.X := wx, Cfg.Y := wy
        Cfg.Save()
        return 0
    }

    static OnLUp(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        if this.sliding {
            this.sliding := false
            DllCall("ReleaseCapture")
            Cfg.Save()
            this.Render()
            return 0
        }
        was := this.pressed
        this.pressed := BTN_NONE
        DllCall("ReleaseCapture")
        if (was != BTN_NONE && this.HitTest(x, y) = was) {
            if (was = BTN_MAIN) {
                if this.isOn
                    this.DoOff(0)
                else
                    this.DoOn()
            } else
                this.DoOff(was)
        } else
            this.Render()
        return 0
    }

    static OnMove(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        if this.sliding {
            this.SlideTo(x)
            return 0
        }
        if !this.tracking {
            tme := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
            NumPut("UInt", tme.Size, tme, 0), NumPut("UInt", 2, tme, 4), NumPut("Ptr", this.hwnd, tme, 8)
            DllCall("TrackMouseEvent", "Ptr", tme)
            this.tracking := true
        }
        h := this.HitTest(x, y)
        if (h != this.hover) {
            this.hover := h
            this.Render()
        }
    }

    static OnLeave(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.tracking := false
        if this.sliding
            return
        if (this.hover != BTN_NONE || this.pressed != BTN_NONE) {
            this.hover := BTN_NONE, this.pressed := BTN_NONE
            this.Render()
        }
    }

    static OnWheel(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        delta := (wParam >> 16) & 0xFFFF
        if (delta > 0x7FFF)
            delta -= 0x10000
        if (wParam & 0x8)   ; MK_CONTROL
            this.SetTransparency(Cfg.Transparency + (delta > 0 ? -5 : 5))
        return 0
    }

    static OnSetCursor(wParam, lParam, msg, hwnd) {
        if (wParam != this.hwnd)
            return
        MouseGetPos(&mx, &my)
        WinGetPos(&wx, &wy, , , this.hwnd)
        id := this.HitTest(mx - wx, my - wy) = BTN_NONE ? 32646 : 32649   ; IDC_SIZEALL : IDC_HAND
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", id, "Ptr"))
        return 1
    }

    ; ---------- drawing (1:1 port of LockForm.Draw) ----------
    static Txt(g, s, font, argb, x, y, w, h, align) => Gp.Text(g, s, font, argb, x, y, w, h, align, this.S(1))

    static DrawPadlock(g, bxX, bxY, bxW, bxH, closed, argb) {
        S := this.S.Bind(this)
        bw := S(18), bh := S(14)
        bx := bxX + (bxW - bw) / 2, by := bxY + bxH / 2 - S(1)
        sw := S(11), sh := S(10)
        sx := bx + (bw - sw) / 2
        if !closed
            sx += S(7)
        p := Gp.Pen(argb, S(2.6), true)
        top := by - sh
        Gp.Arc(g, p, sx, top, sw, sw, 180, 180)
        Gp.Line(g, p, sx + sw, top + sw / 2, sx + sw, by)
        Gp.Line(g, p, sx, top + sw / 2, sx, closed ? by : by - S(4))
        DllCall("gdiplus\GdipDeletePen", "Ptr", p)
        Gp.FillRounded(g, argb, bx, by, bw, bh, S(3))
    }

    static Render() {
        if !this.hwnd
            return
        W := this.W, H := this.H
        S := this.S.Bind(this)
        fg := ARGB(255, 244, 246, 250), dim := ARGB(255, 205, 212, 222)
        green := [38, 160, 92], red := [214, 64, 64]

        bmp := 0, g := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", W, "Int", H, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)        ; AntiAlias
        DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 3)    ; AntiAliasGridFit
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0x00FFFFFF)

        alpha := Max(RoundEven(255 * (100 - Cfg.Transparency) / 100.0), 3)
        Gp.FillRounded(g, ARGB(alpha, 18, 20, 26), 0.5, 0.5, W - 1, H - 1, S(12))
        Gp.DrawRounded(g, ARGB(Min(255, alpha // 2 + 20), 255, 255, 255), 1, 0.5, 0.5, W - 1, H - 1, S(12))
        btnA := 110 + alpha * 145 // 255

        pad := S(8)
        ; ---- main button ----
        this.rMain := [pad, pad, W - 2 * pad, S(54)]
        r := this.rMain
        stateC := this.isOn ? green : red
        mainA := Min(255, btnA + (this.hover = BTN_MAIN ? 30 : 0) - (this.pressed = BTN_MAIN ? 40 : 0))
        Gp.FillRounded(g, ARGBc(mainA, stateC), r[1], r[2], r[3], r[4], S(9))
        this.DrawPadlock(g, r[1] + S(4), r[2], S(40), r[4], this.isOn, ARGB(255, 255, 255, 255))

        if this.isOn {
            l1 := "Блокировка вкл."
            mins := LockTimeoutMinutes()
            l2 := mins > 0 ? "Пароль после " mins " мин простоя" : "Пароль после простоя"
        } else if (Cfg.OffUntilUtc > 0) {
            untilL := TicksToLocal(Cfg.OffUntilUtc)
            l1 := "Выкл. ещё " Left2((Cfg.OffUntilUtc - UtcTicksNow()) / 10000000)
            d := FormatTime(untilL, "yyyyMMdd")
            day := d = FormatTime(A_Now, "yyyyMMdd") ? "" : d = FormatTime(DateAdd(A_Now, 1, "Days"), "yyyyMMdd") ? "завтра " : FormatTime(untilL, "dd.MM") " "
            l2 := "Вернётся " day "в " FormatTime(untilL, "HH:mm")
        } else {
            l1 := "Блокировка выкл."
            l2 := "Без срока · нажмите, чтобы включить"
        }
        tx := r[1] + S(46), right := r[1] + r[3]
        this.Txt(g, l1, this.fMain, fg, tx, r[2] + S(5), right - tx - S(6), S(24), 0)
        this.Txt(g, l2, this.fSub, dim, tx, r[2] + S(28), right - tx - S(6), S(20), 0)

        ; ---- timer buttons ----
        ry := r[2] + r[4] + S(6), rh := S(32)
        labelW := S(68)
        this.Txt(g, "Снять на:", this.fSub, fg, pad + S(2), ry, labelW, rh, 0)
        gap := S(6)
        bw := (W - 2 * pad - labelW - 2 * gap) / 3
        Loop 3 {
            i := A_Index
            bx := pad + labelW + (i - 1) * (bw + gap)
            this.rHours[i] := [bx, ry, bw, rh]
            active := !this.isOn && Cfg.OffUntilUtc > 0 && Cfg.OffSlot = i
            a := Min(255, (active ? btnA : btnA * 55 // 100) + (this.hover = i ? 40 : 0) - (this.pressed = i ? 40 : 0))
            c := active ? red : [70, 78, 92]
            Gp.FillRounded(g, ARGBc(Max(a, 20), c), bx, ry, bw, rh, S(7))
            Gp.DrawRounded(g, ARGB(Min(255, btnA // 2), 255, 255, 255), 1, bx, ry, bw, rh, S(7))
            this.Txt(g, SlotLabel(Cfg.Slots[i]), this.fBtn, fg, bx, ry, bw, rh, 1)
        }

        ; ---- transparency slider ----
        sy := ry + rh + S(2)
        this.rSlider := [pad, sy, W - 2 * pad, H - sy - S(2)]
        cy := sy + this.rSlider[4] / 2
        ir := S(6), ix := pad + S(4) + ir
        pn := Gp.Pen(fg, S(1.4))
        DllCall("gdiplus\GdipDrawEllipse", "Ptr", g, "Ptr", pn, "Float", ix - ir, "Float", cy - ir, "Float", 2 * ir, "Float", 2 * ir)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pn)
        b := Gp.Brush(fg)
        DllCall("gdiplus\GdipFillPie", "Ptr", g, "Ptr", b, "Float", ix - ir, "Float", cy - ir, "Float", 2 * ir, "Float", 2 * ir, "Float", 90, "Float", 180)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
        this.trackX0 := pad + S(26)
        this.trackX1 := W - pad - S(42)
        f := Cfg.Transparency / MAX_TR
        kx := this.trackX0 + f * (this.trackX1 - this.trackX0)
        hot := this.sliding || this.hover = BTN_SLIDER
        pbg := Gp.Pen(ARGB(Min(255, btnA), 90, 98, 112), S(4), true)
        Gp.Line(g, pbg, this.trackX0, cy, this.trackX1, cy)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pbg)
        pf := Gp.Pen(ARGB(Min(255, btnA + 40), 110, 168, 255), S(4), true)
        if (kx > this.trackX0)
            Gp.Line(g, pf, this.trackX0, cy, kx, cy)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pf)
        kr := S(hot ? 8 : 7)
        Gp.FillEllipse(g, ARGB(90, 0, 0, 0), kx - kr + S(1), cy - kr + S(1), 2 * kr, 2 * kr)
        Gp.FillEllipse(g, ARGB(255, 255, 255, 255), kx - kr, cy - kr, 2 * kr, 2 * kr)
        this.Txt(g, Cfg.Transparency "%", this.fSub, fg, this.trackX1 + S(8), sy, W - pad - this.trackX1 - S(8), this.rSlider[4], 2)

        ; ---- push to the layered window ----
        hbm := 0
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bmp, "Ptr*", &hbm, "UInt", 0)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
        screen := DllCall("GetDC", "Ptr", 0, "Ptr")
        mem := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
        old := DllCall("SelectObject", "Ptr", mem, "Ptr", hbm, "Ptr")
        WinGetPos(&wx, &wy, , , this.hwnd)
        pt := Buffer(8), sz := Buffer(8), src := Buffer(8, 0), bl := Buffer(4)
        NumPut("Int", wx, "Int", wy, pt), NumPut("Int", W, "Int", H, sz)
        NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bl)   ; AC_SRC_OVER, alpha 255, AC_SRC_ALPHA
        DllCall("UpdateLayeredWindow", "Ptr", this.hwnd, "Ptr", screen, "Ptr", pt, "Ptr", sz, "Ptr", mem, "Ptr", src, "UInt", 0, "Ptr", bl, "UInt", 2)
        DllCall("SelectObject", "Ptr", mem, "Ptr", old)
        DllCall("DeleteObject", "Ptr", hbm)
        DllCall("DeleteDC", "Ptr", mem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
        this.UpdateTray()
    }
}
