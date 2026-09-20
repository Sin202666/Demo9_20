--[[
	Module: UIMgr.Gradients.Anim
	Description: UIGradient 循环表现（色带滚动 / 旋转）与样式注册（由 Gradients/init 合并，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	功能：
	- PlayGradientAnim / StopGradientAnim / RegisterGradientAnimStyle
	- PlayGradientAnimForPreset（按 GradientAnimCfg 或 Attribute GradientAnim 自动播）
	- PrepareClonedGradient：克隆模板后剥子级脚本，避免预制体 LocalScript 双跑
	- ColorScroll 色板：彩虹满 / 彩虹柔（默认）/ 彩虹柔金 / 彩虹艳 / 彩虹粉 / 红脉
	- RegisterGradientAnimPalette；预制体 Attribute GradientAnimPalette 选色板
	- 全实例共用一条 Heartbeat；仅客户端 Play；同一写口（Color/Rotation/Offset/Transparency）互斥

	与 Core：
	- GetGradientColor 克隆后 Prepare；Add/Remove 与过渡前 Stop；彩虹类挂载后 PlayGradientAnimForPreset
	- 业务只走 Utils.UIMgr

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.AddGradientColor("彩虹", frame)
		UIMgr.PlayGradientAnim(gradient, "ColorScroll", { palette = "彩虹艳" })
		UIMgr.PlayGradientAnim(gradient, "Rotation", { degPerSec = 50 })
		UIMgr.RegisterGradientAnimStyle("OffsetSweep", {
			writes = { "Offset" },
			onTick = function(g, ctx, dt, opts)
				ctx.t = (ctx.t or 0) + dt
				local x = (ctx.t * (opts.speed or 1)) % 2 - 1
				g.Offset = Vector2.new(x, 0)
			end,
		})
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local RunService = Utils.RunService

local GradientCfg = require(script.Parent.Parent.GradientCfg)
local GradientAnimCfg = require(script.Parent.Parent.GradientAnimCfg)

local IS_CLIENT = RunService:IsClient()
local ATTR_GRADIENT_ANIM = "GradientAnim"

local COLOR_SCROLL_PERIOD = 2
local COLOR_SCROLL_STEP = 0.25
local ROTATION_DEG_PER_SEC = 50
local ATTR_GRADIENT_ANIM_PALETTE = "GradientAnimPalette"

-- Palette names: Full, Soft, Pastel, Vivid, Candy, Red
local PALETTE_FULL = utf8.char(0x5F69, 0x8679, 0x6EE1)
local PALETTE_SOFT = utf8.char(0x5F69, 0x8679, 0x67D4)
local PALETTE_PASTEL = utf8.char(0x5F69, 0x8679, 0x67D4, 0x91D1)
local PALETTE_VIVID = utf8.char(0x5F69, 0x8679, 0x8273)
local PALETTE_CANDY = utf8.char(0x5F69, 0x8679, 0x7C89)
local PALETTE_RED = utf8.char(0x7EA2, 0x8109)
local DEFAULT_COLOR_SCROLL_PALETTE = PALETTE_SOFT

local _palettes = {
	[PALETTE_FULL] = { "#ffff00", "#ff0004", "#eb04f6", "#4545fa", "#06f8fe", "#00f900" },
	[PALETTE_SOFT] = { "#fff88f", "#f3acc8", "#e761ff", "#8dacff", "#33f8ff" },
	[PALETTE_PASTEL] = { "#d5c160", "#ff91d3", "#fe77f8", "#c898fb", "#71b3d5" },
	[PALETTE_VIVID] = { "#fe0002", "#0b00fa", "#00feff", "#00fe22", "#fff600" },
	[PALETTE_CANDY] = { "#fff88d", "#ffa7c6", "#fe86ff", "#ff55ff", "#3fe2ff" },
	[PALETTE_RED] = { "#7e0404", "#9a0505", "#fc0000", "#9a0505", "#7e0404" },
}

local WRITE_COLOR = "Color"
local WRITE_ROTATION = "Rotation"

type StyleDef = {
	writes: { [string]: boolean },
	onStart: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
	onTick: (UIGradient, { [string]: any }, number, { [string]: any }) -> (),
	onStop: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
}

type StyleSlot = {
	def: StyleDef,
	ctx: { [string]: any },
	opts: { [string]: any },
}

type InstState = {
	styles: { [string]: StyleSlot },
	ancestryConnection: RBXScriptConnection?,
}

local _styleDefs: { [string]: StyleDef } = {}
local _instances: { [UIGradient]: InstState } = {}
local _heartbeat: RBXScriptConnection? = nil
local _instanceCount = 0

--[[
	浅拷贝 opts，避免调用方表被样式写回
	@param src { [string]: any }? - 源表
	@return { [string]: any } - 拷贝结果
]]
local function _copyOpts(src: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = {}
	if not src then
		return out
	end
	for key, value in src do
		out[key] = value
	end
	return out
end

--[[
	将 writes 数组转成集合
	@param writes { string }? - 写口名列表（Color / Rotation / Offset / Transparency）
	@return { [string]: boolean } - 集合
]]
local function _writesSet(writes: { string }?): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if not writes then
		return set
	end
	for _, name in writes do
		if typeof(name) == "string" and name ~= "" then
			set[name] = true
		end
	end
	return set
end

--[[
	两写口集合是否相交
	@param a { [string]: boolean } - 集合 A
	@param b { [string]: boolean } - 集合 B
	@return boolean - 有交集时 true
]]
local function _writesOverlap(a: { [string]: boolean }, b: { [string]: boolean }): boolean
	for name in a do
		if b[name] then
			return true
		end
	end
	return false
end

--[[
	解析目标上的 UIGradient（自身或子级）
	@param target Instance - UIGradient 或挂载父节点
	@return UIGradient? - 渐变实例
]]
local function _resolveGradient(target: Instance): UIGradient?
	if target:IsA("UIGradient") then
		return target
	end
	return target:FindFirstChildOfClass("UIGradient")
end

--[[
	拷贝色板色序（避免对外漏出内部表）
	@param src { string } - 源色序
	@return { string } - 拷贝
]]
local function _copyHexList(src: { string }): { string }
	local out: { string } = {}
	for i, hex in src do
		out[i] = hex
	end
	return out
end

--[[
	hex / Color3 转为 Color3
	@param value any - "#rrggbb" / "rrggbb" / Color3
	@return Color3? - 无法解析时 nil
]]
local function _toColor3(value: any): Color3?
	if typeof(value) == "Color3" then
		return value
	end
	if typeof(value) ~= "string" then
		return nil
	end
	local hex = string.gsub(value, "^#", "")
	local ok, color = pcall(Color3.fromHex, hex)
	if ok and typeof(color) == "Color3" then
		return color
	end
	return nil
end

--[[
	按色板名取色序拷贝
	@param name string - 色板名
	@return { string }? - 未注册时 nil
]]
local function _getPaletteColors(name: string): { string }?
	local src = _palettes[name]
	if not src then
		return nil
	end
	return _copyHexList(src)
end

--[[
	色列表展开为带环绕的索引表（覆盖 5 色 -1～8 与 6 色 -1～10）
	@param colors { any } - Color3 或 hex 数组（至少 2 项；可含重复以表达往复）
	@return { [number]: Color3 }? - 失败时 nil
]]
local function _colorMapFromList(colors: { any }): { [number]: Color3 }?
	local unique: { Color3 } = {}
	for _, item in colors do
		local color = _toColor3(item)
		if color then
			table.insert(unique, color)
		end
	end
	local count = #unique
	if count < 2 then
		return nil
	end
	local map: { [number]: Color3 } = {}
	for index = -1, count * 2 do
		local seq = ((index + 1) % count) + 1
		map[index] = unique[seq]
	end
	return map
end

--[[
	解析 ColorScroll 用色：opts.colors > opts.palette > Attribute GradientAnimPalette > 默认彩虹柔
	@param gradient UIGradient - 目标，可读 Attribute
	@param opts { [string]: any } - 播放参数
	@return { [number]: Color3 } - 索引色表
]]
local function _resolveColorScrollMap(gradient: UIGradient, opts: { [string]: any }): { [number]: Color3 }
	if typeof(opts.colors) == "table" then
		local fromColors = _colorMapFromList(opts.colors)
		if fromColors then
			return fromColors
		end
		Log.warn("[Gradients.Anim] ColorScroll colors 无效，回退色板")
	end

	local paletteName: string? = nil
	if typeof(opts.palette) == "string" and opts.palette ~= "" then
		paletteName = opts.palette
	else
		local attr = gradient:GetAttribute(ATTR_GRADIENT_ANIM_PALETTE)
		if typeof(attr) == "string" and attr ~= "" then
			paletteName = attr
		end
	end
	if paletteName then
		local listed = _getPaletteColors(paletteName)
		if listed then
			local fromPalette = _colorMapFromList(listed)
			if fromPalette then
				return fromPalette
			end
		end
		Log.warn("[Gradients.Anim] 未注册色板，回退", paletteName, DEFAULT_COLOR_SCROLL_PALETTE)
	end

	local fallback = _getPaletteColors(DEFAULT_COLOR_SCROLL_PALETTE)
	return _colorMapFromList(fallback :: { string }) :: { [number]: Color3 }
end

--[[
	保证 ColorSequence 关键点：排序、去重、0/1 端点、至少两点
	@param list { ColorSequenceKeypoint } - 未规范化列表
	@return ColorSequence? - 非法时 nil
]]
local function _makeColorSequence(list: { ColorSequenceKeypoint }): ColorSequence?
	if #list == 0 then
		return nil
	end
	table.sort(list, function(a, b)
		return a.Time < b.Time
	end)
	local cleaned: { ColorSequenceKeypoint } = {}
	local lastTime: number? = nil
	for _, kp in list do
		local t = math.clamp(kp.Time, 0, 1)
		if lastTime == nil or t > lastTime + 1e-5 then
			table.insert(cleaned, ColorSequenceKeypoint.new(t, kp.Value))
			lastTime = t
		end
	end
	if #cleaned == 0 then
		return nil
	end
	if cleaned[1].Time > 0 then
		table.insert(cleaned, 1, ColorSequenceKeypoint.new(0, cleaned[1].Value))
	end
	if cleaned[#cleaned].Time < 1 then
		table.insert(cleaned, ColorSequenceKeypoint.new(1, cleaned[#cleaned].Value))
	end
	if #cleaned < 2 then
		return nil
	end
	local ok, seq = pcall(function()
		return ColorSequence.new(cleaned)
	end)
	if ok then
		return seq
	end
	return nil
end

--[[
	按时间轴重建色带 ColorSequence（对齐原预制体脚本）
	@param timeline number - 当前时间轴
	@param colorMap { [number]: Color3 } - 索引色表
	@param step number - 关键点间距
	@return ColorSequence? - 本帧序列
]]
local function _buildColorScrollSequence(
	timeline: number,
	colorMap: { [number]: Color3 },
	step: number
): ColorSequence?
	local list: { ColorSequenceKeypoint } = {}
	local endPoint = timeline + 1
	for index, color in colorMap do
		local cur = index * step
		if timeline - cur >= 0 and timeline - cur <= step then
			table.insert(list, ColorSequenceKeypoint.new(0, color))
			continue
		end
		if cur - endPoint >= 0 and cur - endPoint <= step then
			table.insert(list, ColorSequenceKeypoint.new(1, color))
			continue
		end
		if cur > timeline and cur < endPoint then
			local point = cur - timeline
			if point > 1 then
				point = point - 1
			end
			table.insert(list, ColorSequenceKeypoint.new(point, color))
		end
	end
	return _makeColorSequence(list)
end

--[[
	断开共用 Heartbeat（无实例时）
]]
local function _ensureHeartbeatStopped()
	if _instanceCount > 0 then
		return
	end
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end
end

--[[
	停止某实例上的一个样式槽（不调整 Heartbeat）
	@param gradient UIGradient - 目标
	@param styleName string - 样式名
	@param state InstState - 实例状态
]]
local function _stopSlot(gradient: UIGradient, styleName: string, state: InstState)
	local slot = state.styles[styleName]
	if not slot then
		return
	end
	state.styles[styleName] = nil
	if slot.def.onStop then
		slot.def.onStop(gradient, slot.ctx, slot.opts)
	end
end

--[[
	停止实例全部样式并从表移除
	@param gradient UIGradient - 目标
]]
local function _stopAll(gradient: UIGradient)
	local state = _instances[gradient]
	if not state then
		return
	end
	local styleNames: { string } = {}
	for styleName in state.styles do
		table.insert(styleNames, styleName)
	end
	for _, styleName in styleNames do
		_stopSlot(gradient, styleName, state)
	end
	if state.ancestryConnection then
		state.ancestryConnection:Disconnect()
		state.ancestryConnection = nil
	end
	_instances[gradient] = nil
	_instanceCount -= 1
	_ensureHeartbeatStopped()
end

--[[
	共用 Heartbeat：无 Parent 则停，否则 tick 各样式
	@param dt number - 帧间隔秒
]]
local function _onHeartbeat(dt: number)
	local dead: { UIGradient } = {}
	for gradient, state in _instances do
		if gradient.Parent == nil then
			table.insert(dead, gradient)
		else
			for _, slot in state.styles do
				slot.def.onTick(gradient, slot.ctx, dt, slot.opts)
			end
		end
	end
	for _, gradient in dead do
		_stopAll(gradient)
	end
end

--[[
	确保 Heartbeat 已连接
]]
local function _ensureHeartbeat()
	if _heartbeat or not IS_CLIENT then
		return
	end
	_heartbeat = RunService.Heartbeat:Connect(_onHeartbeat)
end

--[[
	取得或创建实例状态
	@param gradient UIGradient - 目标
	@return InstState - 状态
]]
local function _getOrCreateState(gradient: UIGradient): InstState
	local state = _instances[gradient]
	if state then
		return state
	end
	state = {
		styles = {},
		ancestryConnection = nil,
	}
	state.ancestryConnection = gradient.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			_stopAll(gradient)
		end
	end)
	_instances[gradient] = state
	_instanceCount += 1
	_ensureHeartbeat()
	return state
end

--[[
	注册内置 ColorScroll / Rotation
]]
local function _registerBuiltinStyles()
	_styleDefs.ColorScroll = {
		writes = { [WRITE_COLOR] = true },
		onStart = function(gradient: UIGradient, ctx: { [string]: any }, opts: { [string]: any })
			local period = opts.period
			if typeof(period) ~= "number" or period <= 0 then
				period = COLOR_SCROLL_PERIOD
			end
			local step = opts.step
			if typeof(step) ~= "number" or step <= 0 then
				step = COLOR_SCROLL_STEP
			end
			ctx.period = period
			ctx.step = step
			ctx.totalLen = period * (1 + step)
			ctx.total = 0
			ctx.colorMap = _resolveColorScrollMap(gradient, opts)
		end,
		onTick = function(gradient: UIGradient, ctx: { [string]: any }, dt: number, _opts: { [string]: any })
			ctx.total -= dt
			local timeline = ctx.total / ctx.period - ctx.step
			if timeline >= -ctx.step then
				local seq = _buildColorScrollSequence(timeline, ctx.colorMap, ctx.step)
				if seq then
					gradient.Color = seq
				end
			else
				ctx.total = ctx.totalLen
			end
		end,
	}

	_styleDefs.Rotation = {
		writes = { [WRITE_ROTATION] = true },
		onStart = function(gradient: UIGradient, ctx: { [string]: any }, opts: { [string]: any })
			local degPerSec = opts.degPerSec
			if typeof(degPerSec) ~= "number" then
				degPerSec = ROTATION_DEG_PER_SEC
			end
			ctx.degPerSec = degPerSec
			ctx.rot = gradient.Rotation
		end,
		onTick = function(gradient: UIGradient, ctx: { [string]: any }, dt: number, _opts: { [string]: any })
			ctx.rot = (ctx.rot + ctx.degPerSec * dt) % 360
			gradient.Rotation = ctx.rot
		end,
	}
end

_registerBuiltinStyles()

--[[
	按逗号拆 Attribute GradientAnim
	@param raw string - 原始字符串
	@return { string } - 样式名列表
]]
local function _splitStyleNames(raw: string): { string }
	local names: { string } = {}
	for part in string.gmatch(raw, "[^,]+") do
		local name = string.gsub(part, "^%s+", "")
		name = string.gsub(name, "%s+$", "")
		if name ~= "" then
			table.insert(names, name)
		end
	end
	return names
end

--[[
	挂载循环 API 到 Gradients 表。
	@param Gradients table - 与 init 同一份导出表
	@return () - 无返回值
]]
return function(Gradients)
	--[[
		克隆出的 UIGradient 去掉子级脚本，避免预制体 LocalScript 与模块双跑
		@param gradient UIGradient - 克隆实例
		@return () - 无返回值
	]]
	function Gradients.PrepareClonedGradient(gradient: UIGradient)
		if not gradient or not gradient:IsA("UIGradient") then
			return
		end
		local toDestroy: { Instance } = {}
		for _, child in gradient:GetDescendants() do
			if child:IsA("LuaSourceContainer") then
				table.insert(toDestroy, child)
			end
		end
		for _, child in toDestroy do
			child:Destroy()
		end
	end

	--[[
		注册或覆盖 ColorScroll 色板（色序从原脚本 -1 项起一圈，不含环绕拷贝）
		@param name string - 色板名（如 彩虹柔 / 彩虹满）
		@param colors { any } - hex 或 Color3 数组，至少 2 色；可含重复（如红脉往复）
		@return () - 无返回值
	]]
	function Gradients.RegisterGradientAnimPalette(name: string, colors: { any })
		if typeof(name) ~= "string" or name == "" then
			Log.warn("[Gradients.Anim] RegisterGradientAnimPalette 名称非法")
			return
		end
		if typeof(colors) ~= "table" then
			Log.warn("[Gradients.Anim] RegisterGradientAnimPalette 缺少 colors", name)
			return
		end
		local stored: { string } = {}
		for _, item in colors do
			if typeof(item) == "Color3" then
				local c = item :: Color3
				table.insert(stored, string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)))
			elseif typeof(item) == "string" and item ~= "" then
				table.insert(stored, item)
			end
		end
		if not _colorMapFromList(stored) then
			Log.warn("[Gradients.Anim] RegisterGradientAnimPalette 色序无效", name)
			return
		end
		_palettes[name] = stored
	end

	--[[
		查询 ColorScroll 色板色序（拷贝，可改返回表不影响内部）
		@param name string - 色板名
		@return { string }? - hex 列表；未注册 nil
	]]
	function Gradients.GetGradientAnimPalette(name: string): { string }?
		if typeof(name) ~= "string" or name == "" then
			return nil
		end
		return _getPaletteColors(name)
	end

	--[[
		注册或覆盖循环样式（新表现只注册，不改 Core）
		@param styleName string - 样式名（如 ColorScroll / Rotation / 自定义）
		@param def { writes: { string }, onStart: ((UIGradient, table, table) -> ())?, onTick: (UIGradient, table, number, table) -> (), onStop: ((UIGradient, table, table) -> ())? } - writes 声明写口；onTick 每帧；ctx 由 onStart 填充
		@return () - 无返回值
	]]
	function Gradients.RegisterGradientAnimStyle(styleName: string, def: {
		writes: { string },
		onStart: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
		onTick: (UIGradient, { [string]: any }, number, { [string]: any }) -> (),
		onStop: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
	})
		if typeof(styleName) ~= "string" or styleName == "" then
			Log.warn("[Gradients.Anim] RegisterGradientAnimStyle 样式名非法")
			return
		end
		if typeof(def) ~= "table" or typeof(def.onTick) ~= "function" then
			Log.warn("[Gradients.Anim] RegisterGradientAnimStyle 缺少 onTick", styleName)
			return
		end
		local writes = _writesSet(def.writes)
		local hasWrite = false
		for _ in writes do
			hasWrite = true
			break
		end
		if not hasWrite then
			Log.warn("[Gradients.Anim] RegisterGradientAnimStyle 缺少 writes", styleName)
			return
		end
		_styleDefs[styleName] = {
			writes = writes,
			onStart = def.onStart,
			onTick = def.onTick,
			onStop = def.onStop,
		}
	end

	--[[
		停止目标上的循环表现
		@param target Instance - UIGradient 或其挂载父节点
		@param styleName string? - 指定样式；nil 则停全部
		@return () - 无返回值
	]]
	function Gradients.StopGradientAnim(target: Instance, styleName: string?)
		if not target then
			return
		end
		local gradient = _resolveGradient(target)
		if not gradient then
			return
		end
		local state = _instances[gradient]
		if not state then
			return
		end
		if styleName == nil then
			_stopAll(gradient)
			return
		end
		_stopSlot(gradient, styleName, state)
		local remain = false
		for _ in state.styles do
			remain = true
			break
		end
		if not remain then
			_stopAll(gradient)
		end
	end

	--[[
		在 UIGradient 上播放命名循环样式（仅客户端；服务端 no-op）
		@param gradient UIGradient - 目标渐变
		@param styleName string - 已注册样式名（内置 ColorScroll / Rotation）
		@param opts { [string]: any }? - ColorScroll 可用 period、step、palette、colors；Rotation 可用 degPerSec
		@return () - 无返回值
	]]
	function Gradients.PlayGradientAnim(gradient: UIGradient, styleName: string, opts: { [string]: any }?)
		if not IS_CLIENT then
			return
		end
		if not gradient or not gradient:IsA("UIGradient") then
			return
		end
		if gradient.Parent == nil then
			return
		end
		if typeof(styleName) ~= "string" or styleName == "" then
			return
		end
		local def = _styleDefs[styleName]
		if not def then
			Log.warn("[Gradients.Anim] 未注册样式", styleName)
			return
		end

		local state = _getOrCreateState(gradient)
		local toStop: { string } = {}
		for existingName, slot in state.styles do
			if existingName ~= styleName and _writesOverlap(def.writes, slot.def.writes) then
				table.insert(toStop, existingName)
			end
		end
		for _, name in toStop do
			_stopSlot(gradient, name, state)
		end
		if state.styles[styleName] then
			_stopSlot(gradient, styleName, state)
		end

		local playOpts = _copyOpts(opts)
		local ctx: { [string]: any } = {}
		if def.onStart then
			def.onStart(gradient, ctx, playOpts)
		end
		state.styles[styleName] = {
			def = def,
			ctx = ctx,
			opts = playOpts,
		}
	end

	--[[
		按预设名 / 别名 / Attribute GradientAnim 自动播放（无配置则忽略）
		@param gradient UIGradient - 目标渐变
		@param typeKey string? - AddGradientColor 的类型键或解析后的预设名
		@return () - 无返回值
	]]
	function Gradients.PlayGradientAnimForPreset(gradient: UIGradient, typeKey: string?)
		if not IS_CLIENT then
			return
		end
		if not gradient or not gradient:IsA("UIGradient") then
			return
		end

		local attr = gradient:GetAttribute(ATTR_GRADIENT_ANIM)
		if typeof(attr) == "string" and attr ~= "" then
			for _, name in _splitStyleNames(attr) do
				Gradients.PlayGradientAnim(gradient, name)
			end
			return
		end

		local keysToTry: { string } = {}
		if typeof(typeKey) == "string" and typeKey ~= "" then
			table.insert(keysToTry, typeKey)
			local resolved = GradientCfg[typeKey]
			if typeof(resolved) == "string" and resolved ~= typeKey then
				table.insert(keysToTry, resolved)
			end
		end
		local instName = gradient.Name
		if instName ~= "" then
			table.insert(keysToTry, instName)
		end

		local played = false
		for _, key in keysToTry do
			local entries = GradientAnimCfg[key]
			if entries then
				for _, entry in entries do
					if entry and typeof(entry.style) == "string" then
						Gradients.PlayGradientAnim(gradient, entry.style, entry.opts)
						played = true
					end
				end
				if played then
					return
				end
			end
		end
	end
end
