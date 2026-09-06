default rel
bits 64

global main

; Win32 Tray & Window APIs
extern GetModuleHandleA, RegisterClassA, CreateWindowExA, DefWindowProcA
extern GetMessageA, TranslateMessage, DispatchMessageA, PostQuitMessage, DestroyWindow
extern LoadIconA, Shell_NotifyIconA
extern CreatePopupMenu, AppendMenuA, TrackPopupMenu, DestroyMenu, GetCursorPos, SetForegroundWindow
extern RegOpenKeyExA, RegQueryValueExA, RegSetValueExA, RegDeleteValueA, RegCloseKey
extern GetModuleFileNameA, lstrlenA, ExitProcess

; Multimedia WaveOut APIs
extern waveOutGetNumDevs, waveOutGetDevCapsA, waveOutOpen, waveOutPrepareHeader
extern waveOutWrite, waveOutReset, waveOutUnprepareHeader, waveOutClose

; Windows Messages
WM_DESTROY          equ 0x0002
WM_COMMAND          equ 0x0111
WM_USER             equ 0x0400
WM_TRAYICON         equ (WM_USER + 1)
WM_RBUTTONUP        equ 0x0205
WM_LBUTTONUP        equ 0x0202
WM_DEVICECHANGE     equ 0x0219

; Menu IDs
ID_TRAY_STARTUP     equ 1001
ID_TRAY_EXIT        equ 1002
ID_DEV_DEFAULT      equ 3000
ID_DEV_BASE         equ 3001

; Menu Flags
MF_STRING           equ 0x0000
MF_POPUP            equ 0x0010
MF_CHECKED          equ 0x0008
MF_UNCHECKED        equ 0x0000
MF_SEPARATOR        equ 0x0800

; Tray Constants
NIM_ADD             equ 0
NIM_DELETE          equ 2
NIF_MESSAGE         equ 1
NIF_ICON            equ 2
NIF_TIP             equ 4
IDI_APPLICATION     equ 32512

; Registry
HKEY_CURRENT_USER   equ 0x80000001
KEY_READ            equ 0x20019
KEY_SET_VALUE       equ 0x0002
REG_SZ              equ 1

; WaveOut Constants
WAVE_FORMAT_PCM     equ 1
WAVE_MAPPER         equ -1
WHDR_BEGINLOOP      equ 4
WHDR_ENDLOOP        equ 8

; waveOutPrepareHeader/Write/UnprepareHeader all take the same
; (hWaveOut, &waveHdr, sizeof(WAVEHDR)) argument triple.
%macro WAVEHDR_CALL 1
    mov rcx, [hWaveOut]
    lea rdx, [waveHdr]
    mov r8d, 48
    call %1
%endmacro

section .data
    szClassName     db "AudioKeepAliveTray", 0
    szAppName       db "AudioKeepAlive", 0
    szRegKey        db "Software\Microsoft\Windows\CurrentVersion\Run", 0
    szMenuDevices   db "Audio Devices", 0
    szDefaultDev    db "Default Endpoint (WAVE_MAPPER)", 0
    szMenuStartup   db "Run on Startup", 0
    szMenuExit      db "Exit", 0
    szTip           db "Audio Keep Alive (Active)", 0

    ; WAVEFORMATEX (PCM 44.1kHz Stereo 16-bit)
    wFormatTag      dw WAVE_FORMAT_PCM
    nChannels       dw 2
    nSamplesPerSec  dd 44100
    nAvgBytesPerSec dd 176400
    nBlockAlign     dw 4
    wBitsPerSample  dw 16
    cbSize          dw 0

    currentDevId    dd -1

section .bss
    hInstance       resq 1
    hWnd            resq 1
    hIcon           resq 1
    hWaveOut        resq 1
    pt              resq 1
    msg             resb 48
    pathBuf         resb 260
    silentBuffer    resb 4096
    waveHdr         resb 48
    nid             resb 504
    wc              resb 72
    waveCaps        resb 52

section .text

; -------------------------------------------------------------
; Entry Point
; -------------------------------------------------------------
main:
    sub rsp, 104

    xor ecx, ecx
    call GetModuleHandleA
    mov [hInstance], rax

    ; Load embedded icon from resource ID 1 (fallback to IDI_APPLICATION)
    mov rcx, [hInstance]
    mov edx, 1
    call LoadIconA
    test rax, rax
    jnz .icon_ready
    xor ecx, ecx
    mov edx, IDI_APPLICATION
    call LoadIconA
.icon_ready:
    mov [hIcon], rax

    ; Register background message-only window class
    lea rax, [WndProc]
    mov [wc + 8], rax
    mov rax, [hInstance]
    mov [wc + 24], rax
    mov rax, [hIcon]
    mov [wc + 32], rax
    lea rax, [szClassName]
    mov [wc + 64], rax
    lea rcx, [wc]
    call RegisterClassA

    ; Create invisible listener window
    xor ecx, ecx
    lea rdx, [szClassName]
    lea r8, [szAppName]
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    mov qword [rsp + 64], 0
    mov qword [rsp + 72], 0
    mov rax, [hInstance]
    mov [rsp + 80], rax
    mov qword [rsp + 88], 0
    call CreateWindowExA
    mov [hWnd], rax

    ; Initialize Notification Tray Icon
    mov dword [nid], 504
    mov rax, [hWnd]
    mov [nid + 8], rax
    mov dword [nid + 16], 1
    mov dword [nid + 20], (NIF_ICON | NIF_MESSAGE | NIF_TIP)
    mov dword [nid + 24], WM_TRAYICON
    mov rax, [hIcon]
    mov [nid + 32], rax

    lea rsi, [szTip]
    lea rdi, [nid + 40]
.copy_tip:
    lodsb
    stosb
    test al, al
    jnz .copy_tip

    xor ecx, ecx
    lea rdx, [nid]
    call Shell_NotifyIconA

    ; Start silence stream on default device
    mov dword [currentDevId], -1
    call RestartAudio

.msg_loop:
    lea rcx, [msg]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call GetMessageA
    test eax, eax
    jle .exit
    lea rcx, [msg]
    call TranslateMessage
    lea rcx, [msg]
    call DispatchMessageA
    jmp .msg_loop

.exit:
    xor ecx, ecx
    call ExitProcess

; -------------------------------------------------------------
; Window Procedure
; -------------------------------------------------------------
WndProc:
    sub rsp, 40
    cmp edx, WM_TRAYICON
    je .tray_event
    cmp edx, WM_DEVICECHANGE
    je .restart_and_done
    cmp edx, WM_COMMAND
    je .command_event
    cmp edx, WM_DESTROY
    je .destroy_event

    call DefWindowProcA
    add rsp, 40
    ret

.tray_event:
    cmp r9d, WM_RBUTTONUP
    je .tray_menu
    cmp r9d, WM_LBUTTONUP
    jne .wnd_done
.tray_menu:
    call ShowContextMenu
    jmp .wnd_done

.command_event:
    cmp r8w, ID_TRAY_STARTUP
    je .toggle_startup
    cmp r8w, ID_TRAY_EXIT
    je .do_exit

    ; Default device (ID_DEV_DEFAULT) and enumerated devices (ID_DEV_BASE..+64)
    ; occupy one contiguous range: ID_DEV_DEFAULT == ID_DEV_BASE - 1, so
    ; subtracting ID_DEV_BASE naturally yields -1 for "default" and 0..63
    ; for enumerated devices, replacing what used to be two separate cases.
    cmp r8w, ID_DEV_DEFAULT
    jb .wnd_done
    cmp r8w, (ID_DEV_BASE + 64)
    ja .wnd_done
    movzx eax, r8w
    sub eax, ID_DEV_BASE
    mov [currentDevId], eax

.restart_and_done:
    call RestartAudio
    jmp .wnd_done

.toggle_startup:
    call IsStartupEnabled
    test eax, eax
    setz cl
    movzx ecx, cl
    call SetStartup
    jmp .wnd_done

.do_exit:
    mov rcx, [hWnd]
    call DestroyWindow
    jmp .wnd_done

.destroy_event:
    mov ecx, NIM_DELETE
    lea rdx, [nid]
    call Shell_NotifyIconA
    call StopAudio
    xor ecx, ecx
    call PostQuitMessage

.wnd_done:
    xor eax, eax
    add rsp, 40
    ret

; -------------------------------------------------------------
; Audio Helpers (waveOut)
; -------------------------------------------------------------
RestartAudio:
    sub rsp, 40
    call StopAudio
    call StartAudio
    add rsp, 40
    ret

StartAudio:
    sub rsp, 56
    lea rcx, [hWaveOut]
    mov edx, dword [currentDevId]
    lea r8, [wFormatTag]
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call waveOutOpen
    test eax, eax
    jnz .audio_fail

    lea rax, [silentBuffer]
    mov [waveHdr], rax
    mov dword [waveHdr + 8], 4096
    mov dword [waveHdr + 24], (WHDR_BEGINLOOP | WHDR_ENDLOOP)
    mov dword [waveHdr + 28], 0xFFFFFFFF

    WAVEHDR_CALL waveOutPrepareHeader
    WAVEHDR_CALL waveOutWrite

.audio_fail:
    add rsp, 56
    ret

StopAudio:
    sub rsp, 40
    mov rcx, [hWaveOut]
    test rcx, rcx
    jz .stop_done
    call waveOutReset
    WAVEHDR_CALL waveOutUnprepareHeader
    mov rcx, [hWaveOut]
    call waveOutClose
    mov qword [hWaveOut], 0
.stop_done:
    add rsp, 40
    ret

; -------------------------------------------------------------
; Context Menu with Dynamic Devices Submenu
; -------------------------------------------------------------
ShowContextMenu:
    push rbx
    push r12
    push r13
    push rsi
    sub rsp, 56

    lea rcx, [pt]
    call GetCursorPos

    call CreatePopupMenu
    mov rbx, rax

    call CreatePopupMenu
    mov r12, rax

    ; 1. Add Default Device option
    mov edx, MF_UNCHECKED
    cmp dword [currentDevId], -1
    jne .add_def_item
    mov edx, MF_CHECKED
.add_def_item:
    mov rcx, r12
    mov r8d, ID_DEV_DEFAULT
    lea r9, [szDefaultDev]
    call AppendMenuA

    ; 2. Enumerate installed output devices
    call waveOutGetNumDevs
    mov r13d, eax
    xor esi, esi

.enum_loop:
    cmp esi, r13d
    jge .enum_done

    mov ecx, esi
    lea rdx, [waveCaps]
    mov r8d, 52
    call waveOutGetDevCapsA
    test eax, eax
    jnz .next_dev

    mov edx, MF_UNCHECKED
    cmp esi, dword [currentDevId]
    jne .append_dev
    mov edx, MF_CHECKED
.append_dev:
    mov rcx, r12
    lea r8d, [rsi + ID_DEV_BASE]
    lea r9, [waveCaps + 8]
    call AppendMenuA

.next_dev:
    inc esi
    jmp .enum_loop

.enum_done:
    ; Attach Submenu to Main Menu
    mov rcx, rbx
    mov edx, MF_POPUP
    mov r8, r12
    lea r9, [szMenuDevices]
    call AppendMenuA

    ; Separator
    mov rcx, rbx
    call AppendSeparator

    ; Run on Startup checkbox item
    call IsStartupEnabled
    mov edx, MF_UNCHECKED
    test eax, eax
    jz .add_startup_item
    mov edx, MF_CHECKED
.add_startup_item:
    mov rcx, rbx
    mov r8d, ID_TRAY_STARTUP
    lea r9, [szMenuStartup]
    call AppendMenuA

    ; Separator
    mov rcx, rbx
    call AppendSeparator

    ; Exit item
    mov rcx, rbx
    mov edx, MF_STRING
    mov r8d, ID_TRAY_EXIT
    lea r9, [szMenuExit]
    call AppendMenuA

    mov rcx, [hWnd]
    call SetForegroundWindow

    ; Display popup
    mov rcx, rbx
    mov edx, 2                     ; TPM_RIGHTBUTTON
    mov r8d, dword [pt]
    mov r9d, dword [pt + 4]
    mov qword [rsp + 32], 0
    mov rax, [hWnd]
    mov [rsp + 40], rax
    mov qword [rsp + 48], 0
    call TrackPopupMenu

    mov rcx, rbx
    call DestroyMenu

    add rsp, 56
    pop rsi
    pop r13
    pop r12
    pop rbx
    ret

; Appends a menu separator. Caller sets rcx (hMenu); tail-jumps into
; AppendMenuA so its ret returns straight to our caller.
AppendSeparator:
    mov edx, MF_SEPARATOR
    xor r8d, r8d
    xor r9d, r9d
    jmp AppendMenuA

; -------------------------------------------------------------
; Startup Registry Helpers
; -------------------------------------------------------------
IsStartupEnabled:
    sub rsp, 56
    mov rcx, HKEY_CURRENT_USER
    lea rdx, [szRegKey]
    xor r8d, r8d
    mov r9d, KEY_READ
    lea rax, [rsp + 40]
    mov [rsp + 32], rax
    call RegOpenKeyExA
    test eax, eax
    jnz .not_enabled

    mov rcx, [rsp + 40]
    lea rdx, [szAppName]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call RegQueryValueExA
    mov r8d, eax

    mov rcx, [rsp + 40]
    call RegCloseKey

    test r8d, r8d
    jnz .not_enabled
    mov eax, 1
    add rsp, 56
    ret
.not_enabled:
    xor eax, eax
    add rsp, 56
    ret

SetStartup:
    push rbx
    sub rsp, 48
    mov ebx, ecx
    mov rcx, HKEY_CURRENT_USER
    lea rdx, [szRegKey]
    xor r8d, r8d
    mov r9d, KEY_SET_VALUE
    lea rax, [rsp + 40]
    mov [rsp + 32], rax
    call RegOpenKeyExA
    test eax, eax
    jnz .reg_done

    test ebx, ebx
    jz .do_delete

    xor ecx, ecx
    lea rdx, [pathBuf]
    mov r8d, 260
    call GetModuleFileNameA

    lea rcx, [pathBuf]
    call lstrlenA
    inc eax
    mov rbx, rax

    mov rcx, [rsp + 40]
    lea rdx, [szAppName]
    xor r8d, r8d
    mov r9d, REG_SZ
    lea rax, [pathBuf]
    mov [rsp + 32], rax
    mov [rsp + 40], rbx
    call RegSetValueExA
    jmp .close_reg

.do_delete:
    mov rcx, [rsp + 40]
    lea rdx, [szAppName]
    call RegDeleteValueA

.close_reg:
    mov rcx, [rsp + 40]
    call RegCloseKey
.reg_done:
    add rsp, 48
    pop rbx
    ret
