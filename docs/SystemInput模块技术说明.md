# SystemInput 模块技术说明

客户端统一输入路由器技术参考（Action / Binding / Context / Scheme / 重绑存档）。  
业务订 **Action**，不绑 `KeyCode`；**不**取代 CharacterControl 移动 Intent。

> 设计演进见 [`SystemInput模块设计计划.md`](SystemInput模块设计计划.md)。  
> 3C 边界见 [`CharacterControl模块技术说明.md`](CharacterControl模块技术说明.md)。  
> 创建：2026-08-27 · 作者：林奥宇 · Last Modified: 2026-08-27

---

## 1. 目标与边界

| 能力 | 说明 |
|------|------|
| Action | Button：`Started` / `Ended`；`OnAction` / `IsActionActive` / `GetActionValue` |
| Binding | 按 Scheme 分组；每 Scheme 每 Action 一键；`SetBinding` / `GetBindings` |
| Context 栈 | `PushContext` / `PopContext(token)`；`consume` / `suppressLower` |
| 活跃 Scheme | PreferredInput + 本次输入；`Get/SetActiveScheme` |
| 重绑 | `BeginRebindCapture`；冲突拒绝；Esc 取消 |
| 存档 | `InputBindings` 表经 `SystemInputBind`；非 SystemSet |
| Debug | Studio `DebugOverlay` |

**不做：** WASD/跳/冲刺采样（IntentSampler）；Axis/载具 Context（Phase 2b 延后）；Touch 虚拟按钮重绑。

---

## 2. 分层

```text
UIS
  → SystemInput.InputPump
      → 活跃 Scheme 查 Binding
      → Context 栈分发 ActionRegistry
          → PlayerMount / PlayerSkill / …
设置 KeybindPanel → Capture / SetBinding / SaveBindings
存档 SystemInputBind（服）← LocalBindingSave（客）
```

| 路径 | 职责 |
|------|------|
| `ClientSideCode/SystemModule/SystemInput/` | 领域逻辑 |
| `ServerSideCode/System/SystemInputBind.luau` | 存档读写 + Remote |
| `Setting/KeybindPanel.luau` | 重绑 UI |
| `PlayerInputClientManager` | Init + Gameplay + defer LoadSavedBindings |

**Utils：** `Utils.SystemInput` / `Utils.SystemInputBind`（服）。

---

## 3. Scheme

| Scheme | 来源 |
|--------|------|
| KeyboardMouse | PreferredInput.KeyboardAndMouse / 键鼠 Input |
| Gamepad | PreferredInput.Gamepad / Gamepad* Input |
| Touch | PreferredInput.Touch / Touch（绑定后置） |

解析**只查当前活跃 Scheme**。切换时 `ReleaseAllActive`。

---

## 4. Context 默认

| ContextId | Priority | 用途 |
|-----------|----------|------|
| `UI.Modal` | 100 | 设置/重绑；`suppressLower` |
| `Gameplay` | 10 | 默认玩法键 |

---

## 5. 重绑与存档

存档字段 `InputBindings`：

```lua
{
  KeyboardMouse = { ["Mount.Toggle"] = "M", ["Skill.Slot1"] = "E" },
  Gamepad = { ["Mount.Toggle"] = "ButtonY" },
}
```

流程：默认绑定（Mount DefaultConfig + Skill `RegisterDefaultProvider`）→ `task.defer LoadSavedBindings` 覆盖。

Remote：`INPUT_BINDINGS_GET` / `INPUT_BINDINGS_SET`。

冲突：同 Scheme 键已被其它 Action 占用 → 回调 `CONFLICT:<actionId>`，不写入。

---

## 6. 主要 API

```lua
SystemInput.Init()
SystemInput.PushContext / PopContext / OnAction
SystemInput.SetBinding / GetBindings / FindConflict
SystemInput.BeginRebindCapture / CancelRebindCapture
SystemInput.ResetBindingsToDefault(scheme?, save?)
SystemInput.LoadSavedBindings / SaveBindings
SystemInput.GetActiveScheme / SetActiveScheme(scheme, lock?)
SystemInput.SetDebugOverlay(enabled)
SystemInput.RegisterDefaultProvider(fn)
```

---

## 7. 与 CharacterControl

移动轴 / 跳 / 冲刺 Hold **仍由 IntentSampler 直连 UIS**。SystemInput 只负责离散快捷键与设备 Scheme。
