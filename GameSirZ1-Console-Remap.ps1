# GameSir Z1: interactive, hardware-persistent key rebinding for Windows PowerShell 5.1.
# Uses Windows Raw Input to distinguish Z1 from a second keyboard.
# Waits for release and flushes the console buffer to prevent input leaking into prompts.
# Requires no Python, device-driver installation, or background remapper.
# Source key must have an ordinary, unique (or disambiguated) HID assignment.
# Unknown/vendor-defined records are never modified. Writes full 384-byte image.
# Before write: two identical live reads + saved backup. After write: two readbacks.
# No automatic write retries or rollbacks.
param(
    [switch]$PreviewOnly,
    [string]$BackupDirectory = ''
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows 10/11.' }
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GameSirZ1-Backups'
}

if(-not ('Z1RemapTransportV4' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Z1RemapTransportV4 {
    const uint GENERIC_READ_WRITE=0xC0000000u, SHARE_READ_WRITE=3u;
    const uint OPEN_EXISTING=3u, FILE_FLAG_OVERLAPPED=0x40000000u;
    const int ERROR_IO_PENDING=997, ERROR_IO_INCOMPLETE=996;
    const uint WAIT_OBJECT_0=0u, WAIT_TIMEOUT=258u;

    [StructLayout(LayoutKind.Sequential)]
    struct NativeOverlapped {
        public IntPtr Internal;
        public IntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr hEvent;
    }
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateEvent(IntPtr attrs, bool manualReset, bool initialState, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool ReadFile(IntPtr h, IntPtr buffer, uint length, IntPtr transferred, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool WriteFile(IntPtr h, IntPtr buffer, uint length, IntPtr transferred, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetOverlappedResult(IntPtr h, IntPtr ov, out uint transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool CancelIoEx(IntPtr h, IntPtr ov);

    static uint Finish(IntPtr h, IntPtr ev, IntPtr ov, bool immediately, uint timeout, string label) {
        if (!immediately) {
            uint status=WaitForSingleObject(ev,timeout);
            if (status==WAIT_TIMEOUT) throw new TimeoutException(label+" timed out after "+timeout+" ms");
            if (status!=WAIT_OBJECT_0) throw new Exception(label+" wait failed: "+status);
        }
        uint count;
        if (!GetOverlappedResult(h,ov,out count,false))
            throw new Exception(label+" completion failed: Win32 "+Marshal.GetLastWin32Error());
        return count;
    }
    static void CancelPending(IntPtr h, IntPtr ov, IntPtr ev) {
        if (ov==IntPtr.Zero) return;
        uint count;
        if (GetOverlappedResult(h,ov,out count,false)) return;
        int err=Marshal.GetLastWin32Error();
        if (err==ERROR_IO_PENDING || err==ERROR_IO_INCOMPLETE) {
            CancelIoEx(h,ov);
            if (ev!=IntPtr.Zero) WaitForSingleObject(ev,5000u);
        }
    }
    public static byte[] ReadBlock(string path, int offset, int length, byte command) {
        // Hard safety boundaries: fixed known VID/PID, collection and read opcode.
        if (path==null || !path.ToLowerInvariant().StartsWith(@"\\?\hid#vid_0c45&pid_7521&mi_01&col04#"))
            throw new ArgumentException("Unexpected device path; no transfer sent");
        if (offset<0 || offset>336 || offset%56!=0 ||
            length!=Math.Min(56,384-offset))
            throw new ArgumentOutOfRangeException("offset","Only seven verified 56/48-byte blocks are permitted");
        if(command!=0x07 && command!=0x08) throw new ArgumentException("Only keymap read opcodes 0x07/0x08 are supported");
        byte[] req=new byte[64];
        req[0]=0x04; req[3]=command; req[4]=(byte)length;
        req[5]=(byte)(offset&255); req[6]=(byte)((offset>>8)&255);
        int check=0;
        for(int i=3;i<64;i++) check=(check+req[i])&65535;
        req[1]=(byte)(check&255); req[2]=(byte)(check>>8);

        IntPtr h=CreateFileW(path,GENERIC_READ_WRITE,SHARE_READ_WRITE,IntPtr.Zero,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,IntPtr.Zero);
        if(h==new IntPtr(-1)) throw new Exception("Cannot open Z1 HID interface: Win32 "+Marshal.GetLastWin32Error());
        IntPtr readEv=IntPtr.Zero,writeEv=IntPtr.Zero,readOv=IntPtr.Zero,writeOv=IntPtr.Zero;
        IntPtr readBuf=IntPtr.Zero,writeBuf=IntPtr.Zero;
        bool readPending=false,writePending=false;
        try {
            readEv=CreateEvent(IntPtr.Zero,true,false,null);
            writeEv=CreateEvent(IntPtr.Zero,true,false,null);
            if(readEv==IntPtr.Zero || writeEv==IntPtr.Zero) throw new Exception("Cannot create HID events");
            readBuf=Marshal.AllocHGlobal(64); writeBuf=Marshal.AllocHGlobal(64);
            readOv=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
            writeOv=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
            for(int i=0;i<64;i++) {
                Marshal.WriteByte(readBuf,i,0); Marshal.WriteByte(writeBuf,i,req[i]);
            }
            Marshal.StructureToPtr(new NativeOverlapped{hEvent=readEv},readOv,false);
            Marshal.StructureToPtr(new NativeOverlapped{hEvent=writeEv},writeOv,false);

            bool r=ReadFile(h,readBuf,64u,IntPtr.Zero,readOv);
            int re=r?0:Marshal.GetLastWin32Error();
            if(!r && re!=ERROR_IO_PENDING) throw new Exception("Cannot queue input read: Win32 "+re);
            readPending=true;

            bool w=WriteFile(h,writeBuf,64u,IntPtr.Zero,writeOv);
            int we=w?0:Marshal.GetLastWin32Error();
            if(!w && we!=ERROR_IO_PENDING) throw new Exception("HID request write failed: Win32 "+we);
            writePending=true;
            uint wrote=Finish(h,writeEv,writeOv,w,2500u,"HID WriteFile");
            if(wrote!=64u) throw new Exception("Incomplete output report ("+wrote+" bytes)");
            uint got=Finish(h,readEv,readOv,r,2500u,"HID ReadFile");
            if(got!=64u) throw new Exception("Unexpected input report length "+got);
            byte[] response=new byte[64]; Marshal.Copy(readBuf,response,0,64);
            for(int i=0;i<8;i++) if(response[i]!=req[i])
                throw new Exception("Unexpected response header at byte "+i+"; refusing further reads");
            byte[] payload=new byte[length]; Array.Copy(response,8,payload,0,length);
            return payload;
        }
        finally {
            if(readPending) CancelPending(h,readOv,readEv);
            if(writePending) CancelPending(h,writeOv,writeEv);
            if(writeOv!=IntPtr.Zero) Marshal.FreeHGlobal(writeOv);
            if(readOv!=IntPtr.Zero) Marshal.FreeHGlobal(readOv);
            if(writeBuf!=IntPtr.Zero) Marshal.FreeHGlobal(writeBuf);
            if(readBuf!=IntPtr.Zero) Marshal.FreeHGlobal(readBuf);
            if(readEv!=IntPtr.Zero) CloseHandle(readEv);
            if(writeEv!=IntPtr.Zero) CloseHandle(writeEv);
            CloseHandle(h);
        }
    }

    // The user has verified that 0x01/0x09/0x02 modifies a Z1 mapping persistently.
    // Exact rollback behavior and partial-write recovery remain unverified.
    private static byte[] MakePacket(byte command, int offset, byte[] data, int pos, int count) {
        if(count<0 || count>56 || offset<0 || offset>65535) throw new ArgumentOutOfRangeException("count/offset");
        byte[] packet=new byte[64];
        packet[0]=0x04; packet[3]=command; packet[4]=(byte)count;
        packet[5]=(byte)(offset&255); packet[6]=(byte)((offset>>8)&255);
        if(count>0) Array.Copy(data,pos,packet,8,count);
        int sum=0;
        for(int i=3;i<64;i++) sum=(sum+packet[i])&65535;
        packet[1]=(byte)(sum&255); packet[2]=(byte)(sum>>8);
        return packet;
    }
    private static void SendFrame(IntPtr h, byte[] packet) {
        IntPtr ev=IntPtr.Zero, ov=IntPtr.Zero, buffer=IntPtr.Zero;
        bool queued=false;
        try {
            ev=CreateEvent(IntPtr.Zero,true,false,null);
            if(ev==IntPtr.Zero) throw new Exception("CreateEvent failed for output");
            ov=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
            buffer=Marshal.AllocHGlobal(64);
            Marshal.Copy(packet,0,buffer,64);
            Marshal.StructureToPtr(new NativeOverlapped{hEvent=ev},ov,false);
            bool success=WriteFile(h,buffer,64u,IntPtr.Zero,ov);
            int err=success?0:Marshal.GetLastWin32Error();
            if(!success && err!=ERROR_IO_PENDING) throw new Exception("WriteFile failed: Win32 "+err);
            queued=true;
            uint wrote=Finish(h,ev,ov,success,2500u,"WriteFile output");
            if(wrote!=64u) throw new Exception("Short HID write: "+wrote);
        }
        finally {
            if(queued) CancelPending(h,ov,ev);
            if(ov!=IntPtr.Zero) Marshal.FreeHGlobal(ov);
            if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if(ev!=IntPtr.Zero) CloseHandle(ev);
        }
    }
    public static void ApplyFullImage(string path, byte[] image) {
        if(path==null || !path.ToLowerInvariant().StartsWith(@"\\?\hid#vid_0c45&pid_7521&mi_01&col04#"))
            throw new ArgumentException("Unexpected device path; no transfer sent");
        if(image==null || image.Length!=384) throw new ArgumentException("Only complete 384-byte images accepted");
        IntPtr h=CreateFileW(path,GENERIC_READ_WRITE,SHARE_READ_WRITE,IntPtr.Zero,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,IntPtr.Zero);
        if(h==new IntPtr(-1)) throw new Exception("Cannot open Z1 interface for output: Win32 "+Marshal.GetLastWin32Error());
        try {
            SendFrame(h,MakePacket(0x01,0,image,0,0));
            System.Threading.Thread.Sleep(20);
            for(int offset=0;offset<384;offset+=56) {
                int count=Math.Min(56,384-offset);
                SendFrame(h,MakePacket(0x09,offset,image,offset,count));
                System.Threading.Thread.Sleep(15);
            }
            System.Threading.Thread.Sleep(30);
            SendFrame(h,MakePacket(0x02,0,image,0,0));
        }
        finally { CloseHandle(h); }
    }
}
'@ -ErrorAction Stop
}


if (-not ('Z1RawInputCaptureV3' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public sealed class Z1CapturedKey {
    public int ScanCode;
    public int Flags;
    public int VirtualKey;
    public string DevicePath;
    public bool IsZ1;
    public bool IsRelease;
}

public static class Z1RawInputCaptureV3 {
    const uint WM_INPUT=0x00FF, WM_CLOSE=0x0010;
    const uint WM_KEYDOWN=0x0100, WM_SYSKEYDOWN=0x0104;
    const uint WM_KEYUP=0x0101, WM_SYSKEYUP=0x0105;
    const uint RID_INPUT=0x10000003, RIDI_DEVICENAME=0x20000007;
    const uint RIDEV_INPUTSINK=0x00000100, RIDEV_REMOVE=0x00000001;
    const uint RIM_TYPEKEYBOARD=1;
    const uint INVALID_UINT=0xFFFFFFFFu;

    [StructLayout(LayoutKind.Sequential)]
    struct RawInputDevice {
        public ushort UsagePage;
        public ushort Usage;
        public uint Flags;
        public IntPtr Target;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct RawInputHeader {
        public uint Type;
        public uint Size;
        public IntPtr Device;
        public IntPtr WParam;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct RawKeyboard {
        public ushort MakeCode;
        public ushort Flags;
        public ushort Reserved;
        public ushort VKey;
        public uint Message;
        public uint ExtraInformation;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct Message {
        public IntPtr HWnd;
        public uint Msg;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public Point Pt;
        public uint Private;
    }

    [DllImport("user32.dll", EntryPoint="CreateWindowExW", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateWindowEx(uint exStyle,string className,string title,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool RegisterRawInputDevices(RawInputDevice[] devices,uint count,uint size);
    [DllImport("user32.dll", EntryPoint="GetMessageW", SetLastError=true)]
    static extern int GetMessage(out Message msg,IntPtr hwnd,uint min,uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message msg);
    [DllImport("user32.dll", EntryPoint="DispatchMessageW")] static extern IntPtr DispatchMessage(ref Message msg);
    [DllImport("user32.dll", EntryPoint="PostMessageW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr wParam,IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint GetRawInputData(IntPtr raw,uint command,IntPtr data,ref uint size,uint headerSize);
    [DllImport("user32.dll", EntryPoint="GetRawInputDeviceInfoW", CharSet=CharSet.Unicode,SetLastError=true)]
    static extern uint GetRawInputDeviceInfo(IntPtr device,uint command,StringBuilder data,ref uint size);

    // Raw Input identifies the keyboard, but normal keystrokes are also placed in
    // PowerShell's console input queue. Drain those events after key release so
    // they cannot become text in a later Read-Host confirmation prompt.
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool FlushConsoleInputBuffer(IntPtr consoleInput);

    const int STD_INPUT_HANDLE=-10;
    public static void FlushConsoleKeys() {
        IntPtr input=GetStdHandle(STD_INPUT_HANDLE);
        if(input==IntPtr.Zero || input==new IntPtr(-1))
            throw new Exception("No console input handle; use Windows PowerShell in an interactive console");
        if(!FlushConsoleInputBuffer(input))
            throw new Exception("FlushConsoleInputBuffer failed: Win32 "+Marshal.GetLastWin32Error());
    }

    sealed class Session {
        public readonly bool WantZ1;
        public readonly ManualResetEvent Ready=new ManualResetEvent(false);
        public readonly ManualResetEvent Finished=new ManualResetEvent(false);
        public IntPtr Window=IntPtr.Zero;
        public volatile bool Stopping=false;
        public volatile string LastDevice="";
        public Z1CapturedKey Result;
        private Z1CapturedKey PendingKey;
        public Exception Error;
        public Session(bool wantZ1) { WantZ1=wantZ1; }

        static string DeviceName(IntPtr device) {
            uint length=0;
            uint query=GetRawInputDeviceInfo(device,RIDI_DEVICENAME,null,ref length);
            if(query==INVALID_UINT || length==0 || length>2048) return "(device path unavailable)";
            StringBuilder name=new StringBuilder((int)length+2);
            uint response=GetRawInputDeviceInfo(device,RIDI_DEVICENAME,name,ref length);
            return response==INVALID_UINT ? "(device path unavailable)" : name.ToString();
        }
        Z1CapturedKey Extract(IntPtr raw) {
            uint size=0;
            uint headerSize=(uint)Marshal.SizeOf(typeof(RawInputHeader));
            if(GetRawInputData(raw,RID_INPUT,IntPtr.Zero,ref size,headerSize)==INVALID_UINT ||
               size < headerSize+(uint)Marshal.SizeOf(typeof(RawKeyboard)) || size>4096) return null;
            IntPtr mem=Marshal.AllocHGlobal((int)size);
            try {
                if(GetRawInputData(raw,RID_INPUT,mem,ref size,headerSize)==INVALID_UINT) return null;
                RawInputHeader header=(RawInputHeader)Marshal.PtrToStructure(mem,typeof(RawInputHeader));
                if(header.Type!=RIM_TYPEKEYBOARD) return null;
                IntPtr keyPtr=new IntPtr(mem.ToInt64()+(long)headerSize);
                RawKeyboard key=(RawKeyboard)Marshal.PtrToStructure(keyPtr,typeof(RawKeyboard));
                bool isDown=(key.Message==WM_KEYDOWN || key.Message==WM_SYSKEYDOWN) && (key.Flags&1)==0;
                bool isUp=(key.Message==WM_KEYUP || key.Message==WM_SYSKEYUP) || (key.Flags&1)!=0;
                if(!isDown && !isUp) return null;
                string path=DeviceName(header.Device);
                LastDevice=path;
                bool isZ1=path.IndexOf("VID_0C45&PID_7521",StringComparison.OrdinalIgnoreCase)>=0;
                if(isZ1!=WantZ1) return null;
                return new Z1CapturedKey { ScanCode=key.MakeCode, Flags=key.Flags,
                    VirtualKey=key.VKey, DevicePath=path, IsZ1=isZ1, IsRelease=isUp };
            } finally { Marshal.FreeHGlobal(mem); }
        }
        public void Run() {
            IntPtr hwnd=IntPtr.Zero;
            bool registered=false;
            try {
                // An invisible top-level window receives WM_INPUT independently
                // of which application owns the foreground keyboard focus.
                hwnd=CreateWindowEx(0,"STATIC","Z1RawInputWindow",0,0,0,0,0,
                    IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
                if(hwnd==IntPtr.Zero) throw new Exception("CreateWindowEx failed: "+Marshal.GetLastWin32Error());
                Window=hwnd;
                RawInputDevice[] devs={new RawInputDevice {
                    UsagePage=0x0001,Usage=0x0006,Flags=RIDEV_INPUTSINK,Target=hwnd
                }};
                if(!RegisterRawInputDevices(devs,1,(uint)Marshal.SizeOf(typeof(RawInputDevice))))
                    throw new Exception("RegisterRawInputDevices failed: "+Marshal.GetLastWin32Error());
                registered=true;
                Ready.Set();
                Message message;
                while(!Stopping) {
                    int n=GetMessage(out message,IntPtr.Zero,0,0);
                    if(n<0) throw new Exception("GetMessage failed: "+Marshal.GetLastWin32Error());
                    if(n==0 || message.Msg==WM_CLOSE) break;
                    if(message.Msg==WM_INPUT) {
                        Z1CapturedKey item=Extract(message.LParam);
                        if(item!=null) {
                            if(!item.IsRelease) {
                                // Ignore key-repeat and additional keys while waiting for release.
                                if(PendingKey==null) PendingKey=item;
                            } else if(PendingKey!=null &&
                                      item.ScanCode==PendingKey.ScanCode &&
                                      item.VirtualKey==PendingKey.VirtualKey &&
                                      item.DevicePath==PendingKey.DevicePath &&
                                      (item.Flags&2)==(PendingKey.Flags&2)) {
                                // Let the normal console host finish queuing the key-up,
                                // then discard both down/up before returning to Read-Host.
                                Thread.Sleep(90);
                                FlushConsoleKeys();
                                Result=PendingKey;
                                Finished.Set();
                                break;
                            }
                        }
                    }
                    TranslateMessage(ref message);
                    DispatchMessage(ref message);
                }
            } catch(Exception ex) { Error=ex; }
            finally {
                Ready.Set();
                Finished.Set();
                if(registered) {
                    RawInputDevice[] remove={new RawInputDevice {
                        UsagePage=0x0001,Usage=0x0006,Flags=RIDEV_REMOVE,Target=IntPtr.Zero
                    }};
                    RegisterRawInputDevices(remove,1,(uint)Marshal.SizeOf(typeof(RawInputDevice)));
                }
                if(hwnd!=IntPtr.Zero) DestroyWindow(hwnd);
                Window=IntPtr.Zero;
            }
        }
        public void Stop() {
            Stopping=true;
            IntPtr hwnd=Window;
            if(hwnd!=IntPtr.Zero) PostMessage(hwnd,WM_CLOSE,IntPtr.Zero,IntPtr.Zero);
        }
    }
    public static Z1CapturedKey Capture(bool fromZ1,int timeoutSeconds) {
        if(timeoutSeconds<1 || timeoutSeconds>120) throw new ArgumentOutOfRangeException("timeoutSeconds");
        Session session=new Session(fromZ1);
        Thread worker=new Thread(new ThreadStart(session.Run));
        worker.IsBackground=true;
        worker.Name="GameSir Z1 Raw Input";
        worker.Start();
        try {
            if(!session.Ready.WaitOne(4000)) throw new TimeoutException("Raw Input listener did not start");
            if(session.Error!=null) throw new Exception("Raw Input setup: "+session.Error.Message,session.Error);
            if(!session.Finished.WaitOne(timeoutSeconds*1000))
                throw new TimeoutException("No matching key detected in "+timeoutSeconds+" seconds. Last device: "+session.LastDevice);
            if(session.Error!=null) throw new Exception("Raw Input capture: "+session.Error.Message,session.Error);
            if(session.Result==null) throw new Exception("Capture stopped without a matching key. Last device: "+session.LastDevice);
            return session.Result;
        }
        finally {
            session.Stop();
            worker.Join(2000);
            session.Ready.Dispose();
            session.Finished.Dispose();
        }
    }
}
'@ -ErrorAction Stop
}


# Based on verified 0x07 reference, observed 0x08 active read, and successful persistent 0x09 write
# that the user has already tested and confirmed persistent on the Z1.
function Get-SHA([byte[]]$bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') })) }
    finally { $sha.Dispose() }
}
function Get-Z1DevicePath {
    $entries=@(Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -like 'HID\VID_0C45&PID_7521&MI_01&COL04\*'
    })
    if($entries.Count -ne 1){ throw "Expected one Z1 vendor HID collection; found $($entries.Count)." }
    return '\\?\' + $entries[0].InstanceId.Replace('\','#').ToLowerInvariant() + '#{4d1e55b2-f16f-11cf-88cb-001111000030}'
}
function Read-Z1Image([string]$path,[byte]$command) {
    if($command -notin @(0x07,0x08)){throw "Invalid keymap read command."}
    [byte[]]$bytes = New-Object byte[] 384
    for($off=0;$off -lt 384;$off+=56) {
        $len=[Math]::Min(56,384-$off)
        [byte[]]$chunk=[Z1RemapTransportV4]::ReadBlock($path,$off,$len,$command)
        [Array]::Copy($chunk,0,$bytes,$off,$len)
    }
    return ,$bytes
}
function Compare-Bytes([byte[]]$a,[byte[]]$b) {
    if($a.Length -ne $b.Length) { return -2 }
    for($i=0;$i -lt $a.Length;$i++){ if($a[$i] -ne $b[$i]) { return $i } }
    return -1
}
function Hex3([byte[]]$bytes) { return (($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ') }

# Set 1 raw hardware scancodes to USB HID usages. The physical key is used,
# not the character produced by the active Windows keyboard layout.
$scanMap=@{}
    $scanMap['01'] = @{ Label='Esc'; Usage=0x29 }
    $scanMap['02'] = @{ Label='1'; Usage=0x1E }
    $scanMap['03'] = @{ Label='2'; Usage=0x1F }
    $scanMap['04'] = @{ Label='3'; Usage=0x20 }
    $scanMap['05'] = @{ Label='4'; Usage=0x21 }
    $scanMap['06'] = @{ Label='5'; Usage=0x22 }
    $scanMap['07'] = @{ Label='6'; Usage=0x23 }
    $scanMap['08'] = @{ Label='7'; Usage=0x24 }
    $scanMap['09'] = @{ Label='8'; Usage=0x25 }
    $scanMap['0A'] = @{ Label='9'; Usage=0x26 }
    $scanMap['0B'] = @{ Label='0'; Usage=0x27 }
    $scanMap['0C'] = @{ Label='Minus'; Usage=0x2D }
    $scanMap['0D'] = @{ Label='Equals'; Usage=0x2E }
    $scanMap['0E'] = @{ Label='Backspace'; Usage=0x2A }
    $scanMap['0F'] = @{ Label='Tab'; Usage=0x2B }
    $scanMap['10'] = @{ Label='Q'; Usage=0x14 }
    $scanMap['11'] = @{ Label='W'; Usage=0x1A }
    $scanMap['12'] = @{ Label='E'; Usage=0x08 }
    $scanMap['13'] = @{ Label='R'; Usage=0x15 }
    $scanMap['14'] = @{ Label='T'; Usage=0x17 }
    $scanMap['15'] = @{ Label='Y'; Usage=0x1C }
    $scanMap['16'] = @{ Label='U'; Usage=0x18 }
    $scanMap['17'] = @{ Label='I'; Usage=0x0C }
    $scanMap['18'] = @{ Label='O'; Usage=0x12 }
    $scanMap['19'] = @{ Label='P'; Usage=0x13 }
    $scanMap['1A'] = @{ Label='LeftBracket'; Usage=0x2F }
    $scanMap['1B'] = @{ Label='RightBracket'; Usage=0x30 }
    $scanMap['1C'] = @{ Label='Enter'; Usage=0x28 }
    $scanMap['1E'] = @{ Label='A'; Usage=0x04 }
    $scanMap['1F'] = @{ Label='S'; Usage=0x16 }
    $scanMap['20'] = @{ Label='D'; Usage=0x07 }
    $scanMap['21'] = @{ Label='F'; Usage=0x09 }
    $scanMap['22'] = @{ Label='G'; Usage=0x0A }
    $scanMap['23'] = @{ Label='H'; Usage=0x0B }
    $scanMap['24'] = @{ Label='J'; Usage=0x0D }
    $scanMap['25'] = @{ Label='K'; Usage=0x0E }
    $scanMap['26'] = @{ Label='L'; Usage=0x0F }
    $scanMap['27'] = @{ Label='Semicolon'; Usage=0x33 }
    $scanMap['28'] = @{ Label='Apostrophe'; Usage=0x34 }
    $scanMap['29'] = @{ Label='Grave'; Usage=0x35 }
    $scanMap['2B'] = @{ Label='Backslash'; Usage=0x31 }
    $scanMap['2C'] = @{ Label='Z'; Usage=0x1D }
    $scanMap['2D'] = @{ Label='X'; Usage=0x1B }
    $scanMap['2E'] = @{ Label='C'; Usage=0x06 }
    $scanMap['2F'] = @{ Label='V'; Usage=0x19 }
    $scanMap['30'] = @{ Label='B'; Usage=0x05 }
    $scanMap['31'] = @{ Label='N'; Usage=0x11 }
    $scanMap['32'] = @{ Label='M'; Usage=0x10 }
    $scanMap['33'] = @{ Label='Comma'; Usage=0x36 }
    $scanMap['34'] = @{ Label='Period'; Usage=0x37 }
    $scanMap['35'] = @{ Label='Slash'; Usage=0x38 }
    $scanMap['39'] = @{ Label='Space'; Usage=0x2C }
    $scanMap['3A'] = @{ Label='CapsLock'; Usage=0x39 }
    $scanMap['3B'] = @{ Label='F1'; Usage=0x3A }
    $scanMap['3C'] = @{ Label='F2'; Usage=0x3B }
    $scanMap['3D'] = @{ Label='F3'; Usage=0x3C }
    $scanMap['3E'] = @{ Label='F4'; Usage=0x3D }
    $scanMap['3F'] = @{ Label='F5'; Usage=0x3E }
    $scanMap['40'] = @{ Label='F6'; Usage=0x3F }
    $scanMap['41'] = @{ Label='F7'; Usage=0x40 }
    $scanMap['42'] = @{ Label='F8'; Usage=0x41 }
    $scanMap['43'] = @{ Label='F9'; Usage=0x42 }
    $scanMap['44'] = @{ Label='F10'; Usage=0x43 }
    $scanMap['45'] = @{ Label='NumLock'; Usage=0x53 }
    $scanMap['46'] = @{ Label='ScrollLock'; Usage=0x47 }
    $scanMap['47'] = @{ Label='Numpad7'; Usage=0x5F }
    $scanMap['48'] = @{ Label='Numpad8'; Usage=0x60 }
    $scanMap['49'] = @{ Label='Numpad9'; Usage=0x61 }
    $scanMap['4A'] = @{ Label='NumpadMinus'; Usage=0x56 }
    $scanMap['4B'] = @{ Label='Numpad4'; Usage=0x5C }
    $scanMap['4C'] = @{ Label='Numpad5'; Usage=0x5D }
    $scanMap['4D'] = @{ Label='Numpad6'; Usage=0x5E }
    $scanMap['4E'] = @{ Label='NumpadPlus'; Usage=0x57 }
    $scanMap['4F'] = @{ Label='Numpad1'; Usage=0x59 }
    $scanMap['50'] = @{ Label='Numpad2'; Usage=0x5A }
    $scanMap['51'] = @{ Label='Numpad3'; Usage=0x5B }
    $scanMap['52'] = @{ Label='Numpad0'; Usage=0x62 }
    $scanMap['53'] = @{ Label='NumpadDot'; Usage=0x63 }
    $scanMap['56'] = @{ Label='ISOKey'; Usage=0x64 }
    $scanMap['57'] = @{ Label='F11'; Usage=0x44 }
    $scanMap['58'] = @{ Label='F12'; Usage=0x45 }
    $scanMap['E1C'] = @{ Label='NumpadEnter'; Usage=0x58 }
    $scanMap['E35'] = @{ Label='NumpadDivide'; Usage=0x54 }
    $scanMap['E47'] = @{ Label='Home'; Usage=0x4A }
    $scanMap['E48'] = @{ Label='Up'; Usage=0x52 }
    $scanMap['E49'] = @{ Label='PageUp'; Usage=0x4B }
    $scanMap['E4B'] = @{ Label='Left'; Usage=0x50 }
    $scanMap['E4D'] = @{ Label='Right'; Usage=0x4F }
    $scanMap['E4F'] = @{ Label='End'; Usage=0x4D }
    $scanMap['E50'] = @{ Label='Down'; Usage=0x51 }
    $scanMap['E51'] = @{ Label='PageDown'; Usage=0x4E }
    $scanMap['E52'] = @{ Label='Insert'; Usage=0x49 }
    $scanMap['E53'] = @{ Label='Delete'; Usage=0x4C }
    $scanMap['E5D'] = @{ Label='Menu'; Usage=0x65 }
$modMap=@{}
    $modMap['1D'] = @{ Label='LeftCtrl'; Mask=0x01 }
    $modMap['E1D'] = @{ Label='RightCtrl'; Mask=0x10 }
    $modMap['2A'] = @{ Label='LeftShift'; Mask=0x02 }
    $modMap['36'] = @{ Label='RightShift'; Mask=0x20 }
    $modMap['38'] = @{ Label='LeftAlt'; Mask=0x04 }
    $modMap['E38'] = @{ Label='RightAlt'; Mask=0x40 }
    $modMap['E5B'] = @{ Label='LeftWin'; Mask=0x08 }
    $modMap['E5C'] = @{ Label='RightWin'; Mask=0x80 }

function Convert-KeyEvent($ev) {
    # 0x02 is the E0 extended-key flag in RAWKEYBOARD.Flags.
    $prefix=''
    if (([int]$ev.Flags -band 0x02) -ne 0) { $prefix='E' }
    $scanKey=$prefix+([int]$ev.ScanCode).ToString('X2')
    if($modMap.ContainsKey($scanKey)) {
        $entry=$modMap[$scanKey]
        return [pscustomobject]@{
            Label=$entry.Label; Bytes=[byte[]]@(0x20,[byte]$entry.Mask,0x00)
            Scan=$scanKey; VirtualKey=$ev.VirtualKey
        }
    }
    if($scanMap.ContainsKey($scanKey)) {
        $entry=$scanMap[$scanKey]
        return [pscustomobject]@{
            Label=$entry.Label; Bytes=[byte[]]@(0x20,0x00,[byte]$entry.Usage)
            Scan=$scanKey; VirtualKey=$ev.VirtualKey
        }
    }
    return $null
}

# These correspond to verified ordinary-key records in the original Z1 image.
# They are factory *labels*, useful when two records now send the same key.
$factoryLabels=@{
    4='Space'; 6='Esc';7='1';8='2';9='3';10='4';11='5';12='Tab'
    13='Q';14='W';15='E';16='R';17='T';18='Equals'
    19='A';20='S';21='D';22='F';23='G';24='LeftShift'
    25='Z';26='X';27='C';28='V';30='LeftCtrl'
    32='LeftAlt';33='B';34='M'
}
function Is-EditableRecord([byte[]]$image,[int]$record) {
    if(-not $factoryLabels.ContainsKey($record)) {return $false}
    $at=$record*3
    if($image[$at] -ne 0x20){return $false}
    $isKey=($image[$at+1] -eq 0 -and $image[$at+2] -ne 0)
    $isModifier=($image[$at+2] -eq 0 -and $image[$at+1] -in @(1,2,4,8,16,32,64,128))
    return ($isKey -or $isModifier)
}
function Find-MatchingRecords([byte[]]$image,[byte[]]$keyBytes) {
    $results=@()
    foreach($n in ($factoryLabels.Keys | Sort-Object)) {
        $n=[int]$n
        if(-not (Is-EditableRecord $image $n)){continue}
        $at=3*$n
        if($image[$at] -eq $keyBytes[0] -and $image[$at+1] -eq $keyBytes[1] -and $image[$at+2] -eq $keyBytes[2]) {
            $results+= $n
        }
    }
    return $results
}
function Capture-KnownKey([bool]$fromZ1) {
    for($attempt=0;$attempt -lt 5;$attempt++) {
        $raw=[Z1RawInputCaptureV3]::Capture($fromZ1,30)
        # Console input can arrive a little after WM_INPUT. Clear it once more
        # before any following prompt can consume the captured keystroke.
        Start-Sleep -Milliseconds 75
        [Z1RawInputCaptureV3]::FlushConsoleKeys()
        $key=Convert-KeyEvent $raw
        if($null -ne $key){return $key}
        Write-Warning ('Unsupported scan code {0:X2} flags {1:X2}. Try an ordinary key.' -f $raw.ScanCode,$raw.Flags)
    }
    throw 'Could not decode a supported key after five attempts.'
}

Write-Host ''
Write-Host 'GameSir Z1 - direct onboard key remapping' -ForegroundColor Cyan
Write-Host 'Press a Z1 key, then a key on your main keyboard. No G-Core required.'
Write-Host 'This version reads the actual active keymap with opcode 0x08.'
Write-Host 'Ctrl+C cancels before writing. Keep a second keyboard connected.'
Write-Host ''

$path=Get-Z1DevicePath
Write-Host 'Reading Z1 reference map (0x07) and ACTIVE map (0x08)...'
# Read the 0x07 reference once, only for a known hardware-layout guard.
# This map was observed to remain factory-original after Q -> W was saved.
[byte[]]$reference=Read-Z1Image $path 0x07
$expectedReferenceHash='ADF7946335EBF5648A7044A187291DE4F0FD92C76B5C0987119EE7C62E4DB381'
if((Get-SHA $reference) -ne $expectedReferenceHash) {
    throw '0x07 reference map differs from the Z1 mapping used to identify physical key records. Refusing to guess key positions.'
}
# The previous console mistakenly used the reference map as the live map.
# On this Z1, 0x08 returns current active key assignments (verified Q -> W).
[byte[]]$initial=Read-Z1Image $path 0x08
[byte[]]$initial2=Read-Z1Image $path 0x08
if((Compare-Bytes $initial $initial2) -ne -1){ throw 'Active map changed between reads. No write will be attempted.' }
Write-Host ('Reference (0x07) SHA256: '+(Get-SHA $reference))
Write-Host ('ACTIVE (0x08) SHA256: '+(Get-SHA $initial)) -ForegroundColor Green
Write-Host ('Physical Q (record 13): reference {0}; active {1}' -f (Hex3 ([byte[]]@($reference[39],$reference[40],$reference[41]))),(Hex3 ([byte[]]@($initial[39],$initial[40],$initial[41]))))
Write-Host ('Physical W (record 14): reference {0}; active {1}' -f (Hex3 ([byte[]]@($reference[42],$reference[43],$reference[44]))),(Hex3 ([byte[]]@($initial[42],$initial[43],$initial[44]))))

Write-Host ''
Write-Host 'STEP 1: TAP AND RELEASE ONE key on the GameSir Z1.' -ForegroundColor Cyan
Write-Host 'Listening for the Z1 only (30-second timeout)...'
$source=Capture-KnownKey $true
Write-Host ('Z1 sent: '+$source.Label+'  ('+(Hex3 $source.Bytes)+')')
[int[]]$matches=@(Find-MatchingRecords $initial $source.Bytes)
if($matches.Count -eq 0) {
    throw 'The Z1 key does not match a safely editable mapping record. Vendor-defined keys, macros and unsupported layers are protected.'
}
[int]$record=$matches[0]
if($matches.Count -gt 1) {
    Write-Warning 'Several Z1 keys currently send this SAME value. Windows cannot distinguish their physical switches.'
    Write-Host 'Choose the ORIGINAL physical key label from this list:'
    foreach($n in $matches) {
        Write-Host ('  [{0}] Physical {1} key (currently sends {2})' -f $n,$factoryLabels[[int]$n],$source.Label)
    }
    $choice=(Read-Host 'Enter the number for the PHYSICAL Z1 key you pressed').Trim()
    [int]$entered=-1
    if(-not [int]::TryParse($choice,[ref]$entered) -or $matches -notcontains $entered) {
        throw 'Selection not in candidate records. No write attempted.'
    }
    $record=$entered
}
Write-Host ('Selected Z1 record {0}, PHYSICAL {1}; current output {2}' -f $record,$factoryLabels[$record],$source.Label) -ForegroundColor Green

Write-Host ''
Write-Host 'STEP 2: TAP AND RELEASE the REPLACEMENT key on your normal PC keyboard.' -ForegroundColor Cyan
Write-Host 'Listening for any keyboard EXCEPT the Z1 (30-second timeout)...'
$target=Capture-KnownKey $false
Write-Host ('New assignment: '+$target.Label+'  ('+(Hex3 $target.Bytes)+')')

$at=$record*3
[byte[]]$old3=@($initial[$at],$initial[$at+1],$initial[$at+2])
if((Compare-Bytes $old3 $target.Bytes) -eq -1) {
    Write-Host 'Already mapped to this key. Nothing to write.' -ForegroundColor Green
    exit 0
}
[byte[]]$proposed=New-Object byte[] 384
[Array]::Copy($initial,$proposed,384)
[Array]::Copy($target.Bytes,0,$proposed,$at,3)
$changed=0
for($i=0;$i -lt 384;$i++) { if($initial[$i] -ne $proposed[$i]){$changed++} }
if($changed -gt 3) {throw 'Internal patch invariant failed; refusing write.'}

Write-Host ''
Write-Host 'PROPOSED CHANGE' -ForegroundColor Yellow
Write-Host ('  Z1 original key: '+$factoryLabels[$record])
Write-Host ('  Physical record:  '+$record)
Write-Host ('  Current output:   '+$source.Label+' ['+(Hex3 $old3)+']')
Write-Host ('  New output:       '+$target.Label+' ['+(Hex3 $target.Bytes)+']')
Write-Host ('  Bytes modified:   '+$changed+' / 384')
Write-Host ''
if(-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Force -Path $BackupDirectory)
}
$runFolder=Join-Path $BackupDirectory ('Change-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[void](New-Item -ItemType Directory -Path $runFolder)
[IO.File]::WriteAllBytes((Join-Path $runFolder 'before.bin'),$initial)
[IO.File]::WriteAllBytes((Join-Path $runFolder 'proposed.bin'),$proposed)
$plan=[ordered]@{
    Device='GameSir Z1';VID='0C45';PID='7521';Record=$record;ActiveReadOpcode='0x08';ReferenceReadOpcode='0x07'
    FactoryLabel=$factoryLabels[$record];Source=$source.Label;Destination=$target.Label
    OldBytes=(Hex3 $old3);NewBytes=(Hex3 $target.Bytes);ByteOffset=$at
    BeforeSHA256=(Get-SHA $initial);ProposedSHA256=(Get-SHA $proposed)
    TimestampUTC=[DateTime]::UtcNow.ToString('o')
}
$plan|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $runFolder 'change.json') -Encoding UTF8
Write-Host ('Backups saved: '+$runFolder) -ForegroundColor Green
if($PreviewOnly){
    Write-Host 'PREVIEW ONLY: No write commands sent.' -ForegroundColor Yellow
    exit 0
}
Write-Host 'The script will write the FULL configuration, not a single 3-byte record.' -ForegroundColor Yellow
$confirm=Read-Host 'Type WRITE to program the Z1, or anything else to cancel'
if($confirm -cne 'WRITE') { Write-Host 'Cancelled. No configuration writes.'; exit 0 }

# A fresh double read immediately before any modification: if another program
# or key-layer changed the configuration, abort rather than overwrite it.
Write-Host 'Verifying the ACTIVE 384 bytes twice (0x08)...'
$path=Get-Z1DevicePath
[byte[]]$live=Read-Z1Image $path 0x08
[byte[]]$liveAgain=Read-Z1Image $path 0x08
if((Compare-Bytes $initial $live) -ne -1 -or (Compare-Bytes $initial $liveAgain) -ne -1) {
    throw 'The keymap changed since the initial scan. No write was sent.'
}
[IO.File]::WriteAllBytes((Join-Path $runFolder 'immediate-before.bin'),$live)
Write-Host 'Writing the Z1 onboard configuration...'
try {
    [Z1RemapTransportV4]::ApplyFullImage($path,$proposed)
} catch {
    Write-Warning ('Write failed or was interrupted: '+$_.Exception.Message)
    Write-Warning ('No automatic retry or rollback. Keep backup: '+$runFolder)
    throw
}
Start-Sleep -Milliseconds 350
try {
    [byte[]]$readback=Read-Z1Image $path 0x08
    [IO.File]::WriteAllBytes((Join-Path $runFolder 'after.bin'),$readback)
    [byte[]]$confirmRead=Read-Z1Image $path 0x08
    if((Compare-Bytes $proposed $readback) -ne -1 -or (Compare-Bytes $proposed $confirmRead) -ne -1) {
        throw 'Post-write full-image verification failed. Do not issue another write blindly.'
    }
    Write-Host 'SUCCESS: ACTIVE (0x08) keymap matches the new assignment in two full readbacks.' -ForegroundColor Green
    Write-Host ('SHA256: '+(Get-SHA $readback))
} catch {
    Write-Warning ('Readback failed: '+$_.Exception.Message)
    Write-Warning ('Do not repeat the write automatically. Original backup: '+$runFolder)
    throw
}
Write-Host ''
$answer=Read-Host 'Optional persistence test: unplug/replug Z1, then press Enter (or type SKIP)'
if($answer -ne 'SKIP') {
    try {
        $newPath=Get-Z1DevicePath
        [byte[]]$persisted=Read-Z1Image $newPath 0x08
        if((Compare-Bytes $proposed $persisted) -ne -1) {
            throw 'Configuration changed after reconnection; persistence NOT verified.'
        }
        Write-Host 'PERSISTENCE CONFIRMED via ACTIVE map (0x08). The Z1 retained the mapping after reconnecting.' -ForegroundColor Green
    } catch {
        Write-Warning ('Persistence check failed: '+$_.Exception.Message)
        Write-Warning ('Backup location: '+$runFolder)
    }
}
Write-Host ('Finished. Backups: '+$runFolder)
