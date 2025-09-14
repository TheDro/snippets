; Alt+Shift+1 -> Focus RubyMine
!+1:: {
    if WinExist("ahk_exe rubymine64.exe")
        WinActivate
}

; Alt+Shift+2 -> Focus VS Code
!+2:: {
    if WinExist("ahk_exe Code.exe")
        WinActivate
}

; Alt+Shift+3 -> Focus Terminal
!+3:: {
    if WinExist("ahk_exe WindowsTerminal.exe")
        WinActivate
}

; Alt+Shift+4 -> Focus Brave
!+4:: {
    if WinExist("ahk_exe brave.exe")
        WinActivate
}