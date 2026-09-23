--!strict
--[[
	Module: SystemWorldGen
	Description: 服务端固定区域高度图表层地图生成（多材质 Part + Terrain 水体）
	Author: 程莘
	Created: 2026-09-23
	Last Modified: 2026-09-23

	功能：
	- Init：生成 SIZE_X×SIZE_Z（默认 2048×2048）表层地图到 workspace.程序化地图
	- 材质：Grass / Dirt / Sand / Lava 用 Map 下 Part 模板；Water 用 Terrain:FillBlock(Material.Water)
	- 高度图决定列高；海平面以下列铺沙底 + 水体；近岸沙；陆地草顶/泥侧；熔岩噪声覆盖地表
	- 分块 + 同材质贪婪合并；Clone 后 Decal→Texture 并 StudsPerTile=BLOCK_SIZE
	- 不改 workspace.场景；无 Remote / 存档 / 挖方；不写角色位姿

	与相关模块：
	- AssetAcquire：Server scope 取 ServerStorage.Assets.Map.{Grass,Dirt,Sand,Lava}
	- AssetRegistry.Catalog.Map
	- WorldGenManager：唯一 Init 入口

	端侧约束：
	- 仅服务端；程序化地图 Part 与本模块写入的 Terrain 水体为本域唯一写口
	- 重生时按分块把该块 AABB 内 Terrain 置为 Air（禁止整图一次 FillBlock，会 Extents too large）

	加载：
		local SystemWorldGen = Utils.SystemWorldGen
		SystemWorldGen.Init()
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local AssetAcquire = Utils.AssetAcquire
local AssetRegistry = Utils.AssetRegistry

local Terrain = Workspace.Terrain

local SystemWorldGen = {}

-- ============================================================================
-- 常量
-- ============================================================================

local BLOCK_SIZE = 4
local SIZE_X = 2048
local SIZE_Y = 100
local SIZE_Z = 2048
local CHUNK_SIZE = 32
local SEED = 42
local ORIGIN = Vector3.new(0, 0, 0)

local BASE_HEIGHT = 18
local HEIGHT_AMP = 10
local HEIGHT_FREQ = 0.015

-- 海平面（格）：列高低于此则沙底 + Terrain 水；近岸 BEACH_BAND 格为沙
local SEA_LEVEL = 15
local BEACH_BAND = 2

-- 熔岩地表噪声（较高阈值 + 高阈值 → 稀疏散落）
local LAVA_FREQ = 0.025
local LAVA_THRESHOLD = 0.42

local MAT_GRASS = 1
local MAT_DIRT = 2
local MAT_SAND = 3
local MAT_LAVA = 4

local MAT_TEMPLATE_NAME: { [number]: string } = {
	[MAT_GRASS] = "Grass",
	[MAT_DIRT] = "Dirt",
	[MAT_SAND] = "Sand",
	[MAT_LAVA] = "Lava",
}

local FOLDER_NAME = "程序化地图"
local SPAWN_BATCH = 200
local WATER_BATCH = 100
-- Terrain:FillBlock 单次轴长上限（整图 8192 会报 Extents are too large）
local MAX_TERRAIN_FILL_AXIS = 512

-- ============================================================================
-- 私有状态
-- ============================================================================

local _inited = false
local _templates: { [number]: BasePart } = {}

export type VoxelRun = {
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	mat: number,
}

-- ============================================================================
-- 私有函数：高度 / 材质
-- ============================================================================

--[[
	采样地表高度（连续格）
	@param x number - 世界格 X
	@param z number - 世界格 Z
	@return number - 高度
]]
local function _sampleHeight(x: number, z: number): number
	local n = math.noise(x * HEIGHT_FREQ, SEED * 0.01, z * HEIGHT_FREQ)
	return BASE_HEIGHT + n * HEIGHT_AMP
end

--[[
	列顶面高度（整数格）；越界 -1
	@param x number - 世界格 X
	@param z number - 世界格 Z
	@return number - 顶面 Y
]]
local function _columnHeight(x: number, z: number): number
	if x < 0 or x >= SIZE_X or z < 0 or z >= SIZE_Z then
		return -1
	end
	local h = math.floor(_sampleHeight(x, z))
	if h < 0 then
		return -1
	end
	if h >= SIZE_Y then
		return SIZE_Y - 1
	end
	return h
end

--[[
	该列是否熔岩热点（仅影响陆地顶面）
	@param x number - 世界格 X
	@param z number - 世界格 Z
	@return boolean - 是否熔岩
]]
local function _isLavaHotspot(x: number, z: number): boolean
	local n = math.noise(x * LAVA_FREQ, SEED * 0.03, z * LAVA_FREQ)
	return n >= LAVA_THRESHOLD
end

--[[
	是否表层实心（顶面或悬崖侧面）
	@param x number - 世界格 X
	@param y number - 世界格 Y
	@param z number - 世界格 Z
	@return boolean - 是否有方块
]]
local function _isSolidWorld(x: number, y: number, z: number): boolean
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z then
		return false
	end
	local h = _columnHeight(x, z)
	if y > h then
		return false
	end
	if y == h then
		return true
	end
	local minNeighbor = math.min(
		_columnHeight(x + 1, z),
		_columnHeight(x - 1, z),
		_columnHeight(x, z + 1),
		_columnHeight(x, z - 1)
	)
	return y >= minNeighbor
end

--[[
	表层方块材质（不含 Water）
	@param x number - 世界格 X
	@param y number - 世界格 Y
	@param z number - 世界格 Z
	@return number? - MAT_*；非实心 nil
]]
local function _partMaterialAt(x: number, y: number, z: number): number?
	if not _isSolidWorld(x, y, z) then
		return nil
	end
	local h = _columnHeight(x, z)
	local nearShore = h <= SEA_LEVEL + BEACH_BAND
	local isTop = y == h

	if isTop then
		if h < SEA_LEVEL or nearShore then
			return MAT_SAND
		end
		if _isLavaHotspot(x, z) then
			return MAT_LAVA
		end
		return MAT_GRASS
	end

	-- 悬崖侧面
	if nearShore then
		return MAT_SAND
	end
	if _isLavaHotspot(x, z) and y >= h - 1 then
		return MAT_LAVA
	end
	return MAT_DIRT
end

--[[
	是否应由 Terrain 填水（海平面以下、列顶之上）
	@param x number - 世界格 X
	@param y number - 世界格 Y
	@param z number - 世界格 Z
	@return boolean - 是否水体格
]]
local function _isWaterCell(x: number, y: number, z: number): boolean
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z then
		return false
	end
	if y > SEA_LEVEL then
		return false
	end
	local h = _columnHeight(x, z)
	return y > h
end

-- ============================================================================
-- 私有函数：分块网格 / 贪婪
-- ============================================================================

--[[
	局部下标
	@param lx number - 局部 X
	@param ly number - 局部 Y
	@param lz number - 局部 Z
	@param dimX number - 局部宽
	@param dimY number - 局部高
	@return number - 一维下标
]]
local function _localIndex(lx: number, ly: number, lz: number, dimX: number, dimY: number): number
	return lx + ly * dimX + lz * dimX * dimY + 1
end

--[[
	对材质/水体 mask 做核内同值贪婪合并
	@param values {number} - 0=空，非0=可合并键（材质或 1=水）
	@param padMinX number - padding 世界 X
	@param padMinZ number - padding 世界 Z
	@param dimX number - 局部宽
	@param dimY number - 局部高
	@param dimZ number - 局部深
	@param coreLx0 number - 核局部 X0
	@param coreLz0 number - 核局部 Z0
	@param coreW number - 核宽
	@param coreD number - 核深
	@param asMat boolean - true 时 run.mat=格子值；false 时 mat=0（水体）
	@return {VoxelRun} - 合并结果
]]
local function _greedyByValue(
	values: { number },
	padMinX: number,
	padMinZ: number,
	dimX: number,
	dimY: number,
	dimZ: number,
	coreLx0: number,
	coreLz0: number,
	coreW: number,
	coreD: number,
	asMat: boolean
): { VoxelRun }
	local total = dimX * dimY * dimZ
	local visited = table.create(total, false)
	local runs: { VoxelRun } = {}
	local coreLx1 = coreLx0 + coreW
	local coreLz1 = coreLz0 + coreD

	for lz = coreLz0, coreLz1 - 1 do
		for ly = 0, dimY - 1 do
			for lx = coreLx0, coreLx1 - 1 do
				local i0 = _localIndex(lx, ly, lz, dimX, dimY)
				local key = values[i0]
				if key ~= 0 and not visited[i0] then
					local sx = 1
					while lx + sx < coreLx1 do
						local j = _localIndex(lx + sx, ly, lz, dimX, dimY)
						if values[j] ~= key or visited[j] then
							break
						end
						sx += 1
					end

					local sz = 1
					while lz + sz < coreLz1 do
						local ok = true
						for dx = 0, sx - 1 do
							local j = _localIndex(lx + dx, ly, lz + sz, dimX, dimY)
							if values[j] ~= key or visited[j] then
								ok = false
								break
							end
						end
						if not ok then
							break
						end
						sz += 1
					end

					local sy = 1
					while ly + sy < dimY do
						local ok = true
						for dz = 0, sz - 1 do
							for dx = 0, sx - 1 do
								local j = _localIndex(lx + dx, ly + sy, lz + dz, dimX, dimY)
								if values[j] ~= key or visited[j] then
									ok = false
									break
								end
							end
							if not ok then
								break
							end
						end
						if not ok then
							break
						end
						sy += 1
					end

					for dz = 0, sz - 1 do
						for dy = 0, sy - 1 do
							for dx = 0, sx - 1 do
								visited[_localIndex(lx + dx, ly + dy, lz + dz, dimX, dimY)] = true
							end
						end
					end

					table.insert(runs, {
						x = padMinX + lx,
						y = ly,
						z = padMinZ + lz,
						sx = sx,
						sy = sy,
						sz = sz,
						mat = if asMat then key else 0,
					})
				end
			end
		end
	end

	return runs
end

--[[
	处理一块：Part 材质 runs + 水体 runs
	@param ox number - 核区世界 X
	@param oz number - 核区世界 Z
	@param coreW number - 核宽
	@param coreD number - 核深
	@return {VoxelRun} - Part runs
	@return {VoxelRun} - Water runs
	@return number - Part 暴露格数
]]
local function _processChunk(ox: number, oz: number, coreW: number, coreD: number): ({ VoxelRun }, { VoxelRun }, number)
	local padMinX = math.max(0, ox - 1)
	local padMinZ = math.max(0, oz - 1)
	local padMaxX = math.min(SIZE_X, ox + coreW + 1)
	local padMaxZ = math.min(SIZE_Z, oz + coreD + 1)
	local dimX = padMaxX - padMinX
	local dimY = SIZE_Y
	local dimZ = padMaxZ - padMinZ
	local total = dimX * dimY * dimZ

	local solidMat = table.create(total, 0)
	local waterMask = table.create(total, 0)

	for lz = 0, dimZ - 1 do
		local wz = padMinZ + lz
		for ly = 0, dimY - 1 do
			for lx = 0, dimX - 1 do
				local wx = padMinX + lx
				local i = _localIndex(lx, ly, lz, dimX, dimY)
				local mat = _partMaterialAt(wx, ly, wz)
				if mat ~= nil then
					solidMat[i] = mat
				elseif _isWaterCell(wx, ly, wz) then
					waterMask[i] = 1
				end
			end
		end
	end

	local function solidLocal(lx: number, ly: number, lz: number): boolean
		if lx < 0 or lx >= dimX or ly < 0 or ly >= dimY or lz < 0 or lz >= dimZ then
			return false
		end
		return solidMat[_localIndex(lx, ly, lz, dimX, dimY)] ~= 0
	end

	local exposed = table.create(total, 0)
	local exposedCount = 0
	local coreLx0 = ox - padMinX
	local coreLz0 = oz - padMinZ

	for lz = coreLz0, coreLz0 + coreD - 1 do
		for ly = 0, dimY - 1 do
			for lx = coreLx0, coreLx0 + coreW - 1 do
				local i = _localIndex(lx, ly, lz, dimX, dimY)
				local mat = solidMat[i]
				if mat ~= 0 then
					local keep = not (
						solidLocal(lx + 1, ly, lz)
						and solidLocal(lx - 1, ly, lz)
						and solidLocal(lx, ly + 1, lz)
						and solidLocal(lx, ly - 1, lz)
						and solidLocal(lx, ly, lz + 1)
						and solidLocal(lx, ly, lz - 1)
					)
					if keep then
						exposed[i] = mat
						exposedCount += 1
					end
				end
			end
		end
	end

	local partRuns = _greedyByValue(exposed, padMinX, padMinZ, dimX, dimY, dimZ, coreLx0, coreLz0, coreW, coreD, true)
	local waterRuns = _greedyByValue(waterMask, padMinX, padMinZ, dimX, dimY, dimZ, coreLx0, coreLz0, coreW, coreD, false)
	return partRuns, waterRuns, exposedCount
end

-- ============================================================================
-- 私有函数：实例化
-- ============================================================================

--[[
	加载 Map 下 Part 模板；缺哪个 warn，不中断
]]
local function _loadTemplates()
	table.clear(_templates)
	for matId, name in MAT_TEMPLATE_NAME do
		local path = AssetRegistry.BuildCatalogPath(AssetRegistry.Catalog.Map, name)
		local tpl = AssetAcquire.GetTemplate(path, AssetAcquire.Scope.Server)
		if tpl and tpl:IsA("BasePart") then
			_templates[matId] = tpl
		else
			Log.warn("[SystemWorldGen] missing BasePart template:", path)
		end
	end
end

--[[
	清空输出 Folder（Terrain 按分块在生成循环里清，避免整图 Extents 超限）
	@return Folder - workspace.程序化地图
]]
local function _prepareFolder(): Folder
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

--[[
	单次 FillBlock；若任一轴超过上限则沿最大轴对半递归切开
	@param cf CFrame - 盒子中心
	@param size Vector3 - 盒子尺寸（studs）
	@param material Enum.Material - 材质
]]
local function _fillTerrainSafe(cf: CFrame, size: Vector3, material: Enum.Material)
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return
	end
	if size.X <= MAX_TERRAIN_FILL_AXIS and size.Y <= MAX_TERRAIN_FILL_AXIS and size.Z <= MAX_TERRAIN_FILL_AXIS then
		Terrain:FillBlock(cf, size, material)
		return
	end
	-- 沿最长轴切开
	local axis = "X"
	local longest = size.X
	if size.Y > longest then
		axis = "Y"
		longest = size.Y
	end
	if size.Z > longest then
		axis = "Z"
	end
	if axis == "X" then
		local half = size.X * 0.5
		local offset = cf.RightVector * (half * 0.5)
		_fillTerrainSafe(cf - offset, Vector3.new(half, size.Y, size.Z), material)
		_fillTerrainSafe(cf + offset, Vector3.new(size.X - half, size.Y, size.Z), material)
	elseif axis == "Y" then
		local half = size.Y * 0.5
		local offset = cf.UpVector * (half * 0.5)
		_fillTerrainSafe(cf - offset, Vector3.new(size.X, half, size.Z), material)
		_fillTerrainSafe(cf + offset, Vector3.new(size.X, size.Y - half, size.Z), material)
	else
		local half = size.Z * 0.5
		-- 轴对齐盒子用世界 Z 切开
		local worldOffset = Vector3.new(0, 0, half * 0.5)
		_fillTerrainSafe(cf - worldOffset, Vector3.new(size.X, size.Y, half), material)
		_fillTerrainSafe(cf + worldOffset, Vector3.new(size.X, size.Y, size.Z - half), material)
	end
end

--[[
	将一块水平核区对应的 Terrain 体积置为 Air
	@param ox number - 核区世界格 X
	@param oz number - 核区世界格 Z
	@param coreW number - 核宽（格）
	@param coreD number - 核深（格）
]]
local function _clearChunkTerrain(ox: number, oz: number, coreW: number, coreD: number)
	local size = Vector3.new(coreW * BLOCK_SIZE, SIZE_Y * BLOCK_SIZE, coreD * BLOCK_SIZE)
	local minCorner = ORIGIN + Vector3.new(ox * BLOCK_SIZE, 0, oz * BLOCK_SIZE)
	local center = minCorner + size * 0.5
	_fillTerrainSafe(CFrame.new(center), size, Enum.Material.Air)
end

--[[
	Decal→Texture + StudsPerTile 平铺
	@param part BasePart - Clone 实例
]]
local function _applyTiledFaceTextures(part: BasePart)
	local children = part:GetChildren()
	for _, child in children do
		if child:IsA("Decal") then
			local tex = Instance.new("Texture")
			tex.Name = child.Name
			tex.Face = child.Face
			tex.Texture = child.Texture
			tex.Color3 = child.Color3
			tex.Transparency = child.Transparency
			tex.ZIndex = child.ZIndex
			tex.StudsPerTileU = BLOCK_SIZE
			tex.StudsPerTileV = BLOCK_SIZE
			tex.Parent = part
			child:Destroy()
		elseif child:IsA("Texture") then
			child.StudsPerTileU = BLOCK_SIZE
			child.StudsPerTileV = BLOCK_SIZE
		end
	end
end

--[[
	实例化 Part runs
	@param folder Folder - 父级
	@param runs {VoxelRun} - 带 mat 的合并盒
	@param spawnedSoFar number - 累计
	@return number - 新累计
]]
local function _spawnPartRuns(folder: Folder, runs: { VoxelRun }, spawnedSoFar: number): number
	local spawned = spawnedSoFar
	for _, run in runs do
		local template = _templates[run.mat]
		if not template then
			continue
		end
		local part = template:Clone()
		if not part:IsA("BasePart") then
			part:Destroy()
			continue
		end
		local size = Vector3.new(run.sx * BLOCK_SIZE, run.sy * BLOCK_SIZE, run.sz * BLOCK_SIZE)
		local minCorner = ORIGIN + Vector3.new(run.x * BLOCK_SIZE, run.y * BLOCK_SIZE, run.z * BLOCK_SIZE)
		local center = minCorner + size * 0.5
		part.Size = size
		part.CFrame = CFrame.new(center)
		part.Anchored = true
		part.CanCollide = true
		part.CanTouch = false
		part.CanQuery = true
		_applyTiledFaceTextures(part)
		part.Parent = folder
		spawned += 1
		if spawned % SPAWN_BATCH == 0 then
			task.wait()
		end
	end
	return spawned
end

--[[
	Terrain 填水（合并盒）
	@param runs {VoxelRun} - 水体盒
	@param filledSoFar number - 累计 Fill 次数
	@return number - 新累计
]]
local function _fillWaterRuns(runs: { VoxelRun }, filledSoFar: number): number
	local filled = filledSoFar
	for _, run in runs do
		local size = Vector3.new(run.sx * BLOCK_SIZE, run.sy * BLOCK_SIZE, run.sz * BLOCK_SIZE)
		local minCorner = ORIGIN + Vector3.new(run.x * BLOCK_SIZE, run.y * BLOCK_SIZE, run.z * BLOCK_SIZE)
		local center = minCorner + size * 0.5
		_fillTerrainSafe(CFrame.new(center), size, Enum.Material.Water)
		filled += 1
		if filled % WATER_BATCH == 0 then
			task.wait()
		end
	end
	return filled
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	生成地图（幂等重建 Folder + 清空地图区 Terrain）
	@return () - 无返回；全部 Part 模板缺失则 warn 后仍可只填水
]]
function SystemWorldGen.Init()
	if _inited then
		Log.print("[SystemWorldGen] already inited, regenerating")
	end
	_inited = true

	_loadTemplates()
	local hasAnyPart = next(_templates) ~= nil
	if not hasAnyPart then
		Log.warn("[SystemWorldGen] no Part templates loaded; only Terrain water may generate")
	end

	Log.print(
		"[SystemWorldGen] start",
		SIZE_X,
		"x",
		SIZE_Y,
		"x",
		SIZE_Z,
		"sea",
		SEA_LEVEL,
		"chunk",
		CHUNK_SIZE
	)

	local folder = _prepareFolder()
	local totalExposed = 0
	local totalPartRuns = 0
	local totalWaterRuns = 0
	local spawned = 0
	local waterFills = 0
	local chunkCount = 0

	for oz = 0, SIZE_Z - 1, CHUNK_SIZE do
		local coreD = math.min(CHUNK_SIZE, SIZE_Z - oz)
		for ox = 0, SIZE_X - 1, CHUNK_SIZE do
			local coreW = math.min(CHUNK_SIZE, SIZE_X - ox)
			_clearChunkTerrain(ox, oz, coreW, coreD)
			local partRuns, waterRuns, exposedCount = _processChunk(ox, oz, coreW, coreD)
			totalExposed += exposedCount
			totalPartRuns += #partRuns
			totalWaterRuns += #waterRuns
			spawned = _spawnPartRuns(folder, partRuns, spawned)
			waterFills = _fillWaterRuns(waterRuns, waterFills)
			chunkCount += 1
			task.wait()
		end
		if oz % (CHUNK_SIZE * 4) == 0 then
			Log.print("[SystemWorldGen] progress z=", oz, "/", SIZE_Z, "parts=", spawned, "waterFills=", waterFills)
		end
	end

	Log.print(
		"[SystemWorldGen] done chunks=",
		chunkCount,
		"exposed=",
		totalExposed,
		"partRuns=",
		totalPartRuns,
		"waterRuns=",
		totalWaterRuns,
		"parts=",
		spawned,
		"waterFills=",
		waterFills
	)
end

return SystemWorldGen