--[[
	Module: UIMgr/Award
	Description: UIMgr 子模块 — 奖励格展示与角色图标（由 init 合并导出至 Utils.UIMgr）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-04

	功能：
	- SetAward：按物品类型填充奖励格（图标/数量/等级/视口/碎片）
	- SetRoleIcon：按英雄 Role 切换 RoleIcon 容器内子 Gui

	与 init / Gradients：
	- 业务只调 Utils.UIMgr，不要直接 require 本文件
	- SetAward 在运行时查 façade 的 SetHeroXyd（Gradients 合并后才有）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.SetAward(frame, itemId, count, lv, fakexyd, shardNum)
		UIMgr.SetRoleIcon(roleIcon, heroCfg.Role)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local MathMgr = Utils.MathMgr
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local ViewportFrameModule = Utils.ViewportFrameModule
local ShowDetail = Utils.ShowDetail
local TranslationHelper = Utils.TranslationHelper
local ResourceUtil = Utils.ResourceUtil
-- 延迟缓存：避免 UIMgr → AddListen → UIanima → UIMgr 在模块加载期成环；业务内用短名
local AddListen = nil

-- 称号图标相对 Prefab 放大；其它类型不改 Size，沿用格子 Prefab
local TITLE_ICON_SIZE = UDim2.new(1.8, 0, 1.8, 0)

local UI_ELEMENT_NAMES = {
	ICON = "Icon",
	COUNT = "Count",
	REQ_LV = "ReqLv",
	LEVEL_STR = "LevelStr",
	VIEWPORT_FRAME = "ViewportFrame",
	ROLE_ICON = "RoleIcon",
	ZH_NAME = "ZhName",
	SHARD_ICON = "ShardIcon",
	BUTTON = "Button",
}

--[[
	绑定到 UIMgr façade（init 调用）。SetAward 运行时经此表查找 SetHeroXyd / SetRoleIcon。
	@param UIMgr { SetRoleIcon: (Frame, any) -> (), SetHeroXyd: (Frame, number) -> () } - façade；SetHeroXyd 由 Gradients 合并后才有
	@return { SetRoleIcon: (Frame, any) -> (), SetAward: (Frame, number, number, number?, number?, number?, boolean?) -> () } - 待合并的公开 API
]]
return function(UIMgr)
	local Award = {}

	--[[
		设置英雄类型的奖励显示
		@param _itemID number - 英雄物品 ID
		@param _lv number - 等级，缺省按 1
		@param _shardNum number? - 碎片数量；有值视为重复获得
		@param Icon ImageLabel? - 图标标签
		@param Count TextLabel? - 数量标签
		@param ReqLv TextLabel? - 需求等级标签
		@param LevelStr TextLabel? - 等级字符串标签
		@param ViewportFrame Frame? - 视口框架
		@param RoleIcon Frame? - 角色图标框架
		@param ShardIcon ImageLabel? - 碎片图标标签
		@return () - 无返回值
	]]
	local function _setHeroAward(
		_itemID: number,
		_lv: number,
		_shardNum: number?,
		Icon: ImageLabel?,
		Count: TextLabel?,
		ReqLv: TextLabel?,
		LevelStr: TextLabel?,
		ViewportFrame: Frame?,
		RoleIcon: Frame?,
		ShardIcon: ImageLabel?
	): ()
		if not _lv then
			_lv = 1
		end

		if ViewportFrame then
			ViewportFrame.Visible = true
			local model = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Anime, _itemID)
			if model then
				ViewportFrameModule.new(ViewportFrame, model, model:GetAttribute("Head") or Vector3.new(0, 0, 0))
			end
		end

		if Icon then
			Icon.Visible = false
		end

		if ReqLv then
			ReqLv.Visible = false
		end

		if RoleIcon then
			RoleIcon.Visible = true
			local heroCfg = CfgFind.FindCfgByID(_itemID)
			if heroCfg then
				UIMgr.SetRoleIcon(RoleIcon, heroCfg.Role)
			end
		end

		if ShardIcon then
			if _shardNum then
				-- 重复获得的碎片
				if LevelStr then
					LevelStr.Visible = false
				end
				ShardIcon.Visible = true
				if Count then
					Count.Visible = true
					TranslationHelper.SetRawText(Count, "x" .. _shardNum)
				end
			else
				-- 第一次获得英雄
				if Count then
					Count.Visible = false
				end
				ShardIcon.Visible = false
				if LevelStr then
					LevelStr.Visible = true
					TranslationHelper.SetText(LevelStr, "当前等级", {_lv})
				end
			end
		else
			-- 第一次获得英雄（没有碎片图标）
			if Count then
				Count.Visible = false
			end
			if LevelStr then
				LevelStr.Visible = true
				TranslationHelper.SetText(LevelStr, "当前等级", {_lv})
			end
		end
	end

	--[[
		设置英雄碎片类型的奖励显示
		@param cfg { HeroID: number } - 碎片配置，须含 HeroID
		@param _count number - 碎片数量
		@param Icon ImageLabel? - 图标标签
		@param Count TextLabel? - 数量标签
		@param ReqLv TextLabel? - 需求等级标签
		@param LevelStr TextLabel? - 等级字符串标签
		@param ViewportFrame Frame? - 视口框架
		@param RoleIcon Frame? - 角色图标框架
		@param ShardIcon ImageLabel? - 碎片图标标签
		@return () - 无返回值
	]]
	local function _setHeroShardAward(
		cfg: { HeroID: number },
		_count: number,
		Icon: ImageLabel?,
		Count: TextLabel?,
		ReqLv: TextLabel?,
		LevelStr: TextLabel?,
		ViewportFrame: Frame?,
		RoleIcon: Frame?,
		ShardIcon: ImageLabel?
	): ()
		local heroCfg = CfgFind.FindCfgByID(cfg.HeroID, EnumMgr.ItemType.Hero)
		if not heroCfg then
			return
		end

		if ViewportFrame then
			ViewportFrame.Visible = true
			local model = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Anime, cfg.HeroID)
			if model then
				ViewportFrameModule.new(ViewportFrame, model, model:GetAttribute("Head") or Vector3.new(0, 0, 0))
			end
		end

		if Icon then
			Icon.Visible = false
		end

		if ReqLv then
			ReqLv.Visible = false
		end

		if RoleIcon then
			RoleIcon.Visible = true
			UIMgr.SetRoleIcon(RoleIcon, heroCfg.Role)
		end

		if ShardIcon and _count then
			if LevelStr then
				LevelStr.Visible = false
			end
			ShardIcon.Visible = true
			if Count then
				Count.Visible = true
				TranslationHelper.SetRawText(Count, "x" .. _count)
			end
		end
	end

	--[[
		设置装备类型的奖励显示
		@param cfg { Icon: string?, RequireLv: number? } - 装备配置，只读 Icon / RequireLv
		@param _lv number - 强化等级，缺省 0
		@param Icon ImageLabel? - 图标标签
		@param Count TextLabel? - 数量标签
		@param ReqLv TextLabel? - 需求等级标签
		@param LevelStr TextLabel? - 等级字符串标签
		@param ViewportFrame Frame? - 视口框架
		@param RoleIcon Frame? - 角色图标框架
		@param ShardIcon ImageLabel? - 碎片图标标签
		@return () - 无返回值
	]]
	local function _setEquipmentAward(
		cfg: { Icon: string?, RequireLv: number? },
		_lv: number,
		Icon: ImageLabel?,
		Count: TextLabel?,
		ReqLv: TextLabel?,
		LevelStr: TextLabel?,
		ViewportFrame: Frame?,
		RoleIcon: Frame?,
		ShardIcon: ImageLabel?
	): ()
		if not _lv then
			_lv = 0
		end

		if ViewportFrame then
			ViewportFrame.Visible = false
		end

		if Icon then
			Icon.Visible = true
			if cfg.Icon then
				Icon.Image = "rbxassetid://" .. cfg.Icon
			end
		end

		if Count then
			Count.Visible = false
		end

		if ReqLv then
			ReqLv.Visible = true
			TranslationHelper.SetText(ReqLv, "当前等级", {cfg.RequireLv})
		end

		if LevelStr then
			if _lv > 0 then
				LevelStr.Visible = true
				TranslationHelper.SetRawText(LevelStr, "+" .. _lv)
			else
				LevelStr.Visible = false
			end
		end

		if RoleIcon then
			RoleIcon.Visible = false
		end

		if ShardIcon then
			ShardIcon.Visible = false
		end
	end

	--[[
		设置其他类型的奖励显示
		@param cfg { Icon: string?, tp: number? } - 物品配置，只读 Icon / tp
		@param _count number - 数量；>0 时显示
		@param Icon ImageLabel? - 图标标签
		@param Count TextLabel? - 数量标签
		@param ReqLv TextLabel? - 需求等级标签
		@param LevelStr TextLabel? - 等级字符串标签
		@param ViewportFrame Frame? - 视口框架
		@param RoleIcon Frame? - 角色图标框架
		@param ShardIcon ImageLabel? - 碎片图标标签
		@return () - 无返回值
	]]
	local function _setOtherAward(
		cfg: { Icon: string?, tp: number? },
		_count: number,
		Icon: ImageLabel?,
		Count: TextLabel?,
		ReqLv: TextLabel?,
		LevelStr: TextLabel?,
		ViewportFrame: Frame?,
		RoleIcon: Frame?,
		ShardIcon: ImageLabel?
	): ()
		if ViewportFrame then
			ViewportFrame.Visible = false
		end

		if Icon then
			Icon.Visible = true
			if cfg.Icon then
				Icon.Image = "rbxassetid://" .. cfg.Icon
			end

			if cfg.tp == EnumMgr.ItemType.Title then
				Icon.Size = TITLE_ICON_SIZE
			end
		end

		if Count then
			if _count and _count > 0 then
				Count.Visible = true
				TranslationHelper.SetRawText(Count, "x" .. MathMgr.getNumStr(_count))
			else
				Count.Visible = false
			end
		end

		if ReqLv then
			ReqLv.Visible = false
		end

		if LevelStr then
			LevelStr.Visible = false
		end

		if RoleIcon then
			RoleIcon.Visible = false
		end

		if ShardIcon then
			ShardIcon.Visible = false
		end
	end

	--[[
		按 hero cfg.Role 在 RoleIcon 容器内切换同名子 Gui 可见性
		@param RoleIcon Frame - 角色图标容器（子级 Name 与 Role 枚举值字符串一致）
		@param role any - 英雄配置 Role 字段（number/string，无效时隐藏全部子级）
		@return () - 无返回值
	]]
	function Award.SetRoleIcon(RoleIcon: Frame, role: any): ()
		if not RoleIcon then
			return
		end
		local roleKey = role ~= nil and tostring(role) or ""
		for _, child in RoleIcon:GetChildren() do
			if child:IsA("GuiObject") then
				child.Visible = roleKey ~= "" and child.Name == roleKey
			end
		end
	end

	--[[
		设置奖励显示
		@param _frame Frame - UI 框架
		@param _itemID number - 物品ID
		@param _count number - 数量
		@param _lv number? - 等级（可选，英雄/装备强化等级）
		@param _fakexyd number? - 假稀有度（可选，主要用于UI显示）
		@param _shardNum number? - 碎片数量（可选，只用于英雄）
		@param _isTips boolean? - 是否显示提示（可选，默认 true）
		@return () - 无返回值
	]]
	function Award.SetAward(
		_frame: Frame,
		_itemID: number,
		_count: number,
		_lv: number?,
		_fakexyd: number?,
		_shardNum: number?,
		_isTips: boolean?
	): ()
		-- 获取 UI 元素
		local Icon: ImageLabel? = _frame:FindFirstChild(UI_ELEMENT_NAMES.ICON) :: ImageLabel?
		local Count: TextLabel? = _frame:FindFirstChild(UI_ELEMENT_NAMES.COUNT) :: TextLabel?
		local ReqLv: TextLabel? = _frame:FindFirstChild(UI_ELEMENT_NAMES.REQ_LV) :: TextLabel?
		local LevelStr: TextLabel? = _frame:FindFirstChild(UI_ELEMENT_NAMES.LEVEL_STR) :: TextLabel?
		local ViewportFrame: Frame? = _frame:FindFirstChild(UI_ELEMENT_NAMES.VIEWPORT_FRAME) :: Frame?
		local RoleIcon: Frame? = _frame:FindFirstChild(UI_ELEMENT_NAMES.ROLE_ICON) :: Frame?
		local ZhName: Frame? = _frame:FindFirstChild(UI_ELEMENT_NAMES.ZH_NAME) :: Frame?
		local ShardIcon: ImageLabel? = _frame:FindFirstChild(UI_ELEMENT_NAMES.SHARD_ICON) :: ImageLabel?

		-- 获取配置
		local cfg = CfgFind.FindCfgByID(_itemID)
		if not cfg then
			return
		end

		-- 设置稀有度
		local Xyd = _fakexyd or cfg["xyd"]
		if Xyd and cfg.tp == EnumMgr.ItemType.Hero then
			Xyd = tonumber(Xyd)
			if Xyd then
				UIMgr.SetHeroXyd(_frame, Xyd)
			end
		end

		-- 设置中文名称
		if ZhName then
			TranslationHelper.SetText(ZhName, cfg.ZhName)
		end

		-- 根据物品类型设置不同的显示
		if cfg["tp"] == EnumMgr.ItemType.Hero then
			_setHeroAward(_itemID, _lv or 1, _shardNum, Icon, Count, ReqLv, LevelStr, ViewportFrame, RoleIcon, ShardIcon)
		elseif cfg["tp"] == EnumMgr.ItemType.HeroShard then
			_setHeroShardAward(cfg, _count, Icon, Count, ReqLv, LevelStr, ViewportFrame, RoleIcon, ShardIcon)
		elseif cfg["tp"] == EnumMgr.ItemType.Equipment then
			_setEquipmentAward(cfg, _lv or 0, Icon, Count, ReqLv, LevelStr, ViewportFrame, RoleIcon, ShardIcon)
		else
			_setOtherAward(cfg, _count, Icon, Count, ReqLv, LevelStr, ViewportFrame, RoleIcon, ShardIcon)
		end

		-- 设置点击详情
		if _isTips == nil then
			_isTips = true
		end

		if _isTips then
			if cfg.tp == EnumMgr.ItemType.Item or cfg.tp == EnumMgr.ItemType.UseItem then
				local parentFrame = _frame.Parent
				if parentFrame then
					local Button: ImageButton? = parentFrame:FindFirstChild(UI_ELEMENT_NAMES.BUTTON) :: ImageButton?
					if Button then
						-- 延迟缓存 AddListen，避免模块加载期循环引用；禁止 Utils.AddListen. 链式
						if not AddListen then
							AddListen = Utils.AddListen
						end
						AddListen.AddMouseClick(Button, function()
							local data = {
								id = _itemID,
								onlyID = _itemID,
							}
							ShowDetail.ShowDetailByData(data, _frame, "通用物品详情", true)
						end, _frame)
					end
				end
			end
		end
	end

	return Award
end
