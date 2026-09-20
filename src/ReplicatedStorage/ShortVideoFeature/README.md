# ShortVideoFeature

可整包迁移的 Roblox 短视频模块：Experience Configs 片单、左右切集、主槽 +（+1/+2/−1）预载与换槽提升、客户端推荐（未看优先）、全服赞/评、场景 Part + SurfaceGui + 摄像机会话。

可选 API：`ShowTrainPreview` / `HideTrainPreview`（预览传送门 + 帧交接）。本仓库不包含自动训练接入（无 TrainBridge / 训场联调）。

## 目录

| 路径 | 说明 |
|------|------|
| `ReplicatedStorage/ShortVideoFeature` | Shared / Client / Server 逻辑 + `Open`/`Close` |
| `ServerScriptService/ShortVideoFeature/ShortVideo.server.luau` | 服务端入口 |
| `StarterPlayerScripts/ShortVideoFeature/ShortVideo.client.luau` | 客户端入口 |

`default.project.json` 已映射上述 ReplicatedStorage / ServerScriptService 节点。StarterPlayerScripts 随整目录映射。

## Config（Studio → 文件 → 打开配置）

- Key: `ShortVideoList`（JSON）

```json
[
  { "id": "v001", "videoId": 1234567890, "title": "可选标题" }
]
```

## 接入

业务调用 `Open()` / `Close()`。不依赖本仓库 `NetMsg` / `UpdateManager` / `Utils`（有 Utils 时会软依赖 `UIMgr.SetMainUIVisible` 隐藏主界面）。

```lua
local ShortVideo = require(game.ReplicatedStorage.ShortVideoFeature)
ShortVideo.Open({ displayMode = "screen", lockCharacter = false, exitOnCameraDisturb = false })
ShortVideo.Close("manual")
```

`ShowTrainPreview` 需调用方传入 `boardCFrame`；预览模型默认 `ModelRes/视频传送门`（Studio 手放）。未调用则不影响 2D/3D 播放。

## 2D UI 预制体

- 路径：`ReplicatedStorage.Assets.ScreenGui.ShortVideoScreen`（Studio 手放，**不**走 Rojo 映射）
- 运行时优先克隆该预制体；缺失时回退 `BuildUI` 代码创建
- 仓库备份（供导入 Studio）：`src/ReplicatedStorage/Assets/ScreenGui/ShortVideoScreen.rbxmx`
- 详见 `STYLE.md`

## UI 资源配置

编辑 `Shared/Constants.UI`（或 `Open({ ui = {...} })`）：

- 左右切集图 / 尺寸 / 键位：`Nav.ImagePrev` `ImageNext` `KeyPrev` `KeyNext`（手柄另有 `Key*GamepadPS/Xbox/Both`）`KeyTextSize`
- 赞/评/分享图与计数字号：`Action.ImageLike` `CountTextSize` `CountStrokeThickness` `CountTextTransparency`
- 底部进度条：`Progress.Height` `OffsetY` `FillColor`（默认 #26d956）
- Loading 转圈图：`Loading.Image`（可自行提供经典转圈图 asset）
- 边框：`Board.PaddingPx` `StrokeThickness` `StrokeTransparency`

评论排序：抽屉 `Header` 下 `SortHotBtn` / `SortNewestBtn`（`Top` / `Newest`）；服务端双 ODS（赞序 `CommentRank` + 时间序 `CommentTime`）；每条新视频默认 Top；同视频内切换后清空重拉。

详见 `STYLE.md`。