# CharacterMotion 模块技术说明

> OW 级可控速度电机：Drive（主动位移）+ Impulse（击退/衔步）共享合成→意图路程→Blockcast 扫掠。  
> 创建：2026-08-05 · 修订：2026-08-06（仅 XZ LV；MaxAxesForce∞ 压摩擦；PlatformStand；PreSimulation；默认 SlideAlong；合成软主导）

## 1. 产品契约（单写入者）

角色**平面速度**唯一经本模块写入：

| 写入 | API | 用途 |
|------|-----|------|
| Drive | `Begin` / `End` / `EndTravel` / `ReleaseControlLock` / `Interrupt` / `ForceCleanup` | 闪避、突进、技能冲刺 |
| Impulse | `AddImpulse` / `ApplyKnockback` | 击退、Interrupt 衔步 |

每 tick：`Compose(Drive + ΣImpulse)` → **意图路程** → **Blockcast** 扫掠 → **仅 XZ** 写 `LinearVelocity`（Y 力=0；活跃期 PlatformStand）。

**禁止：** 角色 `BodyVelocity` / 业务直写 `AssemblyLinearVelocity`；第二套位移物理。  
**允许例外：** 可破坏物碎片（`HitBroken`）仍可用 BodyVelocity。  
**Gate 唯一模板：** `DashStyleRoll`；已清退 `DirectionalRoll`，禁止再引入裸 BV 翻滚 Action。  
**不做：** SkillActionLock / LockMovement / CMS / Ability Timeline（属技能编排层）。

技能消费方示例：`DashStyleRoll` + `NewRoll`（控制相位 Gate，非电机内核）。

## 2. 模块边界

| 模块 | 职责 |
|------|------|
| **CharacterMotion** | VelocityMotor、Drive Session、Impulse/Knockback API、Jump/Sprint `PushLock`、Rubberband、查询 |
| **SystemCharacterMotion** | 服包络：能力位移窗（**仅观测**）+ 击退短窗（可钳回）；`FireKnockback`；拒释 `RejectRubberband` |
| **DashStyleRoll** | 技能控制相位 Gate（Travel / Cancel / ActionLock）；调用电机 |
| **HitResolver** | 服命中结算 → `FireKnockback` → 所有者客户端 `ApplyKnockback` |
| **CharacterControl** | 输入 Intent / LockMask；不写 LV |

```text
输入 / 技能 / 受击
        │
        ▼
 CharacterMotion VelocityMotor（Heartbeat）
   Compose(Drive + ΣImpulse) → 意图路程 → Blockcast → 仅 XZ LinearVelocity
        │
        ├─ Drive：Begin Session（motionTier 默认 50）
        └─ Impulse：AddImpulse / ApplyKnockback（Knockback tier 默认 100）
```

速度是**被设计的状态**（可钳制、清零、忽略质量），不是真刚体。

## 3. 客户端 API

```lua
local CharacterMotion = Utils.CharacterMotion
local recipe = CharacterMotion.GetRecipe("NewRoll", "Forward")

-- Drive
CharacterMotion.Begin(character, {
  sessionId = "Skill:NewRoll:" .. castId,
  recipe = recipe, -- 可含 composeCap / easingStyle / speedKeys
  directionWorld = flatDir,
  controlMask = { Jump = true, Sprint = true },
  adoptIfPresent = isSoftMerge,
  elapsedSec = elapsed,
  faceDirection = moveDir2D,
})

CharacterMotion.EndTravel(character, sessionId)
CharacterMotion.ReleaseControlLock(character, sessionId)
CharacterMotion.ForceCleanup(character, sessionId)

-- 取消衔步：不定死 peak；默认 peak = clamp(|lastPlanar|*0.55, 10, 55)；collision=SlideAlong
CharacterMotion.Interrupt(character, sessionId, {
  earlyEndBoostDuration = 0.22,
  earlyEndBoostScale = 0.55, -- 可选；缺省 Constants.DEFAULT_INTERRUPT_BOOST_SCALE
  -- earlyEndBoostPeakSpeed = 40, -- 仅 >0 时绝对覆写
  earlyEndBoostEasingStyle = Enum.EasingStyle.Quad,
  earlyEndBoostEasingDirection = Enum.EasingDirection.Out,
  -- deferImpulse = true, -- DashStyleRoll：ForceCleanup 后再 AddImpulse
})

-- 击退（默认 SlideAlong + Linear + 0.15s + tier=100 + air×0.85）
CharacterMotion.ApplyKnockback(character, {
  id = "Knock:" .. castId,
  direction = flatAway,
  speed = 60,
  massScale = 1,
  -- airMultiplier / collisionPolicy / interruptDrive 可覆盖
})

CharacterMotion.AddImpulse(character, {
  id = "...",
  followMoveDirection = true,
  peakSpeed = 40,
  durationSec = 0.22,
  decay = "QuadOut",
})

CharacterMotion.GetActive(character)
CharacterMotion.GetDriveRemaining(character)
CharacterMotion.HasImpulse(character, id?)
CharacterMotion.RubberbandTo(character, targetPos, durationSec)
```

### ApplyKnockback vs AddImpulse

| | ApplyKnockback | AddImpulse |
|--|----------------|------------|
| 默认 collision | `SlideAlong` | 调用方自定（缺省策略见 Impulse-only） |
| 默认 decay | `Linear` | `Linear` |
| 默认 duration | `0.15` | `0.15` |
| 默认 motionTier | `100`（KNOCKBACK） | `40`（IMPULSE） |
| 与 Drive | 默认叠加；`interruptDrive=true` 只拆 Drive | 叠加 |
| 空中 | 默认 `airMultiplier=0.85` | 无 |

### Interrupt 衔步（残速比例）

```text
residual = |Drive.lastPlanar|   -- 须在 End/DestroyAll 之前读取
peak = clamp(residual * scale, MIN, MAX)
```

| 常量 | 默认 | 含义 |
|------|------|------|
| `DEFAULT_INTERRUPT_BOOST_SCALE` | `0.55` | 带走约一半当前冲刺速 |
| `INTERRUPT_BOOST_MIN` | `10` | 下限（降晚取消地板弹） |
| `INTERRUPT_BOOST_MAX` | `70` | 上限（长冲峰速衔步） |
| `DEFAULT_INTERRUPT_BOOST_COLLISION` | `SlideAlong` | 衔步默认墙策略 |
| `DRIVE_END_BLEND_SEC` | `0.30` | 有移向时残速→走速混合 |
| `DRIVE_END_BLEND_IDLE_SEC` | `0.525` | 无操作时滑行收束 |

`earlyEndBoostPeakSpeed > 0` 绝对覆写。`ResolveInterruptBoostPeak` 可单独查询。  
`DashStyleRoll` 取消：`deferImpulse=true` → Over/`ForceCleanup` 后再 `AddImpulse`（`SlideAlong`）。  
Drive 软结束：`DriveEndBlend`（`blendToWalk` + QuadOut）；WalkSpeed=0 时用 `ExpectedWalkSpeed`；软收尾 `preserveDriveEndBlend`。  
DashStyleRoll：解锁延后放 ActionLock；接 3C 用 `FadeOutSoftKeepPriority`（勿 Demote→Core）。

## 4. 物理契约

- **PreserveY（真义）**：`LinearVelocity` 仅约束 XZ（`ForceLimitMode=PerAxis`，`MaxAxesForce=(∞,0,∞)`）；重力/跳跃归物理。**禁止**把 `AssemblyLinearVelocity.Y` 写进 `VectorVelocity`。XZ 轴力用 `math.huge`：有限力（如 5e4）压不过贴地摩擦，地面冲刺会远短于空中。
- **Humanoid 压制**：Drive / Impulse（含 DriveEndBlend）活跃期 `PlatformStand=true`；电机 tick 绑 `PreSimulation`；完全空闲时还原 PlatformStand。
- **composeCap**：加权合成后的平面合速上限；默认 `Constants.DEFAULT_COMPOSE_CAP`（200）。
- **软主导合成**：`COMPOSE_SOFT_DOMINANCE`（默认 true）时，Drive 与 Impulse 并存：`v = vDrive*(driveTier/maxTier) + vImpulse*(impulseTier/maxTier)`，再套 composeCap。例：Knockback(100)+Drive(50) → 击退全量 + 冲刺×0.5。仅单侧活跃或开关 false 时裸加。硬拆 Drive 仍用 `interruptDrive=true`。
- **意图路程**：预算累加碰撞裁切后的 `|vPlanar| * dt`。
- **碰撞**：默认 `SlideAlong`（`DEFAULT_COLLISION_POLICY` / `DEFAULT_IMPULSE_COLLISION`）；按最高 motionTier 的 policy；同 tier 更严：`StopOnHit > SlideAlong > MaxForceClip`；Blockcast。`MaxForceClip` / `StopOnHit` 须 recipe 或 opts 显式指定。
- **IMPULSE_ENDED_ATTR**：语义 = DriveEnded；改名另开兼容 PR。
- **ForceCleanup**：清物理时同步摘 Session。
- **DriveEndBlend**：软结束 `blendToWalk` + QuadOut；有移向 `0.30` / 无操作 `0.525`；软收尾可 `preserveDriveEndBlend`。

## 4.1 源仲裁（motionTier）

| 源 | 默认 tier | 行为 |
|----|-----------|------|
| Knockback Impulse | 100 | 默认与 Drive **软主导叠加**；`interruptDrive=true` 只拆 Drive |
| Drive Session | 50 | 异 session：新≥旧替换 Drive；新低于旧拒 Begin |
| InterruptBoost / 普通 Impulse | 40 | 与 Drive 软主导叠加 |

## 4.2 Drive 曲线可编

- `easingStyle` / `easingDirection`（缺省 Quad/Out）
- `speedKeys`：分段线性 `factor * planeSpeed * dir`；无 keys 则 start→goal Lerp

`AdoptDrive` 按原包络续算。

## 4.3 地面 vs 空中水平距差（定位）

路径已确认：`DashStyleRoll` → `CharacterMotion.Begin` → `VelocityMotor`（唯一写速者）。

已踩过的真因（日志特征 `END(ClearImpulsesIdle) dt≈0.08 residualXZ≈峰速`）：

1. 预测 `End(preserve)` 误调 `EndDriveKeepMarker` → Drive 早死、`IMPULSE_ENDED=true`
2. 正式 `Begin` 的 `clearImpulsesOnBegin` 打出 `ClearImpulsesIdle`；`AdoptDrive` 因标记失败
3. LV 拆掉后留下高残速：地面摩擦急刹、空中滑行 → **体感水平距可差数倍**（与摩擦改力无关）

修复：预测交接用 `keepDriveActive=true`（只摘 Session）；正式 `adoptIfPresent` 续跑同一 Drive。

其它分叉（用 `[CM_Debug]` 区分）：

| 现象 | 含义 |
|------|------|
| 整段 Travel `act/cmd` 地面 ≪ 1，空中 ≈ 1 | 冲刺窗内地面仍吃速（摩擦/控制器） |
| 两边 `act/cmd`≈1，但感觉空中更远 | **测量窗不同**：只比电机活跃期 `\|dXZ\|` |
| BEGIN 里 `MaxAxesForce`/`PS` 异常 | 未热更到预期配置 |

开启：`Constants.DEBUG_PLANAR_MOTION` 或 `LocalPlayer:SetAttribute("CM_DebugMotion", true)`。  
对比：平地前冲 + 跳起同向冲，**只比两条完整 Travel 的 END `|dXZ|` / `act/cmd`**（寿命应≈ tweenDuration）。

## 5. soft-merge（能力位移）

1. 预测 `End(preservePhysicsToken=true, keepDriveActive=true)`：只摘 Session/锁，**Drive 继续跑**。  
2. 正式 `Begin(adoptIfPresent=true)` 收养同令牌；异 session 时勿 `EndDriveKeepImpulses`。  
3. 过 Travel：Gate 跳过 Begin。  
4. 拒释：`ForceCleanup`。  
5. `EndTravel`（自然结束）仍用 `preserve` **无** `keepDriveActive` → `EndDriveKeepMarker` 软收束。

## 6. 服包络

| 窗 | API | 说明 |
|----|-----|------|
| 能力位移 | `OpenWindow` / `CloseWindow` | maxDistance×SLACK 仅观测（warn+计数，**不** EnvelopeClamp）；默认窗长 = tween + DRIVE_END_BLEND + 0.10 |
| 关窗时机 | NewRoll `Server_ExitRolling` | Travel/Rolling 结束即关；`onEndServer` 兜底 |
| 击退 | `OpenKnockbackWindow` / `CloseKnockbackWindow` | 与能力窗分表；超距仍 `EnvelopeClamp` |
| 纠偏 | `SynPlayerCFrame` → `RubberbandTo` | 击退 EnvelopeClamp / 拒释 RejectRubberband（能力冲刺不拉回） |
| 击退下发 | `FireKnockback` | → 客户端 `ApplyKnockback`（可覆盖 air/collision） |

## 7. Recipes / NewRoll 手感（长冲）

主轴（Forward）：`Travel=Rolling=0.4s`；`controlUnlock=0.38`；`INVULN=0.35`（嵌套前段）；Cancel ⊆ 约 0.25–0.38；闪现 FX UnFade@0.30 落在前段。

| 向 | tween | planeSpeed | endFactor | cancel | boost scale |
|----|-------|------------|-----------|--------|-------------|
| Forward | 0.4 | 80 | 0.12 | 0.25+0.13 | 0.55 |
| Backward | 0.40 | 65 | 0.05 | 0.20+0.20 | 0.5 |
| Left/Right | 0.45 | 70 | 0.05 | 0.25+0.18 | 0.5 |

- Forward `speedKeys`：`1 → 0.92@0.35 → 0.55@0.65 → 0.12`；`maxDistance` 按 keys 积分。
- Forward `animationSpeed=1.0`、`animationWeightFadeTime=0.90`；Recovery=1.15；Action overTime≈2.3。
- 解锁：延后 ActionLock；接 3C 用 SoftKeepPriority 淡出；无操作不砍翻滚。
- DriveEndBlend：有移向 0.30 / 无操作 0.525，QuadOut；软收尾保留 blend。
- 侧后简化 `speedKeys`；碰撞 `SlideAlong`；`clearImpulsesOnBegin=true`；`enforceMaxDistance=false`。
- 包络：Rolling Exit 关窗；能力窗仅观测；默认窗长 = tween + DRIVE_END_BLEND + 0.10。

## 8. 防回归（单写入者）

- SkillAction 禁止角色位移 `BodyVelocity`；Gate=`DashStyleRoll`。
- 禁止复活 `DirectionalRoll`。
- 角色击退走 `ApplyKnockback`；碎片可用 BV。

## 9. 延后（Phase 3+）

- ActionArbiter Knockback 档 / 受击动画
- 垂直模式、服仿真 / rewind
- `IMPULSE_ENDED_ATTR` 改名
- NPC 无所有者击退
- per-source composeCap / 路程预算

## 10. 相关文件

- `ToolSystem/CharacterMotion/`
- `SystemCharacterMotion.luau`
- `SkillAction/DashStyleRoll.luau`
- `SkillModule/NewRoll/`（`init.luau` + `Fx.luau`）
- `HitResolver.luau` / `PlayerSkillClientManager`

## 11. 手测清单（长冲）

- [ ] Forward 完整约 0.4s；尾速量级 ×0.12；中段有平台感
- [ ] 控制解锁约 0.8s 可走/跳/奔；电机可略晚结束；接走丝滑（DriveEndBlend 0.38 Linear）
- [ ] 无敌仅前约 0.35s（非全程无敌）
- [ ] 取消约 0.6–0.8；须侧/后转向；衔步贴墙可滑
- [ ] 前冲动画 ×1；解锁无操作时翻滚不立刻被砍；技能自然结束软淡出；有移向/跳再交接 loco
- [ ] 能力超距只打 observe log、不拉回；击退超距仍可 Clamp
- [ ] soft-merge / 再滚清击退 / 取消衔步无回归
- [ ] 地面击退撞墙可滑；空中水平约 85%；显式 `StopOnHit` 仍可钉墙
- [ ] 同条件空中前冲：水平距大致稳定；不起跳上飘、不因起跳相位飘出超远
- [ ] 起跳顶点 / 上升段 / 下落段释放：竖直仍跟重力，电机只改 XZ
- [ ] 平地无障碍前冲 vs 原地跳起同向冲：水平 `|Δxz|` 接近（PlatformStand + MaxAxesForce.X/Z=∞ 压摩擦）
- [ ] 冲刺中 PlatformStand=true；电机完全空闲后还原，可正常走跳
- [ ] 指令 `|vPlanar|` 与实际 `|ALV.xz|` 地面大致贴合（不再 act≪cmd）
- [ ] soft-merge / 取消衔步 / 击退 SlideAlong 无回归
- [ ] 平地前冲撞墙：贴墙滑（默认 SlideAlong），不钉死、不主要靠引擎夹速
- [ ] 前冲中 `ApplyKnockback`（默认叠）：合速明显低于两峰裸加；不明显「加速冲」
- [ ] `interruptDrive=true`：Drive 立刻停，只剩击退
- [ ] 显式 `collisionPolicy="MaxForceClip"` 仍可走旧墙策略（若临时改测）