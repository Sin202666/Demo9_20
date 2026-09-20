# 图复刻 Animate 表现方案

> 日期：2026-09-02  
> 作者：林奥宇  
> 状态：§1.8 **有条件通过**（2026-09-02）；条件见 §8。新会话可按 [`图复刻Animate开工交接.md`](图复刻Animate开工交接.md) 写业务代码。  
> 对照：[`LocoDefault.graph.json`](LocoDefault.graph.json)、P0 Spike、`docs/代码结构和设计开发规范.md` §1.2–1.4 / §1.6 / §1.7 / §1.8

本切片目标是 **loco 选片与切态序列与现网一致**（含起步/停步/落地锁/防抖），不是像素级 100%。脚相位、Land Action 档、Select from→to 边见 §6 缺口。

---

## 0. 目标与非目标

### 目标

- 特性开关双跑：关 = 现网基轨 + StrafeBlend；开 = 一条已发布图轨 `rbxassetid://90774329769612`
- 状态仍由 `GroundLocomotion` 编译；图只 `SetParameter`
- 默认 `GraphLoco.ENABLE = false`，现网行为不变

### 非目标

- 不改 `GroundLocomotion` FSM（最多只读对照）
- 不改已发布图拓扑 / AssetId
- 不新 Remote、不新存档、不把 FSM 搬进图
- 不写 `HRP.CFrame` / `WalkSpeed` / `Store.cframe` / `RootJoint.C0`
- 不 Unbind `AnimateShiftLockFaceCamera`
- 不接 Overlay、不把 Spike 升格为正式 loco、不做 LocoStyle 多图

---

## 1. 权威与写口（§1.6 / §1.7）

| 资源 | 权威 / 写口 | 本切片 |
|------|-------------|--------|
| 位移 / HRP | `CharacterMotion` | 不写 |
| WalkSpeed | `CharacterMoveSpeed` | 不写 |
| ShiftLock 偏航 | Animate `BindToRenderStep` | 不写、不 Unbind |
| 空中 lean | `AirLean` Stepped 写 RootJoint | 不进图 |
| 腿姿（关开关） | `AnimateModule` 基轨 + StrafeBlend | 唯一 |
| 腿姿（开开关且图 Load 成功） | 图 `AnimationTrack` | 唯一；禁止再 Play 经典基轨 |
| 技能 Overlay | `AnimationLayer` | 不进 loco 图 |
| 经济 / 伤害 / 存档 | 服 | 不碰 |

**§1.6：** 纯表现。

**§1.7：** 开/关开关两条腿姿写口互斥，不得双开。Gate `pauseBaseTracks` 时 Stop 图轨（开）或 `stopBaseAction`（关）。打断清理：角色销毁 Stop 图轨。乘骑 `MountActive` 停图，与现网 Mounted 总闸一致。

---

## 2. 分层

- 新模块：`src/StarterPlayer/StarterCharacterScripts/Animate/GraphLocoDriver.luau`（角色动画，不进 Utils）
- 开关：`AnimateSetting.GraphLoco`（不打 Language / ConfigInstance）
- 编排：`init.client.luau`；GroundLocomotion / StrafeBlend / **LocoStyle.Create** / Gate 必须吃 **同一 animate 对象**
- 仅 LocalScript，无 `IsServer`

`init.client` 现状：`animate = Animate` 传给 GroundLocomotion、StrafeBlend、`LocoStyle.Create`。只包装 GroundLocomotion 时 LocoStyle `bindBaseAction` + 解闸 `resync` 会再 Play 经典轨 → 叠播。图模式须包装单例或改单例方法，使上述四方走同一对象。`BasePos` / `BaseActionEnabled` / `BasePosChanged` 不得分裂。

---

## 3. 参数契约（Spike 已验证）

| 参数 | 规则 |
|------|------|
| `LocoState` | 与 Select 针名逐字相同 = `_pose`。含 StartWalk/StartRun/StopRun/Land/LightLand。`StopWalk` 仍尊重 `TransitionEnable.StopWalk=false` |
| `MoveYawRad` | **SetParameter 用弧度**。`getMoveYaw()` 为角度（0 前、+90 右、-90 左）。写入 `math.rad(-yawDeg)`（Polar 左右与脚本相反） |
| `MoveMag` | 走跑恒 `1`；换键 hold 上一 yaw |
| `ClipSpeed` | 只一条。Walk/Run/Climb = `getRunAnimationSpeed`（15/21/20 / RigScale） |

针名消毒：`Walk_Left` / `Walk_Right` / `Walk_Back` / `Run_*` **不得**当 Select 针，映射为 `Walk`/`Run` + yaw。

`playTransition`：图 OnceAndHold 往往无 `Stopped`。代理须返回 `(true, cancelFn)`，完成/取消用 `Transition.commit` / `middleDuration` 合成。GroundLocomotion 内 `task.delay(commit)` 保持不动。

---

## 4. 实现要点

1. **加载顺序：** 先 `LoadAnimation`。失败：Log，整条现网（LocoStyle 照常 bind）。成功：`stopBaseAction`，跳过经典 bind Play，接管图轨。
2. **Stepped：** 四参数；`LocoState` 与 `_pose` 同拍（经代理 `setBasePos` / `playTransition`）。
3. **Gate：** pause → Stop 图轨；解闸 → Play + 当前稳态参数（不播 Start*），与 `resyncAfterBaseUnpause` 同拍。
4. **MountActive：** 上马 Stop 图轨；下马 Play + 稳态参数。
5. **StrafeBlend：** 图模式只输出平滑 yaw + `ZERO_INPUT_HOLD`；`setStrafeBlend` / `clearStrafeBlend` 禁止播双轨。
6. **FootStep：** 图轨 Marker → 现 `FootLand`；Blend2D 转发对不齐则记缺口、速度计步兜底。
7. **与 Spike 运行时互斥：** `GraphLoco.ENABLE` 与 `LocoGraphSpike.SPIKE_ENABLE` 同时真则一方拒绝并 Log。禁止只写文档不管运行时。
8. 销毁：Stop 图轨；不写位移；不 Unbind 偏航。Author = `git config user.name`；UTF-8 无 BOM、LF。

---

## 5. 表现对照

- Idle↔走跑：图吃 StartWalk/StartRun/StopRun（现网 commit 时刻）
- Walk↔Run：Select 过渡；**无** GaitBlend 脚相位（缺口）
- 落地：FSM Land 窗仍在；图 Land 为 Movement 档，业务 Action Idle 可能盖落地（缺口）
- ShiftLock 方向：Polar + 平滑 yaw，替代 Cardinal 双轨
- 非 ShiftLock：yaw≈0，等价前向循环
- ClimbAssist 压 Run→Walk：仍走 `_applyStableLocomotionVisual`，图收到 Walk

---

## 6. 已知缺口（本切片不宣称已对齐）

- Walk↔Run `GaitBlend.PHASE_SYNC`
- Land 现网 Action 档 vs 整图 Movement
- `setBasePos(fadeTime)` from→to（Select 只有切进该针时长）
- json `extraOverrides` 引擎未必有边
- LocoStyle 风格切图

---

## 7. 验收

1. `ENABLE=false`：与现网无差别
2. `ENABLE=true` 且 Spike 关：无双轨；推杆有 Start*；松键有 StopRun（前向）；落地有 Land 窗
3. Gate 技能冻腿 / 解闸接腿
4. 乘骑停人型图
5. 关开关重生：现网基轨回来
6. Load 失败：现网仍在

---

## 8. §1.8 二次审评（2026-09-02）

对照结构规范 §1.2–1.4、§1.6、§1.7、Remote/存档、未决问题。与初稿分开出具。

| 项 | 结论 |
|----|------|
| §1.2–1.4 | 角色 Animate 子模块 + init 编排。成立 |
| §1.6 | 纯表现。成立 |
| §1.7 | 开关互斥腿姿；位移写口不变。须同一 animate + Spike 运行时互斥，否则叠播。无新 HRP 写口 |
| Remote / 存档 | 无。旁观复制本切片不做 |
| 未决 | Walk_* 针名、playTransition 无 Stopped、Mount、Load 失败回落 — 已写回 §3–§4 |

**结论：有条件通过。** 开工必须遵守：

1. 默认 `ENABLE=false`；不改已发布 AssetId；不新 Remote/存档
2. 全仓同一 animate；LocoStyle/Gate 不得另拿裸单例 Play 经典轨
3. 先 Load 成败分流；失败走完整现网
4. Select 仅合法针名；扇区后缀 → Walk/Run+yaw
5. playTransition 合成完成/取消，不依赖 Stopped
6. Mount 停图；Gate Stop/Play 图轨；不写 CFrame/WalkSpeed/RootJoint；不 Unbind 偏航
7. 与 Spike 运行时互斥
8. 不把 §6 缺口当成本切片已对齐

---

## 9. 实施顺序

Setting 开关 → GraphLocoDriver → init 同一包装与 Gate/Mount → Strafe yaw → FootStep → 对照 §7。
