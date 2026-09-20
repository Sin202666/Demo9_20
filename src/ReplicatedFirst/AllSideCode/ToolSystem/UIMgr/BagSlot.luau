--[[
	Module: UIMgr/BagSlot
	Description: UIMgr 子模块 — 背包格子皮肤（V1 仅 AwardStyle 填格；由 init 挂到 Utils.UIMgr.BagSlot）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- Bind(frame, vm, style?)：把 SlotVM 填进格子；默认 AwardStyle
	- Clear(frame, style?)：隐藏格子内 SetAward 约定节点
	- AwardStyle：走现有 SetAward（Icon / Count / ZhName / ViewportFrame 等）

	与 Award / GetData.BagView 的关系：
	- 只填格，不绑 Remote、不改 PlayerData.Bag
	- vm 由 GetData.BagView.ToSlotVM 提供（id/tp/count/onlyID/lock）
	- 皮肤由调用方传入 Bind，不做全局 SetStyle（避免多窗抢皮肤）
	- V1 不改 RewardWindow / 邮件 GuiScripts；HudStyle 二期再做

	加载方式（业务只经 Utils.UIMgr）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	使用示例：
		local vm = GetData.BagView.ToSlotVM(entry)
		UIMgr.BagSlot.Bind(frame, vm)
		UIMgr.BagSlot.Clear(frame)
		UIMgr.BagSlot.Bind(frame, vm, UIMgr.BagSlot.AwardStyle)
]]

local UI_ELEMENT_NAMES = {
	ICON = "Icon",
	COUNT = "Count",
	REQ_LV = "ReqLv",
	LEVEL_STR = "LevelStr",
	VIEWPORT_FRAME = "ViewportFrame",
	ROLE_ICON = "RoleIcon",
	ZH_NAME = "ZhName",
	SHARD_ICON = "ShardIcon",
}

--[[
	绑定到 UIMgr façade（init 在 Award 合并之后调用，以便使用 SetAward）

	@param UIMgr { SetAward: (Frame, number, number, number?, number?, number?, boolean?) -> () } - façade
	@return { Bind: (Frame, any, any?) -> (), Clear: (Frame, any?) -> (), AwardStyle: any } - BagSlot 命名空间
]]
return function(UIMgr)
	local AwardStyle = {}

	--[[
		隐藏 SetAward 约定子节点（不清销毁，便于下次 Bind）

		@param frame Frame - 格子框架
		@return () - 无返回值
	]]
	function AwardStyle.Clear(frame: Frame): ()
		if not frame then
			return
		end
		for _, childName in UI_ELEMENT_NAMES do
			local child = frame:FindFirstChild(childName)
			if child and child:IsA("GuiObject") then
				child.Visible = false
			end
		end
	end

	--[[
		用 SetAward 填格（节点约定与奖励格相同）

		@param frame Frame - 格子框架
		@param vm table - SlotVM，字段 id / count；缺 id 时视为 Clear
		@return () - 无返回值
	]]
	function AwardStyle.Bind(frame: Frame, vm: any): ()
		if not frame then
			return
		end
		if type(vm) ~= "table" or vm.id == nil then
			AwardStyle.Clear(frame)
			return
		end
		local itemId = tonumber(vm.id)
		if not itemId then
			AwardStyle.Clear(frame)
			return
		end
		UIMgr.SetAward(frame, itemId, tonumber(vm.count) or 0)
	end

	local BagSlot = {
		AwardStyle = AwardStyle,
	}

	--[[
		填格；style 须含 Bind，默认 AwardStyle

		@param frame Frame - 格子框架
		@param vm table - GetData.BagView.ToSlotVM 结果
		@param style { Bind: (Frame, any) -> () }? - 皮肤；省略用 AwardStyle
		@return () - 无返回值
	]]
	function BagSlot.Bind(frame: Frame, vm: any, style: any?): ()
		local impl = if type(style) == "table" and type(style.Bind) == "function" then style else AwardStyle
		impl.Bind(frame, vm)
	end

	--[[
		清空格子；style 须含 Clear，默认 AwardStyle

		@param frame Frame - 格子框架
		@param style { Clear: (Frame) -> () }? - 皮肤；省略用 AwardStyle
		@return () - 无返回值
	]]
	function BagSlot.Clear(frame: Frame, style: any?): ()
		local impl = if type(style) == "table" and type(style.Clear) == "function" then style else AwardStyle
		impl.Clear(frame)
	end

	return BagSlot
end
