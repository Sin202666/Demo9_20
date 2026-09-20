--[[
	Module: UiPrefabUtil
	Description: ShortVideo ScreenGui 预制体克隆与节点整理；评论行正文扩高/超限缩字；ActionRail 计数查询
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-09-01

	功能：
	- 优先从 `ReplicatedStorage.Assets.ScreenGui.ShortVideoScreen` 克隆 2D 界面（Studio 手放，不走 Rojo 映射）
	- 无预制体时由 SceneBoard 回退 `BuildUI` 代码创建
	- 整理评论行：优先提升 List.RowTemplate（正确样式）覆盖 drawer 直属旧模板；兼容 LikeIcon / 行级 LikeCount
	- ApplyCommentBodyFit：Body 全程 TextScaled + RichText；≤5 行扩高，超限锁高框内缩放；Name/Time 框尺寸不变
	- 查询 ActionRail 下 LikeCount / CommentCount（优先按钮子级，再平铺）

	用法：
		local UiPrefabUtil = require(...Client.UiPrefabUtil)
		local screenGui, content, prevBtn, nextBtn = UiPrefabUtil.CloneScreen()
		UiPrefabUtil.ApplyCommentBodyFit(row, list, item.text)
		UiPrefabUtil.SetRelativeTime(timeLabel, item.createdAt)
]]

local TextService = game:GetService("TextService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TranslationHelper = Utils.TranslationHelper

local Constants = require(script.Parent.Parent.Shared.Constants)

local UiPrefabUtil = {}

local ATTR_BASE_TEXT_SIZE = "SvBodyBaseTextSize"
local ATTR_LAYOUT_READY = "SvCommentRowLayoutReady"

--[[
	查找预制体：ReplicatedStorage.Assets.ScreenGui.ShortVideoScreen
	@return ScreenGui? - 源 ScreenGui
]]
local function findPrefabSource(): ScreenGui?
	local rs = game:GetService("ReplicatedStorage")
	local assets = rs:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local screenFolder = assets:FindFirstChild("ScreenGui")
	if not screenFolder then
		return nil
	end
	local named = screenFolder:FindFirstChild("ShortVideoScreen")
		or screenFolder:FindFirstChild("UiPrefab")
	if named and named:IsA("ScreenGui") then
		return named
	end
	-- 兼容：Folder 内再包一层 ScreenGui
	if named and named:IsA("Folder") then
		local inner = named:FindFirstChildWhichIsA("ScreenGui")
		if inner then
			return inner
		end
	end
	return nil
end

--[[
	评论行 LikeBtn：确保子层 LikeIcon；LikeCount 提到行直属（对齐新预制体）
	@param row Frame - RowTemplate / 评论行
]]
local function ensureCommentRowLikeStructure(row: Frame)
	local likeBtn = row:FindFirstChild("LikeBtn")
	if not likeBtn or not likeBtn:IsA("ImageButton") then
		return
	end

	local icon = likeBtn:FindFirstChild("LikeIcon")
	if not (icon and icon:IsA("ImageLabel")) then
		icon = Instance.new("ImageLabel")
		icon.Name = "LikeIcon"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(0.4, 0.4)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = likeBtn.ZIndex + 1
		if likeBtn.Image ~= "" then
			icon.Image = likeBtn.Image
		end
		icon.Parent = likeBtn
	end
	likeBtn.Image = ""

	local nestedCount = likeBtn:FindFirstChild("LikeCount")
	if nestedCount and nestedCount:IsA("TextLabel") then
		nestedCount.Parent = row
	end
end

--[[
	去掉行级 UIAspectRatioConstraint（保留 AvatarBg 上的 1:1）
	@param row Frame - 评论行
]]
local function removeRowAspectRatio(row: Frame)
	for _, ch in ipairs(row:GetChildren()) do
		if ch:IsA("UIAspectRatioConstraint") then
			ch:Destroy()
		end
	end
end

--[[
	由 List 高度得到单行稿高
	@param list ScrollingFrame - CommentDrawer.List
	@return number - 像素高；未布局时为 0
]]
local function getRowHeightFromList(list: ScrollingFrame): number
	local listH = list.AbsoluteSize.Y
	if listH < 1 then
		return 0
	end
	local scale = Constants.COMMENT_ROW_HEIGHT_SCALE or 0.2
	return math.max(1, listH * scale)
end

--[[
	将 Name/Body/Time/Avatar/赞区改为固定 Offset（锁尺寸）；Body 可随后增高
	@param row Frame - 评论行
	@param rowH number - 单行稿像素高
	@param rowW number - 行像素宽（List 宽）
]]
local function applyFixedYLayout(row: Frame, rowH: number, rowW: number)
	local layout = Constants.COMMENT_ROW_LAYOUT
	if not layout then
		return
	end
	local nameCfg = layout.Name
	local bodyCfg = layout.Body
	local timeCfg = layout.Time
	local avatarCfg = layout.Avatar
	local likeBtnCfg = layout.LikeBtn
	local likeCountCfg = layout.LikeCount
	if rowW < 1 then
		rowW = row.AbsoluteSize.X
	end
	if rowW < 1 then
		rowW = rowH * 5
	end

	local nameLabel = row:FindFirstChild("NameLabel")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Position = UDim2.new(nameCfg.X, 0, 0, rowH * nameCfg.Y)
		nameLabel.Size = UDim2.new(nameCfg.W, 0, 0, rowH * nameCfg.H)
	end

	local body = row:FindFirstChild("BodyLabel")
	if body and body:IsA("TextLabel") then
		body.Position = UDim2.new(bodyCfg.X, 0, 0, rowH * bodyCfg.Y)
		body.Size = UDim2.new(bodyCfg.W, 0, 0, rowH * bodyCfg.H)
		body.TextWrapped = true
		body.TextTruncate = Enum.TextTruncate.None
		body.RichText = true
		if body:GetAttribute(ATTR_BASE_TEXT_SIZE) == nil then
			body:SetAttribute(ATTR_BASE_TEXT_SIZE, body.TextSize)
		end
	end

	local timeLabel = row:FindFirstChild("TimeLabel")
	if timeLabel and timeLabel:IsA("TextLabel") then
		timeLabel.Position = UDim2.new(timeCfg.X, 0, 0, rowH * timeCfg.Y)
		timeLabel.Size = UDim2.new(timeCfg.W, 0, 0, rowH * timeCfg.H)
	end

	-- 头像：按单行稿高锁正方形 Offset，行变高不再放大
	local avatarBg = row:FindFirstChild("AvatarBg")
	if avatarBg and avatarBg:IsA("GuiObject") and avatarCfg then
		local avatarPx = math.max(1, rowH * (avatarCfg.SizeScale or 0.7))
		avatarBg.Position = UDim2.new(avatarCfg.X or 0.02, 0, 0, rowH * (avatarCfg.Y or 0.1))
		avatarBg.Size = UDim2.fromOffset(avatarPx, avatarPx)
	end

	-- 赞按钮 / 计数：锁到单行稿尺寸，避免随行高 TextScaled 放大
	local likeBtn = row:FindFirstChild("LikeBtn")
	if likeBtn and likeBtn:IsA("GuiObject") and likeBtnCfg then
		likeBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		likeBtn.Position = UDim2.new(likeBtnCfg.X, 0, 0, rowH * likeBtnCfg.Y)
		likeBtn.Size = UDim2.fromOffset(math.max(1, rowW * likeBtnCfg.W), math.max(1, rowH * likeBtnCfg.H))
	end
	local likeCount = row:FindFirstChild("LikeCount")
	if likeCount and likeCount:IsA("TextLabel") and likeCountCfg then
		likeCount.AnchorPoint = Vector2.new(1, 0.5)
		likeCount.Position = UDim2.new(likeCountCfg.X, 0, 0, rowH * likeCountCfg.Y)
		likeCount.Size = UDim2.fromOffset(math.max(1, rowW * likeCountCfg.W), math.max(1, rowH * likeCountCfg.H))
	end

	row.Size = UDim2.new(1, 0, 0, rowH)
	row:SetAttribute(ATTR_LAYOUT_READY, true)
end

--[[
	测算固定字号下正文所需高度
	@param body TextLabel - BodyLabel
	@param text string - 正文
	@param textSize number - 字号
	@param widthPx number - 可用宽度
	@return number - 所需像素高
]]
local function measureBodyHeight(body: TextLabel, text: string, textSize: number, widthPx: number): number
	if widthPx < 1 then
		return body.AbsoluteSize.Y
	end
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, textSize, body.Font, Vector2.new(widthPx, 10000))
	end)
	if ok and bounds then
		return math.max(1, bounds.Y)
	end
	return body.AbsoluteSize.Y
end

--[[
	Body 增高后推 Time、更新行高（Name/Time Size 不变）
	@param row Frame - 评论行
	@param rowH number - 单行稿高
	@param bodyH number - 当前 Body 高
]]
local function layoutRowAfterBody(row: Frame, rowH: number, bodyH: number)
	local layout = Constants.COMMENT_ROW_LAYOUT
	local bodyCfg = layout and layout.Body
	local timeCfg = layout and layout.Time
	if not (bodyCfg and timeCfg) then
		return
	end

	local bodyY = rowH * bodyCfg.Y
	local timeH = rowH * timeCfg.H
	local gap = rowH * timeCfg.Y - (rowH * bodyCfg.Y + rowH * bodyCfg.H)
	if gap < 0 then
		gap = 0
	end

	local body = row:FindFirstChild("BodyLabel")
	if body and body:IsA("TextLabel") then
		body.Position = UDim2.new(bodyCfg.X, 0, 0, bodyY)
		body.Size = UDim2.new(bodyCfg.W, 0, 0, bodyH)
	end

	local timeLabel = row:FindFirstChild("TimeLabel")
	local timeBottom = bodyY + bodyH + gap + timeH
	if timeLabel and timeLabel:IsA("TextLabel") then
		timeLabel.Position = UDim2.new(timeCfg.X, 0, 0, bodyY + bodyH + gap)
	end

	row.Size = UDim2.new(1, 0, 0, math.max(rowH, timeBottom + 4))
end

--[[
	清空评论行演示数据
	@param row Frame - 行
]]
local function clearRowDemo(row: Frame)
	ensureCommentRowLikeStructure(row)
	removeRowAspectRatio(row)
	local nameLabel = row:FindFirstChild("NameLabel")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = ""
	end
	local body = row:FindFirstChild("BodyLabel")
	if body and body:IsA("TextLabel") then
		body.Text = ""
	end
	local timeLabel = row:FindFirstChild("TimeLabel")
	if timeLabel and timeLabel:IsA("TextLabel") then
		timeLabel.Text = ""
	end
	local avatar = row:FindFirstChild("Avatar", true)
	if avatar and avatar:IsA("ImageLabel") then
		avatar.Image = ""
	end
	local likeCount = row:FindFirstChild("LikeCount") or row:FindFirstChild("LikeCount", true)
	if likeCount and likeCount:IsA("TextLabel") then
		likeCount.Text = "0"
	end
	local likeIcon = row:FindFirstChild("LikeIcon", true)
	if likeIcon and likeIcon:IsA("ImageLabel") then
		likeIcon.Image = ""
	end
end

--[[
	整理评论行模板：优先提升 List.RowTemplate（正确样式）覆盖 drawer 直属旧模板；
	清空演示文案，并移除 List 内剩余样例 Row_*。
	@param drawer Frame - CommentDrawer
]]
function UiPrefabUtil.PrepareRowTemplate(drawer: Frame)
	local list = drawer:FindFirstChild("List")
	local drawerTemplate = drawer:FindFirstChild("RowTemplate")
	local listTemplate = list and list:FindFirstChild("RowTemplate")
	local listRow1 = list and list:FindFirstChild("Row_1")

	local source: Frame? = nil
	if listTemplate and listTemplate:IsA("Frame") then
		source = listTemplate
	elseif listRow1 and listRow1:IsA("Frame") then
		source = listRow1
	end

	if source then
		clearRowDemo(source)
		source.Name = "RowTemplate"
		source.Visible = false
		if drawerTemplate and drawerTemplate ~= source and drawerTemplate:IsA("Frame") then
			drawerTemplate:Destroy()
		end
		source.Parent = drawer
	elseif drawerTemplate and drawerTemplate:IsA("Frame") then
		clearRowDemo(drawerTemplate)
		drawerTemplate.Visible = false
		if drawerTemplate.Parent ~= drawer then
			drawerTemplate.Parent = drawer
		end
	end

	if list then
		for _, ch in ipairs(list:GetChildren()) do
			if ch:IsA("GuiObject") and (ch.Name == "RowTemplate" or string.match(ch.Name, "^Row_")) then
				ch:Destroy()
			end
		end
	end
end

--[[
	旧名兼容
	@param drawer Frame - CommentDrawer
]]
function UiPrefabUtil.PromoteRowTemplate(drawer: Frame)
	UiPrefabUtil.PrepareRowTemplate(drawer)
end

--[[
	按 List 高度规范化行纵向布局（Name/Time 框锁定）；List 未布局时返回 false
	@param row Frame - 评论行
	@param list ScrollingFrame - List
	@return boolean - 是否已应用
]]
function UiPrefabUtil.EnsureCommentRowLayout(row: Frame, list: ScrollingFrame): boolean
	local rowH = getRowHeightFromList(list)
	if rowH < 1 then
		return false
	end
	ensureCommentRowLikeStructure(row)
	removeRowAspectRatio(row)
	if row:GetAttribute(ATTR_LAYOUT_READY) ~= true then
		applyFixedYLayout(row, rowH, list.AbsoluteSize.X)
	end
	return true
end

--[[
	正文拟合：Body 全程 TextScaled + RichText；≤MAX_LINES 扩高，超限锁高（框内整体缩放）；Name/Time Size 不变
	@param row Frame - 评论行
	@param list ScrollingFrame - List
	@param text string - 正文
	@return boolean - List 已布局且拟合完成
]]
function UiPrefabUtil.ApplyCommentBodyFit(row: Frame, list: ScrollingFrame, text: string): boolean
	local body = row:FindFirstChild("BodyLabel")
	if not (body and body:IsA("TextLabel")) then
		return false
	end

	local rowH = getRowHeightFromList(list)
	if rowH < 1 then
		body.Text = text
		return false
	end

	ensureCommentRowLikeStructure(row)
	removeRowAspectRatio(row)
	applyFixedYLayout(row, rowH, list.AbsoluteSize.X)

	local layout = Constants.COMMENT_ROW_LAYOUT
	local bodyCfg = layout and layout.Body
	local nameCfg = layout and layout.Name
	local hBase = rowH * ((bodyCfg and bodyCfg.H) or 0.264)
	local maxLines = Constants.COMMENT_BODY_MAX_LINES or 5
	local maxBodyH = hBase * maxLines

	local nameLabel = row:FindFirstChild("NameLabel")
	local nameH = 0
	if nameLabel and nameLabel:IsA("TextLabel") and nameLabel.AbsoluteSize.Y > 1 then
		nameH = nameLabel.AbsoluteSize.Y
	elseif nameCfg then
		nameH = rowH * nameCfg.H
	end
	if nameH < 1 then
		nameH = body.TextSize
	end

	-- 测高仍按 Name 框高估算换行所需高度；显示全程 TextScaled
	local measureSize = math.max(1, nameH)
	if body:GetAttribute(ATTR_BASE_TEXT_SIZE) == nil then
		body:SetAttribute(ATTR_BASE_TEXT_SIZE, measureSize)
	end

	body.Text = text or ""
	body.TextWrapped = true
	body.TextTruncate = Enum.TextTruncate.None
	body.TextScaled = true
	body.RichText = true
	body.TextSize = measureSize

	local widthPx = body.AbsoluteSize.X
	if widthPx < 1 then
		widthPx = list.AbsoluteSize.X * ((bodyCfg and bodyCfg.W) or 0.65)
	end

	local needed = measureBodyHeight(body, body.Text, measureSize, widthPx)
	if needed <= maxBodyH + 0.5 then
		layoutRowAfterBody(row, rowH, math.max(hBase, needed))
	else
		layoutRowAfterBody(row, rowH, maxBodyH)
	end
	return true
end

--[[
	重置克隆后的演示态（标题/计数/进度/抽屉）
	@param content Frame - Content
]]
local function resetDemoState(content: Frame)
	local title = content:FindFirstChild("TopBar") and content.TopBar:FindFirstChild("TitleLabel")
	if title and title:IsA("TextLabel") then
		title.Text = ""
	end
	local rail = content:FindFirstChild("ActionRail")
	if rail then
		local likeCount = UiPrefabUtil.FindActionCount(rail, "LikeBtn", "LikeCount")
		local cmtCount = UiPrefabUtil.FindActionCount(rail, "CommentBtn", "CommentCount")
		if likeCount then
			likeCount.Text = "0"
		end
		if cmtCount then
			cmtCount.Text = "0"
		end
	end
	local progress = content:FindFirstChild("ProgressBar")
	if progress then
		local fill = progress:FindFirstChild("Fill")
		if fill and fill:IsA("GuiObject") then
			fill.Size = UDim2.new(0, 0, 1, 0)
		end
	end
	local drawer = content:FindFirstChild("CommentDrawer")
	if drawer and drawer:IsA("Frame") then
		drawer.Visible = false
		UiPrefabUtil.PrepareRowTemplate(drawer)
		local header = drawer:FindFirstChild("Header")
		local headerTitle = header and header:FindFirstChild("Title")
		if headerTitle and headerTitle:IsA("TextLabel") then
			TranslationHelper.SetText(headerTitle, "短视频评论")
		end
		local input = drawer:FindFirstChild("Input", true)
		if input and input:IsA("TextBox") then
			input.Text = ""
			TranslationHelper.SetText(input, "短视频评论占位")
		end
	end
	local loading = content:FindFirstChild("LoadingOverlay")
	if loading and loading:IsA("GuiObject") then
		loading.Visible = false
	end
end

--[[
	查询 ActionRail 计数 Label（优先按钮子级，再平铺）
	@param rail Instance - ActionRail
	@param btnName string - LikeBtn / CommentBtn
	@param countName string - LikeCount / CommentCount
	@return TextLabel?
]]
function UiPrefabUtil.FindActionCount(rail: Instance, btnName: string, countName: string): TextLabel?
	local btn = rail:FindFirstChild(btnName)
	if btn then
		local nested = btn:FindFirstChild(countName)
		if nested and nested:IsA("TextLabel") then
			return nested
		end
	end
	local flat = rail:FindFirstChild(countName)
	if flat and flat:IsA("TextLabel") then
		return flat
	end
	return nil
end

--[[
	相对时间写入 TimeLabel（切语言可刷新）
	@param label TextLabel - 评论行时间控件
	@param createdAt number - unix 秒；无效则清空
	@return nil
]]
function UiPrefabUtil.SetRelativeTime(label: TextLabel, createdAt: number)
	local ts = tonumber(createdAt)
	if not ts or ts <= 0 then
		TranslationHelper.SetRawText(label, "")
		return
	end
	local diff = math.max(0, os.time() - math.floor(ts))
	if diff < 60 then
		TranslationHelper.SetText(label, "短视频刚刚")
		return
	end
	if diff < 3600 then
		TranslationHelper.SetText(label, "短视频分钟前", { math.floor(diff / 60) })
		return
	end
	if diff < 86400 then
		TranslationHelper.SetText(label, "短视频小时前", { math.floor(diff / 3600) })
		return
	end
	if diff < 86400 * 30 then
		TranslationHelper.SetText(label, "短视频天前", { math.floor(diff / 86400) })
		return
	end
	if diff < 86400 * 365 then
		TranslationHelper.SetText(label, "短视频月前", { math.floor(diff / (86400 * 30)) })
		return
	end
	TranslationHelper.SetText(label, "短视频年前", { math.floor(diff / (86400 * 365)) })
end

--[[
	是否存在可克隆的 ScreenGui 预制体
	@return boolean
]]
function UiPrefabUtil.HasScreenPrefab(): boolean
	return findPrefabSource() ~= nil
end

--[[
	克隆 2D ShortVideoScreen 预制体并整理节点
	@return ScreenGui? - 克隆体
	@return Frame? - Content（业务根）
	@return ImageButton? - PrevBtn
	@return ImageButton? - NextBtn
	@return Frame? - Phone
	@return Frame? - Stage
]]
function UiPrefabUtil.CloneScreen(): (ScreenGui?, Frame?, ImageButton?, ImageButton?, Frame?, Frame?)
	local source = findPrefabSource()
	if not source then
		return nil, nil, nil, nil, nil, nil
	end
	local screenGui = source:Clone()
	screenGui.Name = "ShortVideoScreen"
	screenGui.Enabled = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 120
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local stage = screenGui:FindFirstChild("Stage") :: Frame?
	local phone = stage and stage:FindFirstChild("Phone") :: Frame?
	local rootShell = phone and phone:FindFirstChild("Root") :: Frame?
	local content = rootShell and rootShell:FindFirstChild("Content") :: Frame?
	local prevBtn = stage and stage:FindFirstChild("PrevBtn") :: ImageButton?
	local nextBtn = stage and stage:FindFirstChild("NextBtn") :: ImageButton?

	if not (stage and phone and content and prevBtn and nextBtn) then
		screenGui:Destroy()
		warn("[ShortVideoFeature] Assets.ScreenGui.ShortVideoScreen hierarchy incomplete")
		return nil, nil, nil, nil, nil, nil
	end

	resetDemoState(content)
	return screenGui, content, prevBtn, nextBtn, phone, stage
end

return UiPrefabUtil
