--[[
	Module: HatchEffect
	Description: 抽蛋容器与奖励展示表现（客户端专用）
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	功能：
	- 容器表现：高处掉落、抖动、放大
	- 奖励展示：模型展示、粒子、音效、UI 联动
	- 单物品展示：ShowItemEffect（跳过容器阶段）

	子模块：
	- HatchConfig.luau       常量与资源引用
	- HatchAnimUtil.luau     通用 Easing 循环
	- HatchCamera.luau       摄像机缩放与位置
	- HatchSound.luau        音效播放
	- HatchBoxEffect.luau    容器掉落/抖动表现
	- HatchRewardBuild.luau  奖励模型构建
	- HatchRewardEffect.luau 奖励展示动画
	- ShowInfoUI.luau        抽蛋信息 UI

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local HatchEffect = Utils.HatchEffect

	【运行环境】
	- 仅客户端调用（依赖 LocalPlayer、CurrentCamera、PlayerGui）
	- 两个公共 API 均为阻塞式：内部含 RenderStepped 动画与 task.wait，会占用当前线程直到表现结束
	- 若不希望卡住调用方逻辑，请在外层 task.spawn / task.defer 中调用
	- 同时只允许一路表现；重叠调用会 Log.warn 并忽略

	【API 选择】
	| API               | 适用场景                                      |
	|-------------------|-----------------------------------------------|
	| ShowHatchEffect   | 完整抽蛋：先播宠物蛋容器动画，再展示奖励      |
	| ShowItemEffect    | 仅展示奖励：无容器阶段（如奖励弹窗已结算后）  |

	【ShowHatchEffect 参数】
	- boxId: number
	  宠物蛋配置 ID（CfgFind）。须为 EnumMgr.ItemType.PetEgg，且配置含 Model 字段。
	- rewardTable: {number}
	  奖励宠物 ID 数组，最多 5 个，超出自动截断并 Log.warn。
	  UI 槽位与模型均按稀有度 xyd 降序排列（PetInfo1 = 最高稀有度）。
	  模型须为 EnumMgr.ItemType.Pet 且配置含 Model、xyd、NormalIdleName。
	- speedScale: number?  默认 1。
	  乘在各阶段 duration 上，越大越慢（如 2 = 约两倍时长）。
	- isAutoSkip: boolean? 默认 false。
	  false：旋转展示后等待玩家点击 / 触摸 / Q 键跳过；
	  true：等待 WAIT_DURATION 后自动播放结束动画。

	【ShowItemEffect 参数】
	- itemTable: {number}  同上，宠物 ID 数组，最多 5 个。
	- isAuto: boolean?       同 isAutoSkip，默认 false。speedScale 固定为 1。

	【表现流程（ShowHatchEffect）】
	1. 克隆并预处理宠物蛋模型 → 容器掉落/抖动/放大
	2. 奖励 ID 按 xyd 降序 → 克隆宠物模型（同序）
	3. 填充 RngShowUI 信息条（与模型顺序一致）
	4. 奖励旋转展示 → 等待/跳过 → 结束下落并清理
	5. 额外等待 HATCH_FINISH_WAIT（1.2s）后返回

	【前置依赖】
	- PlayerGui.UIAnimGui.RngShowUI 及 PetInfo1 ~ PetInfo5（ShowInfoUI 使用）
	- 资源：Assets/Hatch/star_particles、OPEN_particles、StarParticle
	- 资源：Assets/UIGradient/稀有度底色{xyd}（非 Xyd5/Xyd6 时使用）
	- ModelRes 中对应 PetEgg / Pet 模型

	【副作用】
	- 临时修改 LocalPlayer.CameraMinZoomDistance，结束表现后恢复为进入前的值
	- 模型与粒子挂载在 workspace.CurrentCamera 下，结束时 Debris 销毁
	- 播放 2D 抽蛋音效（掉落、抖动、放大、稀有度结果音）

	【调用示例】
	-- 完整抽蛋（10 连抽结果，自动跳过）
	task.spawn(function()
		HatchEffect.ShowHatchEffect(eggCfgId, { 1001, 1002, 1003 }, 1.5, true)
	end)

	-- 奖励窗口仅展示新获得宠物（手动点击继续）
	HatchEffect.ShowItemEffect({ 2001, 2002 }, false)

	【常见失败（静默 return + Log.warn）】
	- rewardTable / itemTable 为空
	- boxId 非宠物蛋或缺少模型配置 / GetModel 失败
	- 单个 rewardId 缺少 Pet 模型配置（跳过该条，其余继续）
	- 全部 rewardId 均无法构建模型（跳过 UI/奖励，恢复摄像机缩放）
	- Hatch 资源缺失时跳过容器表现，仍尝试展示奖励；OPEN_particles 缺失则奖励阶段 abort
	- 已有一路表现进行中
]]

-- ============================================================================
-- 依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local VisibleMgr = Utils.VisibleMgr
local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind
local ResourceUtil = Utils.ResourceUtil
local Log = Utils.Log

local HatchConfig = require(script.HatchConfig)
local HatchCamera = require(script.HatchCamera)
local HatchBoxEffect = require(script.HatchBoxEffect)
local HatchRewardBuild = require(script.HatchRewardBuild)
local HatchRewardEffect = require(script.HatchRewardEffect)
local InfoUI = require(script.ShowInfoUI)

local HatchEffect = {}

-- ============================================================================
-- 私有状态 / 私有函数
-- ============================================================================

local isPlaying = false

--[[
	串行化两路公共 API：重叠调用忽略；异常时 restoreZoom 并释放锁。

	@param runner () -> () - 实际表现体
]]
local function _runGuarded(runner: () -> ())
	if isPlaying then
		Log.warn("[HatchEffect] 已有表现进行中，忽略本次调用")
		return
	end
	isPlaying = true
	local ok, err = pcall(runner)
	isPlaying = false
	if not ok then
		Log.warn("[HatchEffect] 表现异常", err)
		HatchCamera.restoreZoom()
	end
end

--[[
	播放奖励 + UI 展示阶段；模型为空时跳过并恢复摄像机

	@param sortedItemIds {number} - 已按 xyd 降序的 ID 列表
	@param rewardNum number - 截断后的奖励数量（用于 UI 槽位数）
	@param speedScale number - 时长倍率，越大越慢
	@param isAutoSkip boolean - true 自动结束等待；false 等输入
	@return boolean - 是否成功展示（至少有一个模型）
]]
local function _playRewardPresentation(
	sortedItemIds: {number},
	rewardNum: number,
	speedScale: number,
	isAutoSkip: boolean
): boolean
	local rewardModels = HatchRewardBuild.buildPetModels(sortedItemIds)
	if #rewardModels == 0 then
		Log.warn("缺少可展示的奖励模型")
		HatchCamera.restoreZoom()
		return false
	end

	InfoUI.createUI(sortedItemIds, isAutoSkip)
	InfoUI.showUI(speedScale, rewardNum)
	HatchRewardEffect.play(rewardModels, speedScale, isAutoSkip)
	InfoUI.hideUI(speedScale, rewardNum)

	return true
end

--[[
	获取并预处理抽蛋容器模型

	@param boxId number - 宠物蛋 CfgFind ID
	@return Model? - GetModel 克隆；缺配置、类型非 PetEgg 或实例失败时 nil
]]
local function _getBoxModel(boxId: number): Model?
	local boxCfg = CfgFind.FindCfgByID(boxId)
	if not boxCfg or not boxCfg["Model"] then
		Log.warn("缺少宝箱模型")
		return nil
	end

	if boxCfg["tp"] ~= EnumMgr.ItemType.PetEgg then
		Log.warn("宝箱类型错误", boxCfg["tp"])
		return nil
	end

	local boxModel = ResourceUtil.GetModel(ResourceUtil.ModelCategory.PetEgg, boxCfg["Model"])
	if not boxModel then
		Log.warn("缺少宝箱模型实例")
		return nil
	end

	VisibleMgr.DisableParticle(boxModel)
	VisibleMgr.CloseShade(boxModel)

	return boxModel
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	播放完整抽蛋表现（容器 + 奖励 + UI，阻塞直到结束）

	@param boxId number - 宠物蛋配置 ID（CfgFind，类型须为 PetEgg）
	@param rewardTable {number} - 奖励宠物 ID 数组，最多 MAX_HATCH_TIME(5) 个，超出截断
	@param speedScale number? - 时长倍率，默认 1（2 表示约两倍时长）
	@param isAutoSkip boolean? - 是否自动跳过等待；false 时需点击/触摸/Q 继续

	@return nil - 无返回值；失败或重叠调用时静默 return

	@example
	task.spawn(function()
		HatchEffect.ShowHatchEffect(eggId, { petId1, petId2 }, 1, false)
	end)
]]
function HatchEffect.ShowHatchEffect(boxId: number, rewardTable: {number}, speedScale: number?, isAutoSkip: boolean?)
	if not next(rewardTable) then
		return
	end

	_runGuarded(function()
		speedScale = speedScale or 1
		isAutoSkip = isAutoSkip or false

		local boxModel = _getBoxModel(boxId)
		if not boxModel then
			return
		end

		local clampedRewardIds, rewardNum = HatchConfig.clampRewardIds(rewardTable)
		local sortedRewardIds = HatchRewardBuild.sortItemIdsByXyd(clampedRewardIds)

		local boxPlayed = HatchBoxEffect.play(boxModel, rewardNum, speedScale)
		if not boxPlayed then
			Log.warn("容器表现资源缺失，跳过容器动画")
		end

		if not _playRewardPresentation(sortedRewardIds, rewardNum, speedScale, isAutoSkip) then
			return
		end

		task.wait(HatchConfig.HATCH_FINISH_WAIT)
	end)
end

--[[
	播放奖励展示（无容器阶段，阻塞直到结束）

	适用于奖励弹窗、重复获得提示等已无需再播蛋盒动画的场景。

	@param itemTable {number} - 宠物 ID 数组，最多 5 个，超出截断；按 xyd 降序展示
	@param isAuto boolean? - 是否自动跳过；false 时显示「点击继续」并等待输入

	@return nil - 无返回值；失败或重叠调用时静默 return

	@example
	HatchEffect.ShowItemEffect({ newPetId1, newPetId2 })
]]
function HatchEffect.ShowItemEffect(itemTable: {number}, isAuto: boolean?)
	if not next(itemTable) then
		return
	end

	_runGuarded(function()
		isAuto = isAuto or false

		local clampedItemIds, rewardNum = HatchConfig.clampRewardIds(itemTable)
		local sortedItemIds = HatchRewardBuild.sortItemIdsByXyd(clampedItemIds)

		if not _playRewardPresentation(sortedItemIds, rewardNum, 1, isAuto) then
			return
		end

		task.wait(HatchConfig.ITEM_FINISH_WAIT)
	end)
end

return HatchEffect
