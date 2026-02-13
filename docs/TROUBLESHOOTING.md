# Troubleshooting

## Multiple App Instances Appearing

**Symptoms:** Multiple GhostType entries in Dock, Spotlight, or Finder.

**Cause:** macOS LaunchServices/Spotlight indexed build artifacts from DerivedData or local build directories.

**Fix:**

```bash
# 1. Kill all running instances
pkill -x GhostType

# 2. Ensure only /Applications/GhostType.app exists
ls /Applications/GhostType.app

# 3. Re-register with LaunchServices
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
$LSREG -f /Applications/GhostType.app

# 4. Relaunch
open /Applications/GhostType.app
```

If Spotlight still shows duplicates, unregister stale paths:

```bash
# Find all indexed GhostType.app paths
mdfind "kMDItemFSName == 'GhostType.app'c"

# Unregister non-/Applications paths
$LSREG -u "<stale-path>"
```

## Python Backend Fails to Start

**Symptoms:** App shows "Backend startup failed" or "Starting" indefinitely.

**Possible causes:**
1. Python 3 not installed or not in PATH.
2. Insufficient disk space for venv + ML models (~2 GB).
3. Network issue during pip install.

**Fix:**

```bash
# Check Python availability
python3 --version

# Check venv status
ls ~/Library/Application\ Support/GhostType/.venv/bin/python

# If venv is corrupted, delete and let the app recreate it
rm -rf ~/Library/Application\ Support/GhostType/.venv
rm -f ~/Library/Application\ Support/GhostType/.requirements.sha256

# Relaunch the app
open /Applications/GhostType.app
```

## Python Process Lingers After App Exit

**Symptoms:** `service.py` process remains running after closing the app.

**Fix:**

```bash
pkill -x GhostType
pkill -f "GhostType.app/Contents/Resources/service.py"
```

## Microphone Permission Denied

**Symptoms:** Recording does not start; app shows microphone permission error.

**Fix:**
1. Open **System Settings → Privacy & Security → Microphone**.
2. Enable the toggle for **GhostType**.
3. If running from Xcode, also enable for **Xcode**.

## Global Hotkeys Not Working

**Symptoms:** Pressing the hotkey does nothing.

**Cause:** Accessibility permission not granted.

**Fix:**
1. Open **System Settings → Privacy & Security → Accessibility**.
2. Add and enable **GhostType** (or **Xcode** if running in development).
3. If the app was recently rebuilt, you may need to remove and re-add it.

## App Shows Old Version After Rebuilding

**Symptoms:** Code changes are not reflected in the running app.

**Cause:** The running app is from a different build path than the one just compiled.

**Fix:**

```bash
# Rebuild
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -derivedDataPath ./.build CODE_SIGNING_ALLOWED=NO build

# Kill old instance and copy new build
pkill -x GhostType
rm -rf /Applications/GhostType.app
cp -R .build/Build/Products/Debug/GhostType.app /Applications/GhostType.app

# Relaunch
open /Applications/GhostType.app
```

## Models Download Slowly on First Launch

**Symptoms:** First dictation takes a long time or shows "warming up" status.

**Cause:** MLX models (~500 MB total) are downloaded from Hugging Face on first use and cached in `~/.cache/huggingface/`.

**Fix:** This is expected on first launch. Subsequent launches will use the cached models. Ensure you have a stable internet connection for the initial download.

## Reset to Default State

To completely reset GhostType to a fresh state:

```bash
# Stop the app
pkill -x GhostType

# Remove all app data
rm -rf ~/Library/Application\ Support/GhostType/

# Remove cached models (optional, will re-download)
rm -rf ~/.cache/huggingface/hub/models--mlx-community--whisper-small-mlx
rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen2.5-1.5B-Instruct-4bit

# Remove user preferences
defaults delete com.codeandchill.ghosttype

# Relaunch
open /Applications/GhostType.app
```

---

# 常见问题排障

## 出现多个应用实例

**症状：** Dock、Spotlight 或 Finder 中出现多个 GhostType 条目。

**原因：** macOS LaunchServices/Spotlight 索引了 DerivedData 或本地构建目录中的构建产物。

**修复方法：**

```bash
# 1. 终止所有运行中的实例
pkill -x GhostType

# 2. 确认仅 /Applications/GhostType.app 存在
ls /Applications/GhostType.app

# 3. 重新注册 LaunchServices
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
$LSREG -f /Applications/GhostType.app

# 4. 重新启动
open /Applications/GhostType.app
```

## Python 后端启动失败

**症状：** 应用显示 "Backend startup failed" 或一直停留在 "Starting"。

**修复方法：**

```bash
# 检查 Python 版本
python3 --version

# 如果虚拟环境损坏，删除后让应用重新创建
rm -rf ~/Library/Application\ Support/GhostType/.venv
rm -f ~/Library/Application\ Support/GhostType/.requirements.sha256

# 重新启动应用
open /Applications/GhostType.app
```

## 麦克风权限被拒绝

**修复方法：**
1. 打开 **系统设置 → 隐私与安全性 → 麦克风**。
2. 为 **GhostType** 打开开关。

## 全局快捷键不工作

**修复方法：**
1. 打开 **系统设置 → 隐私与安全性 → 辅助功能**。
2. 添加并启用 **GhostType**。

## 完全重置

```bash
pkill -x GhostType
rm -rf ~/Library/Application\ Support/GhostType/
defaults delete com.codeandchill.ghosttype
open /Applications/GhostType.app
```
