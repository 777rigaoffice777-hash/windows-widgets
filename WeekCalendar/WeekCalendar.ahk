#Requires AutoHotkey v2.0
; WeekCalendar - semi-transparent desktop calendar with ISO week numbers and a transparency slider.
; Runs on AutoHotkey v2 (passes Smart App Control). Drawing: GDI+ flat API + UpdateLayeredWindow.
; Installs itself (--install), starts at logon (Task Scheduler + Run key), updates itself daily from GitHub windows-widgets.
#SingleInstance Off
#NoTrayIcon
Persistent
DetectHiddenWindows true
CoordMode "Mouse", "Screen"

global APP_NAME := "WeekCalendar", APP_TITLE := "Календарь недель", APP_VER := "1.2"
global RUN_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
global UNINST_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\WeekCalendar"
global INSTALL_DIR := EnvGet("LOCALAPPDATA") "\Programs\WeekCalendar"
global INSTALLED_SCRIPT := INSTALL_DIR "\WeekCalendar.ahk"
global SETTINGS_DIR := A_AppData "\WeekCalendar"
global SETTINGS_FILE := SETTINGS_DIR "\settings.ini"
global MONTHS := ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
global MONTHS_GEN := ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
global DOW := ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
global DOW_LONG := ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"]
; ---- install / autostart / daily update (same in every widget) ----
global REPO_RAW := "https://raw.githubusercontent.com/777rigaoffice777-hash/windows-widgets/main/"
global UPDATE_URL := REPO_RAW APP_NAME "/" APP_NAME ".ahk"
global TASK_NAME := "WindowsWidgets " APP_NAME
global UPDATE_HOUR := 8            ; check GitHub once a day, from 08:00 (or at the first start after 08:00)
global MUTEX_HANDLE := 0
global FORCE_UPDATE_CHECK := false ; --update-check: check right away (for testing)

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
    }
    if wantUninstall {
        Uninstall(true)
        ExitApp
    }
    if (!portable && A_ScriptFullPath != INSTALLED_SCRIPT) {
        r := MsgBox("Установить «Календарь недель» на этот компьютер?`n`n"
            . "Он скопируется в вашу папку программ и будет сам запускаться при входе в Windows.`n`n"
            . "«Нет» — просто открыть без установки.", APP_TITLE, "YesNoCancel Icon?")
        if (r = "Cancel")
            ExitApp
        if (r = "Yes") {
            err := Install()
            if (err = "") {
                Run('"' A_AhkPath '" "' INSTALLED_SCRIPT '"')
                MsgBox("Готово. Календарь установлен и будет запускаться вместе с Windows.`n`n"
                    . "Настройки — правой кнопкой мыши по календарю.", APP_TITLE, "Iconi")
            } else
                MsgBox("Не удалось установить:`n" err, APP_TITLE, "Iconx")
            ExitApp
        }
    }
    MUTEX_HANDLE := DllCall("CreateMutex", "Ptr", 0, "Int", 1, "Str", "Local\WeekCalendar.SingleInstance", "Ptr")
    if (A_LastError = 183)
        ExitApp
    Cal.Start()
}

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
    if (ask && MsgBox("Удалить «Календарь недель» с этого компьютера?", APP_TITLE, "YesNo Icon?") != "Yes")
        return
    CloseOtherInstances()
    try SetAutostart(false)
    try RegDeleteKey(UNINST_KEY)
    try DirDelete(SETTINGS_DIR, true)
    if DirExist(INSTALL_DIR)
        Run(A_ComSpec ' /c ping -n 3 127.0.0.1 >nul & rd /s /q "' INSTALL_DIR '"', , "Hide")
    if ask
        MsgBox("Календарь удалён.", APP_TITLE, "Iconi")
}

; ======================= settings (same file format as the C# build) =======================
class Cfg {
    static Transparency := 30, X := -2147483648, Y := -2147483648, TopMost := false, LastUpdateCheck := 0

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
                    case "Transparency": this.Transparency := Max(0, Min(95, Integer(v)))
                    case "X": this.X := Integer(v)
                    case "Y": this.Y := Integer(v)
                    case "TopMost": this.TopMost := (v = "1")
                    case "LastUpdateCheck": this.LastUpdateCheck := Integer(v)
                }
            }
        }
    }

    static Save() {
        try {
            DirCreate(SETTINGS_DIR)
            f := FileOpen(SETTINGS_FILE, "w", "UTF-8-RAW")
            f.Write("Transparency=" this.Transparency "`r`nX=" this.X "`r`nY=" this.Y "`r`nTopMost=" (this.TopMost ? "1" : "0") "`r`nLastUpdateCheck=" this.LastUpdateCheck "`r`n")
            f.Close()
        }
    }
}

; ======================= dates =======================
Today() => FormatTime(A_Now, "yyyyMMdd")
DowMon0(d) => Mod(Integer(FormatTime(d, "WDay")) + 5, 7)       ; Monday = 0
AddDays(d, n) => FormatTime(DateAdd(d, n, "Days"), "yyyyMMdd")
IsoWeek(d) {
    th := AddDays(d, 3 - DowMon0(d))
    return (Integer(FormatTime(th, "YDay")) - 1) // 7 + 1
}

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
    static Brush(color) {
        b := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &b)
        return b
    }
    static Pen(color, w, round := false) {
        p := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", color, "Float", w, "Int", 0, "Ptr*", &p)
        if round {
            DllCall("gdiplus\GdipSetPenStartCap", "Ptr", p, "Int", 2)
            DllCall("gdiplus\GdipSetPenEndCap", "Ptr", p, "Int", 2)
            DllCall("gdiplus\GdipSetPenLineJoin", "Ptr", p, "Int", 2)
        }
        return p
    }
    static FillRounded(g, color, x, y, w, h, r) {
        p := this.Rounded(x, y, w, h, r), b := this.Brush(color)
        DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", b, "Ptr", p)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b), DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    }
    static DrawRounded(g, color, width, x, y, w, h, r) {
        p := this.Rounded(x, y, w, h, r), pn := this.Pen(color, width)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pn, "Ptr", p)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pn), DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    }
    static FillEllipse(g, color, x, y, w, h) {
        b := this.Brush(color)
        DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", b, "Float", x, "Float", y, "Float", w, "Float", h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
    }
    static Lines(g, pen, pts) {
        buf := Buffer(pts.Length * 4)
        for i, v in pts
            NumPut("Float", v, buf, (i - 1) * 4)
        DllCall("gdiplus\GdipDrawLines", "Ptr", g, "Ptr", pen, "Ptr", buf, "Int", pts.Length // 2)
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
    static Text(g, s, font, color, x, y, w, h, align, shadow, shadowA) {
        fmt := 0
        DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", &fmt)   ; NoWrap
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
        rc := Buffer(16)
        sb := this.Brush(ARGB(shadowA, 0, 0, 0))
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
class Cal {
    static gui := 0, hwnd := 0, sc := 1, W := 0, H := 0
    static today := "", shownY := 0, shownM := 0
    static rPrev := [0, 0, 0, 0], rNext := [0, 0, 0, 0], rTitle := [0, 0, 0, 0], rSlider := [0, 0, 0, 0]
    static trackX0 := 0, trackX1 := 0, sliding := false
    static fBig := 0, fMonth := 0, fDay := 0, fDayB := 0, fSmall := 0, fWeek := 0

    static S(v) => v * this.sc

    static Start() {
        Cfg.Load()
        Gp.Start()
        this.today := Today()
        this.shownY := Integer(SubStr(this.today, 1, 4)), this.shownM := Integer(SubStr(this.today, 5, 2))
        this.sc := A_ScreenDPI / 96
        this.W := RoundEven(272 * this.sc), this.H := RoundEven(326 * this.sc)   ; +26 for the transparency slider
        sc := this.sc
        this.fBig := Gp.Font("Segoe UI Semibold", 20 * sc)
        this.fMonth := Gp.Font("Segoe UI Semibold", 15 * sc)
        this.fDay := Gp.Font("Segoe UI", 14 * sc)
        this.fDayB := Gp.Font("Segoe UI Semibold", 14 * sc)
        this.fSmall := Gp.Font("Segoe UI", 12 * sc)
        this.fWeek := Gp.Font("Segoe UI Semibold", 13 * sc)

        g := Gui("-Caption +ToolWindow +E0x80000 -DPIScale" (Cfg.TopMost ? " +AlwaysOnTop" : ""), APP_TITLE)
        this.gui := g, this.hwnd := g.Hwnd

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
            x := r - this.W - Integer(16 * sc), y := t + Integer(16 * sc)
        }
        g.Show("NA x" x " y" y " w" this.W " h" this.H)
        this.Render()
        Updater.Start()
        Updater.TakeUpdatedMarker()

        OnMessage(0x201, ObjBindMethod(this, "OnLDown"))
        OnMessage(0x203, ObjBindMethod(this, "OnLDbl"))
        OnMessage(0x200, ObjBindMethod(this, "OnMove"))
        OnMessage(0x202, ObjBindMethod(this, "OnLUp"))
        OnMessage(0x20A, ObjBindMethod(this, "OnWheel"))
        OnMessage(0x205, ObjBindMethod(this, "OnRUp"))
        OnMessage(0x1E, ObjBindMethod(this, "OnTimeChange"))    ; WM_TIMECHANGE
        OnMessage(0x7E, ObjBindMethod(this, "OnDisplay"))       ; WM_DISPLAYCHANGE
        SetTimer(ObjBindMethod(this, "Tick"), 20000)
    }

    static Tick() {
        t := Today()
        if (t != this.today) {
            wasCurrent := this.shownY = Integer(SubStr(this.today, 1, 4)) && this.shownM = Integer(SubStr(this.today, 5, 2))
            this.today := t
            if wasCurrent
                this.shownY := Integer(SubStr(t, 1, 4)), this.shownM := Integer(SubStr(t, 5, 2))
            this.Render()
        }
    }

    static OnTimeChange(*) {
        SetTimer(() => (this.today := Today(), this.Render()), -200)
    }
    static OnDisplay(*) {
        SetTimer(ObjBindMethod(this, "Render"), -200)
    }

    static AddMonths(n) {
        m := this.shownY * 12 + (this.shownM - 1) + n
        this.shownY := m // 12, this.shownM := Mod(m, 12) + 1
        this.Render()
    }

    static GoToday() {
        this.today := Today()
        this.shownY := Integer(SubStr(this.today, 1, 4)), this.shownM := Integer(SubStr(this.today, 5, 2))
        this.Render()
    }

    static SetTransparency(t) {
        Cfg.Transparency := Max(0, Min(95, t))
        Cfg.Save()
        this.Render()
    }

    ; ---------- menu ----------
    static OnRUp(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        SetTimer(ObjBindMethod(this, "ShowMenu"), -1)
        return 0
    }

    static ShowMenu() {
        m := Menu()
        m.Add("Сегодня", (*) => this.GoToday())
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
        if (MsgBox("Удалить «Календарь недель» с этого компьютера?", APP_TITLE, "YesNo Icon?") = "Yes") {
            Uninstall(false)
            ExitApp
        }
    }

    ; ---------- mouse ----------
    static In(r, x, y) => x >= r[1] && x < r[1] + r[3] && y >= r[2] && y < r[2] + r[4]

    static XY(lParam, &x, &y) {
        x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
        if (x > 0x7FFF)
            x -= 0x10000
        if (y > 0x7FFF)
            y -= 0x10000
    }

    static OnLDown(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        if this.In(this.rSlider, x, y) {
            this.sliding := true
            DllCall("SetCapture", "Ptr", this.hwnd)
            this.SlideTo(x)
            return 0
        }
        if this.In(this.rPrev, x, y)
            return (this.AddMonths(-1), 0)
        if this.In(this.rNext, x, y)
            return (this.AddMonths(1), 0)
        if this.In(this.rTitle, x, y)
            return (this.GoToday(), 0)
        DllCall("ReleaseCapture")
        DllCall("SendMessage", "Ptr", this.hwnd, "UInt", 0xA1, "Ptr", 2, "Ptr", 0)
        WinGetPos(&wx, &wy, , , this.hwnd)
        Cfg.X := wx, Cfg.Y := wy
        Cfg.Save()
        return 0
    }

    static SlideTo(x) {
        if (this.trackX1 <= this.trackX0)
            return
        f := Max(0, Min(1, (x - this.trackX0) / (this.trackX1 - this.trackX0)))
        t := RoundEven(f * 95)
        if (t != Cfg.Transparency) {
            Cfg.Transparency := t
            this.Render()
        }
    }

    static OnMove(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd || !this.sliding)
            return
        this.XY(lParam, &x, &y)
        this.SlideTo(x)
        return 0
    }

    static OnLUp(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd || !this.sliding)
            return
        this.sliding := false
        DllCall("ReleaseCapture")
        Cfg.Save()
        this.Render()
        return 0
    }

    static OnLDbl(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        this.XY(lParam, &x, &y)
        if this.In(this.rSlider, x, y)
            return (this.OnLDown(wParam, lParam, msg, hwnd), 0)
        if this.In(this.rPrev, x, y)
            this.AddMonths(-1)
        else if this.In(this.rNext, x, y)
            this.AddMonths(1)
        else
            this.GoToday()
        return 0
    }

    static OnWheel(wParam, lParam, msg, hwnd) {
        if (hwnd != this.hwnd)
            return
        delta := (wParam >> 16) & 0xFFFF
        if (delta > 0x7FFF)
            delta -= 0x10000
        if (wParam & 0x8)   ; MK_CONTROL
            this.SetTransparency(Cfg.Transparency + (delta > 0 ? -5 : 5))
        else
            this.AddMonths(delta > 0 ? -1 : 1)
        return 0
    }

    ; ---------- drawing (1:1 port of CalendarForm.Draw) ----------
    static Txt(g, s, font, color, x, y, w, h, align) {
        Gp.Text(g, s, font, color, x, y, w, h, align, this.S(1), Cfg.Transparency >= 50 ? 150 : 70)
    }

    static Chevron(g, r, dir, color) {
        S := this.S.Bind(this)
        cx := r[1] + r[3] / 2, cy := r[2] + r[4] / 2, a := S(4.5)
        pts := [cx - dir * a * 0.5, cy - a, cx + dir * a * 0.5, cy, cx - dir * a * 0.5, cy + a]
        sh := Gp.Pen(ARGB(110, 0, 0, 0), S(2.4), true)
        o := S(1)
        Gp.Lines(g, sh, [pts[1] + o, pts[2] + o, pts[3] + o, pts[4] + o, pts[5] + o, pts[6] + o])
        DllCall("gdiplus\GdipDeletePen", "Ptr", sh)
        p := Gp.Pen(color, S(2.2), true)
        Gp.Lines(g, p, pts)
        DllCall("gdiplus\GdipDeletePen", "Ptr", p)
    }

    static Render() {
        if !this.hwnd
            return
        W := this.W, H := this.H
        S := this.S.Bind(this)
        fg := ARGB(255, 240, 242, 246), dimRGB := [120, 126, 138], dim := ARGB(255, 120, 126, 138)
        weekend := ARGB(255, 255, 140, 140), accent := ARGB(255, 110, 168, 255), accentFill := ARGB(255, 62, 120, 235)
        tdy := this.today

        bmp := 0, g := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", W, "Int", H, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
        DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 3)
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0x00FFFFFF)

        alpha := Max(RoundEven(255 * (100 - Cfg.Transparency) / 100.0), 3)
        Gp.FillRounded(g, ARGB(alpha, 18, 20, 26), 0.5, 0.5, W - 1, H - 1, S(12))
        Gp.DrawRounded(g, ARGB(Min(255, alpha // 2 + 20), 255, 255, 255), 1, 0.5, 0.5, W - 1, H - 1, S(12))

        pad := S(14), y := S(10)
        this.Txt(g, "Неделя " IsoWeek(tdy), this.fBig, fg, pad, y, W - 2 * pad, S(34), 0)
        this.Txt(g, SubStr(tdy, 1, 4), this.fSmall, dim, pad, y, W - 2 * pad, S(34), 2)
        y += S(36)

        rowH := S(26)
        this.rPrev := [pad - S(4), y, S(28), rowH]
        this.rNext := [W - pad - S(24), y, S(28), rowH]
        this.rTitle := [pad + S(28), y, W - 2 * pad - S(56), rowH]
        this.Chevron(g, this.rPrev, -1, fg)
        this.Chevron(g, this.rNext, 1, fg)
        t := this.rTitle
        this.Txt(g, MONTHS[this.shownM] " " this.shownY, this.fMonth, fg, t[1], t[2], t[3], t[4], 1)
        y += rowH + S(6)

        weekColW := S(36)
        cellW := (W - 2 * pad - weekColW) / 7
        cellH := S(27)
        gx := pad + weekColW
        this.Txt(g, "Нед", this.fSmall, accent, pad, y, weekColW, S(20), 1)
        Loop 7 {
            i := A_Index - 1
            this.Txt(g, DOW[A_Index], this.fSmall, i >= 5 ? weekend : dim, gx + i * cellW, y, cellW, S(20), 1)
        }
        y += S(22)

        first := Format("{:04}{:02}01", this.shownY, this.shownM)
        d := AddDays(first, -DowMon0(first))
        Loop 6 {
            ry := y + (A_Index - 1) * cellH
            monday := d
            curWeek := tdy >= monday && tdy < AddDays(monday, 7)
            if curWeek
                Gp.FillRounded(g, ARGB(40, 255, 255, 255), pad - S(4), ry + S(1), W - 2 * pad + S(8), cellH - S(2), S(7))
            this.Txt(g, IsoWeek(monday), this.fWeek, curWeek ? fg : accent, pad, ry, weekColW, cellH, 1)
            Loop 7 {
                i := A_Index - 1
                cx := gx + i * cellW
                inMonth := Integer(SubStr(d, 5, 2)) = this.shownM
                isToday := d = tdy
                c := !inMonth ? ARGB(90, dimRGB[1], dimRGB[2], dimRGB[3]) : (i >= 5 ? weekend : fg)
                if isToday {
                    sz := Min(cellW, cellH) - S(3)
                    Gp.FillEllipse(g, accentFill, cx + (cellW - sz) / 2, ry + (cellH - sz) / 2, sz, sz)
                    c := ARGB(255, 255, 255, 255)
                }
                this.Txt(g, Integer(SubStr(d, 7, 2)), isToday ? this.fDayB : this.fDay, c, cx, ry, cellW, cellH, 1)
                d := AddDays(d, 1)
            }
        }
        y += 6 * cellH + S(4)

        line := DOW_LONG[DowMon0(tdy) + 1] ", " Integer(SubStr(tdy, 7, 2)) " " MONTHS_GEN[Integer(SubStr(tdy, 5, 2))]
        line := StrUpper(SubStr(line, 1, 1)) SubStr(line, 2)
        this.Txt(g, line, this.fSmall, dim, pad, y, W - 2 * pad, S(28), 1)

        ; ---- transparency slider (same look as on the lock button) ----
        btnA := 110 + alpha * 145 // 255
        sy := y + S(28)
        this.rSlider := [pad - S(6), sy, W - 2 * pad + S(12), H - sy - S(2)]
        cy := sy + (H - sy - S(2)) / 2
        ir := S(6), ix := pad + S(4) + ir
        pn := Gp.Pen(fg, S(1.4))
        DllCall("gdiplus\GdipDrawEllipse", "Ptr", g, "Ptr", pn, "Float", ix - ir, "Float", cy - ir, "Float", 2 * ir, "Float", 2 * ir)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pn)
        b := Gp.Brush(fg)
        DllCall("gdiplus\GdipFillPie", "Ptr", g, "Ptr", b, "Float", ix - ir, "Float", cy - ir, "Float", 2 * ir, "Float", 2 * ir, "Float", 90, "Float", 180)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
        this.trackX0 := pad + S(26)
        this.trackX1 := W - pad - S(42)
        kx := this.trackX0 + Cfg.Transparency / 95 * (this.trackX1 - this.trackX0)
        pbg := Gp.Pen(ARGB(Min(255, btnA), 90, 98, 112), S(4), true)
        DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pbg, "Float", this.trackX0, "Float", cy, "Float", this.trackX1, "Float", cy)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pbg)
        pf := Gp.Pen(ARGB(Min(255, btnA + 40), 110, 168, 255), S(4), true)
        if (kx > this.trackX0)
            DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pf, "Float", this.trackX0, "Float", cy, "Float", kx, "Float", cy)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pf)
        kr := S(this.sliding ? 8 : 7)
        Gp.FillEllipse(g, ARGB(90, 0, 0, 0), kx - kr + S(1), cy - kr + S(1), 2 * kr, 2 * kr)
        Gp.FillEllipse(g, ARGB(255, 255, 255, 255), kx - kr, cy - kr, 2 * kr, 2 * kr)
        this.Txt(g, Cfg.Transparency "%", this.fSmall, fg, this.trackX1 + S(8), sy, W - pad - this.trackX1 - S(8), H - sy - S(2), 2)

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
        NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bl)
        DllCall("UpdateLayeredWindow", "Ptr", this.hwnd, "Ptr", screen, "Ptr", pt, "Ptr", sz, "Ptr", mem, "Ptr", src, "UInt", 0, "Ptr", bl, "UInt", 2)
        DllCall("SelectObject", "Ptr", mem, "Ptr", old)
        DllCall("DeleteObject", "Ptr", hbm)
        DllCall("DeleteDC", "Ptr", mem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    }
}
