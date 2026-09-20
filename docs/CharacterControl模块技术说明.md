# CharacterControl 模块技术说明

客户端角色 **Control 薄层**技术参考（3C 中的 Control 柱）。业务侧**只经 `Utils.CharacterControl`** 取实例并调用锁/Intent API；勿裸写 `Humanoid.WalkSpeed`、勿直调 `PlayerModule:GetControls():Disable`、勿在本模块外旁路采样冲刺键改移速。

> 本文覆盖 **Control** 与跨模块契约。Camera 见 `CameraModule模块技术说明.md`；移速写口在 CharacterMoveSpeed（CMS）；腿/朝向/相机**表现占用**在 ActionArbiter。技能编排与位移 Gate 总览见 `技能系统技术说明.md`。

---

## 1. 目标与边界

| 能力 | 说明 |
|------|------|
| Intent 采样 | 设备输入 → `IntentSnapshot`（移动轴、跳、冲刺按住、交互边沿等） |
| LockMask | 多来源输入锁栈；通道 OR 聚合（Move / Jump / Sprint / Look / Interact） |
| Sprint Toggle/Hold | Walk/Run 模式机（设置 RunMode：一键切换/长按）；经 CMS Modifier 声明奔跑加成，不写 WalkSpeed |
| Jump 策略 | Buffer / Coyote / SuppressJump；经 `SetStateEnabled(Jumping)` 禁跳 |
| Look / Interact 闸 | 聚合结果写 LocalPlayer Attribute，供 Animate / 交互只读 |
| TransferControlOwner | 临时全通道接管（缺省 FullLock + DisableControls） |
| Controls Bridge | 引用计数封装引擎 ControlModule Enable/Disable |

**不做：**

- 写 `Humanoid.WalkSpeed` / `ExpectedWalkSpeed`（归 CMS）
- 播移动/技能动画轨（归 Animate / 技能）
- 写相机 CFrame / FOV / PushMode（归 CameraModule；Look 锁**不**自动改 Mode）
- `ActionArbiter:Acquire`（管腿表现占用；本模块不占闸）
- 技能位移「冲刺」NewRoll（Q）——与 Locomotion Sprint（Walk/Run）无关

**相关但不并入本模块：**

| 模块 | 关系 |
|------|------|
| CharacterMoveSpeed + Bind | 唯一写 WalkSpeed；消费 `Control:Sprint` / `Control:Lock:Move` Modifier |
| Animate | 消费 ExpectedWalkSpeed + MoveDirection；`IsControlLookLocked` 时让出 ShiftLock 朝向写口 |
| CameraMode | 跟拍模式栈；业务可 `Transfer` + `PushMode` 组合 |
| ActionArbiter | suppressLoco / facingOwner / cameraOwner；与 Move 锁正交，见 §5 |
| HumanModule | `GetIsControlLookLocked` / `GetIsControlInteractLocked` 只读封装 |
| PlayerModule.ControlModule | 仅经内部 `PlayerControlsBridge`；禁止业务直调 |

---

## 2. 分层架构

```text
业务 / 技能 / UI / 载具·过场
        │ Utils.CharacterControl.GetForCharacter
        ▼
CharacterManager (CharacterScripts)   ← 薄编排：Create / destroy（task.defer）
        │ moveSpeedBind = CharacterMoveSpeedBind
        ▼
CharacterControl (ToolSystem)         ← Intent / Lock / Sprint / Jump / Transfer
        ├── ControlInstance.luau        ← Create 工厂（Heartbeat / Lock / Transfer）
        ├── Constants.luau
        ├── IntentSampler.luau
        ├── LockMask.luau
        ├── SprintMode.luau
        ├── JumpPolicy.luau
        └── PlayerControlsBridge.luau   ← 引用计数 Disable/Enable Controls

并行（同角色脚本层，非本模块子树）：
CharacterMoveSpeed.client + CharacterMoveSpeedBind  ← 唯一写 WalkSpeed
Animate/*                                          ← 轨与朝向
CameraModule / CameraMode                          ← 相机（全局）
ActionArbiter                                      ← 表现门闸

配置：GameConfig.CharacterControl + GameConfig.CharacterMoveSpeed
类型桩：Interface/CharacterControl-Type.luau
```

| 层 | 路径 | 职责 |
|----|------|------|
| Manager | `StarterCharacterScripts/CharacterScripts/CharacterManager` | 仅 Create/destroy + HeadLock；`task.defer` 避开 CMS `setHandler` 竞态 |
| CharacterControl | `AllSideCode/ToolSystem/CharacterControl/` | Control 领域逻辑与公开实例 API |
| CMS | `CharacterScripts/CharacterMoveSpeed*.luau` | Attribute + Modifier 合成并写速 |
| 类型桩 | `Interface/CharacterControl-Type.luau` | IDE 补全；实现以 ToolSystem 为准 |

**实例范围：** 仅**本地玩家**角色可 `Create`；弱表按 `Model` 索引。业务一律 `GetForCharacter`，禁止自行 `Create`（除非测试/工具明确知情）。

---

## 3. 所有权约定（强制）

| 资源 | 允许写入方 |
|------|------------|
| `Humanoid.WalkSpeed` / `ExpectedWalkSpeed` | **仅** CharacterMoveSpeed（经 Bind Modifier 合成） |
| `Control:Sprint` / `Control:Lock:Move` Modifier | CharacterControl（SprintMode / Move 锁） |
| 其它技能锁速 Modifier | 技能 / 业务经 Bind；**禁止**裸写 WalkSpeed |
| `Humanoid:SetStateEnabled(Jumping)` | JumpPolicy（本模块） |
| ControlModule Enable/Disable | **仅** PlayerControlsBridge |
| `IsControlLookLocked` / `IsControlInteractLocked` | CharacterControl（聚合锁变化时） |
| HRP 偏航（ShiftLock） | Animate；Look 锁为 true 时**必须让出** |
| 相机 CFrame / FOV / Mode | CameraModule |

---

## 4. 每帧管线（Heartbeat）

`CharacterControl.Create` 内绑定 `RunService.Heartbeat`：

```text
1. IntentSampler:Sample(humanoid)
   → moveAxis（来自 Humanoid.MoveDirection 水平分量）
   → jumpPressed / jumpHeld / sprintHeld / interactPressed（边沿在 Sample 内消费）
2. 若 LockMask.Interact → 清 lastIntent.interactPressed（对外已吞边沿）
3. SprintMode:Update(sprintHeld, lockSprint)
   → 推/弹 Control:Sprint { add = 奔跑速 - 行走速 }
4. JumpPolicy:Update(jumpPressed, lockJump)
   → Suppress / Lock → 禁 Jumping 状态
   → Buffer / Coyote → 必要时 humanoid.Jump = true
```

**注意：**

- `GetIntent()` 返回**字段浅拷贝**；改表不会回写内部。
- `jumpPressed` / `interactPressed` 为**帧边沿**：同一帧内多次 `GetIntent` 看到相同值；若业务漏读一整帧则边沿丢失（当前无事件总线）。
- `crouchHeld` 当前恒为 `false`（预留 Phase3 Crouch）。

---

## 5. 与 ActionArbiter / CMS / Animate / Camera 决策

### 5.1 「停腿」两通道（勿混用）

| 诉求 | 用谁 | 说明 |
|------|------|------|
| 冻移速 / 禁输入意图 / 禁跳·冲刺·交互 | **CharacterControl** `PushLock` / `Transfer` | 输入与速度合成层 |
| 冻 loco 动画 / 抢朝向 / 抢相机表现 | **ActionArbiter** `Acquire` | 表现占用层 |
| 仅技能短时锁速（不关 Controls） | CMS `pushModifier` 或 Control `PushLock({ Move=true })` | 看是否要进 LockMask 可观测 |

技能位移模板（`DashStyleRoll` → `CharacterMotion`）：`SkillActionLock` + ActionArbiter + Motion `PushLock(Jump+Sprint)` 同相；**不要**再直调 ControlModule 或裸写 LinearVelocity。

### 5.2 Look 锁 vs CameraMode

```text
IsControlLookLocked = true
  → Animate 不写 HRP 朝向（ShiftLock 写口让出）
  → 不自动 CameraMode.PushMode

过场/载具需要改跟拍：业务自行 PushMode + TransferControlOwner 组合
```

### 5.3 Sprint 命名消歧

| 名称 | 含义 | 入口 |
|------|------|------|
| Locomotion Sprint | Walk↔Run 步态 | CharacterControl + `冲刺键`（默认 LeftShift） |
| 技能冲刺 / NewRoll | 翻滚类位移技能 | 技能系统（如 Q）；**不**走 SprintMode |

**输入模式**（`settingConf.RunMode`，Control 分类 Choose，默认 `0`）：

| 值 | 文案 | 行为 |
|----|------|------|
| 0 | 一键切换 | 冲刺键按下边沿翻转 Run↔Walk；松键不改步态 |
| 1 | 长按奔跑 | 按住 Run、松开 Walk（原 Hold-Sprint） |

Create 读 `GetSetting(plr,"RunMode")`，并监听 `player.Setting.RunMode` 热切换。Sprint 锁期间不翻转 Toggle 闩。

ShiftLock 开关键默认 `LeftControl`（`GameConfig.CharacterControl.ShiftLock键`），由 CameraModule 重绑 MouseLockController，避免与奔跑抢 LeftShift。

---

## 6. LockMask 与 MovePolicy

### 6.1 通道

| 通道 | 生效表现 |
|------|----------|
| Move | CMS `Control:Lock:Move` hardLock（WalkSpeed→0）；可选 DisableControls |
| Jump | JumpPolicy 禁跳 + 清 Buffer |
| Sprint | SprintMode 强制 Walk（弹 Sprint Modifier） |
| Look | `IsControlLookLocked = true` |
| Interact | `IsControlInteractLocked = true`，且 GetIntent 清 interactPressed |

- 同 `sourceId` **覆盖**；多源按通道 **OR** 聚合。
- `GetLockMask()` 返回浅拷贝。

### 6.2 MovePolicy

| 策略 | 行为 | 默认用于 |
|------|------|----------|
| `SpeedOnly` | 仅 CMS hardLock；**MoveDirection 仍可能非零** | `PushLock`（`Move锁默认策略`） |
| `DisableControls` | 冻速 + `ControlModule:Disable`（清默认移动意图；亦影响默认跳键） | `TransferControlOwner`（`Transfer移控策略`） |

显式覆盖：`mask.MovePolicy = "SpeedOnly" | "DisableControls"`（仅 `Move=true` 时有意义）。

**产品提示：** UI 仅冻速若出现「零速踏步」动画，应改用 `DisableControls`，或业务侧保证 Animate 在 hardLock 下按无输入处理（见 §12 已知限制）。

### 6.3 Transfer 语义（当前实现）

`TransferControlOwner(ownerId, mask?)` ≡ 以 `ownerId` 为 source 的 `PushLock`：

- 缺省 mask = `FullLockMask`（五通道全 true）
- Move 缺省策略 = DisableControls
- **不是**互斥单所有者栈：多个 Transfer 可同时存在，通道 OR

`ReleaseControlOwner(ownerId)` ≡ `PopLock(ownerId)`。

命名保留「Owner」便于载具/过场表达；实现为多源锁。若需严格单所有者，应在业务层约定唯一 `ownerId` 或后续版本改为互斥栈。

---

## 7. 业务 API

引入：

```lua
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CharacterControl = Utils.CharacterControl

local ctrl = CharacterControl.GetForCharacter(character)
if not ctrl then
	return
end
```

### 7.1 工厂（仅 CharacterManager）

| API | 说明 |
|-----|------|
| `Create(character, options)` | `options.moveSpeedBind` 必填；`enabled=false` 或不创建；非本地角色拒绝 |
| `GetForCharacter(character)` | 已 Create 实例；否则 nil |

### 7.2 实例方法

| API | 说明 |
|-----|------|
| `GetIntent()` | 本帧 Intent **浅拷贝** |
| `GetMode()` | `"Walk"` \| `"Run"` |
| `PushLock(sourceId, mask)` | 压入/覆盖锁；Move 默认 SpeedOnly |
| `PopLock(sourceId)` | 弹出；返回是否曾存在 |
| `GetLockMask()` | 聚合锁浅拷贝 |
| `TransferControlOwner(ownerId, mask?)` | 缺省 FullLock + DisableControls |
| `ReleaseControlOwner(ownerId)` | 归还（= PopLock） |
| `SuppressJump(durationSec, reason?)` | 限时禁跳 |
| `ClearJumpBuffer()` | 清空跳跃预输入 |
| `destroy()` | 断连接、清锁、还 Modifier、复位 Attribute、恢复 Controls |

### 7.3 IntentSnapshot 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `moveAxis` | Vector3 | 水平移动意图（来自 MoveDirection） |
| `moveMagnitude` | number | 模长 |
| `jumpPressed` | boolean | 本帧跳跃边沿 |
| `jumpHeld` | boolean | 跳跃键按住 |
| `sprintHeld` | boolean | 冲刺键按住 |
| `crouchHeld` | boolean | 预留；当前恒 false |
| `interactPressed` | boolean | 本帧交互边沿（Interact 锁时对外为 false） |

### 7.4 典型示例

**技能锁跳与奔跑：**

```lua
ctrl:PushLock("Skill:DashStyleRoll", { Jump = true, Sprint = true })
-- ...
ctrl:PopLock("Skill:DashStyleRoll")
```

**UI 仅冻速（不关 Controls）：**

```lua
ctrl:PushLock("UI:Shop", { Move = true }) -- 默认 SpeedOnly
-- 或：{ Move = true, MovePolicy = "SpeedOnly" }
```

**载具 / 过场真接管：**

```lua
ctrl:TransferControlOwner("Vehicle:Bike")
-- 可选：CameraModule.PushMode(...)
-- ...
ctrl:ReleaseControlOwner("Vehicle:Bike")
```

**交互边沿：**

```lua
local intent = ctrl:GetIntent()
if intent.interactPressed then
	-- 开门 / 对话；须有业务每帧或稳定频率消费
end
```

---

## 8. Attribute 与只读查询

| Attribute（LocalPlayer） | 含义 |
|--------------------------|------|
| `IsControlLookLocked` | Look 通道聚合为 true |
| `IsControlInteractLocked` | Interact 通道聚合为 true |

只读封装：`HumanModule.GetIsControlLookLocked` / `GetIsControlInteractLocked`。

相关（非本模块写入）：`ExpectedWalkSpeed`（CMS）、`IsShiftLocked`（CameraModule / MouseLock）。

---

## 9. 配置

### 9.1 `GameConfig.CharacterControl`

| 键 | 默认 | 含义 |
|----|------|------|
| 启用 | true | false 时 Create 返回 nil |
| 进场默认奔跑 | false | true：进场即 Run（Toggle=初值闩 / Hold=直至首次松键） |
| 冲刺键 | `"LeftShift"` | KeyCode 名；非法回退 LeftShift |
| ShiftLock键 | `"LeftControl"` | 供 CameraModule 重绑；本模块不读 |
| 交互键 | `"E"` | Intent.interactPressed；手柄默认 ButtonX |
| 跳跃缓冲秒 | 0.12 | Jump Buffer |
| 郊狼秒 | 0.08 | Coyote Time |
| 默认落地禁跳秒 | 0 | Create 时 SuppressJump；0=不自动禁跳 |
| Move锁默认策略 | `"SpeedOnly"` | PushLock 且 Move 未写 MovePolicy |
| Transfer移控策略 | `"DisableControls"` | Transfer 且 Move 未写 MovePolicy |

### 9.2 `settingConf.RunMode`（玩家设置）

| 字段 | 值 |
|------|-----|
| ShowName | `RunMode` |
| SetType / TempType | 4 Control / 3 Choose |
| set（默认） | `0`（一键切换） |
| ZhDes | `一键切换` / `长按奔跑` |

### 9.3 `GameConfig.CharacterMoveSpeed`（Sprint 加成来源）

| 键 | 默认 | 含义 |
|----|------|------|
| 玩家行走移动速度 | 16 | 行走基准 |
| 玩家奔跑移动速度 | 22 | Sprint Modifier `add = max(0, 跑-走)` |

### 9.4 Modifier ownerId（Constants）

| 常量 | 值 |
|------|-----|
| `OwnerSprint` | `Control:Sprint` |
| `OwnerLockMove` | `Control:Lock:Move` |

---

## 10. 生命周期

| 步骤 | 说明 |
|------|------|
| 角色加载 | CharacterManager `task.defer` → `CharacterControl.Create` |
| 运行 | Heartbeat 采样；锁变化同步 CMS / Attribute / Bridge |
| 角色销毁 | AncestryChanged → `ctrl:destroy()`：断 Heartbeat、清锁、`releaseAll` Controls、弹 Modifier、Attribute 复位、子模块 destroy |
| 重复 Create | 同 character 返回已有实例 |

PlayerModule 未就绪时，DisableControls 可能暂时跳过（仍依赖 CMS 冻速）；Bridge 会 warn，不永久失败（解析失败除外）。

---

## 11. 约定与禁止项

**应做**

- 业务只经 `Utils.CharacterControl.GetForCharacter`
- 锁使用**稳定** `sourceId`（如 `Skill:DashStyleRoll` / `UI:Shop` / `Vehicle:Bike`），成对 Push/Pop
- 技能位移以 `DashStyleRoll` 为模板（SkillActionLock + ActionArbiter + PushLock）
- 真接管（载具/过场）用 `TransferControlOwner`，需要跟拍时另 `CameraMode.PushMode`
- Interact 边沿由业务稳定消费；UI/对话打开时 `PushLock({ Interact = true })`

**禁止**

- 裸写 `Humanoid.WalkSpeed`
- 业务 `GetControls():Disable` / `Enable`（必须走本模块 MovePolicy）
- 用 SprintMode / 冲刺键实现技能翻滚位移
- 在 CharacterControl 内 `Acquire` ActionArbiter 或写相机
- 依赖篡改 `GetIntent()` 返回表回写内部状态
- 非本地角色 Create

---

## 12. 已知限制与后续（商业级缺口摘要）

| 项 | 现状 | 建议方向 |
|----|------|----------|
| Interact 消费端 | 仅采样，无框架级交互系统 | 业务系统轮询或后续 OnIntent |
| SpeedOnly 与动画 | MoveDirection 可非零 → 可能零速踏步 | UI 用 DisableControls，或 CMS/Animate hardLock 当无输入 |
| 触控冲刺/交互 | 仅 JumpRequest；无 Touch 注入 | InjectIntent / VirtualControls |
| Crouch | `crouchHeld` 占位 | Phase3 |
| Transfer 互斥 | 多源 OR，非单 Owner | 业务约定或改互斥栈 |
| 可观测性 | 仅 Look/Interact Attribute | Debug 快照（Mode、锁来源、Bridge 计数） |
| 回归资产 | 无自动化用例 | LockMask / Bridge / JumpPolicy 纯逻辑测 |

---

## 13. 验收清单（建议）

手工或自动化至少覆盖：

- [ ] 进场：`进场默认奔跑` true/false 下 Mode 与 WalkSpeed 加成符合预期
- [ ] RunMode=一键切换：单击冲刺键翻转 Run↔Walk；松键不变；Sprint 锁期间不翻转
- [ ] RunMode=长按奔跑：按住/松开冲刺键 Run↔Walk；Sprint 锁期间保持 Walk
- [ ] 设置中切换 RunMode：热切换生效，无残留 Modifier
- [ ] Jump Buffer：离地前短按，落地后短窗内起跳
- [ ] Coyote：离地后 `郊狼秒` 内仍可跳
- [ ] `SuppressJump` / Jump 锁：期间无法起跳，解除后恢复
- [ ] `PushLock(Move)` SpeedOnly：WalkSpeed=0；Pop 后恢复
- [ ] `TransferControlOwner`：Controls Disable、五通道锁；Release 后 Controls Enable
- [ ] 多源锁 OR：两源各锁不同通道，Pop 一个不影响另一通道
- [ ] Look 锁：ShiftLock 下 Animate 不写 HRP；Attribute 正确
- [ ] Interact 锁：`GetIntent().interactPressed` 为 false
- [ ] `DashStyleRoll`：占闸期间 Jump+Sprint 锁，结束 Pop
- [ ] 角色销毁：无残留 Modifier / Controls Disable / Attribute true
- [ ] 非本地角色 Create 被拒绝（若有测试入口）

---

## 14. 相关源码索引

| 模块 | 路径 |
|------|------|
| CharacterControl | `src/ReplicatedFirst/AllSideCode/ToolSystem/CharacterControl/` |
| 类型桩 | `src/ReplicatedFirst/AllSideCode/Interface/CharacterControl-Type.luau` |
| CharacterManager | `src/StarterPlayer/StarterCharacterScripts/CharacterScripts/CharacterManager/` |
| CharacterMoveSpeed | `src/StarterPlayer/StarterCharacterScripts/CharacterScripts/CharacterMoveSpeed.client.luau` |
| CharacterMoveSpeedBind | `.../CharacterMoveSpeedBind.luau` |
| Animate（Look 让出） | `src/StarterPlayer/StarterCharacterScripts/Animate/init.client.luau` |
| ActionArbiter | `src/ReplicatedFirst/AllSideCode/ToolSystem/ActionArbiter/` |
| DashStyleRoll | `src/ReplicatedStorage/ClientSideCode/SystemSkill/BaseSkill/SkillAction/DashStyleRoll.luau` |
| HumanModule | `src/ReplicatedFirst/AllSideCode/ToolBasic/HumanModule.luau` |
| 配置 | `src/ReplicatedFirst/AllSideCode/ToolBasic/GameConfig.luau` → `CharacterControl` / `CharacterMoveSpeed` |
| Camera（ShiftLock 键） | `docs/CameraModule模块技术说明.md` |
| 技能系统总览 | `docs/技能系统技术说明.md` |

文件头注释含更细的边界语义与用例；本说明作跨模块总览与验收参考，实现细节以对应模块头为准。