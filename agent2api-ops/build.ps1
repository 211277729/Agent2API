<#
.SYNOPSIS
  Agent2API 本地构建 -> 打包成 tar.gz ->（可选）上传到服务器。

.DESCRIPTION
  Windows + Docker Desktop 上完成「改完代码 -> 出可部署镜像」。
  Dockerfile 依赖 BuildKit（BUILDPLATFORM / TARGETARCH），不要设 DOCKER_BUILDKIT=0。

  与 jingyu-api 构建的差别：
    · 只编 agent2api-server 这个 Rust crate，不含 Tauri 桌面壳；
    · amd64 服务器 = 原生编译；arm64 = 容器内 rustup 交叉编译（无需 QEMU）；
    · 首次要编整棵依赖树（几分钟），之后改源码通常 1~2 分钟。

.PARAMETER Repo
  Agent2API 仓库路径。默认取本脚本所在目录的同级 Agent2API（脚本和仓库并排放即可）。

.PARAMETER Tag
  镜像 tag。默认 <Cargo.toml 版本>-<yyyyMMdd-HHmm>-<git短哈希>。

.PARAMETER Platform
  linux/amd64（x86_64 服务器）或 linux/arm64（ARM 服务器，先 `uname -m` 确认）。

.PARAMETER BuildUi
  先重建前端产物。改了 ui-islands/src 或 i18n/i18n-src 时必须带上：
  ui/islands/ui.js、ui/islands/ui.css、ui/i18n/** 是入库的构建产物，
  Dockerfile 只 COPY desktop-tauri/ui，不重建就会把旧界面打进镜像。

.PARAMETER Upload
  构建完 scp 上传并触发远端 update.sh（远端目录默认与本地脚本同名的部署目录）。

.PARAMETER DryRun
  只打印将要执行的命令，不构建也不上传。

.EXAMPLE
  .\build.ps1 -BuildUi
.EXAMPLE
  .\build.ps1 -Upload -Server root@1.2.3.4 -RemoteDir /home/ubuntu/agent2api
#>
[CmdletBinding()]
param(
    [string]$Repo      = "",
    [string]$Tag       = "",
    [ValidateSet("linux/amd64", "linux/arm64")]
    [string]$Platform  = "linux/amd64",
    [switch]$BuildUi,
    [switch]$Upload,
    [switch]$DryRun,
    [string]$Server    = "root@YOUR_SERVER_IP",
    [string]$RemoteDir = "/opt/agent2api",
    [string]$Proxy     = ""
)

$ErrorActionPreference = "Stop"
$OutDir = Join-Path $PSScriptRoot "out"
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# 原生命令（docker / ssh / tar）的 stderr 在 Windows PowerShell 5.1 里会被当成错误记录，
# 配合 $ErrorActionPreference='Stop' 会直接把脚本打断（buildx 的进度日志正好走 stderr）。
# 统一走这个包装：临时降级、把输出打印出来、再按退出码抛错。
function Invoke-External([string]$Label, [scriptblock]$Action) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Action 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message }
            else { Write-Host $_ }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { throw "${Label} 失败（exit ${code}），看上面输出" }
}

# ── 0. 仓库路径（默认：从脚本所在目录往上找第一个含 Dockerfile 的目录）──
if (-not $Repo) {
    $probe = $PSScriptRoot
    while ($probe -and -not (Test-Path (Join-Path $probe "Dockerfile"))) {
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { $probe = $null; break }
        $probe = $parent
    }
    if ($probe) { $Repo = $probe }
}
if (-not $Repo -or -not (Test-Path (Join-Path $Repo "Dockerfile"))) {
    throw "找不到 Agent2API 仓库（脚本所在目录往上都没有 Dockerfile）：用 -Repo 指定路径"
}
Say "仓库：$Repo"

$dirty = git -C $Repo status --porcelain
if ($dirty) {
    Write-Host "提示：工作区有未提交改动，镜像会包含它们的当前内容：" -ForegroundColor Yellow
    $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

# ── 1. 版本号 / tag ────────────────────────────────────────────
$cargoToml = Join-Path $Repo "desktop-tauri\src-tauri\server\Cargo.toml"
$ver = (Select-String -Path $cargoToml -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
$short = (git -C $Repo rev-parse --short HEAD).Trim()
if (-not $Tag) {
    $Tag = "${ver}-$((Get-Date).ToString('yyyyMMdd-HHmm'))-${short}"
}
$Image = "agent2api:${Tag}"
Say "版本 ${ver} / 镜像 ${Image} / 平台 ${Platform}"

# ── 2. （可选）重建前端产物 ────────────────────────────────────
if ($BuildUi -and -not $DryRun) {
    Say "重建前端产物（ui-islands 的 ui.js/ui.css + i18n 词典）"
    foreach ($pkg in @("ui-kit", "ui-islands", "i18n")) {
        $dir = Join-Path $Repo "desktop-tauri\$pkg"
        if (-not (Test-Path (Join-Path $dir "node_modules"))) {
            Write-Host "    npm ci @ $pkg" -ForegroundColor DarkGray
            Invoke-External "npm ci ($pkg)" { npm --prefix $dir ci }
        }
    }
    Invoke-External "ui-islands 构建" { npm --prefix (Join-Path $Repo "desktop-tauri\ui-islands") run build }
    Invoke-External "i18n 词典构建" { npm --prefix (Join-Path $Repo "desktop-tauri\i18n") run build }

    $uiChanged = git -C $Repo status --porcelain -- desktop-tauri/ui
    if ($uiChanged) {
        Write-Host "产物已更新，记得连同源码一起提交（否则别人 clone 到的是旧界面）：" -ForegroundColor Yellow
        $uiChanged | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "    产物与源码一致，无变化。" -ForegroundColor DarkGray
    }
}

# ── 3. 构建镜像 ────────────────────────────────────────────────
# 不给 --load 的话 buildx 只把结果留在缓存里，docker save 会找不到镜像。
$buildArgs = @(
    "buildx", "build",
    "--platform", $Platform,
    "-f", (Join-Path $Repo "Dockerfile"),
    "-t", $Image,
    "--load"
)
if ($Proxy) { $buildArgs += @("--build-arg", "HTTP_PROXY=$Proxy", "--build-arg", "HTTPS_PROXY=$Proxy") }
$buildArgs += $Repo

Say "开始构建（首次 5~15 分钟，之后改源码通常 1~2 分钟）"

if ($DryRun) {
    Write-Host "    [DryRun] docker $($buildArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host "    [DryRun] docker save -o $(Join-Path $OutDir "agent2api-${Tag}.tar") ${Image}" -ForegroundColor DarkGray
    Write-Host "    [DryRun] gzip 压缩 -> $(Join-Path $OutDir "agent2api-${Tag}.tar.gz")" -ForegroundColor DarkGray
    if ($BuildUi) { Write-Host "    [DryRun] 前置：npm ci（缺 node_modules 时）+ ui-islands/i18n 的 build" -ForegroundColor DarkGray }
    if ($Upload) {
        Write-Host "    [DryRun] ssh ${Server} `"mkdir -p '${RemoteDir}'`"" -ForegroundColor DarkGray
        Write-Host "    [DryRun] scp $(Join-Path $OutDir "agent2api-${Tag}.tar.gz") ${Server}:${RemoteDir}/" -ForegroundColor DarkGray
        Write-Host "    [DryRun] ssh ${Server} `"bash ${RemoteDir}/update.sh '${RemoteDir}/agent2api-${Tag}.tar.gz' '${Tag}'`"" -ForegroundColor DarkGray
    }
    Say "[DryRun] 未执行任何构建/上传"
    return
}

Invoke-External "docker buildx build" { & docker @buildArgs }

# ── 4. 导出 tar.gz ─────────────────────────────────────────────
# 注意：是把 tar 的字节流直接 gzip，不是 `tar -czf 文件` ——
# 后者会产出「一个 tar 里套一个 .tar」的嵌套包，docker load 报 unrecognized image format。
$rawName = "agent2api-${Tag}.tar"
$rawTar  = Join-Path $OutDir $rawName
$gzTar   = "$rawTar.gz"
Say "导出镜像 -> $gzTar"
Invoke-External "docker save" { & docker save -o $rawTar $Image }

$in  = [IO.File]::OpenRead($rawTar)
$out = [IO.File]::Create($gzTar)
try {
    $gzip = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionLevel]::Optimal)
    try { $in.CopyTo($gzip) } finally { $gzip.Dispose() }
} finally {
    $out.Dispose(); $in.Dispose()
}
Remove-Item $rawTar -Force

# 自检：顶层必须是镜像布局（index.json / manifest.json），不能是一个 .tar
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $entries = & tar -tzf $gzTar } finally { $ErrorActionPreference = $prevEap }
$ok = ($entries | Where-Object { $_ -match '^(\./)?(index\.json|manifest\.json|oci-layout)$' }).Count -gt 0
if (-not $ok) {
    Remove-Item $gzTar -Force
    throw "打包结果不是合法镜像归档（顶层缺 index.json/manifest.json），已删除：$gzTar"
}

$mb = [math]::Round((Get-Item $gzTar).Length / 1MB, 1)
Say "完成：${gzTar}（${mb} MB）"

# ── 5. （可选）上传并上线 ─────────────────────────────────────
if ($Upload) {
    Say "上传到 ${Server}:${RemoteDir}"
    Invoke-External "ssh 建目录" { ssh $Server "mkdir -p '$RemoteDir'" }
    Invoke-External "scp 上传" { scp $gzTar "${Server}:${RemoteDir}/" }

    Say "服务器上执行 update.sh（tag 由远端脚本从包里自动读，不用手填）"
    $remoteCmd = "bash ${RemoteDir}/update.sh '${RemoteDir}/${rawName}.gz'"
    Invoke-External "远端 update.sh" { ssh $Server $remoteCmd }
} else {
    Write-Host ""
    Write-Host "下一步（二选一）：" -ForegroundColor Green
    Write-Host "  A) 本机先跑一下： docker run --rm -p 3065:3065 -v `"${OutDir}\outdata:/data`" $Image"
    Write-Host "  B) 传到服务器：   scp `"$gzTar`" root@<服务器IP>:<部署目录>/"
    Write-Host "     然后：         ssh root@<服务器IP> `"bash <部署目录>/update.sh`"   # 包和 tag 都自动识别"
    Write-Host ""
}
