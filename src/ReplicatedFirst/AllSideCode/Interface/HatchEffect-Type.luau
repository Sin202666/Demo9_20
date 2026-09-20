--[[
	Module: HatchEffect-Type
	Description: HatchEffect 类型声明（完整使用说明见 ToolSystem/HatchEffect/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01
]]

local HatchEffect = {}

--[[
	完整抽蛋表现：宠物蛋容器动画 → 奖励模型 + RngShowUI → 旋转展示 → 结束。
	阻塞至表现结束；失败时静默 return。

	@param boxId number - 宠物蛋 CfgFind ID（须为 EnumMgr.ItemType.PetEgg）
	@param rewardTable {number} - 宠物奖励 ID 数组，最多 5 个；展示前按 xyd 降序，再对应 PetInfo1~N
	@param speedScale number? - 时长倍率，默认 1；乘在各阶段 duration 上，越大越慢
	@param isAutoSkip boolean? - true 等待 WAIT_DURATION 后自动结束；false 等待点击/触摸/Q
	@return nil - 无返回值
]]
function HatchEffect.ShowHatchEffect(boxId: number, rewardTable: {number}, speedScale: number?, isAutoSkip: boolean?)
end

--[[
	仅奖励展示（无容器），speedScale 固定为 1。
	阻塞至表现结束；失败时静默 return。

	@param itemTable {number} - 宠物 ID 数组，最多 5 个；展示前按 xyd 降序
	@param isAuto boolean? - 同 ShowHatchEffect 的 isAutoSkip，默认 false
	@return nil - 无返回值
]]
function HatchEffect.ShowItemEffect(itemTable: {number}, isAuto: boolean?)
end

return HatchEffect
