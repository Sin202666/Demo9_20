# 战斗仿真 ECS 迁移方案（总方案）

> **进度（2026-08-18）**：一期 A/B + Projectile **已完成**；**逻辑怪 L0–L5 已收口**（含 I7=A；陨石可击杀）。  
> **§4.3.3：PartIcles 永不进 CombatWorld**。  
> **三期已落地：** C0a/C0b（`Enemy` 碰撞组 + 受击表现）、**LogicalDisplace**、浮空 A0/A1/A2 代码。TRANSFORM **20Hz**（~~10Hz~~ 已作废）。技能 Group/Base 已拆目录 façade（调度仍 CombatWorld）。  
> **下一主路径：** C0 基线 / **C1 Attacking** / 浮空 **A3** 空中 Anim；**并行运动轨 M0–M2 已手测封板**（迷宫绕路）见 [`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md)；**不**开 Summon/关卡/物理怪 Script；**不**换 Matter/JECS。  
> Author: 林奥宇 · Created: 2026-08-12 · Last Modified: 2026-08-28（运动轨 M0–M2 另立）

> **文档对齐（2026-08-18 · 对照代码）**：下列旧述已过时，正文已改为现行值。

| 过时陈述（勿再引用） | 现行代码 |
|----------------------|----------|
| TRANSFORM **10Hz** | **20Hz**（`EnemyLogicalSync` `TRANSFORM_INTERVAL=0.05`；10Hz+短缓冲会回拉） |
| C0b「首包不做 LogicalDisplace」 | **已落地**：`LogicalDisplace` + Profile；EnemySim 顺序：Airborne → Displace → Ranger |
| 客 LocalMonster 无 CollisionGroup；作者规范「不要求碰撞组」 | 表现层 **CollisionGroup=`Enemy`**；权威仍服 OBB；**CanQuery=false** |
| A1「落地中」为唯一状态 | A1/A2 **代码已接**（服 `moveState=air_*`）；A3 客 `_setLocomotion` 对 air_* **仍回退 idle** |
| §4.3.2 J「工作区脏、未提交」 | **已合入主线** |
| GroupSkill / BaseSkill 单文件 | **目录 façade**（`init` + 子模块；`require(...GroupSkillClient)` 路径不变） |
| Ranger Attacking / `enemyConf` bbox 列 / SkillBuff 堆叠·DoT | **均未做**（C1 / C2 / C3 仍待开工） |

---

## 1. 背景与目标

### 1.1 现状问题（一期前）

- 仓库**无** Matter / JECS / 自研 World 等 ECS 框架。
- 技能运行时已呈半 ECS 形态（`runningRuntimeList` + Tick），但：
  - GroupSkill / BaseSkill / 部分 SkillModule **各自** `Heartbeat:Connect`；
  - Meteor / SpaceSkill 等存在**每施法一条**帧循环，连接数随实例线性增长。
- PartIcles、SkillBuffUtil、EntityUtil 等已接近「实体列表 + 系统」，但调度分散。

### 1.2 目标（分层）

| 层级 | 目标 | 状态 |
|------|------|------|
| **近期（一期）** | 战斗仿真统一 `CombatWorld:step(dt)`；消灭技能热路径上的多 Heartbeat | **已完成** |
| **中期（二期）** | 弹道 / 逻辑怪进 World | 弹道 **已完成**；逻辑怪 **L0–L5 已收口**；PartIcles **不进 World**（§4.3.3） |
| **中期（三期）** | 战斗闭环深化：怪物侧（碰撞组 + 受击 + 击退 + 浮空代码）→ **C1 敌方攻击态**、bbox、StatusEffect；可选追踪弹 / 薄组件表 | **当前主路径**（§4.5；C0a/C0b/Displace/A1–A2 已接，C1 未开） |
| **远期（可选）** | 按实体规模决定是否换 Matter / JECS；**边界不变，只换存储与查询** | 待触发（§4.3.6） |

### 1.3 非目标

- 不把 `SystemSave` / `SystemBag` / `SystemShop` / UI / Lighting / Camera 做成 ECS。
- **不把 PartIcles 迁入 CombatWorld**（中立 FX；见 §4.3.3）。
- 一期不重写 PartIcles 对象池与 UpdateX。
- 一期不做完整 Component 数据表重构（可先「注册 Tick」，后「组件化」——见 §4.3.5）。

---

## 2. 决策摘要

### 2.1 两层决策（正交）

| 决策 | 问什么 | 本方案结论 |
|------|--------|------------|
| **迁移边界** | 哪些模块进 World | **边界 B**：仅战斗仿真进；服务型 System 永外；槽位/属性做桥接 |
| **框架选型** | 用自研 / Matter / JECS | **一期自研薄 CombatWorld**；二期按规模再评估是否换库 |

### 2.2 选型对照（供二期分叉）

| 方案 | 适合 | 风险 |
|------|------|------|
| **自研薄 World** | 先止血调度、贴合现有 Utils/Manager | 组合查询需自建 |
| **Matter** | 长期玩法全面 ECS、重协作与 Debugger | 依赖与心智成本；极致吞吐一般 |
| **JECS** | 怪潮 / 海量弹道、要 archetype 性能 | 与现有 OOP Runtime 落差大 |

**已走路径：** 自研 + 边界 B → 一期 A 只迁调度 → 一期 B 战斗 Buff 挂 World。

---

## 3. 迁移边界（进 / 桥 / 不进）

### 3.1 总图

```text
永不进 ECS          桥接层                    Combat World
─────────────       ─────────────             ─────────────────
Save / DataStore    SystemSkill(槽位) ──Cast→ SkillRuntime
Bag / Shop / UI     SystemPlrAttr ←──Hit──── Hitbox / Projectile
Net / Lighting      SystemEnemy(薄权威)←───── EnemySim（Ranger+Displace+Airborne；无 Summon）
Camera / Rank       CharacterMotion ←──────── StatusEffect / Motion（暂缓）
SystemBUFF(存档型)  UpdateManager ──────────→ CombatWorld.Init
                                              SkillBuff（一期 B 已挂 StatusEffect）
```

### 3.2 进 World

| 阶段 | 模块 | 路径（根下） | 状态 |
|------|------|----------------|------|
| **一期** | GroupSkill / BaseSkill 运行时 | `GroupSkill/{GroupSkillClient,GroupSkillServer}/`（目录 façade）；`BaseSkill/{BaseSkillClient,BaseSkillServer}/` | 已完成（2026-08-18 拆目录，调度不变） |
| **一期** | Hitbox / 命中查询调度 | `SkillHitboxRuntime`、`HitResolver` 等 | 已完成（经 Runtime/World） |
| **一期** | SkillModule 逻辑 Tick | `SkillModule/**`（禁止私自 Heartbeat） | 已完成（样例+禁令） |
| **一期** | Entity 身份适配 | `BaseSkill/EntityUtil.luau` | 已完成 |
| **一期 B** | 战斗状态窗 | `ToolSystem/SkillBuffUtil.luau` | 已完成 |
| **二期** | 弹道 | `SkillModule/_Templates/Projectile/*` 及实现 | **已完成** |
| **二期** | 客户端逻辑怪 | RP18 Logical* + `SystemLogicalEnemy` | **L0–L5 已收口**（无 Summon / 无关卡 / 无物理怪 Script） |
| **二期** | Motion（NPC 共用时） | `CharacterMotion` / `SystemCharacterMotion` | 暂缓（现仅玩家） |
| — | PartIcles | `ToolSystem/PartIcles` | **不进 CombatWorld**（§4.3.3 已否决） |

### 3.3 桥接（不进 World，向 World 读写）

| 模块 | 路径 | 职责 |
|------|------|------|
| SystemSkill（槽位） | `ServerStorage/.../System/SystemSkill.luau` | 装备存档 → 仅 `Cast` / 取消 |
| SystemPlrAttr | `.../SystemPlrAttr.luau` | 承伤 / 属性；被 Hit system 调用 |
| SystemEnemy（薄权威） | `.../SystemEnemy.luau` | 注册 + TakeDamage；仿真进内、权威可留外 |
| Managers | `InitGame/Manager`、`StarterPlayerScripts/Manager` | 只启停 World，不写业务 Tick |

### 3.4 永不进

Save / FixData / DataStore、Bag / Shop / BuyRoblox / Email / Code / DailyAward / Feedback、  
SystemBUFF（元游戏）、ServerBuff / GlobalData / Rank / RedPoint / Record / Leaderstats / Set / UpdateLog、  
Teleport / SDK、Camera / Lighting* / UIMgr / NetWork / CfgFind / DataCache、  
**PartIcles / FXUtil / SequenceManager**（中立表现层；与 `战斗系统`/`技能系统` 门控正交）等。

---

## 4. 分阶段实施计划

### 4.0 阶段总览

| 阶段 | 名称 | 交付 | 成功标准 | 状态 |
|------|------|------|----------|------|
| **一期 A** | 统一调度 | `CombatWorld` + 技能热路径去多 Heartbeat | 同侧战斗逻辑 Tick 仅 1 条全局循环；连接数不随施法线性涨 | **已完成** |
| **一期 B** | 状态效果挂接 | SkillBuff 进同一 `step` | 无第二套战斗 buff 时钟 | **已完成** |
| **二期** | 规模实体 | Projectile / 逻辑怪 | 逻辑怪可批量 Tick | 弹道已完成；**逻辑怪 L0–L5 已收口**；PartIcles **不迁 World** |
| **三期** | 战斗闭环深化 | 敌方攻击闭环 + 数据硬化 + StatusEffect | 逻辑怪能打人；同屏 N 可测；Buff 可堆叠/DoT | **当前主路径**（§4.5） |
| **组件化深化** | 三期内可选轨 | 热路径稀疏组件表 / 查询 API | 组合查询成本下降，且不改边界 | 按触发条件（§4.5.4） |
| **选型分叉** | 换库评估 | 保留边界，评估 Matter vs JECS | 有实体量 + 维护成本数据后再定 | 待触发 |

---

### 4.1 一期 A — 统一调度（已完成 · 存档）

#### 落地要点

| 项 | 实际路径 / 结果 |
|----|-----------------|
| CombatWorld | `ReplicatedFirst/AllSideCode/ToolSystem/CombatWorld.luau`；`Utils.CombatWorld` |
| Phase | `Cooldown(10)` → `SkillRuntime(20)` → `Hitbox(30)` → `StatusEffect(40)` |
| Init | 双端幂等：`UpdateManager.server`、`PlayerSkillManager`、`PlayerSkillClientManager` 均调 `CombatWorld.Init()` |
| BaseSkill 时钟 | `BaseSkillRuntimeHost.startClock` → `CombatWorld.register`（`Phase.SkillRuntime`） |
| GroupSkill | Runtime + Cooldown 均 `register`（Cooldown 用 `Phase.Cooldown`） |
| Meteor1 / SpaceSkill1 | 逻辑 Tick 经 World；无每施法 Heartbeat |
| 规范 | [`技能模块作者规范.md`](技能模块作者规范.md) + `_Templates/SkillCommon.luau` 禁 Heartbeat |

#### 仍允许的例外（非技能实例仿真）

| 文件 | 原因 |
|------|------|
| `SkillSyncRouter.luau` audience sweep | 网络订阅清理 |
| `PlayerAimSync.luau` | 输入/同步 |
| Meteor / NewRoll Fx 的 **RenderStepped** | 纯表现；**禁止**承载伤害/Hitbox/状态机 |

#### 验收（一期 A）

- [x] 技能热路径无新增/残留的「每实例 Heartbeat」
- [x] 同侧战斗逻辑 Tick 由 World 统一驱动
- [x] 新 SkillModule 模板写明禁止私自 Connect
- [ ] 现有 Meteor / SpaceSkill / NewRoll / SkillDemoCast **行为回归**（建议在二期开工前补一轮）

---

### 4.2 一期 B — SkillBuff 挂接（已完成 · 存档）

| 项 | 结果 |
|----|------|
| 动作 | `SkillBuffUtil.Init()` 注册 `Phase.StatusEffect`；UpdateManager **不再** FAST 扫 Buff |
| 约束 | SkillBuffUtil **无**自建 Heartbeat；`SystemBUFF`（存档元游戏）**不迁** |
| 验收 | [x] 战斗减速/窗与技能同一 `step`；堆叠/DoT 接口可后置 |

---

### 4.3 二期 — 规模实体（已收口 · 存档）

> 原则：**只迁 / 移植仿真 Tick 与批量更新**；权威结算仍走桥接（`SystemPlrAttr` / `SystemEnemy` Hit）。  
> 新代码一律 `CombatWorld.register`，禁止新增战斗仿真 Heartbeat（含「每怪一条」）。  
> **现状快照（2026-08-12）：** 本仓无敌召仿真；RP18 有完整逻辑怪 + 物理怪双轨。本阶段**只吃逻辑怪/客户端怪物轨**。

#### 4.3.0 建议执行顺序

```text
1) Projectile                                   ← 已完成（§4.3.1）
2) 客户端逻辑怪（RP18 Logical* → CombatWorld） ← L0–L5 已收口（§4.3.2）
3) PartIcles                                    ← **不迁 CombatWorld**（§4.3.3 已拍）
4) **三期战斗闭环**（Attacking / bbox / StatusEffect）← **当前主路径**（§4.5）
5) Motion / 组件化 / 换库                       ← 按触发（§4.5.4 / §4.3.6）
```

**本阶段（二期）不做：** Summon、RP18 关卡、物理怪 Script；首包 AI 仅 **Ranger**。  
**三期仍不做：** 同上三项 + Matter/JECS + PartIcles 进 World。

---

#### 4.3.1 P0 — Projectile（弹道）【已完成】

| 里程碑 | 交付 | 状态 |
|--------|------|------|
| **M0** | `PlayerSkillClientManager`：`ProjectilePathConfirmed` / `HitConfirmed` 等 mid-event → `BaseSkillClient.handleServerEvent` | 已完成 |
| **M1** | `_Templates/Projectile/ProjectileLinearRuntime.luau`（`Phase.Hitbox` spawn/tick/stop） | 已完成 |
| **M2a** | `GroupSkillModule/SkillDemoProjectile` + `SkillModule/SkillDemoProjectile`（直线撞敌 + 伤害 + Path/Hit） | 已完成 |
| **M2b** | `Server_UpdateProjectileObstacleCheck` + 旁观 Path 对齐（经 M0） | 已完成 |
| **M3** | 本文 / 作者规范 / 技术说明 / SkillCommon 头注释回写 | 已完成 |

| 项 | 实际结果 |
|----|----------|
| Phase | 复用 `CombatWorld.Phase.Hitbox`（未新增 Projectile=25） |
| 禁令 | 弹道逻辑无 `Heartbeat:Connect`；句柄进 `runData.runEvent` |
| 桥接 | `onProjectileHitServer` → `HitResolver` + `ImpactResolver` + `fireProjectileHitConfirmed` |
| Tracking | `ProjectileObjectTracking` 仍占位（自瞄后置） |

**验收**

- [x] 模板 + 样例技能经 `CombatWorld.register`；无每弹一条 Heartbeat
- [x] 客户端 mid-event 可路由到 `onServerEvent`
- [x] 作者规范补充直线弹道约定
- [ ] 手测：同屏多发连接数不涨；撞敌/撞障；旁观可见飞行（建议合入前 / 敌召开工前补）

---

#### 4.3.2 P0 — 客户端逻辑怪 ECS 迁移【L0–L5 已收口】

> **目标一句话：** 移植 RP18 **逻辑怪**（服务端内存权威 + 定向同步 + 客户端 `LocalMonster` 插值），AI/位移 Tick 进 `CombatWorld` 批处理；**不**做 Summon、**不**做关卡、**不**移植物理怪 Script 栈。  
> **现行覆盖（相对本节当时快照）：** TRANSFORM 已改为 **20Hz**（L2 当时写 10Hz，已作废）；客表现层已写 `CollisionGroup=Enemy`（C0a）；击退/浮空见 §4.5。

##### A. 已锁定范围

| 项 | 决议 |
|----|------|
| Summon | **暂不考虑**（`SystemSummon` 保持空壳；无 `SummonSim`） |
| RP18 关卡 | **忽略**：`DungeonEnemy`、`SystemSpecialEnemy`、波次/分帧刷怪/通关结算一律不迁 |
| 怪物形态 | **只移植客户端逻辑怪**：服 `LogicalStore` 权威 + 客户端 `SystemLogicalEnemy` 表现 |
| 物理怪 | **不迁**：`workspace.Monster` + 克隆 `AI\Script\{Archetype}` + 每怪 `connectHeartbeat` |
| 首包 AI | **Ranger**（逻辑装配，无物理 Script） |
| 同步频率 | L2 当时 **10Hz**；**现行 20Hz**（`TRANSFORM_INTERVAL=0.05`） |
| **Hit / 伤害体积** | **服端纯数据 OBB**（`cframe`+`bboxSize`）；`collectLogicalOverlapHits`；**禁** LocalMonster 权威检测 |
| bboxSize | **配表优先 + Extents 兜底**；现表无 bbox 列 → **首包 Extents** |
| Hitbox 双端 | **必须对齐**：服对逻辑体做权威相交；客户端可不做权威结算 |
| 客户端命中 | **可仅 FX**（表现预览）；结算以服为准 |
| LocalMonster Query | **关闭 CanQuery**（避免误入客户端 Hitbox） |
| 弹道撞怪 | **是**——与 L3 同一套服逻辑体相交 API |
| 配置与资产 | **Enemy 表已同步**（`enemyConf`；样例 **5011001** / `Ai=Ranger`）。模型目录：**`ReplicatedStorage/Assets/ModelRes/Enemy`**；克隆：`ResourceUtil.GetModel("Enemy", enemyConf.model)`。现表无 bbox 列 → 首包 **Extents 兜底** |
| 通信 | **复用**现有网关 / Net 约定 |
| Phase | 首包即加 **`CombatWorld.Phase.EnemySim = 15`** |
| 排期 | 弹道手测与 L1 **可并行** |
| 死亡表现 | 首包 **直接 Destroy**（不迁 `MonsterDeathFx`） |
| 调度改造 | 每实体 Heartbeat → **`EnemySim` 批处理** |
| 客户端表现 | `LocalMonster` **仅表现**（插值/可见/可选 FX）；不参与权威 Hit |

##### A.1 Hit 模型（已锁定）

```text
服 LogicalStore（纯数据逻辑体，无伤害用 Part）
  · id / cframe / bboxSize / alive / …
  · bboxSize = 配表字段；缺省则创建时 GetExtentsSize 兜底

服 Hitbox（权威，与客户端 Hitbox 对齐）
  · collectLogicalOverlapHits(cf, size, shape) → OBB/球相交
  · → SystemEnemy.Hit + LogicalHitValidate
  · 弹道撞敌复用同一 API

客户端
  · LocalMonster：插值表现；CanQuery=false
  · 可仅播命中 FX；不得 GetPartsInPart 权威结算逻辑怪
```

对照：~~「Hit=LocalMonster」已作废~~。

##### B. 进 / 不进（对照 RP18）

| 进本仓（本阶段） | 路径参照（RP18） | 落点 |
|------------------|------------------|------|
| 逻辑怪创建 / 注册 / Hit 门面 | `SystemEnemy.CreateLogicalEnemy` / `Hit` / `Despawn*` | 服 `SystemEnemy` 加厚 |
| 内存权威表 + **bboxSize** | `EnemyLogicalStore` | 配表写入；Extents 兜底；随位姿更新 cframe |
| **逻辑体积相交查询** | `SystemEnemy.collectLogicalOverlapHits` | 服 Hitbox + 弹道共用；L3 |
| Hit 粗检 | `LogicalHitValidate` | 门面 `Hit` 内 |
| 定向同步 SPAWN/TRANSFORM/STATE/DEATH | `EnemyLogicalSync`（~~10Hz~~ **现行 20Hz**） | **复用**现有 Net |
| 装配（无 Script） | `LogicalEnemyBootstrap` / `NPCAssembly` | `EnemySim.add`，禁 `connectHeartbeat` |
| 状态机 + **Ranger** | Ranger Brain/States | `EnemySim.step` |
| 逻辑位移 | `LogicEntityMotion`（精简） | 仿真层 |
| 受击扣血 | `NPCCombat` / `NPCDamageCompliance`（可先薄） | 门面 `Hit` |
| 客户端 LocalMonster | `SystemLogicalEnemy` | 仅表现；**CanQuery=false**；可选命中 FX |
| 类型工具（按需） | `EnemyLogicalTypes` 等 | ToolSystem |

| 明确不进（本阶段） | 原因 |
|--------------------|------|
| 用 `LocalMonster` 做伤害 GetPartsInPart | **已否决** |
| 服侧隐形 Part 当伤害体积 | **已否决**（I1=纯数据） |
| Summon / 关卡 / 物理怪 Script / 非 Ranger | 已锁定 |
| `AiHost.connectHeartbeat` | 改 World |
| DeathFx / 血条等 | 首包 Destroy |

##### C. 目标架构（仅逻辑怪 · Ranger · 服端纯数据 Hit）

```text
CreateLogicalEnemy（bbox：配表 → Extents 兜底）
        ▼
SystemEnemy + LogicalStore（纯数据 OBB）
  · collectLogicalOverlapHits / Hit / Validate
        │ EnemySim.add
        ▼
CombatWorld.Phase.EnemySim = 15
  · Ranger AI + 位移 → Store.cframe
  · ~~10Hz~~ **20Hz** Sync → 客户端
        ▼
服 Hitbox / 弹道（权威，双端对齐）
  · overlap(逻辑体) → Hit → 扣血
        ▼
客户端 SystemLogicalEnemy
  · LocalMonster 插值；CanQuery=false
  · 可仅 FX；死亡 Destroy
```

##### D. Phase

| 决议 | 做法 |
|------|------|
| **已锁定** | `CombatWorld.Phase.EnemySim = 15` |

##### E. 里程碑（本阶段）

| 里程碑 | 交付 | 状态 |
|--------|------|------|
| **L0** | 范围 + Hit/§I 全部拍板写入 A | **已完成** |
| **L1** | `LogicalStore`（cframe+bbox）+ Create/Despawn；`Phase.EnemySim` + `EnemySim` | **已完成** |
| **L2** | Sync + `SystemLogicalEnemy`（CanQuery=false）；~~10Hz~~ **现行 20Hz**；从 `ModelRes/Enemy` 克隆 | **已完成**（频率事后改为 20Hz） |
| **L3** | 双端 Hitbox 对齐：服 `collectLogicalOverlapHits`；客仅 FX；弹道同 API；Hit+Validate；Destroy | **已完成** |
| **L4** | **Ranger** AI 批处理；连接数不随 N 涨 | **已完成** |
| **L5** | 文档 + 作者禁令 | **已完成** |

##### F. 验收

- [x] 服 `collectLogicalOverlapHits` + Hitbox 补查 + HitResolver 逻辑 id 结算（代码）
- [x] 弹道撞敌走同一逻辑体 API（代码）
- [x] Ranger 进 EnemySim 批处理（Idle/Wandering/Chasing；无每怪 Heartbeat）（代码）
- [x] 手测：Spawn → LocalMonster 可见（Query 关）→ 巡逻/追击 → **仅服逻辑体**可击杀 → Destroy（陨石术）
- [x] 手测：客户端无 Query 时服侧仍命中；客侧最多 FX
- [x] 无每实例 Heartbeat；Phase 15；~~10Hz~~ **现行 20Hz**；复用网关；无 Summon/副本
- [x] I7=A：服射线贴地 + 挡墙手测（落地/坡/墙）
- [x] L5：技能系统技术说明 §9.1 + 作者规范 §5/§5.2 禁令补全

##### G. 明确不做（重申）

- Summon、关卡、物理怪 Script、非 Ranger、DeathFx  
- LocalMonster / 隐形 Part 权威 Hit；插值进 CombatWorld；Matter/JECS  

##### H. 决议记录（首轮）

| # | 问题 | 决议 |
|---|------|------|
| 1 | 首包 AI | **Ranger** |
| 2 | 同步频率 | L2 拍 **10Hz**；**现行 20Hz**（卡顿修复后改；见 `EnemyLogicalSync`） |
| 3 | Hit | **服端逻辑体**（作废 LocalMonster 检测） |
| 4 | 配置与资产 | **已同步** 表 + 路径 `ReplicatedStorage/Assets/ModelRes/Enemy`；`GetModel("Enemy", model)` |
| 5 | 通信 | **复用**现有网关 |
| 6 | Phase | **`EnemySim=15`** |
| 7 | 与弹道回归 | **可并行** |
| 8 | 死亡表现 | **Destroy** |

##### I. 决议记录（Hit 修订轮 · 已拍板）

| # | 问题 | 决议 |
|---|------|------|
| I1 | 逻辑体表示 | **纯数据 OBB** |
| I2 | bboxSize | **配表 + Extents 兜底**（现表无 bbox 列 → **先 Extents**；后补配表列） |
| I3 | Hitbox | **必须对齐双端**（服权威逻辑体相交） |
| I4 | 客户端预览 | **可仅 FX** |
| I5 | LocalMonster Query | **关** |
| I6 | 弹道撞怪 | **是**（同一 API） |
| I7 | 重力 / 环境碰撞 | **A 已落地**：服射线贴地 + 水平挡墙（`LogicEntityMotion`）；客仍 PivotTo；伤害体积纯数据 OBB |


##### J. 会话入口（L3 · 已完成 · 2026-08-12）

> **历史会话**：L3 已合入。勿再按下方「开工 L3」开场白新建工作。TRANSFORM 频率以文首现行 **20Hz** 为准。

**一句话：** L0–L2 已完成；开 **L3：服端纯数据 OBB 命中**（禁 LocalMonster 检测）。

**范围锁定（勿回潮）**
- 做：逻辑怪（服 Store + 客 LocalMonster 表现）+ 首包 AI 后续 L4=**Ranger**
- 不做：Summon、RP18 关卡/副本、物理怪 Script、DeathFx、Matter/JECS

**已落地代码（已合入；J 当时「工作区脏」已过时）**

| 模块 | 路径 |
|------|------|
| Phase.EnemySim=15 | `ToolSystem/CombatWorld.luau` |
| Store | `ToolSystem/EnemyLogicalStore.luau` |
| 批处理 | `ToolSystem/EnemySim.luau`（step 末 `EnemyLogicalSync.tick`） |
| Sync ~~10Hz~~ **现行 20Hz** | `ToolSystem/EnemyLogicalSync.luau` |
| Types | `ToolSystem/EnemyLogicalTypes.luau` |
| 门面 | `ServerSideCode/System/SystemEnemy.luau`（Create/Despawn/逻辑 Hit by id） |
| 客表现 | `ClientSideCode/SystemModule/SystemLogicalEnemy.luau`（**CanQuery=false**） |
| Manager | `StarterPlayerScripts/Manager/EnemyManager.client.luau` |
| NetMsg | `ENEMY_LOGICAL_SPAWN/TRANSFORM/DEATH` |
| Init | `UpdateManager` → `SystemEnemy.Init()` |

**资产：** `config/Enemy.xlsx` → `enemyConf`；样例 **5011001**（`Ai=Ranger`，model≈近战哥布林）；模型 `ReplicatedStorage/Assets/ModelRes/Enemy`；`GetModel("Enemy", model)`。现表**无 bbox 列** → Extents 兜底。

**冒烟（已具备）**
```lua
local id = Utils.SystemEnemy.CreateLogicalEnemy(5011001, CFrame.new(0, 5, 0))
-- 客：workspace.LocalMonster 可见
Utils.SystemEnemy.DespawnById(id)
```

**L3 目标**
1. `SystemEnemy.collectLogicalOverlapHits(cf, size, shape, alreadyHit?)`（对照 RP18 同名；扫 Store OBB）
2. 服 Hitbox 路径补查逻辑体；**双端 Hitbox 对齐**（客可仅 FX，结算以服为准）
3. 弹道撞敌复用同一 API（I6）
4. 可选薄 `LogicalHitValidate`（距离/combatReady/白名单）
5. 验收：关 LocalMonster Query 仍能服侧击杀；死亡 Destroy

**参照：** `D:\Git\rp18` → `SystemEnemy.collectLogicalOverlapHits`、`Hitbox.luau` 服侧补查分支、`LogicalHitValidate.luau`。

**新会话建议开场白：**  
「按 `docs/战斗仿真ECS迁移方案.md` §4.3.2 J 开工 L3：实现 collectLogicalOverlapHits 并接入服 Hitbox/弹道。」

---


##### K. 会话入口（L4 · 已完成 · 2026-08-12）

**一句话：** L0–L3 已完成；开 **L4：Ranger AI 批处理**（Tick 只走 EnemySim，禁每实例 Heartbeat）。

**L3 已落地（相对 J）**

| 模块 | 路径 / 要点 |
|------|-------------|
| OBB 查询 | `SystemEnemy.collectLogicalOverlapHits` → `{ [id]: Position }` |
| Validate | `ToolSystem/LogicalHitValidate`（白名单空=全开 + combatReady + 距离） |
| Hitbox 服补查 | `Hitbox.check`：Player/Mirror + IsServer → 合并 number 键 |
| 结算 | `HitResolver.applyLogicalEnemyHit`；`applyHit` 遇 number 分流 |
| 弹道 | 同 Hitbox.check API（`SkillDemoProjectile.onProjectileHitServer` 认 id/Vector3） |
| 客 stub | `ToolSystem/SystemEnemy.collectLogicalOverlapHits` → `{}` |

**L4 目标**
1. Ranger Brain/States 装配进 `EnemySim.step`（对照 RP18 Ranger，无物理 Script）
2. 位移写 `EnemyLogicalStore.setCFrame`；连接数不随 N 涨
3. 验收：CreateLogicalEnemy(5011001) → Ranger 行为 + 仍可被服 Hit 击杀

**范围锁定（勿回潮）**：无 Summon / 无关卡 / 无物理怪 Script / 无 DeathFx。

**新会话建议开场白：**
「按 `docs/战斗仿真ECS迁移方案.md` §4.3.2 K 开工 L4：Ranger AI 批处理进 EnemySim。」


##### L. 会话入口（L5 文档 · 已完成 · 2026-08-12）

**一句话：** L0–L4 + I7=A + 陨石击杀手测已通；**L5 文档与作者禁令已收口**。

**L4 已落地（相对 K）**

| 模块 | 路径 / 要点 |
|------|-------------|
| LogicEntityMotion | `ToolSystem/LogicEntityMotion.luau`：goal 积分 → 挡墙/贴地 → `Store.setCFrame` |
| RangerAi | `ToolSystem/RangerAi.luau`：Idle ↔ Wandering ↔ Chasing（风筝环带） |
| EnemySim.step | `RangerAi.step` + `integrate` + Sync.tick；无每怪 Heartbeat |
| 装配 | `CreateLogicalEnemy`：`Ai=Ranger` → `RangerAi.assemble`；出生预贴地 |
| 首包不做 | BandWander / Attacking 技能 / SimplePath / 物理 Script（寻路 2026-08-28 起改走 [`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md)） |

**手测（已通过）**
```lua
local id = Utils.SystemEnemy.CreateLogicalEnemy(5011001, CFrame.new(0, 5, 0))
-- 客：LocalMonster 巡逻/追击可见；陨石术服 OBB 可击杀 → Destroy
```

**L5 已交付**
1. [`技能系统技术说明.md`](技能系统技术说明.md) §9.1 逻辑怪桥接 + 架构/索引补全
2. [`技能模块作者规范.md`](技能模块作者规范.md) §5 / §5.2：禁每怪 Heartbeat；禁 LocalMonster 权威 Hit
3. 本文验收清单勾完；进度条收口
4. 不迁 PartIcles（§4.3.3 **已拍：永不进 CombatWorld**）

**新会话建议开场白：**
「逻辑怪已收口；PartIcles 不迁 CombatWorld。按需开下一主题。」


##### M. 新会话入口（重力/碰撞 · 已拍 A 并落地 · 2026-08-12）

**一句话：** L1–L4 与客表现动作已通；**I7=A 已落地**；**L5 已收口**；PartIcles **不迁** CombatWorld。

**本会话追加落地（相对 L4）**
| 项 | 要点 |
|----|------|
| 客跟随 | `SystemLogicalEnemy`：`PivotTo` 插值；**仅 HRP Anchored**，肢体 Weld/Motor6D |
| 动作 | TRANSFORM `moveState` → idle/walk/run；DEATH 播死后 Destroy |
| 动作表 | `Animation.luau` 仅留 5011001 六条（待机/走/跑/受击/死亡/眩晕） |
| 临时刷怪 | `LogicalEnemySpawnTest.server.luau` → `workspace["刷怪测试"]`，死后补刷 |
| Hit L3 | 服 OBB `collectLogicalOverlapHits`；LocalMonster 不进权威 Query |
| **I7=A** | `LogicEntityMotion`：Ground 下打贴地 + 三射线挡墙；`CreateLogicalEnemy` 出生预贴地 |

**开放议题 I7：逻辑体重力 / 环境碰撞 — 已拍板 A 并落地**

| 方案 | 做法 | 优点 | 风险/成本 |
|------|------|------|-----------|
| **A. 服射线贴地 + 挡墙**（**已选**） | `LogicEntityMotion.integrate`：下打 Ray 贴地；水平步三射线挡墙缩短 step；Create 预贴地 | 仍纯数据权威；无 Invisible Part；与 I1 一致 | 斜坡/台阶需手测调参 |
| B. 服隐形碰撞代理 | 每怪一 Anchored=false 的碰撞壳，物理落地后再写回 Store | 借引擎物理 | **否决**（易撞 I1） |
| C. 客物理、服纠正 | 客 LocalMonster 受重力/碰撞，服定期纠偏 | 手感像实体 | **否决**（权威分裂） |
| D. 维持无重力 | 刷怪点保证贴地；AI 不改 Y | 零成本 | **否决**（悬空/穿模） |

**决议：A** — 服 `LogicEntityMotion` 加贴地 + 水平挡墙；客仍 PivotTo 跟随；伤害体积继续纯数据 OBB。

**不要回潮：** Summon / 关卡 / 物理怪 Script / DeathFx / Matter。

**新会话建议开场白：**
「按 `docs/战斗仿真ECS迁移方案.md` §4.5 开工三期：C0 基线 → C1 Ranger Attacking。」

#### 4.3.3 P1 — PartIcles（**已拍：不迁入 CombatWorld** · 2026-08-12）

##### 决议

| # | 问题 | 决议 |
|---|------|------|
| P1 | 是否把 ActiveEmits 步进挂到 `CombatWorld.register` | **否** |
| P2 | PartIcles 与战斗/技能门控关系 | **正交**：关 `战斗系统.启用` / `技能系统.启用` 不得停粒子时钟 |
| P3 | 时钟归属 | **维持** `Engine.EnsureActivated` 独立 Heartbeat（+ LinkService 既有第二路） |
| P4 | 若将来要控帧预算 | 另开 **Presentation / Fx 调度器**（可选），**不**并入 CombatWorld |

**理由：** PartIcles 是中立 FX 引擎（对象池 + Emit），技能只是调用方之一；CombatWorld 是战斗仿真域。绑在一起会在关战斗/关技能时误伤全局粒子。

##### 现状（保持）

| 项 | 事实 |
|----|------|
| 主循环 | `PartIcles/Engine.luau`：`EnsureActivated` → **独立** `RunService.Heartbeat` 扫 `ActiveEmits` |
| 其它时钟 | `LinkService` / `Lifecycle`：客 PreRender / 服 Heartbeat（白名单保留） |
| 与 World | **零** `CombatWorld` 引用；**刻意不挂** |

##### 做什么 / 不做什么

| **做** | **不做** |
|--------|----------|
| 文档写明：PartIcles ∈ §3.4 永不进；与门控正交 | 挂 `CombatWorld.register` |
| 技能作者继续经 `Utils.PartIcles` Emit/Stop | 推倒对象池、重写 Emit API |
| 可选：以后另立 Presentation 调度（与战斗解耦） | 把粒子做成通用 ECS 组件；强制并入 SmartBone |

##### 验收（文档决议）

- [x] 总方案否决「挂 CombatWorld」；列入 §3.4 永不进
- [x] CombatWorld 头注释与本文一致：PartIcles 勿迁入
- [x] 关战斗/技能门控不影响粒子独立 Activate 路径（设计约束；代码保持现状）

**新会话建议开场白：**
「PartIcles 已拍不迁 CombatWorld（§4.3.3）。有帧预算诉求时另开 Presentation 调度，勿绑战斗 World。」

---

#### 4.3.4 P2 — CharacterMotion（按需 · 暂缓）

| 现状 | 结论 |
|------|------|
| 调用链均为玩家 Character / 技能位移（如 DashStyleRoll）；电机自有 `PreSimulation`；服包络另有 Heartbeat | **与 NPC/召唤物未共用** |
| 条件：仅玩家 3C | **不必**强迁 |
| 条件：NPC / 召唤物与玩家共用 Motion 包络 | 再挂 `Motion` system 到 World，并对齐物理步相位 |

---

#### 4.3.5 可选并行 — 组件化深化

在**不换库**前提下，把「id → tickFn」升级为更易查询的数据布局（仍属自研 World）：

| 步 | 内容 | 何时做 |
|----|------|--------|
| 1 | 实体 id + 稀疏组件表（Transform / Lifetime / Owner） | 弹道/敌召数据重复拷贝明显时 |
| 2 | 按组件掩码的批处理 API（`forEachWith`） | 出现多处手写双层循环时 |
| 3 | 调试：World 内入口计数 / phase 耗时 | 性能回归需要时 |

**明确不做（直到选型分叉）：** 引入 Matter/JECS 依赖、重写 BaseSkill OOP Runtime 为纯 archetype。

---

#### 4.3.6 选型分叉（触发后再开）

**触发条件（示例）：** 同屏需稳定维护大量敌召 + 弹道 + 状态，且自研组合查询/调试成本明显高于换库。

| 倾向 | 选 |
|------|-----|
| 工程协作 / Debugger | Matter |
| 极致吞吐 / 海量实体 | JECS |

边界表（§3）不变；只换存储与查询实现。

---

### 4.4 二期收口检查清单（存档）

- [x] §H + §I 全部拍板；**L0 收口**
- [x] **Enemy 表已同步**（`enemyConf`；样例 5011001 / Ranger）
- [x] 模型路径锁定：`ReplicatedStorage/Assets/ModelRes/Enemy`（`GetModel("Enemy", model)`）
- [x] **L1 完成**：LogicalStore + Phase.EnemySim=15 + EnemySim + CreateLogicalEnemy/DespawnById
- [x] **L2 完成**：EnemyLogicalSync（SPAWN/TRANSFORM/DEATH）+ SystemLogicalEnemy（CanQuery=false）+ EnemyManager
- [x] **L3 完成**：服 `collectLogicalOverlapHits`；Hitbox 服补查；弹道同 API；LogicalHitValidate；HitResolver 逻辑 id 结算
- [x] **L4 完成**：RangerAi + LogicEntityMotion 进 EnemySim；CreateLogicalEnemy 装配 Ranger
- [x] **I7=A 完成**：服贴地+挡墙；出生预贴地；手测落地/坡/墙
- [x] **L5 完成**：技能技术说明 §9.1 + 作者规范禁令；本文验收勾完
- [x] 技能行为回归（陨石术击杀逻辑怪手测通过）
- [x] CombatWorld.Init 双端；Projectile 已落地；Ranger / 服 OBB Hit / 无 Summon 关卡
- [x] **§4.3.3**：PartIcles **不迁入** CombatWorld（中立 FX；与门控正交）

---

### 4.5 三期 — 战斗闭环深化（当前主路径 · 2026-08-17）

> **一句话：** 调度与逻辑怪「能跑、能被打」已完成；三期**怪物侧**（碰撞组 + 受击 + **击退** + 浮空代码）已接；下一刀是同一 `CombatWorld` 边界内的「怪能打人、数据可配、Buff 可长」；**不开** Summon / 关卡 / 物理怪 Script / Matter。

#### 4.5.0 为何是这一步（而非换库 / Summon）

| 候选 | 结论 | 理由 |
|------|------|------|
| **LocalMonster 碰撞组 `Enemy`** | **已完成（C0a）** | 克隆全 Part `CollisionGroup="Enemy"`；仍 `CanQuery=false` |
| **怪物受击表现（对照 RP18）** | **已完成（C0b）** | `SkillHitPresentation` + `NPCCosmeticHit`；`realDmg>0` |
| **逻辑怪地面击退** | **已完成** | `LogicalDisplace` + Profile；陨石 `PhysicsEffectName=中等力度受击物理效果` |
| **浮空 Launch/Juggle** | **A1/A2 代码已接** | EnemySim 优先于 Displace；A3 客 air_* Anim **未播** |
| **敌方攻击闭环（Attacking）** | **做（P0）** | Ranger 仅 Idle/Wander/Chase；战斗环未闭合；**排在怪物侧补完之后** |
| **bbox 配表 + 命中硬化** | **做（P0）** | I2 仍 Extents 兜底；量产怪体积不准会误伤/漏伤 |
| **StatusEffect 堆叠 / DoT** | **做（P1）** | 一期 B 仅 RuntimeWindow；时钟已在 World，补数据模型成本低 |
| **追踪弹 Tracking** | **按需（P2）** | 模板占位；有自瞄玩法需求再开 |
| **薄组件表 / World 诊断** | **按触发（P2）** | 先量后改；避免过早 archetype |
| CharacterMotion 进 World | **暂缓** | 仍仅玩家 3C；逻辑怪走 `LogicEntityMotion` |
| Summon / 关卡 / 物理怪 Script | **不做** | 二期边界延续；产品未要时禁止回潮 |
| PartIcles → CombatWorld | **永不** | §4.3.3 |
| Matter / JECS | **不换** | 无同屏实体量与维护成本数据；见 §4.3.6 |

#### 4.5.1 架构目标（相对二期末）

```text
二期末（已有 · 当时快照）
  EnemySim: Ranger(Idle/Wander/Chase) + Motion + Sync（当时 10Hz）
  Hit: 玩家/技能 → 服 OBB → 扣血/Destroy（无受击表现）
  LocalMonster: 插值；CanQuery=false；CollisionGroup 未对齐

三期前段（已落地 · 怪物侧）
  LocalMonster 全 Part：CollisionGroup = "Enemy"（仍 CanQuery=false；权威 Hit 仍服 OBB）
  Hit 后表现：SkillHitPresentation（FX+音效）+ Cosmetic 受击 Anim（animHitName）
  受击运动：LogicalAirborne（优先）→ LogicalDisplace（地面击退）
  Sync：TRANSFORM **20Hz**
        └─ 表现/击退/浮空均不进 StatusEffect Phase；无每怪 Heartbeat

三期末（目标）
  EnemySim: + Attacking（冷却窗 + 对玩家薄攻击桥）
        │
        ├─→ SystemPlrAttr / 既有 Hit 桥（怪打人）
        └─→（可选）经 SkillRuntime 释放「敌技」样板，仍禁每怪 Heartbeat

  数据：enemyConf.bbox* 优先；Extents 仅兜底
  StatusEffect：堆叠规则 + DoT Tick（仍 Phase.StatusEffect）
  可选：ProjectileObjectTracking；稀疏组件表；phase 耗时诊断
```

**Phase 不变**（除非诊断证明需拆分）：

| Phase | 值 | 三期用途 |
|-------|-----|----------|
| Cooldown | 10 | 不变 |
| EnemySim | 15 | + Attacking；仍唯一批处理入口 |
| SkillRuntime | 20 | 可选「敌技」样板挂此 Phase（经既有 Runtime，**不**新建每怪时钟） |
| Hitbox | 30 | 追踪弹若开，仍挂此 Phase |
| StatusEffect | 40 | 堆叠 / DoT |

#### 4.5.2 进 / 桥 / 不进（三期锁定）

| 进 World / 仿真层 | 落点 | 备注 |
|--------------------|------|------|
| Ranger **Attacking** 态 | `RangerAi` + `EnemySim.step` | 冷却、进入/退出条件在 AI；**无**每怪 Connect；**尚未开工**（Ranger 仍 Idle/Wander/Chase） |
| 怪→玩家伤害桥 | `SystemEnemy` 或薄 `LogicalAttackBridge` → `SystemPlrAttr` | 权威在服；可先近战瞬时 Hit，再挂敌技 |
| bbox 配表字段 | `enemyConf` + `SystemEnemy.CreateLogicalEnemy` | **代码可读** `bboxSize`/`BBox`/`bbox`；**表列仍无** → 现行 Extents 兜底 |
| 地面击退 | `LogicalDisplace`（EnemySim） | **已落地**；`PhysicsEffectName` → Profile |
| 浮空 | `LogicalAirborne`（EnemySim，优先于 Displace） | A1/A2 **已接**；不进 StatusEffect |
| SkillBuff 堆叠 / DoT | `SkillBuffUtil`（Phase.StatusEffect） | 不迁 `SystemBUFF` |
| （可选）追踪弹 | `ProjectileObjectTracking` → `Phase.Hitbox` | 与直线弹同禁令 |
| （可选）稀疏组件 | CombatWorld 旁路表或 Store 字段规范化 | 见 §4.5.4 |

| 桥接（不进 World） | 职责 |
|--------------------|------|
| `SystemPlrAttr` | 承伤 / 属性 |
| `SystemSkill` | 玩家槽位；敌技若走技能管线则只 Cast，不持有怪时钟 |
| `SystemLogicalEnemy` | LocalMonster 表现；**克隆时写 `CollisionGroup="Enemy"`**；收 Cosmetic Hit |
| `SkillHitPresentation`（移植 RP18） | 技能命中怪：FX + 音效（含 `InjuredSound`）；服批处理下行 |
| `NPCCosmeticHit`（薄移植） | `animHitName` 受击轨；逻辑怪 FireClient → LocalMonster 播 |
| Managers | 只 Init；不写 Attacking 业务 |

| **明确不做** | 原因 |
|--------------|------|
| SummonSim / 关卡波次 / 物理怪 Script | 产品未要；防范围膨胀 |
| DeathFx 重系统 / 血条 UI 大改 | 表现可后置；首包可继续 Destroy（**受击表现 ≠ DeathFx**） |
| BandWander / 社区 SimplePath 库 | 寻路改走自研 `LogicalPathFollow` + `PathfindingService`，见 [`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md) **M2**；BandWander 仍 **M3** |
| Motion Phase | 玩家 CharacterMotion 未与 NPC 共用 |
| PartIcles / Presentation 并入 CombatWorld | §4.3.3；帧预算另立调度器 |
| 引入 Matter / JECS | §4.3.6 触发前禁止 |
| 用 LocalMonster `CanQuery=true` 做权威 Hit | 仍否决；权威只走服 OBB（§I1） |

#### 4.5.3 里程碑（C0–C5；怪物侧插入 C0a / C0b）

| 里程碑 | 优先级 | 交付 | 成功标准 | 状态 |
|--------|--------|------|----------|------|
| **C0** | P0 | 范围拍板 + 基线：同屏逻辑怪 N、`EnemySim`/`step` 粗耗时、连接数抽查 | 文档写入；有可复测数字 | **待开工** |
| **C0a** | P0 | LocalMonster 全 `BasePart`：**`CollisionGroup = "Enemy"`**（对照 RP18） | 克隆后抽查 Part 组名为 Enemy；**仍** `CanQuery=false` / `CanCollide=false`；服 OBB Hit 不变 | **已完成** |
| **C0b** | P0 | 怪物受击表现：移植/对齐 RP18 `SkillHitPresentation` + 薄 `NPCCosmeticHit` | 陨石/技能打中逻辑怪有 FX+音效+受击 Anim；`realDmg>0`；不进 CombatWorld | **已完成** |
| **C1** | P0 | Ranger **Attacking**：进入条件（进入攻击距 + CD）→ 对玩家薄 Hit → 回 Chasing/Idle | `CreateLogicalEnemy(5011001)` 可对玩家造成伤害；无每怪 Heartbeat | **待开工**（依赖 C0a/C0b 可并行基线，但表现应先可见） |
| **C2** | P0 | `enemyConf` bbox 列（或等价字段）+ Create 优先读表；文档/作者规范补一句 | 配表怪体积与手感对齐；Extents 仅缺省 | **待开工** |
| **C3** | P1 | SkillBuff：**堆叠规则** + **DoT**（仍 StatusEffect Phase） | 同一 WindowKey 可定义叠法；DoT 与技能同一 `step` | **待开工** |
| **C4** | P2 | （按需）`ProjectileObjectTracking` 最小实现 | 追踪弹经 World；作者规范补约定 | **按需** |
| **C5** | P2 | （按触发）薄组件表 / `forEachWith` / phase 耗时诊断 | 满足 §4.5.4 触发条件之一再开 | **按触发** |

##### C0a 设计要点（碰撞组 `Enemy`）

| 项 | 做法 |
|----|------|
| 落点 | 客户端 `SystemLogicalEnemy` 克隆准备（本仓 `_applyPresentationPhysics` / 对等 prepare） |
| 对照 RP18 | `SystemLogicalEnemy._prepareLogicalCloneModel`：`desc.CollisionGroup = "Enemy"` |
| 常量 | `COLLISION_GROUP_ENEMY = "Enemy"`（与 Hitbox `TARGET_GROUPS_BY_OWNER.Player` 键名一致） |
| 与权威 Hit 关系 | **不改变** §I1：伤害体积仍是服 `LogicalStore` OBB；`CanQuery` **保持 false**（避免客 Hitbox 误扫） |
| 为何仍要写组 | 碰撞矩阵 / 射线预设 / 组名约定对齐；后续若开「仅 FX 的 Query」也不会落到 Default |
| 服侧 | 逻辑怪无伤害 Part；若有假人/物理壳注册路径，继续 `VisibleMgr.SetCollideID(..., "Enemy")`（对照 RP18 `SystemEnemy`） |
| 手测 | SPAWN 后 Studio 选中 LocalMonster 任意 Part → CollisionGroup 为 `Enemy`；陨石仍可击杀 |

##### C0b 设计要点（受击表现 · 对照 RP18）

```text
服 Hit / applyLogicalEnemyHit（realDmg > 0）
        │
        ├─→ SkillHitPresentation.beginBatch / accumulateFromCombat / flushBatch
        │     · hitboxConfig.HitPresentationProfile（如「通用受击」）→ FX + 音效
        │     · enemyConf.InjuredSound 叠加怪物受击音（SoundMap）
        │     · 合并 AOE 包下行（对照 RP18 NetMsg.SKILL_HIT_PRESENTATION）
        │
        └─→ NPCCosmeticHit.tryPlayAfterDamage（未进完整 Hurt 硬直时）
              · animHitName（配表，如「人型受击R6-1」）
              · 逻辑怪：白名单 FireClient → 客在 LocalMonster 上播轨
              · CD：cosmeticHitAnimCooldown（防刷屏）

不进 CombatWorld 仿真 Phase；不改扣血/Despawn 权威路径  
~~首包不做 LogicalDisplace~~ **已过时**：击退已落地（见上表 / §4.5.8）  
首包仍不做：完整 Hurt 硬直态、DeathFx（可后置）
```

| 项 | RP18 参照 | 本仓落点 |
|----|-----------|----------|
| FX + 技能音效预设 | `ToolSystem/SkillHitPresentation/*` | 移植薄模块或等价 API；技能 hitbox 已有 `EffectName`/`HitPresentationProfile` 字段处接上 |
| 怪物受击音 | `enemyConf.InjuredSound` + `SkillHitPresentationSoundMap` | 读既有 `InjuredSound`（样例 5011001=`受击-哥布林1`） |
| 受击动画 | `NPCCosmeticHit` + `NPCCosmeticHitPlay`；`animHitName` | 客 `SystemLogicalEnemy` / 薄 Play 助手；走既有 `Animation` 表 |
| 触发点 | `NPCCombat` 扣血后 | `SystemEnemy._hitLogical` / `HitResolver.applyLogicalEnemyHit` 在 `realDmg>0` 后调用 |
| DoT | RP18：`skillDotFixedDamage` 跳过表现 | 本仓 C3 前若无 DoT，可先忽略；有则对齐跳过 |

**决议建议（C0 一并拍板）：**

| # | 问题 | 建议决议 |
|---|------|----------|
| P1 | 碰撞组名 | **固定 `"Enemy"`**（与 Hitbox / RayCast 预设一致） |
| P2 | 受击表现首包范围 | **FX + 音效 + Cosmetic Anim + LogicalDisplace（陨石 PhysicsEffectName）**；闪红 / 完整 Hurt **后置** |
| P3 | 表现时钟 | **事件驱动**（Hit 瞬时 + 短 Anim）；禁止为受击新建每怪 Heartbeat |
| P4 | 缺模块时 | 优先从 `D:\Git\rp18` 移植 `SkillHitPresentation` + `NPCCosmeticHit` 薄链路，按本仓 Utils/Net 约定改 |

##### C1 设计要点（敌方攻击闭环）

```text
RangerAi
  Chasing 且 dist ≤ attackRange 且 cdReady
       ▼
  Attacking（短窗）
       ▼
  LogicalAttackBridge.apply(attackerId, targetPlayer)
       ▼
  SystemPlrAttr（或既有玩家承伤 API）—— 服权威
       ▼
  （可选）客：玩家受击 Anim / FX；不进权威
  （怪物被打表现已由 C0b 覆盖，勿在此重复造轮）

冷却：写在 entity / Store 字段，由 EnemySim 批处理递减 —— 禁止每怪 Heartbeat
```

**决议建议（可在 C0 拍板）：**

| # | 问题 | 建议决议 |
|---|------|----------|
| T1 | 首包攻击形态 | **近战瞬时 Hit**（无完整敌技 Timeline）；验证闭环后再挂 SkillRuntime 敌技样板 |
| T2 | 伤害公式 | **复用** `GetData.GetDmg` / 既有属性桥；不在 RangerAi 内写死魔法数 |
| T3 | 攻击动画 | 客 `moveState` 或 STATE 扩展播 Attack；**不**把 Anim 当权威 |
| T4 | 多目标 | 首包 **单一当前目标**（Chase 锁定的玩家） |
| T5 | 敌技 SkillModule | **后置**；若做，必须 `CombatWorld.register`，经 Group/Base 管线或薄 `EnemySkillCast`，禁私建时钟 |

##### C2 设计要点（bbox）

| 项 | 做法 |
|----|------|
| 配表 | `Enemy.xlsx` 增加 bbox（如 `BboxX/Y/Z` 或 `BboxSize`）；导表进 `enemyConf` |
| Create | 有配表 → 用配表；否则 `GetExtentsSize` 兜底（保持 I2） |
| 手测 | 改表体积后，陨石/弹道命中体感变化符合预期 |

##### C3 设计要点（StatusEffect）

| 项 | 做法 |
|----|------|
| 堆叠 | 明确同 `WindowKey`：Refresh / StackCount / Ignore；写入 API 注释 |
| DoT | StatusEffect Tick 内按窗结算；伤害走 `SystemPlrAttr` / 逻辑怪 `Hit` 桥，**不**直改 Store |
| 非目标 | 不把存档型 `SystemBUFF` 迁入 |

#### 4.5.4 组件化 / 诊断触发条件（沿用并具体化 §4.3.5）

**任一满足再开 C5，否则不做：**

1. 同屏逻辑怪稳定 **≥ 80** 且 `collectLogicalOverlapHits` 或 AI 双层循环成为 CPU 热点；或  
2. 弹道 + 敌 + Buff 出现 **≥ 3 处**手写「扫全表再过滤」重复；或  
3. 性能回归需要 **phase 耗时 / 入口计数** 才能定位。

落地顺序建议：诊断计数 → 稀疏字段规范化（Transform / Lifetime / Owner）→ 必要时空间粗分桶（逻辑怪 OBB 查询）。**仍不引入 Matter/JECS。**

#### 4.5.4b CharacterMotion / Presentation（三期仍旁路）

| 模块 | 三期态度 |
|------|----------|
| `CharacterMotion` | 保持玩家电机；逻辑怪继续 `LogicEntityMotion`；**不**加 `Phase.Motion` |
| Presentation / Fx 调度 | 仅当 PartIcles/FXUtil 帧预算成问题时另立；**永不**并入 CombatWorld |

#### 4.5.5 验收（三期总）

- [ ] C0：基线数字写入本文或附录（N、粗耗时、连接数）
- [x] C0a：LocalMonster 全 Part `CollisionGroup="Enemy"`；`CanQuery=false`；服 OBB 仍可击杀
- [x] C0b：技能命中逻辑怪有 FX+音效+受击 Anim（对照 RP18）；权威路径无回归
- [x] 地面击退：`LogicalDisplace` 经 EnemySim；陨石 `PhysicsEffectName` 走击退档
- [x] 浮空 A1/A2：Launch/Juggle/Fall 进 EnemySim；服下发 `air_*`；**A3 客 Anim 未勾**
- [ ] C1：逻辑怪可对玩家造成伤害；Attacking 仅经 EnemySim；无每怪 Heartbeat
- [ ] C2：配表 bbox 优先；缺省 Extents；手测体积
- [ ] C3：堆叠规则可测；DoT 与技能同一 `step`
- [ ] 回归：陨石/弹道仍可击杀逻辑怪；LocalMonster `CanQuery=false`
- [ ] 边界：无 Summon / 无关卡 / 无物理怪 Script / 无 PartIcles 迁入 / 无 Matter

#### 4.5.6 风险与缓解

| 风险 | 缓解 |
|------|------|
| 为「客侧扫怪」重开 `CanQuery` | CR 拒绝；权威只服 OBB；C0a 只改 CollisionGroup |
| 受击表现做成每怪 Heartbeat | P3：事件驱动；只许短 Anim / FX |
| 受击表现进 CombatWorld | 明确桥接层；与 §4.3.3 Presentation 旁路一致 |
| Attacking 做成每怪 Heartbeat | CR 拒绝；只许 EnemySim 批处理 |
| 怪打人绕过属性系统 | 只走 `SystemPlrAttr`（或统一承伤门面） |
| 过早上完整敌技 Timeline | T1：先瞬时 Hit |
| 过早组件化 / 换库 | 严格 §4.5.4 / §4.3.6 触发 |
| bbox 配表与模型不一致 | 手测清单 + Extents 兜底日志（warn 一次） |

#### 4.5.7 会话入口（三期开工 · 先 C0a/C0b 怪物侧）

**一句话：** 二期 L0–L5 已收口；**C0a/C0b + Displace + 浮空 A1/A2 已落地**；下一开 C0 基线 / C1 Attacking / A3 空中 Anim；**地面移动并行 M0–M2**（[`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md)）。

**范围锁定（勿回潮）**
- ~~先做：C0a 碰撞组；C0b 受击 FX/音效/Anim~~ **已完成**
- 随后：C0 基线；C1 Attacking + 怪→玩家承伤；C2 bbox、C3 Buff
- 并行：逻辑怪地面移动 M0–M2（[`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md)）
- 不做：Summon、关卡、物理怪 Script、DeathFx 大系统、Matter/JECS、PartIcles 进 World、权威改回 LocalMonster Query

**建议开场白：**  
「按 `docs/战斗仿真ECS迁移方案.md` §4.5 开工 C1：Ranger Attacking（近战瞬时 Hit → SystemPlrAttr）。C0a/C0b 已完成。」

---

## 5. 架构约束（与仓库规范对齐）

- **分层：** CombatWorld 属 ToolSystem 仿真层；不绑 Remote、不碰 UI、不写 DataStore。
- **通信：** Client→Server 仍经 `NetWorkManager`；Hit 结算调 `SystemPlrAttr` / `SystemEnemy`。
- **Utils：** `local CombatWorld = Utils.CombatWorld`，禁止业务里 `Utils.CombatWorld.xxx` 长链。
- **Init：** 仅 Manager 调 `CombatWorld.Init()` / `SystemEnemy.Init()` / `SkillBuffUtil.Init()`；System 互不 `Init`。
- **Server/Client：** 分文件或分注册表，避免 `IsServer` 业务分支混写。
- **编码：** 源文件 UTF-8 无 BOM、LF；文件头 Author = `git config user.name`（林奥宇）。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 改时钟导致技能时序漂移 | 样例回归；先迁调度不改逻辑数值 |
| Group 与 Base 双层 Tick 重复 | 只保留一层「实例 Tick」入口，Group 只编排 |
| 表现 Connect 被误删 | RenderStepped 纯 FX 白名单保留 |
| 范围膨胀到 Bag/Save | 严格按 §3.4；CR 拒绝服务型 System ECS 化 |
| 弹道/敌召过早组件化 | 二期先 register Tick；组件表按 §4.3.5 触发 |
| 照搬 RP18 每怪 Heartbeat | 逻辑怪 Tick 只走 `EnemySim`；表现 RenderStepped 白名单 |
| 范围回潮（Summon/关卡/物理怪） | §4.3.2 A 已锁定；CR 拒绝 |
| 无 Enemy 资产/表 | ~~已解除~~：表 + `ModelRes/Enemy` 已锁定 |
| Hit 打不到 LocalMonster | ~~旧风险~~ → 改为服逻辑体；见 §I |
| 客户端 Hitbox 误扫 LocalMonster | L2 关 Query；L3 服 `collectLogicalOverlapHits` |
| 过早引入 Matter/JECS | 用实体量与维护成本触发 §4.3.6 |
| 三期 Attacking 回潮每怪时钟 | 只许 `EnemySim`；CR 拒绝 |
| 怪伤绕过 PlrAttr | 统一承伤桥；RangerAi 不直改玩家存档 |
| C0a 误开 CanQuery | 只改 CollisionGroup；权威仍服 OBB |
| C0b 受击表现进 World / 每怪 Connect | 事件驱动桥接；对照 RP18 批处理下行 |

---

## 7. 文档与规范同步

| 文档 | 变更 | 状态 |
|------|------|------|
| 本文 | 总方案；二期收口；§4.5 三期；**2026-08-18 对照代码修订**（20Hz / Displace / 目录 façade / A3 未播） | **与代码对齐** |
| [`技能模块作者规范.md`](技能模块作者规范.md) | 禁 Heartbeat + 弹道 + 逻辑怪 Hit；**碰撞组/PhysicsEffectName 已补** | **2026-08-18 已同步**；C1/C3 后仍须补敌攻/Buff |
| `SkillModule/_Templates/SkillCommon.luau` | 指向 Projectile 模板 | 已同步 |
| [`技能系统技术说明.md`](技能系统技术说明.md) | CombatWorld + §9.1；**20Hz / 击退 / 浮空 / 受击表现 / 目录 façade** | **2026-08-18 已同步**；C1 攻击桥仍待写 |
| 逻辑怪 / PartIcles | L0–L5；PartIcles 永不进 | **已收口** |

---


#### 4.5.8 怪物浮空控制（对照鬼泣5 · A0 已拍 · A1/A2 代码已接 · 2026-08-18）

> **一句话：** 逻辑怪 Launch / Juggle / Fall / Land；时钟在 `EnemySim`；**不**进 StatusEffect Phase；浮空禁贴地。

##### 决议（按建议拍板）

| # | 议题 | 决议 |
|---|------|------|
| O1 | 浮空是否进 StatusEffect Phase | **否** — 与 Displace 同属 EnemySim 运动域 |
| O2 | 浮空中水平击退 | **短水平 impulse，不取消 Airborne** |
| O3 | 砸地伤害 | A3 可选；首包仅落地不伤 |
| O4 | 玩家 Enemy Step | **后置**；不挡 A1–A2 |

##### 状态机

`Grounded → Launching → Floating → Falling → Grounded`

##### 模块

| 模块 | 路径 | 职责 |
|------|------|------|
| LogicalAirborneProfile | `ToolSystem/LogicalAirborneProfile.luau` | 轻上挑/中击飞/重击飞/空中连段/下砸 |
| LogicalAirborne | `ToolSystem/LogicalAirborne.luau` | applyLaunch/Juggle/Slam、step、锁 AI |
| EnemySim | 步进优先 Airborne → Displace | 浮空跳过贴地 integrate |
| HitResolver | 优先 `LogicalAirborne.tryApplyFromHitbox` | 未处理再 Displace |
| Meteor1 | `PhysicsEffectName = "中等力度受击物理效果"` | **已改回地面击退**；浮空用手测技能挂「中击飞」等档 |

##### 里程碑

| ID | 交付 | 状态 |
|----|------|------|
| **A0** | 决议表 | **已完成** |
| **A1** | Launch+Fall+禁贴地+Sync `moveState=air_*` | **代码已接** |
| **A2** | Juggle 衰减 + 空中默认续浮空 | **随 A1 薄实现**（空中挨地面击退档仍 Juggle） |
| **A3** | 空中/落地 Anim + 可选 Slam 表现 | **待开工**（服已下发 `air_launch/float/fall`；客 `_setLocomotion` **回退 idle**） |
| **A4** | enemyConf.airWeight / launchArmor 配表列 | **代码可读缺省 Medium/0**；`ConfigInstance.enemyConf` **尚无表列** |

##### 明确不做

玩家 Enemy Step、完整 Hurt FSM、布娃娃、客物理权威、每怪 Heartbeat、Summon/物理怪 Script、Matter/JECS。

##### 手测

```lua
-- 刷怪后：陨石走地面击退；浮空需技能 PhysicsEffectName 为「中击飞」等档
local id = Utils.SystemEnemy.CreateLogicalEnemy(5011001, CFrame.new(0, 5, 0))
```

**新会话建议开场白：**  
「陨石走地面击退；浮空用手测技能挂中击飞。下一刀 A3：客机播 `air_*` Anim（现回退 idle）。」

---
## 8. 建议排期

| 周次（示意） | 内容 |
|--------------|------|
| — | 一期 A/B、Projectile、逻辑怪 L0–L5、PartIcles 否决（均已完成） |
| **W0** | ~~C0a/C0b~~ **已完成**；另已接 Displace + 浮空 A1/A2；**C0** 基线仍待写 |
| **W1** | **C1** Attacking + 怪→玩家薄 Hit；**A3** 客 air_* Anim；**并行 M0** 沿墙滑移（见位移寻路计划） |
| **W2** | **C2** bbox 配表；**C3** 堆叠/DoT；A4 表列；**M1** 移动命令层 |
| 其后 | **M2** 路点寻路；C4 追踪弹 / C5 组件·诊断（按触发）；Summon/Motion/换库仍门控 |

---

## 9. 一句话结论

**二期已收口**（逻辑怪可跑可被打；PartIcles 不进 World；Sync **20Hz**）。  
**三期已接：** `Enemy` 碰撞组、受击 FX/Anim、地面击退、浮空代码（A3 客 Anim 未播）。  
**下一主路径：** **Ranger Attacking 闭环 → bbox 硬化 → StatusEffect 深化**；**地面移动**按 [`逻辑怪位移与寻路开发计划.md`](逻辑怪位移与寻路开发计划.md) **M0 滑移 → M1 命令 → M2 寻路** 并行。组件化与换库严格按触发条件，禁止范围回潮。
