#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── [จุดปรับปรุงที่ 2] ตรวจสอบสิทธิ์ Administrator ทันทีที่เริ่มสคริปต์ ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  [ERROR] This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "  Please launch it via Launcher.bat or run PowerShell as Administrator." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit..." | Out-Null
    Exit
}

$APP_NAME            = 'GAME COMPRESSOR'
$APP_VERSION         = '3.2'
$MIN_FREE_MB         = 1024
$PROGRESS_REFRESH_MS = 100
$SCAN_REPORT_EVERY   = 300
$BOX_W               = 60

$SKIP_EXT = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '.zip', '.rar', '.7z',  '.gz',  '.bz2', '.xz',  '.zst', '.br',  '.lz4', '.cab',
        '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.m4v',
        '.mp3', '.ogg', '.flac','.aac', '.wma', '.opus',
        '.jpg', '.jpeg','.png', '.gif', '.webp', '.avif', '.dds', '.tga',
        '.apk', '.jar', '.iso', '.img', '.pak'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

$PROTECTED_PATHS = @(
    $env:SystemRoot
    $env:windir
    $env:ProgramData
    "$($env:SystemDrive)\System Volume Information"
    "$($env:SystemDrive)\Recovery"
    "$($env:SystemDrive)\Boot"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.TrimEnd('\').ToLower() }

try {
    $regPath = 'HKCU:\Console'
    if (Test-Path $regPath) {
        $vtl = Get-ItemProperty $regPath -Name VirtualTerminalLevel -EA SilentlyContinue
        if ($null -eq $vtl -or $vtl.VirtualTerminalLevel -ne 1) {
            Set-ItemProperty $regPath -Name VirtualTerminalLevel -Value 1 -EA SilentlyContinue
        }
    }
    $consoleSrc = @'
using System; using System.Runtime.InteropServices;
public static class WinConsole {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    public static void EnableAnsi() {
        IntPtr h = GetStdHandle(-11); uint m;
        if (GetConsoleMode(h, out m)) SetConsoleMode(h, m | 4);
    }
}
'@
    if (-not ([System.Management.Automation.PSTypeName]'WinConsole').Type) {
        Add-Type -TypeDefinition $consoleSrc -Language CSharp -EA SilentlyContinue
    }
    [WinConsole]::EnableAnsi()
} catch {}

$E   = [char]27
$cR  = "$E[91m"; $cG  = "$E[92m"; $cY  = "$E[93m"; $cB  = "$E[94m"
$cC  = "$E[96m"; $cW  = "$E[97m"; $cDG = "$E[90m"; $cBL = "$E[1m"
$cX  = "$E[0m";  $ESC_ERASE = "$E[2K"

$wofSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public static class NativeWof {

    [StructLayout(LayoutKind.Sequential)]
    public struct WOF_FILE_COMPRESSION_INFO {
        public uint Version;
        public uint Provider;
        public uint FileInfoVersion;
        public uint Algorithm;
        public uint Flags;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFileW(
        string path, uint access, uint share,
        IntPtr sa, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr h, uint code,
        ref WOF_FILE_COMPRESSION_INFO inBuf, uint inSize,
        IntPtr outBuf, uint outSize, out uint returned, IntPtr ov);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    public static extern bool DeviceIoControlNull(
        IntPtr h, uint code,
        IntPtr inBuf, uint inSize,
        IntPtr outBuf, uint outSize, out uint returned, IntPtr ov);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetCompressedFileSizeW(string path, out uint high);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    // ── [จุดปรับปรุงที่ 1] นำเข้า Win32 API สำหรับจัดการ Attributes เพื่อรองรับ Long Path (\\?\) ──
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFileAttributesW(string lpFileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);

    private const uint WOF_ACCESS     = 0xC0000000u;
    private const uint SHARE_RW       = 0x00000003u;
    private const uint OPEN_EXISTING  = 3u;
    private const uint FLAG_BACKUP    = 0x02000000u;
    private const uint FSCTL_SET_COMP = 0x0009030Cc;
    private const uint FSCTL_DEL_COMP = 0x00090310c;
    private const uint INVALID_FSIZE  = 0xFFFFFFFFu;
    private const uint INVALID_FILE_ATTR = 0xFFFFFFFFu;
    private const uint FILE_ATTRIBUTE_READONLY = 0x00000001u;
    private static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

    private static int           _done;
    private static int           _failed;
    private static volatile bool _running;
    private static volatile bool _abort;

    public static int  Done    { get { return Interlocked.CompareExchange(ref _done,   0, 0); } }
    public static int  Failed  { get { return Interlocked.CompareExchange(ref _failed, 0, 0); } }
    public static bool Running { get { return _running; } }
    public static bool Abort   { get { return _abort; } set { _abort = value; } }

    public static long GetCompressedSize(string path) {
        uint high;
        uint low = GetCompressedFileSizeW(path, out high);
        if (low == INVALID_FSIZE && Marshal.GetLastWin32Error() != 0) return -1L;
        return ((long)high << 32) | (long)(uint)low;
    }

    public static int QueryWofState(string path, long logicalSize) {
        long onDisk = GetCompressedSize(path);
        if (onDisk < 0)           return -1;
        if (logicalSize <= 0)     return -1;
        if (onDisk > 0 && onDisk < logicalSize && (logicalSize - onDisk) >= 4096)
            return 1;
        return 0;
    }

    public static bool CompressFile(string path, uint algo) {
        bool isReadOnly = false;
        uint attrs = INVALID_FILE_ATTR;

        try {
            // ปรับไปใช้ GetFileAttributesW เพื่อไม่ให้พังเมื่อเจอพาธยาว \\?\
            attrs = GetFileAttributesW(path);
            if (attrs != INVALID_FILE_ATTR && (attrs & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY) {
                isReadOnly = true;
                SetFileAttributesW(path, attrs & ~FILE_ATTRIBUTE_READONLY);
            }
        } catch { }

        IntPtr h = CreateFileW(path, WOF_ACCESS, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FLAG_BACKUP, IntPtr.Zero);
        if (h == INVALID_HANDLE || h == IntPtr.Zero) {
            if (isReadOnly && attrs != INVALID_FILE_ATTR) { try { SetFileAttributesW(path, attrs); } catch { } }
            return false;
        }

        try {
            WOF_FILE_COMPRESSION_INFO info = new WOF_FILE_COMPRESSION_INFO();
            info.Version = 1; info.Provider = 2; info.FileInfoVersion = 1;
            info.Algorithm = algo; info.Flags = 0;
            uint dummy;
            uint sz = (uint)Marshal.SizeOf(typeof(WOF_FILE_COMPRESSION_INFO));
            return DeviceIoControl(h, FSCTL_SET_COMP, ref info, sz, IntPtr.Zero, 0, out dummy, IntPtr.Zero);
        } finally {
            CloseHandle(h);
            if (isReadOnly && attrs != INVALID_FILE_ATTR) { try { SetFileAttributesW(path, attrs); } catch { } }
        }
    }

    public static bool DecompressFile(string path) {
        bool isReadOnly = false;
        uint attrs = INVALID_FILE_ATTR;

        try {
            // ปรับไปใช้ GetFileAttributesW เพื่อรองรับ Long Path เช่นกัน
            attrs = GetFileAttributesW(path);
            if (attrs != INVALID_FILE_ATTR && (attrs & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY) {
                isReadOnly = true;
                SetFileAttributesW(path, attrs & ~FILE_ATTRIBUTE_READONLY);
            }
        } catch { }

        IntPtr h = CreateFileW(path, WOF_ACCESS, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FLAG_BACKUP, IntPtr.Zero);
        if (h == INVALID_HANDLE || h == IntPtr.Zero) {
            if (isReadOnly && attrs != INVALID_FILE_ATTR) { try { SetFileAttributesW(path, attrs); } catch { } }
            return false;
        }
        try {
            uint dummy;
            return DeviceIoControlNull(h, FSCTL_DEL_COMP, IntPtr.Zero, 0, IntPtr.Zero, 0, out dummy, IntPtr.Zero);
        } finally {
            CloseHandle(h);
            if (isReadOnly && attrs != INVALID_FILE_ATTR) { try { SetFileAttributesW(path, attrs); } catch { } }
        }
    }

    private static void RunBatch(string[] paths, uint algo, int threads, bool decompress) {
        _done   = 0;
        _failed = 0;
        _abort  = false;
        Thread.MemoryBarrier();
        _running = true;
        try {
            ParallelOptions opts = new ParallelOptions();
            opts.MaxDegreeOfParallelism = threads;
            Parallel.ForEach(paths, opts, delegate(string p, ParallelLoopState state) {
                if (_abort) { state.Stop(); return; }
                bool ok = false;
                try {
                    if (decompress) ok = DecompressFile(p);
                    else            ok = CompressFile(p, algo);
                } catch {
                    ok = false;
                }
                if (ok) Interlocked.Increment(ref _done);
                else    Interlocked.Increment(ref _failed);
            });
        } finally {
            Thread.MemoryBarrier();
            _running = false;
        }
    }

    public static void StartAsync(string[] paths, uint algo, int threads, bool decompress) {
        Task.Factory.StartNew(delegate() {
            RunBatch(paths, algo, threads, decompress);
        });
    }
}
'@

$script:WofLoaded = $false
$script:WofError  = $null
try {
    if (-not ([System.Management.Automation.PSTypeName]'NativeWof').Type) {
        Add-Type -TypeDefinition $wofSrc -Language CSharp -EA Stop
    }
    $script:WofLoaded = $true
} catch {
    $script:WofError = $_.Exception.Message
}

if (-not $script:WofLoaded) {
    Write-Host ""
    Write-Host "  [CRITICAL ERROR] Failed to load WOF Engine!" -ForegroundColor Red
    Write-Host "  This tool requires Windows 10 / 11 or Windows Server 2016+" -ForegroundColor Yellow
    if ($null -ne $script:WofError) {
        Write-Host "  Compiler details:"
        $script:WofError -split "`n" | ForEach-Object { Write-Host "    $_" }
    }
    Write-Host ''
    Read-Host '  Press Enter to exit' | Out-Null
    exit 2
}

function Write-C {
    param([string]$Color, [string]$Text, [switch]$NoNewLine)
    if ($NoNewLine) { Write-Host "${Color}${Text}${cX}" -NoNewline }
    else            { Write-Host "${Color}${Text}${cX}" }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 0)   { return 'N/A' }
    if ($Bytes -ge 1GB) { return "$([Math]::Round($Bytes / 1GB, 2)) GB" }
    if ($Bytes -ge 1MB) { return "$([Math]::Round($Bytes / 1MB, 1)) MB" }
    if ($Bytes -ge 1KB) { return "$([Math]::Round($Bytes / 1KB, 0)) KB" }
    return "${Bytes} B"
}

function Format-Duration {
    param([double]$Seconds)
    $s = [int][Math]::Max(0, [Math]::Round($Seconds))
    if ($s -lt 60)   { return "${s}s" }
    if ($s -lt 3600) { return "$([Math]::Floor($s/60))m $($s % 60)s" }
    return "$([Math]::Floor($s/3600))h $([Math]::Floor(($s % 3600)/60))m"
}

function Get-VisibleLength {
    param([string]$Text)
    return ([System.Text.RegularExpressions.Regex]::Replace(
        $Text, '\x1B\[[0-9;]*[mABCDHJKSTfu]', '')).Length
}

function Draw-Box {
    param([string]$Title, [string[]]$Lines)
    $border   = '+' + ('-' * $BOX_W) + '+'
    $titlePad = [Math]::Max(0, $BOX_W - 1 - (Get-VisibleLength $Title))
    Write-Host "  ${cDG}${border}${cX}"
    Write-Host "  ${cDG}|${cX} ${cC}${cBL}${Title}${cX}$(' ' * $titlePad)${cDG}|${cX}"
    Write-Host "  ${cDG}${border}${cX}"
    foreach ($line in $Lines) {
        if ([string]::IsNullOrEmpty($line)) {
            Write-Host "  ${cDG}|${cX}$(' ' * $BOX_W)${cDG}|${cX}"
        } else {
            $pad = [Math]::Max(0, $BOX_W - 1 - (Get-VisibleLength $line))
            Write-Host "  ${cDG}|${cX} ${line}$(' ' * $pad)${cDG}|${cX}"
        }
    }
    Write-Host "  ${cDG}${border}${cX}"
}

function Draw-Bar {
    param(
        [long]  $Done,
        [long]  $Total,
        [long]  $Failed     = 0,
        [double]$EtaSec     = -1,
        [long]  $SavedBytes = 0,
        [long]  $ElapsedSec = -1
    )
    if ($Total -le 0) { return }

    $pct    = [Math]::Min(100.0, [Math]::Round($Done * 100.0 / $Total, 1))
    $filled = [int][Math]::Floor($pct / 2)
    $bar    = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * (50 - $filled))

    $eta      = if ($EtaSec -ge 0)     { "ETA:$(Format-Duration $EtaSec)" }                               else { 'ETA:--' }
    $time     = if ($ElapsedSec -ge 0) { "  ${cDG}|${cX} ${cY}$(Format-Duration $ElapsedSec)${cX}" }     else { '' }
    $saved    = if ($SavedBytes -gt 512KB){ "  ${cDG}|${cX} ${cG}+$(Format-Size $SavedBytes)${cX}" }      else { '' }
    $failTxt  = if ($Failed -gt 0)     { "  ${cDG}|${cX} ${cR}!$("{0:N0}" -f $Failed)${cX}" }            else { '' }
    $files    = "  ${cDG}|${cX} ${cDG}$("{0:N0}" -f $Done)/$("{0:N0}" -f $Total)${cX}"

    Write-Host "${ESC_ERASE}`r  ${cG}${bar}${cX} ${cBL}${cW}$($pct.ToString('F1'))%${cX}${files}${time}  ${cDG}|${cX} ${cC}${eta}${cX}${saved}${failTxt}" -NoNewline
}

function Wait-Enter {
    Write-Host ''
    Write-C $cDG '  Press Enter to return to menu...' -NoNewLine
    Read-Host | Out-Null
}

function Get-DriveProfile {
    param([string]$FolderPath)

    $letter   = ([System.IO.Path]::GetPathRoot($FolderPath)).TrimEnd('\')
    $diskType = 'Unknown'

    try {
        $logDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter'" -EA Stop
        $parts   = @(Get-CimAssociatedInstance -InputObject $logDisk `
                       -ResultClassName Win32_DiskPartition -EA Stop)
        if ($parts.Count -gt 0) {
            $drive = Get-CimAssociatedInstance -InputObject $parts[0] `
                       -ResultClassName Win32_DiskDrive -EA Stop
            $pd    = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' `
                       -ClassName MSFT_PhysicalDisk `
                       -Filter "DeviceID='$($drive.Index)'" -EA SilentlyContinue

            $diskType = if ($pd) {
                switch ($pd.MediaType) {
                    4       { 'SSD' }
                    3       { 'HDD' }
                    default { if ($pd.FriendlyName -match 'SSD|NVMe|Solid|Flash') { 'SSD' } else { 'HDD' } }
                }
            } else {
                if ($drive.Model -match 'SSD|NVMe|Solid|Flash') { 'SSD' } else { 'HDD' }
            }
        }
    } catch {}

    $cpu     = [Math]::Max([Environment]::ProcessorCount, 1)
    $threads = switch ($diskType) {
        'SSD'   { [Math]::Min($cpu, 12) }
        'HDD'   { 1 }
        default { [Math]::Min([int]($cpu / 2), 4) }
    }

    $freeGB = 0.0; $totalGB = 0.0
    try {
        $di      = [System.IO.DriveInfo]::new($letter + '\')
        $freeGB  = [Math]::Round($di.AvailableFreeSpace / 1GB, 1)
        $totalGB = [Math]::Round($di.TotalSize / 1GB, 1)
    } catch {}

    return @{
        Type        = $diskType
        MaxThreads  = $threads
        FreeGB      = $freeGB
        TotalGB     = $totalGB
        DriveLetter = $letter
    }
}

function Test-IsNtfs {
    param([string]$FolderPath)
    try   { return ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($FolderPath))).DriveFormat -eq 'NTFS' }
    catch { return $true }
}

function Get-FreeBytes {
    param([string]$DriveLetter)
    try   { return ([System.IO.DriveInfo]::new($DriveLetter + '\')).AvailableFreeSpace }
    catch { return [long]::MaxValue }
}

function Test-HasEnoughSpace {
    param([string]$DriveLetter)
    return (Get-FreeBytes $DriveLetter) -gt ($MIN_FREE_MB * 1MB)
}

function Read-GameFolder {
    param([string]$Prompt = 'Enter game folder path')

    while ($true) {
        Write-Host ''
        Write-C $cC  "  $Prompt"
        Write-C $cDG '  (Paste path and press Enter — surrounding quotes are stripped automatically)'
        Write-Host ''
        Write-C $cW  '  > ' -NoNewLine

        $path = (Read-Host).Trim() -replace '^["\x27]|["\x27]$' | ForEach-Object { $_.Trim() }

        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-C $cR '  [ERROR] Path cannot be empty.'; continue
        }
        if ($path -match '[;&|`<>*?]') {
            Write-C $cR '  [SECURITY] Illegal characters detected in path.'; continue
        }

        try   { $path = [System.IO.Path]::GetFullPath($path) }
        catch { Write-C $cR "  [ERROR] Invalid path: $($_.Exception.Message)"; continue }

        if ($path -match '\.\.') {
            Write-C $cR '  [SECURITY] Path traversal (..) not permitted.'; continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Write-C $cR "  [ERROR] Folder not found: $path"
            Write-C $cY '  [HINT]  Check spelling or verify the drive is connected.'; continue
        }

        $pathLower = $path.TrimEnd('\').ToLower()
        $blocked   = $false
        foreach ($sp in $PROTECTED_PATHS) {
            if ($pathLower -eq $sp -or $pathLower.StartsWith($sp + '\')) {
                Write-C $cR '  [SECURITY] Path is inside a protected system folder.'
                $blocked = $true; break
            }
        }
        if ($blocked) { continue }

        if ($path.TrimEnd('\') -eq ([System.IO.Path]::GetPathRoot($path)).TrimEnd('\')) {
            Write-C $cR '  [SECURITY] Drive root is not allowed.'; continue
        }
        if (-not (Test-IsNtfs $path)) {
            Write-C $cR '  [ERROR] Drive must be NTFS for WOF compression.'; continue
        }

        Write-Host ''
        Write-C $cG "  [OK] Path accepted: $path"
        return $path
    }
}

function Test-IsWofCompressed {
    param([System.IO.FileInfo]$File)
    $attrCheck = ($File.Attributes -band [System.IO.FileAttributes]::Compressed) -ne 0
    if (-not $script:WofLoaded) { return $attrCheck }
    try {
        $state = [NativeWof]::QueryWofState($File.FullName, $File.Length)
        if ($state -eq  1) { return $true }
        if ($state -eq  0) { return $false }
        return $attrCheck
    } catch { return $attrCheck }
}

function Invoke-Prescan {
    param([string]$FolderPath)

    Write-Host ''
    Write-C $cC '  Scanning folder...'

    $totalFiles  = 0L; $totalBytes   = 0L
    $skipFiles   = 0L; $alreadyComp  = 0L
    $toCompFiles = 0L; $toCompBytes  = 0L

    $toCompList = [System.Collections.Generic.List[string]]::new(8192)
    $compList   = [System.Collections.Generic.List[string]]::new(4096)

    $enumPath = if ($FolderPath.StartsWith('\\?\')) { $FolderPath } else { "\\?\$FolderPath" }
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $enumerator = [System.IO.Directory]::EnumerateFiles(
            $enumPath, '*', [System.IO.SearchOption]::AllDirectories)
    } catch {
        try {
            $enumerator = [System.IO.Directory]::EnumerateFiles(
                $FolderPath, '*', [System.IO.SearchOption]::AllDirectories)
        } catch {
            Write-Host ''
            Write-C $cR "  [ERROR] Cannot read folder: $($_.Exception.Message)"
            return $null
        }
    }

    foreach ($fp in $enumerator) {
        $totalFiles++

        if ($totalFiles % $SCAN_REPORT_EVERY -eq 0) {
            $rate    = if ($sw.Elapsed.TotalSeconds -gt 0.5) { [int]($totalFiles / $sw.Elapsed.TotalSeconds) } else { 0 }
            $elapsed = Format-Duration $sw.Elapsed.TotalSeconds
            Write-Host "${ESC_ERASE}`r  ${cDG}Scanning:${cX} ${cW}$("{0:N0}" -f $totalFiles)${cX} files  ${cDG}|${cX} ${cC}${rate}/s${cX}  ${cDG}|${cX} ${cY}${elapsed}${cX}   " -NoNewline
        }

        $fi = $null
        try { $fi = [System.IO.FileInfo]::new($fp) } catch { continue }
        $totalBytes += $fi.Length

        if (Test-IsWofCompressed $fi) {
            $alreadyComp++
            $compList.Add($fp)
        } elseif ($SKIP_EXT.Contains([System.IO.Path]::GetExtension($fp))) {
            $skipFiles++
        } else {
            $toCompFiles++
            $toCompBytes += $fi.Length
            $toCompList.Add($fp)
        }
    }

    $sw.Stop()
    Write-Host "${ESC_ERASE}`r" -NoNewline

    $compPct = if ($totalFiles -gt 0) { [Math]::Round($alreadyComp * 100.0 / $totalFiles, 1) } else { 0 }

    Draw-Box 'PRE-SCAN RESULTS' @(
        "${cW}Total files  :${cX} $("{0:N0}" -f $totalFiles)  ($(Format-Size $totalBytes))"
        "${cW}Skip (packed):${cX} $("{0:N0}" -f $skipFiles)  (.zip / .mp4 / .jpg ...)"
        "${cW}Compressed   :${cX} $("{0:N0}" -f $alreadyComp)  ($($compPct)% — WOF/NTFS)"
        ''
        "${cW}To compress  :${cX} $("{0:N0}" -f $toCompFiles)  ($(Format-Size $toCompBytes))"
    )

    return @{
        TotalFiles  = $totalFiles
        TotalBytes  = $totalBytes
        SkipFiles   = $skipFiles
        AlreadyComp = $alreadyComp
        CompPct     = $compPct
        ToCompFiles = $toCompFiles
        ToCompBytes = $toCompBytes
        ToCompList  = $toCompList.ToArray()
        CompList    = $compList.ToArray()
    }
}

function Invoke-Batch {
    param(
        [string[]] $FileList,
        [string]   $Algorithm,
        [int]      $MaxThreads,
        [long]     $TotalCount,
        [string]   $DriveLetter,
        [switch]   $Decompress
    )

    if ($FileList.Length -eq 0) {
        return @{ Done = 0; Failed = 0; ElapsedSec = 0.0; Aborted = $false; SavedBytes = 0L }
    }
    if (-not $script:WofLoaded) {
        Write-C $cR '  [ERROR] WOF engine not loaded — cannot process files.'
        return @{ Done = 0; Failed = 0; ElapsedSec = 0.0; Aborted = $true; SavedBytes = 0L }
    }

    # ── [จุดปรับปรุงที่ 3] ระบุค่า Switch Case ของ Algorithm ให้ชัดเจนตรงไปตรงมาตามหลักสากล ──
    $algoId = switch ($Algorithm) {
        'Xpress4K'  { [uint32]0 }
        'Xpress8K'  { [uint32]1 }
        'Xpress16K' { [uint32]2 }
        'LZX'       { [uint32]3 }
        default     { [uint32]1 } # Fallback เป็น Xpress8K หากค่าหลุดมา
    }

    $modeLabel = if ($Decompress) { "${cR}DECOMPRESS${cX}" } else { "${cG}COMPRESS${cX} [${cY}${Algorithm}${cX}]" }
    Write-Host ''
    Write-Host "  ${cDG}Files:${cX} ${cW}$($FileList.Length)${cX}  ${cDG}|${cX}  Threads: ${cW}${MaxThreads}${cX}  ${cDG}|${cX}  Mode: ${modeLabel}"
    Write-Host ''

    $baseline = Get-FreeBytes $DriveLetter
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $aborted  = $false

    $WIN_SIZE = 8
    $winDone  = [System.Collections.Generic.Queue[long]]::new()
    $winTime  = [System.Collections.Generic.Queue[double]]::new()
    $prevDone = 0L; $prevTime = 0.0

    [NativeWof]::StartAsync($FileList, $algoId, $MaxThreads, $Decompress.IsPresent)

    try {
        while ([NativeWof]::Running) {

            if (-not (Test-HasEnoughSpace $DriveLetter)) {
                [NativeWof]::Abort = $true
                Write-Host ''
                Write-C $cR "  [ABORT] Free space below ${MIN_FREE_MB} MB — stopping to protect data."
                $aborted = $true
                break
            }

            $done    = [NativeWof]::Done
            $failed  = [NativeWof]::Failed
            $elapsed = $sw.Elapsed.TotalSeconds
            $saved   = [Math]::Max(0L, (Get-FreeBytes $DriveLetter) - $baseline)

            $processed = $done + $failed

            $etaSec = -1.0
            if ($processed -gt $prevDone) {
                $winDone.Enqueue($processed - $prevDone)
                $winTime.Enqueue($elapsed - $prevTime)
                if ($winDone.Count -gt $WIN_SIZE) { $winDone.Dequeue() | Out-Null; $winTime.Dequeue() | Out-Null }
                $prevDone = $processed; $prevTime = $elapsed

                $sumD = 0L;  foreach ($v in $winDone) { $sumD += $v }
                $sumT = 0.0; foreach ($v in $winTime) { $sumT += $v }
                if ($sumD -gt 0 -and $sumT -gt 0) {
                    $rate   = $sumD / $sumT
                    $remain = $TotalCount - $processed
                    if ($rate -gt 0 -and $remain -ge 0) { $etaSec = $remain / $rate }
                }
            }

            Draw-Bar -Done $processed -Total $TotalCount -Failed $failed `
                     -EtaSec $etaSec -SavedBytes $saved -ElapsedSec ([long]$elapsed)

            [System.Threading.Thread]::Sleep($PROGRESS_REFRESH_MS)
        }
    } finally {
        if ($aborted) {
            [NativeWof]::Abort = $true
            $limit = [System.Diagnostics.Stopwatch]::StartNew()
            while ([NativeWof]::Running -and $limit.Elapsed.TotalSeconds -lt 10) {
                [System.Threading.Thread]::Sleep(50)
            }
        }
    }

    $sw.Stop()
    $finalDone   = [NativeWof]::Done
    $finalFailed = [NativeWof]::Failed
    $finalSaved  = [Math]::Max(0L, (Get-FreeBytes $DriveLetter) - $baseline)

    Draw-Bar -Done ($finalDone + $finalFailed) -Total $TotalCount -Failed $finalFailed `
             -EtaSec 0 -SavedBytes $finalSaved -ElapsedSec ([long]$sw.Elapsed.TotalSeconds)
    Write-Host ''

    return @{
        Done       = $finalDone
        Failed     = $finalFailed
        ElapsedSec = $sw.Elapsed.TotalSeconds
        Aborted    = $aborted
        SavedBytes = $finalSaved
    }
}

function Start-Compress {
    param([string]$FolderPath, [hashtable]$DrvInfo)

    Write-Host ''
    Draw-Box 'SELECT COMPRESSION ALGORITHM' @(
        "${cW}[1]${cX}  ${cG}Xpress4K ${cX} — Fastest, least compression  ${cDG}(best for HDD)${cX}"
        "${cW}[2]${cX}  ${cC}Xpress8K ${cX} — Balanced speed / ratio       ${cDG}(recommended)${cX}"
        "${cW}[3]${cX}  ${cC}Xpress16K${cX} — Better ratio, slightly slower"
        "${cW}[4]${cX}  ${cY}LZX      ${cX} — Maximum compression, slowest ${cDG}(best for SSD)${cX}"
    )
    Write-Host ''
    Write-C $cW '  Select [1-4]: ' -NoNewLine
    $algo = switch ((Read-Host).Trim()) {
        '1' { 'Xpress4K'  }
        '2' { 'Xpress8K'  }
        '3' { 'Xpress16K' }
        '4' { 'LZX'       }
        default { Write-C $cY '  [INFO] Invalid — defaulting to Xpress8K'; 'Xpress8K' }
    }
    Write-C $cG "  Algorithm : ${cBL}${algo}${cX}"

    $scan = Invoke-Prescan -FolderPath $FolderPath
    if ($null -eq $scan) { return }

    if ($scan.ToCompFiles -eq 0) {
        Write-Host ''
        if ($scan.AlreadyComp -gt 0) {
            Write-C $cG '  [OK] All compressible files are already compressed.'
            Write-C $cDG "       Run ${cW}Scan Only${cX}${cDG} to verify space savings."
        } else {
            Write-C $cG '  [OK] No compressible files found. Nothing to do.'
        }
        return
    }

    $needed  = [long]($scan.ToCompBytes * 0.10) + ($MIN_FREE_MB * 1MB)
    $freeNow = Get-FreeBytes $DrvInfo.DriveLetter
    if ($freeNow -gt 0 -and $freeNow -lt $needed) {
        Write-Host ''
        Write-C $cR '  [ERROR] Not enough free space for safe compression.'
        Write-C $cY "  Free: $(Format-Size $freeNow)   Minimum: $(Format-Size $needed)"
        return
    }

    Write-Host ''
    Write-C $cY '  Press Enter to start  or  Ctrl+C to cancel...' -NoNewLine
    Read-Host | Out-Null

    $before = Get-FreeBytes $DrvInfo.DriveLetter
    $result = Invoke-Batch -FileList $scan.ToCompList -Algorithm $algo `
                  -MaxThreads $DrvInfo.MaxThreads -TotalCount $scan.ToCompFiles `
                  -DriveLetter $DrvInfo.DriveLetter

    Start-Sleep -Milliseconds 1500

    $saved     = [Math]::Max(0L, (Get-FreeBytes $DrvInfo.DriveLetter) - $before)
    $savedPct  = if ($scan.TotalBytes -gt 0 -and $saved -gt 0) { [Math]::Round($saved * 100.0 / $scan.TotalBytes, 1) } else { 0 }
    $speedMBps = if ($result.ElapsedSec -gt 0) { [Math]::Round(($scan.ToCompBytes / 1MB) / $result.ElapsedSec, 1) } else { 0 }
    $savedLine = if ($saved -gt 512KB) { "Space saved  : ${cG}$(Format-Size $saved)${cX} ($($savedPct)%)" } `
                                  else { "Space saved  : ${cDG}N/A — run Scan Only to verify${cX}" }

    $failLine = if ($result.Failed -gt 0) {
        "Skipped      : ${cR}$("{0:N0}" -f $result.Failed) files${cX} (read-only / locked / error)"
    } else {
        "Skipped      : ${cG}none${cX}"
    }

    Write-Host ''
    $summary = @(
        "Algorithm    : ${cY}${algo}${cX}"
        "OK           : ${cW}$("{0:N0}" -f $result.Done)${cX}  ($(Format-Size $scan.ToCompBytes))"
        $failLine
        ''
        $savedLine
        "Time         : $(Format-Duration $result.ElapsedSec)"
        "Throughput   : ${cC}${speedMBps} MB/s${cX}"
    )
    if ($result.Aborted) { $summary += ''; $summary += "${cR}*** ABORTED — low disk space ***${cX}" }
    Draw-Box 'COMPRESSION COMPLETE' $summary
}

function Start-Decompress {
    param([string]$FolderPath, [hashtable]$DrvInfo)

    Write-Host ''
    Write-C $cY '  [WARNING] About to decompress all WOF-backed files in:'
    Write-C $cW "            $FolderPath"
    Write-Host ''

    $scan = Invoke-Prescan -FolderPath $FolderPath
    if ($null -eq $scan) { return }

    if ($scan.TotalFiles -eq 0) {
        Write-C $cG '  [OK] Folder is empty — nothing to do.'; return
    }
    if ($scan.AlreadyComp -eq 0) {
        Write-C $cY '  [INFO] No compressed files found — nothing to decompress.'
        Wait-Enter; return
    }

    Write-C $cG "  Compressed : ${cW}$("{0:N0}" -f $scan.AlreadyComp)${cX} / $("{0:N0}" -f $scan.TotalFiles) files  ($($scan.CompPct)%)"
    Write-Host ''

    $estNeeded = [Math]::Max([long]($scan.TotalBytes * 0.60), 1GB)
    $freeNow   = Get-FreeBytes $DrvInfo.DriveLetter
    Write-C $cY "  Estimated space needed : $(Format-Size $estNeeded)"
    Write-C $cY "  Current free space     : $(Format-Size $freeNow)"
    Write-Host ''

    if ($freeNow -gt 0 -and $freeNow -lt $estNeeded) {
        Write-C $cR "  [WARNING] Possible shortfall: $(Format-Size ([Math]::Max(0L, $estNeeded - $freeNow)))"
        Write-Host ''
    }

    Write-C $cY '  Confirm decompression? [Y/N]: ' -NoNewLine
    if ((Read-Host) -notmatch '^[Yy]') { Write-C $cDG '  Cancelled.'; return }

    $before = Get-FreeBytes $DrvInfo.DriveLetter
    $result = Invoke-Batch -FileList $scan.CompList -Algorithm '' `
                  -MaxThreads $DrvInfo.MaxThreads -TotalCount $scan.AlreadyComp `
                  -DriveLetter $DrvInfo.DriveLetter -Decompress

    Start-Sleep -Milliseconds 1500

    $delta     = $before - (Get-FreeBytes $DrvInfo.DriveLetter)
    $spaceLine = if ($delta -gt 512KB)      { "Space consumed : ${cY}$(Format-Size $delta)${cX}  (files expanded)" } `
                 elseif ($delta -lt -512KB) { "Space freed    : ${cG}$(Format-Size ([Math]::Abs($delta)))${cX}  (verify results)" } `
                 else                       { "Space change   : ${cDG}~0 KB — run Scan Only to verify${cX}" }

    $failLine = if ($result.Failed -gt 0) {
        "Skipped      : ${cR}$("{0:N0}" -f $result.Failed) files${cX} (read-only / locked / error)"
    } else {
        "Skipped      : ${cG}none${cX}"
    }

    Write-Host ''
    $summary = @(
        "Total files  : $("{0:N0}" -f $scan.TotalFiles)"
        "OK           : ${cW}$("{0:N0}" -f $result.Done)${cX} files"
        $failLine
        ''
        $spaceLine
        "Time         : $(Format-Duration $result.ElapsedSec)"
    )
    if ($result.Aborted) { $summary += ''; $summary += "${cR}*** ABORTED — low disk space ***${cX}" }
    Draw-Box 'DECOMPRESSION COMPLETE' $summary
}

function Show-Banner {
    param([hashtable]$DrvInfo = $null)
    Clear-Host
    Write-Host ''

    $title = "$APP_NAME  v$APP_VERSION"
    $padL  = [Math]::Max(0, [Math]::Floor(($BOX_W - $title.Length) / 2))
    $padR  = [Math]::Max(0, $BOX_W - $title.Length - $padL)
    Write-Host "  ${cC}+$('-' * $BOX_W)+${cX}"
    Write-Host "  ${cC}|${cW}${cBL}$(' ' * $padL)${title}$(' ' * $padR)${cX}${cC}|${cX}"
    Write-Host "  ${cC}+$('-' * $BOX_W)+${cX}"
    Write-Host ''

    if ($null -ne $DrvInfo) {
        $dClr  = switch ($DrvInfo.Type) { 'SSD' { $cG } 'HDD' { $cY } default { $cDG } }
        $dIcon = switch ($DrvInfo.Type) { 'SSD' { '[SSD]' } 'HDD' { '[HDD]' } default { '[???]' } }
        $fClr  = if ($DrvInfo.FreeGB -lt 5) { $cR } elseif ($DrvInfo.FreeGB -lt 20) { $cY } else { $cG }
        $tClr  = if ($DrvInfo.MaxThreads -ge 8) { $cG } elseif ($DrvInfo.MaxThreads -ge 4) { $cC } else { $cY }
        $total = if ($DrvInfo.TotalGB -gt 0) { " / $($DrvInfo.TotalGB) GB" } else { '' }

        Write-Host ("  ${cDG}Drive:${cX} ${cW}$($DrvInfo.DriveLetter):\${cX}  " +
                    "Type: ${dClr}${dIcon}${cX}  " +
                    "Free: ${fClr}$($DrvInfo.FreeGB) GB${cX}${cDG}${total}${cX}  " +
                    "Threads: ${tClr}$($DrvInfo.MaxThreads)${cX}")
        Write-Host ''
    }
}

function Show-Menu {
    Write-Host "  ${cC}[ MENU ]${cX}"
    Write-Host "  ${cDG}$('-' * $BOX_W)${cX}"
    Write-Host "  ${cG} 1.${cX}  ${cBL}${cW}Compress${cX}    — Compress a game folder"
    Write-Host "  ${cY} 2.${cX}  ${cBL}${cW}Decompress${cX}  — Remove WOF compression"
    Write-Host "  ${cB} 3.${cX}  ${cBL}${cW}Scan Only${cX}   — Preview, no changes made"
    Write-Host "  ${cDG}$('-' * $BOX_W)${cX}"
    Write-Host "  ${cR} 0.${cX}  Exit"
    Write-Host "  ${cDG}$('-' * $BOX_W)${cX}"
    Write-Host ''
    Write-C $cW '  Enter option [0-3]: ' -NoNewLine
}

# ── [จุดปรับปรุงที่ 4] เติมเต็มโค้ดโครงสร้างลูปหลัก (Main Loop) ส่วนท้ายสุดที่ขาดหายไปให้สมบูรณ์ครบถ้วน ──

$activeDrvInfo = $null

while ($true) {
    Show-Banner -DrvInfo $activeDrvInfo
    Show-Menu

    $choice = (Read-Host).Trim()

    if ($choice -eq '0') {
        Write-Host ''
        Write-C $cG '  Thank you for using GAME COMPRESSOR! Exiting...'
        Start-Sleep -Seconds 1
        break
    }

    if ($choice -in '1','2','3') {
        $labels = @{ '1' = 'COMPRESS'; '2' = 'DECOMPRESS'; '3' = 'SCAN' }
        $folder = Read-GameFolder -Prompt "Enter the game folder path to $($labels[$choice])"
        $di     = Get-DriveProfile -FolderPath $folder
        $activeDrvInfo = $di
        Show-Banner -DrvInfo $di
        Write-C $cC "  Folder : ${cW}${folder}${cX}"
        Write-C $cC "  Drive  : ${cW}$($di.Type)${cX}  ($($di.MaxThreads) thread$(if ($di.MaxThreads -ne 1) {'s'}))"
    }

    switch ($choice) {
        '1' { Start-Compress   -FolderPath $folder -DrvInfo $di; Wait-Enter }
        '2' { Start-Decompress -FolderPath $folder -DrvInfo $di; Wait-Enter }
        '3' {
                Write-Host ''
                $scan = Invoke-Prescan -FolderPath $folder
                Wait-Enter
            }
        default {
            Write-Host ''
            Write-C $cR '  [WARNING] Invalid selection. Please enter 0, 1, 2, or 3.'
            Start-Sleep -Seconds 15
        }
    }
}
