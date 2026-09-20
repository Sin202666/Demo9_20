# CameraModule 模块技术说明

客户端相机控制与震动统一栈的技术参考。业务侧**只经 `Utils.CameraModule` 注册/注销事件与震动**；勿自行 `BindToRenderStep` 写 `CurrentCamera.CFrame` / `FieldOfView`。

---

## 1. 目标与边界

| 能力 | 说明 |
|------|------|
| 主相机事件 | 按优先级接管 Scriptable 相机与绝对 FOV；栈空归还开镜前轨道 |
| 辅助事件 | 无主事件时叠加 CFrame / FOV 偏移；主事件生效期间 mute Helper |
| 相机震动 | 多层 Trauma + 方向 Kick + 命名源 Sustain |
| CameraMode 栈 | Default / ShiftLock / OTS / LockOn / Aim；基线肩偏 Helper |
| ShiftLock 同步 | `MouseBehavior.LockCenter` → `LocalPlayer.IsShiftLocked`；键重绑 |
| 设置震动强度 | 监听 `LocalPlayer.Setting.Shake`（0~1 或 0~100） |

**不做：** 服务端写相机；业务旁路写 CFrame/FOV；用主事件做日常跟拍（日常跟拍走 CameraMode / 引擎 Custom）。

**相关但不并入本栈：**

| 模块 | 关系 |
|------|------|
| `CameraImpulse` | 仅 FOV 脉冲总线 → `AnimateFov` Helper；不写 CFrame |
| `HatchCamera` | 可写 `CameraMinZoomDistance`；禁止旁路写 CFrame |
| `AnimateFov` | 唯一「移速影响相机FOV」Helper 消费者 |

---

## 2. 分层架构

```text
业务 / 技能 / Animate / Setting UI
        │ Utils.CameraModule.*
        ▼
CameraManager.client.luau     ← 薄编排：启动时 Init() 一次
        │
        ▼
CameraModule (init.luau)      ← 主事件栈 / Helper / RenderStep 合成 / 公开 API
        ├── CameraMode.luau           模式栈 + Attribute + 基线 Helper
        ├── ShakeRuntime.luau         Trauma / Kick / Sustain 运行时
        ├── ShakePresets.luau         震动类型预设（Enum 1-8）
        ├── TraumaNoise.luau          六轴 Perlin 采样
        ├── CameraShiftLock.luau      IsShiftLocked 同步与开关键重绑
        ├── CameraSettingShake.luau   Setting.Shake 监听
        └── CameraHandoff.luau        开镜快照 / 轨道归还 / FOV 退出过渡

配置：GameConfig.CameraModule
枚举：EnumMgr.CameraShakeType / EnumMgr.CameraMode
类型桩：Interface/CameraModule-Type.luau
FOV 脉冲：ToolSystem/CameraImpulse → AnimateFov
```

| 层 | 路径 | 职责 |
|----|------|------|
| Manager | `StarterPlayerScripts/Manager/CameraManager.client.luau` | 仅 `Init()`；须先于 CharacterScripts 业务注册 |
| CameraModule | `SystemModule/CameraModule/init.luau` | 所有权、渲染管线、公开 API |
| CameraMode | `CameraModule/CameraMode.luau` | Push/Pop 模式；不抢主事件 Scriptable |
| ShakeRuntime | `CameraModule/ShakeRuntime.luau` | 震动层合成与限幅 |
| ShakePresets | `CameraModule/ShakePresets.luau` | 只读冻结预设表 |
| TraumaNoise | `CameraModule/TraumaNoise.luau` | 无状态噪声采样 |
| CameraShiftLock | `CameraModule/CameraShiftLock.luau` | IsShiftLocked 与 BoundKeys 重绑 |
| CameraSettingShake | `CameraModule/CameraSettingShake.luau` | Setting.Shake → SetSettingShakeScale |
| CameraHandoff | `CameraModule/CameraHandoff.luau` | 开镜快照、栈空归还、FOV 短过渡 |

---

## 3. 所有权约定（强制）

| 状态 | 允许写入方 |
|------|------------|
| `CFrame` / `FieldOfView` | **仅** CameraModule（主事件 / Helper delta / 震动） |
| `CameraMinZoomDistance` | HatchCamera 抽蛋表现专用 |
| FOV 脉冲（冲刺等） | CameraImpulse → AnimateFov **唯一** Helper |

业务只调用 Enable/Disable / Shake / PushMode；不要平行注册第二个 FOV Helper。

---

## 4. 每帧渲染管线

`BindToRenderStep` 名：`CameraModuleUpdate`  
优先级：`Enum.RenderPriority.Camera + 1`

```text
1. 主事件：priority 最高；同 priority 后注册（更大 Seq）胜出
   → 可设 Scriptable + 绝对 FOV；opts.suppressShake 时跳过震动
2. 震动：ShakeRuntime.ComputeOffset(dt)（可被 suppress / handoff 抑制）
3. 辅助事件：仅无主事件且无 pending handoff 时累计 helperOffset / fovDelta（Seq 升序）
4. 合成：baseCF * shakeOffset * helperOffset → CFrame；按需写 FOV
5. 主事件栈有→无：一帧切回开镜前轨道（Classic look*zoom，不做 CFrame tween）
   → 下一帧同步 PlayerModule/Zoom 后交还 Custom（之后不再硬写 CFrame）
```

补充规则：

- 无活跃主事件且无 Helper 且无 FOV 退出过渡时，**不写** `FieldOfView`（留给引擎/其他合法 Helper 路径）。
- 仅有辅助事件时，以 `GameConfig.CameraModule.默认视野角度` 为基准叠加 `fovDelta`。
- 主事件期间 **mute Helper**（避免过场漏进奔跑 FOV）。

---

## 5. 主事件归还语义

启用首个主事件前捕获 `_preMainSnapshot`：

- `cameraType` / `cameraSubject` / `fieldOfView`
- Classic 风格 `lookVector` + `orbitDistance`（有 Subject 焦点时）
- 回退用当时 `CFrame`

栈空时：

1. Scriptable 下一帧钉开镜轨道（对齐 ClassicCamera：`focus - look * zoom`）
2. 同步 `PlayerModule` 距离 / `lastCameraTransform` 等，并 `ZoomController.ReleaseSpring`
3. 下一帧交还快照中的 `CameraType`（通常 Custom）
4. FOV：快照目标值；无快照时用默认 FOV + 短过渡（`过场FOV过渡秒`）

`FocusPlayer`：**不读**开镜快照，强制 `CameraSubject=本地 Humanoid` + `Custom`，供角色晚到补救。

---

## 6. 业务 API

引入：

```lua
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CameraModule = Utils.CameraModule
local EnumMgr = Utils.EnumMgr
```

变更类 API 返回 `(boolean, string?[, number?])`；查询类返回数据。

### 6.1 主事件 / Helper

| API | 语义 |
|-----|------|
| `EnableCameraEvent(name, priority, fov?, func, opts?)` | 主事件；`func(t,dt)->(CFrame?, fov?)`；`opts.suppressShake` |
| `DisableCameraEvent(name)` | 注销；若为空栈则触发归还 |
| `EnableCameraHelperEvent(name, func)` | 辅助偏移；`func` 返回相对 CFrame 与 **FOV 增量** |
| `DisableCameraHelperEvent(name)` | 注销 Helper |
| `FocusPlayer()` | 强制跟角色；不读快照 |

`EnableCameraEvent_Helper` / `DisableCameraEvent_Helper` 为历史别名，等价于 Helper API。

### 6.2 震动

| API | 语义 |
|-----|------|
| `CameraShakeOnce(type, intensityMul?)` | 推入瞬时 Trauma 层 |
| `CameraShakeAt(type, worldPos, maxDist?, directionalKick?, intensityMul?)` | 距离衰减；默认叠方向 Kick |
| `CameraShakeImpulse(type, worldDir, distanceFactor?, intensityMul?)` | Trauma + 相机局部 Kick |
| `CameraShakeSustain(sourceId, type)` | 命名源引用计数 +1 |
| `CameraShakeStop(sourceId, fadeOutTime?)` | 引用计数 -1；归零后淡出/移除 |
| `CameraShakeCancel(handle, fadeOutTime?)` | 按句柄取消层 + 同 id Kick |
| `SetShakeScale` / `GetShakeScale` | 全局强度 0~1（另乘 Setting） |
| `StopAllShakes(fadeOutTime?)` | 全停；缺省淡出 0.1s；`<=0` 立即清空 |

### 6.3 CameraMode

| API | 语义 |
|-----|------|
| `PushMode(sourceId, mode, priority?)` | 压入/覆盖来源；不可 Push Default |
| `PopMode(sourceId)` | 弹出指定来源 |
| `GetActiveMode()` | 优胜模式名；栈空为 `"Default"` |

引擎用户 ShiftLock → 自动 `PushMode("Engine:MouseLock", ShiftLock)`；Animate 朝向仍读 `IsShiftLocked`。

### 6.4 使用示例

```lua
-- 1. 固定视角过场
CameraModule.EnableCameraEvent("BossIntro", 100, 70, function(t, dt)
	return CFrame.lookAt(Vector3.new(0, 10, 20), Vector3.zero)
end)
CameraModule.DisableCameraEvent("BossIntro")

-- 2. 运镜大招（动态 FOV + 禁震）
CameraModule.EnableCameraEvent("SpaceSkillCam", 120, 70, function(t, dt)
	local cf = KeyframeEval.EvalCFrame(camKeys, t)
	local fov = KeyframeEval.EvalNumber(fovKeys, t)
	return cf, fov
end, { suppressShake = true })

-- 3. 受击 / 爆炸
CameraModule.CameraShakeOnce(EnumMgr.CameraShakeType.Clash)
CameraModule.CameraShakeAt(EnumMgr.CameraShakeType.Explosion, boomPos, 80)

-- 4. 载具持续震
CameraModule.CameraShakeSustain("Vehicle", EnumMgr.CameraShakeType.Ambient)
CameraModule.CameraShakeStop("Vehicle", 0.2)

-- 5. 瞄准模式
CameraModule.PushMode("Skill:Aim", CameraModule.Mode.Aim)
CameraModule.PopMode("Skill:Aim")
```

FOV 脉冲（冲刺）走 Impulse，不走 Shake：

```lua
local CameraImpulse = Utils.CameraImpulse
CameraImpulse.emit(character, {
	kind = "FovPulse",
	id = "Dash:Forward",
	adoptIfActive = true,
})
```

---

## 7. CameraMode 语义

| 模式 | 默认 priority | 行为 |
|------|---------------|------|
| Default | 0（空栈） | 无基线 Helper |
| ShiftLock | 10 | 无基线 Helper；引擎 MouseLock 映射为此模式 |
| OTS | 20 | Helper：肩偏移 `(OTS肩偏移X/Y/Z)` |
| LockOn | 30 | Helper：肩偏移 × `LockOn肩偏移系数` |
| Aim | 40 | Helper：缩小肩偏 + `Aim视野增量`（FOV delta） |

优胜规则：priority 大者胜；同级后 Push（更大 order）胜。  
发布：`LocalPlayer:SetAttribute("CameraMode", mode)`（仅变化时写）。

**现状说明（产品边界）：**  
OTS / LockOn / Aim **不是**独立第三人称轨道控制器（无墙体遮挡、无锁敌目标混合），仅为默认 Custom 上的 Helper 偏移。技能完全接管仍用主事件。

---

## 8. 震动运行时

### 8.1 模型

```text
强度 = trauma² × 全局 scale × Setting scale ×（StopAll 淡出乘子）
偏移 = Σ(噪声 × 层 influence × 全局 influence) + Kick 弹簧位移/转角
合成后硬限幅：震动最大位移 / 震动最大转角
```

- **瞬时层**（Once/At/Impulse）：Attack 上升 → Decay 衰减 → 移除  
- **Sustain**：引用计数；trauma 不低于地板 `0.35`；Stop 归零后可加速衰减或立即移除  
- **Kick**：世界方向转相机局部，写入速度冲量，刚度/阻尼弹簧回零  
- **层上限** `12`：满时驱逐 trauma 最低的非 Sustain；全为 Sustain 则拒绝新瞬时层（返回 `nil`）

### 8.2 预设（`EnumMgr.CameraShakeType`）

| 值 | 名 | 典型用途 |
|----|-----|----------|
| 1 | Attack | 轻攻击 |
| 2 | Clash | 普通碰撞 |
| 3 | BigClash | 重击 |
| 4 | LongClash | 较长冲击 |
| 5 | MagicHit | 魔法（偏水平位姿） |
| 6 | Land | 落地（偏竖直） |
| 7 | Explosion | 爆炸 |
| 8 | Ambient | 环境/载具持续底噪 |

查询：`CameraModule.GetShakePresets()`（只读冻结表）。

### 8.3 距离衰减（PlayAt）

```text
d <= PlayAt最小满幅距离 → factor = 1
d >= maxDistance        → factor = 0
中间                    → 1 - smoothstep(...)
```

默认 `maxDistance = PlayAt默认最大距离`；`directionalKick ~= false` 时叠「事件→听点」Kick（幅度 × `PlayAt方向Kick系数`）。

听点优先：本地角色 `HumanoidRootPart` / PrimaryPart，否则相机位置。

---

## 9. 配置（`GameConfig.CameraModule`）

| 键 | 默认（代码回退） | 含义 |
|----|------------------|------|
| 默认视野角度 | 60 | Helper / 退出回退基准 |
| 过场FOV过渡秒 | 0.15 | 无快照归还时 FOV smoothstep；0=立即 |
| 震动最大位移 | 3 | 合成后 studs 硬限幅 |
| 震动最大转角 | 18 | 合成后度硬限幅 |
| Trauma衰减每秒 | 1.2 | 层缺省 decay |
| Trauma上升秒 | 0.05 | Once 等缺省 Attack |
| 噪声频率 | 12 | roughness 缺省 |
| 降频下限 | 0.2 | 衰减时频率地板 |
| 位置/旋转影响 X/Y/Z | 1 | 全局乘子 |
| Impulse位移/转角系数 | 0.8 / 4 | Kick 幅度 |
| Impulse弹簧刚度/阻尼/冲量系数 | 180 / 22 / 12 | 弹簧积分 |
| PlayAt默认最大距离 | 80 | At 缺省衰减距离 |
| PlayAt最小满幅距离 | 0 | 满幅半径 |
| PlayAt方向Kick系数 | 0.65 | At 自动 Kick；0=关强度 |
| OTS肩偏移 X/Y/Z | 1.5 / 0.35 / 0.5 | CameraMode Helper |
| LockOn肩偏移系数 | 0.6 | 相对 OTS |
| Aim视野增量 | -8 | Aim FOV delta |

ShiftLock 开关键：`GameConfig.CharacterControl.ShiftLock键`（默认 `LeftControl`，与冲刺 LeftShift 分离）。

---

## 10. 错误码

| 码 | 含义 |
|----|------|
| `NOT_INITIALIZED` | 尚未 Init |
| `NOT_CLIENT` | 服务端误调用 |
| `DUPLICATE_EVENT` | eventName 已存在 |
| `EVENT_NOT_FOUND` | Disable / Cancel 找不到目标 |
| `INVALID_SHAKE_TYPE` | 震动类型不在 1-8 |
| `INVALID_ARGUMENT` | 参数类型/取值非法 |
| `CHARACTER_NOT_READY` | FocusPlayer 无角色/Humanoid |
| `SOURCE_NOT_FOUND` | PopMode 找不到 sourceId |

服务端加载模块时 API 为空壳，返回 `NOT_CLIENT`，不绑 RenderStep。

---

## 11. 生命周期

| 步骤 | 说明 |
|------|------|
| `Init()` | 幂等；绑 RenderStep / CurrentCamera / Setting.Shake / ShiftLock；启动 CameraMode |
| `destroy()` | 解绑连接与 RenderStep；清空事件与震动；作废进行中的键重绑 WaitForChild |
| Manager | `CameraManager` 启动调用 Init；失败 `warn` |

StarterPlayerScripts/Manager 默认先于 StarterCharacterScripts，一般无需额外排序。

---

## 12. 约定与禁止项

**应做**

- 业务只经 `Utils.CameraModule` / `Utils.CameraImpulse`
- 运镜大招用主事件 + `suppressShake`
- 日常模式用 `PushMode` / `PopMode`，稳定 `sourceId`
- 爆炸等世界事件用 `CameraShakeAt`
- 持续源用 Sustain + Stop，避免泄漏
- 关闭震动走 Setting.Shake 或 `SetShakeScale(0)`

**禁止**

- 业务 `BindToRenderStep` / 直写 `CurrentCamera.CFrame` / `FieldOfView`
- 平行注册第二个 FOV Helper（冲刺脉冲必须走 CameraImpulse → AnimateFov）
- 用主事件做日常 OTS/瞄准跟拍（应走 CameraMode；完全接管除外）
- 服务端调用震动/事件 API
- 把 `CameraShakeAt` 过远返回的 `handle=nil` 当成错误（成功且未播放）

---

## 13. 相关源码索引

| 模块 | 路径 |
|------|------|
| CameraManager | `src/StarterPlayer/StarterPlayerScripts/Manager/CameraManager.client.luau` |
| CameraModule | `src/ReplicatedStorage/ClientSideCode/SystemModule/CameraModule/` |
| 类型桩 | `src/ReplicatedFirst/AllSideCode/Interface/CameraModule-Type.luau` |
| CameraImpulse | `src/ReplicatedFirst/AllSideCode/ToolSystem/CameraImpulse.luau` |
| AnimateFov | `src/StarterPlayer/StarterCharacterScripts/Animate/AnimateFov.luau` |
| HatchCamera | `src/ReplicatedFirst/AllSideCode/ToolSystem/HatchEffect/HatchCamera.luau` |
| 枚举 | `src/ReplicatedFirst/AllSideCode/ToolSystem/EnumMgr.luau` |
| 配置 | `src/ReplicatedFirst/AllSideCode/ToolBasic/GameConfig.luau` → `CameraModule` |

文件头注释含更细的边界语义与用例；本说明作跨模块总览，实现细节以对应模块头为准。