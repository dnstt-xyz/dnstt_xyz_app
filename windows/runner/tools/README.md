# Windows SSH Tools

Place `connect.exe` in this directory for SSH SOCKS5 proxy support.

## Quick Setup

Run the PowerShell script from the project root:
```powershell
.\scripts\get_connect_exe.ps1
```

This will automatically find or download `connect.exe` for you.

## Manual Setup

### Option 1: Download from Git for Windows
If you have Git for Windows installed, copy from:
```
C:\Program Files\Git\mingw64\bin\connect.exe
```

### Option 2: Build from source
1. Clone: https://github.com/gotoh/ssh-connect
2. Build with MinGW or Visual Studio
3. Place the resulting `connect.exe` here

### Option 3: Download pre-built
Download from the releases page of:
https://github.com/gotoh/ssh-connect/releases

## What is connect.exe?

`connect.exe` is a simple proxy connection tool that allows SSH to connect through a SOCKS5 proxy. It's used by the DNSTT app to route SSH connections through the DNSTT tunnel.
