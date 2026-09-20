--[[
	Module: BackpackDrag
	Description: 工具栏↔仓库拖拽；乐观态只走 Core overlay，禁止改 PlayerData
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	落点：先 Toolbar 预检与 applyOptimisticDrag（overlay），成功后再 FireServer。
	服拒绝或超时由 View 回滚 overlay；权威以 PLAYER_DATA_SYNC 为准。
]]

local UserInputService = game:GetService("UserInputService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AllUI = require(script.Parent.AllUI)

local GetData = Utils.GetData
local EnumMgr = Utils.EnumMgr
local LocalPlayer = Utils.LocalPlayer
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork

local BagCapacity = GetData.BagCapacity

local BackpackDrag = {}

-- ========================================
-- 类型与常量
-- ========================================
export type DragHost = {
	getToolbarSlots: () -> { GuiObject },
	getWarehouseSlotFrames: () -> { GuiObject },
	getWarehouseSlotByOnlyId: (number) -> GuiObject?,
	getToolbarItemAtSlot: (number) -> any?,
	isWarehouseOpen: () -> boolean,
	isLockActive: () -> boolean,
	applyOptimisticDrag: (
		{ zone: string, equipSlot: number?, onlyID: number? },
		{ zone: string, equipSlot: number?, onlyID: number? }
	) -> boolean,
	canDropOnToolbar: (number) -> boolean,
}

local host: DragHost? = nil
local dragClone: Frame? = nil
local dragSource: { zone: string, equipSlot: number?, onlyID: number? }? = nil
local dragConnections: { RBXScriptConnection } = {}
local warehouseDragConnByOnlyId: { [number]: RBXScriptConnection } = {}
local isDragging = false
local dragStartPosition = Vector2.zero
local lastPointerPos = Vector2.zero
local DRAG_THRESHOLD_PX = 12

-- ========================================
-- 私有函数
-- ========================================

--[[
	是否已有拖拽会话

	@return boolean - true 表示不可再开新会话
]]
local function _isDragSessionActive(): boolean
	return dragSource ~= nil or #dragConnections > 0
end

--[[
	清理拖拽状态

	@return nil
]]
local function _clearDrag(): ()
	for _, conn in dragConnections do
		conn:Disconnect()
	end
	table.clear(dragConnections)
	if dragClone then
		dragClone:Destroy()
		dragClone = nil
	end
	dragSource = nil
	isDragging = false
end

--[[
	读取 ScreenGui UIScale

	@return number - Scale，无效时 1
]]
local function _getScreenUiScale(): number
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui") :: PlayerGui?
	if not playerGui then
		return 1
	end
	local screenGui = playerGui:FindFirstChild("ScreenGui")
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return 1
	end
	local scaleIns = screenGui:FindFirstChild("UIScale")
	if scaleIns and scaleIns:IsA("UIScale") and scaleIns.Scale > 0 then
		return scaleIns.Scale
	end
	return 1
end

--[[
	指针屏幕坐标 → ScreenGui 偏移

	@param screenPos Vector2 - 不含 GuiInset 的坐标
	@return number, number - offsetX, offsetY
]]
local function _pointerToGuiOffset(screenPos: Vector2): (number, number)
	local mainScale = _getScreenUiScale()
	return screenPos.X / mainScale, screenPos.Y / mainScale
end

--[[
	创建拖拽虚影

	@param sourceFrame GuiObject - 源槽
	@param pointerPos Vector2 - 当前指针
	@return Frame? - 拖拽容器
]]
local function _createDragClone(sourceFrame: GuiObject, pointerPos: Vector2): Frame?
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui") :: PlayerGui?
	if not playerGui then
		return nil
	end
	local screenGui = playerGui:FindFirstChild("ScreenGui") :: ScreenGui?
	local parentGui: Instance = screenGui or playerGui
	local mainScale = _getScreenUiScale()

	local absSize = sourceFrame.AbsoluteSize
	local dragContainer = Instance.new("Frame")
	dragContainer.Name = "BackpackDragContainer"
	dragContainer.BackgroundTransparency = 1
	dragContainer.Size = UDim2.fromOffset(absSize.X / mainScale, absSize.Y / mainScale)
	dragContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	dragContainer.ZIndex = 1000
	dragContainer.Parent = parentGui

	local clone = sourceFrame:Clone()
	clone.Name = "DragClone"
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Size = UDim2.fromScale(1, 1)
	clone.Position = UDim2.fromScale(0.5, 0.5)
	clone.BackgroundTransparency = math.min(clone.BackgroundTransparency + 0.3, 0.85)
	clone.Visible = true
	clone.Parent = dragContainer

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			descendant.AutoButtonColor = false
			descendant.Active = false
			descendant.Selectable = false
		end
	end

	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = Color3.fromRGB(255, 255, 0)
	uiStroke.Thickness = 3
	uiStroke.Parent = clone

	local ox, oy = _pointerToGuiOffset(pointerPos)
	dragContainer.Position = UDim2.fromOffset(ox, oy)
	return dragContainer
end

--[[
	提交拖拽落点

	@param target { zone: string, equipSlot: number?, onlyID: number? } - 落点
	@return nil
]]
local function _commitDrag(target: { zone: string, equipSlot: number?, onlyID: number? }): ()
	if not dragSource or not host then
		return
	end
	if dragSource.zone == EnumMgr.BagDragZone.Warehouse and target.zone == EnumMgr.BagDragZone.Toolbar then
		local onlyID = tonumber(dragSource.onlyID) or 0
		if not host.canDropOnToolbar(onlyID) then
			_clearDrag()
			return
		end
	end
	if not host.applyOptimisticDrag(dragSource, target) then
		_clearDrag()
		return
	end
	NetWork.FireServer(NetMsg.BACKPACK_TOOLBAR_DRAG, {
		from = dragSource,
		to = target,
	})
	_clearDrag()
end

--[[
	点是否在 GuiObject 矩形内

	@param gui GuiObject - UI
	@param screenPos Vector2 - 屏幕坐标
	@return boolean - 是否在内
]]
local function _isPointInGui(gui: GuiObject, screenPos: Vector2): boolean
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	return screenPos.X >= absPos.X
		and screenPos.X <= absPos.X + absSize.X
		and screenPos.Y >= absPos.Y
		and screenPos.Y <= absPos.Y + absSize.Y
end

--[[
	查找落点命中的工具栏槽与仓库格

	@param screenPos Vector2 - 屏幕坐标
	@return number?, number? - 工具栏槽、仓库 onlyID
]]
local function _findHitsAt(screenPos: Vector2): (number?, number?)
	if not host then
		return nil, nil
	end
	local toolbarSlot: number? = nil
	local warehouseOnlyId: number? = nil
	for _, slot in host.getToolbarSlots() do
		if slot.Visible and _isPointInGui(slot, screenPos) then
			local uiSlot = tonumber(slot:GetAttribute("UiSlotIndex")) or 0
			if uiSlot > 0 then
				toolbarSlot = uiSlot
				break
			end
		end
	end
	for _, slot in host.getWarehouseSlotFrames() do
		if _isPointInGui(slot, screenPos) then
			warehouseOnlyId = tonumber(slot:GetAttribute("OnlyID")) or 0
			break
		end
	end
	if warehouseOnlyId == nil and host then
		-- 拖动替换区 / 仓库空白也视为卸回
	end
	return toolbarSlot, warehouseOnlyId
end

--[[
	解析落点

	@param screenPos Vector2 - 屏幕坐标
	@return table? - 落点；nil 取消
]]
local function _resolveDropTarget(screenPos: Vector2): { zone: string, equipSlot: number?, onlyID: number? }?
	if not host then
		return nil
	end
	local fromZone = if dragSource then dragSource.zone else nil
	local toolbarSlot, warehouseOnlyId = _findHitsAt(screenPos)
	local warehouseOpen = host.isWarehouseOpen()
	local zoneToolbar = EnumMgr.BagDragZone.Toolbar
	local zoneWarehouse = EnumMgr.BagDragZone.Warehouse

	if fromZone == zoneToolbar then
		if warehouseOnlyId ~= nil then
			return { zone = zoneWarehouse }
		end
		if toolbarSlot ~= nil and BagCapacity.IsToolbarEquipSlot(toolbarSlot) then
			return { zone = zoneToolbar, equipSlot = toolbarSlot }
		end
		if warehouseOpen then
			return { zone = zoneWarehouse }
		end
		return nil
	end

	if toolbarSlot ~= nil and BagCapacity.IsToolbarEquipSlot(toolbarSlot) then
		return { zone = zoneToolbar, equipSlot = toolbarSlot }
	end
	return nil
end

--[[
	更新虚影位置

	@return nil
]]
local function _updateDragClonePos(): ()
	if not dragClone then
		return
	end
	local ox, oy = _pointerToGuiOffset(lastPointerPos)
	dragClone.Position = UDim2.fromOffset(ox, oy)
end

--[[
	开始拖拽监视

	@param sourceFrame GuiObject - 源 UI
	@param sourceData table - 源数据
	@param beginInput InputObject - 发起输入
	@return nil
]]
local function _startDragWatch(
	sourceFrame: GuiObject,
	sourceData: { zone: string, equipSlot: number?, onlyID: number? },
	beginInput: InputObject
): ()
	_clearDrag()
	dragSource = sourceData
	local beginPos = Vector2.new(beginInput.Position.X, beginInput.Position.Y)
	dragStartPosition = beginPos
	lastPointerPos = beginPos
	isDragging = false

	table.insert(
		dragConnections,
		UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			lastPointerPos = pos
			if not isDragging then
				if (pos - dragStartPosition).Magnitude < DRAG_THRESHOLD_PX then
					return
				end
				isDragging = true
				dragClone = _createDragClone(sourceFrame, pos)
			end
			_updateDragClonePos()
		end)
	)

	table.insert(
		dragConnections,
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			local endPos = Vector2.new(input.Position.X, input.Position.Y)
			lastPointerPos = endPos
			if isDragging and dragSource then
				local target = _resolveDropTarget(endPos)
				if target then
					_commitDrag(target)
					return
				end
			end
			_clearDrag()
		end)
	)
end

--[[
	绑定按下开始拖拽

	@param gui GuiObject - 热区
	@param sourceFrame GuiObject - 视觉源
	@param sourceData table - 源数据
	@param requireWarehouseOpen boolean? - 仓库关闭不拖
	@return RBXScriptConnection - 连接
]]
local function _bindDragBegin(
	gui: GuiObject,
	sourceFrame: GuiObject,
	sourceData: { zone: string, equipSlot: number?, onlyID: number? },
	requireWarehouseOpen: boolean?
): RBXScriptConnection
	return gui.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if _isDragSessionActive() then
			return
		end
		if not host then
			return
		end
		if requireWarehouseOpen and not host.isWarehouseOpen() then
			return
		end
		if host.isLockActive() then
			return
		end
		if sourceData.zone == EnumMgr.BagDragZone.Toolbar and sourceData.equipSlot then
			if not host.getToolbarItemAtSlot(sourceData.equipSlot) then
				return
			end
		end
		_startDragWatch(sourceFrame, sourceData, input)
	end)
end

--[[
	绑定工具栏槽拖拽

	@return nil
]]
local function _bindToolbarDrag(): ()
	if not host then
		return
	end
	for _, slot in host.getToolbarSlots() do
		local uiSlot = tonumber(slot:GetAttribute("UiSlotIndex")) or 0
		if BagCapacity.IsToolbarEquipSlot(uiSlot) then
			local dragTarget = AllUI.findSlotButton(slot, "toolbarDrag:" .. uiSlot)
			if dragTarget then
				_bindDragBegin(dragTarget, slot, {
					zone = EnumMgr.BagDragZone.Toolbar,
					equipSlot = uiSlot,
				}, true)
			end
		end
	end
end

--[[
	断开仓库格拖拽

	@param onlyID number - onlyID
	@return nil
]]
local function _unbindWarehouseDrag(onlyID: number): ()
	local conn = warehouseDragConnByOnlyId[onlyID]
	if conn then
		if conn.Connected then
			conn:Disconnect()
		end
		warehouseDragConnByOnlyId[onlyID] = nil
	end
end

--[[
	为单个仓库格绑定拖拽

	@param onlyID number - onlyID
	@param slot GuiObject - 仓库格
	@return nil
]]
local function _bindWarehouseDragSlot(onlyID: number, slot: GuiObject): ()
	_unbindWarehouseDrag(onlyID)
	local dragTarget = AllUI.findSlotButton(slot, "warehouseDrag:" .. onlyID)
	if not dragTarget then
		return
	end
	local conn = _bindDragBegin(dragTarget, slot, {
		zone = EnumMgr.BagDragZone.Warehouse,
		onlyID = onlyID,
	})
	warehouseDragConnByOnlyId[onlyID] = conn
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	重绑仓库格拖拽（差量）

	@param addedOnlyIds { number }? - 新增
	@param removedOnlyIds { number }? - 移除
	@return nil
]]
function BackpackDrag.rebindWarehouseSlots(addedOnlyIds: { number }?, removedOnlyIds: { number }?): ()
	if not host then
		return
	end
	if addedOnlyIds == nil and removedOnlyIds == nil then
		for _, conn in warehouseDragConnByOnlyId do
			if conn.Connected then
				conn:Disconnect()
			end
		end
		table.clear(warehouseDragConnByOnlyId)
		for _, slot in host.getWarehouseSlotFrames() do
			local onlyID = tonumber(slot:GetAttribute("OnlyID")) or 0
			if onlyID > 0 then
				_bindWarehouseDragSlot(onlyID, slot)
			end
		end
		return
	end
	if removedOnlyIds then
		for _, onlyID in ipairs(removedOnlyIds) do
			_unbindWarehouseDrag(onlyID)
		end
	end
	if addedOnlyIds then
		for _, onlyID in ipairs(addedOnlyIds) do
			local slot = host.getWarehouseSlotByOnlyId(onlyID)
			if slot then
				_bindWarehouseDragSlot(onlyID, slot)
			end
		end
	end
end

--[[
	绑定 Host 并初始化工具栏拖拽

	@param dragHost DragHost - Core 提供的只读/乐观接口
	@return nil
]]
function BackpackDrag.bind(dragHost: DragHost): ()
	host = dragHost
	_bindToolbarDrag()
end

return BackpackDrag
