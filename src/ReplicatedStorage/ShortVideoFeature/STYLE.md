# UI 样式说明（U1）

## 色板

| 用途 | RGB / Hex |
|------|-----------|
| 主底 | 10,10,10 / #0A0A0A |
| 抽屉 | 22,22,22 / #161616 |
| 主文字 | 245,245,245 / #F5F5F5 |
| 次文字 | 163,163,163 / #A3A3A3 |
| 强调 | 255,45,85 / #FF2D55 |
| 分割 | 42,42,42 / #2A2A2A |
| 进度填充 | 38,217,86 / #26D956 |

## 结构

- 世界 Part 主底板（`Material=Neon` 白，不加 Light）+ SurfaceGui：`Content` 内缩留白露白边
- **左右切集**：主底板外两侧独立 Part + SurfaceGui（不遮挡视频画面）；按钮叠加 **Q / E** 键位字，键盘同键切集
- 右侧动作栏纵向：点赞 / 评论 / 分享（分享 = `SocialService:PromptGameInvite`）
- 底部 **ProgressBar**：白轨 + 绿色填充，跟 `VideoFrame.TimePosition / TimeLength`
- 半高 `CommentDrawer`（行池 + 输入发送；`Header` 内 `SortHotBtn` / `SortNewestBtn`：`Top` / `Newest`）
- 视频未 `IsLoaded` 时显示 `LoadingOverlay` 转圈

控件名见 `Client/BuildUI.luau`。

## 2D 预制体（推荐改样式方式）

- 源路径：`ReplicatedStorage.Assets.ScreenGui.ShortVideoScreen`（Studio 手放，不走 Rojo 映射）
- 运行时：`SceneBoard.CreateScreen` 优先克隆上述预制体；缺失则回退 `BuildUI` 代码创建
- 评论行：以 **`List.RowTemplate`** 为正确样式源（运行时提升为 drawer 正式模板）；含 `AvatarBg` / `TimeLabel` / `LikeIcon`；`LikeCount` 挂在行上
- 评论正文：`BodyLabel` **全程 TextScaled + RichText**；≤5 行换行扩高，超限锁高（框内整体缩放）；**不裁切**；`NameLabel`/`TimeLabel`/头像/赞区框尺寸不随正文变
- 单行稿高：`List.AbsoluteSize.Y * Constants.COMMENT_ROW_HEIGHT_SCALE`（默认 0.2）；勿给行加回 `UIAspectRatioConstraint`
- `TimeLabel`：相对时间（`just now` / `Nm ago` / `Nh ago` / `Nd ago` …），数据字段 `createdAt`
- 评论排序：`CommentDrawer.Header` → `SortHotBtn`（Top）/ `SortNewestBtn`（Newest）；缺省时 `CommentDrawer` 运行时补建
- CloseBtn 可越出 Phone（Position.X>1），属故意设计
- 改样式：直接在 Studio 改 `Assets.ScreenGui.ShortVideoScreen`；**不要改逻辑已绑定的节点名**

## 可配置资源（`Shared/Constants.UI`）

| 字段 | 说明 |
|------|------|
| `Nav.ImagePrev` / `ImageNext` | 左右切集图 |
| `Nav.BtnSize` / `PartSize` / `GapStuds` | 切集像素尺寸、侧板 Stud 尺寸、与底板间隙 |
| `Nav.KeyPrev` / `KeyNext` / `KeyTextSize` | 键位字（默认 Q/E，字号 42） |
| `TopBar.ImageClose` | 关闭按钮图 |
| `Action.ImageLike` / `ImageLiked` | 未赞 / 已赞图 |
| `Action.ImageComment` / `ImageShare` | 评论 / 分享图 |
| `Action.BtnSize` / `Spacing` / `MarginRight` | 动作栏尺寸与间距 |
| `Action.CountTextSize` / `CountStrokeThickness` / `CountTextTransparency` | 计数样式（默认 28 / 描 2 / 透 0.5） |
| `Progress.Height` / `OffsetY` / `FillColor` | 进度条高 12、底边 0、色 #26d956 |
| `Loading.Image` / `Size` / `SpinDegPerSec` | 加载转圈图与转速；无图时用圆环占位 |
| `CommentLike.ImageLike` / `ImageLiked` | 评论行未赞 / 已赞图 |
| `Pause.Image` / `Size` | 暂停图标（默认 130x130）；点击视频区切换 |
| `Send.Image` | 评论发送按钮图标（文字清空） |
| `Board.PaddingPx` | Content 内缩像素，露出 Neon 边框 |
| `Board.NeonColor` | 主底板 Neon 颜色（默认白） |
| `Board.StrokeThickness` / `StrokeColor` / `StrokeTransparency` | Content 内侧白描边（默认实线 2） |

也可在 `Open({ ui = { Action = { ImageLike = 123 }, Loading = { Image = 456 } } })` 临时覆盖。

## 点击 / 悬浮反馈

与项目 `UIanima` 一致（实现见 `Client/ButtonFeedback.luau`）：

- 悬浮进入：放大到 `1.1`（`BtnScaleAnimEnter`）
- 悬浮离开：恢复 `1`（`BtnScaleAnimLeave`）
- 按下：缩放到 `0.9`（`ButtonDown`）；抬起后若仍悬浮则回到 `1.1`，否则回 `1`
