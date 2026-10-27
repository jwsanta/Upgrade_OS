<#
.SYNOPSIS
    Windows Server 업그레이드 전 구성 인벤토리 추출

.DESCRIPTION
    In-place 업그레이드 또는 신규 OS 재구성 대비 현재 서버 구성을 CSV 및 원본 설정 파일로 추출
    추출 항목
      01. 시스템 정보 (에디션, 설치 유형, OS 언어, 도메인 역할)
      02. 설치 프로그램 (MSI/EXE 구분, ProductCode, 원본 패키지 정보)
      03. 핫픽스
      04. 역할/기능
      05. 서비스 (비 Microsoft 서비스 레지스트리 백업 포함)
      06. 예약 작업 (XML 백업 포함)
      07. 시스템 환경변수 (PATH 항목별 존재 여부 포함)
      08. 네트워크 (IP, DNS, 고정 경로, hosts, WinHTTP 프록시)
      09. 방화벽 (정책 전체 백업 포함)
      10. 인증서 (LocalMachine 저장소)
      11. ODBC (DSN, 드라이버)
      12. 공유 폴더 (공유 권한 포함)
      13. 로컬 사용자/그룹
      14. 보안 정책 (secedit, auditpol, gpresult, SCHANNEL, LSA)
      15. 디스크/볼륨
      16. 데이터 드라이브 NTFS 권한
      17. IIS 설정
      18. 레지스트리 (시작 프로그램, HKLM\SOFTWARE 벤더 키)

.PARAMETER OutputRoot
    결과 저장 상위 경로. 기본값 C:\PreUpgradeInventory

.PARAMETER AclDepth
    시스템 드라이브 외 고정 드라이브의 NTFS 권한 수집 깊이
    0: 드라이브 루트만, 1: 루트 + 1단계 하위 폴더 (기본값), 최대 3

.PARAMETER SkipRegistryExport
    HKLM\SOFTWARE 벤더 키 reg export 생략

.PARAMETER SkipZip
    결과 폴더 ZIP 압축 생략

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Get-PreUpgradeInventory.ps1

.EXAMPLE
    .\Get-PreUpgradeInventory.ps1 -OutputRoot D:\Inventory -AclDepth 2

.NOTES
    Author   : jongwon park
    Version  : 1.0
    요구사항 : Windows PowerShell 5.1, 관리자 권한, 64비트 PowerShell
    대상 OS  : Windows Server 2016 / 2019 / 2022
    시스템 변경 없음 (조회 및 파일 출력만 수행)
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $env:SystemDrive 'PreUpgradeInventory'),

    [ValidateRange(0, 3)]
    [int]$AclDepth = 1,

    [switch]$SkipRegistryExport,

    [switch]$SkipZip
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

#region 사전 점검
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '관리자 권한으로 실행 필요' -ForegroundColor Red
    exit 1
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host '64비트 PowerShell로 실행 필요 (32비트 실행 시 레지스트리 리디렉션으로 누락 발생)' -ForegroundColor Red
    exit 1
}
#endregion

#region 초기화
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir    = Join-Path $OutputRoot ('{0}_{1}' -f $env:COMPUTERNAME, $Timestamp)
$CfgDir    = Join-Path $OutDir 'Config'
$RegDir    = Join-Path $OutDir 'Registry'
$TaskDir   = Join-Path $OutDir 'ScheduledTasks'
foreach ($d in @($OutDir, $CfgDir, $RegDir, $TaskDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$LogFile             = Join-Path $OutDir '_run.log'
$script:Summary      = New-Object System.Collections.Generic.List[object]
$script:SectionCount = 0
$script:Ctx          = @{}
#endregion

#region 공통 함수
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Save-Csv {
    param(
        [object[]]$Data,
        [Parameter(Mandatory)]
        [string]$Name
    )
    $path  = Join-Path $OutDir $Name
    $items = @($Data | Where-Object { $null -ne $_ })
    if ($items.Count -gt 0) {
        $items | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    } else {
        New-Item -ItemType File -Path $path -Force | Out-Null
    }
    $script:SectionCount += $items.Count
}

function Export-RegKey {
    param(
        [string]$Key,
        [string]$File
    )
    $out = & reg.exe export $Key $File /y 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log ('reg export 실패: {0} ({1})' -f $Key, (($out | ForEach-Object { $_.ToString() }) -join ' ')) 'WARN'
    }
}

function Get-SafeName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Name.ToCharArray()) {
        if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

function Get-ExePath {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim()) -replace '^\\\?\?\\', ''
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($c, '(?i)^.+?\.(exe|com|bat|cmd)')
    if ($m.Success) { return $m.Value }
    return ($c -split ' ')[0]
}

function ConvertTo-SquishedGuid {
    # MSI ProductCode -> Windows Installer 내부 레지스트리 키 형식 변환
    param([string]$Guid)
    $g = $Guid.Trim('{', '}').Replace('-', '').ToUpper()
    if ($g.Length -ne 32) { return $null }
    $p1 = -join ($g.Substring(0, 8).ToCharArray()[7..0])
    $p2 = -join ($g.Substring(8, 4).ToCharArray()[3..0])
    $p3 = -join ($g.Substring(12, 4).ToCharArray()[3..0])
    $p4 = ''
    for ($i = 16; $i -lt 32; $i += 2) {
        $p4 += $g.Substring($i + 1, 1) + $g.Substring($i, 1)
    }
    return $p1 + $p2 + $p3 + $p4
}

function Get-InstallerHint {
    # 제거 명령 경로 기반 설치 엔진 판별. MSI 외 항목은 추정
    param($Entry)
    $u = [string]$Entry.UninstallString
    if ($Entry.WindowsInstaller -eq 1 -or $u -match '(?i)msiexec') { return 'MSI' }
    if ([string]::IsNullOrWhiteSpace($u))                          { return 'Unknown' }
    if ($u -match '(?i)\\unins\d{3}\.exe')                         { return 'EXE-InnoSetup(추정)' }
    if ($u -match '(?i)InstallShield Installation Information')    { return 'EXE-InstallShield(추정)' }
    if ($u -match '(?i)\\Package Cache\\')                         { return 'EXE-WiXBurn(추정)' }
    if ($u -match '(?i)\\uninst(all)?\.exe')                       { return 'EXE-NSIS(추정)' }
    return 'EXE-Unknown'
}

function Invoke-Section {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    Write-Log ('[{0}] 시작' -f $Name)
    $script:SectionCount = 0
    $Error.Clear()
    $status = 'OK'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body | Out-Null
    } catch {
        $status = 'FAIL'
        Write-Log ('[{0}] 실패: {1}' -f $Name, $_.Exception.Message) 'ERROR'
    }
    $sw.Stop()
    $warnCount = $Error.Count
    if ($status -eq 'OK' -and $warnCount -gt 0) {
        $status = 'WARN'
        $Error | Select-Object -First 5 | ForEach-Object {
            Write-Log ('[{0}] 경고: {1}' -f $Name, $_.ToString()) 'WARN'
        }
    }
    $script:Summary.Add([pscustomobject]@{
        Section  = $Name
        Status   = $status
        Items    = $script:SectionCount
        Warnings = $warnCount
        Seconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    })
    Write-Log ('[{0}] 종료 ({1}, {2}건, {3}초)' -f $Name, $status, $script:SectionCount, [Math]::Round($sw.Elapsed.TotalSeconds, 1))
}
#endregion

Write-Log ('인벤토리 추출 시작: {0}, OutputRoot={1}, AclDepth={2}' -f $env:COMPUTERNAME, $OutputRoot, $AclDepth)

#region 01. 시스템 정보
Invoke-Section '01_System' {
    $os       = Get-CimInstance Win32_OperatingSystem
    $cs       = Get-CimInstance Win32_ComputerSystem
    $cpu      = @(Get-CimInstance Win32_Processor)
    $cv       = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ndp      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Ignore
    $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)

    $osLang = try { ([Globalization.CultureInfo]::GetCultureInfo([int]$os.OSLanguage)).Name } catch { [string]$os.OSLanguage }
    $sysLocale = try { (Get-WinSystemLocale).Name } catch { '' }

    $roleNames = @{ 0 = 'StandaloneWorkstation'; 1 = 'MemberWorkstation'; 2 = 'StandaloneServer'; 3 = 'MemberServer'; 4 = 'BackupDC'; 5 = 'PrimaryDC' }

    if ($cs.AutomaticManagedPagefile) {
        $pageFile = '자동 관리'
    } else {
        $pageFile = (@(Get-CimInstance Win32_PageFileSetting) | ForEach-Object {
            '{0} ({1}-{2}MB)' -f $_.Name, $_.InitialSize, $_.MaximumSize
        }) -join '; '
    }

    $script:Ctx.OSCaption         = $os.Caption
    $script:Ctx.IsEvaluation      = ([string]$cv.EditionID -like '*Eval*')
    $script:Ctx.InstallationType  = $cv.InstallationType
    $script:Ctx.OSLanguage        = $osLang
    $script:Ctx.IsDC              = ($cs.DomainRole -ge 4)
    $script:Ctx.SystemDriveFreeGB = [Math]::Round($sysDrive.FreeSpace / 1GB, 1)

    $row = [pscustomobject]@{
        HostName          = $env:COMPUTERNAME
        Domain            = $cs.Domain
        PartOfDomain      = $cs.PartOfDomain
        DomainRole        = $roleNames[[int]$cs.DomainRole]
        OSCaption         = $os.Caption
        EditionID         = $cv.EditionID
        IsEvaluation      = $script:Ctx.IsEvaluation
        InstallationType  = $cv.InstallationType
        OSVersion         = $os.Version
        Build             = '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR
        OSLanguage        = $osLang
        MUILanguages      = ($os.MUILanguages -join ';')
        SystemLocale      = $sysLocale
        TimeZone          = (Get-TimeZone).Id
        InstallDate       = $os.InstallDate
        LastBootUpTime    = $os.LastBootUpTime
        Manufacturer      = $cs.Manufacturer
        Model             = $cs.Model
        CPU               = $cpu[0].Name
        Sockets           = $cpu.Count
        LogicalProcessors = $cs.NumberOfLogicalProcessors
        MemoryGB          = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        SystemDrive       = $env:SystemDrive
        SystemDriveSizeGB = [Math]::Round($sysDrive.Size / 1GB, 1)
        SystemDriveFreeGB = $script:Ctx.SystemDriveFreeGB
        PageFile          = $pageFile
        DotNet4Release    = $ndp.Release
        PSVersion         = $PSVersionTable.PSVersion.ToString()
    }
    Save-Csv -Data $row -Name '01_System.csv'
}
#endregion

#region 02. 설치 프로그램
Invoke-Section '02_Software' {
    $sources = New-Object System.Collections.Generic.List[object]
    $sources.Add(@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = 'Machine'; Arch = 'x64' })
    $sources.Add(@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine'; Arch = 'x86' })

    # 사용자 단위 설치 (현재 로드된 사용자 하이브만 대상)
    foreach ($u in Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction Ignore) {
        if ($u.PSChildName -match '^S-1-5-21-[\d-]+$') {
            $sources.Add(@{
                Path  = 'Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Uninstall' -f $u.PSChildName
                Scope = 'User:{0}' -f $u.PSChildName
                Arch  = ''
            })
        }
    }

    $installProps = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    $classesProds = 'HKLM:\SOFTWARE\Classes\Installer\Products'
    $guidPattern  = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'

    $rows = foreach ($src in $sources) {
        if (-not (Test-Path $src.Path)) { continue }
        foreach ($key in Get-ChildItem $src.Path -ErrorAction Ignore) {
            $e = Get-ItemProperty $key.PSPath -ErrorAction Ignore
            if (-not $e -or [string]::IsNullOrWhiteSpace($e.DisplayName)) { continue }

            $productCode = ''; $localPkg = ''; $localPkgExists = ''; $pkgName = ''; $lastSource = ''
            if ($key.PSChildName -match $guidPattern) {
                $productCode = $key.PSChildName
                $sq = ConvertTo-SquishedGuid $productCode
                if ($sq) {
                    $ip = Get-ItemProperty ('{0}\{1}\InstallProperties' -f $installProps, $sq) -ErrorAction Ignore
                    if ($ip -and $ip.LocalPackage) {
                        $localPkg       = $ip.LocalPackage
                        $localPkgExists = Test-Path -LiteralPath $ip.LocalPackage
                    }
                    $sl = Get-ItemProperty ('{0}\{1}\SourceList' -f $classesProds, $sq) -ErrorAction Ignore
                    if ($sl) {
                        $pkgName    = $sl.PackageName
                        $lastSource = $sl.LastUsedSource
                    }
                }
            }

            [pscustomobject]@{
                Scope                = $src.Scope
                Arch                 = $src.Arch
                DisplayName          = $e.DisplayName
                DisplayVersion       = $e.DisplayVersion
                Publisher            = $e.Publisher
                InstallDate          = $e.InstallDate
                InstallLocation      = $e.InstallLocation
                InstallSource        = $e.InstallSource
                InstallerType        = Get-InstallerHint $e
                ProductCode          = $productCode
                OriginalPackageName  = $pkgName
                LastUsedSource       = $lastSource
                LocalPackage         = $localPkg
                LocalPackageExists   = $localPkgExists
                UninstallString      = $e.UninstallString
                QuietUninstallString = $e.QuietUninstallString
                SystemComponent      = ($e.SystemComponent -eq 1)
                IsUpdate             = ([bool]$e.ParentKeyName -or ([string]$e.ReleaseType -match 'Update|Hotfix'))
                EstimatedSizeMB      = if ($e.EstimatedSize) { [Math]::Round($e.EstimatedSize / 1024, 1) } else { '' }
                RegistryKey          = $key.Name
            }
        }
    }

    $rows = @($rows | Sort-Object DisplayName)
    $main = @($rows | Where-Object { -not $_.SystemComponent -and -not $_.IsUpdate })
    $script:Ctx.MsiCount = @($main | Where-Object { $_.InstallerType -eq 'MSI' }).Count
    $script:Ctx.ExeCount = @($main | Where-Object { $_.InstallerType -like 'EXE*' }).Count
    Save-Csv -Data $rows -Name '02_Software.csv'
}
#endregion

#region 03. 핫픽스
Invoke-Section '03_Hotfix' {
    $rows = Get-HotFix -ErrorAction Stop |
        Select-Object HotFixID, Description, InstalledOn, InstalledBy |
        Sort-Object InstalledOn
    Save-Csv -Data $rows -Name '03_Hotfix.csv'
}
#endregion

#region 04. 역할/기능
Invoke-Section '04_Features' {
    if (Get-Command Get-WindowsFeature -ErrorAction Ignore) {
        $rows = Get-WindowsFeature | Where-Object { $_.Installed } |
            Select-Object Name, DisplayName, FeatureType, Path, Depth
    } else {
        $rows = Get-WindowsOptionalFeature -Online | Where-Object { $_.State -eq 'Enabled' } |
            Select-Object @{ n = 'Name'; e = { $_.FeatureName } },
                          @{ n = 'DisplayName'; e = { '' } },
                          @{ n = 'FeatureType'; e = { 'Optional' } },
                          @{ n = 'Path'; e = { '' } },
                          @{ n = 'Depth'; e = { '' } }
    }
    Save-Csv -Data $rows -Name '04_Features.csv'
}
#endregion

#region 05. 서비스
Invoke-Section '05_Services' {
    $svcRegDir = Join-Path $RegDir 'Services'
    New-Item -ItemType Directory -Path $svcRegDir -Force | Out-Null

    $rows = foreach ($s in Get-CimInstance Win32_Service) {
        $reg     = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $s.Name) -ErrorAction Ignore
        $exe     = Get-ExePath $s.PathName
        $company = ''
        if ($exe -and (Test-Path -LiteralPath $exe -ErrorAction Ignore)) {
            $company = (Get-Item -LiteralPath $exe -ErrorAction Ignore).VersionInfo.CompanyName
        }
        $nonMs = -not ([string]$company -match 'Microsoft')

        # 비 Microsoft 서비스는 재등록 대비 서비스 레지스트리 키 백업
        if ($nonMs) {
            Export-RegKey ('HKLM\SYSTEM\CurrentControlSet\Services\{0}' -f $s.Name) (Join-Path $svcRegDir ((Get-SafeName $s.Name) + '.reg'))
        }

        [pscustomobject]@{
            Name             = $s.Name
            DisplayName      = $s.DisplayName
            State            = $s.State
            StartMode        = $s.StartMode
            DelayedAutoStart = ($reg.DelayedAutostart -eq 1)
            StartName        = $s.StartName
            PathName         = $s.PathName
            ExePath          = $exe
            CompanyName      = $company
            NonMicrosoft     = $nonMs
            DependsOn        = (@($reg.DependOnService) -join ';')
            Description      = $s.Description
        }
    }

    $script:Ctx.SvcLocalAccount = @($rows | Where-Object {
        $_.StartName -match '^\.\\' -or $_.StartName -like ('{0}\*' -f $env:COMPUTERNAME)
    }).Count
    Save-Csv -Data $rows -Name '05_Services.csv'
}
#endregion

#region 06. 예약 작업
Invoke-Section '06_ScheduledTasks' {
    $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }

    $rows = foreach ($t in $tasks) {
        $info    = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Ignore
        $xmlName = (Get-SafeName (($t.TaskPath.Trim('\') + '_' + $t.TaskName).Trim('_'))) + '.xml'
        try {
            Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop |
                Out-File -FilePath (Join-Path $TaskDir $xmlName) -Encoding Unicode
        } catch {
            Write-Log ('예약 작업 XML 추출 실패: {0}{1}' -f $t.TaskPath, $t.TaskName) 'WARN'
            $xmlName = ''
        }

        [pscustomobject]@{
            TaskPath         = $t.TaskPath
            TaskName         = $t.TaskName
            State            = $t.State
            RunAs            = $t.Principal.UserId
            LogonType        = $t.Principal.LogonType
            RunLevel         = $t.Principal.RunLevel
            Actions          = (@($t.Actions) | ForEach-Object { ('{0} {1}' -f $_.Execute, $_.Arguments).Trim() }) -join ' | '
            WorkingDirectory = (@($t.Actions) | ForEach-Object { $_.WorkingDirectory }) -join ' | '
            Triggers         = (@($t.Triggers) | ForEach-Object {
                                    ('{0} {1}' -f ($_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', ''), $_.StartBoundary).Trim()
                                }) -join ' | '
            LastRunTime      = $info.LastRunTime
            LastTaskResult   = $info.LastTaskResult
            NextRunTime      = $info.NextRunTime
            XmlFile          = $xmlName
        }
    }

    $script:Ctx.TaskPassword = @($rows | Where-Object { [string]$_.LogonType -eq 'Password' }).Count
    Save-Csv -Data $rows -Name '06_ScheduledTasks.csv'
}
#endregion

#region 07. 시스템 환경변수
Invoke-Section '07_Environment' {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
    try {
        $rows = foreach ($n in ($key.GetValueNames() | Sort-Object)) {
            $raw = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($n -eq 'Path') { $script:Ctx.MachinePath = [string]$raw }
            [pscustomobject]@{
                Name          = $n
                Kind          = $key.GetValueKind($n).ToString()
                RawValue      = $raw
                ExpandedValue = [Environment]::ExpandEnvironmentVariables([string]$raw)
            }
        }
    } finally {
        $key.Close()
    }
    Save-Csv -Data $rows -Name '07_Environment.csv'

    $order = 0
    $pathRows = foreach ($p in ([string]$script:Ctx.MachinePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $order++
        $expanded = [Environment]::ExpandEnvironmentVariables($p)
        [pscustomobject]@{
            Order    = $order
            Entry    = $p
            Expanded = $expanded
            Exists   = (Test-Path -LiteralPath $expanded -ErrorAction Ignore)
        }
    }
    Save-Csv -Data $pathRows -Name '07_Environment_Path.csv'

    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' (Join-Path $RegDir 'Environment.reg')
}
#endregion

#region 08. 네트워크
Invoke-Section '08_Network' {
    $ipIf = @{}
    foreach ($i in Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Ignore) { $ipIf[$i.InterfaceIndex] = $i }

    $rows = foreach ($cfg in Get-NetIPConfiguration -Detailed -ErrorAction Stop) {
        $nic = $ipIf[$cfg.InterfaceIndex]
        [pscustomobject]@{
            InterfaceAlias = $cfg.InterfaceAlias
            Description    = $cfg.InterfaceDescription
            Status         = $cfg.NetAdapter.Status
            MacAddress     = $cfg.NetAdapter.MacAddress
            LinkSpeed      = $cfg.NetAdapter.LinkSpeed
            Dhcp           = $nic.Dhcp
            MTU            = $nic.NlMtu
            IPv4Address    = (@($cfg.IPv4Address) | Where-Object { $_ } | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join '; '
            DefaultGateway = (@($cfg.IPv4DefaultGateway) | Where-Object { $_ } | ForEach-Object { $_.NextHop }) -join '; '
            DnsServers     = (@($cfg.DNSServer) | Where-Object { $_ -and $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join '; '
        }
    }
    Save-Csv -Data $rows -Name '08_Network_Interfaces.csv'

    $routes = Get-NetRoute -PolicyStore PersistentStore -ErrorAction Ignore |
        Select-Object InterfaceAlias, AddressFamily, DestinationPrefix, NextHop, RouteMetric
    Save-Csv -Data $routes -Name '08_Network_PersistentRoutes.csv'

    $teams = Get-NetLbfoTeam -ErrorAction Ignore |
        Select-Object Name, TeamingMode, LoadBalancingAlgorithm, @{ n = 'Members'; e = { $_.Members -join ';' } }, Status
    if ($teams) { Save-Csv -Data $teams -Name '08_Network_Teaming.csv' }

    & route.exe print | Out-File (Join-Path $CfgDir 'route_print.txt') -Encoding UTF8
    & netsh.exe winhttp show proxy | Out-File (Join-Path $CfgDir 'winhttp_proxy.txt') -Encoding UTF8
    Copy-Item (Join-Path $env:windir 'System32\drivers\etc\hosts') (Join-Path $CfgDir 'hosts') -ErrorAction Ignore
}
#endregion

#region 09. 방화벽
Invoke-Section '09_Firewall' {
    # 정책 전체 백업 (netsh advfirewall import 로 복원 가능)
    $wfw = Join-Path $CfgDir 'firewall_policy.wfw'
    $out = & netsh.exe advfirewall export $wfw 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log ('netsh advfirewall export 실패: {0}' -f ($out -join ' ')) 'WARN' }

    $profiles = Get-NetFirewallProfile -PolicyStore ActiveStore |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogFileName, LogAllowed, LogBlocked
    Save-Csv -Data $profiles -Name '09_Firewall_Profiles.csv'

    $portF = @{}; foreach ($f in Get-NetFirewallPortFilter -All -PolicyStore ActiveStore)        { $portF[$f.InstanceID] = $f }
    $addrF = @{}; foreach ($f in Get-NetFirewallAddressFilter -All -PolicyStore ActiveStore)     { $addrF[$f.InstanceID] = $f }
    $appF  = @{}; foreach ($f in Get-NetFirewallApplicationFilter -All -PolicyStore ActiveStore) { $appF[$f.InstanceID]  = $f }

    $rows = foreach ($r in Get-NetFirewallRule -PolicyStore ActiveStore) {
        $id = if ($r.InstanceID) { $r.InstanceID } elseif ($r.ID) { $r.ID } else { $r.Name }
        $p  = $portF[$id]
        $a  = $addrF[$id]
        $ap = $appF[$id]
        [pscustomobject]@{
            DisplayName   = $r.DisplayName
            Name          = $r.Name
            Group         = $r.DisplayGroup
            Enabled       = $r.Enabled
            Direction     = $r.Direction
            Action        = $r.Action
            Profile       = $r.Profile
            Protocol      = $p.Protocol
            LocalPort     = (@($p.LocalPort) -join ',')
            RemotePort    = (@($p.RemotePort) -join ',')
            LocalAddress  = (@($a.LocalAddress) -join ',')
            RemoteAddress = (@($a.RemoteAddress) -join ',')
            Program       = $ap.Program
            PolicySource  = $r.PolicyStoreSourceType
        }
    }
    Save-Csv -Data $rows -Name '09_Firewall_Rules.csv'
}
#endregion

#region 10. 인증서
Invoke-Section '10_Certificates' {
    $stores = 'My', 'WebHosting', 'Root', 'CA', 'TrustedPeople', 'TrustedPublisher', 'Remote Desktop'
    $now    = Get-Date

    $rows = foreach ($s in $stores) {
        $path = 'Cert:\LocalMachine\{0}' -f $s
        if (-not (Test-Path $path)) { continue }
        foreach ($c in Get-ChildItem $path -ErrorAction Ignore) {
            $san = (@($c.Extensions) | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }) -join '; '
            [pscustomobject]@{
                Store         = $s
                Subject       = $c.Subject
                Issuer        = $c.Issuer
                Thumbprint    = $c.Thumbprint
                FriendlyName  = $c.FriendlyName
                NotBefore     = $c.NotBefore
                NotAfter      = $c.NotAfter
                Expired       = ($c.NotAfter -lt $now)
                HasPrivateKey = $c.HasPrivateKey
                SAN           = $san
                EKU           = (@($c.EnhancedKeyUsageList) | ForEach-Object { $_.FriendlyName }) -join '; '
            }
        }
    }

    $script:Ctx.CertWithKey = @($rows | Where-Object { $_.HasPrivateKey }).Count
    Save-Csv -Data $rows -Name '10_Certificates.csv'
}
#endregion

#region 11. ODBC
Invoke-Section '11_ODBC' {
    if (-not (Get-Command Get-OdbcDsn -ErrorAction Ignore)) {
        Write-Log 'Wdac 모듈 없음, ODBC 수집 생략' 'WARN'
        return
    }

    $rows = foreach ($plat in '64-bit', '32-bit') {
        foreach ($d in Get-OdbcDsn -Platform $plat -ErrorAction Ignore) {
            # 암호 속성 마스킹
            $attr = (@($d.Attribute.GetEnumerator()) | Sort-Object Key | ForEach-Object {
                if ($_.Key -match '(?i)^(pwd|password)$') { '{0}=********' -f $_.Key } else { '{0}={1}' -f $_.Key, $_.Value }
            }) -join '; '
            [pscustomobject]@{
                Name       = $d.Name
                DsnType    = $d.DsnType
                Platform   = $plat
                DriverName = $d.DriverName
                Attributes = $attr
            }
        }
    }
    Save-Csv -Data $rows -Name '11_ODBC_DSN.csv'

    $drivers = Get-OdbcDriver -Platform All -ErrorAction Ignore | Select-Object Name, Platform
    Save-Csv -Data $drivers -Name '11_ODBC_Drivers.csv'

    Export-RegKey 'HKLM\SOFTWARE\ODBC'             (Join-Path $RegDir 'ODBC_x64.reg')
    Export-RegKey 'HKLM\SOFTWARE\WOW6432Node\ODBC' (Join-Path $RegDir 'ODBC_x86.reg')
}
#endregion

#region 12. 공유 폴더
Invoke-Section '12_Shares' {
    $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special })

    $rows = $shares | Select-Object Name, Path, Description, ScopeName, FolderEnumerationMode, CachingMode, EncryptData, ConcurrentUserLimit
    Save-Csv -Data $rows -Name '12_Shares.csv'

    $access = foreach ($s in $shares) {
        Get-SmbShareAccess -Name $s.Name -ErrorAction Ignore |
            Select-Object Name, AccountName, AccessControlType, AccessRight
    }
    Save-Csv -Data $access -Name '12_Shares_Access.csv'

    # 공유 정의 원본 백업 (reg import 후 Server 서비스 재시작으로 복원 가능)
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares' (Join-Path $RegDir 'LanmanServer_Shares.reg')
}
#endregion

#region 13. 로컬 사용자/그룹
Invoke-Section '13_LocalAccounts' {
    if ($script:Ctx.IsDC) {
        Write-Log '도메인 컨트롤러, 로컬 계정 수집 생략' 'WARN'
        return
    }

    $users = Get-LocalUser |
        Select-Object Name, Enabled, @{ n = 'SID'; e = { $_.SID.Value } }, Description,
                      PasswordRequired, PasswordExpires, PasswordLastSet, UserMayChangePassword, LastLogon
    Save-Csv -Data $users -Name '13_LocalUsers.csv'

    # ADSI 사용: 미확인 SID 포함 그룹에서도 오류 없이 조회
    $hostPattern = '/{0}/' -f [regex]::Escape($env:COMPUTERNAME)
    $rows = foreach ($g in Get-LocalGroup) {
        $adsi = [ADSI]('WinNT://{0}/{1},group' -f $env:COMPUTERNAME, $g.Name)
        foreach ($m in @($adsi.psbase.Invoke('Members'))) {
            $path  = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
            $class = $m.GetType().InvokeMember('Class', 'GetProperty', $null, $m, $null)
            if ($path -match 'S-1-5-21-[\d-]+$') {
                $scope  = 'UnresolvedSID'
                $member = ($path -split '/')[-1]
            } elseif ($path -match $hostPattern) {
                $scope  = 'Local'
                $member = '{0}\{1}' -f $env:COMPUTERNAME, ($path -split '/')[-1]
            } else {
                $scope  = 'Domain/WellKnown'
                $member = ($path -replace '^WinNT://', '') -replace '/', '\'
            }
            [pscustomobject]@{
                Group       = $g.Name
                GroupSID    = $g.SID.Value
                Member      = $member
                MemberClass = $class
                Scope       = $scope
            }
        }
    }
    Save-Csv -Data $rows -Name '13_LocalGroupMembers.csv'
}
#endregion

#region 14. 보안 정책
Invoke-Section '14_SecurityPolicy' {
    $secDir = Join-Path $CfgDir 'Security'
    New-Item -ItemType Directory -Path $secDir -Force | Out-Null

    $out = & secedit.exe /export /cfg (Join-Path $secDir 'secpol.inf') /quiet 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log ('secedit export 실패: {0}' -f ($out -join ' ')) 'WARN' }

    $out = & auditpol.exe /backup ('/file:{0}' -f (Join-Path $secDir 'auditpol.csv')) 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log ('auditpol backup 실패: {0}' -f ($out -join ' ')) 'WARN' }

    $out = & gpresult.exe /scope computer /h (Join-Path $secDir 'gpresult_computer.html') /f 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log ('gpresult 실패: {0}' -f ($out -join ' ')) 'WARN' }

    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL' (Join-Path $secDir 'SCHANNEL.reg')
    Export-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'                         (Join-Path $secDir 'Lsa.reg')

    $script:SectionCount = @(Get-ChildItem $secDir -File).Count
}
#endregion

#region 15. 디스크/볼륨
Invoke-Section '15_Disks' {
    $bl = @{}
    if (Get-Command Get-BitLockerVolume -ErrorAction Ignore) {
        foreach ($b in Get-BitLockerVolume -ErrorAction Ignore) { $bl[$b.MountPoint] = [string]$b.ProtectionStatus }
    }

    $vols = foreach ($v in (Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' })) {
        $mp = if ($v.DriveLetter) { '{0}:' -f $v.DriveLetter } else { '' }
        $blStatus = ''
        if ($mp -and $bl.ContainsKey($mp)) { $blStatus = $bl[$mp] }
        [pscustomobject]@{
            DriveLetter = $mp
            Label       = $v.FileSystemLabel
            FileSystem  = $v.FileSystem
            SizeGB      = [Math]::Round($v.Size / 1GB, 1)
            FreeGB      = [Math]::Round($v.SizeRemaining / 1GB, 1)
            Health      = $v.HealthStatus
            BitLocker   = $blStatus
        }
    }
    Save-Csv -Data $vols -Name '15_Volumes.csv'

    $script:Ctx.DataDrives = @($vols | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $env:SystemDrive } |
        ForEach-Object { $_.DriveLetter })

    $disks = Get-Disk -ErrorAction Ignore |
        Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle,
                      @{ n = 'SizeGB'; e = { [Math]::Round($_.Size / 1GB, 1) } }, OperationalStatus, IsBoot, IsSystem
    Save-Csv -Data $disks -Name '15_Disks.csv'

    $parts = Get-Partition -ErrorAction Ignore |
        Select-Object DiskNumber, PartitionNumber, DriveLetter, Type,
                      @{ n = 'SizeGB'; e = { [Math]::Round($_.Size / 1GB, 1) } }, IsBoot, IsSystem, IsActive
    Save-Csv -Data $parts -Name '15_Partitions.csv'
}
#endregion

#region 16. 데이터 드라이브 NTFS 권한
Invoke-Section '16_DataDriveAcl' {
    $drives = @($script:Ctx.DataDrives)
    if ($drives.Count -eq 0) {
        Write-Log '시스템 드라이브 외 고정 드라이브 없음'
        return
    }

    $localPrefix = '{0}\' -f $env:COMPUTERNAME
    $skipPattern = '\\(\$RECYCLE\.BIN|System Volume Information)(\\|$)'

    $rows = foreach ($d in $drives) {
        $root    = '{0}\' -f $d
        $targets = @(Get-Item -LiteralPath $root -Force -ErrorAction Ignore)
        if ($AclDepth -ge 1) {
            $targets += @(Get-ChildItem -LiteralPath $root -Directory -Force -Recurse -Depth ($AclDepth - 1) -ErrorAction Ignore |
                Where-Object { $_.FullName -notmatch $skipPattern })
        }

        foreach ($t in $targets) {
            try {
                $acl = Get-Acl -LiteralPath $t.FullName -ErrorAction Stop
            } catch {
                Write-Log ('ACL 조회 실패: {0}' -f $t.FullName) 'WARN'
                continue
            }
            $isRoot = ($t.FullName.TrimEnd('\') -eq $d)

            foreach ($ace in $acl.Access) {
                # 하위 폴더는 명시적 권한만 기록 (상속 권한은 루트에서 확인)
                if (-not $isRoot -and $ace.IsInherited) { continue }
                $idn = $ace.IdentityReference.Value
                if ($idn -match '^S-1-5-21-') {
                    $scope = 'UnresolvedSID'
                } elseif ($idn.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $scope = 'Local'
                } else {
                    $scope = 'Domain/BuiltIn'
                }
                [pscustomobject]@{
                    Path                = $t.FullName
                    Owner               = $acl.Owner
                    InheritanceDisabled = $acl.AreAccessRulesProtected
                    Identity            = $idn
                    AccountScope        = $scope
                    Rights              = $ace.FileSystemRights
                    Type                = $ace.AccessControlType
                    IsInherited         = $ace.IsInherited
                    InheritanceFlags    = $ace.InheritanceFlags
                    PropagationFlags    = $ace.PropagationFlags
                }
            }
        }
    }

    $script:Ctx.AclLocal = @($rows | Where-Object { $_.AccountScope -ne 'Domain/BuiltIn' }).Count
    Save-Csv -Data $rows -Name '16_DataDriveAcl.csv'
}
#endregion

#region 17. IIS
Invoke-Section '17_IIS' {
    $inetsrv = Join-Path $env:windir 'System32\inetsrv'
    if (-not (Test-Path (Join-Path $inetsrv 'config\applicationHost.config'))) {
        Write-Log 'IIS 미설치, 수집 생략'
        return
    }

    $iisDir = Join-Path $CfgDir 'IIS'
    New-Item -ItemType Directory -Path $iisDir -Force | Out-Null

    foreach ($f in 'applicationHost.config', 'administration.config', 'redirection.config') {
        Copy-Item (Join-Path $inetsrv ('config\{0}' -f $f)) $iisDir -ErrorAction Ignore
    }

    $appcmd = Join-Path $inetsrv 'appcmd.exe'
    foreach ($obj in 'site', 'apppool', 'app', 'vdir') {
        & $appcmd list $obj | Out-File (Join-Path $iisDir ('list_{0}.txt' -f $obj)) -Encoding UTF8
    }

    $script:SectionCount = @(Get-ChildItem $iisDir -File).Count
}
#endregion

#region 18. 레지스트리
Invoke-Section '18_Registry' {
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    $psProps = 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider'

    $runRows = foreach ($k in $runKeys) {
        $p = Get-ItemProperty $k -ErrorAction Ignore
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($psProps -contains $prop.Name) { continue }
            [pscustomobject]@{
                Key     = $k
                Name    = $prop.Name
                Command = $prop.Value
            }
        }
    }
    Save-Csv -Data $runRows -Name '18_Startup_Run.csv'

    if ($SkipRegistryExport) {
        Write-Log '벤더 레지스트리 키 추출 생략 (-SkipRegistryExport)'
        return
    }

    # HKLM\SOFTWARE 하위 벤더 키 단위 백업 (애플리케이션 설정 복원 참조용)
    $swDir = Join-Path $RegDir 'Software'
    New-Item -ItemType Directory -Path $swDir -Force | Out-Null
    $exclude = 'Microsoft', 'Classes', 'Clients', 'RegisteredApplications', 'WOW6432Node', 'ODBC'
    $bases = @(
        @{ Path = 'SOFTWARE';             Prefix = 'x64' }
        @{ Path = 'SOFTWARE\WOW6432Node'; Prefix = 'x86' }
    )

    foreach ($b in $bases) {
        foreach ($k in Get-ChildItem ('HKLM:\{0}' -f $b.Path) -ErrorAction Ignore) {
            if ($exclude -contains $k.PSChildName) { continue }
            $file = Join-Path $swDir ('{0}_{1}.reg' -f $b.Prefix, (Get-SafeName $k.PSChildName))
            Export-RegKey ('HKLM\{0}\{1}' -f $b.Path, $k.PSChildName) $file
            $script:SectionCount++
        }
    }
}
#endregion

#region 요약
$script:Summary | Export-Csv -Path (Join-Path $OutDir '00_Summary.csv') -NoTypeInformation -Encoding UTF8

$checks = [ordered]@{
    '호스트명'                         = $env:COMPUTERNAME
    'OS'                               = $script:Ctx.OSCaption
    'Evaluation 버전'                  = $script:Ctx.IsEvaluation
    '설치 유형'                        = $script:Ctx.InstallationType
    'OS 언어'                          = $script:Ctx.OSLanguage
    '도메인 컨트롤러'                  = $script:Ctx.IsDC
    '시스템 드라이브 여유 공간(GB)'    = $script:Ctx.SystemDriveFreeGB
    '설치 프로그램 MSI'                = $script:Ctx.MsiCount
    '설치 프로그램 EXE'                = $script:Ctx.ExeCount
    '로컬 계정 실행 서비스'            = $script:Ctx.SvcLocalAccount
    '암호 저장 예약 작업'              = $script:Ctx.TaskPassword
    '개인키 보유 인증서'               = $script:Ctx.CertWithKey
    '데이터 드라이브 로컬/미확인 SID 권한' = $script:Ctx.AclLocal
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Windows Server 업그레이드 전 구성 인벤토리')
$lines.Add(('생성 일시: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$lines.Add('')
$lines.Add('[주요 점검 항목]')
foreach ($k in $checks.Keys) { $lines.Add(('{0} : {1}' -f $k, $checks[$k])) }
$lines.Add('')
$lines.Add('[섹션별 결과]')
$lines.Add(($script:Summary | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())
$lines.Add('')
$lines.Add('[유의사항]')
$lines.Add('1. 결과물에 레지스트리, 보안 정책, 계정 정보 포함. 기밀 자료로 취급')
$lines.Add('2. 인증서 개인키 미포함. 개인키는 별도 PFX 백업 필요')
$lines.Add('3. 사용자 단위 설치 프로그램은 현재 로드된 사용자 하이브만 포함')
$lines.Add('4. InstallerType 의 (추정) 항목은 제거 명령 경로 기반 판별. 확인필요')
$lines | Out-File -FilePath (Join-Path $OutDir '00_Summary.txt') -Encoding UTF8

Write-Log '인벤토리 추출 완료'
#endregion

#region 압축
if (-not $SkipZip) {
    $zip = '{0}.zip' -f $OutDir
    try {
        Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zip -Force -ErrorAction Stop
        Write-Host ('ZIP 파일: {0}' -f $zip) -ForegroundColor Cyan
    } catch {
        Write-Host ('ZIP 생성 실패: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ('결과 폴더: {0}' -f $OutDir) -ForegroundColor Cyan
Write-Host '결과물은 업그레이드 대상 서버 외부 저장소로 복사 필요' -ForegroundColor Cyan
#endregion
