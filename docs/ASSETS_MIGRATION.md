# Assets 资源目录迁移清单

本文档配合 `AssetPaths` / `AssetRegistry` / `AssetAcquire` / `ResourceUtil` 模块，指导将资源从散落路径迁移到统一的 `Assets` 目录。

## 目标目录结构

```text
ReplicatedStorage/
└── Assets/
    ├── ModelRes/
    │   ├── Anime/
    │   ├── Pet/
    │   ├── Effect/
    │   ├── Skill/
    │   └── ...
    ├── UI/
    ├── Hatch/
    ├── Sequence/
    ├── Tips/
    ├── BUFF/
    ├── UIanima/
    ├── LightingConfig/
    └── LightingStates/

ServerStorage/
└── Assets/
    ├── ModelRes/          # 可选：服务端专用模型
    └── UI/                # 如排行榜 RankTemp
        └── 排行榜/
            └── RankTemp
```

迁移期 **旧路径仍可用**（由 `AssetPaths` 自动兜底）：

| 旧路径 | 新路径 |
|--------|--------|
| `ReplicatedStorage.ModelRes` | `ReplicatedStorage.Assets.ModelRes` |
| `ServerStorage.ModelRes` | `ServerStorage.Assets.ModelRes` 或 `ServerStorage.Assets.UI/...` |

---

## 已完成的代码迁移（Phase 0 + Phase 1 部分）

| 文件 | 变更 |
|------|------|
| `ToolBasic/AssetPaths.luau` | **新建** — 路径解析 + 旧路径兼容 |
| `ToolBasic/AssetRegistry.luau` | **新建** — catalog / ModelCategory 配置 |
| `ToolSystem/AssetAcquire.luau` | **新建** — Clone + Restore + 对象池 |
| `ToolSystem/ResourceUtil.luau` | **升级** — 门面 API |
| `ToolSystem/ModelFind.luau` | **已删除**（2026-07-02）— 曾委托 `AssetAcquire` 的兼容层 |
| `ToolBasic/ResRestore.luau` | Skill 目录改走 `AssetPaths.Resolve` |
| `ResMemoryManager.server.luau` | Skill ClearAssert 改走 `AssetPaths` |
| `ToolSystem/FXUtil.luau` | 特效获取改走 `AssetAcquire.GetModel` |
| `SystemModule/SystemRankManager.luau` | 排行榜模板改走 `AssetPaths.Resolve` |
| `UtilsSystem.luau` / `Interface/*` | 注册新模块与类型 |

---

## 推荐 API（新代码）

```lua
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local R = Utils.ResourceUtil
local Cat = Utils.AssetRegistry.ModelCategory

-- 双端模型
local pet = R.GetModel(Cat.Pet, "Cat1")

-- 双端 UI
local bg = R.GetUI("Tips/BGTemp")

-- 仅服务端 UI
local rankTemp = R.GetServerUI("排行榜/RankTemp")

-- 任意 catalog 路径
local hatch = R.Get("Hatch/BoxModel")

-- 只读模板（不 Clone）
local template = R.GetTemplate("ModelRes/Effect/受击效果")

-- 对象池 / 预加载
local inst = R.GetPooledInstance(template)
R.BackToPool(inst)
R.PreloadSkill("Meteor")
```

---

## 待迁移文件清单（Phase 2）

以下文件仍 **直接访问** `ReplicatedStorage.Assets.*`，应逐步改为 `ResourceUtil` / `AssetPaths`：

| 优先级 | 文件 | 现状 | 建议改法 |
|--------|------|------|----------|
| P1 | `ToolSystem/HatchEffect/init.luau` | `ReplicatedStorage.Assets.Hatch` | `R.Get("Hatch/...")` 或 `AssetPaths.GetCatalog("Hatch")` |
| P1 | `ToolSystem/NewTipsModule.luau` | `ReplicatedStorage.Assets.Tips` | `R.GetUI("Tips/...")` + 池模板用 `GetTemplate` |
| P1 | `ToolSystem/SequenceManager.luau` | `ReplicatedStorage.Assets.Sequence` | `AssetPaths.GetCatalog("Sequence")` |
| P1 | `ToolSystem/UIanima.luau` | `ReplicatedStorage.Assets.UIanima` | `AssetPaths.GetCatalog("UIanima")` |
| P1 | `ToolSystem/GradientsMgr/init.luau` | `Assets.Gridient` / `Assets.RarityGridient` | 补充 `AssetRegistry.Catalog` 后 `GetCatalog` |
| P2 | `Manager/LightingManager/init.client.luau` | `Assets.LightingConfig` | `AssetPaths.GetCatalog("LightingConfig")` |
| P2 | `Manager/LightingManager/LightingCustomState.luau` | `Assets.LightingStates` | `R.GetTemplate("LightingStates/...")` |
| P2 | `ClientScript/BuffUpdate.client.luau` | `Assets.BUFF` | `AssetPaths.GetCatalog("BUFF")` |
| P2 | `ToolSystem/HatchEffect/init.luau` | `Assets.UIGradient` | `AssetRegistry` 增加 UIGradient catalog |

### 搜索命令（排查遗漏）

```bash
rg "ReplicatedStorage\.(Assets|ModelRes)|ServerStorage\.(Assets|ModelRes)" src/
rg "game\.ReplicatedStorage\.Assets" src/
```

---

## Studio / Rojo 资源迁移步骤

### 1. 在 Studio 中移动 Instance

1. 在 `ReplicatedStorage` 下创建 `Assets` Folder（若不存在）
2. 将 `ModelRes` 拖入 `Assets/ModelRes`
3. 确认已有 `Assets/Hatch`、`Assets/Tips` 等子目录结构正确
4. 在 `ServerStorage` 下创建 `Assets`，将 `ModelRes/排行榜` 等迁入 `Assets/UI/排行榜`（推荐）或 `Assets/ModelRes/排行榜`

### 2. 更新 Rojo 映射（可选）

在 `default.project.json` 增加：

```json
"ReplicatedStorage": {
  "Assets": {
    "$path": "assets/ReplicatedStorage/Assets"
  },
  "ClientSideCode": {
    "$path": "src/ReplicatedStorage/ClientSideCode"
  }
},
"ServerStorage": {
  "Assets": {
    "$path": "assets/ServerStorage/Assets"
  },
  "ServerSideCode": {
    "$path": "src/ServerStorage/ServerSideCode"
  }
}
```

### 3. 验证

- [ ] 客户端：HatchEffect / UIMgr 模型正常显示
- [ ] 客户端：FXUtil 受击特效正常
- [ ] 服务端：ResMemoryManager 启动无报错，Skill 贴图延迟加载正常
- [ ] 服务端：排行榜 RankTemp 能正确 Resolve
- [ ] 旧路径 `RS.ModelRes` 移除后，仅 `RS.Assets.ModelRes` 仍可运行

---

## Phase 3 清理（旧路径移除后）

1. 在 `AssetPaths.luau` 中删除 `LEGACY_ROOT_CATALOGS` 及 `_findLegacyCatalogUnder`
2. ~~删除 `@deprecated` 的 `ModelFind` 模块~~ **已完成**（2026-07-02，`58d1ead`）
3. 删除 `ResourceUtil.GetModelClone` 兼容 API（`GetModelClone` 已不在仓内）
4. 全项目 grep 确认无硬编码路径

---

## 模块职责速查

| 模块 | 何时使用 |
|------|----------|
| `AssetPaths` | 仅需定位 Folder/Instance，不 Clone |
| `AssetRegistry` | 查 catalog 名、ModelCategory、拼路径 |
| `AssetAcquire` | Clone + Restore + 池化 |
| `ResourceUtil` | **业务代码首选门面**（含 `ModelType` 再导出） |

---

## 常见问题

**Q: 客户端能否访问 ServerStorage.Assets？**  
A: 不能。仅服务端脚本使用 `Scope.Server` 或 `ResourceUtil.GetServerUI`。

**Q: Auto 作用域如何工作？**  
A: 服务端优先 `ServerStorage.Assets`，找不到再回退 `ReplicatedStorage.Assets`；客户端只用后者。

**Q: 何时调用 `AssetPaths.ClearCache()`？**  
A: Studio 热替换 Assets 子目录后可选调用；正式服一般不需要。
