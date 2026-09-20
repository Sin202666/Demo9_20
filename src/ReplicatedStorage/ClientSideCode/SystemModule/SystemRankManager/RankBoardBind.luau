--[[
	Module: RankBoardBind
	Description: 客户端排行榜格子绑定（克隆 RankTemp、表头文案、控件引用）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	职责（相对 init / Prepare / Refresh）：
	- 遍历 场景/*/功能/排行榜 下已登记 Board，克隆格子并缓存 SlotWidgets
	- 绑定表头、RankTitle（翻译 Key 必须在本文件调用处写字面量，禁止 KEYS 表）与同级 Icon
	- 不读 workspace 缓存、不拉玩家名/头像（Refresh 负责）

	由 SystemRankManager 内部 require(script.RankBoardBind)；业务请走 Utils.SystemRankManager。
	场景约定与 Init 流程见同目录 init.luau 文件头。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UIMgr = Utils.UIMgr
local TranslationHelper = Utils.TranslationHelper
local CollectionService = Utils.CollectionService
local RankConfig = Utils.RankConfig
local Log = Utils.Log

local RankBoardPrepare = require(script.Parent.RankBoardPrepare)

local RankBoardBind = {}

export type SlotWidgets = {
	frameRank: Frame,
	username: TextLabel?,
	rankLabel: TextLabel?,
	number: TextLabel?,
	portrait: ImageLabel?,
}

export type RankBoardRef = {
	rankName: string,
	main: GuiObject,
	slots: { [number]: SlotWidgets },
	myRank: SlotWidgets?,
}

-- ========================================
-- 常量定义
-- ========================================
local BOARD_STRUCT_WAIT_SEC = 8
local BOARD_PART_NAME = "Board"
local SURFACE_GUI_NAME = "SurfaceGui"
local CONTENT_NAME = "Content"
local MAIN_NAME = "Main"
local MY_RANK_NAME = "MyRank"
local TITLE_PART_NAME = "title"
local RANK_TITLE_NAME = "RankTitle"
local RANK_ICON_NAME = "Icon"
local RBX_ASSET_PREFIX = "rbxassetid://"
local STATIC_LOCALE_TAG = "本地化"
local HEADER_RANK_NAME = "排行榜-排名"
local HEADER_AMOUNT_NAME = "排行榜-数量"
local HEADER_PLAYER_NAME = "排行榜-玩家"
local MY_RANK_SLOT_NAME = "Self"
local SLOT_INNER_NAME = "Frame"
local USERNAME_NAME = "Username"
local RANK_LABEL_NAME = "Rank"
local NUMBER_NAME = "Number"
local PORTRAIT_NAME = "Portrait"
local BG_NAME = "BG"
local FEATURE_FOLDER_NAME = "功能"

-- ========================================
-- 私有函数
-- ========================================

--[[
	按名称取子实例，可选校验 ClassName

	@param parent Instance? - 父节点；nil 时直接返回 nil
	@param childName string - 子实例 Name
	@param className string? - 期望 ClassName；nil 时不校验类型
	@return Instance? - 匹配的子实例；未找到或类型不符时 nil
]]
local function _findChild(parent: Instance?, childName: string, className: string?): Instance?
	if not parent then
		return nil
	end
	local child = parent:FindFirstChild(childName)
	if not child then
		return nil
	end
	if className and not child:IsA(className) then
		return nil
	end
	return child
end

--[[
	Main / MyRank 是否可作为格子父级（Frame 或 ScrollingFrame；后者不是 Frame 子类）

	@param inst Instance - 待判断实例
	@return boolean - 可作为格子容器时 true
]]
local function _isSlotContainer(inst: Instance): boolean
	return inst:IsA("Frame") or inst:IsA("ScrollingFrame")
end

--[[
	按名称取子实例，先直子再后代

	@param parent Instance? - 父节点；nil 时直接返回 nil
	@param childName string - 实例 Name
	@param className string? - 期望 ClassName；nil 时不校验类型
	@return Instance? - 匹配实例；未找到时 nil
]]
local function _findByName(parent: Instance?, childName: string, className: string?): Instance?
	local direct = _findChild(parent, childName, className)
	if direct then
		return direct
	end
	if not parent then
		return nil
	end
	for _, desc in parent:GetDescendants() do
		if desc.Name == childName and (not className or desc:IsA(className)) then
			return desc
		end
	end
	return nil
end

--[[
	从格子 Frame 收集展示控件引用

	@param frameRank Frame - 名为名次的格子根 Frame
	@return SlotWidgets - 可能缺控件的引用表
]]
local function _collectSlotWidgets(frameRank: Frame): SlotWidgets
	local inner = _findChild(frameRank, SLOT_INNER_NAME) or frameRank
	local username = _findByName(inner, USERNAME_NAME, "TextLabel")
	if not username then
		username = _findByName(frameRank, USERNAME_NAME, "TextLabel")
	end
	local rankLabel = _findByName(inner, RANK_LABEL_NAME, "TextLabel")
	if not rankLabel then
		rankLabel = _findByName(frameRank, RANK_LABEL_NAME, "TextLabel")
	end
	local number = _findByName(inner, NUMBER_NAME, "TextLabel")
	if not number then
		number = _findByName(frameRank, NUMBER_NAME, "TextLabel")
	end
	local portrait = _findByName(inner, PORTRAIT_NAME, "ImageLabel")
	if not portrait then
		portrait = _findByName(frameRank, PORTRAIT_NAME, "ImageLabel")
	end
	return {
		frameRank = frameRank,
		username = username :: TextLabel?,
		rankLabel = rankLabel :: TextLabel?,
		number = number :: TextLabel?,
		portrait = portrait :: ImageLabel?,
	}
end

--[[
	定位 Board → SurfaceGui → Content

	@param boardModel Instance - 单个榜模型（如 Rank_N_Gold）
	@return Instance? - Content；结构不完整时 nil
]]
local function _findBoardContent(boardModel: Instance): Instance?
	local board = RankBoardPrepare.waitChild(boardModel, BOARD_PART_NAME, BOARD_STRUCT_WAIT_SEC)
	local surfaceGui = RankBoardPrepare.waitChild(board, SURFACE_GUI_NAME, BOARD_STRUCT_WAIT_SEC)
	return RankBoardPrepare.waitChild(surfaceGui, CONTENT_NAME, BOARD_STRUCT_WAIT_SEC)
end

--[[
	定位 title → SurfaceGui（RankTitle 与 Icon 的父级）

	@param boardModel Instance - 单个榜模型
	@return Instance? - title 上的 SurfaceGui；结构不完整时 nil
]]
local function _findTitleSurfaceGui(boardModel: Instance): Instance?
	local titlePart = RankBoardPrepare.waitChild(boardModel, TITLE_PART_NAME, BOARD_STRUCT_WAIT_SEC)
	return RankBoardPrepare.waitChild(titlePart, SURFACE_GUI_NAME, BOARD_STRUCT_WAIT_SEC)
end

--[[
	在 title SurfaceGui 下找名为 RankTitle 的标题控件（Name 只是实例名，不是翻译键）

	@param titleGui Instance - title/SurfaceGui
	@return Instance? - RankTitle TextLabel；未找到时 nil
]]
local function _findRankTitleLabel(titleGui: Instance): Instance?
	local rankTitle = RankBoardPrepare.waitChild(titleGui, RANK_TITLE_NAME, BOARD_STRUCT_WAIT_SEC)
	if rankTitle and rankTitle:IsA("TextLabel") then
		return rankTitle
	end
	return _findByName(titleGui, RANK_TITLE_NAME, "TextLabel")
end

--[[
	把配置中的 rbxassetid 规范成可赋给 Image 的 URI

	@param icon string - 完整 rbxassetid://... 或纯数字 ID
	@return string - rbxassetid:// 前缀的 URI
]]
local function _toImageUri(icon: string): string
	if string.sub(icon, 1, #RBX_ASSET_PREFIX) == RBX_ASSET_PREFIX then
		return icon
	end
	return RBX_ASSET_PREFIX .. icon
end

--[[
	把该榜 Icon 图片写入 title/SurfaceGui/Icon。未配置 icon 时隐藏控件。

	@param titleGui Instance - title 上的 SurfaceGui
	@param rankName string - 写榜键
	@return () - 无返回值
]]
local function _bindRankIcon(titleGui: Instance, rankName: string)
	local icon = RankConfig.GetRankIcon(rankName)
	local iconInst = titleGui:FindFirstChild(RANK_ICON_NAME)
	if not iconInst then
		if not icon then
			return
		end
		iconInst = RankBoardPrepare.waitChild(titleGui, RANK_ICON_NAME, BOARD_STRUCT_WAIT_SEC)
	end
	if not iconInst or not (iconInst:IsA("ImageLabel") or iconInst:IsA("ImageButton")) then
		iconInst = _findByName(titleGui, RANK_ICON_NAME, "ImageLabel")
			or _findByName(titleGui, RANK_ICON_NAME, "ImageButton")
	end
	if not iconInst then
		return
	end
	local imageGui = iconInst :: ImageLabel
	if not icon then
		imageGui.Visible = false
		return
	end
	imageGui.Image = _toImageUri(icon)
	imageGui.Visible = true
end

--[[
	给格子背景/数值上榜对应渐变；未配置渐变类型则跳过

	@param rankName string - 写榜键
	@param inst Instance? - 目标实例
	@return () - 无返回值
]]
local function _applyRankGradient(rankName: string, inst: Instance?)
	if not inst then
		return
	end
	local gradientType = RankConfig.RANK_GRADIENT_TYPES[rankName]
	if not gradientType then
		return
	end
	UIMgr.AddGradientColor(gradientType, inst)
end

--[[
	给 RankTitle 挂彩虹 ColorScroll（随时间变色）。AddGradientColor 会按 GradientAnimCfg 自动播。

	@param rankTitle Instance - 名为 RankTitle 的 TextLabel
	@return () - 无返回值
]]
local function _applyRankTitleGradient(rankTitle: Instance)
	UIMgr.AddGradientColor(RankConfig.RANK_TITLE_GRADIENT, rankTitle, true)
end

--[[
	把该榜标题文案写入 RankTitle。RankTitle 不得当作翻译 Key。
	新增一榜须在此增加字面量 SetText 分支（本地化禁止 KEYS 表 / 赋变量再传入）。

	@param rankTitle Instance - 名为 RankTitle 的 TextLabel
	@param rankName string - 写榜键
	@return () - 无返回值
]]
local function _bindRankTitleText(rankTitle: Instance, rankName: string)
	if CollectionService:HasTag(rankTitle, STATIC_LOCALE_TAG) then
		CollectionService:RemoveTag(rankTitle, STATIC_LOCALE_TAG)
	end
	if rankName == RankConfig.RANK_GOLD_NAME then
		TranslationHelper.SetText(rankTitle, "排行榜标题-金币")
		return
	end
	if rankName == RankConfig.RANK_TIME_NAME then
		TranslationHelper.SetText(rankTitle, "排行榜标题-时长")
		return
	end
	if rankName == RankConfig.RANK_ROBUX_NAME then
		TranslationHelper.SetText(rankTitle, "排行榜标题-罗宝")
		return
	end
	Log.warn("[SystemRankManager] 无标题文案映射:", rankName)
end

--[[
	绑定 Content 表头、RankTitle 文案与同级 Icon（Key 必须是调用处字面量）

	@param boardModel Instance - 单个榜模型
	@param content Instance - Content 节点
	@param rankName string - 写榜键，用于 RankTitle / Icon
	@return () - 无返回值
]]
local function _bindBoardStaticTexts(boardModel: Instance, content: Instance, rankName: string)
	local headerRank = _findChild(content, HEADER_RANK_NAME, "TextLabel")
	if headerRank then
		TranslationHelper.SetText(headerRank, "排行榜-排名")
	end
	local headerAmount = _findChild(content, HEADER_AMOUNT_NAME, "TextLabel")
	if headerAmount then
		TranslationHelper.SetText(headerAmount, "排行榜-数量")
	end
	local headerPlayer = _findChild(content, HEADER_PLAYER_NAME, "TextLabel")
	if headerPlayer then
		TranslationHelper.SetText(headerPlayer, "排行榜-玩家")
	end

	local titleGui = _findTitleSurfaceGui(boardModel)
	if not titleGui then
		return
	end
	local rankTitle = _findRankTitleLabel(titleGui)
	if rankTitle then
		_bindRankTitleText(rankTitle, rankName)
		_applyRankTitleGradient(rankTitle)
	end
	_bindRankIcon(titleGui, rankName)
end

--[[
	在容器上取已有格子，或克隆 RankTemp。
	Main 列表禁止把容器本身当格子（避免误用名为 Frame 的样例行）。

	@param rankTemp Frame - RankTemp 模板
	@param container GuiObject - Main 或 MyRank
	@param slotName string - 子格子 Name
	@param allowUseContainer boolean - true 时容器自身已是格子结构则直接用（MyRank）
	@return Frame? - 格子根 Frame；无模板且结构不符时 nil
]]
local function _ensureSlotFrame(
	rankTemp: Frame,
	container: GuiObject,
	slotName: string,
	allowUseContainer: boolean
): Frame?
	local existing = container:FindFirstChild(slotName)
	if existing and existing:IsA("Frame") then
		return existing
	end
	if allowUseContainer and container:FindFirstChild(SLOT_INNER_NAME) then
		return container
	end
	local frameRank = rankTemp:Clone()
	frameRank.Parent = container
	frameRank.Name = slotName
	return frameRank
end

--[[
	遍历各世界「功能/排行榜」下已登记的 Board 模型（大厅等 Folder/Model 均可）

	@param allWorldFolder Instance - workspace.场景
	@param onBoard (string, Instance) -> () - 写榜键与 Board 模型
	@return () - 无返回值
]]
local function _forEachBoardModel(allWorldFolder: Instance, onBoard: (string, Instance) -> ())
	for _, worldInst in allWorldFolder:GetChildren() do
		if not (worldInst:IsA("Model") or worldInst:IsA("Folder")) then
			continue
		end
		local featureFolder = worldInst:FindFirstChild(FEATURE_FOLDER_NAME)
		if not featureFolder then
			continue
		end
		local rankFolder = featureFolder:FindFirstChild(RankConfig.RANK_TEMP_FOLDER_NAME)
		if not rankFolder then
			continue
		end
		for _, boardModel in rankFolder:GetChildren() do
			if not (boardModel:IsA("Model") or boardModel:IsA("Folder")) then
				continue
			end
			local rankName = RankConfig.GetRankNameByBoard(boardModel.Name)
			if rankName then
				onBoard(rankName, boardModel)
			else
				Log.warn("[SystemRankManager] 未登记的榜板，已跳过:", boardModel.Name)
			end
		end
	end
end

--[[
	绑定单块榜板：表头、列表格、MyRank

	@param rankName string - 写榜键
	@param boardModel Instance - 场景 Board 模型
	@param rankTemp Frame - Shared RankTemp
	@param onPlaceholder (SlotWidgets, number) -> () - 列表格占位
	@param onMyRankInit (SlotWidgets) -> () - MyRank 初始未上榜
	@return RankBoardRef? - 绑定成功返回引用；结构不完整时 nil
]]
local function _bindSingleBoard(
	rankName: string,
	boardModel: Instance,
	rankTemp: Frame,
	onPlaceholder: (SlotWidgets, number) -> (),
	onMyRankInit: (SlotWidgets) -> ()
): RankBoardRef?
	local content = _findBoardContent(boardModel)
	if not content then
		Log.warn("[SystemRankManager] 榜板缺少 Board/SurfaceGui/Content:", boardModel:GetFullName())
		return nil
	end
	local mainInst = RankBoardPrepare.waitChild(content, MAIN_NAME, BOARD_STRUCT_WAIT_SEC)
	local main = if mainInst and _isSlotContainer(mainInst) then mainInst :: GuiObject else nil
	if not main then
		Log.warn(
			"[SystemRankManager] 榜板缺少 Content.Main:",
			boardModel:GetFullName(),
			if mainInst then mainInst.ClassName else "nil"
		)
		return nil
	end

	_bindBoardStaticTexts(boardModel, content, rankName)

	local slots: { [number]: SlotWidgets } = {}
	local slotCount = RankConfig.GetSlotCount(rankName)
	for i = 1, slotCount do
		local frameRank = _ensureSlotFrame(rankTemp, main, tostring(i), false)
		if not frameRank then
			continue
		end
		frameRank.LayoutOrder = i
		frameRank.Name = tostring(i)

		local widgets = _collectSlotWidgets(frameRank)
		onPlaceholder(widgets, i)
		local inner = _findChild(frameRank, SLOT_INNER_NAME)
		local bg = _findChild(inner, BG_NAME)
		_applyRankGradient(rankName, bg)
		_applyRankGradient(rankName, widgets.number)
		slots[i] = widgets
	end

	local myRankWidgets: SlotWidgets? = nil
	local myRankInst = _findChild(content, MY_RANK_NAME)
	local myRankContainer = if myRankInst and _isSlotContainer(myRankInst) then myRankInst :: GuiObject else nil
	if myRankContainer then
		local myRankFrame = _ensureSlotFrame(rankTemp, myRankContainer, MY_RANK_SLOT_NAME, true)
		if myRankFrame then
			myRankWidgets = _collectSlotWidgets(myRankFrame)
			onMyRankInit(myRankWidgets)
		end
	end

	return {
		rankName = rankName,
		main = main,
		slots = slots,
		myRank = myRankWidgets,
	}
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	初始化排行榜 UI 条目模板并缓存格子引用

	@param allWorldFolder Instance - workspace.场景
	@param rankTemp Frame - Shared RankTemp
	@param onPlaceholder (SlotWidgets, number) -> () - 列表格占位（名次色）
	@param onMyRankInit (SlotWidgets) -> () - MyRank 初始未上榜
	@return { RankBoardRef } - 已绑定的榜板；无板时为空表
]]
function RankBoardBind.initializeRankBoards(
	allWorldFolder: Instance,
	rankTemp: Frame,
	onPlaceholder: (SlotWidgets, number) -> (),
	onMyRankInit: (SlotWidgets) -> ()
): { RankBoardRef }
	local boardRefs: { RankBoardRef } = {}

	_forEachBoardModel(allWorldFolder, function(rankName: string, boardModel: Instance)
		local ref = _bindSingleBoard(rankName, boardModel, rankTemp, onPlaceholder, onMyRankInit)
		if ref then
			table.insert(boardRefs, ref)
		end
	end)

	if #boardRefs == 0 then
		Log.warn("[SystemRankManager] 未绑定任何榜板（检查 场景/*/功能/排行榜/Rank_N_* 与 RankConfig 映射）")
	end

	return boardRefs
end

return RankBoardBind
