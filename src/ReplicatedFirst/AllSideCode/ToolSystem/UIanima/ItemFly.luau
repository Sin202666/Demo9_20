--[[
	Module: UIanima/ItemFly
	Description: UIanima 子模块——物品获得飞入动画（克隆 catalog 模板后飞向目标）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅供 init 挂到 UIanima.GetItemAnimation。业务请走 Utils.UIanima。
]]

local TweenService = game:GetService("TweenService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local MathMgr = Utils.MathMgr
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local AssetPaths = Utils.AssetPaths
local AssetRegistry = Utils.AssetRegistry
local Log = Utils.Log
local TranslationHelper = Utils.TranslationHelper

local Helpers = require(script.Parent.Helpers)

local ItemFly = {}

--[[
	填充飞入克隆体的数量文案、稀有度渐变与图标
	@param uiobject Instance - 模板克隆
	@param cfg {[string]: any} - CfgFind 物品行，使用 xyd / Icon
	@param num number - 展示数量（已默认过）
	@return nil - 无返回值
]]
local function _fillItemFlyClone(uiobject: Instance, cfg: { [string]: any }, num: number)
	local itemNumLabel = uiobject:FindFirstChild(Helpers.ITEM_NUM_LABEL_NAME)
	if not itemNumLabel or not itemNumLabel:IsA("GuiObject") then
		return
	end

	local mgr = Helpers.GetUIMgr()
	if mgr then
		mgr.AddGradientColor(cfg.xyd, itemNumLabel)
	end

	if itemNumLabel:IsA("TextLabel") or itemNumLabel:IsA("TextButton") then
		-- "+" 与数字不随语言变化，与 Award.SetRawText("+"..n) 约定一致
		TranslationHelper.SetRawText(itemNumLabel, "+" .. MathMgr.getNumStr(math.floor(num)))
	end

	local icon = cfg.Icon
	if icon then
		local itemIcon = itemNumLabel:FindFirstChild(Helpers.ITEM_ICON_NAME)
		if itemIcon and itemIcon:IsA("ImageLabel") then
			itemIcon.Image = Helpers.RBX_ASSET_PREFIX .. icon
		end
	end
end

--[[
	展示结束后飞向 goalUi：缩放到 1px 并位移，到达后震动目标
	@param uiobject GuiObject - 已挂到 ScreenGui 的飞入克隆
	@param goalUi GuiObject - 飞入终点（取 AbsolutePosition）
	@param screenScale number - ScreenGui UIScale.Scale，用于把绝对像素换回 Offset
	@param shakeUI (GuiObject) -> () - 到达后的震动回调（init 传入 ShakeUI）
	@return nil - 无返回值
]]
local function _playItemFlyAfterShow(
	uiobject: GuiObject,
	goalUi: GuiObject,
	screenScale: number,
	shakeUI: (GuiObject) -> ()
)
	if not goalUi.Parent then
		uiobject:Destroy()
		return
	end

	local safeScale = if screenScale > 0 then screenScale else 1
	local goalUDim = UDim2.fromOffset(
		(goalUi.AbsolutePosition.X + Helpers.ITEM_GOAL_ANCHOR * goalUi.AbsoluteSize.X) / safeScale,
		(goalUi.AbsolutePosition.Y + Helpers.ITEM_GOAL_ANCHOR * goalUi.AbsoluteSize.Y) / safeScale
	)

	local fadeOutTween = TweenService:Create(
		uiobject,
		TweenInfo.new(Helpers.ITEM_FADE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
		{ Size = UDim2.fromOffset(1, 1) }
	)
	local moveTween = TweenService:Create(
		uiobject,
		TweenInfo.new(Helpers.ITEM_MOVE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
		{ Position = goalUDim }
	)

	Helpers.OnTweenCompletedOnce(fadeOutTween, function()
		uiobject:Destroy()
	end)
	Helpers.OnTweenCompletedOnce(moveTween, function()
		if goalUi.Parent then
			shakeUI(goalUi)
		end
	end)

	moveTween:Play()
	fadeOutTween:Play()
end

--[[
	物品获得飞入动画：克隆 UIanima catalog 模板，展示后飞向目标并震动
	@param itemID number - 物品配置 ID（CfgFind.FindCfgByID）
	@param itemNum number? - 显示数量；nil 时为 1
	@param goalUi GuiObject - 飞入终点 UI（用于取 AbsolutePosition）
	@param shakeUI (GuiObject) -> () - 到达后的震动回调
	@return nil - 无返回值；缺配置/模板/ScreenGui 时 Log.warn 后返回
]]
function ItemFly.Play(itemID: number, itemNum: number?, goalUi: GuiObject, shakeUI: (GuiObject) -> ())
	if type(itemID) ~= "number" or not Helpers.IsGuiObject(goalUi) then
		Log.warn("[UIanima] GetItemAnimation 入参非法")
		return
	end

	local num = itemNum or 1
	local cfg = CfgFind.FindCfgByID(itemID)
	if not cfg then
		Log.warn("[UIanima] GetItemAnimation 未找到物品配置", itemID)
		return
	end

	local screenGui, screenScale = Helpers.GetScreenGuiScale()
	if not screenGui then
		Log.warn("[UIanima] GetItemAnimation 未找到 ScreenGui")
		return
	end

	local templatePath = AssetRegistry.BuildCatalogPath(AssetRegistry.Catalog.UIanima, Helpers.ITEM_FLY_TEMPLATE_NAME)
	local template = AssetPaths.Resolve(templatePath)
	if not template then
		Log.warn("[UIanima] GetItemAnimation 未找到飞入模板", templatePath)
		return
	end

	local uiobject = template:Clone()
	if not uiobject:IsA("GuiObject") then
		Log.warn("[UIanima] GetItemAnimation 模板不是 GuiObject", templatePath)
		uiobject:Destroy()
		return
	end

	_fillItemFlyClone(uiobject, cfg, num)

	local jitterX = Helpers.ITEM_SPAWN_JITTER * (1 - 2 * math.random())
	local jitterY = Helpers.ITEM_SPAWN_JITTER * (1 - 2 * math.random())
	uiobject.Size = UDim2.fromOffset(1, 1)
	uiobject.Position = Helpers.ITEM_SPAWN_CENTER + UDim2.fromScale(jitterX, jitterY)
	uiobject.Parent = screenGui

	local showPx = Helpers.ITEM_SHOW_SIZE
	if itemID == EnumMgr.ItemID.Coin or itemID == EnumMgr.ItemID.Diamond then
		showPx = Helpers.ITEM_SMALL_SHOW_SIZE
	end
	local showSize = UDim2.fromOffset(showPx, showPx)

	local showTween = TweenService:Create(
		uiobject,
		TweenInfo.new(Helpers.ITEM_SHOW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = showSize }
	)
	Helpers.OnTweenCompletedOnce(showTween, function()
		_playItemFlyAfterShow(uiobject, goalUi, screenScale, shakeUI)
	end)
	showTween:Play()
end

return ItemFly
