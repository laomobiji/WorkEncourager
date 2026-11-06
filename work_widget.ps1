# =====================================================================
#  上班鼓励器 / Work Encourager  —  WPF 原生桌面悬浮窗
#  运行方式：powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File work_widget.ps1
#  调试参数：-Clock "18:30"  用假时间预览界面（正式运行不要带）
# =====================================================================
param([string]$Clock = '', [switch]$TestToast)

# 调试模式：-Clock 只做界面预览，任何情况下都不写 state.json
$script:TestMode = ($Clock -ne '')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Win32：桌面嵌入（SetParent 到壁纸 WorkerW）所需
if (-not ('WorkEncNative' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WorkEncNative {
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern uint SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    public struct RECT { public int L; public int T; public int R; public int B; }
    // 触发系统创建壁纸层 WorkerW，返回可以挂部件的容器（找不到就退回 Progman）
    public static IntPtr GetWallpaperHost() {
        IntPtr progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return IntPtr.Zero;
        IntPtr res;
        SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, 0x0002, 1000, out res);
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr top, IntPtr lp) {
            IntPtr dv = FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (dv != IntPtr.Zero) {
                IntPtr w = FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
                if (w != IntPtr.Zero) { found = w; return false; }
            }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) found = progman;
        return found;
    }
}
'@
}

# 单实例：已经在跑就直接退出（上一个实例被强杀时会抛 AbandonedMutexException，视为可以接管）
$script:Mtx = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, 'Local\WorkEncouragerWidget'
try {
    $script:GotMutex = $script:Mtx.WaitOne(0)
} catch {
    $script:GotMutex = $true
}
if (-not $script:GotMutex) { exit }

# ---------------------------- 可调参数 ----------------------------
$script:Wage         = 500.0      # 日薪
$script:StartH       = 8          # 上班 8:00
$script:StartM       = 0
$script:EndH         = 16         # 下班 16:45（小时、分钟必须分开写，
$script:EndM         = 45         #   EndH 写 16.45 会被当成 16 小时 27 分）
$script:CountWeekend = $false     # 周末是否也算钱（默认不算）
$script:Holidays     = @()        # 额外假日（设置里手动填，作为自动数据的补充）

# 节点奖励（金额 → 提示文案）
$script:Milestones = @(
    @{ Amt = 50;  Title = '【已获得一个金铲铲皮肤】'; Tag = '金铲铲'; Sub = '皮肤到手，人还在工位' },
    @{ Amt = 100; Title = '【已获得一顿寿司郎】';     Tag = '寿司郎'; Sub = '今天中午别吃泡面了' },
    @{ Amt = 300; Title = '【已获得一次滑雪票】';     Tag = '滑雪票'; Sub = '摔一天，快乐一整天' },
    @{ Amt = 500; Title = '【打工圆满速速下班】';     Tag = '下班';  Sub = '500 到手，人自由了' }
)

# 本月累计金额 → 一句话对照（写死，不联网）
$script:Tiers = @(
    @{ At = 0;     Text = '一杯奶茶，先甜一下' },
    @{ At = 50;    Text = '一个金铲铲皮肤' },
    @{ At = 100;   Text = '一顿寿司郎' },
    @{ At = 150;   Text = '两杯手冲咖啡' },
    @{ At = 200;   Text = '一场 livehouse 的票' },
    @{ At = 300;   Text = '一次滑雪票' },
    @{ At = 400;   Text = '一顿像样的日料' },
    @{ At = 500;   Text = '周边游一天（不含住宿）' },
    @{ At = 700;   Text = '一双入门跑鞋' },
    @{ At = 1000;  Text = '一场演唱会看台票' },
    @{ At = 1200;  Text = '一台千元级显示器' },
    @{ At = 1500;  Text = '一场演唱会内场票' },
    @{ At = 2000;  Text = '一双旗舰跑鞋加一顿好饭' },
    @{ At = 2500;  Text = '一台 iPad 基础款' },
    @{ At = 3000;  Text = '短途两天一夜' },
    @{ At = 4000;  Text = '一台入门微单' },
    @{ At = 5000;  Text = '一部中端旗舰手机' },
    @{ At = 6000;  Text = '一张日本往返机票（淡季）' },
    @{ At = 8000;  Text = '一台 MacBook Air' },
    @{ At = 10000; Text = '一趟日本 5 天 4 晚' },
    @{ At = 12000; Text = '一台顶配游戏本的首付' },
    @{ At = 15000; Text = '一块高端显卡' }
)

# ---------------------------- 主题 ----------------------------
# 右键菜单「主题」可随时切换，选择存在 state.json 里。
# 想加自己的主题：照抄一份改色值，Key 不重复即可，会自动出现在右键菜单里。
$script:Themes = [ordered]@{
    sakura = @{
        Name='奶油粉'; WinBg='#FFF7F2'; WinBd='#F3D3DB'; TitleFg='#A98D96'; StatusFg='#B99AA4'
        CloseBg='#FBE3EA'; CloseFg='#D8A8B6'; CloseHoverBg='#FFD3E0'; CloseHoverFg='#E8547F'
        YuanFg='#FF9EBB'; MoneyFg='#E8547E'; SubFg='#A98D96'; TrackBg='#F5E3E8'; FillA='#FF9EBB'; FillB='#FFC1D5'
        LeftFg='#B08A96'; RightFg='#C4A6B0'; Divider='#F5E4E8'; DaysFg='#9A7E88'; Money2Fg='#6B4A52'; SmallFg='#C9A8B2'; TierFg='#A98D96'
        LockBg='#FAECEF'; LockBd='#F1D9E0'; LockNum='#C9A8B2'; LockTag='#B895A2'
        OnBg='#FFE9F0'; OnBd='#F7A8C0'; OnNum='#E8547E'; OnTag='#8C5B68'
        Eye='#8C5B68'; Blush='#FFC2D1'
        ToastBgA='#FFF3F6'; ToastBgB='#FFEBF1'; ToastBd='#F7A8C0'; ToastIconBg='#FFE1EB'; ToastIcon='#F0567F'
        ToastTitle='#6B4A52'; ToastSub='#C98A9B'; ToastAmt='#F0567F'
    }
    night = @{
        Name='经典暗夜'; WinBg='#0F1116'; WinBd='#2B3141'; TitleFg='#818CA1'; StatusFg='#5A6577'
        CloseBg='#151922'; CloseFg='#4B5464'; CloseHoverBg='#2A1418'; CloseHoverFg='#FF7A8A'
        YuanFg='#3FCF97'; MoneyFg='#ECFDF5'; SubFg='#6B7689'; TrackBg='#1A1F28'; FillA='#22B87C'; FillB='#78F0C0'
        LeftFg='#8B96A9'; RightFg='#4C5666'; Divider='#1E2430'; DaysFg='#7B8698'; Money2Fg='#CBD6E5'; SmallFg='#464F5F'; TierFg='#5B6678'
        LockBg='#14171E'; LockBd='#1C222C'; LockNum='#454E5D'; LockTag='#4C5666'
        OnBg='#12241C'; OnBd='#2E6B4F'; OnNum='#4BE0A0'; OnTag='#DDE9E2'
        Eye='#4BE0A0'; Blush='#2E6B4F'
        ToastBgA='#0E2019'; ToastBgB='#0A1712'; ToastBd='#2E7A57'; ToastIconBg='#14352A'; ToastIcon='#5FE3A8'
        ToastTitle='#EAFBF3'; ToastSub='#5FA487'; ToastAmt='#4BE0A0'
    }
    matcha = @{
        Name='抹茶拿铁'; WinBg='#F6FAF2'; WinBd='#D8E8CC'; TitleFg='#8A9B7E'; StatusFg='#9FAE93'
        CloseBg='#E8F2DE'; CloseFg='#A3B395'; CloseHoverBg='#D5E8C4'; CloseHoverFg='#5E8C2F'
        YuanFg='#9BC46A'; MoneyFg='#5E8C2F'; SubFg='#8A9B7E'; TrackBg='#E4EED8'; FillA='#A8CE6E'; FillB='#CFE8A8'
        LeftFg='#9AA88C'; RightFg='#B3C2A6'; Divider='#E6EEDD'; DaysFg='#93A385'; Money2Fg='#4E6138'; SmallFg='#BCC9AC'; TierFg='#8A9B7E'
        LockBg='#EFF5E7'; LockBd='#DFEAD2'; LockNum='#AAB89C'; LockTag='#9CAE8E'
        OnBg='#EAF4DC'; OnBd='#B5D488'; OnNum='#5E8C2F'; OnTag='#3E5222'
        Eye='#4E6132'; Blush='#C8E3A8'
        ToastBgA='#F4FAEC'; ToastBgB='#EFF7E4'; ToastBd='#B5D488'; ToastIconBg='#E2F0CC'; ToastIcon='#5E8C2F'
        ToastTitle='#3E5222'; ToastSub='#93A878'; ToastAmt='#5E8C2F'
    }
    sky = @{
        Name='云朵蓝'; WinBg='#F2F8FD'; WinBd='#CFE2F2'; TitleFg='#8298AC'; StatusFg='#93A9BC'
        CloseBg='#E1EEF9'; CloseFg='#9DB2C6'; CloseHoverBg='#CCE3F7'; CloseHoverFg='#2E6DA8'
        YuanFg='#7FB3E3'; MoneyFg='#2E6DA8'; SubFg='#8298AC'; TrackBg='#E0EDF8'; FillA='#86BCE8'; FillB='#BDDCF4'
        LeftFg='#92A7BA'; RightFg='#B0C3D4'; Divider='#E3EDF6'; DaysFg='#8498AA'; Money2Fg='#33506B'; SmallFg='#B6C7D6'; TierFg='#8298AC'
        LockBg='#EBF3FA'; LockBd='#DCE9F4'; LockNum='#A3B5C6'; LockTag='#96A9BA'
        OnBg='#E3F0FB'; OnBd='#9CC4E8'; OnNum='#2E6DA8'; OnTag='#28455E'
        Eye='#33506B'; Blush='#B9D8F0'
        ToastBgA='#F0F7FD'; ToastBgB='#E9F3FB'; ToastBd='#9CC4E8'; ToastIconBg='#D8EAF8'; ToastIcon='#2E6DA8'
        ToastTitle='#28455E'; ToastSub='#8FA8BE'; ToastAmt='#2E6DA8'
    }
    peach = @{
        Name='蜜柚橙'; WinBg='#FFF8F1'; WinBd='#F5DCC8'; TitleFg='#A98F7E'; StatusFg='#B9A293'
        CloseBg='#F9E8DA'; CloseFg='#CBA790'; CloseHoverBg='#F6D9C3'; CloseHoverFg='#C96F3B'
        YuanFg='#FFAB7E'; MoneyFg='#E0703A'; SubFg='#A98F7E'; TrackBg='#F7E8DB'; FillA='#FFA96E'; FillB='#FFCBAA'
        LeftFg='#B09884'; RightFg='#C8B2A0'; Divider='#F6E7DA'; DaysFg='#9C8574'; Money2Fg='#6B4A3A'; SmallFg='#D2B49C'; TierFg='#A98F7E'
        LockBg='#FBF0E6'; LockBd='#F1DFCF'; LockNum='#C0A691'; LockTag='#B49B85'
        OnBg='#FFEEDF'; OnBd='#F5B98B'; OnNum='#E0703A'; OnTag='#7A4E30'
        Eye='#7A4E30'; Blush='#FFC9A3'
        ToastBgA='#FFF6ED'; ToastBgB='#FFF1E4'; ToastBd='#F5B98B'; ToastIconBg='#FFE3CC'; ToastIcon='#E0703A'
        ToastTitle='#7A4E30'; ToastSub='#C49B7F'; ToastAmt='#E0703A'
    }
    grape = @{
        Name='葡萄汽水'; WinBg='#F8F5FD'; WinBd='#E0D6F2'; TitleFg='#9286AC'; StatusFg='#A395BD'
        CloseBg='#ECE5F9'; CloseFg='#AFA0C9'; CloseHoverBg='#DFD2F4'; CloseHoverFg='#6E4FB8'
        YuanFg='#B39BE3'; MoneyFg='#6E4FB8'; SubFg='#9286AC'; TrackBg='#EDE7F8'; FillA='#B49BE8'; FillB='#D8C9F4'
        LeftFg='#9C90B4'; RightFg='#B6AAD0'; Divider='#EAE3F6'; DaysFg='#8E82A6'; Money2Fg='#4A3A66'; SmallFg='#C6BAE0'; TierFg='#9286AC'
        LockBg='#F1ECFA'; LockBd='#E4DCF2'; LockNum='#AC9FC4'; LockTag='#A094BA'
        OnBg='#EFE8FC'; OnBd='#C4AEEC'; OnNum='#6E4FB8'; OnTag='#3D2E5C'
        Eye='#4A3A66'; Blush='#D5C4F0'
        ToastBgA='#F6F2FD'; ToastBgB='#F1EBFB'; ToastBd='#C4AEEC'; ToastIconBg='#E6DBF8'; ToastIcon='#6E4FB8'
        ToastTitle='#3D2E5C'; ToastSub='#9C8FB8'; ToastAmt='#6E4FB8'
    }
}

# ---------------------------- 状态文件 ----------------------------
$script:StateDir  = Join-Path $env:APPDATA 'WorkEncourager'
$script:StateFile = Join-Path $script:StateDir 'state.json'
if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }

$script:FiredDate = ''
$script:Fired     = @()
$script:Left      = $null
$script:Top       = $null
$script:LastPosSave = [DateTime]::MinValue
$script:ThemeName = 'sakura'
$script:LastIncome  = 0.0
$script:DesktopMode = $false
$script:SavedStyle  = 0
$script:SavedEx     = 0

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8
        $st  = $raw | ConvertFrom-Json
        if ($st.PSObject.Properties.Name -contains 'date')     { $script:FiredDate = [string]$st.date }
        if ($st.PSObject.Properties.Name -contains 'fired')    { $script:Fired = @($st.fired | ForEach-Object { [int]$_ }) }
        if ($st.PSObject.Properties.Name -contains 'left')     { $script:Left  = [double]$st.left }
        if ($st.PSObject.Properties.Name -contains 'top')      { $script:Top   = [double]$st.top }
        if ($st.PSObject.Properties.Name -contains 'theme')    { $script:ThemeName = [string]$st.theme }
        if ($st.PSObject.Properties.Name -contains 'desktopMode') { $script:DesktopMode = [bool]$st.desktopMode }
        if ($st.PSObject.Properties.Name -contains 'cfg' -and $null -ne $st.cfg) {
            $c = $st.cfg
            try {
                $pn = $c.PSObject.Properties.Name
                if ($pn -contains 'wage')         { $v = [double]$c.wage; if ($v -gt 0) { $script:Wage = $v } }
                if ($pn -contains 'startH')       { $script:StartH = [int]$c.startH }
                if ($pn -contains 'startM')       { $script:StartM = [int]$c.startM }
                if ($pn -contains 'endH')         { $script:EndH   = [int]$c.endH }
                if ($pn -contains 'endM')         { $script:EndM   = [int]$c.endM }
                if ($pn -contains 'countWeekend') { $script:CountWeekend = [bool]$c.countWeekend }
                if ($pn -contains 'holidays')     { $script:Holidays = @($c.holidays | ForEach-Object { [string]$_ }) }
                if ($pn -contains 'milestones') {
                    $list = @($c.milestones); $newMs = @()
                    for ($i = 0; $i -lt $list.Count; $i++) {
                        $m = $list[$i]
                        $def = if ($i -lt $script:Milestones.Count) { $script:Milestones[$i] } else { @{ Amt = 0; Tag = ''; Title = ''; Sub = '' } }
                        $mpn = $m.PSObject.Properties.Name
                        $amt = if ($mpn -contains 'amt')   { [double]$m.amt }   else { [double]$def.Amt }
                        $tag = if ($mpn -contains 'tag')   { [string]$m.tag }   else { [string]$def.Tag }
                        $tit = if ($mpn -contains 'title') { [string]$m.title } else { [string]$def.Title }
                        $sub = if ($mpn -contains 'sub')   { [string]$m.sub }   else { [string]$def.Sub }
                        $newMs += @{ Amt = $amt; Tag = $tag; Title = $tit; Sub = $sub }
                    }
                    if ($newMs.Count -gt 0) { $script:Milestones = $newMs }
                }
            } catch { }
        }
    } catch { }
    if (-not $script:Themes.Contains($script:ThemeName)) { $script:ThemeName = 'sakura' }
}

function Save-State {
    if ($script:TestMode) { return }   # -Clock 预览模式不落盘
    try {
        $obj = [PSCustomObject]@{
            date  = $script:FiredDate
            fired = @($script:Fired)
            left  = $script:Left
            top   = $script:Top
            theme = $script:ThemeName
            desktopMode = $script:DesktopMode
            cfg   = $script:Cfg
        }
        $json = $obj | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:StateFile, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

Load-State

# ---------------------------- 主界面 XAML ----------------------------
$script:WinW = 400
$script:WinH = 356

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="400" Height="356" WindowStartupLocation="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Border Name="Root" CornerRadius="22" Background="#FFF7F2" BorderBrush="#F3D3DB" BorderThickness="1">
    <Grid Margin="22,16,22,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Grid Name="Dot" Width="16" Height="11" VerticalAlignment="Center" Margin="0,1,0,0">
            <Ellipse Name="EyeL" Width="2.6" Height="2.6" Margin="3.4,2.6,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Fill="#8C5B68"/>
            <Ellipse Name="EyeR" Width="2.6" Height="2.6" Margin="10,2.6,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Fill="#8C5B68"/>
            <Ellipse Name="BlushL" Width="4.6" Height="2.8" Margin="0.4,5.6,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Fill="#FFC2D1" Opacity="0.9"/>
            <Ellipse Name="BlushR" Width="4.6" Height="2.8" Margin="11,5.6,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Fill="#FFC2D1" Opacity="0.9"/>
          </Grid>
          <TextBlock Name="TitleText" Text="打工鼓励器" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="#A98D96" VerticalAlignment="Center" Margin="7,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <TextBlock Name="StatusText" Text="" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="#B99AA4" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Border Name="CloseBtn" Width="22" Height="22" CornerRadius="11" Background="#FBE3EA">
            <TextBlock Name="CloseTxt" Text="✕" FontSize="9" Foreground="#D8A8B6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </StackPanel>
      </Grid>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,16,0,0">
        <TextBlock Name="YuanText" Text="¥" FontFamily="Microsoft YaHei UI" FontSize="24" Foreground="#FF9EBB" VerticalAlignment="Bottom" Margin="0,0,9,9"/>
        <TextBlock Name="MoneyText" Text="0.00000" FontFamily="Consolas" FontSize="46" Foreground="#E8547E" VerticalAlignment="Bottom"/>
      </StackPanel>

      <TextBlock Name="SubLine" Grid.Row="2" Text="" FontFamily="Microsoft YaHei UI" FontSize="11.5" Foreground="#A98D96" Margin="1,3,0,0"/>

      <Border Name="Track" Grid.Row="3" Height="7" CornerRadius="3.5" Background="#F5E3E8" Margin="1,18,1,0" HorizontalAlignment="Stretch">
        <Border Name="Fill" CornerRadius="3.5" HorizontalAlignment="Left" Width="0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#FF9EBB" Offset="0"/>
              <GradientStop Color="#FFC1D5" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
      </Border>

      <Grid Grid.Row="4" Margin="1,9,1,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Name="LeftTime" Text="" FontFamily="Microsoft YaHei UI" FontSize="10.5" Foreground="#B08A96"/>
        <TextBlock Name="RightTime" Grid.Column="1" Text="" FontFamily="Microsoft YaHei UI" FontSize="10.5" Foreground="#C4A6B0"/>
      </Grid>

      <Border Name="Div1" Grid.Row="5" Height="1" Background="#F5E4E8" Margin="0,15,0,0"/>

      <UniformGrid Name="ChipsGrid" Grid.Row="6" Columns="2" Rows="2" Margin="0,14,0,0"/>

      <Border Name="Div2" Grid.Row="7" Height="1" Background="#F5E4E8" Margin="0,8,0,0"/>

      <StackPanel Grid.Row="8" Margin="1,12,1,0">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Name="MonthDays" Text="本月已打工 0 天" FontFamily="Microsoft YaHei UI" FontSize="11.5" Foreground="#9A7E88" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Name="MonthMoney" Text="¥0.00" FontFamily="Consolas" FontSize="14" Foreground="#6B4A52"/>
            <TextBlock Name="SmallText" Text="含今日" FontFamily="Microsoft YaHei UI" FontSize="9" Foreground="#C9A8B2" VerticalAlignment="Bottom" Margin="5,0,0,3"/>
          </StackPanel>
        </Grid>
        <TextBlock Name="MonthTier" Text="" FontFamily="Microsoft YaHei UI" FontSize="11.5" Foreground="#A98D96" Margin="0,7,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$w = [Windows.Markup.XamlReader]::Parse($xaml)

# 定位：优先上次位置，其次右上角
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $script:Left -and $null -ne $script:Top) {
    $w.Left = [double]$script:Left
    $w.Top  = [double]$script:Top
} else {
    $w.Left = [double]($wa.Right - $script:WinW - 36)
    $w.Top  = [double]($wa.Top + 48)
}

# 引用缓存
$script:UI = @{}
foreach ($n in @('Root','Dot','EyeL','EyeR','BlushL','BlushR','TitleText','StatusText','CloseBtn','CloseTxt','YuanText','MoneyText','SubLine','Track','Fill','LeftTime','RightTime','Div1','Div2','ChipsGrid','MonthDays','MonthMoney','SmallText','MonthTier')) {
    $script:UI[$n] = $w.FindName($n)
}

# 固定文案跟随参数区，改上下班时间后不用再改别处
$script:UI['RightTime'].Text = ('{0:00}:{1:00} 收工' -f $script:EndH, $script:EndM)

# ---------------------------- 颜色 / 主题应用 ----------------------------
function Brush([string]$hex) { [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex)) }

function Set-ChipState($c, [bool]$on, [bool]$force) {
    $bg = if ($on) { $script:C.OnBg }  else { $script:C.LockBg }
    $bd = if ($on) { $script:C.OnBd }  else { $script:C.LockBd }
    $nf = if ($on) { $script:C.OnNum } else { $script:C.LockedNum }
    $tf = if ($on) { $script:C.OnTag } else { $script:C.LockedTag }
    if ($force -or ($c.Border.Background -ne $bg)) {
        $c.Border.Background  = $bg
        $c.Border.BorderBrush = $bd
        $c.Num.Text           = [string]$c.Amt
        $c.Num.Foreground     = $nf
        $c.Tag.Foreground     = $tf
        $tg = ($script:Milestones | Where-Object { $_.Amt -eq $c.Amt } | Select-Object -First 1).Tag
        $c.Tag.Text = if ($on) { '✓ ' + $tg } else { $tg }
    }
}

function Apply-Theme {
    if (-not $script:Themes.Contains($script:ThemeName)) { $script:ThemeName = 'sakura' }
    $t = $script:Themes[$script:ThemeName]

    $script:C = @{
        Accent    = (Brush $t.FillA)
        AccentDim = (Brush $t.OnBd)
        OffDot    = (Brush $t.LockBd)
        LockedNum = (Brush $t.LockNum);  LockedTag = (Brush $t.LockTag)
        LockBg    = (Brush $t.LockBg);   LockBd    = (Brush $t.LockBd)
        OnBg      = (Brush $t.OnBg);     OnBd      = (Brush $t.OnBd)
        OnNum     = (Brush $t.OnNum);    OnTag     = (Brush $t.OnTag)
    }

    $script:UI['Root'].Background       = Brush $t.WinBg
    $script:UI['Root'].BorderBrush      = Brush $t.WinBd
    $script:UI['TitleText'].Foreground  = Brush $t.TitleFg
    $script:UI['StatusText'].Foreground = Brush $t.StatusFg
    $script:UI['CloseBtn'].Background   = Brush $t.CloseBg
    $script:UI['CloseTxt'].Foreground   = Brush $t.CloseFg
    $script:UI['YuanText'].Foreground   = Brush $t.YuanFg
    $script:UI['MoneyText'].Foreground  = Brush $t.MoneyFg
    $script:UI['SubLine'].Foreground    = Brush $t.SubFg
    $script:UI['Track'].Background      = Brush $t.TrackBg
    $script:UI['LeftTime'].Foreground   = Brush $t.LeftFg
    $script:UI['RightTime'].Foreground  = Brush $t.RightFg
    $script:UI['Div1'].Background       = Brush $t.Divider
    $script:UI['Div2'].Background       = Brush $t.Divider
    $script:UI['MonthDays'].Foreground  = Brush $t.DaysFg
    $script:UI['MonthMoney'].Foreground = Brush $t.Money2Fg
    $script:UI['SmallText'].Foreground  = Brush $t.SmallFg
    $script:UI['MonthTier'].Foreground  = Brush $t.TierFg

    $eye   = Brush $t.Eye
    $blush = Brush $t.Blush
    $script:UI['EyeL'].Fill   = $eye
    $script:UI['EyeR'].Fill   = $eye
    $script:UI['BlushL'].Fill = $blush
    $script:UI['BlushR'].Fill = $blush

    $grad = $script:UI['Fill'].Background
    $grad.GradientStops[0].Color = [Windows.Media.ColorConverter]::ConvertFromString($t.FillA)
    $grad.GradientStops[1].Color = [Windows.Media.ColorConverter]::ConvertFromString($t.FillB)

    foreach ($c in $script:Chips) { Set-ChipState $c ($script:LastIncome -ge $c.Amt) $true }
}

# ---------------------------- 节点小卡 ----------------------------
$script:Chips = @()
for ($i = 0; $i -lt $script:Milestones.Count; $i++) {
    $m = $script:Milestones[$i]
    $b = [Windows.Controls.Border]::new()
    $b.CornerRadius = [Windows.CornerRadius]::new(11)
    $b.BorderThickness = [Windows.Thickness]::new(1)
    $b.Padding = [Windows.Thickness]::new(9,5,9,5)
    $b.Margin = [Windows.Thickness]::new(0,0,6,6)
    $b.Background = $script:C.LockBg
    $b.BorderBrush = $script:C.LockBd

    $sp = [Windows.Controls.StackPanel]::new()
    $sp.Orientation = [Windows.Controls.Orientation]::Horizontal

    $num = [Windows.Controls.TextBlock]::new()
    $num.Text = [string]$m.Amt
    $num.FontFamily = [Windows.Media.FontFamily]::new('Consolas')
    $num.FontSize = 11
    $num.FontWeight = [Windows.FontWeights]::SemiBold
    $num.Foreground = $script:C.LockedNum
    $num.VerticalAlignment = [Windows.VerticalAlignment]::Center

    $tag = [Windows.Controls.TextBlock]::new()
    $tag.Text = $m.Tag
    $tag.FontFamily = [Windows.Media.FontFamily]::new('Microsoft YaHei UI')
    $tag.FontSize = 11
    $tag.Foreground = $script:C.LockedTag
    $tag.Margin = [Windows.Thickness]::new(7,0,0,0)
    $tag.VerticalAlignment = [Windows.VerticalAlignment]::Center

    [void]$sp.Children.Add($num)
    [void]$sp.Children.Add($tag)
    $b.Child = $sp
    [void]$script:UI['ChipsGrid'].Children.Add($b)

    $script:Chips += @{ Border = $b; Num = $num; Tag = $tag; Amt = [double]$m.Amt }
}

# 首次应用主题（覆盖 XAML 里的默认粉色）
Apply-Theme

# ---------------------------- 桌面嵌入（底层模式） ----------------------------
# 说明：WPF 透明窗口挂到 WorkerW/Progman 下会停止渲染（子窗口不支持 DX 分层呈现），
# 所以这里不重新挂父，而是保持顶层窗口 + 压到 Z 序最底 + 点击不抢焦点，
# 并用低频计时器保证 Win+D 最小化后自动恢复。视觉效果与桌面部件一致。
function Get-WidgetHwnd {
    $h = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $w
    if ($h.Handle -eq [IntPtr]::Zero) { [void]$h.EnsureHandle() }
    return $h.Handle
}

function Push-Bottom {
    try {
        $hwnd = Get-WidgetHwnd
        if ([WorkEncNative]::IsIconic($hwnd) -or $w.WindowState -ne 'Normal') {
            $w.WindowState = 'Normal'   # Win+D 之后自动恢复
        }
        # HWND_BOTTOM + NOSIZE|NOMOVE|NOACTIVATE|NOOWNERZORDER
        [void][WorkEncNative]::SetWindowPos($hwnd, [IntPtr]1, 0, 0, 0, 0, 0x213)
    } catch { }
}

function Enable-DesktopMode {
    try {
        $hwnd = Get-WidgetHwnd
        $ex = [WorkEncNative]::GetWindowLong($hwnd, -20)
        $script:SavedEx = $ex
        if (($ex -band [int]0x08000000) -eq 0) {
            [void][WorkEncNative]::SetWindowLong($hwnd, -20, $ex -bor [int]0x08000000)  # WS_EX_NOACTIVATE
        }
        $w.Topmost = $false
        Push-Bottom
        if (-not $script:BottomTimer) {
            $script:BottomTimer = New-Object Windows.Threading.DispatcherTimer
            $script:BottomTimer.Interval = [TimeSpan]::FromSeconds(1)
            $script:BottomTimer.Add_Tick({ Push-Bottom })
        }
        $script:BottomTimer.Start()
        $script:DesktopMode = $true
        return $true
    } catch { return $false }
}

function Disable-DesktopMode {
    try {
        if ($script:BottomTimer) { $script:BottomTimer.Stop() }
        $hwnd = Get-WidgetHwnd
        if ($script:SavedEx -ne 0) { [void][WorkEncNative]::SetWindowLong($hwnd, -20, $script:SavedEx) }
        $w.Topmost = $true
        $script:DesktopMode = $false
    } catch { }
}

# ---------------------------- 交互 ----------------------------
$script:Drag = @{ on = $false; ox = 0.0; oy = 0.0; k = 1.0 }

$script:UI['Root'].Add_MouseLeftButtonDown({
    param($s, $e)
    try {
        $e.Handled = $true
        $src = [Windows.PresentationSource]::FromVisual($w)
        if ($src -and $src.CompositionTarget) { $script:Drag.k = $src.CompositionTarget.TransformToDevice.M11 }
        if ($script:Drag.k -le 0) { $script:Drag.k = 1.0 }
        $gp = [System.Windows.Forms.Cursor]::Position
        $script:Drag.ox = $w.Left - ($gp.X / $script:Drag.k)
        $script:Drag.oy = $w.Top  - ($gp.Y / $script:Drag.k)
        $script:Drag.on = $true
        [void]$script:UI['Root'].CaptureMouse()
    } catch { }
})

$script:UI['Root'].Add_MouseMove({
    param($s, $e)
    try {
        if (-not $script:Drag.on) { return }
        $gp = [System.Windows.Forms.Cursor]::Position
        $w.Left = ($gp.X / $script:Drag.k) + $script:Drag.ox
        $w.Top  = ($gp.Y / $script:Drag.k) + $script:Drag.oy
    } catch { }
})

$script:UI['Root'].Add_MouseLeftButtonUp({
    param($s, $e)
    try {
        if ($script:Drag.on) {
            $script:Drag.on = $false
            [void]$script:UI['Root'].ReleaseMouseCapture()
            $script:Left = $w.Left
            $script:Top  = $w.Top
            Save-State
        }
    } catch { }
})

$script:UI['CloseBtn'].Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $w.Close()
})

$script:UI['CloseBtn'].Add_MouseEnter({
    $t = $script:Themes[$script:ThemeName]
    $script:UI['CloseBtn'].Background = Brush $t.CloseHoverBg
    $script:UI['CloseTxt'].Foreground = Brush $t.CloseHoverFg
})
$script:UI['CloseBtn'].Add_MouseLeave({
    $t = $script:Themes[$script:ThemeName]
    $script:UI['CloseBtn'].Background = Brush $t.CloseBg
    $script:UI['CloseTxt'].Foreground = Brush $t.CloseFg
})

# 右键菜单
$cm = [Windows.Controls.ContextMenu]::new()
$miAlways = [Windows.Controls.MenuItem]::new()
$miAlways.Header = '取消置顶'
[void]$cm.Items.Add($miAlways)
$miHome = [Windows.Controls.MenuItem]::new()
$miHome.Header = '回到右上角'
[void]$cm.Items.Add($miHome)

$miTheme = [Windows.Controls.MenuItem]::new()
$miTheme.Header = '主题'
foreach ($k in $script:Themes.Keys) {
    $sm = [Windows.Controls.MenuItem]::new()
    $sm.Header = $script:Themes[$k].Name
    $sm.IsCheckable = $true
    $sm.IsChecked = ($k -eq $script:ThemeName)
    $sm.Tag = $k
    $sm.Add_Click({
        $script:ThemeName = $this.Tag
        foreach ($it in $miTheme.Items) { $it.IsChecked = ($it.Tag -eq $script:ThemeName) }
        Apply-Theme
        Save-State
    })
    [void]$miTheme.Items.Add($sm)
}
[void]$cm.Items.Add($miTheme)

$miSet = [Windows.Controls.MenuItem]::new()
$miSet.Header = '设置'
$miSet.Add_Click({
    try {
        Show-Settings
    } catch {
        try {
            [System.IO.File]::AppendAllText((Join-Path $env:APPDATA 'WorkEncourager\settings_err.log'), ((Get-Date).ToString('s') + ' | ' + $_.Exception.GetType().Name + ' | ' + $_.Exception.Message + " | " + ($_.ScriptStackTrace -replace "`r`n", ' / ') + "`r`n"))
        } catch { }
    }
})
[void]$cm.Items.Add($miSet)

$miHol = [Windows.Controls.MenuItem]::new()
$miHol.Header = '刷新假日数据'
$miHol.Add_Click({
    Update-Holidays -Force
    Update-UI
})
[void]$cm.Items.Add($miHol)

$miDesk = [Windows.Controls.MenuItem]::new()
$miDesk.Header = '嵌入桌面（当壁纸）'
$miDesk.IsCheckable = $true
$miDesk.IsChecked = $script:DesktopMode
$miDesk.Add_Click({
    param($s, $e)
    try {
        if ($s.IsChecked) {
            if (Enable-DesktopMode) { } else { $s.IsChecked = $false }
        } else {
            Disable-DesktopMode
        }
        Save-State
    } catch { }
})
[void]$cm.Items.Add($miDesk)

[void]$cm.Items.Add([Windows.Controls.Separator]::new())
$miExit = [Windows.Controls.MenuItem]::new()
$miExit.Header = '退出'
[void]$cm.Items.Add($miExit)
$script:UI['Root'].ContextMenu = $cm

$miAlways.Add_Click({
    $w.Topmost = -not $w.Topmost
    $miAlways.Header = if ($w.Topmost) { '取消置顶' } else { '保持置顶' }
})
$miHome.Add_Click({
    $w.Left = [double]($wa.Right - $script:WinW - 36)
    $w.Top  = [double]($wa.Top + 48)
    $script:Left = $w.Left; $script:Top = $w.Top; Save-State
})
$miExit.Add_Click({ $w.Close() })

# ---------------------------- 提示气泡 ----------------------------
$script:OpenToasts = @()

$toastXamlTpl = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="400" Height="76" WindowStartupLocation="Manual" Opacity="0">
  <Border CornerRadius="16" BorderThickness="1" BorderBrush="{3}">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="{4}" Offset="0"/>
        <GradientStop Color="{5}" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid Margin="16,12,14,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Width="36" Height="36" CornerRadius="18" Background="{6}" VerticalAlignment="Center">
        <TextBlock Text="✦" FontFamily="Microsoft YaHei UI" FontSize="16" Foreground="{7}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="12,0,6,0" VerticalAlignment="Center">
        <TextBlock Text="{0}" FontFamily="Microsoft YaHei UI" FontSize="13" FontWeight="SemiBold" Foreground="{8}" TextTrimming="CharacterEllipsis"/>
        <TextBlock Text="{1}" FontFamily="Microsoft YaHei UI" FontSize="10" Foreground="{9}" Margin="0,4,0,0"/>
      </StackPanel>
      <TextBlock Grid.Column="2" Text="{2}" FontFamily="Consolas" FontSize="15" Foreground="{10}" VerticalAlignment="Center"/>
    </Grid>
  </Border>
</Window>
'@

function Show-Toast($title, $sub, $amount) {
    $t = $script:Themes[$script:ThemeName]
    $x = $toastXamlTpl -f $title, $sub, ('¥' + $amount), $t.ToastBd, $t.ToastBgA, $t.ToastBgB, $t.ToastIconBg, $t.ToastIcon, $t.ToastTitle, $t.ToastSub, $t.ToastAmt
    $tw = [Windows.Markup.XamlReader]::Parse($x)

    $baseLeft = $w.Left
    $baseTop  = [double]($w.Top + $w.ActualHeight + 10)
    $stackIdx = $script:OpenToasts.Count
    $tw.Left = $baseLeft
    $tw.Top  = [double]($baseTop + $stackIdx * 86)
    if (($tw.Top + 76) -gt ($wa.Bottom - 8)) { $tw.Top = [double]($w.Top - 86 - $stackIdx * 86) }

    $ctx = @{ t = 0; win = $tw; timer = $null }
    $ft = New-Object Windows.Threading.DispatcherTimer
    $ft.Interval = [TimeSpan]::FromMilliseconds(30)
    $ctx.timer = $ft
    $handler = {
        $ctx.t += 30
        if ($ctx.t -lt 260) {
            $ctx.win.Opacity = $ctx.t / 260.0
        } elseif ($ctx.t -lt 5200) {
            $ctx.win.Opacity = 1.0
        } else {
            $v = 1.0 - (($ctx.t - 5200) / 500.0)
            if ($v -lt 0) { $v = 0 }
            $ctx.win.Opacity = $v
            if ($ctx.t -gt 5750) {
                $ctx.timer.Stop()
                try { $ctx.win.Close() } catch { }
            }
        }
    }.GetNewClosure()
    $ft.Add_Tick($handler)
    $ft.Start()

    $tw.Add_Closed({
        param($s, $e)
        $script:OpenToasts = @($script:OpenToasts | Where-Object { $_ -ne $tw })
    }.GetNewClosure())

    $script:OpenToasts += $tw
    $tw.Show()
}

function Play-Ding {
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
}

# ---------------------------- 设置窗口 ----------------------------
function Parse-Hm([string]$s) {
    $t = $s.Trim()
    $m = [regex]::Match($t, '^(\d{1,2})\s*[:：.]\s*(\d{1,2})$')
    if ($m.Success) {
        $h = [int]$m.Groups[1].Value; $mi = [int]$m.Groups[2].Value
    } else {
        $m2 = [regex]::Match($t, '^(\d{1,2})$')
        if (-not $m2.Success) { throw "时间看不懂：'$s'，要写成 8:00 这样" }
        $h = [int]$m2.Groups[1].Value; $mi = 0
    }
    if ($h -gt 23 -or $mi -gt 59) { throw "时间超出范围：'$s'" }
    return ,@($h, $mi)
}

$settingsXamlTpl = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="440" SizeToContent="Height" WindowStartupLocation="Manual">
  <Border Name="SRoot" CornerRadius="16" Background="{0}" BorderBrush="{1}" BorderThickness="1">
    <StackPanel Margin="20,16,20,18">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="设置" FontFamily="Microsoft YaHei UI" FontSize="14" FontWeight="SemiBold" Foreground="{2}"/>
        <TextBlock Name="SClose" Grid.Column="1" Text="✕" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="{4}" Cursor="Hand" VerticalAlignment="Center"/>
      </Grid>
      <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
        <TextBlock Text="日薪 ¥" Width="70" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
        <TextBox Name="TbWage" Width="100" FontSize="12" Padding="6,4,6,4" VerticalAlignment="Center"/>
        <TextBlock Text="  ／天" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="{4}" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock Text="上下班" Width="70" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
        <TextBox Name="TbStart" Width="60" FontSize="12" Padding="6,4,6,4" VerticalAlignment="Center"/>
        <TextBlock Text="  到  " FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
        <TextBox Name="TbEnd" Width="60" FontSize="12" Padding="6,4,6,4" VerticalAlignment="Center"/>
        <TextBlock Text="  （写成 8:00 这样）" FontFamily="Microsoft YaHei UI" FontSize="11" Foreground="{4}" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock Text="周末" Width="70" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
        <CheckBox Name="CkWeekend" Content="周末也算钱" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock Text="额外假日" Width="70" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" VerticalAlignment="Center"/>
        <TextBox Name="TbHoliday" Width="260" FontSize="12" Padding="6,4,6,4" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock Text="法定假日已自动识别（含调休），这里补充自定义假日，如 2026-10-01" FontFamily="Microsoft YaHei UI" FontSize="10.5" Foreground="{4}" Margin="70,4,0,0"/>
      <Border Height="1" Background="{5}" Margin="0,12,0,0"/>
      <TextBlock Text="节点奖励（金额 / 小卡标签 / 弹出标题）" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="{3}" Margin="0,10,0,0"/>
      <StackPanel Margin="0,8,0,0">
        __MSROWS__
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
        <Button Name="BtnOk" Content="保存" Width="76" Height="28" FontSize="12" Cursor="Hand"/>
        <Button Name="BtnCancel" Content="取消" Width="76" Height="28" Margin="10,0,0,0" FontSize="12" Cursor="Hand"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

function Show-Settings {
    $t = $script:Themes[$script:ThemeName]
    $lf = $t.SubFg

    $msRows = ''
    for ($i = 0; $i -lt $script:Milestones.Count; $i++) {
        $msRows += "<StackPanel Orientation='Horizontal' Margin='0,0,0,8'>"
        $msRows += "<TextBlock Text='¥' FontSize='12' Foreground='$lf' VerticalAlignment='Center'/>"
        $msRows += "<TextBox Name='M${i}Amt' Width='58' Margin='5,0,0,0' FontSize='12' Padding='6,4,6,4' VerticalAlignment='Center'/>"
        $msRows += "<TextBox Name='M${i}Tag' Width='84' Margin='8,0,0,0' FontSize='12' Padding='6,4,6,4' VerticalAlignment='Center'/>"
        $msRows += "<TextBox Name='M${i}Title' Width='168' Margin='8,0,0,0' FontSize='12' Padding='6,4,6,4' VerticalAlignment='Center'/>"
        $msRows += '</StackPanel>'
    }

    $x = $settingsXamlTpl -f $t.WinBg, $t.WinBd, $t.Money2Fg, $t.SubFg, $t.SmallFg, $t.Divider
    $x = $x.Replace('__MSROWS__', $msRows)
    $sw = [Windows.Markup.XamlReader]::Parse($x)
    $script:SWin = $sw

    $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $sw.Left = [Math]::Min([double]($w.Left + 60), [double]($wa2.Right - 450))
    $sw.Top  = [Math]::Min([double]($w.Top + 60),  [double]($wa2.Bottom - 480))

    $sw.FindName('TbWage').Text         = ('{0:0.##}' -f $script:Wage)
    $sw.FindName('TbStart').Text        = ('{0}:{1:00}' -f $script:StartH, $script:StartM)
    $sw.FindName('TbEnd').Text          = ('{0}:{1:00}' -f $script:EndH, $script:EndM)
    $sw.FindName('CkWeekend').IsChecked = [bool]$script:CountWeekend
    $sw.FindName('TbHoliday').Text      = ($script:Holidays -join ',')

    for ($i = 0; $i -lt $script:Milestones.Count; $i++) {
        $m = $script:Milestones[$i]
        $sw.FindName("M${i}Amt").Text   = ('{0:0.##}' -f $m.Amt)
        $sw.FindName("M${i}Tag").Text   = $m.Tag
        $sw.FindName("M${i}Title").Text = $m.Title
    }

    $sw.FindName('SRoot').Add_MouseLeftButtonDown({
        try { $script:SWin.DragMove() } catch { }
    })
    $sw.FindName('SClose').Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true
        try { $script:SWin.Close() } catch { }
    })
    $sw.FindName('BtnCancel').Add_Click({ $script:SWin.Close() })

    $sw.FindName('BtnOk').Add_Click({
        try {
            $f = $script:SWin
            $wage = 0.0
            if (-not [double]::TryParse($f.FindName('TbWage').Text.Trim(), [ref]$wage) -or $wage -le 0) { throw '日薪要填一个正数' }
            $s1 = Parse-Hm $f.FindName('TbStart').Text
            $s2 = Parse-Hm $f.FindName('TbEnd').Text
            if (($s2[0] * 60 + $s2[1]) -le ($s1[0] * 60 + $s1[1])) { throw '下班时间要比上班晚' }
            $hol = @()
            $rawh = $f.FindName('TbHoliday').Text.Trim()
            if ($rawh -ne '') {
                foreach ($p in ($rawh -split '[,，;；]+')) {
                    if ($p.Trim() -eq '') { continue }
                    if ($p.Trim() -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "假日日期看不懂：'$p'（要 2026-10-01 这样）" }
                    $hol += $p.Trim()
                }
            }
            $newMs = @()
            for ($i = 0; $i -lt $script:Milestones.Count; $i++) {
                $amt = 0.0
                if (-not [double]::TryParse($f.FindName("M${i}Amt").Text.Trim(), [ref]$amt) -or $amt -lt 0) { throw "第 $($i + 1) 个节点金额要填不小于 0 的数字" }
                $tg = $f.FindName("M${i}Tag").Text.Trim()
                $tt = $f.FindName("M${i}Title").Text.Trim()
                if ($tg -eq '') { $tg = '{0:0.##}' -f $amt }
                if ($tt -eq '') { $tt = '【达成 ¥{0:0.##}】' -f $amt }
                $newMs += @{ Amt = $amt; Tag = $tg; Title = $tt; Sub = $script:Milestones[$i].Sub }
            }

            $script:Wage = $wage
            $script:StartH = $s1[0]; $script:StartM = $s1[1]
            $script:EndH = $s2[0];   $script:EndM = $s2[1]
            $script:CountWeekend = [bool]$f.FindName('CkWeekend').IsChecked
            $script:Holidays = $hol
            $script:Milestones = $newMs
            $script:Cfg = [PSCustomObject]@{
                wage         = $wage
                startH       = $s1[0]; startM = $s1[1]
                endH         = $s2[0]; endM   = $s2[1]
                countWeekend = [bool]$f.FindName('CkWeekend').IsChecked
                holidays     = @($hol)
                milestones   = @($newMs | ForEach-Object { [PSCustomObject]@{ amt = $_.Amt; tag = $_.Tag; title = $_.Title; sub = $_.Sub } })
            }
            # 参数变了，当天的节点弹出记录作废，让新节点重新生效
            $script:FiredDate = ''
            $script:Fired = @()
            Apply-Theme
            Save-State
            $script:SWin.Close()
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, '设置没保存', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
    })

    [void]$sw.ShowDialog()
}

# ---------------------------- 法定假日自动识别 ----------------------------
# 数据源：holiday-cn（国务院节假日安排的权威镜像），含放假日和调休补班日
# 每年拉取一次，缓存到本地；断网时用缓存 + 手动假日，不影响使用
$script:AutoHolidays = @()   # 法定放假日（含周末连休日）
$script:MakeupDays   = @()   # 调休补班日（周末但要上班）

function Get-HolidayCachePath([int]$y) { Join-Path $script:StateDir ('holidays_' + $y + '.json') }

function Save-HolidayCache([int]$y, $hol, $mk) {
    try {
        $obj = [PSCustomObject]@{ fetched = (Get-Date).ToString('yyyy-MM-dd'); holidays = @($hol); makeup = @($mk) }
        [System.IO.File]::WriteAllText((Get-HolidayCachePath $y), ($obj | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

function Load-HolidayCache([int]$y) {
    try {
        $p = Get-HolidayCachePath $y
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:AutoHolidays = @($c.holidays | ForEach-Object { [string]$_ })
        $script:MakeupDays   = @($c.makeup   | ForEach-Object { [string]$_ })
        return $true
    } catch { return $false }
}

function Update-Holidays([switch]$Force) {
    # 阴影模式（-Clock 预览）不联网，直接用现有缓存
    $y = (Get-Date).Year
    Load-HolidayCache $y | Out-Null
    if ($script:TestMode) { return }
    # 缓存是今年且 30 天内更新过，就不用联网（-Force 强制刷新）
    if (-not $Force) {
        try {
            $p = Get-HolidayCachePath $y
            if (Test-Path -LiteralPath $p) {
                $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
                $fd = [datetime]::Parse([string]$c.fetched)
                if ($fd.Year -ge $y -and ((Get-Date) - $fd).TotalDays -lt 30) { return }
            }
        } catch { }
    }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    # 依次尝试多个数据源，成功后缓存
    $sources = @(
        'https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{0}.json',
        'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{0}.json',
        'https://gitee.com/NateScarlet/holiday-cn/raw/master/{0}.json'
    )
    foreach ($tpl in $sources) {
        try {
            $r = Invoke-WebRequest -Uri ($tpl -f $y) -UseBasicParsing -TimeoutSec 8
            $j = $r.Content | ConvertFrom-Json
            if ($j.year -ne $y) { continue }
            $hol = @(); $mk = @()
            foreach ($d in $j.days) {
                if ($d.isOffDay) { $hol += [string]$d.date } else { $mk += [string]$d.date }
            }
            if ($hol.Count -gt 0) {
                $script:AutoHolidays = @($hol)
                $script:MakeupDays   = @($mk)
                Save-HolidayCache $y $hol $mk
                return
            }
        } catch { }
    }
}

# ---------------------------- 计算与刷新 ----------------------------
function Get-TierText([double]$amt) {
    $r = $script:Tiers[0].Text
    foreach ($t in $script:Tiers) { if ($amt -ge $t.At) { $r = $t.Text } }
    return $r
}

function Test-Workday([datetime]$d) {
    $key = $d.ToString('yyyy-MM-dd')
    if ($script:MakeupDays -contains $key)   { return $true }   # 调休补班：周末也要上班
    if ($script:AutoHolidays -contains $key) { return $false }  # 法定假日（含与周末连休的）
    if ($script:Holidays -contains $key)     { return $false }  # 手动补充的假日
    if ($d.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $d.DayOfWeek -eq [System.DayOfWeek]::Sunday) { return $false }
    return $true
}

function Get-MonthWorkdays([datetime]$today) {
    $n = 0
    $d = [datetime]::new($today.Year, $today.Month, 1)
    $stop = $today.Date.AddDays(-1)
    while ($d -le $stop) {
        if (Test-Workday $d) { $n++ }
        $d = $d.AddDays(1)
    }
    return $n
}

$script:FirstRun = $true
$script:ErrCount = 0
try { [System.IO.File]::WriteAllText((Join-Path $env:APPDATA 'WorkEncourager\tick_error.log'), '') } catch { }
$script:WeekNames = @('周日','周一','周二','周三','周四','周五','周六')

function Update-UI {
    $realNow = Get-Date
    if ($Clock -ne '') {
        $hh = 0; $mm = 0
        $parts = $Clock.Split(':')
        $hh = [int]$parts[0]; if ($parts.Count -gt 1) { $mm = [int]$parts[1] }
        $now = $realNow.Date.AddHours($hh).AddMinutes($mm)
    } else {
        $now = $realNow
    }

    $day0  = $now.Date
    $start = $day0.AddHours($script:StartH).AddMinutes($script:StartM)
    $end   = $day0.AddHours($script:EndH).AddMinutes($script:EndM)
    $totalSec = ($end - $start).TotalSeconds
    $isWork = Test-Workday $day0

    # 各节点的到达时刻（用于气泡文案）
    $script:MTime = @{}
    foreach ($mm in $script:Milestones) {
        if ($script:Wage -gt 0) {
            $script:MTime[[int]$mm.Amt] = $start.AddSeconds($totalSec * ($mm.Amt / $script:Wage)).ToString('HH:mm')
        } else {
            $script:MTime[[int]$mm.Amt] = '--:--'
        }
    }

    if ((-not $isWork) -and (-not $script:CountWeekend)) {
        $income = 0.0; $phase = 'rest'
    } elseif ($now -lt $start) {
        $income = 0.0; $phase = 'before'
    } elseif ($now -ge $end) {
        $income = $script:Wage; $phase = 'done'
    } else {
        $income = $script:Wage * (($now - $start).TotalSeconds) / $totalSec
        $phase = 'run'
    }

    $pct = 0.0
    if ($script:Wage -gt 0) { $pct = $income / $script:Wage }
    if ($pct -gt 1) { $pct = 1 }; if ($pct -lt 0) { $pct = 0 }
    $script:LastIncome = $income

    # 大数字
    $script:UI['MoneyText'].Text = ('{0:N5}' -f $income)

    # 时薪
    $hourly = 0.0
    if (($end - $start).TotalHours -gt 0) { $hourly = $script:Wage / ($end - $start).TotalHours }

    # 状态 / 副标题 / 计时
    switch ($phase) {
        'run' {
            $script:UI['StatusText'].Text = $script:WeekNames[[int]$day0.DayOfWeek] + ' · 搬砖中 (๑•̀ㅂ•́)و'
            $script:UI['SubLine'].Text    = ('时薪 ¥{0:N2} · 进度 {1:N1}%' -f $hourly, ($pct * 100))
            $script:UI['Dot'].Opacity     = 1.0
        }
        'before' {
            $script:UI['StatusText'].Text = $script:WeekNames[[int]$day0.DayOfWeek] + ' · 未开工 (´-ω-`)'
            $script:UI['SubLine'].Text    = ('还没到点，{0:00}:{1:00} 才开工，再眯一会' -f $script:StartH, $script:StartM)
            $script:UI['Dot'].Opacity     = 0.45
        }
        'done' {
            $script:UI['StatusText'].Text = $script:WeekNames[[int]$day0.DayOfWeek] + ' · 已收工 (๑˃̵ᴗ˂̵)و'
            $script:UI['SubLine'].Text    = ('时薪 ¥{0:N2} · 今日 {1:N0} 全部到账' -f $hourly, $script:Wage)
            $script:UI['Dot'].Opacity     = 0.75
        }
        'rest' {
            $script:UI['StatusText'].Text = $script:WeekNames[[int]$day0.DayOfWeek] + ' · 不打工 ヾ(￣▽￣)'
            $script:UI['SubLine'].Text    = '今天休息，一分钱不挣，安心躺平 (´｡• ᵕ •｡`)'
            $script:UI['Dot'].Opacity     = 0.45
        }
    }

    # 计时行
    if ($phase -eq 'run') {
        $span = $end - $now
        $script:UI['LeftTime'].Text = ('剩余 {0:00}:{1:00}:{2:00} · {3:N2} 元在路上跑' -f $span.Hours, $span.Minutes, $span.Seconds, ($script:Wage - $income))
    } elseif ($phase -eq 'before') {
        $span = $start - $now
        $script:UI['LeftTime'].Text = ('距开工 {0:00}:{1:00}:{2:00}，急什么' -f $span.Hours, $span.Minutes, $span.Seconds)
    } elseif ($phase -eq 'done') {
        $script:UI['LeftTime'].Text = ('今天的 {0:N0} 已经落袋，撒花 ✿' -f $script:Wage)
    } else {
        $script:UI['LeftTime'].Text = '休息日，好好躺，别想工位'
    }

    # 进度条
    $trackW = $script:UI['Track'].ActualWidth
    if ($trackW -le 0) { $trackW = ($script:WinW - 44) }
    $script:UI['Fill'].Width = [math]::Round(($trackW * $pct), 1)

    # 节点小卡
    foreach ($c in $script:Chips) {
        Set-ChipState $c ($income -ge $c.Amt) $false
    }

    # 当日节点触发
    $key = $day0.ToString('yyyy-MM-dd')
    if ($script:FiredDate -ne $key) {
        $script:FiredDate = $key
        $script:Fired = @()
        Save-State
    }
    if ($script:FirstRun) {
        $script:FirstRun = $false
        $reach = @($script:Milestones | Where-Object { $income -ge $_.Amt })
        if ($reach.Count -gt 0) {
            $top = $reach[$reach.Count - 1]
            if ($script:Fired -notcontains ([int]$top.Amt)) {
                foreach ($m in $reach) { if ($script:Fired -notcontains ([int]$m.Amt)) { $script:Fired += [int]$m.Amt } }
                Save-State
                Show-Toast $top.Title ('补发 · 到这时候你已经攒到 ¥' + $top.Amt) ([string]::Format('{0:N0}', $top.Amt))
                Play-Ding
            }
        }
    }

    foreach ($m in $script:Milestones) {
        if (($income -ge $m.Amt) -and ($script:Fired -notcontains ([int]$m.Amt))) {
            $script:Fired += [int]$m.Amt
            Save-State
            Show-Toast $m.Title ('达成 ¥' + $m.Amt + ' · ' + $script:MTime[[int]$m.Amt] + ' · ' + $m.Sub) ([string]::Format('{0:N0}', $m.Amt))
            Play-Ding
        }
    }

    # 本月
    $mDays = Get-MonthWorkdays $day0
    $mSum  = ($mDays * $script:Wage) + $income
    $script:UI['MonthDays'].Text  = ('本月已打工 {0} 天' -f $mDays)
    $script:UI['MonthMoney'].Text = ('¥{0:N2}' -f $mSum)
    $script:UI['MonthTier'].Text  = ('相当于 · ' + (Get-TierText $mSum))

    # 位置存档（每 3 秒）
    if (((Get-Date) - $script:LastPosSave).TotalSeconds -gt 3) {
        $script:LastPosSave = Get-Date
        if (($w.Left -ne $script:Left) -or ($w.Top -ne $script:Top)) {
            $script:Left = $w.Left
            $script:Top  = $w.Top
            Save-State
        }
    }
}

# ---------------------------- 启动 ----------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({
    try { Update-UI } catch {
        try {
            $script:ErrCount++
            if ($script:ErrCount -le 3) {
                $msg = (Get-Date).ToString('s') + ' | ' + $_.Exception.GetType().Name + ' | ' + $_.Exception.Message + ' | cmd=' + $_.InvocationInfo.MyCommand + ' | line=' + $_.InvocationInfo.ScriptLineNumber + ' | ' + ($_.InvocationInfo.PositionMessage -replace "`r`n", ' ') + ' | stack=' + ($_.ScriptStackTrace -replace "`r`n", ' / ')
                [System.IO.File]::AppendAllText((Join-Path $env:APPDATA 'WorkEncourager\tick_error.log'), ($msg + "`r`n"))
            }
        } catch { }
    }
})
$timer.Start()

$w.Add_Closed({
    $timer.Stop()
    $script:Left = $w.Left
    $script:Top  = $w.Top
    Save-State
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
})

$w.Add_Loaded({
    Update-Holidays
    Update-UI
    if ($script:DesktopMode) { [void](Enable-DesktopMode) }
    if ($TestToast) {
        $script:ToastQueue = @($script:Milestones)
        $qTimer = New-Object Windows.Threading.DispatcherTimer
        $qTimer.Interval = [TimeSpan]::FromMilliseconds(760)
        $qTimer.Add_Tick({
            if ($script:ToastQueue.Count -gt 0) {
                $m = $script:ToastQueue[0]
                $script:ToastQueue = @($script:ToastQueue | Select-Object -Skip 1)
                Show-Toast $m.Title ('达成 ¥' + $m.Amt + ' · ' + $script:MTime[[int]$m.Amt] + ' · ' + $m.Sub) ([string]::Format('{0:N0}', $m.Amt))
                Play-Ding
            } else {
                $this.Stop()
            }
        })
        $qTimer.Start()
    }
})

[void]$w.ShowDialog()
