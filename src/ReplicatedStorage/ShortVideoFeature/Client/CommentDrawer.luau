--[[
	Module: CommentDrawer
	Description: 评论半高抽屉；Top/Newest 排序切换；分页；发评本地置顶；评论赞立刻乐观 + 单飞追赶
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-09-01

	预制体约定：正式评论行以 List.RowTemplate 提升后的 drawer.RowTemplate 为准（含 AvatarBg、TimeLabel）；
	LikeBtn 贴图走子层 LikeIcon（ImageLabel），LikeCount 为行直属子节点（不在按钮内）；
	正文 ApplyCommentBodyFit：Body 全程 TextScaled + RichText；≤5 行扩高，超限锁高；Name/Time 框尺寸不变。
	Input / SendBtn 可在 InputFrame 下（FindFirstChild 递归查找）。
	排序按钮在 Header 下（SortHotBtn / SortNewestBtn，文案在子 TextLabel），可缺省，运行时补建。
	打开抽屉才拉评；近底预载（COMMENT_PREFETCH_VIEWPORT_RATIO）+ 首屏后静默再拉一页；
	达 COMMENT_MEMORY_MAX 停载。
	切换排序清空列表并首页重拉；切视频时强制回到最高赞（Top）排序。
	发评成功本地插入置顶；点赞只 patch 该行，不整表 rebind。
	发评/赞失败走 TipsModule.ErrorTips（调用处字面量 Language 键）。
]]

local Constants = require(script.Parent.Parent.Shared.Constants)
local AvatarCache = require(script.Parent.AvatarCache)
local SocialClient = require(script.Parent.SocialClient)
local ButtonFeedback = require(script.Parent.ButtonFeedback)
local UiAssets = require(script.Parent.UiAssets)
local UiPrefabUtil = require(script.Parent.UiPrefabUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TipsModule = Utils.TipsModule
local TranslationHelper = Utils.TranslationHelper
local LocalPlayer = Utils.LocalPlayer

local CommentDrawer = {}

local DEFAULT_SORT = Constants.DEFAULT_COMMENT_SORT or Constants.COMMENT_SORT.Hot

export type Drawer = {
	open: (self: Drawer) -> (),
	close: (self: Drawer) -> (),
	toggle: (self: Drawer) -> (),
	isOpen: (self: Drawer) -> boolean,
	setVideo: (self: Drawer, videoId: string) -> (),
	setTotalCount: (self: Drawer, count: number) -> (),
	setOnTotalCountChanged: (self: Drawer, cb: ((number) -> ())?) -> (),
	destroy: (self: Drawer) -> (),
}

--[[
	应用评论行点赞视觉（CommentLike 专用图，与主界面 Action 分离）
	@param likeBtn GuiButton - 点赞按钮
	@param liked boolean - 是否已赞
]]
local function applyCommentLikeVisual(likeBtn: GuiButton, liked: boolean)
	local cfg = Constants.UI.CommentLike or Constants.UI.Action
	UiAssets.ApplyLikeState(
		likeBtn,
		liked,
		cfg.ImageLike,
		cfg.ImageLiked,
		cfg.FallbackLike,
		cfg.FallbackLiked
	)
end

--[[
	运行时补建排序按钮文案 Label（对齐预制体：字色在 TextLabel 上）
	@param btn TextButton - 排序按钮
	@param text string - 文案
	@return TextLabel
]]
local function ensureSortBtnLabel(btn: TextButton, text: string): TextLabel
	local label = btn:FindFirstChildWhichIsA("TextLabel")
	if label then
		return label
	end
	label = Instance.new("TextLabel")
	label.Name = "TextLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = 14
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = Constants.COLORS.SortUnselectedText
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = btn.ZIndex + 1
	label.Parent = btn
	return label
end

--[[
	应用单个排序按钮选中/未选中视觉
	@param btn GuiButton - SortHotBtn / SortNewestBtn
	@param selected boolean - 是否选中
]]
local function applySortBtnVisual(btn: GuiButton, selected: boolean)
	local colors = Constants.COLORS
	btn.BackgroundColor3 = if selected then colors.SortSelectedBg else colors.SortUnselectedBg
	btn.BackgroundTransparency = 0
	local textColor = if selected then colors.SortSelectedText else colors.SortUnselectedText
	local label = btn:FindFirstChildWhichIsA("TextLabel")
	if label then
		label.TextColor3 = textColor
	elseif btn:IsA("TextButton") then
		(btn :: TextButton).TextColor3 = textColor
	end
end

--[[
	保证 Header 下排序按钮存在（预制体可缺省）
	@param header Frame - CommentDrawer.Header
	@return GuiButton - SortHotBtn
	@return GuiButton - SortNewestBtn
]]
local function ensureSortButtons(header: Frame): (GuiButton, GuiButton)
	local hotBtn = header:FindFirstChild("SortHotBtn") :: GuiButton?
	if not hotBtn then
		local btn = Instance.new("TextButton")
		btn.Name = "SortHotBtn"
		btn.Size = UDim2.fromOffset(72, 26)
		btn.Position = UDim2.fromOffset(12, 7)
		btn.Text = ""
		btn.BackgroundColor3 = Constants.COLORS.SortSelectedBg
		btn.BackgroundTransparency = 0
		btn.BorderSizePixel = 0
		btn.ZIndex = 12
		btn.AutoButtonColor = false
		btn.Parent = header
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = btn
		ensureSortBtnLabel(btn, "Top")
		hotBtn = btn
	elseif hotBtn:IsA("TextButton") then
		ensureSortBtnLabel(hotBtn :: TextButton, "Top")
	end
	local newestBtn = header:FindFirstChild("SortNewestBtn") :: GuiButton?
	if not newestBtn then
		local btn = Instance.new("TextButton")
		btn.Name = "SortNewestBtn"
		btn.Size = UDim2.fromOffset(72, 26)
		btn.Position = UDim2.fromOffset(92, 7)
		btn.Text = ""
		btn.BackgroundColor3 = Constants.COLORS.SortUnselectedBg
		btn.BackgroundTransparency = 0
		btn.BorderSizePixel = 0
		btn.ZIndex = 12
		btn.AutoButtonColor = false
		btn.Parent = header
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = btn
		ensureSortBtnLabel(btn, "Newest")
		newestBtn = btn
	elseif newestBtn:IsA("TextButton") then
		ensureSortBtnLabel(newestBtn :: TextButton, "Newest")
	end
	return hotBtn, newestBtn
end

--[[
	仅校正 List 滚动行为；Size/Position 保持预制体，不在运行时改写
	@param drawerFrame Frame - CommentDrawer（保留参数，便于调用点不变）
	@param list ScrollingFrame - List
]]
local function layoutList(_drawerFrame: Frame, list: ScrollingFrame)
	list.ScrollBarThickness = math.max(list.ScrollBarThickness, 4)
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ElasticBehavior = Enum.ElasticBehavior.Always
end

--[[
	绑定抽屉 UI
	@param root Frame - Root
	@return Drawer
]]
function CommentDrawer.new(root: Frame): Drawer
	local drawerFrame = root:WaitForChild("CommentDrawer") :: Frame
	local list = drawerFrame:WaitForChild("List") :: ScrollingFrame
	UiPrefabUtil.PrepareRowTemplate(drawerFrame)
	local template = drawerFrame:WaitForChild("RowTemplate") :: Frame
	local input = drawerFrame:FindFirstChild("Input", true) :: TextBox
	local sendBtn = drawerFrame:FindFirstChild("SendBtn", true) :: GuiButton
	assert(input and input:IsA("TextBox"), "[ShortVideoFeature] CommentDrawer.Input missing")
	assert(sendBtn and sendBtn:IsA("GuiButton"), "[ShortVideoFeature] CommentDrawer.SendBtn missing")
	local header = drawerFrame:WaitForChild("Header") :: Frame
	local closeBtn = header:WaitForChild("CloseDrawerBtn") :: TextButton
	local headerTitle = header:WaitForChild("Title") :: TextLabel
	local sortHotBtn, sortNewestBtn = ensureSortButtons(header)

	layoutList(drawerFrame, list)

	local self = {} :: any
	self._open = false
	self._videoId = nil :: string?
	self._items = {} :: { any }
	self._liked = {} :: { [string]: boolean }
	self._nextCursor = nil :: any
	self._hasMore = true
	self._loading = false
	self._posting = false
	self._likingCid = nil :: string?
	self._likingCids = {} :: { [string]: boolean }
	self._gen = 0
	self._totalCount = 0
	self._pool = {} :: { Frame }
	self._conns = {} :: { RBXScriptConnection }
	self._boundLike = {} :: { [Frame]: boolean }
	self._onTotalCountChanged = nil :: ((number) -> ())?
	self._sortMode = DEFAULT_SORT
	self._didAutoPrefetch = false

	-- 清理旧版底栏 Loading 文案节点（若预制体/上次运行残留）
	local staleFooter = list:FindFirstChild("LoadingFooter")
	if staleFooter then
		staleFooter:Destroy()
	end

	--[[
		同步外层评论数回调
	]]
	local function notifyTotalCount()
		local cb = self._onTotalCountChanged
		if cb then
			cb(self._totalCount)
		end
	end

	--[[
		框架 Tips 错误提示（Language 键；TOO_LONG 带上限参数）
		@param errCode string? - Constants.ERROR
	]]
	local function showErrHint(errCode: string?)
		if errCode == Constants.ERROR.TOO_LONG then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论过长", { Constants.COMMENT_MAX_LEN })
		elseif errCode == Constants.ERROR.RATE_LIMIT then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论过快")
		elseif errCode == Constants.ERROR.FILTER_FAIL then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论被屏蔽")
		elseif errCode == Constants.ERROR.BUSY then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论繁忙")
		elseif errCode == Constants.ERROR.INVALID then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论无效")
		elseif errCode == Constants.ERROR.NOT_FOUND then
			TipsModule.ErrorTips(LocalPlayer, "短视频评论不存在")
		end
	end

	--[[
		刷新排序按钮选中态（背景 + 子 TextLabel 字色）
	]]
	local function applySortVisual()
		local isHot = self._sortMode == Constants.COMMENT_SORT.Hot
		applySortBtnVisual(sortHotBtn, isHot)
		applySortBtnVisual(sortNewestBtn, not isHot)
	end

	--[[
		保证行池至少 n 行
		@param n number - 需要的行数
	]]
	local function ensurePool(n: number)
		n = math.min(n, Constants.COMMENT_MEMORY_MAX)
		while #self._pool < n do
			local row = template:Clone()
			row.Name = "Row_" .. (#self._pool + 1)
			row.Visible = false
			row.Parent = list
			table.insert(self._pool, row)
		end
	end

	ensurePool(Constants.COMMENT_ROW_POOL)

	--[[
		估算单行高度
		@return number - 像素高度
	]]
	local function estimateRowHeight(): number
		local sample = self._pool[1]
		if sample and sample.AbsoluteSize.Y > 1 then
			return sample.AbsoluteSize.Y + 6
		end
		return 116
	end

	--[[
		刷新标题
	]]
	local function refreshTitle()
		local n = self._totalCount
		if n < #self._items then
			n = #self._items
		end
		TranslationHelper.SetText(headerTitle, "短视频评论标题", { n })
	end

	--[[
		是否已滚到近底预载区（方案 A）
		@return boolean - true 表示应触发 loadMore
	]]
	local function isNearPrefetchEdge(): boolean
		local windowH = list.AbsoluteWindowSize.Y
		local canvasH = list.AbsoluteCanvasSize.Y
		if windowH < 1 then
			return false
		end
		-- 内容未填满视口：视为已在底，便于短列表连续补页
		if canvasH <= windowH + 1 then
			return true
		end
		local ratio = tonumber(Constants.COMMENT_PREFETCH_VIEWPORT_RATIO) or 8
		local threshold = math.max(40, windowH * ratio)
		return list.CanvasPosition.Y + windowH >= canvasH - threshold
	end

	local resetAndLoad: () -> ()
	local rebind: () -> ()
	local loadMore: () -> ()

	--[[
		按 cid 找本地评论
		@param cid string - 评论 id
		@return any? - item
	]]
	local function findItem(cid: string): any?
		for _, item in ipairs(self._items) do
			if item and item.cid == cid then
				return item
			end
		end
		return nil
	end

	--[[
		只刷新某一行的赞视觉（不重拉头像）
		@param cid string - 评论 id
		@param playPop boolean? - 是否弹跳
	]]
	local function patchRowLike(cid: string, playPop: boolean?)
		for i, item in ipairs(self._items) do
			if item and item.cid == cid then
				local row = self._pool[i]
				if row and row.Visible then
					local likeBtn = row:FindFirstChild("LikeBtn") :: GuiButton?
					if likeBtn then
						local liked = self._liked[cid] == true
						applyCommentLikeVisual(likeBtn, liked)
						local likeCountLabel = (row:FindFirstChild("LikeCount") or likeBtn:FindFirstChild("LikeCount")) :: TextLabel?
						if likeCountLabel then
							likeCountLabel.Text = tostring(item.likeCount or 0)
						end
						likeBtn:SetAttribute("Cid", cid)
						if playPop then
							ButtonFeedback.PlayLikePop(likeBtn)
						end
					end
				end
				return
			end
		end
	end

	--[[
		单飞追赶评论赞到本地目标态
		@param videoId string - 视频 id
		@param cid string - 评论 id
	]]
	local function syncCommentLikeToServer(videoId: string, cid: string)
		if self._likingCids[cid] then
			return
		end
		self._likingCids[cid] = true
		task.spawn(function()
			while true do
				if self._videoId ~= videoId then
					break
				end
				local issuedLiked = self._liked[cid] == true
				while SocialClient.IsCommentLikeCooling() do
					task.wait(0.05)
					if self._videoId ~= videoId then
						self._likingCids[cid] = nil
						return
					end
					issuedLiked = self._liked[cid] == true
				end
				local res = SocialClient.ToggleCommentLike(videoId, cid)
				if self._videoId ~= videoId then
					break
				end
				local cur = findItem(cid)
				local currentLiked = self._liked[cid] == true
				if not res or not res.ok then
					if currentLiked == issuedLiked then
						self._liked[cid] = not issuedLiked
						if cur then
							cur.likeCount = math.max(0, (tonumber(cur.likeCount) or 0) + (if issuedLiked then -1 else 1))
						end
						showErrHint(res and res.err)
						patchRowLike(cid)
					end
					break
				end
				local serverLiked = res.liked == true
				local serverCount = math.max(0, tonumber(res.likeCount) or 0)
				if currentLiked == serverLiked then
					self._liked[cid] = serverLiked
					if cur then
						cur.likeCount = serverCount
					end
					patchRowLike(cid)
					break
				end
				if cur then
					cur.likeCount = math.max(0, serverCount + (if currentLiked then 1 else -1))
				end
				patchRowLike(cid)
			end
			self._likingCids[cid] = nil
		end)
	end

	--[[
		绑定点赞（每行一次）；立刻乐观反馈；单飞追赶服务端
		@param row Frame - 行
	]]
	local function bindRowLike(row: Frame)
		if self._boundLike[row] then
			return
		end
		self._boundLike[row] = true
		local likeBtn = row:FindFirstChild("LikeBtn") :: GuiButton
		for _, c in ipairs(ButtonFeedback.Bind(likeBtn)) do
			table.insert(self._conns, c)
		end
		table.insert(self._conns, likeBtn.MouseButton1Click:Connect(function()
			local cid = likeBtn:GetAttribute("Cid")
			if typeof(cid) ~= "string" or not self._videoId then
				return
			end
			if not self._likingCids[cid] and SocialClient.IsCommentLikeCooling() then
				ButtonFeedback.PlayLikePop(likeBtn)
				return
			end
			local item = findItem(cid)
			if not item then
				return
			end
			local videoId = self._videoId
			local prevLiked = self._liked[cid] == true
			local prevCount = math.max(0, tonumber(item.likeCount) or 0)
			local nextLiked = not prevLiked
			self._liked[cid] = nextLiked
			item.likeCount = math.max(0, prevCount + (if nextLiked then 1 else -1))
			patchRowLike(cid, true)
			syncCommentLikeToServer(videoId, cid)
		end))
	end

	--[[
		刷新可见行绑定（已加载条全部生成）
	]]
	rebind = function()
		local gen = self._gen
		ensurePool(#self._items)
		for i, row in ipairs(self._pool) do
			local item = self._items[i]
			if not item then
				row.Visible = false
			else
				bindRowLike(row)
				row.Visible = true
				row.LayoutOrder = i
				local nameLabel = row:FindFirstChild("NameLabel") :: TextLabel
				local body = row:FindFirstChild("BodyLabel") :: TextLabel
				local likeBtn = row:FindFirstChild("LikeBtn") :: GuiButton
				local likeCount = (row:FindFirstChild("LikeCount") or (likeBtn and likeBtn:FindFirstChild("LikeCount"))) :: TextLabel?
				local avatar = row:FindFirstChild("Avatar", true) :: ImageLabel
				local timeLabel = row:FindFirstChild("TimeLabel") :: TextLabel?
				nameLabel.Text = item.name or ""
				if timeLabel then
					UiPrefabUtil.SetRelativeTime(timeLabel, item.createdAt or 0)
				end
				local fitOk = UiPrefabUtil.ApplyCommentBodyFit(row, list, item.text or "")
				if not fitOk then
					body.Text = item.text or ""
				end
				local liked = self._liked[item.cid] == true
				applyCommentLikeVisual(likeBtn, liked)
				if likeCount then
					likeCount.Text = tostring(item.likeCount or 0)
				end
				avatar:SetAttribute("UserId", item.userId)
				local prevUid = avatar:GetAttribute("BoundUserId")
				local hasImg = avatar.Image ~= nil and avatar.Image ~= ""
				if prevUid == item.userId and hasImg then
					-- 同用户已绑过头像：不清空、不重打 API
				else
					avatar.Image = ""
					AvatarCache.GetAsync(item.userId, function(url)
						if gen ~= self._gen then
							return
						end
						if url then
							avatar.Image = url
							avatar:SetAttribute("BoundUserId", item.userId)
						end
					end)
				end
				likeBtn:SetAttribute("Cid", item.cid)
			end
		end
		local function refreshCanvas()
			local layout = list:FindFirstChildOfClass("UIListLayout")
			if layout then
				list.CanvasSize = UDim2.fromOffset(0, math.max(layout.AbsoluteContentSize.Y, 1))
			else
				list.CanvasSize = UDim2.fromOffset(0, math.max(#self._items, 1) * estimateRowHeight())
			end
		end
		refreshCanvas()
		-- List 未布局或 AutomaticSize 未落定：下一帧补拟合再刷 Canvas
		task.defer(function()
			if gen ~= self._gen then
				return
			end
			for i, row in ipairs(self._pool) do
				local item = self._items[i]
				if item and row.Visible then
					UiPrefabUtil.ApplyCommentBodyFit(row, list, item.text or "")
				end
			end
			refreshCanvas()
			layoutList(drawerFrame, list)
		end)
		refreshTitle()
		layoutList(drawerFrame, list)
	end

	--[[
		拉一页（达内存上限则停载；限流短延迟重试；空列表时标题 Loading）
		成功后：首屏静默再拉一页（B）；若仍近底则继续补页（A）
	]]
	loadMore = function()
		if self._loading or not self._videoId or not self._hasMore then
			return
		end
		if #self._items >= Constants.COMMENT_MEMORY_MAX then
			self._hasMore = false
			return
		end
		self._loading = true
		if #self._items == 0 then
			TranslationHelper.SetText(headerTitle, "加载中")
		end
		local gen = self._gen
		local videoId = self._videoId
		local cursor = self._nextCursor
		local sortMode = self._sortMode
		local room = Constants.COMMENT_MEMORY_MAX - #self._items
		local pageSize = math.min(Constants.COMMENT_PAGE_SIZE, room)
		task.spawn(function()
			local ok, res = pcall(function()
				return SocialClient.FetchComments(videoId, cursor, pageSize, sortMode)
			end)
			self._loading = false
			if gen ~= self._gen then
				return
			end
			if not ok then
				warn("[ShortVideoFeature] FetchComments failed:", res)
				self._hasMore = false
				refreshTitle()
				return
			end
			if not res or not res.ok then
				if res and res.err == Constants.ERROR.RATE_LIMIT then
					-- 限流：短延迟重试，避免永久停载
					task.delay(0.6, function()
						if gen == self._gen and self._open and self._videoId == videoId then
							loadMore()
						end
					end)
					return
				end
				self._hasMore = false
				refreshTitle()
				showErrHint(res and res.err)
				return
			end
			local seen = {}
			for _, c in ipairs(self._items) do
				seen[c.cid] = true
			end
			for _, c in ipairs(res.comments or {}) do
				if #self._items >= Constants.COMMENT_MEMORY_MAX then
					break
				end
				if c and c.cid and not seen[c.cid] then
					seen[c.cid] = true
					table.insert(self._items, c)
					-- 按页重建 liked：缺省视为未赞（避免只下发 true 残留）
					self._liked[c.cid] = (res.likedMap and res.likedMap[c.cid]) == true
				end
			end
			self._nextCursor = res.nextCursor
			if #self._items >= Constants.COMMENT_MEMORY_MAX then
				self._hasMore = false
			else
				self._hasMore = res.nextCursor ~= nil
			end
			rebind()

			-- 首屏成功后静默再拉一页；补页后仍近底则继续
			local willContinue = false
			if self._hasMore and self._open and self._videoId == videoId then
				local autoFirst = Constants.COMMENT_AUTO_PREFETCH_FIRST ~= false
				if autoFirst and not self._didAutoPrefetch then
					self._didAutoPrefetch = true
					willContinue = true
				elseif isNearPrefetchEdge() then
					willContinue = true
				end
			end
			if willContinue then
				task.defer(loadMore)
			end
		end)
	end

	--[[
		重置并拉首屏
	]]
	resetAndLoad = function()
		self._gen += 1
		self._items = {}
		self._liked = {}
		self._nextCursor = nil
		self._hasMore = true
		self._loading = false
		self._didAutoPrefetch = false
		self._likingCid = nil
		table.clear(self._likingCids)
		list.CanvasPosition = Vector2.zero
		rebind()
		if self._open and self._videoId then
			loadMore()
		end
	end

	--[[
		切换排序（同模式忽略；跨模式清空重拉）
		@param mode string - COMMENT_SORT
	]]
	local function setSortMode(mode: string)
		local normalized = if mode == Constants.COMMENT_SORT.Newest
			then Constants.COMMENT_SORT.Newest
			else Constants.COMMENT_SORT.Hot
		if self._sortMode == normalized then
			return
		end
		self._sortMode = normalized
		applySortVisual()
		if self._open and self._videoId then
			resetAndLoad()
		end
	end

	applySortVisual()

	table.insert(self._conns, closeBtn.MouseButton1Click:Connect(function()
		self:close()
	end))

	for _, c in ipairs(ButtonFeedback.Bind(closeBtn)) do
		table.insert(self._conns, c)
	end
	for _, c in ipairs(ButtonFeedback.Bind(sendBtn)) do
		table.insert(self._conns, c)
	end
	for _, c in ipairs(ButtonFeedback.Bind(sortHotBtn)) do
		table.insert(self._conns, c)
	end
	for _, c in ipairs(ButtonFeedback.Bind(sortNewestBtn)) do
		table.insert(self._conns, c)
	end

	table.insert(self._conns, sortHotBtn.MouseButton1Click:Connect(function()
		setSortMode(Constants.COMMENT_SORT.Hot)
	end))
	table.insert(self._conns, sortNewestBtn.MouseButton1Click:Connect(function()
		setSortMode(Constants.COMMENT_SORT.Newest)
	end))

	table.insert(self._conns, sendBtn.MouseButton1Click:Connect(function()
		if not self._videoId or self._posting then
			return
		end
		local text = input.Text
		if text == "" then
			return
		end
		local trimmed = string.gsub(text, "^%s+", "")
		trimmed = string.gsub(trimmed, "%s+$", "")
		if trimmed == "" then
			showErrHint(Constants.ERROR.INVALID)
			return
		end
		-- 客户端先拦：UTF-8 字节长度超限，避免无意义请求
		if #trimmed > Constants.COMMENT_MAX_LEN then
			showErrHint(Constants.ERROR.TOO_LONG)
			return
		end
		local videoId = self._videoId
		self._posting = true
		task.spawn(function()
			local res = SocialClient.PostComment(videoId, trimmed)
			self._posting = false
			if self._videoId ~= videoId then
				return
			end
			if not res or not res.ok then
				showErrHint(res and res.err)
				return
			end
			input.Text = ""
			-- 本地置顶插入，避免热度序重拉后「自己的评论消失」
			local cmt = res.comment
			if cmt and cmt.cid then
				local seen = false
				for _, existing in ipairs(self._items) do
					if existing.cid == cmt.cid then
						seen = true
						break
					end
				end
				if not seen then
					table.insert(self._items, 1, cmt)
					while #self._items > Constants.COMMENT_MEMORY_MAX do
						table.remove(self._items)
					end
				end
				self._liked[cmt.cid] = false
			end
			if typeof(res.commentCount) == "number" then
				self._totalCount = math.max(0, math.floor(res.commentCount))
			else
				self._totalCount = self._totalCount + 1
			end
			notifyTotalCount()
			list.CanvasPosition = Vector2.zero
			rebind()
		end)
	end))

	table.insert(self._conns, list:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if isNearPrefetchEdge() then
			loadMore()
		end
	end))

	local layout = list:FindFirstChildOfClass("UIListLayout")
	if layout then
		table.insert(self._conns, layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			list.CanvasSize = UDim2.fromOffset(0, math.max(layout.AbsoluteContentSize.Y, 1))
		end))
	end

	function self:open()
		self._open = true
		drawerFrame.Visible = true
		layoutList(drawerFrame, list)
		if #self._items == 0 then
			resetAndLoad()
		end
	end

	function self:close()
		self._open = false
		drawerFrame.Visible = false
	end

	function self:toggle()
		if self._open then
			self:close()
		else
			self:open()
		end
	end

	function self:isOpen(): boolean
		return self._open
	end

	function self:setVideo(videoId: string)
		if self._videoId == videoId then
			return
		end
		self._videoId = videoId
		self._totalCount = 0
		-- 每条新视频默认最高赞排序
		self._sortMode = DEFAULT_SORT
		applySortVisual()
		resetAndLoad()
	end

	function self:setTotalCount(count: number)
		self._totalCount = math.max(0, math.floor(tonumber(count) or 0))
		refreshTitle()
	end

	--[[
		外层角标同步（发评成功时回调）
		@param cb ((number) -> ())? - 新评论总数；传 nil 清空
	]]
	function self:setOnTotalCountChanged(cb: ((number) -> ())?)
		self._onTotalCountChanged = cb
	end

	function self:destroy()
		self._gen += 1
		for _, c in ipairs(self._conns) do
			c:Disconnect()
		end
		table.clear(self._conns)
		self._onTotalCountChanged = nil
		self:close()
	end

	return self :: Drawer
end

return CommentDrawer
