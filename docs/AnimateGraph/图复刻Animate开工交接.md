# 图复刻 Animate — 新会话开工交接

> 日期：2026-09-02  
> 用途：新会话 **按已审方案接现网 Animate**（特性开关，默认关）。不要重做 P0 Spike。  
> 方案正文：[`图复刻Animate方案.md`](图复刻Animate方案.md)

---

## 1. 可贴的开场白

```text
按 docs/AnimateGraph/图复刻Animate开工交接.md 和 图复刻Animate方案.md 开工。
方案 §1.8 已有条件通过。先确认 LocoGraphSpike.SPIKE_ENABLE=false，
再做 GraphLocoDriver + init 同一 animate 包装。
不改 GroundLocomotion FSM，不写 CFrame/WalkSpeed，不重开 §1.8 除非改设计。
```

本交接 **授权写业务代码**（条件已写入方案 §8）。若改设计（第二套 animate、Spike 双开、图写 HRP）须重审。

---

## 2. 上一会话已完成（勿重做）

### P0 旁路 Spike

- 文件：`src/StarterPlayer/StarterCharacterScripts/LocoGraphSpike.client.luau`
- 图：`rbxassetid://90774329769612`
- **未改** `Animate/init.client`（Spike 独立脚本：`stopBaseAction` + `Animate.Enabled=false`）
- 试播：四向/Select 能驱动；自动路径不写 Start*/StopRun/Land，质感跳变是预期

Spike 已验证、接入必须沿用：

- `SetParameter("MoveYawRad", math.rad(-yawDeg))`：运行时 **弧度**；`getMoveYaw()` 仍是角度；**取负** 对齐 Polar 左右
- `FORCE_YAW_DEG` 仍填 `0/90/180/-90`，不要把 1.57 填进 FORCE
- `MoveMag=1`；`ClipSpeed` 只一条
- Studio 采样点是角度；脚本 API 是弧度

**开工前：** `SPIKE_ENABLE` 必须为 `false`。与 GraphLoco 同时开会双 Load 同 AssetId。

### 方案与审查

- 接入方式：特性开关双跑，默认关
- §1.8（2026-09-02）：**有条件通过**，条件在方案正文 §8
- 未写代码：`GraphLocoDriver`、`AnimateSetting.GraphLoco`、init 包装

---

## 3. 本会话只做

按 [`图复刻Animate方案.md`](图复刻Animate方案.md)：

1. `AnimateSetting.GraphLoco.ENABLE = false`
2. 新模块 `Animate/GraphLocoDriver.luau`（Author = `git config user.name`）
3. `init.client`：GroundLocomotion / StrafeBlend / LocoStyle / Gate **同一 animate**
4. 先 Load 图，失败走完整现网；成功才停经典 Play
5. 图模式 Strafe 只出平滑 yaw；FootStep 接图轨 Marker
6. 与 Spike 运行时互斥

不要：改 GroundLocomotion 状态机、改已发布图 AssetId、新 Remote/存档、写 CFrame/WalkSpeed/RootJoint、Unbind 偏航 RenderStep、把 Spike 当正式 loco。

---

## 4. 关键路径

- [`图复刻Animate方案.md`](图复刻Animate方案.md) — 权威/写口/条件/验收
- [`LocoDefault.graph.json`](LocoDefault.graph.json) — 图规格 + AssetId
- `src/StarterPlayer/StarterCharacterScripts/Animate/init.client.luau`
- `GroundLocomotion.luau` — 只读 `_pose` / `playTransition` / `Walk_Left`
- `LocoGraphSpike.client.luau` — 只读 SetParameter（弧度+取负）
- `docs/代码结构和设计开发规范.md` §1.6 / §1.7

---

## 5. 完成定义

- 默认关开关 = 现网 Animate 不变
- 开开关 + Spike 关：走跑有 Start*/StopRun；落地有 Land 窗；Gate 冻/接腿；无双轨叠姿
- 关开关重生 = 现网基轨回来
- UTF-8 无 BOM、LF；中文读回完好
