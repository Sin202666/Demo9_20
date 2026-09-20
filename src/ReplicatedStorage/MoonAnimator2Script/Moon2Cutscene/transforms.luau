--[[
	属性变换模块
	处理各种属性的插值和设置
]]

-- 线性插值函数
local lerp = function(a, b, c)
	return a + c * (b - a)
end

local VisibleMgr = require(game.ReplicatedFirst.AllSideCode.ToolBasic.VisibleMgr)

-- 属性类型处理函数映射
local propertyTypes = {
	-- 数值类型属性（支持插值）
	[{"Transparency", "Reflectance", "FieldOfView", "BackgroundTransparency", "ImageTransparency", "Brightness", "Contrast", "Saturation", "ExposureCompensation", "TextSize", "TextTransparency", "Volume", "PlaybackSpeed", "RollOffMaxDistance", "RollOffMinDistance"}] = function(property: string, obj: Instance, value: number, lastValue: number, alpha: number)
		
	
		
		local success = pcall(function()
			return obj[property]
		end)
		if success then
			obj[property] = lastValue and lerp(lastValue, value, alpha) or value
		else
			--if obj:IsA("Model") and property == "Transparency" then
			--	VisibleMgr.fadeAll(obj,lastValue and lerp(lastValue, value, alpha) or value)
			--end
		end
	end,

	-- 时间设置（只在完成时设置）
	[{"SetTime"}] = function(property, obj: Instance, value: number, _, alpha)
		if alpha == 1 then
			obj[property] = value
		end
	end,

	-- 摄像机附着到部件
	-- 注意：此函数需要接收 cutscene 实例来存储连接，防止内存泄漏
	[{"AttachToPart"}] = function(property, obj: Camera, value: BasePart, _, alpha, cutscene)
		if alpha == 1 then
			-- 如果之前已有连接，先断开
			if cutscene and cutscene.attachConnections and cutscene.attachConnections[obj] then
				local oldConnection = cutscene.attachConnections[obj]
				if oldConnection and oldConnection.Connected then
					oldConnection:Disconnect()
				end
			end

			-- 创建新连接
			local connection = nil
			connection = game:GetService("RunService").Heartbeat:Connect(function()
				if value and value.Parent then
					obj.CFrame = value.CFrame
				else
					-- 如果部件已被销毁，断开连接
					if connection then
						connection:Disconnect()
						if cutscene and cutscene.attachConnections then
							cutscene.attachConnections[obj] = nil
						end
					end
				end
			end)

			-- 存储连接以便后续清理
			if cutscene and cutscene.attachConnections then
				cutscene.attachConnections[obj] = connection
			end
		end
	end,

	-- 枚举类型属性
	[{"Material", "RollOffMode"}] = function(property: string, obj: BasePart, value: string)
		obj[property] = Enum[property][value]
	end,

	-- 布尔/字符串类型属性（只在完成时设置）
	[{"Anchored", "CastShadow", "Enabled", "Text", "Looped", "Playing", "SoundId", "Font"}] = function(property: string, obj: Instance, value: number, lastValue: number, alpha: number)
		if alpha == 1 then
			obj[property] = value
			return
		end

		obj[property] = lastValue
	end,

	-- 颜色类型属性（使用 Color3:Lerp）
	[{"Color", "BackgroundColor3", "TextColor3", "TintColor"}] = function(property: string, obj: Instance, value: Color3, lastValue: Color3, alpha: number)
		obj[property] = lastValue and lastValue:Lerp(value, alpha) or value
	end,

	-- 声音播放
	[{"PlayOnce", "Play"}] = function(_, obj: Sound, _, _, alpha: number)
		if alpha == 1 then
			obj:Play()
		end
	end,

	-- 声音控制
	[{"Stop", "Pause", "Resume"}] = function(v, obj: Sound, _, _, alpha: number)
		if alpha == 1 then
			obj[v](obj)
		end
	end,
}

-- 特殊值类型处理函数
local valueTypes = {
	-- Motor6D 的 C1 属性（骨骼关节变换）
	["C1"] = function(obj: Instance, value: CFrame, lastValue: CFrame, alpha: number)
		local default = (obj.Part0.CFrame * obj.C0)
		local f_last, f_next = default * lastValue:Inverse(), default * value:Inverse()
		local desired = f_last:Lerp(f_next, alpha)

		obj.C1 = desired:Inverse() * default
	end,

	-- CFrame 属性（位置和旋转）
	["CFrame"] = function(obj: Instance, value: CFrame, lastValue: CFrame, alpha: number)
		local newValue = lastValue and lastValue:Lerp(value, alpha) or value
		if obj:IsA("Camera") then
			obj.CameraType = Enum.CameraType.Scriptable
			obj.CFrame = newValue
			obj.Focus = newValue
			return
		end

		-- Model 无 PrimaryPart 时不能写 .CFrame，统一用 PivotTo
		if obj:IsA("Model") then
			obj:PivotTo(newValue)
			return
		end

		(obj :: BasePart).CFrame = newValue
	end,

	-- Size 属性（尺寸）
	["Size"] = function(obj: BasePart, value: Vector3, lastValue: Vector3, alpha: number)
		obj.Size = lastValue and lastValue:Lerp(value, alpha) or value
	end,

	-- 粒子发射
	["Emit"] = function(obj: ParticleEmitter, value: number, _, alpha: number)
		if alpha == 1 then
			obj:Emit(value)
		end
	end,
}

-- 值包装器（用于处理特殊序列类型）
valueTypes.Wrappers = {
	-- NumberSequence 包装器
	["NumberSequence"] = function(value, lastValue, alpha)
		return NumberSequence.new(lerp(lastValue, value, alpha))
	end,

	-- ColorSequence 包装器
	["ColorSequence"] = function(value: Color3, lastValue, alpha)
		return ColorSequence.new(lastValue:Lerp(value, alpha))
	end,
}

-- 将属性类型处理函数映射到 valueTypes
for properties, fn in propertyTypes do
	for _, p in properties do
		valueTypes[p] = function(...)
			fn(p, ...)
		end
	end
end

-- 清理临时变量
propertyTypes = nil

return valueTypes