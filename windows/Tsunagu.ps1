<#
  Tsunagu for Windows
  Tailscale の端末一覧をタスクバーの通知領域に出し、リモートデスクトップ・画面共有・SSH・Taildrop を 1 クリックで行う。
  端末の情報は Tailscale 本体の CLI (`status --json`) からメニューを開くたびに取り直す。常駐中は何もしない。

  起動:      powershell -NoProfile -ExecutionPolicy Bypass -File Tsunagu.ps1
  動作確認:  powershell -NoProfile -ExecutionPolicy Bypass -File Tsunagu.ps1 -Dump
#>
param([switch]$Dump)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptPath = $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- Tailscale CLI

function Get-TailscaleExe {
    $c = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $c) { return $c }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function ConvertTo-Device($d) {
    $dns = ([string]$d.DNSName).Trim('.')
    if (-not $dns) { return $null }
    $ips = @($d.TailscaleIPs)
    $ip = ($ips | Where-Object { $_ -notmatch ':' } | Select-Object -First 1)
    if (-not $ip) { $ip = $ips | Select-Object -First 1 }
    $seen = $null
    if ($d.LastSeen) {
        $t = [datetime]$d.LastSeen
        if ($t.Year -gt 1) { $seen = $t.ToLocalTime() }   # 0001-01-01 は「値なし」
    }
    [pscustomobject]@{
        Name            = $dns.Split('.')[0]
        DnsName         = $dns
        Ip              = [string]$ip
        Os              = ([string]$d.OS).ToLowerInvariant()
        Online          = [bool]$d.Online
        LastSeen        = $seen
        CanReceiveFiles = ($d.TaildropTarget -eq 1)   # 1 = 送信可能
    }
}

function Get-Tailnet {
    $t = [pscustomobject]@{ Running = $false; Me = $null; Peers = @(); Error = $null }
    $exe = Get-TailscaleExe
    if (-not $exe) { $t.Error = 'Tailscale が見つかりません'; return $t }
    try {
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $json = (& $exe status --json 2>$null) -join "`n" | ConvertFrom-Json
        [Console]::OutputEncoding = $prev
    } catch { $t.Error = 'Tailscale から状態を取得できません'; return $t }
    if (-not $json) { $t.Error = 'Tailscale から状態を取得できません'; return $t }
    $t.Running = ($json.BackendState -eq 'Running')
    if ($json.Self) { $t.Me = ConvertTo-Device $json.Self }
    if ($json.Peer) {
        $t.Peers = @($json.Peer.PSObject.Properties | ForEach-Object { ConvertTo-Device $_.Value } |
            Where-Object { $_ } | Sort-Object Name -CaseSensitive)
    }
    return $t
}

# ---------------------------------------------------------------- 小物

function Format-Relative([datetime]$t) {
    $s = (Get-Date) - $t
    if ($s.TotalMinutes -lt 1) { return 'たった今' }
    if ($s.TotalHours -lt 1)   { return "$([int][math]::Floor($s.TotalMinutes))分前" }
    if ($s.TotalDays -lt 1)    { return "$([int][math]::Floor($s.TotalHours))時間前" }
    if ($s.TotalDays -lt 30)   { return "$([int][math]::Floor($s.TotalDays))日前" }
    if ($s.TotalDays -lt 365)  { return "$([int][math]::Floor($s.TotalDays / 30))か月前" }
    return "$([int][math]::Floor($s.TotalDays / 365))年前"
}

function Open-Target([string]$target, [string]$arguments) {
    try {
        if ($arguments) { Start-Process -FilePath $target -ArgumentList $arguments -ErrorAction Stop }
        else { Start-Process -FilePath $target -ErrorAction Stop }
        return $true
    } catch { return $false }
}

function Show-Warning([string]$text, [string]$title = 'Tsunagu') {
    [void][System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', 'Warning')
}

function Test-LightTheme {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).SystemUsesLightTheme
    return ($v -eq 1)
}

# macOS 版の point.3.connected.trianglepath.dotted に似た「3 点を点線で結んだ」アイコンを描く
function New-TrayIcon([bool]$busy = $false) {
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width * 2
    $fg = if (Test-LightTheme) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [single]$size
    $pts = @(
        (New-Object System.Drawing.PointF ($s * 0.22), ($s * 0.30)),
        (New-Object System.Drawing.PointF ($s * 0.78), ($s * 0.30)),
        (New-Object System.Drawing.PointF ($s * 0.50), ($s * 0.78))
    )
    $pen = New-Object System.Drawing.Pen $fg, ([math]::Max(1, $s / 16))
    $pen.DashStyle = 'Dot'
    $g.DrawLine($pen, $pts[0], $pts[1]); $g.DrawLine($pen, $pts[0], $pts[2]); $g.DrawLine($pen, $pts[1], $pts[2])
    $r = $s * 0.13
    $dotColor = if ($busy) { [System.Drawing.Color]::FromArgb(0x30, 0xA0, 0xFF) } else { $fg }
    $brush = New-Object System.Drawing.SolidBrush $dotColor
    foreach ($p in $pts) { $g.FillEllipse($brush, $p.X - $r, $p.Y - $r, $r * 2, $r * 2) }
    $pen.Dispose(); $brush.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

function New-Dot([bool]$online) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $c = if ($online) { [System.Drawing.Color]::FromArgb(0x34, 0xC7, 0x59) } else { [System.Drawing.Color]::FromArgb(0x9A, 0x9A, 0x9A) }
    $b = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($b, 4, 4, 8, 8)
    $b.Dispose(); $g.Dispose()
    return $bmp
}
$DotOn = New-Dot $true
$DotOff = New-Dot $false

# ---------------------------------------------------------------- Windows 起動時に開く

$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
# conhost --headless を挟むと、起動時にコンソール窓が一瞬出るのを防げる
$RunCommand = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

function Get-AutoStart {
    $v = (Get-ItemProperty $RunKey -Name Tsunagu -ErrorAction SilentlyContinue).Tsunagu
    return ($v -eq $RunCommand)
}
function Set-AutoStart([bool]$on) {
    if ($on) { Set-ItemProperty $RunKey -Name Tsunagu -Value $RunCommand }
    else { Remove-ItemProperty $RunKey -Name Tsunagu -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- 操作

function Start-Ssh($d) {
    if (-not (Open-Target 'wt.exe' "ssh $($d.DnsName)")) { [void](Open-Target 'cmd.exe' "/k ssh $($d.DnsName)") }
}

function Test-Port([string]$hostName, [int]$port, [int]$timeoutMs = 1500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return ($c.ConnectAsync($hostName, $port).Wait($timeoutMs) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}

# ---- RustDesk (画面共有の第一候補)

function Get-RustDeskExe {
    @(
        (Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\RustDesk\rustdesk.exe')   # ポータブル版 (管理者権限なしで置ける)
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# 端末名 → RustDesk ID の対応表 (任意)。IP 直接接続ができない端末だけ書けばよい。
# 例: %APPDATA%\Tsunagu\rustdesk-ids.json に {"mac-mini": "123456789"}
function Get-RustDeskId([string]$name) {
    $f = Join-Path $env:APPDATA 'Tsunagu\rustdesk-ids.json'
    if (-not (Test-Path $f)) { return $null }
    try { $map = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json; return $map.$name } catch { return $null }
}

function Start-RustDesk($d) {
    $exe = Get-RustDeskExe
    if (-not $exe) { Show-Warning 'RustDesk が見つかりません。'; return }
    # Tailscale 内なら IP 直接接続 (ポート 21118) が使える。中継サーバーを通らないので速い
    if (Test-Port $d.Ip 21118) { [void](Open-Target $exe "--connect $($d.Ip)"); return }
    $id = Get-RustDeskId $d.Name
    if ($id) { [void](Open-Target $exe "--connect $id"); return }
    [void][System.Windows.Forms.MessageBox]::Show(
        "$($d.Name) に RustDesk の IP 直接接続ができません。`n`n" +
        "接続先の RustDesk で次を設定してください:`n  設定 → セキュリティ → 「IP直接アクセスを有効にする」をオン`n`n" +
        "または %APPDATA%\Tsunagu\rustdesk-ids.json に`n  {`"$($d.Name)`": `"<RustDesk ID>`"}`nと書くと ID で接続します。",
        'Tsunagu', 'OK', 'Information')
}

# ---- VNC (macOS の画面共有に直接つなぐ)

function Start-Vnc($d) {
    # vnc:// を受けるアプリが登録されているときだけ URL で開く
    # (未登録のまま開くと Windows の「アプリを探す」画面が出てしまう)
    if (Test-Path 'Registry::HKEY_CLASSES_ROOT\vnc\shell\open\command') {
        if (Open-Target "vnc://$($d.DnsName)") { return }
    }
    $viewers = @(
        (Join-Path $env:ProgramFiles 'TigerVNC\vncviewer.exe'),
        (Join-Path $env:ProgramFiles 'RealVNC\VNC Viewer\vncviewer.exe'),
        (Join-Path $env:ProgramFiles 'TightVNC\tvnviewer.exe'),
        (Join-Path $env:ProgramFiles 'uvnc bvba\UltraVNC\vncviewer.exe')
    )
    $v = $viewers | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($v) { [void](Open-Target $v $d.DnsName); return }
    Show-Warning "VNC ビューアが見つかりません。`nTigerVNC などを入れると、Mac の画面共有に接続できます。`n`n接続先: $($d.DnsName)"
}

function Open-Tailscale {
    $p = Join-Path $env:ProgramFiles 'Tailscale\tailscale-ipn.exe'
    if (Test-Path $p) { [void](Open-Target $p) } else { [void](Open-Target 'https://login.tailscale.com/admin/machines') }
}

$script:Sending = $null
function Send-Files($d) {
    if ($script:Sending) { Show-Warning '前の送信が終わるまでお待ちください'; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true   # フォルダは Tailscale 本体が非対応
    $dlg.Title = "$($d.Name) に送るファイルを選択"
    if ($dlg.ShowDialog() -ne 'OK' -or $dlg.FileNames.Count -eq 0) { return }
    $files = @($dlg.FileNames)
    $errFile = [IO.Path]::GetTempFileName()
    $argList = @('file', 'cp') + ($files | ForEach-Object { '"' + $_ + '"' }) + @("$($d.Ip):")
    $proc = Start-Process -FilePath (Get-TailscaleExe) -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardError $errFile
    $script:Sending = [pscustomobject]@{ Proc = $proc; Err = $errFile; Device = $d; Count = $files.Count }
    Set-TrayIcon $true
    $tray.Text = 'Tsunagu - 送信中…'
    $sendTimer.Start()
}

function Complete-Send {
    $s = $script:Sending
    if (-not $s -or -not $s.Proc.HasExited) { return }
    $sendTimer.Stop()
    $script:Sending = $null
    Set-TrayIcon $false
    $tray.Text = 'Tsunagu'
    $err = (Get-Content $s.Err -Raw -ErrorAction SilentlyContinue)
    Remove-Item $s.Err -ErrorAction SilentlyContinue
    if ($s.Proc.ExitCode -eq 0) {
        $tray.ShowBalloonTip(3000, '送信完了', "$($s.Device.Name) に $($s.Count) 件送りました", 'Info')
    } else {
        Show-Warning ([string]$err).Trim() "$($s.Device.Name) へ送信できませんでした"
    }
}

# 操作はメニュー項目の Tag に入れておき、ここでまとめて実行する
function Invoke-MenuAction($tag) {
    $d = $tag.Device
    switch ($tag.Action) {
        'rdp'       { [void](Open-Target 'mstsc.exe' "/v:$($d.DnsName)") }
        'rustdesk'  { Start-RustDesk $d }
        'vnc'       { Start-Vnc $d }
        'ssh'       { Start-Ssh $d }
        'taildrop'  { Send-Files $d }
        'browser'   { [void](Open-Target "https://$($d.DnsName)") }
        'copy'      { [System.Windows.Forms.Clipboard]::SetText($tag.Text) }
        'tailscale' { Open-Tailscale }
        'autostart' { Set-AutoStart (-not (Get-AutoStart)) }
        'quit'      { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }
    }
}

# ---------------------------------------------------------------- メニュー

$OnClick = { Invoke-MenuAction $this.Tag }

function New-Item2([string]$text, [hashtable]$tag, $image) {
    $i = New-Object System.Windows.Forms.ToolStripMenuItem $text
    if ($image) { $i.Image = $image }
    if ($tag) { $i.Tag = $tag; $i.add_Click($OnClick) }
    return $i
}
function New-Label([string]$text) {
    $i = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $i.Enabled = $false
    return $i
}
function New-Sep { New-Object System.Windows.Forms.ToolStripSeparator }

function Add-SubItems($item, $d) {
    $dd = $item.DropDownItems
    if ($d.Online) {
        $hasRustDesk = [bool](Get-RustDeskExe)
        if ($hasRustDesk -and $d.Os -ne 'ios') { [void]$dd.Add((New-Item2 '画面共有 (RustDesk)' @{ Action = 'rustdesk'; Device = $d })) }
        switch ($d.Os) {
            'macos'   { [void]$dd.Add((New-Item2 '画面共有 (VNC)' @{ Action = 'vnc'; Device = $d }))
                        [void]$dd.Add((New-Item2 'SSH (ターミナル)' @{ Action = 'ssh'; Device = $d })) }
            'windows' { [void]$dd.Add((New-Item2 'リモートデスクトップ' @{ Action = 'rdp'; Device = $d }))
                        [void]$dd.Add((New-Item2 'SSH (ターミナル)' @{ Action = 'ssh'; Device = $d })) }
            'ios'     { }
            default   { [void]$dd.Add((New-Item2 'SSH (ターミナル)' @{ Action = 'ssh'; Device = $d })) }
        }
        if ($d.CanReceiveFiles) { [void]$dd.Add((New-Item2 'ファイルを送る (Taildrop)…' @{ Action = 'taildrop'; Device = $d })) }
        if ($d.Os -ne 'ios') { [void]$dd.Add((New-Item2 'ブラウザで開く' @{ Action = 'browser'; Device = $d })) }
        [void]$dd.Add((New-Sep))
    }
    [void]$dd.Add((New-Item2 "IP をコピー  $($d.Ip)" @{ Action = 'copy'; Text = $d.Ip }))
    [void]$dd.Add((New-Item2 "名前をコピー  $($d.DnsName)" @{ Action = 'copy'; Text = $d.DnsName }))
}

function Build-Menu($items, $t) {
    $items.Clear()
    if ($t.Error) { [void]$items.Add((New-Label $t.Error)) }
    elseif (-not $t.Running) { [void]$items.Add((New-Label 'Tailscale は停止中です')) }

    $online = @($t.Peers | Where-Object { $_.Online })
    $offline = @($t.Peers | Where-Object { -not $_.Online })

    foreach ($d in $online) {
        $item = New-Item2 $d.Name $null $DotOn
        Add-SubItems $item $d
        [void]$items.Add($item)
    }
    if ($online.Count -eq 0 -and -not $t.Error -and $t.Running) { [void]$items.Add((New-Label 'オンラインの端末はありません')) }

    if ($offline.Count -gt 0) {
        [void]$items.Add((New-Sep))
        [void]$items.Add((New-Label 'オフライン'))
        foreach ($d in $offline) {
            $title = $d.Name
            if ($d.LastSeen) { $title += "  $(Format-Relative $d.LastSeen)" }
            $item = New-Item2 $title $null $DotOff
            Add-SubItems $item $d
            [void]$items.Add($item)
        }
    }

    [void]$items.Add((New-Sep))
    if ($t.Me) { [void]$items.Add((New-Item2 "この PC: $($t.Me.Name)  $($t.Me.Ip)" @{ Action = 'copy'; Text = $t.Me.Ip })) }
    [void]$items.Add((New-Item2 'Tailscale を開く' @{ Action = 'tailscale' }))
    $auto = New-Item2 'Windows 起動時に開く' @{ Action = 'autostart' }
    $auto.Checked = Get-AutoStart
    [void]$items.Add($auto)
    [void]$items.Add((New-Item2 'Tsunagu を終了' @{ Action = 'quit' }))
}

function Write-MenuDump($items, [string]$indent = '') {
    foreach ($i in $items) {
        $text = if ($i -is [System.Windows.Forms.ToolStripSeparator]) { '────' } else { $i.Text }
        $suffix = if ($i.Enabled) { '' } else { '  (見出し)' }
        Write-Output ($indent + $text + $suffix)
        if ($i -is [System.Windows.Forms.ToolStripMenuItem] -and $i.HasDropDownItems) { Write-MenuDump $i.DropDownItems ($indent + '    ') }
    }
}

# ---------------------------------------------------------------- 起動

if ($Dump) {
    # 動作確認用: 実際のメニューと同じ内容を文字で出して終了する
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    Build-Menu $m.Items (Get-Tailnet)
    Write-MenuDump $m.Items
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\Tsunagu', [ref]$createdNew)
if (-not $createdNew) { exit 0 }   # 二重起動しない

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('…')   # 空だと開かないので仮の項目を入れておく
$menu.add_Opening({ param($s, $e) Set-TrayIcon $false; Build-Menu $menu.Items (Get-Tailnet); $e.Cancel = $false })

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Tsunagu'
$tray.ContextMenuStrip = $menu
function Set-TrayIcon([bool]$busy) {
    if ($script:Sending -and -not $busy) { $busy = $true }
    $old = $tray.Icon
    $tray.Icon = New-TrayIcon $busy
    if ($old) { $old.Dispose() }
}
Set-TrayIcon $false
$tray.Visible = $true

# 左クリックでも右クリックと同じメニューを開く
$showMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
$tray.add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left') { [void]$showMenu.Invoke($tray, $null) } })

$sendTimer = New-Object System.Windows.Forms.Timer
$sendTimer.Interval = 500
$sendTimer.add_Tick({ Complete-Send })

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
}
