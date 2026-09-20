--[[
	Module: PlayerController
	Description: VideoFrame 主槽/预载槽；+1/+2/−1 固定前瞻；命中则换槽提升免重载；加载态仅未就绪
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14

	主槽比例：底座 9:16；播后按 Resolution 宽度铺满、高度留白（VideoContainer ClipsDescendants）
	预载命中：交换主槽与预载槽布局（复用已 IsLoaded 的 VideoFrame），不重赋 Video。
	预载优先级：+1 → +2 → −1（history 仅补空位，不挤掉 +2）。
	warmStart：Open 时提前灌主槽（含训练预览帧交接），列表到达后同 id 免重载。
	onLoadingChanged：仅 cold miss / 提升时未就绪才 true。
]]

local Constants = require(script.Parent.Parent.Shared.Constants)

local PlayerController = {}

local LOADING_TIMEOUT_SEC = 8

export type Controller = {
	setFeed: (self: Controller, feed: { any }, preferId: any) -> (),
	warmStart: (self: Controller, item: any) -> (),
	getIndex: (self: Controller) -> number,
	getCurrent: (self: Controller) -> any?,
	getMainFrame: (self: Controller) -> VideoFrame,
	getPlayedSec: (self: Controller) -> number,
	next: (self: Controller) -> any?,
	prev: (self: Controller) -> any?,
	setPaused: (self: Controller, paused: boolean) -> (),
	togglePause: (self: Controller) -> boolean,
	isPaused: (self: Controller) -> boolean,
	destroy: (self: Controller) -> (),
	onIndexChanged: ((item: any, index: number) -> ())?,
	onLoadingChanged: ((loading: boolean) -> ())?,
}

--[[
	按片源分辨率：宽度铺满底座，高度按比例（不足则上下留白）
	@param frame VideoFrame - 主槽
	@return boolean - 是否已适配
]]
local function applyFitWidth(frame: VideoFrame): boolean
	local ok, res = pcall(function()
		return frame.Resolution
	end)
	if not ok or typeof(res) ~= "Vector2" then
		return false
	end
	if res.X <= 0 or res.Y <= 0 then
		return false
	end
	local videoAspect = res.X / res.Y
	local boardAspect = Constants.BOARD_ASPECT
	local heightScale = boardAspect / videoAspect
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.new(1, 0, heightScale, 0)
	return true
end

--[[
	帧是否已加载
	@param frame VideoFrame - 目标帧
	@return boolean - IsLoaded
]]
local function isFrameLoaded(frame: VideoFrame): boolean
	local loaded = false
	pcall(function()
		loaded = frame.IsLoaded == true
	end)
	return loaded
end

--[[
	创建隐藏预载槽（预制体缺 PreloadVideo3 时补齐）
	@param parent Instance - 父级
	@param name string - 实例名
	@return VideoFrame
]]
local function createPreloadSlot(parent: Instance, name: string): VideoFrame
	local frame = Instance.new("VideoFrame")
	frame.Name = name
	frame.Size = UDim2.fromOffset(1, 1)
	frame.Position = UDim2.fromOffset(-100, -100)
	frame.Visible = false
	frame.Looped = true
	frame.Volume = 0
	frame.Parent = parent
	return frame
end

--[[
	创建播放控制器
	@param mainVideo VideoFrame - 初始主槽
	@param preload1 VideoFrame - 预载1（优先 +1）
	@param preload2 VideoFrame - 预载2（优先 +2）
	@param preload3 VideoFrame? - 预载3（优先 −1；缺省则自动创建）
	@return Controller
]]
function PlayerController.new(
	mainVideo: VideoFrame,
	preload1: VideoFrame,
	preload2: VideoFrame,
	preload3: VideoFrame?
): Controller
	local self = {} :: any
	self._feed = {} :: { any }
	self._index = 1
	self._history = {} :: { number }
	self._switching = false
	self._lastSwitch = 0
	self._playStart = os.clock()
	self._preloadGen = 0
	self._loadGen = 0
	self._loadConn = nil :: RBXScriptConnection?
	self._paused = false
	self.onIndexChanged = nil
	self.onLoadingChanged = nil

	-- 可变引用：promote 后主槽/预载槽指针互换
	local main = mainVideo
	local preloadParent = preload1.Parent or mainVideo.Parent
	local slot3 = preload3
	if not slot3 or not slot3:IsA("VideoFrame") then
		slot3 = createPreloadSlot(preloadParent or mainVideo, "PreloadVideo3")
	end
	local slots = { preload1, preload2, slot3 }
	local videoContainer = mainVideo.Parent

	local function layoutAsPreload(frame: VideoFrame)
		frame.Visible = false
		frame.Size = UDim2.fromOffset(1, 1)
		frame.Position = UDim2.fromOffset(-100, -100)
		frame.AnchorPoint = Vector2.new(0, 0)
		pcall(function()
			frame.Volume = 0
		end)
		if preloadParent then
			frame.Parent = preloadParent
		end
	end

	local function layoutAsMain(frame: VideoFrame)
		if videoContainer then
			frame.Parent = videoContainer
		end
		frame.Visible = true
		frame.ZIndex = 1
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(1, 1)
		pcall(function()
			frame.Volume = 1
		end)
	end

	-- 初始预载槽布局
	for _, slot in ipairs(slots) do
		layoutAsPreload(slot)
	end

	--[[
		暂停全部预载槽
	]]
	local function pausePreloadSlots()
		for _, frame in ipairs(slots) do
			pcall(function()
				frame:Pause()
			end)
		end
	end

	--[[
		通知加载态
		@param loading boolean - 是否加载中
	]]
	local function setLoading(loading: boolean)
		if self.onLoadingChanged then
			self.onLoadingChanged(loading)
		end
	end

	--[[
		监听主槽加载完成（仅未就绪时显示 Loading）
		@param showLoading boolean - 是否先展示 Loading
	]]
	local function watchMainLoaded(showLoading: boolean)
		self._loadGen += 1
		local gen = self._loadGen
		if self._loadConn then
			self._loadConn:Disconnect()
			self._loadConn = nil
		end

		local function finish()
			if gen ~= self._loadGen then
				return
			end
			if self._loadConn then
				self._loadConn:Disconnect()
				self._loadConn = nil
			end
			applyFitWidth(main)
			setLoading(false)
		end

		if isFrameLoaded(main) then
			finish()
			return
		end

		if showLoading then
			setLoading(true)
		end

		self._loadConn = main:GetPropertyChangedSignal("IsLoaded"):Connect(function()
			if gen ~= self._loadGen then
				return
			end
			if isFrameLoaded(main) then
				finish()
			end
		end)

		task.delay(LOADING_TIMEOUT_SEC, function()
			if gen == self._loadGen then
				finish()
			end
		end)
	end

	--[[
		主槽分辨率适配（不触发 Loading）
		@param frame VideoFrame - 主槽
	]]
	local function adaptMainSize(frame: VideoFrame)
		if applyFitWidth(frame) then
			return
		end
		local conn: RBXScriptConnection? = nil
		local gen = (frame:GetAttribute("AdaptGen") :: number?) or 0
		gen += 1
		frame:SetAttribute("AdaptGen", gen)
		local myGen = gen
		conn = frame:GetPropertyChangedSignal("Resolution"):Connect(function()
			if frame:GetAttribute("AdaptGen") ~= myGen then
				if conn then
					conn:Disconnect()
				end
				return
			end
			if applyFitWidth(frame) and conn then
				conn:Disconnect()
				conn = nil
			end
		end)
		task.spawn(function()
			for _ = 1, 30 do
				if frame:GetAttribute("AdaptGen") ~= myGen then
					return
				end
				if applyFitWidth(frame) then
					if conn then
						conn:Disconnect()
					end
					return
				end
				task.wait(0.1)
			end
		end)
	end

	--[[
		设片源
		@param frame VideoFrame - 目标帧
		@param videoId number - 资产 Id
		@param asMain boolean - 是否作为主槽（出声 + 加载监听）
		@param forceReload boolean - 同 URI 是否强制重赋（一般 false）
	]]
	local function setVideo(frame: VideoFrame, videoId: number, asMain: boolean, forceReload: boolean?)
		local uri = "rbxassetid://" .. tostring(videoId)
		local cur = ""
		pcall(function()
			cur = tostring((frame :: any).Video or "")
		end)
		if forceReload or cur ~= uri then
			pcall(function()
				(frame :: any).Video = uri
			end)
		end
		pcall(function()
			frame.Volume = if asMain then 1 else 0
		end)
		pcall(function()
			frame:Play()
		end)
		if not asMain then
			return
		end
		watchMainLoaded(true)
		adaptMainSize(frame)
	end

	--[[
		主槽已是目标片：不重赋，仅恢复播放/加载态
		@param item any - VideoItem
	]]
	local function resumeMainAsCurrent(item: any)
		main:SetAttribute("VideoBizId", item.id)
		pcall(function()
			main.Volume = 1
			main:Play()
		end)
		if isFrameLoaded(main) then
			self._loadGen += 1
			if self._loadConn then
				self._loadConn:Disconnect()
				self._loadConn = nil
			end
			setLoading(false)
			adaptMainSize(main)
		else
			watchMainLoaded(true)
			adaptMainSize(main)
		end
	end

	--[[
		将预载槽提升为主槽（交换布局与引用，不重赋 Video）
		@param slot VideoFrame - 已缓冲的预载帧
		@param slotIndex number - slots 下标
		@return boolean - 提升后是否已 IsLoaded
	]]
	local function promoteSlot(slot: VideoFrame, slotIndex: number): boolean
		local oldMain = main
		local oldBiz = oldMain:GetAttribute("VideoBizId")
		local loaded = isFrameLoaded(slot)

		layoutAsPreload(oldMain)
		pcall(function()
			oldMain:Pause()
		end)
		oldMain:SetAttribute("VideoBizId", oldBiz)

		layoutAsMain(slot)
		pcall(function()
			slot.Volume = 1
			slot:Play()
		end)

		main = slot
		slots[slotIndex] = oldMain

		-- 名称便于调试；逻辑以引用为准
		pcall(function()
			main.Name = "MainVideo"
			oldMain.Name = "PreloadVideo" .. tostring(slotIndex)
		end)

		return loaded
	end

	--[[
		灌入预载目标（立即；可跳过仍匹配的槽）
		@param uniq {any} - 最多 #slots 条，顺序即槽位语义
	]]
	local function applyPreloadTargets(uniq: { any })
		for s = 1, #slots do
			local item = uniq[s]
			local frame = slots[s]
			if item then
				if frame:GetAttribute("VideoBizId") == item.id and isFrameLoaded(frame) then
					-- 已就绪，保持
				else
					setVideo(frame, item.videoId, false, false)
					frame:SetAttribute("VideoBizId", item.id)
				end
				pcall(function()
					frame:Play()
				end)
			else
				frame:SetAttribute("VideoBizId", nil)
				pcall(function()
					frame:Pause()
				end)
			end
		end
	end

	--[[
		收集邻接目标：固定 +1 → +2 → −1；history 仅补空位
		@return {any}
	]]
	local function collectNeighborTargets(): { any }
		local feed = self._feed
		local n = #feed
		local i = self._index
		if n == 0 then
			return {}
		end

		local function at(offset: number): any?
			local idx = ((i - 1 + offset) % n) + 1
			return feed[idx]
		end

		local curId = feed[i] and feed[i].id
		local seen = {}
		local uniq = {}

		local function tryAdd(item: any)
			if not item or item.id == curId or seen[item.id] then
				return
			end
			seen[item.id] = true
			table.insert(uniq, item)
		end

		-- 连刷关键路径：前方两条优先于回退
		tryAdd(at(1))
		tryAdd(at(2))
		tryAdd(at(-1))

		local hist = self._history[#self._history]
		if hist and feed[hist] and #uniq < #slots then
			tryAdd(feed[hist])
		end

		return uniq
	end

	--[[
		调度邻接预载：+1/+2/−1 立即；停稳后再确认一遍
	]]
	local function schedulePreload()
		self._preloadGen += 1
		local gen = self._preloadGen
		local feed = self._feed
		if #feed == 0 then
			return
		end
		local uniq = collectNeighborTargets()
		applyPreloadTargets(uniq)

		local farIdle = Constants.PRELOAD_IDLE_SEC
		if farIdle > 0 then
			task.delay(farIdle, function()
				if gen ~= self._preloadGen or self._switching then
					return
				end
				applyPreloadTargets(collectNeighborTargets())
			end)
		end
	end

	--[[
		切到指定下标
		@param newIndex number - 下标
		@param pushHistory boolean - 是否压栈
		@return any? - 当前条目
	]]
	local function goTo(newIndex: number, pushHistory: boolean): any?
		local feed = self._feed
		local n = #feed
		if n == 0 then
			return nil
		end
		self._switching = true
		self._preloadGen += 1
		pausePreloadSlots()
		if pushHistory then
			table.insert(self._history, self._index)
		end
		self._index = ((newIndex - 1) % n) + 1
		local item = feed[self._index]
		self._paused = false

		-- 主槽已是目标（warmStart / 交接）：免重载
		if main:GetAttribute("VideoBizId") == item.id then
			resumeMainAsCurrent(item)
		else
			local promoted = false
			local promotedLoaded = false
			for s, frame in ipairs(slots) do
				if frame:GetAttribute("VideoBizId") == item.id then
					promotedLoaded = promoteSlot(frame, s)
					promoted = true
					main:SetAttribute("VideoBizId", item.id)
					break
				end
			end

			if promoted then
				if promotedLoaded then
					self._loadGen += 1
					if self._loadConn then
						self._loadConn:Disconnect()
						self._loadConn = nil
					end
					setLoading(false)
					adaptMainSize(main)
					pcall(function()
						main:Play()
					end)
				else
					-- 预载命中但尚未 IsLoaded：等加载，不重赋 Video
					watchMainLoaded(true)
					adaptMainSize(main)
				end
			else
				main:SetAttribute("VideoBizId", item.id)
				setVideo(main, item.videoId, true, false)
			end
		end

		self._playStart = os.clock()
		self._lastSwitch = os.clock()
		self._switching = false
		if self.onIndexChanged then
			self.onIndexChanged(item, self._index)
		end
		schedulePreload()
		return item
	end

	--[[
		Open 阶段提前灌主槽（列表未到也可开始解码；同 URI 不重赋）
		@param item any - VideoItem（需 id / videoId）
	]]
	function self:warmStart(item: any)
		if typeof(item) ~= "table" or item.videoId == nil or item.id == nil then
			return
		end
		main:SetAttribute("VideoBizId", item.id)
		setVideo(main, item.videoId, true, false)
		self._playStart = os.clock()
	end

	--[[
		设置片单
		@param feed {any} - 序列
		@param preferId string|boolean? - 业务 id 定位；false=强制从第一条；nil=尽量保当前
	]]
	function self:setFeed(feed: { any }, preferId: any)
		local keepId: string? = nil
		if preferId == false then
			keepId = nil
		elseif typeof(preferId) == "string" and preferId ~= "" then
			keepId = preferId
		elseif self._feed[self._index] then
			keepId = self._feed[self._index].id
		elseif main:GetAttribute("VideoBizId") ~= nil then
			-- warmStart 已灌主槽但尚无 feed：用主槽业务 id 定位
			local biz = main:GetAttribute("VideoBizId")
			if typeof(biz) == "string" then
				keepId = biz
			end
		end
		self._feed = feed
		self._history = {}
		local idx = 1
		if typeof(keepId) == "string" and keepId ~= "" then
			for i, item in ipairs(feed) do
				if item and item.id == keepId then
					idx = i
					break
				end
			end
		end
		if #feed > 0 then
			goTo(idx, false)
		else
			setLoading(false)
		end
	end

	function self:getIndex(): number
		return self._index
	end

	function self:getCurrent(): any?
		return self._feed[self._index]
	end

	function self:getMainFrame(): VideoFrame
		return main
	end

	function self:getPlayedSec(): number
		return math.max(0, os.clock() - self._playStart)
	end

	function self:next(): any?
		if #self._feed == 0 then
			return nil
		end
		return goTo(self._index + 1, true)
	end

	function self:prev(): any?
		local last = table.remove(self._history)
		if last then
			return goTo(last, false)
		end
		if #self._feed == 0 then
			return nil
		end
		return goTo(self._index - 1, false)
	end

	function self:setPaused(paused: boolean)
		self._paused = paused == true
		if self._paused then
			pcall(function()
				main:Pause()
			end)
		else
			pcall(function()
				main:Play()
			end)
		end
	end

	function self:togglePause(): boolean
		self:setPaused(not self._paused)
		return self._paused
	end

	function self:isPaused(): boolean
		return self._paused == true
	end

	function self:destroy()
		self._preloadGen += 1
		self._loadGen += 1
		self._paused = false
		if self._loadConn then
			self._loadConn:Disconnect()
			self._loadConn = nil
		end
		self.onIndexChanged = nil
		self.onLoadingChanged = nil
		pcall(function()
			main:Pause()
		end)
		pausePreloadSlots()
	end

	return self :: Controller
end

return PlayerController
