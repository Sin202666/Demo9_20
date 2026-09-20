# Lighting 模块技术说明

客户端大气 / 天气 / 视觉时钟统一栈的技术参考。业务侧**只经 `LightingManager` Bindable** 发消息；勿直接 `Utils.SystemLighting.new` / `CustomState.new` / 绕过 Weather 写通道。

---

## 1. 目标与边界

| 能力 | 说明 |
|------|------|
| 天气基线 | 按 `LightingConfig` 包切换世界大气（昼夜等） |
| 临时租约 | 技能 / 副本等覆盖天气，带 priority / TTL |
| 自定义叠加 | UI 模糊等，同 ClassName 按权重择优 |
| 视觉时钟 | 客户端 `Lighting.ClockTime`；权威在服端 `ClockAuthority` |
| 画质降级 | 低档跳过 Bloom / DoF / SunRays，关 Cloud 微动 |
| 与 FX 共存 | 技能 CC 曲线占 `FXUtilCcBusy`，天气侧跳过写 CC |

**不做：** 服务端权威写 `Lighting.ClockTime`；业务直写天气通道 Instance；在 System 内绑 Remote。

---

## 2. 分层架构

```text
业务 / ClockManager / UI
        │ Bindable（NetWork）
        ▼
LightingManager          ← 薄编排：路由消息、FX 下降沿、角色销毁清 Skill lease
        │
        ▼
SystemLightingWeather    ← baseline + lease 栈 + overlay reconcile + coalesce
        │ createForOwner
        ├── SystemLighting           ← 通道写入（Lighting 属性 + PostEffect）
        └── SystemLightingCustomState ← 自定义叠加状态机

ToolBasic：LightingTweenUtil / ChannelResultUtil
配置：Assets.LightingConfig / Assets.LightingStates
缓动：GameConfig.LightingTween
常量：EnumMgr（Weather* / Lighting*）
```

| 层 | 路径 | 职责 |
|----|------|------|
| Manager | `StarterPlayerScripts/Manager/LightingManager` | 仅路由与会话级监听 |
| Weather | `SystemModule/SystemLightingWeather` | 生效层编排、lease、debug Attribute |
| Lighting | `SystemModule/SystemLighting` | 真正写 `Lighting` / 各效果 Instance |
| CustomState | `SystemModule/SystemLightingCustomState` | overlay 择优与三态 apply |
| Tween | `ToolBasic/LightingTweenUtil` | 过渡规范化与缓动 |

**单例闸门：** `SystemLighting` / `CustomState` 仅允许 `createForOwner("SystemLightingWeather")`；`new()` 恒 `nil`。Weather 应由 Manager 经 `Init()` 唯一持有。

---

## 3. 写者优先级

### 3.1 通道侧（同一效果谁最终写 Instance）

1. **FxLease** — 仅 `ColorCorrection`；`Lighting.FXUtilCcBusy == true` 时跳过写 Instance（`FxBusy`）
2. **CustomOverlay** — `SystemLightingCustomState` 同 ClassName 按权重择优后覆盖
3. **WeatherBase** — 天气配置包；缺子 Instance 则 hide

### 3.2 天气生效层（哪份配置包）

```text
生效配置 = 最高 priority 的活跃 lease；无 lease 则用 baseline
平局：后 Acquire 者胜（order）
```

`WeatherWriterPriority`（`EnumMgr`）：

| 名 | 值 | 用途 |
|----|-----|------|
| Baseline | 0 | **不可** ACQUIRE；走 `LIGHTING_BASELINE_CHANGE` |
| Skill | 100 | 技能临时天气 |
| Dungeon | 200 | 副本等；默认无 TTL |

---

## 4. 业务消息 API

均经 `Utils.NetWork.FireBindable(Utils.NetMsg.xxx, ...)`。

| 消息 | 参数 | 语义 |
|------|------|------|
| `LIGHTING_BASELINE_CHANGE` | `name, transitionTime?` | 只改世界 baseline |
| `LIGHTING_CHANGE` | 同上 | 兼容别名，等同 baseline |
| `LIGHTING_ACQUIRE` | `writerId, name, transitionTime?, priority?, force?, ttl?` | 建 / 刷新 lease |
| `LIGHTING_RELEASE` | `writerId, transitionTime?` | 释放指定 writer |
| `LIGHTING_FORCE_CLEAR` | `maxPriority?, transitionTime?` | 清 `priority <= max` 的 lease |
| `CLOCK_CHANGE` | `clockTime, transitionTime?, force?` | 视觉钟；勿直写 `Lighting.ClockTime` |
| `LIGHT_CUSTOM_CHANGE` | `customName, nowState, transitionTime?` | 开关自定义叠加 |

### 4.1 返回值与落地语义（重要）

- `Acquire` / `setBaseline` 返回 **true = 请求已接受**，画面经同帧 **coalesce 异步**落地。
- **勿**把 Bindable 返回值当成「画面已切换成功」。
- 落地判定：

```lua
local L = game.Lighting
local landed = L:GetAttribute("LightingAppliedName") == L:GetAttribute("CurrentLightingName")
	and L:GetAttribute("LightingApplyPending") ~= true
	and L:GetAttribute("LightingLastError") == nil
```

- 上线健康检查须：`LightingBootReady == true`（缺 `Assets.LightingConfig` 或 Weather 降级时为 false）。

### 4.2 使用示例

```lua
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork, NetMsg, EnumMgr = Utils.NetWork, Utils.NetMsg, Utils.EnumMgr

-- 1. 世界天气
NetWork.FireBindable(NetMsg.LIGHTING_BASELINE_CHANGE, "Day", 5)

-- 2. 技能临时天气（TTL 30s；priority 须为 Skill / Dungeon）
NetWork.FireBindable(
	NetMsg.LIGHTING_ACQUIRE,
	"SpaceSkill1",
	"空间技能",
	0.25,
	EnumMgr.WeatherWriterPriority.Skill,
	false,
	30
)
NetWork.FireBindable(NetMsg.LIGHTING_RELEASE, "SpaceSkill1", 0.5)

-- 3. 容灾：清 Skill 及以下（CharacterRemoving 也会清 Skill）
NetWork.FireBindable(NetMsg.LIGHTING_FORCE_CLEAR, EnumMgr.WeatherWriterPriority.Skill, 0)

-- 4. UI 模糊叠加
NetWork.FireBindable(
	NetMsg.LIGHT_CUSTOM_CHANGE,
	EnumMgr.LightingCustomState.UiBlur,
	true,
	0.2
)

-- 5. 视觉时钟
NetWork.FireBindable(NetMsg.CLOCK_CHANGE, 18, 0)
```

---

## 5. 配置与契约

### 5.1 资源目录

| 目录 | 用途 |
|------|------|
| `ReplicatedStorage.Assets.LightingConfig` | 天气包：名为 Configuration，Attribute + 子效果 Instance |
| `ReplicatedStorage.Assets.LightingStates` | 自定义状态模板；名与 `EnumMgr.LightingCustomState` 一致 |

Clock 相关（`GameConfig.Clock`）：白天 / 夜晚天气名、光照切换秒数等，由服端写 `LightingBaseline` / `ClockAuthority`，客户端 Manager 兜底跟写。

### 5.2 天气包 schema（`ApplyPipeline.validateLightingConfig`）

**Lighting Attribute（出现则类型须匹配；缺省允许）：**

`Ambient`, `Brightness`, `EnvironmentDiffuseScale`, `EnvironmentSpecularScale`, `ExposureCompensation`, `ShadowSoftness`, `OutdoorAmbient`, `GeographicLatitude`

**白名单通道 ClassName（不得重复；ClassName 须等于类型名）：**

`Clouds`, `Atmosphere`, `Sky`, `ColorCorrectionEffect`, `BloomEffect`, `BlurEffect`, `SunRaysEffect`, `DepthOfFieldEffect`

缺子 Instance → 该通道 **hide**。关闭 PostEffect：**先即时写目标属性，再 `Enabled=false`**（不做关闭过程属性 Tween）。

### 5.3 自定义状态

- 注册名：`LightingCustomState.UiBlur` / `NpcDialogBlur`（与模板 Instance.Name 一致）
- 权重：模板 Attribute `StateHighWeight` / `StateLowWeight`，缺省回退注册表
- create 时 Clone 模板（Parent=nil）；运行时不改 Assets 原件
- Overlay 三态：`applied` / `held`（有优胜但未写，**禁止回退天气**）/ `none`（走天气包）

### 5.4 过渡缓动

`GameConfig.LightingTween`：`缓动样式` / `缓动方向`（Enum 名，非法回退 Quad/Out）。`transitionTime` 由 `LightingTweenUtil.normalizeTransitionTime` 统一（nil / 负 → 0）。

---

## 6. SystemLighting 通道写入

| 子模块 | ClassName / 职责 |
|--------|------------------|
| `Lighting.luau` | Lighting 服务属性 + ClockTime（最短弧过渡） |
| `Cloud` | Clouds；低画质关微动 |
| `Atmosphere` / `Sky` | Atmosphere / Sky |
| `ColorCorrection` | CC；尊重 FXUtilCcBusy |
| `Bloom` / `Blur` / `SunRays` / `DepthOfField` | 对应 PostEffect |
| `EffectChannelUtil` / `PostEffectChannel` | 私有通道工具 |

**公开 API（仅 Weather 调用）：**  
`beginApplyGeneration` / `applyWeatherBase` / `applyChannelFromConfig` / `applyEffectFromInstance` / `setClockTime` / `getClockTime` / `setGraphicsQualityLow` / `destroy`

- `applyGen`：全量 / 增量 apply 前 bump；Tween Completed 校验作废过期副作用  
- 单通道 pcall 隔离：一通道抛错不中断其余；硬错误进 `LightingLastError`  
- 预期跳过 `FxBusy` / `QualitySkip` → `LightingSkipReason`，不污染 LastError  

低画质跳过类（`LightingQualityLowSkipClass`）：`BloomEffect`, `DepthOfFieldEffect`, `SunRaysEffect`。  
**低→高不自动 restore**，须 `weather:reapplyEffective`（QualityGate 已在画质变化且首次 apply 后绑定）。

---

## 7. Weather 内部子模块

| 子模块 | 职责 |
|--------|------|
| `LeaseStack` | lease 纯逻辑：priority / TTL / 优胜 / Stale / HardMax |
| `LeaseLifecycle` | TTL / StaleWarn / HardMax 的 delay 调度 sweep |
| `ApplyPipeline` | 配置查找、schema、生效 apply / 单通道 reconcile、Attribute 同步 |
| `ApplyCoalesce` | **生产路径**同帧合并全量 / 增量；`transitionTime` last-wins；时钟不合并 |
| `QualityGate` | 监听 `Player.Setting.GraphicsQuality`，驱动低画质 + reapply |
| `DebugAttrs` | Lighting Attribute 名表 |

生产全量 / 增量必须走 Coalesce；`ApplyPipeline.applyEffectiveIfChanged` 仅同步 / 测试辅助。

---

## 8. Lease 生命周期常量（EnumMgr）

| 常量 | 默认 | 说明 |
|------|------|------|
| `WeatherLeaseDefaultTtl` | Skill=120 / Dungeon=0 / Other=60 | `ttl=nil` 用表；`0`=永不过期；`>0`=秒 |
| `WeatherLeaseExpireTransitionSec` | 0.5 | TTL 到期释放过渡 |
| `WeatherLeaseStaleWarnSec` | 600 | 无 TTL 过久 → `LightingStaleLeaseWriters` + warn |
| `WeatherLeaseHardMaxSec` | 1800 | 无 TTL 硬上限自动释放（容灾）；`0` 关闭 |
| `WeatherAcquireForceMinIntervalSec` | 0.05 | 同 writer 过密 force → 降级非 force |
| `WeatherMaxActiveLeases` | 16 | 新 writer 超限 fail-closed |

- ACQUIRE：非法 priority（含 Baseline）/ 缺配置 / schema 失败 → **不建 lease**  
- 同名生效层 noop（对比 `LightingAppliedName` / `_effectiveName`）；强制重放用 `force` 或 `reapplyEffective`  
- 副本退出仍须业务 `FORCE_CLEAR` / `RELEASE`（HardMax 仅兜底）  
- `CharacterRemoving`：Manager 清 `priority <= Skill`，Dungeon 保留  

---

## 9. 调试 Attribute（`game.Lighting`）

| Attribute | 含义 |
|-----------|------|
| `CurrentLightingName` | 意图名（lease 优胜或 baseline） |
| `LightingAppliedName` | 最近一次天气 apply **成功落地**名（失败不推进） |
| `CurrentBaselineLightingName` | 当前 baseline 名 |
| `LightingLeaseCount` | 活跃 lease 数 |
| `LightingTopLeaseWriter` | 当前优胜 writerId |
| `LightingLastError` | 硬错误（缺配置 / schema / 通道硬错 / 非法参数等） |
| `LightingSkipReason` | 预期跳过：`FxBusy` / `QualitySkip` / 等 |
| `LightingOverlayTop` | 当前 overlay 优胜名摘要 |
| `LightingStaleLeaseWriters` | 无 TTL 且过久的 writerId（逗号拼接） |
| `LightingApplyPending` | coalesce 已排队未 flush |
| `LightingBootReady` | 编排可用且 Config 目录存在 |
| `FXUtilCcBusy` / `FXUtilCcBusyGen` | FX 占用 CC；下降沿 + Gen 防抖后仅 reconcile CC |

非法消息可由 Manager 调 `weather:reportClientError` 写入 LastError。

---

## 10. 时钟语义

```text
服端 ClockAuthority（NumberValue）  ──权威逻辑时刻──►
客户端 CLOCK_CHANGE / weather:setClockTime  ──► Lighting.ClockTime（视觉）
```

- `getClockTime`：客户端**目标缓存**；Tween 中途可与服务 `ClockTime` 不一致  
- `force=true`：目标与缓存相同仍重放（中途重同步）；已到位且无过渡仍为 no-op  
- ClockTime 过渡走**最短弧**（±12h），避免 23→1 倒放整天  
- `GameConfig.Clock.启用=false` 时不创建 ClockAuthority / TimeSlot / LightingBaseline  

Manager 启动兜底：若 Authority / LightingBaseline 已存在而监听尚未就绪，主动跟写一次，避免默认 Day 卡住。

---

## 11. 与 FXUtil 的关系

| 场景 | 路径 |
|------|------|
| 技能 / 演出滤镜曲线 | `FXUtil.PlayColorCorrectionCurve`（占 `FXUtilCcBusy`，递增 Gen） |
| 天气 / UI 模糊等 | Weather → Lighting / CustomState |
| 租约释放后 | Manager 监听 busy 下降沿 → `weather:onFxCcBusyReleased()` → **仅 reconcile CC** |

天气 apply 遇 busy：CC 通道跳过写，记 `FxBusy`，不把整次天气当硬失败。

---

## 12. apply 结果码（`LightingApplyResult`）

| 码 | 含义 |
|----|------|
| `Ok` | 已写 / 已 hide / 已开 Tween |
| `UnknownClass` / `InvalidArg` | 参数或类型无效 |
| `QualitySkip` | 低画质跳过 |
| `FxBusy` | FX 占用，跳过写或 hide |
| `ChannelError` | 通道 apply/hide 抛错（pcall） |

---

## 13. 约定与禁止项

**应做**

- 业务只发 Bindable；健康检查看 `BootReady` + 落地三元组  
- 技能用 Skill + TTL；副本退出显式 RELEASE / FORCE_CLEAR  
- 自定义模糊走 `LIGHT_CUSTOM_CHANGE`  
- 时钟走 `CLOCK_CHANGE`  

**禁止**

- `Utils.SystemLighting.new` / `CustomState.new`（恒 nil）  
- 业务直调 Weather / Lighting 写通道（除 Manager）  
- 绕过 coalesce 在生产路径调 `applyEffectiveIfChanged`  
- 把 `Acquire==true` 或 `LightingApplyPending==true` 当成画面已成功  
- 把 `FxBusy` / `QualitySkip` 当上线阻断硬错误（看 LastError / BootReady）  

---

## 14. 相关源码索引

| 模块 | 路径 |
|------|------|
| LightingManager | `src/StarterPlayer/StarterPlayerScripts/Manager/LightingManager/init.client.luau` |
| SystemLightingWeather | `src/ReplicatedStorage/ClientSideCode/SystemModule/SystemLightingWeather/` |
| SystemLighting | `src/ReplicatedStorage/ClientSideCode/SystemModule/SystemLighting/` |
| SystemLightingCustomState | `src/ReplicatedStorage/ClientSideCode/SystemModule/SystemLightingCustomState.luau` |
| LightingTweenUtil | `src/ReplicatedFirst/AllSideCode/ToolBasic/LightingTweenUtil.luau` |
| ChannelResultUtil | `src/ReplicatedFirst/AllSideCode/ToolBasic/ChannelResultUtil.luau` |
| 类型桩 | `src/ReplicatedFirst/AllSideCode/Interface/SystemLighting*-Type.luau` |
| 枚举 / 消息 | `EnumMgr.luau` / `NetMsg.luau` |
| 配置 | `GameConfig.Clock` / `GameConfig.LightingTween` |

文件头注释含更细的边界语义与用例；本说明作跨模块总览，实现细节以对应模块头为准。
