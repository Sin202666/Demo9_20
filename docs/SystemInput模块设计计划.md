# SystemInput 模块设计计划

客户端统一输入业务模块设计计划（Action / Binding / Context）。  
目标：把散落的 `UserInputService` 直连收敛为**语义动作 + 上下文栈**，供 Manager / System / UI 订阅；**不**取代 CharacterControl 的移动 Intent 管线。

> 商业蓝本：UE5 Enhanced Input（Context + Priority）、Unity Input System（Action Map / Control Scheme）。  
> 分层规范见 [`代码结构和设计开发规范.md`](代码结构和设计开发规范.md)。  
> 3C 契约见 [`CharacterControl模块技术说明.md`](CharacterControl模块技术说明.md)。  
> 坐骑多 Locomotion 换映射见 [`坐骑系统开发说明.md`](坐骑系统开发说明.md)。  
> 创建：2026-08-27 · 作者：林奥宇 · Last Modified: 2026-08-27（Phase 3 产品化已落地；2b 延后）

---

## 1. 背景与动机

### 1.1 现状

| 现象 | 示例 |
|------|------|
| 无统一输入业务模块 | `Utils.UserInputService` 仅作服务入口 |
| Manager 直绑 KeyCode | `PlayerMountClientManager`（M）、`PlayerSkillClientManager`（技能槽） |
| 设备判定与输入分离 | `DeviceType` 只做移动/PC/手柄检测 |
| 移动意图已有语义层 | `CharacterControl.IntentSampler` + `LockMask` |

### 1.2 要解决的问题

1. **同键冲突**：坐骑 / 技能 / UI / 载具对同一物理键的抢占无统一规则。  
2. **上下文切换**：进入载具、打开 UI、过场时，无法整组启用/禁用玩法键。  
3. **重绑与多设备**：默认键散落代码；键鼠 / 触屏 / 手柄难统一配置。  
4. **与 3C 边界模糊**：业务易再次直连 UIS，旁路 Intent / LockMask。

### 1.3 成功标准（产品向）

- 业务代码只认 **Action 名**，不认 `Enum.KeyCode`（除调试与设置页重绑 UI）。  
- 坐骑、技能、后续载具输入层可切换 **Context**，无需改各 Manager 的 KeyCode 分支。  
- UI 模态可 Push 高优 Context，玩法键被正确吞掉或屏蔽。  
- CharacterControl 移动 / 跳 / 冲刺管线保持现状，不被本模块吞并。

---

## 2. 目标与边界

### 2.1 做

| 能力 | 说明 |
|------|------|
| Action 语义层 | 离散动作（ToggleMount、SkillSlot1…）与可选轴值 Action |
| Binding | 物理输入 → Action；支持多绑定、按设备 Scheme |
| Context 栈 | 可 Push/Pop；带 priority；同 Action 冲突时高优胜出并可 Consume |
| 事件与轮询 | `Started` / `Ended`（及可选 `Performed`）；`GetActionValue` / `IsActionActive` |
| 配置驱动 | 默认绑定表；后续支持玩家重绑本地存 |
| 与 LockMask 协作 | Context 或 Action 可声明「应配合 PushLock / 不抢移动轴」 |

### 2.2 不做

| 项 | 归属 |
|----|------|
| 服务端权威校验 / 存档 | 各业务 System |
| 写 WalkSpeed / Drive / 相机 | CMS / CharacterMotion / CameraModule |
| 替代 Intent 移动采样 | CharacterControl.IntentSampler |
| 完整复刻 UE Modifier 资产管线 | 成本过高；按需做死区/Hold |
| System 直绑 Remote | Manager + NetWorkManager |
| 用 `IsServer` 混写双端输入业务 | 本模块仅客户端 |

### 2.3 相关但不并入

| 模块 | 关系 |
|------|------|
| `Utils.UserInputService` | 唯一底层服务入口（经 Utils 缓存） |
| `DeviceType` | 设备类型查询；Scheme 切换可参考其结果 |
| `CharacterControl` | 移动 Intent + LockMask；本模块可通知「玩法 Context 变化」，不采样 WASD |
| `ContextActionService` | 可选底层实现手段之一；对外 API 仍是 SystemInput，禁止业务直绑 CAS |
| `PlayerModule.ControlModule` | 仍只经 CharacterControl / PlayerControlsBridge |

---

## 3. 商业方案借鉴（本计划采纳点）

| 来源 | 概念 | 本仓库映射 |
|------|------|------------|
| UE Enhanced Input | Input Action | `ActionId`（语义动作） |
| UE Enhanced Input | Mapping Context + Priority | `InputContext` + `priority` 栈 |
| UE Enhanced Input | Consume / 冲突解析 | 高优 Context 触发后可 `consume=true` |
| Unity Input System | Action Map 整组开关 | 一个 Context ≈ 一组 Action Map |
| Unity Input System | Control Scheme | `KeyboardMouse` / `Gamepad` / `Touch` |
| Godot InputMap | 轻量 Action 名 + 多绑定 | 配置表 `Input.xlsx`（或 GameConfig） |

**刻意不抄：** 复杂 Chord 图编辑器、完整 Trigger/Modifier 资产链、服务端输入复制。

---

## 4. 分层与路径（建议）

```text
设备原始输入 (UIS / 可选 CAS)
        │
        ▼
SystemInput（客户端）                 ← 绑定、Context、Action 分发
        │
        ├─ 事件：OnAction(actionId, phase, value)
        ├─ 轮询：IsActionActive / GetActionValue
        │
        ├─ CharacterControl            ← 仍自采移动 Intent（不经本模块）
        ├─ PlayerMountClientManager    ← 订 MountToggle → RequestEnter/Exit
        ├─ PlayerSkillClientManager    ← 订 SkillSlot* → 施法
        ├─ MountLocomotion Drivers     ← 订 VehicleThrottle 等（Phase 2+）
        └─ GuiScripts                  ← UI Context Push/Pop
```

| 层 | 建议路径 | 职责 |
|----|----------|------|
| SystemInput | `ReplicatedStorage/ClientSideCode/SystemModule/SystemInput/`（`init.luau` + 子模块） | 领域逻辑：Binding / Context / 分发 |
| 类型桩 | `ReplicatedFirst/AllSideCode/Interface/SystemInput-Type.luau` | ActionId、Context、Phase 类型 |
| 配置 | `config/Input.xlsx` → CfgFind / GameConfig | 默认绑定、Context 模板、Scheme |
| 启动编排 | `StarterPlayerScripts/Manager/PlayerInputClientManager.client.luau` | **仅** `Init`、注册默认 Context；不写业务分支 |
| Utils | `Utils.SystemInput` | 统一访问；文件顶缓存 |

**为何放 Client SystemModule 而非 ToolSystem：**  
本模块持有运行时 Context 栈与连接生命周期，属客户端会话态业务工具；不是无状态纯函数，也不是服务端权威 System。

**Manager 边界：**  
`PlayerInputClientManager` 只负责启动与默认 Context；**具体业务仍由各域 Manager 订阅 Action**（与现规范一致：Manager 薄编排，不堆复杂分支）。

---

## 5. 核心概念

### 5.1 Action（语义动作）

| 字段 | 说明 |
|------|------|
| `actionId` | 稳定字符串或 Enum（如 `Mount.Toggle`、`Skill.Slot1`） |
| `valueType` | `Button`（离散） / `Axis1D` / `Axis2D`（预留载具） |
| `phase` | `Started` / `Ended`；（可选）`Performed`（Hold 达标等） |

命名建议：`域.动作`，与业务域对齐，避免 `Key_M` 这类物理名泄漏。

### 5.2 Binding（物理 → 语义）

```text
Scheme: KeyboardMouse
  Mount.Toggle     ← KeyCode.M
  Skill.Slot1      ← KeyCode.One
  Skill.Dash       ← KeyCode.Q

Scheme: Gamepad
  Mount.Toggle     ← KeyCode.ButtonY
  Skill.Dash       ← KeyCode.ButtonL2
```

- 同一 Action 允许多绑定（键 + 手柄键）。  
- 重绑只改 Binding，不改业务订户。

### 5.3 Context（映射上下文）

| 字段 | 说明 |
|------|------|
| `contextId` | 如 `Gameplay`、`Mount.Ground`、`Mount.Vehicle`、`UI.Modal` |
| `priority` | 数值越大越优先（建议：UI 100、载具 50、地面坐骑 40、Gameplay 10） |
| `actions` | 本 Context 启用的 Action 集合（或引用配置模板） |
| `consume` | 本 Context 处理某 Action 后是否阻止更低优 Context |

**栈语义：**

- `PushContext(id, opts)` / `PopContext(id)`（或 token）。  
- 解析某物理输入时：按 priority 降序找绑定 → 触发 Action → 若 consume 则停止下传。  
- `gameProcessed == true`（引擎已吃）默认不进入玩法分发（可配置白名单例外，如需在部分 UI 上仍响应）。

### 5.4 与 CharacterControl 的分工

```text
WASD / 移动摇杆 / 跳 / 冲刺(Hold)
    → CharacterControl.IntentSampler（保持）
    → LockMask / SprintMode / JumpPolicy

离散快捷键 / 载具专用轴（油门等）/ UI 热键
    → SystemInput Action
    → 各域 Manager / Driver
```

**禁止：** SystemInput 再采一套 WASD 写 Humanoid；载具若需接管移动，走既有 `TransferControlOwner` + Driver 专用映射（Context `Mount.Vehicle`），与坐骑文档一致。

---

## 6. 公开 API 草案

> 最终以实现与类型桩为准；本节供评审与联调对齐。

### 6.1 生命周期

```lua
SystemInput.Init()                    -- 仅 PlayerInputClientManager 调用一次
SystemInput.Destroy()                 -- 可选：测试/热重载
```

### 6.2 Context

```lua
--[[
	@param contextId string - 上下文标识
	@param opts { priority: number, consume: boolean?, actions: {string}? }? - 覆盖配置默认
	@return string - 用于 Pop 的 token（或直接用 contextId 若禁止重复压栈）
]]
SystemInput.PushContext(contextId, opts?) -> token

SystemInput.PopContext(tokenOrId) -> boolean

SystemInput.HasContext(contextId) -> boolean

SystemInput.GetActiveContexts() -> { { id, priority }, ... }  -- 深拷贝或只读视图
```

### 6.3 订阅与查询

```lua
--[[
	@param actionId string - 语义动作
	@param callback (phase: string, value: number|Vector2?, meta: table?) -> ()
	@return RBXScriptConnection 或 disconnect handle
]]
SystemInput.OnAction(actionId, callback) -> handle

SystemInput.IsActionActive(actionId) -> boolean

SystemInput.GetActionValue(actionId) -> number|Vector2|nil
```

### 6.4 绑定（设置页 / 调试）

```lua
SystemInput.GetBindings(scheme?) -> table  -- 深拷贝
SystemInput.SetBinding(actionId, inputSpec, scheme?) -> boolean, errorCode?
SystemInput.ResetBindingsToDefault(scheme?) -> ()
SystemInput.SaveLocalBindings() / LoadLocalBindings()  -- Phase 3
```

### 6.5 辅助

```lua
SystemInput.SetEnabled(boolean)           -- 全局总闸（过场黑屏）
SystemInput.IsEnabled() -> boolean
-- Debug：当前 Context 栈、最后触发的 Action（Studio only）
```

**约定：**

- 返回可变表一律 **深拷贝** 或只读 getter，符合规范。  
- 私有函数 `_` 前缀；业务禁止直连 UIS 做快捷键（Code Review 项）。

---

## 7. 配置设计（草案）

### 7.1 `Input.xlsx`（或拆多表）

**Actions 表**

| 列 | 说明 |
|----|------|
| ActionId | `Mount.Toggle` |
| ValueType | Button / Axis1D / Axis2D |
| Category | Mount / Skill / UI / Vehicle |
| Notes | 策划备注 |

**Bindings 表**

| 列 | 说明 |
|----|------|
| ActionId | |
| Scheme | KeyboardMouse / Gamepad / Touch |
| InputType | KeyCode / UserInputType / … |
| Key | `M` / `ButtonY` |
| PriorityOverride | 可选 |

**Contexts 表**

| 列 | 说明 |
|----|------|
| ContextId | `Gameplay` |
| Priority | 10 |
| ActionList | 引用的 ActionId 列表或组名 |
| Consume | true/false |

默认启动：`PlayerInputClientManager` Push `Gameplay`。

### 7.2 首批 Action 清单（迁移用）

| ActionId | 现状来源 | 优先 Phase |
|----------|----------|------------|
| `Mount.Toggle` | PlayerMountClientManager M | 1 |
| `Skill.Slot1`…`SlotN` | PlayerSkillClientManager | 1 |
| `Skill.Dash` | 冲刺键 Q / L2 | 1 |
| `Vehicle.Throttle` 等 | 坐骑 Phase 2 | 2 |
| `UI.*` | 设置/邮件等 | 2～3 |

---

## 8. 子模块拆分（建议）

```text
SystemInput/
  init.luau              -- 公共 API、Init
  Constants.luau         -- 默认 priority、Phase 名
  ActionRegistry.luau    -- Action 定义与运行时状态
  BindingStore.luau      -- Scheme + 绑定表 + 重绑
  ContextStack.luau      -- Push/Pop、冲突解析
  InputPump.luau         -- 监听 UIS（或 CAS），解析并分发
  LocalBindingSave.luau  -- Phase 3：本地键位
```

文件有效代码超 500 行或职责分叉时再拆；首期可合并 BindingStore + ActionRegistry。

---

## 9. 分阶段计划

### Phase 0 — 设计冻结（本文档评审）

| 交付 | 说明 |
|------|------|
| 边界确认 | 与 CharacterControl / 坐骑 / 技能 Owner 对齐 |
| Action 命名规范 | `域.动作`；首批清单定稿 |
| Context priority 表 | UI / Vehicle / GroundMount / Gameplay |

**出口标准：** 评审通过；无代码亦可。

### Phase 1 — MVP（统一离散快捷键）✅ 已落地

| 项 | 说明 | 状态 |
|----|------|------|
| 实现 | Context 栈 + Button Action + OnAction | 已完成：`ClientSideCode/SystemModule/SystemInput/` |
| 配置 | 最小默认绑定（硬编码 `DefaultConfig`；Skill 由 Manager `SetBinding`） | 已完成 |
| 迁移 | Mount.Toggle、Skill 槽与 Dash 改订 Action | 已完成 |
| 启动 | `PlayerInputClientManager`：Init + Push `Gameplay` | 已完成 |
| 规范 | 新代码禁止业务直连 UIS 绑玩法键 | 坐骑/技能已切；其余域按需迁移 |

**出口标准：** 坐骑 M、技能快捷键行为与现网一致；打开简单 UI 时可 Push `UI.Modal` 屏蔽玩法键（演示即可）。

### Phase 2 — 载具 / 轴值 / 设备 Scheme

拆为 **2a（设备 Scheme，可独立）** 与 **2b（载具 Axis，跟坐骑车辆）**。

#### Phase 2a — 设备 Scheme ✅ 已落地

| 项 | 说明 | 状态 |
|----|------|------|
| 活跃 Scheme | 解析只查当前 Scheme，不再合并全表 | 已完成 |
| 自动切换 | `PreferredInput` + 本次 `InputObject`；手柄插拔刷新 | 已完成 |
| 手动锁定 | `SetActiveScheme(scheme, lock?)` / `IsSchemeLocked` | 已完成 |
| 默认绑定 | Mount：`M` + `ButtonY`；技能槽 Gamepad 面键/DPad；Dash=`ButtonL2` | 已完成 |
| Touch | Scheme 可识别；虚拟按钮绑定后置 | 预留 |

**出口标准：** 键鼠与手柄可分别触发 Mount/Skill；切换设备不串键、不粘键。

#### Phase 2b — 载具 / 轴值（延后，等载具需求）

| 项 | 说明 |
|----|------|
| Axis Action | 油门/转向等，供 `WheeledVehicleDriver` |
| Context | `Mount.Ground` / `Mount.Vehicle` 随 Driver 生命周期 Push/Pop |
| Hold/Tap | 按需（冲刺 Hold 仍可留在 CharacterControl） |

**出口标准：** 坐骑文档车辆 Phase 输入层经 SystemInput，Driver 内不散落 KeyCode。  
**排期：** 可晚于 Phase 3；无载具消费方前不强制开工。

### Phase 3 — 产品化 ✅ 已落地（先于 2b）

| 项 | 说明 | 状态 |
|----|------|------|
| 设置页重绑 | `Setting/KeybindPanel` + `BeginRebindCapture` + 冲突拒绝 | 已完成 |
| 存档持久化 | `InputBindings` + `SystemInputBind` + `LocalBindingSave` | 已完成 |
| Debug 覆盖 | Studio `DebugOverlay` | 已完成 |
| 文档 | [`SystemInput模块技术说明.md`](SystemInput模块技术说明.md) | 已完成 |

**验收：**

- [x] 重绑后经存档可恢复；键鼠/手柄页签独立
- [x] 冲突拒绝；Esc 取消捕获
- [x] 键位面板 Push `UI.Modal`
- [x] Studio 可见 Debug
- [x] 不进 SystemSet NumberValue；未做 Axis/2b

---

## 10. 迁移策略

1. **先加后切：** SystemInput 上线并双轨；旧 UIS 监听暂留，用开关或对比日志。  
2. **按域迁移：** Mount → Skill → 其它 Manager → Gui。  
3. **删除直连：** 迁移完成的 Manager 移除 `UserInputService.InputBegan` 玩法分支。  
4. **Intent 不动：** 不把 WASD/跳/冲刺迁入 SystemInput（除非 Phase 2+ 明确要「输入所有者」抽象且有回归方案）。

### 10.1 示例：坐骑 Manager 目标形态

```text
-- 现：UIS.InputBegan → KeyCode.M → RequestEnter/Exit
-- 目标：
SystemInput.OnAction("Mount.Toggle", function(phase)
  if phase ~= "Started" then return end
  if SystemMount.IsLocalActive() then
    SystemMount.RequestExit()
  else
    SystemMount.RequestEnter(defaultId)
  end
end)
```

进入载具 Driver 时：`PushContext("Mount.Vehicle")`；离开时 Pop；Gameplay 的部分键可被 Vehicle Context consume。

---

## 11. 风险与对策

| 风险 | 对策 |
|------|------|
| 与 IntentSampler 双监同一键 | 职责表写死：移动类不进 SystemInput；Review 检查 |
| `gameProcessed` 导致键「失灵」 | 文档说明；UI Context 与引擎 processed 策略分列 |
| Context 泄漏（Push 未 Pop） | token + 域 `destroy` 必 Pop；可选超时/角色销毁清空 |
| 性能（每键遍历 Context） | Context 数量保持个位数；按 Key 建索引反查 Action |
| 过度设计阻塞坐骑 | Phase 1 只做 Button + 双 Context；轴值延后 |
| 团队继续直连 UIS | 规范 + Code Review 清单 + 可选 lint/grep CI |

---

## 12. 验收清单（Phase 1）

- [x] `Utils.SystemInput` 可加载；`Init` 仅 Manager 调用一次（另支持懒 Init）
- [x] `PushContext` / `PopContext` / `OnAction` 可用
- [x] `Mount.Toggle`、`Skill.*` 经 Action 触发
- [x] `UI.Modal`（`suppressLower`）可屏蔽玩法 Action
- [x] 文件头 / 公共 API 注释；Author 为 Git `user.name`
- [x] 「不做」项无越界实现（未改 IntentSampler）
- [x] CharacterControl 移动 / 跳 / 冲刺回归（Studio 手测通过）

---

## 13. 开放问题（评审填写）

| # | 问题 | 倾向建议 | 决议 |
|---|------|----------|------|
| 1 | ActionId 用字符串还是 EnumMgr？ | 首期字符串 + 常量模块；稳定后进 EnumMgr | **Phase 1：`Constants.ActionIds` 字符串** |
| 2 | 底层用 UIS 还是 ContextActionService？ | MVP 用 UIS；若 priority 与引擎 UI 冲突再评估 CAS | **Phase 1：仅 UIS** |
| 3 | 玩家键位存本地还是 DataStore？ | 设置类偏好可本地；若需多端同步再进存档 | 延后 Phase 3 |
| 4 | 技能 Hold/蓄力是否走 SystemInput Phase？ | 离散 Began 先迁；蓄力仍归技能 Input 子模块直至 Phase 2 | **Phase 1：仅 Began/Ended** |
| 5 | 是否提供 BindableEvent 广播？ | 优先回调订阅；避免全局事件风暴 | **Phase 1：仅 OnAction 回调** |

---

## 14. 文档与跟进

| 动作 | 负责人（待填） | 节点 |
|------|----------------|------|
| 评审本文档 | | Phase 0 |
| 实现 Phase 1 | | |
| 更新坐骑说明交叉引用 | | Phase 1 完成时 |
| 更新技能技术说明输入节 | | Phase 1 完成时 |
| 升格「技术说明」正文 | | Phase 3 |

---

## 附录 A — 推荐 Context Priority（初值）

| ContextId | Priority | 典型用途 |
|-----------|----------|----------|
| `UI.Modal` | 100 | 全屏/模态；consume 玩法键 |
| `UI.HudCapture` | 80 | 个别 HUD 抢键 |
| `Mount.Aircraft` | 60 | 航空器 |
| `Mount.Vehicle` | 50 | 轮式载具 |
| `Mount.Ground` | 40 | 陆地坐骑专用键（若与 Gameplay 不同） |
| `Gameplay` | 10 | 默认战斗/探索快捷键 |
| `System.Disabled` | 0 | 全局关闭时的空上下文（可选） |

## 附录 B — 一句话架构

**SystemInput = 客户端 Action 路由器（Binding + Context 栈）；CharacterControl = 移动 Intent 与锁；业务 Manager 只订 Action，不绑 KeyCode。**
