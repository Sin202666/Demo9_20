--[[
	Module: UIMgr.Gradients.Element
	Description: 元素类型渐变挂载（由 Gradients/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- GetElementGradient / AddElementGradient / RemoveElementGradient
	- 过渡与 Core 共用同一份 _gradientTransitions
	- 克隆剥脚本；移除/替换时 Stop 循环；Attribute GradientAnim 可自动播
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind

--[[
	挂载元素渐变 API 到 Gradients 表。
	@param Gradients table - 与 init 同一份导出表
	@param Core table - finishGradientTransition / applyGradientWithTransition / AllGridientsFolder
	@return () - 无返回值
]]
return function(Gradients, Core)
	local AllGridientsFolder = Core.AllGridientsFolder
	local _finishGradientTransition = Core.finishGradientTransition
	local _applyGradientWithTransition = Core.applyGradientWithTransition
	local _resetParentWhiteBase = Core.resetParentWhiteBase

	--[[
		根据元素类型获取渐变颜色
		@param elementType number - 元素类型（EnumMgr.ElementTp，非 None）
		@return UIGradient? - 渐变对象
	]]
	function Gradients.GetElementGradient(elementType: number): UIGradient?
		if not elementType or elementType < 1 or elementType > EnumMgr.ElementTp.Space then
			return nil
		end

		-- 从 CfgFind 获取转换后的 elementConf（使用字符串键）
		local elementConf = CfgFind.GetCfgByName("elementConf")
		if not elementConf then
			Log.warn("elementConf 配置不存在")
			return nil
		end

		local elementData = elementConf[elementType]
		if not elementData then
			Log.warn("元素类型配置不存在:", elementType)
			return nil
		end

		-- Tag 是转换后的字符串键
		local elementTag = elementData["Tag"]
		if not elementTag or type(elementTag) ~= "string" then
			Log.warn("元素类型 Tag 不存在或格式错误:", elementType)
			return nil
		end

		-- 从 ElementGradients 文件夹中查找
		local elementGradientsFolder: Folder? = AllGridientsFolder and AllGridientsFolder:FindFirstChild("ElementGradients") :: Folder?
		if not elementGradientsFolder then
			Log.warn("ElementGradients 文件夹不存在")
			return nil
		end

		local elementFolder: Folder? = elementGradientsFolder:FindFirstChild(elementTag) :: Folder?
		if not elementFolder then
			Log.warn("元素类型文件夹不存在:", elementTag)
			return nil
		end

		-- 查找 UIGradient
		local gradient: UIGradient? = elementFolder:FindFirstChildOfClass("UIGradient")
		if gradient then
			local cloned = gradient:Clone()
			if cloned:IsA("UIGradient") then
				Gradients.PrepareClonedGradient(cloned)
			end
			return cloned
		end

		return nil
	end

	--[[
		为元素类型添加渐变颜色
		@param elementType number - 元素类型（与 elementConf 一致）
		@param _parent Instance - 父实例
		@param isText boolean? - 与 AddGradientColor 对齐；元素预设无 *-Text 变体，不改变选用模板
		@param _Rot number? - 旋转角度
		@return UIGradient? - 渐变对象
	]]
	function Gradients.AddElementGradient(elementType: number, _parent: Instance, isText: boolean?, _Rot: number?): UIGradient?
		if not _parent or not elementType or elementType < 1 or elementType > EnumMgr.ElementTp.Space then
			return nil
		end

		-- 检查是否已存在相同元素类型的渐变
		if _parent:GetAttribute("elementType") == tostring(elementType) then
			return _parent:FindFirstChildOfClass("UIGradient") :: UIGradient?
		end

		local newGradientTemplate: UIGradient? = Gradients.GetElementGradient(elementType)
		if not newGradientTemplate then
			return nil
		end

		_finishGradientTransition(_parent)
		Gradients.StopGradientAnim(_parent)

		local currentGradient: UIGradient? = _parent:FindFirstChildOfClass("UIGradient")

		if currentGradient then
			local endRot = _Rot or newGradientTemplate.Rotation
			return _applyGradientWithTransition(
				_parent,
				currentGradient,
				newGradientTemplate,
				endRot,
				"elementType",
				tostring(elementType)
			)
		end

		_resetParentWhiteBase(_parent)
		newGradientTemplate.Parent = _parent
		if _Rot then
			newGradientTemplate.Rotation = _Rot
		end
		_parent:SetAttribute("elementType", tostring(elementType))
		Gradients.PlayGradientAnimForPreset(newGradientTemplate, tostring(elementType))
		return newGradientTemplate
	end

	--[[
		移除元素类型渐变颜色
		@param _parent Instance - 父实例
		@return () - 无返回值
	]]
	function Gradients.RemoveElementGradient(_parent: Instance)
		Gradients.StopGradientAnim(_parent)
		_finishGradientTransition(_parent)
		local gradient: UIGradient? = _parent:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient:Destroy()
			_parent:SetAttribute("elementType", nil)
		end
	end
end
