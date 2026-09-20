# BaseSkill / GroupSkill 运行时拆层方案

对照审查名单：`BaseSkill` / `GroupSkill` 运行时维持不通过（架构 P0：ClientSideCode 服权威、`IsServer` 混写、`PlayerAimSync` 私连 Remote）。  
本方案只拆层与收口写口 / Remote，**不改命中/伤害/装备权威**，**不新开 Remote**，**不新存档字段**。

> 创建：2026-08-31 · 作者：林奥宇  
> 状态：已按方案落地（2026-08-31）；待规范性复审改 BaseSkill/GroupSkill 架构 P0 结论  
> Last Modified: 2026-08-31  
> 新会话入口：对 Agent 说「按 BaseSkillGroupSkill拆层方案开工」；先读本文全文，再按 §6 顺序改，§8 全遵守。  
> 对照：SkillBuffUtil / NPCCosmeticHit 拆写口（服 System + 客 stub、Utils 按端分流、Init 不互调、不私连 Remote）  
> 前序：B3 三项拆层已把 Manager 业务下沉到 `SystemPlayerSkill`，并明确「不把 GroupSkill / BaseSkill 迁出 ClientSideCode」——本切片就是那一项迁层。

---

## 0. 目标与非目标

### 目标

| 项 | 现状 | 目标 |
|----|------|------|
| 服权威运行时 | `GroupSkillServer` / `BaseSkillServer` / `GroupSkillInstanceRuntime` / `SkillReleaseCrossCheck` 放在 `ClientSideCode/SystemSkill` | 迁到 `ServerStorage/ServerSideCode/SystemSkillRuntime/`；客机不再加载这些 façade |
| `PlayerAimSync` | 同一文件 `IsServer` 混写；`Instance.new("RemoteEvent")` + `OnServerEvent:Connect` | 服模块 + 客模块；走已有 `NetMsg.PLAYER_AIM_SAMPLE` / `SkillNet.PlayerAimSample`；Manager Register |
| `HitResolver` | ClientSideCode 内伤害结算 + 多处 `IsServer` 早退；`SkillDemoProjectile` 顶部 require | 服写口在 ServerSideCode；客 stub no-op；Utils 分流 |
| `Hitbox` 逻辑怪 OBB | `RunService:IsServer()` 才调 `collectLogicalOverlapHits` | 去掉 `IsServer`；有 `SystemEnemy.collectLogicalOverlapHits` 才调（客 stub 无此函数） |
| `SkillReleaseCrossCheck` | `assertServer()` + `IsServer` | 随服运行时迁走后删除该分支 |

### 非目标（本切片禁止顺手做）

- 不改伤害公式、HitPolicy、派生规则、CD 权威、装备（`SystemSkill`）
- 不新 Remote、不改 `PLAYER_AIM_SAMPLE` payload（仍 `Vector3` + 可选 `clientTime`）
- 不把运行时登记进 Utils 的 ToolSystem `SystemModules` 表（避免抢在 Server/Client 动态发现之前加载到错误层）
- 不迁 `GroupSkillClient` / `BaseSkillClient` / `SkillAction` / `GetSkillData` / `SkillModule` / `GroupSkillModule`
- 不拆 `SkillHitPresentation` 的 `IsServer`（兄弟债）
- 不新开位移写口；击退仍只经 `SystemCharacterMotion.FireKnockback` → `CharacterMotion`
- 不把 `PlayerAimSync` 瞄准点当命中或发奖证据

---

## 1. 权威与写口（§1.6 / §1.7）

| 资源 | 权威 / 写口 | 本切片 |
|------|-------------|--------|
| 技能槽装备 | 仅 `SystemSkill`（服） | 不动 |
| 可否释放、跨槽、CD、`skillCastId` | 服 `SystemPlayerSkill` + `GroupSkillServer` | 文件搬家，规则不变 |
| 派生转段 | 仅服 `BaseSkillDerived` / GroupSkillServer | 不动规则 |
| Hitbox 检测与伤害 | 仅服 `HitResolver` / `Hitbox.check`（客 `CLIENT_HITBOX_DISABLED=true`） | 写口迁服模块；客 stub 不结算 |
| 手动瞄准落点 | 客上报采样；服校验后写入缓冲；`getTargetCF` 未自瞄时读缓冲 | 通道改走 NetWork；**不以该点定伤/发奖** |
| 客预测施法 | `GroupSkillClient.onInputBegan`；服否决清预测 | 仍预测，不以客为准 |
| 角色击退 / 橡胶 | 客 `CharacterMotion.Compose`；服 `SystemCharacterMotion.Fire*` | 不新写口 |
| 逻辑怪位姿 | `LogicEntityMotion` / `EnemySim` | 不写 |
| WalkSpeed / 占闸 | `LockMovement` / `ActionArbiter` | 不写 |

**§1.6：** 瞄准采样只作「未自瞄时的目标点」；命中仍服 `HitResolver` + 逻辑怪 OBB。禁止把客 `CFrame` / 瞄准点当伤害或掉落证据。  
**§1.7：** 禁止新脚本写 `CFrame` / `WalkSpeed` / `Store.cframe`。`DashStyleRoll` 仍只进 `CharacterMotion` Drive。

---

## 2. 方案 A：服运行时迁 `SystemSkillRuntime`

### 2.1 为什么不并进 SystemSkill / SystemPlayerSkill

- `SystemSkill`：装备权威（已通过复审），不能重开。
- `SystemPlayerSkill`：槽表与释放门控（已通过），不能把状态机/Hitbox 并进去。
- 组/基技 façade 仍是独立领域，只是物理层从 ClientSideCode 挪到 ServerStorage。

### 2.2 目标目录

```text
ServerStorage/ServerSideCode/SystemSkillRuntime/
  GroupSkillServer/          -- init + Cooldown / Input / InstanceFactory
  BaseSkillServer/           -- init + Sync / Start / Lifecycle
  GroupSkillInstanceRuntime.luau
  SkillReleaseCrossCheck.luau
```

**不**放进 `ServerSideCode/System/`，避免 Utils `__index` 按名动态发现、客户端误触。  
Rojo 已映射整个 `ServerSideCode`，新目录自动同步。

### 2.3 require 约定

迁走后 `script.Parent.GetSkillData` 会断。改为与现 `SystemPlayerSkill` 相同的长路径例外（本切片仍不把共享工具登记进 Utils）：

```lua
local BaseSkill = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local GetSkillData = require(BaseSkill.GetSkillData)
```

`GroupSkillInstanceRuntime` 必须与 `GroupSkillServer` **一起迁**（`InstanceFactory` 相对 require 它）。  
`ChainConditionContext` / `DeclarativeCondition` 仍留 ClientSideCode，运行时改为长路径 require。

调用方只改路径：

| 调用方 | 现路径 | 新路径 |
|--------|--------|--------|
| `SystemPlayerSkill`（服） | `.../SystemSkill/GroupSkill/GroupSkillServer` 与 `SkillReleaseCrossCheck` | `game.ServerStorage.ServerSideCode.SystemSkillRuntime.*` |
| `GroupSkillServer` → `BaseSkillServer` | `script.Parent.Parent.BaseSkill.BaseSkillServer` | 同目录上层 `SystemSkillRuntime.BaseSkillServer` |
| `BaseSkillServer/Start` → `HitResolver` | 函数内 `require(script.Parent.Parent.HitResolver)` | 顶部 `Utils.HitResolver`（见方案 B） |

内容模块 `SkillModule/*` **不** require 服 façade。

### 2.4 `SkillReleaseCrossCheck`

随目录迁到 ServerStorage 后删除 `assertServer` / `IsServer`。现 `SkillCommon` 模板并无 `beginCrossCheck`；若线上 SkillModule 有 `registerProvider`，保持 API，仅路径改为新目录（或由 `GroupSkillServer` 再导出）。本切片不改交叉检查语义。

---

## 3. 方案 B：HitResolver（对照 SkillBuffUtil）

### 3.1 分层

```text
服  BaseSkillServer / SkillDemoProjectile.onProjectileHitServer
      → Utils.HitResolver.applyHit / applyLogicalEnemyHit
           -- ServerSideCode/System/HitResolver.luau（从 ClientSideCode 搬入，删 IsServer）

客  Utils.HitResolver
      -- ToolSystem/HitResolver.luau stub：applyHit / applyLogicalEnemyHit 为 no-op
```

Utils 分流（与 SkillBuffUtil 相同，**显式键**，不要只靠 System 动态发现）：

```lua
HitResolver = function()
    if IsServer and ServerSystemPath then
        local serverMod = ServerSystemPath:FindFirstChild("HitResolver")
        if serverMod and serverMod:IsA("ModuleScript") then
            return serverMod
        end
    end
    return _getModuleInstance(SystemPath, "HitResolver")
end
```

### 3.2 调用方

- `SkillDemoProjectile`：`require(script.Parent.Parent.BaseSkill.HitResolver)` 改为顶部缓存 `Utils.HitResolver`。
- `BaseSkillServer/Start.luau`：去掉函数内 `require`，改为文件顶部 `local HitResolver = Utils.HitResolver`。

### 3.3 Hitbox（共享检测，不整文件搬家）

`Hitbox.check` 末尾逻辑怪 OBB：

```lua
if SystemEnemy and SystemEnemy.collectLogicalOverlapHits and self.hitbox then
```

客侧 `Utils.SystemEnemy` 无此函数，分支自然不进。删除 `RunService:IsServer()` 与注释掉的旧 `IsServer`。`Hitbox` 仍留 ClientSideCode（客 `CLIENT_HITBOX_DISABLED` 不 start；服 RuntimeHost 仍用同一检测体）。

---

## 4. 方案 C：PlayerAimSync

### 4.1 为什么可以留两份表

`refreshAimSnapshot` 只清 `skillRunData.manualAimSnapshotCF` 再调实例 `getTargetCF()`。  
SkillModule（双端加载）继续相对 require **客文件** 的 `refreshAimSnapshot`；服 `BaseSkillServer:getTargetCF` 走 **服文件** 的 `getOrFreezeManualAimCF`。快照字段在实例上，不在模块表上。

### 4.2 文件

| 路径 | 动作 |
|------|------|
| `ServerStorage/ServerSideCode/System/PlayerAimSync.luau` | **新建**：缓冲、`validateAndRecordSample` / `OnSample`、`getOrFreezeManualAimCF`（只读服缓冲）、`clearServerBuffer`；`Init` 只钩 `PlayerRemoving`（同端 Players，**禁止** Register Remote） |
| `ClientSideCode/SystemSkill/BaseSkill/PlayerAimSync.luau` | **改写**：删除 `IsServer`、`ensureAimRemote`、`Instance.new`、`OnServerEvent`；`initClient` 用 `SkillNet.PlayerAimSample:FireServer`；`getOrFreezeManualAimCF` 只读客本地 CF |
| `UtilsSystem.luau` | 显式键 `PlayerAimSync`：服优先 System 文件，客回落 ClientSideCode 路径（或 ToolSystem stub + 保留 ClientSideCode 给 SkillModule 相对 require） |
| `PlayerSkillManager` | `RegisterServerRemoteEvent(NetMsg.PLAYER_AIM_SAMPLE, PlayerAimSync.OnSample)`；`PlayerAimSync.Init()`（清理缓冲） |
| `PlayerSkillClientManager` | 仍调客 `initClient`；不处理瞄准 Remote 以外的新通道 |

校验（服 `OnSample`）：玩家在线 → `typeof(pos)==Vector3` → 持武 → 有 HRP → 水平距离 ≤ `DEFAULT_MAX_AIM_HORIZONTAL_STUDS`。不采用 `clientTime` 做结算。频率仍 0.05s 客侧采样；本切片不新做服限频（瞄准非发奖通道）。

**禁止**再 `FindFirstChild("PlayerAimSample")` 后私建 Remote：`NetMsg.PLAYER_AIM_SAMPLE` 已由 NetWork 管道持有。

---

## 5. 通信与存档

| 通道 | 是否改协议 | 谁 Register |
|------|------------|-------------|
| `PLAYER_AIM_SAMPLE` | 否（已有 NetMsg / SkillNet，现被 PlayerAimSync 旁路） | 改由 `PlayerSkillManager` Register → `PlayerAimSync.OnSample` |
| `RELEASE_GROUP_SKILL` 等 | 否 | 仍两 Manager → `SystemPlayerSkill` |
| DataStore / SystemSave | 不碰 | — |

---

## 6. 实施顺序（通过 §1.8 且同意后）

1. Utils：`HitResolver` / `PlayerAimSync` 分流键  
2. 新建服 `HitResolver` + 客 stub；改 `SkillDemoProjectile` 与 `BaseSkillServer/Start`；删函数内 require  
3. `Hitbox.check` 去掉 `IsServer`  
4. 新建服 `PlayerAimSync`；改客文件；Manager Register `PLAYER_AIM_SAMPLE`；删除私建 Remote  
5. 新建 `SystemSkillRuntime/`，搬 GroupSkillServer / BaseSkillServer / InstanceRuntime / CrossCheck；改长路径；删 `IsServer`  
6. `SystemPlayerSkill` 改 require 到 `SystemSkillRuntime`  
7. 更新 [`技能系统技术说明.md`](技能系统技术说明.md) §2 分层图与 §16 索引  

每步保持可运行：先加服模块再切调用方，避免空窗。

---

## 7. 验收

- 持武手动瞄准：服 `getTargetCF` 仍能吃到 10Hz 缓冲；超距/未持武丢包  
- 自瞄技能：不发包、不读手动缓冲  
- Meteor / 弹道：服 Hitbox 结算逻辑怪；客 Query 关仍能杀（服 OBB）  
- `SkillDemoProjectile` 客机 require 不再执行 `applyHit`  
- 预测冲刺 / 跨槽 / 死亡打断 / 旁观与现网一致  
- 无 `IsServer` 出现在 `PlayerAimSync` / `HitResolver` / `Hitbox` / `SkillReleaseCrossCheck` / 新 `SystemSkillRuntime`  
- 无第二套角色位姿写口；无新 Remote 实例名  

---

## 8. 开工约束（二次审评条件，必须遵守）

1. 无新 Remote / 无新存档字段 / 不改 `PLAYER_AIM_SAMPLE` payload 语义。  
2. `PlayerAimSync` / `HitResolver` / `SystemSkillRuntime` **不** `Connect` / `Register*Remote`；瞄准通道只由 `PlayerSkillManager` Register。  
3. 不调用 `CombatWorld.Init` 或其它模块 `Init()`。  
4. 不把运行时并进 `SystemSkill` / `SystemPlayerSkill`；不把 `GroupSkillServer` / `BaseSkillServer` 登记进 Utils `SystemModules`。  
5. **§1.6：** 瞄准点不得作为命中或发奖证据；伤害只经服 `HitResolver`。  
6. **§1.7：** 不写 `CFrame` / `WalkSpeed` / `Store.cframe`；击退仍 `SystemCharacterMotion`。  
7. `GroupSkillInstanceRuntime` 必须与 `GroupSkillServer` 同迁；禁止只搬 façade 留下相对 require。  
8. `BaseSkillServer/Start` 禁止函数内 `require`；`SkillDemoProjectile` 必须走 `Utils.HitResolver`。  
9. 客 `PlayerAimSync` 禁止 `Instance.new("RemoteEvent")`；Fire 只经 `SkillNet.PlayerAimSample`。  
10. SkillModule 相对 require 的客 `PlayerAimSync` 只保留 `refreshAimSnapshot` / 自瞄查询；服 `getOrFreeze` 只在服模块。  
11. 新/改写文件头 `Author` = `git config user.name`（林奥宇），`Last Modified` = 开工日。  
12. 行为除「瞄准改走 NetWork（同名通道）」外必须对齐搬迁。  
13. 同一改动更新 `技能系统技术说明.md` §2 / §16。  
14. 不拆 SkillHitPresentation；不迁 SkillModule 内容。  
15. `SystemSkillRuntime` 目录名固定，避免 Utils 动态发现；服 `SystemPlayerSkill` 用 `game.ServerStorage.ServerSideCode.SystemSkillRuntime` 长路径。  
16. **不迁** `GroupSkillClient` / `GroupSkillClientInstanceRuntime` / `BaseSkillClient`。  
17. 客 `PlayerAimSync` 迁走后禁止残留 `serverBufferByUserId` / `initServer` / `OnServerEvent`。  
18. 服 `HitResolver` 对 `DamageResolver` / `GetSkillData` 等仍用 ClientSideCode 长路径；结算写口只留在服文件。  
19. 开工后手测：手动瞄准、Meteor 逻辑怪、SkillDemoProjectile、预测冲刺拒释；确认 Msg 下只有一份 `PlayerAimSample`。  

---

## 9. 新会话开工入口（交接）

下一会话 **只做本方案落地**，不要顺手修 SystemBuyRoblox P1，也不要重开 §1.8。

**建议开场白：**

```text
按 docs/BaseSkillGroupSkill拆层方案.md 开工。
§1.8 已有条件通过，条件在方案 §8。按 §6 顺序做，做完复审 BaseSkill/GroupSkill 架构 P0。
Author 用 git config user.name（林奥宇）。不要新 Remote、不要改伤害/装备。
```

**对照实现（SkillBuffUtil / NPCCosmeticHit）：** Utils 显式键分流；服模块不 Register Remote；Init 不互调。

**现文件（搬迁前）：**

| 现路径 | 动作 |
|--------|------|
| `ClientSideCode/SystemSkill/BaseSkill/HitResolver.luau` | 迁 `ServerSideCode/System/HitResolver.luau` |
| `ClientSideCode/SystemSkill/BaseSkill/PlayerAimSync.luau` | 拆：服新建 System 文件，客改写去 Remote/`IsServer` |
| `ClientSideCode/SystemSkill/BaseSkill/Hitbox.luau` | 去掉 `IsServer`，有 `collectLogicalOverlapHits` 才调 |
| `ClientSideCode/SystemSkill/BaseSkill/BaseSkillServer/` | 迁 `ServerSideCode/SystemSkillRuntime/BaseSkillServer/` |
| `ClientSideCode/SystemSkill/GroupSkill/GroupSkillServer/` | 迁 `SystemSkillRuntime/GroupSkillServer/` |
| `ClientSideCode/SystemSkill/GroupSkill/GroupSkillInstanceRuntime.luau` | **同迁** |
| `ClientSideCode/SystemSkill/GroupSkill/SkillReleaseCrossCheck.luau` | 同迁，删 `IsServer` |
| `SystemPlayerSkill.luau`（服） | require 改到 `game.ServerStorage.ServerSideCode.SystemSkillRuntime.*` |
| `PlayerSkillManager.server.luau` | Register `NetMsg.PLAYER_AIM_SAMPLE` |
| `SkillDemoProjectile.luau` | `Utils.HitResolver` |
| `UtilsSystem.luau` | 显式键 `HitResolver` / `PlayerAimSync` |
| `docs/技能系统技术说明.md` | §2 / §16 |

落地后：改方案状态为已开工/已落地；名单里 BaseSkill/GroupSkill 待规范性复审改结论。  
