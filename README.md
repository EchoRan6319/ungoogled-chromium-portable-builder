# ungoogled-chromium + Chrome++ portable builder

这个项目会自动：

1. 获取 `ungoogled-software/ungoogled-chromium-windows` 最新 release。
2. 下载对应架构的 `installer_*.exe`。
3. 用 7-Zip 解压两遍，拿到真正的浏览器程序目录。
4. 获取 `Bush2021/chrome_plus` 最新 release。
5. 注入对应架构的 `version.dll` 和 `chrome++.ini`。
6. 产出一个便携目录，以及可选的 `.7z` 打包文件。

默认目录结构：

```text
artifacts/
  ungoogled-chromium-portable-x64/
    App/
    Data/
    Cache/
    metadata.json
downloads/
work/
```

`App` 里是浏览器程序和 `Chrome++` 补丁，`Data` / `Cache` 是便携模式下的数据目录。  
上游 `Chrome++` 默认配置本身已经使用：

```ini
data_dir=%app%\..\Data
cache_dir=%app%\..\Cache
```

所以不额外改配置时也能直接进入便携模式。

## 依赖

- Windows PowerShell 7 或更新版本
- `7z.exe`
- 可访问 GitHub Releases / GitHub API 的网络

## 用法

在项目根目录运行：

```powershell
pwsh .\build-portable.ps1
```

常用参数：

```powershell
pwsh .\build-portable.ps1 -Arch x64 -Force
pwsh .\build-portable.ps1 -Arch x64 -SkipArchive
pwsh .\build-portable.ps1 -Arch x64 -ChromePlusIniPath .\my-chrome++.ini -Force
pwsh .\build-portable.ps1 -Arch arm64 -Force
```

参数说明：

- `-Arch`: `x64`、`x86`、`arm64`
- `-Force`: 覆盖已有下载和产物
- `-SkipArchive`: 只生成目录，不额外打 `.7z`
- `-ChromePlusIniPath`: 使用你自己的 `chrome++.ini`
- `-KeepWorkDir`: 保留双重解压后的临时目录，方便排错

## GitHub Actions

仓库已经包含工作流 [build-portable.yml](</D:/EchoRan/Documents/New project/.github/workflows/build-portable.yml>)，支持两种触发：

- `workflow_dispatch`: 手动选择 `x64`、`x86`、`arm64`
- `schedule`: 每天自动检查一次上游最新 release

工作流会：

1. 查询 `ungoogled-chromium-windows` 和 `chrome_plus` 的最新 release
2. 生成唯一发布标签：`portable-<arch>-ugc-<ungoogled_tag>-cpp-<chrome_plus_tag>`
3. 如果当前仓库已经存在同标签 release，则自动跳过，避免重复构建
4. 运行 `build-portable.ps1`
5. 上传 `.7z` 和 `metadata.json`
6. 在启用发布时创建 GitHub Release

如果你想用 GitHub-hosted runner，直接手动触发即可，默认 `runs-on` 是：

```json
["windows-latest"]
```

如果你想切到自托管 Windows runner，可以在手动触发时把 `runner_labels` 改成类似：

```json
["self-hosted","Windows","X64"]
```

如果希望定时任务也跑在自托管 runner 上，可以设置仓库变量 `PORTABLE_RUNNER_LABELS`，值同样使用 JSON 数组字符串。

## Release 命名

工作流发布出来的 tag 和 Release 标题形如：

```text
x64-147.0.7727.116-1.1-1.16.0
```

压缩包等资源文件名保持完整命名 `ungoogled-chromium-portable-<arch>-<version>.7z`，便于辨识。

## 当前上游状态

我在 `2026-04-28` 验证到的最新版本：

- `ungoogled-chromium-windows`: `147.0.7727.116-1.1`
- `chrome_plus`: `1.16.0`

脚本运行时会实时请求 GitHub API，不会把版本号写死。

## 已知假设

脚本按你确认过的真实流程实现：

1. 下载 `installer_x64.exe` 这一类安装包，而不是 `windows_x64.zip`
2. 第一次解压安装包
3. 自动寻找内层 `7z/zip` 载荷
4. 第二次解压真正的浏览器内容
5. 再注入 `Chrome++`

复制浏览器文件到便携目录时会自动排除 `.7z` 和 `.zip` 文件，避免将解压后的压缩包残留带入最终产物。

如果未来上游安装包内部结构变化，最可能需要调整的是”第一次解压后如何定位内层载荷”的那段逻辑。

## 已验证结果

我已经在这台机器上实际跑到“注入补丁”前一步，确认这些环节是通的：

- 能拉到 `ungoogled-chromium-windows` 最新 `installer_x64.exe`
- 能自动完成两次解压
- 能识别内层 `chrome.7z`
- 能定位浏览器目录
- 能拉到 `Chrome++` 最新 release，并取到 `x64\App\version.dll`

当前唯一阻塞是 Windows 安全中心会把 `Chrome++` 的 `version.dll` 识别为潜在风险并阻止复制。脚本现在会给出更明确的错误提示。若你的环境里已经做过排除项，重新运行即可：

```powershell
pwsh .\build-portable.ps1 -Arch x64 -Force
```

同样要提醒一句：GitHub-hosted 的 Windows runner 也可能出现相同拦截。如果发生这种情况，最稳妥的做法是改用你自己的自托管 Windows runner，并给工作目录加 Defender 排除项。
