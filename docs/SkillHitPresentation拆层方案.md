# SkillHitPresentation 拆层方案

对照 2026-09-01 复审：`SkillHitPresentation` 维持不通过（架构 P0：`init.luau` `RunService:IsServer()` 混写服批处理下行 + 客播轨）。  
本方案只拆层与收口写口，**不改命中/伤害/装备权威**，**不新开 Remote**，**不新存档字段**。

> 创建：2026-09-01 · 作者：林奥宇  
> 状态：已按方案落地（2026-09-01）；待规范性复审改结论  
> Last Modified: 2026-09-01  
> 对照：NPCCosmeticHit 拆写口（服 System + 客 ToolSystem stub、Utils `_preferServerSystemModule`、无 `IsServer` 业务分支）

---

## 0. 目标与非目标

### 目标

| 项 | 现状 | 目标 |
|----|------|------|
| SkillHitPresentation | AllSide `init.luau` 用 `IsServer` 混挂 Resolver（Nearby `FireClient`）与 Client 播轨 | 服写口在 `ServerSideCode/System`；客只播轨 + 预设查询；无 `IsServer` 业务分支 |
| Resolver | `ToolSystem/SkillHitPresentation/SkillHitPresentationResolver.luau`（AllSide 内服逻辑） | 迁入服 System；AllSide **删除** Resolver，避免第二套下行 |
| Utils 键 | `ModuleRegistry` 固定走 ToolSystem 目录 | `_preferServerSystemModule("SkillHitPresentation")`（与 NPCCosmeticHit 同形） |

### 非目标（本切片禁止顺手做）

- 不改 `SystemEnemy.Hit` 扣血 / Despawn 顺序；调用关系保持 `Hit` → `accumulateFromLogical` + `NPCCosmeticHit.tryPlayLogical`
- 不把 FX 下行并进 `SystemEnemy` 或 `NPCCosmeticHit` 函数体
- 不改 `HitResolver` 伤害结算、`hitPresentation` 字段语义、DoT 固定伤跳过规则
- 不新 Remote、不改 `NetMsg.SKILL_HIT_PRESENTATION` 字符串、不改 payload 字段
- 不改 Nearby 半径 / 默认特效名 / `targetScale` / `InjuredSound` 解析
- 不新开位移写口；不写 `CFrame` / `WalkSpeed` / `Store.cframe`
- 不把 `SkillHitPresentationProfile` / `SoundMap` / `Config` 登记成新 Utils 键（子模块仍目录内 require）
- 不删 `SkillHitPresentationClient`（有独立播轨职责，对照 `NPCCosmeticHitPlay`）
- 不迁 `NPCCosmeticHitClient.luau` 残留、不碰 BaseSkill/GroupSkill 运行时

---

## 1. 权威与写口（§1.6 / §1.7）

| 资源 | 权威 / 写口 | 本切片 |
|------|-------------|--------|
| 命中 / 扣血 | `HitResolver` + `SystemEnemy.Hit` | 不动 |
| 是否通知、通知谁、包内条目 | 仅服 `SkillHitPresentation`（`realDmg>0`、非 DoT 固定伤、Nearby 100 stud） | 从 AllSide Resolver 迁服 System |
| `_activeBatch` | 服会话批状态（非存档） | 随 `beginBatch` / `flushBatch` 留在服模块 |
| 客播 FX / 3D 音 | 客 `handleIncoming` → `FXUtil.PlayEffect` / `SoundModule:PlaySoundLocal` | 仍只播，不回写权威 |
| 预设查询 | `resolveProfile` / `resolveHitboxEntry`（Config 副本） | 双端均可调；现网调用只在服 `HitResolver.LogicalEnemy` |
| 受击轨 | `NPCCosmeticHit` | 不碰 |
| 逻辑怪位姿 | `LogicEntityMotion` / `EnemySim` | 不写 |
| 角色击退 / 橡胶 | `CharacterMotion` / `SystemCharacterMotion` | 不写 |

**§1.6：** payload 只驱动 FX/音效。客 `handleIncoming` 不结算伤害、不改 hp、不发奖。`hitPos` 来自服已结算的 `hitData.hitPresentation`，不把客上报 `CFrame` 当命中证据。Nearby 用玩家角色 HRP 只做受众过滤，不作发奖/命中依据。

**§1.7：** 禁止本模块写 `CFrame` / `WalkSpeed` / `Store.cframe` / 速度。`PlayEffect` 与 3D 音为表现，不回写逻辑怪权威位姿。

---

## 2. 分层（对照 NPCCosmeticHit）

```text
服  HitResolver.LogicalEnemy._attachLogicalHitPresentation
      → Utils.SkillHitPresentation.resolveHitboxEntry   -- 服 System 转发 Profile
服  BaseSkillServer.Start  Hitbox.check
      → Utils.SkillHitPresentation.beginBatch / flushBatch
服  SystemEnemy.Hit
      → Utils.SkillHitPresentation.accumulateFromLogical  -- ServerSideCode/System/SkillHitPresentation.luau
           → 组条目、Nearby FireClient(SKILL_HIT_PRESENTATION)

客  EnemyManager  Register SKILL_HIT_PRESENTATION
      → Utils.SkillHitPresentation.handleIncoming       -- ToolSystem/SkillHitPresentation（无 IsServer）
           → SkillHitPresentationClient.handleIncoming → PlayEffect / PlaySoundLocal
```

Utils 分流（与 NPCCosmeticHit / SkillBuffUtil 相同）：

```lua
SkillHitPresentation = function()
    return _preferServerSystemModule("SkillHitPresentation")
end
```

即：服务端优先 `ServerSideCode/System/SkillHitPresentation`；否则回落 `ToolSystem/SkillHitPresentation`。

---

## 3. 文件

| 路径 | 动作 |
|------|------|
| `ServerStorage/ServerSideCode/System/SkillHitPresentation.luau` | **新建**：迁入现 Resolver 全文（`beginBatch` / `flushBatch` / `accumulateFromLogical` / `_dispatchEntries`）；`resolveProfile` / `resolveHitboxEntry` 转发 Profile；`handleIncoming` 为 no-op；表名 `SkillHitPresentation`；五项头 Author=林奥宇 |
| `ToolSystem/SkillHitPresentation/init.luau` | **改写**：删除 `RunService:IsServer()`；只保留查询 + `handleIncoming`；`beginBatch` / `flushBatch` / `accumulateFromLogical` 为 no-op（防误调）；表名 `SkillHitPresentation` |
| `SkillHitPresentationResolver.luau` | **删除**（逻辑并进服 System，避免 AllSide 残留 FireClient） |
| `SkillHitPresentationClient.luau` | **基本不动**（已是客播轨；对照 `NPCCosmeticHitPlay`） |
| `SkillHitPresentationProfile.luau` / `Config` / `SoundMap` | **不动**（无权威状态；freeze 查询表） |
| `UtilsSystem/ModuleRegistry.luau` | `SkillHitPresentation` 改 `_preferServerSystemModule` |
| `SystemEnemy` / `HitResolver.LogicalEnemy` / `BaseSkillServer.Start` / `EnemyManager` | **调用方不改**（仍 `Utils.SkillHitPresentation.*`） |

### 3.1 服模块如何拿到 Profile / SoundMap

服 System 与 ToolSystem 目录不是 `script.Parent` 兄弟。本切片 **不扩 Utils 键**（Profile / SoundMap 不是对外领域 API）。

允许且仅允许：顶部用已缓存 `Utils.ReplicatedFirst` 解析 ToolSystem 容器后再 `require` 子 ModuleScript（与 `HitResolver` 对 `BaseSkill` 长路径同类，不升 P0）：

```lua
local ReplicatedFirst = Utils.ReplicatedFirst
local folder = ReplicatedFirst.AllSideCode.ToolSystem:FindFirstChild("SkillHitPresentation")
local SkillHitPresentationProfile = require(folder:FindFirstChild("SkillHitPresentationProfile"))
local SkillHitPresentationSoundMap = require(folder:FindFirstChild("SkillHitPresentationSoundMap"))
```

禁止 `require(game.ServerStorage...)`。禁止业务 `require` `ModuleRegistry`。客侧 `init` 仍 `require(script.SkillHitPresentationProfile)` / `require(script.SkillHitPresentationClient)`。

### 3.2 公开 API（两端同名，行为按端）

| API | 服 | 客 |
|-----|----|----|
| `resolveProfile` / `resolveHitboxEntry` | 转发 Profile（返回副本） | 同左 |
| `beginBatch` / `flushBatch` / `accumulateFromLogical` | 真实现 | no-op |
| `handleIncoming` | no-op | 转发 Client |

无 `Init`。不注册 CombatWorld。不绑 Remote（`FireClient` 经已缓存 `NetWork`；客 Register 仍在 `EnemyManager`）。

---

## 4. 通信与存档

| 通道 | 是否改协议 | 谁 Register |
|------|------------|-------------|
| `SKILL_HIT_PRESENTATION` | 否 | 仍 `EnemyManager`（客） |
| DataStore / SystemSave | 不碰 | — |

校验顺序（服 `accumulateFromLogical`，规则不变）：`realDmg>0` → `cfgId` 为 number → 非 `skillDotFixedDamage` → `hitPresentation` 表且 `hitPos` 为 Vector3 → 非 `suppressPresentation` → 组条目 → 有批则累积，无批则立即 Nearby 下发。频率仍走 Skill 通道中间件，本切片不新做限频。

---

## 5. 实施顺序（通过 §1.8 且同意后）

1. 新建服 `SkillHitPresentation.luau`（Resolver 行为对齐搬迁 + Profile 转发 + `handleIncoming` stub）  
2. `ModuleRegistry` 改为 `_preferServerSystemModule`  
3. 改写 ToolSystem `init.luau`：去 `IsServer`，stub 写口，保留查询与 `handleIncoming`  
4. 删除 `SkillHitPresentationResolver.luau`  
5. 更新 [`技能系统技术说明.md`](技能系统技术说明.md) §2 表与 §12 路径表：服 System + 客 ToolSystem  

每步保持可运行：先加服模块并切 Utils，再改/删 AllSide Resolver，避免空窗。

---

## 6. 验收

- 逻辑怪 `realDmg>0`：附近玩家仍播 FX + 技能音 + `InjuredSound`；`skipPresentation` / `suppressPresentation` / DoT 固定伤仍不播  
- AOE 同一次 `Hitbox.check` 仍合并为一包（`beginBatch` / `flushBatch`）  
- 无批调用 `accumulateFromLogical` 仍立即下发  
- Nearby 100 stud；无条目不发包  
- `EnemyManager` 在 `怪物系统.启用 == false` 时仍整段不跑（含本 Remote）  
- 无 `IsServer` 业务分支出现在服 System 或 ToolSystem `init`  
- 无第二套 `FireClient(SKILL_HIT_PRESENTATION)`（AllSide 不再留 Resolver）  
- 无第二套角色/逻辑怪位姿写口  
- 调用方源码零改动  

---

## 7. 开工约束（二次审评条件，必须遵守）

1. 无新 Remote / 无新存档字段 / 不改 payload 语义。  
2. System **不** `Connect` / `Register*Remote`；**无** `Init`；**不**调用 `CombatWorld.Init` 或其它模块 `Init`。  
3. 不把表现并进 `SystemEnemy` / `NPCCosmeticHit` 函数体；不并进 `HitResolver` 结算。  
4. **§1.7：** 禁止写 `CFrame` / `WalkSpeed` / 速度 / `Store.cframe`。客只 `PlayEffect` / `PlaySoundLocal`。  
5. **§1.6：** 客 `handleIncoming` 只播表现；不以客包或客 `CFrame` 结算伤害。  
6. 服 System 允许 `Utils.ReplicatedFirst` → ToolSystem 容器 `require` Profile / SoundMap；**不扩 Utils 键**。  
7. 服 / 客业务模块禁止 `IsServer` / `RunService:IsServer()`。分流只留 `ModuleRegistry._preferServerSystemModule`。  
8. 新/改写文件头 `Author` = `git config user.name`（林奥宇），`Last Modified` = 开工日。UTF-8 无 BOM，LF。  
9. 行为必须对齐搬迁（含 DoT 跳过、默认特效名、`targetScale`、Nearby、批状态）。  
10. 删除 AllSide `SkillHitPresentationResolver.luau`；保留 `SkillHitPresentationClient.luau`。  
11. 调用方不改；同一改动更新 [`技能系统技术说明.md`](技能系统技术说明.md) 受击表现路径。  
12. 不登记进 Utils `SystemModules` 抢先表（走 `_preferServerSystemModule`，与 NPCCosmeticHit 相同）。  

---

## 8. §1.8 二次审评（2026-09-01）

对照 `docs/代码结构和设计开发规范.md` §1.2–1.4、§1.6、§1.7、Remote/存档、未决问题。与初稿分开出具，不以方案自述代替审评。

| 项 | 结论 |
|----|------|
| §1.2 分层 | 服 Nearby/`FireClient` 离开 AllSide，进 `ServerSideCode/System`；客播轨留 ToolSystem（与 NPCCosmeticHit 同形）。Profile/Config/SoundMap 无权威写，可留 ToolSystem。 |
| §1.3 Manager/System | 客 Register 仍 `EnemyManager`；System 不绑 Remote、无 Init、不进 CombatWorld。 |
| §1.4 双端拆分 | 两份模块；`IsServer` 只留 `ModuleRegistry` 加载分流。 |
| §1.6 | 客只播 FX/音；通知集合由服按 `realDmg`/抑制/Nearby 决定。HRP 仅受众过滤。无客机结算。 |
| §1.7 | 方案禁止位姿/速度写口；`PlayEffect` 不回写 Store。无第二写口。 |
| Remote / 存档 | 不新开通道、不改 `SKILL_HIT_PRESENTATION` payload、不碰 DataStore。 |
| 未决 | 服 `require` ToolSystem 子脚本已写回 §7.6（P1，不升 P0）。Resolver 迁后必须删 AllSide 文件，避免双下行。 |

**P0：** 无。  
**结论：有条件通过。** 条件以 §7 为准（已写回方案）。需求提出方明确同意后才能改业务代码。
