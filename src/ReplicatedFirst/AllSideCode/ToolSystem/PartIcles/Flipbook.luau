--[[
	Module: Flipbook
	Description: Part 网格 / Beam / ImageLabel 的贴图序列播放（Flipbooks 文件夹按名排序）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- GetSortedTextures / GetSortedBeamTextures：读取并预加载贴图 ID 列表
	- Flip / FlipBeam：按 Loop 或 OneShot 驱动目标属性（Texture / TextureID / ColorMap）

	模块关系：
	- 表名 MeshFlipbook（历史导出名，公共 API 不变）；GetData / Emit / TrailEmitter 引用
	- 帧索引走 pData._effectiveElapsed，因而 Timescale / FreezeTime / Pause / 反向都影响播放
	- SurfaceAppearance.ColorMap 仅插件可写；运行时失败 warn 一次后建议改用 Decal/Texture
	- pData 为 nil 时回退墙钟 elapsed（兼容旧调用）

	加载方式：
		local MeshFlipbook = require(script.Parent.Flipbook)

	使用示例：
		local ids = MeshFlipbook.GetSortedTextures(flipbookFolder)
		MeshFlipbook.Flip(pData, particle, ids, meshPart, lifetime)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ContentProvider = Utils.ContentProvider
local Log = Utils.Log
local RangeMod = require(script.Parent.Range)
local MeshFlipbook = {}

--[[
	发射时读一次 Flipbooks 子级 Decal/Texture，按名称数字排序并预加载。
	非 Decal/Texture 子级跳过。结果应由调用方缓存到 data.CachedMeshTextures。

	@param flipbookFolder Folder - 含编号 Decal/Texture 子级的文件夹
	@return {string} - 按名排序的 Texture 内容 ID 列表；无有效子级为空表
]]
function MeshFlipbook.GetSortedTextures(flipbookFolder: Folder): {string}
	local decalObjects = {}
	for _, child in pairs(flipbookFolder:GetChildren()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			table.insert(decalObjects, child)
		end
	end
	if #decalObjects == 0 then return {} end

	table.sort(decalObjects, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)

	local textures = {}
	for _, obj in ipairs(decalObjects) do
		table.insert(textures, obj.Texture)
	end

	-- Preload textures so frame swaps are instant.
	if #textures > 0 then
		task.spawn(function()
			ContentProvider:PreloadAsync(textures)
		end)
	end

	return textures
end

--[[
	与 GetSortedTextures 相同，但只收 Decal（Beam flipbook 文件夹）。

	@param flipbookFolder Folder - 含编号 Decal 子级的文件夹
	@return {string} - 按名排序的 Texture 内容 ID 列表
]]
function MeshFlipbook.GetSortedBeamTextures(flipbookFolder: Folder): {string}
	local decalObjects = {}
	for _, child in pairs(flipbookFolder:GetChildren()) do
		if child:IsA("Decal") then
			table.insert(decalObjects, child)
		end
	end
	if #decalObjects == 0 then return {} end

	table.sort(decalObjects, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)

	local textures = {}
	for _, obj in ipairs(decalObjects) do
		table.insert(textures, obj.Texture)
	end

	if #textures > 0 then
		task.spawn(function()
			ContentProvider:PreloadAsync(textures)
		end)
	end

	return textures
end

-- One-time warn for SurfaceAppearance.ColorMap write fails (PluginSecurity in runtime).
local _surfaceColorMapWarned = false

--[[
	把一帧贴图写到目标属性。ColorMap 写入失败时只 warn 一次（运行时 PluginSecurity）。

	@param target Instance - 被写属性的视觉件
	@param prop string - 属性名：ColorMap / TextureID / Texture
	@param value string - 贴图内容 ID
]]
local function _writeFrame(target, prop, value)
	local ok, err = pcall(function() target[prop] = value end)
	if not ok and prop == "ColorMap" and not _surfaceColorMapWarned then
		_surfaceColorMapWarned = true
		Log.warn(("[Part-Icles] SurfaceAppearance flipbook ColorMap write failed (%s). " ..
			"ColorMap is PluginSecurity  -  SurfaceAppearance flipbooks only animate in plugin context. " ..
			"For runtime games, use Decal / Texture flipbooks instead."):format(tostring(err)))
	end
end

--[[
	按实例类型选择贴图槽位。

	@param target Instance? - 视觉目标
	@return string - SurfaceAppearance→ColorMap；MeshPart→TextureID；其余→Texture
]]
local function _texProp(target)
	if target and target:IsA("SurfaceAppearance") then return "ColorMap" end
	if target and target:IsA("MeshPart") then return "TextureID" end
	return "Texture"
end

--[[
	Loop：在寿命内循环贴图。帧索引用 pData._effectiveElapsed，使 Timescale /
	FreezeTime / Pause / 反向都影响播放。墙钟上限是安全退出；主拆除仍由 Heartbeat 销毁视觉。

	@param pData table? - 粒子运行时；用 _effectiveElapsed / VisualPart；nil 回退墙钟
	@param particle table - 含 FlipbookFramerate / FlipbookReverse / FlipbookStartRandom
	@param decals {string} - 已排序贴图 ID
	@param target Instance - 被写贴图的实例
	@param lifetime number - 粒子寿命秒（循环墙钟上限为 lifetime*4）
]]
local function _loop(pData, particle, decals, target, lifetime)
	if #decals == 0 then return end

	local framerate = RangeMod.RandomValueFromRange(particle.FlipbookFramerate)
	-- Clamp to 0.1 so framerate=0 doesn't produce 1/0 = inf.
	if not framerate or framerate < 0.1 then framerate = 0.1 end
	local frameDelay = 1 / framerate
	local n = #decals
	local rev = particle.FlipbookReverse
	local startOffset = particle.FlipbookStartRandom and math.random(0, n - 1) or 0
	local startTime = os.clock()
	local prop = _texProp(target)

	task.spawn(function()
		local lastFrame = -1
		while os.clock() - startTime < lifetime * 4 do
			if not target or not target.Parent then return end
			if pData and (not pData.VisualPart or not pData.VisualPart.Parent) then return end
			local elapsed = (pData and pData._effectiveElapsed) or (os.clock() - startTime)
			local frameIndex = (math.floor(elapsed / frameDelay) + startOffset) % n + 1
			if rev then frameIndex = n - frameIndex + 1 end
			if frameIndex ~= lastFrame then
				_writeFrame(target, prop, decals[frameIndex])
				lastFrame = frameIndex
			end
			task.wait()
		end
	end)
end

--[[
	OneShot：在寿命内播完一遍，死亡前保证落到最后一帧。
	帧映射同样用 pData._effectiveElapsed（感知 Timescale / FreezeTime）。

	@param pData table? - 粒子运行时；nil 回退墙钟
	@param particle table - 含 FlipbookReverse / FlipbookStartRandom
	@param decals {string} - 已排序贴图 ID
	@param target Instance - 被写贴图的实例
	@param lifetime number - 粒子寿命秒
]]
local function _oneShot(pData, particle, decals, target, lifetime)
	if #decals == 0 then return end

	local n = #decals
	local rev = particle.FlipbookReverse
	local startOffset = particle.FlipbookStartRandom and math.random(0, n - 1) or 0
	local startTime = os.clock()
	local prop = _texProp(target)

	task.spawn(function()
		local lastFrame = -1
		while os.clock() - startTime < lifetime * 4 do
			if not target or not target.Parent then return end
			if pData and (not pData.VisualPart or not pData.VisualPart.Parent) then break end
			local elapsed = (pData and pData._effectiveElapsed) or (os.clock() - startTime)
			local frameIndex = math.min(math.floor(elapsed / lifetime * n) + 1, n)
			frameIndex = (frameIndex - 1 + startOffset) % n + 1
			if rev then frameIndex = n - frameIndex + 1 end
			if frameIndex ~= lastFrame then
				_writeFrame(target, prop, decals[frameIndex])
				lastFrame = frameIndex
			end
			task.wait()
		end
		if target and target.Parent then
			local finalFrame = (n - 1 + startOffset) % n + 1
			if rev then finalFrame = n - finalFrame + 1 end
			_writeFrame(target, prop, decals[finalFrame])
		end
	end)
end

--[[
	按 FlipbookMode 启动 Loop 或 OneShot。目标槽位由 _texProp 决定。
	pData 供 Timescale/FreezeTime/Pause/反向感知的帧索引；nil 回退墙钟。

	@param pData table? - 粒子运行时；nil 时用墙钟 elapsed
	@param particle table? - 须含 FlipbookMode；nil 或无模式则早退
	@param decals {string} - 已排序贴图 ID
	@param target Instance - Decal/Texture/SurfaceAppearance/MeshPart 等
	@param lifetime number - 粒子寿命秒
]]
function MeshFlipbook.Flip(pData, particle, decals: {string}, target, lifetime)
	if not particle or not particle.FlipbookMode then return end

	if particle.FlipbookMode == Enum.ParticleFlipbookMode.Loop then
		_loop(pData, particle, decals, target, lifetime)
	elseif particle.FlipbookMode == Enum.ParticleFlipbookMode.OneShot then
		_oneShot(pData, particle, decals, target, lifetime)
	end
end

--[[
	Beam 专用入口，语义同 Flip。

	@param pData table? - 粒子运行时；nil 回退墙钟
	@param flipbookParticle table? - 须含 FlipbookMode
	@param decals {string}? - 已排序贴图 ID；nil 早退
	@param beam Beam - 被写 Texture 的 Beam
	@param lifetime number - 粒子寿命秒
]]
function MeshFlipbook.FlipBeam(pData, flipbookParticle, decals: {string}, beam, lifetime)
	if not flipbookParticle or not decals or not flipbookParticle.FlipbookMode then return end

	local mode = flipbookParticle.FlipbookMode
	if mode == Enum.ParticleFlipbookMode.Loop then
		_loop(pData, flipbookParticle, decals, beam, lifetime)
	elseif mode == Enum.ParticleFlipbookMode.OneShot then
		_oneShot(pData, flipbookParticle, decals, beam, lifetime)
	end
end

return MeshFlipbook
