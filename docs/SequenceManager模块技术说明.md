# SequenceManager 模块技术说明

> 客户端 UI 图片序列播放器（`Utils.UISequence` / `Utils.SequenceManager` 同实例）：多图切帧或图集 ImageRect，共享 Heartbeat 时钟。  
> 创建：2026-08-06 · 对应实现：`ToolSystem/SequenceManager`（Last Modified 2026-07-31）

---

## 1. 目标与边界

| 能力 | 说明 |
|------|------|
| 多图序列 | `Assets.Sequence/{名}/` 下连续编号 StringValue → 切 `Image` |
| 图集 Sheet | Folder Attribute + `ImageRectOffset/Size`；Play 时可 `options.sheet` 覆盖/临构 |
| 播放控制 | Play / Pause / Resume / Seek / SeekTime / SetSpeed / Stop* |
| 表现层 | Swap（硬切）/ Crossfade（双缓冲叠化）/ CloneAll（预克隆 Visible） |
| 预载 | Preload / PreloadAsync（可取消回调）/ PreloadMany / PreloadImages |
| 目录 | HasSequence / ValidateSequence / ReloadCatalog / GetSequenceNames |

**不做：** 服务端播放；3D 世界特效序列；在 System 内绑 Remote；用 `BodyVelocity` 等与 UI 无关的位移。

**别名：** `Utils.UISequence` ≡ `Utils.SequenceManager`（商业命名，同模块实例）。

**类型桩：** `Interface/SequenceManager-Type.luau`（与实现同步）。

---

## 2. 分层架构

```text
业务 / GuiScripts / 技能 UI
        │ Utils.UISequence:*
        ▼
SequenceManager (init.luau)     ← 对外 API 门面
        ├── Catalog               扫描 Assets.Sequence；查询 / Validate / Reload
        ├── PlayOptionsUtil       fps / secondsPerFrame / playMode / 区间解析
        ├── Playback              Play 装配 + 转接控制
        │   ├── PlaybackRegistry  状态表 + 世代 id（无公开 byLabel）
        │   ├── PlaybackLifecycle 停播 / 共享时钟 / Destroy 出树
        │   ├── PlaybackControl   Stop / Pause / Seek / Speed / Layer
        │   ├── PlaybackStep      Forward / Reverse / PingPong 逻辑帧
        │   ├── PlaybackPresent   Swap / Crossfade / CloneAll
        │   ├── PlaybackVisual    写 Image/Rect + onFrame / markers
        │   └── PlaybackQuery     IsPlaying / Progress / DebugSnapshot
        ├── Preload               ContentProvider + 可选暖场
        ├── PeerPool              Crossfade/CloneAll 轻量控件池
        └── Contract              RunContractSelfTest
```

| 子模块 | 职责 |
|--------|------|
| Catalog | `AssetPaths.GetCatalog("Sequence")`；多图须连续帧名；图集线索不完整不降级为多图 |
| Playback* | 一控件一活跃播；世代 `PlaybackHandle` 防旧回调误停新播 |
| PeerPool | peer 闲置上限 `MAX_PEER_POOL`（48）；Reload/Shutdown 清空 |
| Contract | Seek 相位 / 帧连续 / Stop nil / Sync-Stop `ABORTED` |

**禁止：** 业务旁路改在播控件的 Image/Rect 当「第二套切帧」；回调内 `StopSequence(label)` 代替 `StopHandle`（易误停重播）。

---

## 3. 资源约定

根目录：`ReplicatedStorage.Assets.Sequence`（经 `AssetPaths.GetCatalog("Sequence")`）。

### 3.1 多图帧（Images）

```text
Assets/Sequence/{序列名}/
  ├── "1"  StringValue  Value = rbxassetid://...
  ├── "2"  StringValue
  └── ...
```

- 帧名从**最小序号起连续无空洞**（`1,2,3` 或 `2,3,4` 均可；`1,2,4` → `rejectCode=FRAME_GAP`）。
- 空 ImageId 扫描时跳过；全空 → `EMPTY_SEQUENCE`。
- 播放逻辑帧 **1..N** 与连续帧名一一对应（`onFrame` / `markers` / `Seek` 均用逻辑帧）。

### 3.2 图集（Sheet）

Folder Attribute（缺一不可，否则扫描失败且**不降级**多图）：

| Attribute | 类型 | 说明 |
|-----------|------|------|
| SheetImage | string | 或子 StringValue 名 `SheetImage` |
| CellWidth / CellHeight | number | 单格像素 |
| Columns | number | 列数 |
| FrameCount | number | 总帧 |
| Rows | number? | 可选；须 `>= ceil(FrameCount/Columns)` |
| Padding / Spacing | number? | 边距 / 格间距，默认 0 |

运行时覆盖示例：

```lua
sheet = {
  imageId = "rbxassetid://123",
  cellWidth = 128, cellHeight = 128,
  columns = 4, frameCount = 8,
  padding = 0, spacing = 0,
}
```

---

## 4. 正交两轴：playMode × presentMode

| 轴 | 枚举 | 含义 |
|----|------|------|
| **playMode** | Forward（默认）/ Reverse / PingPong | 逻辑帧推进方向 |
| **presentMode** | Swap（默认）/ Crossfade / CloneAll | 如何把帧画到控件 |

| presentMode | 适用 | 要点 |
|-------------|------|------|
| Swap | 多图 + 图集 | 单控件硬切 Image / Rect |
| Crossfade | 多图 + 图集 | bufferA=目标，bufferB=同级池化 ImageLabel；叠化用**墙钟**（不受 speed）；Seek 中断叠化硬切；追帧限 1 |
| CloneAll | **仅多图** | 每帧预创建同级；切 Visible；上限 `MAX_CLONE_ALL_FRAMES`（64），超出 `PRESENT_FAILED` |

**PingPong + loop：** `loopInterval` 在越过首帧（完成一轮往返）时生效；越过末帧仅掉头。

---

## 5. 调用方强制约定

1. 必须接收 `PlaySequence` 的 `ok, err, handle`（成功时 **handle 必有**）。
2. `ok == false` 时打日志并走失败分支；勿假装已开播。
3. 主动停播优先 `StopHandle(handle)`；无 handle 才退回 `StopSequence(label)`。
4. `onFrame` / `onComplete` / `markers` 内停播必须用 `StopHandle`。
5. 长循环特效：业务关闭路径须显式 `StopHandle`；Destroy/出树自动停仅作兜底。

```lua
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SequenceManager = Utils.UISequence
local Log = Utils.Log

local ok, err, handle = SequenceManager:PlaySequence(label, name, options)
if not ok or not handle then
	Log.warn("[Caller] PlaySequence failed:", err)
	return
end
-- 业务结束 / 回调内：
SequenceManager:StopHandle(handle)
```

---

## 6. 时间与区间

优先级：`secondsPerFrame` > `fps`。二者至少其一，否则 `INVALID_TIMING`。  
已移除：`frameDuration`、位置参数签名。

| 迁移 | 写法 |
|------|------|
| 旧 `frameDuration = N` | `secondsPerFrame = 0.016 * N` |
| 旧 `PlaySequence(label, name, N, loop)` | `PlaySequence(label, name, { secondsPerFrame = 0.016*N, loop = loop })` |

- `startFrame` / `endFrame`：含端点；越界钳制；`end < start` 时交换。
- `speed`：默认 1，播放中可 `SetSpeed`；须 `> 0`。
- 共享 Heartbeat：同 tick 最多追 `MAX_CATCHUP_CALLBACKS`（32）帧（画面只刷最终帧）；Crossfade 限 1。

---

## 7. 停止策略 stopPolicy

| 值 | 行为 |
|----|------|
| HideClear（常见默认） | 清空 Image/Rect 并隐藏 |
| Restore | 恢复播前快照（含 ImageRect / Transparency / ImageColor3） |
| Keep | 保持当前画面与可见性 |

- 同一控件重播：保留**首次**播前 Restore 快照。
- `StopSequence(nil)` / 未在播：无操作，不改外观。
- `ReloadCatalog()` 默认 `stopActive=true`，以 Keep 停在播，避免新旧帧表混用。

---

## 8. 核心 API 速查

加载：

```lua
local SequenceManager = Utils.UISequence -- 或 Utils.SequenceManager
```

### 8.1 播放 / 控制

| API | 返回 | 说明 |
|-----|------|------|
| `PlaySequence(label, name, options)` | `ok, err, handle?` | 须 fps 或 secondsPerFrame |
| `StopHandle(handle, policy?)` | `ok, err?` | **推荐**停播 |
| `StopSequence(label?, policy?, handle?)` | `ok, err?` | handle 世代不符 → `STALE_HANDLE` |
| `StopAll(policy?)` | `number` | 停止数量 |
| `PauseSequence` / `ResumeSequence` | `ok, err?` | 可带 handle |
| `PauseAll` / `ResumeAll` | `number` | |
| `Seek(label, frame, handle?)` | `ok, err?` | 1-based；PingPong 同步 direction |
| `SeekTime(label, timeSec, handle?)` | `ok, err?` | 相对区间起点相位 |
| `SetSpeed` / `SetLayerTransparency` | `ok, err?` | |

### 8.2 查询

| API | 说明 |
|-----|------|
| `IsPlaying` | 存在且未暂停（含 loopInterval 等待） |
| `IsPaused` / `IsHandleActive` | |
| `GetCurrentFrame` / `GetFrameProgress` / `GetTimeProgress` | 未在播为 nil |
| `GetDuration(label)` | 当前在播、speed=1 区间时长；PingPong 按往返 |
| `GetFrameCount` / `GetSequenceDuration` / `HasSequence` | 目录侧，可不在播 |
| `ValidateSequence` | `(ok, { CatalogIssue })` |
| `GetActiveCount` / `GetDebugSnapshot` | 排障 |

### 8.3 预载与生命周期

| API | 说明 |
|-----|------|
| `Preload` / `PreloadAsync` / `PreloadMany` / `PreloadImages` | 失败不调 `onReady`；暖场用 `forceVisible=false`（内置） |
| `PreloadAsync` 第三返回 | 取消函数：抑制回调并 Stop 暖场（ContentProvider 无法中断） |
| `ReloadCatalog(stopActive?)` | 默认停在播；成功清预载标记与 PeerPool |
| `Shutdown()` | StopAll → 断时钟 → 清池/预载 Gui；换服/热重载调用 |
| `RunContractSelfTest()` | 命令栏自检 PASS/FAIL |

`PreLoad` 为弃用别名（warn-once）→ 请用 `Preload`。

### 8.4 PlayOptions 常用字段

| 字段 | 默认/约束 |
|------|-----------|
| `fps` / `secondsPerFrame` | 必填其一 |
| `loop` / `loopInterval` | |
| `speed` | 1 |
| `stopPolicy` | HideClear / Restore / Keep |
| `startFrame` / `endFrame` | 含端点 |
| `playMode` | Forward / Reverse / PingPong |
| `presentMode` | Swap / Crossfade / CloneAll |
| `crossfadeSec` | 默认 0.04 |
| `layerTransparency` | 0~1 |
| `callbackMode` | Sync（同帧）/ Deferred（`task.spawn`）；均 pcall + 世代校验 |
| `sheet` | 可选覆盖图集 |
| `onFrame` / `onLoop` / `onComplete` / `markers` | |

Sync 回调内 `Stop` 且无后继在播 → Play 返回 `false, ABORTED`（无「假装成功」的 handle）。

---

## 9. ErrorCode

| 码 | 含义 |
|----|------|
| NOT_CLIENT | 非客户端 |
| INVALID_ARG | 参数无效 |
| INVALID_TIMING | 缺/非法时间参数或仍传 frameDuration |
| NOT_FOUND | 序列不存在 |
| NOT_PLAYING | 控制 API 时未在播 |
| PRELOAD_FAILED | 预载失败 |
| NO_PLAYER_GUI | 暖场缺 PlayerGui |
| INVALID_SHEET | 图集几何/配置非法 |
| PRESENT_FAILED | Crossfade/CloneAll 装配失败（无 Parent、图集用 CloneAll、超帧上限等） |
| STALE_HANDLE | handle 世代与当前不一致 |
| FRAME_GAP | 多图帧序号不连续 |
| EMPTY_SEQUENCE | 无有效帧 |
| ABORTED | Sync 回调内已停且无后继 |

变更类 API：`true` 或 `false, ErrorCode`；`PlaySequence` 另返回 `handle?`。

---

## 10. 使用示例

```lua
-- PingPong + CloneAll + Restore
local ok, err, handle = SequenceManager:PlaySequence(imageLabel, "彩虹框", {
	fps = 12,
	loop = true,
	playMode = SequenceManager.PlayMode.PingPong,
	presentMode = SequenceManager.PresentMode.CloneAll,
	stopPolicy = SequenceManager.StopPolicy.Restore,
	onFrame = function(frame) end,
	markers = { [3] = function() end },
})
if ok and handle then
	-- SequenceManager:StopHandle(handle)
end

-- 图集 + 运行时 sheet
SequenceManager:PlaySequence(imageLabel, "爆炸图集", {
	fps = 24,
	sheet = {
		imageId = "rbxassetid://123",
		cellWidth = 128, cellHeight = 128,
		columns = 4, frameCount = 8,
	},
})

-- Crossfade 柔和切帧
SequenceManager:PlaySequence(imageLabel, "加速线", {
	fps = 20,
	loop = true,
	playMode = SequenceManager.PlayMode.PingPong,
	presentMode = SequenceManager.PresentMode.Crossfade,
	crossfadeSec = 0.04,
	layerTransparency = 0.3,
})
```

---

## 11. rp18 迁移对照

| 旧 | 新 |
|----|-----|
| `PlaySequenceEx(...)` | `PlaySequence(label, name, options)` |
| `options.mode` | `options.presentMode`（含 CloneAll） |
| `options.speedScale` | `options.speed` |
| `options.pingPong = true` | `options.playMode = PlayMode.PingPong` |
| `SetPlaybackSpeed` | `SetSpeed` |
| `SetLayerTransparency` | 同名（现返回 `true/false, ErrorCode`） |

---

## 12. 行为备忘（排障）

- 仅客户端；目标为 `ImageLabel` 或 `ImageButton`。
- Destroy 或脱离 DataModel（非 `game` 后代）自动停；换父瞬时 `Parent=nil` 不误停。
- Crossfade 叠化墙钟时间；Seek/SeekTime 中断叠化并硬切。
- `IsPlaying` 含循环间隔等待；`GetTimeProgress` 等待期不累加 `playedTime`。
- 单实例时钟异常不影响其它在播实例。