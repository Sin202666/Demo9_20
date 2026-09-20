--[[
	Module: Catalog
	Description: Sequence 资源目录扫描、查询与热重载（多图帧 / 图集；多图帧序号须连续）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	注意（客户端复制时序）：
	- FirstPreload / LoadingUI 可能在 Assets.Sequence 子帧尚未复制齐时首次查询
	- 仅 GetChildren 一次并永久缓存会导致「资源已齐仍 FRAME_GAP」
	- 因此：根目录未就绪不置 initialized；拒载条目在子节点数量变化时会按文件夹重扫

	多图帧扫描见 CatalogImages（Build / AreFrameIndicesContiguous）。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local AssetPaths = Utils.AssetPaths
local RunService = Utils.RunService
local ReplicatedStorage = Utils.ReplicatedStorage

local Types = require(script.Parent.Types)
local CatalogImages = require(script.Parent.CatalogImages)

type Folder = typeof(workspace:FindFirstChildOfClass("Folder"))
type StringValue = typeof(workspace:FindFirstChildOfClass("StringValue"))
type SequenceFrameData = Types.SequenceFrameData
type SheetLayout = Types.SheetLayout

local Catalog = {}

local loadedImageVt: { [string]: SequenceFrameData } = {}
-- 上次扫描时该序列 Folder 的直接子节点数；用于判断复制是否后又到齐
local _scannedChildCount: { [string]: number } = {}
-- 拒载后是否已做过「等待子节点稳定」重试（每序列至多一次，避免永久坏资源每次卡顿）
local _didSettleRetry: { [string]: boolean } = {}
local _initialized: boolean = false

-- 客户端等待 Assets.Sequence 出现的超时（秒）
local SEQUENCE_ROOT_WAIT_SEC = 5
local SEQUENCE_SETTLE_WAIT_SEC = 1.5
-- Heartbeat 连续多少拍子节点数量不变，视为本轮复制已到齐
local SETTLE_STABLE_TICKS = 2

--[[
	读取正数 Attribute
	@param inst Instance - 目标
	@param attrName string - Attribute 名
	@return number? - 有效正数
]]
local function _readPositiveNumberAttr(inst: Instance, attrName: string): number?
	local value = inst:GetAttribute(attrName)
	if typeof(value) == "number" and value > 0 then
		return value
	end
	return nil
end

--[[
	校验图集几何（纯函数，供扫描与公开 API 共用）
	@param columns number - 列数
	@param frameCount number - 帧数
	@param rows number? - 可选行数上限
	@return boolean - true 合法
	@return string? - 失败说明
]]
local function _validateSheetGeometry(columns: number, frameCount: number, rows: number?): (boolean, string?)
	if typeof(columns) ~= "number" or columns <= 0 then
		return false, "columns 须为正数"
	end
	if typeof(frameCount) ~= "number" or frameCount <= 0 then
		return false, "frameCount 须为正数"
	end
	local cols = math.floor(columns)
	local frames = math.floor(frameCount)
	local neededRows = math.ceil(frames / cols)
	if rows ~= nil then
		if typeof(rows) ~= "number" or rows <= 0 then
			return false, "rows 须为正数"
		end
		if neededRows > math.floor(rows) then
			return false, string.format("需要 %d 行，配置 Rows=%d 不足", neededRows, math.floor(rows))
		end
	end
	return true, nil
end

--[[
	解析图集 ImageId（Attribute 或同名 StringValue）
	@param folder Folder - 序列目录
	@return string? - rbxassetid
]]
local function _resolveSheetImageId(folder: Folder): string?
	local attr = folder:GetAttribute(Types.ATTR_SHEET_IMAGE)
	if typeof(attr) == "string" and attr ~= "" then
		return attr
	end

	local child = folder:FindFirstChild(Types.SHEET_IMAGE_VALUE_NAME)
	if child and child:IsA("StringValue") then
		local value = (child :: StringValue).Value
		if value ~= "" then
			return value
		end
	end

	return nil
end

--[[
	尝试从图集 Attribute 构建序列数据
	@param folder Folder - 序列目录
	@param folderName string - 序列名（仅用于日志）
	@return SequenceFrameData? - 图集数据；成功时非 nil
	@return boolean - true 表示目录含图集线索（即使配置不完整，也不应降级为多图）
]]
local function _tryBuildSheetData(folder: Folder, folderName: string): (SequenceFrameData?, boolean)
	local imageId = _resolveSheetImageId(folder)
	local cellWidth = _readPositiveNumberAttr(folder, Types.ATTR_CELL_WIDTH)
	local cellHeight = _readPositiveNumberAttr(folder, Types.ATTR_CELL_HEIGHT)
	local columns = _readPositiveNumberAttr(folder, Types.ATTR_COLUMNS)
	local frameCount = _readPositiveNumberAttr(folder, Types.ATTR_FRAME_COUNT)
	local rowsAttr = _readPositiveNumberAttr(folder, Types.ATTR_ROWS)

	local anySheetHint = imageId ~= nil
		or cellWidth ~= nil
		or cellHeight ~= nil
		or columns ~= nil
		or frameCount ~= nil
		or rowsAttr ~= nil

	if not anySheetHint then
		return nil, false
	end

	if not imageId or not cellWidth or not cellHeight or not columns or not frameCount then
		Log.warn(
			"[SequenceManager] 图集配置不完整（需 SheetImage/CellWidth/CellHeight/Columns/FrameCount），不降级为多图:",
			folderName
		)
		return nil, true
	end

	local geoOk, geoMsg = _validateSheetGeometry(columns, frameCount, rowsAttr)
	if not geoOk then
		Log.warn("[SequenceManager] 图集几何无效，不降级为多图:", folderName, geoMsg)
		return nil, true
	end

	local paddingAttr = folder:GetAttribute(Types.ATTR_PADDING)
	local spacingAttr = folder:GetAttribute(Types.ATTR_SPACING)
	local padding = if typeof(paddingAttr) == "number" and paddingAttr >= 0 then paddingAttr else 0
	local spacing = if typeof(spacingAttr) == "number" and spacingAttr >= 0 then spacingAttr else 0

	local layout: SheetLayout = table.freeze({
		imageId = imageId,
		cellWidth = cellWidth,
		cellHeight = cellHeight,
		columns = math.floor(columns),
		padding = padding,
		spacing = spacing,
		rows = if rowsAttr then math.floor(rowsAttr) else nil,
	})
	return table.freeze({
		kind = Types.SequenceKind.Sheet,
		frames = table.freeze({ imageId }),
		count = math.floor(frameCount),
		sheet = layout,
		rejectCode = nil,
	}), true
end

--[[
	构造不可播放的占位数据（count=0 + rejectCode）
	@param kind Types.SequenceKind - Images / Sheet
	@param rejectCode string - ErrorCode
	@return SequenceFrameData - 冻结占位
]]
local function _rejectedData(kind: Types.SequenceKind, rejectCode: string): SequenceFrameData
	return table.freeze({
		kind = kind,
		frames = table.freeze({} :: { string }),
		count = 0,
		sheet = nil,
		rejectCode = rejectCode,
	})
end

-- ============================================================================
-- 私有函数（根目录 / 复制时序）
-- ============================================================================

--[[
	解析 Assets.Sequence 根目录；客户端早期可短暂等待复制
	@return Folder? - Sequence catalog
]]
local function _getSequenceRoot(): Folder?
	local sequenceFolder: Folder? = AssetPaths.GetCatalog(Types.SEQUENCE_ROOT_NAME)
	if sequenceFolder then
		return sequenceFolder
	end

	-- AssetPaths 会缓存「未命中」；复制晚到时需清缓存再解析
	if RunService:IsClient() then
		AssetPaths.ClearCache()
		local assetsRoot = ReplicatedStorage:FindFirstChild(AssetPaths.ASSETS_ROOT_NAME)
		if not assetsRoot then
			assetsRoot = ReplicatedStorage:WaitForChild(AssetPaths.ASSETS_ROOT_NAME, SEQUENCE_ROOT_WAIT_SEC)
		end
		if assetsRoot then
			local waited = assetsRoot:FindFirstChild(Types.SEQUENCE_ROOT_NAME)
			if not waited then
				waited = assetsRoot:WaitForChild(Types.SEQUENCE_ROOT_NAME, SEQUENCE_ROOT_WAIT_SEC)
			end
		end
		sequenceFolder = AssetPaths.GetCatalog(Types.SEQUENCE_ROOT_NAME)
	end

	return sequenceFolder
end

--[[
	等待 Folder 直接子节点数量短暂稳定（缓解 GetChildren 扫到半截复制）
	@param folder Folder - 序列目录
	@param timeoutSec number - 最长等待秒数
]]
local function _waitFolderChildrenSettle(folder: Folder, timeoutSec: number): ()
	if not RunService:IsClient() then
		return
	end
	local deadline = os.clock() + timeoutSec
	local lastCount = -1
	local stableTicks = 0
	while os.clock() < deadline do
		local count = #folder:GetChildren()
		if count > 0 and count == lastCount then
			stableTicks += 1
			-- Heartbeat 两拍数量不变，视为本轮已到齐
			if stableTicks >= SETTLE_STABLE_TICKS then
				return
			end
		else
			stableTicks = 0
		end
		lastCount = count
		task.wait()
	end
end

--[[
	扫描单个序列 Folder 并写入缓存
	@param effectFolder Folder - 序列目录
	@param folderName string - 序列名
	@param allowSettle boolean? - true 时若首次拒载则短暂等待子节点稳定后重扫
	@return SequenceFrameData - 扫描结果
]]
local function _scanOneFolder(effectFolder: Folder, folderName: string, allowSettle: boolean?): SequenceFrameData
	--[[
		单次扫描并写入缓存（图集优先，失败不降级为多图）
		@return SequenceFrameData - 本轮扫描结果
	]]
	local function _buildOnce(): SequenceFrameData
		_scannedChildCount[folderName] = #effectFolder:GetChildren()

		local sheetData, isSheetAttempt = _tryBuildSheetData(effectFolder, folderName)
		if sheetData then
			loadedImageVt[folderName] = sheetData
			return sheetData
		end

		-- 有图集线索但配置不全：登记空序列，禁止静默当成多图帧播放
		if isSheetAttempt then
			local rejected = _rejectedData(Types.SequenceKind.Sheet, Types.ErrorCode.INVALID_SHEET)
			loadedImageVt[folderName] = rejected
			return rejected
		end

		local imagesData = CatalogImages.Build(effectFolder, folderName)
		loadedImageVt[folderName] = imagesData
		return imagesData
	end

	local data = _buildOnce()
	if allowSettle
		and RunService:IsClient()
		and data.count <= 0
		and data.rejectCode ~= nil
		and data.rejectCode ~= Types.ErrorCode.INVALID_SHEET
		and not _didSettleRetry[folderName]
	then
		_didSettleRetry[folderName] = true
		local before = #effectFolder:GetChildren()
		_waitFolderChildrenSettle(effectFolder, SEQUENCE_SETTLE_WAIT_SEC)
		local after = #effectFolder:GetChildren()
		if after > before then
			data = _buildOnce()
			if data.count > 0 then
				Log.warn(
					"[SequenceManager] 序列等待复制后重扫成功:",
					folderName,
					"帧数=",
					data.count,
					"子节点=",
					after
				)
			end
		else
			-- 数量未变也再 build 一次：可能同帧内 Value 才写完
			data = _buildOnce()
		end
	end

	return data
end

--[[
	若缓存为拒载 / 缺失 / 子节点增多，则重扫该序列
	@param sequenceName string - 序列名称
	@param data SequenceFrameData? - 当前缓存
	@return SequenceFrameData? - 最新数据
]]
local function _refreshIfStale(sequenceName: string, data: SequenceFrameData?): SequenceFrameData?
	local sequenceFolder = _getSequenceRoot()
	if not sequenceFolder then
		return data
	end

	local effectInst = sequenceFolder:FindFirstChild(sequenceName)
	if not effectInst or not effectInst:IsA("Folder") then
		return data
	end

	local effectFolder = effectInst :: Folder
	local liveCount = #effectFolder:GetChildren()
	local scannedCount = _scannedChildCount[sequenceName]
	local allowSettle = false
	local shouldRescan = false
	if data == nil then
		shouldRescan = true
		allowSettle = true
	elseif data.count <= 0 and data.rejectCode ~= nil then
		if scannedCount == nil or liveCount > scannedCount then
			shouldRescan = true
			allowSettle = true
		elseif not _didSettleRetry[sequenceName] then
			-- 全量扫描可能过早拒载；按名查询时再 settle 一次
			shouldRescan = true
			allowSettle = true
		end
	elseif scannedCount ~= nil and liveCount > scannedCount then
		shouldRescan = true
	end

	if not shouldRescan then
		return data
	end

	local refreshed = _scanOneFolder(effectFolder, sequenceName, allowSettle)
	if data and data.count <= 0 and refreshed.count > 0 then
		Log.warn(
			"[SequenceManager] 序列重扫成功（此前可能复制未齐）:",
			sequenceName,
			"帧数=",
			refreshed.count,
			"子节点=",
			#effectFolder:GetChildren()
		)
	end
	return refreshed
end

--[[
	扫描 Assets.Sequence 目录并写入缓存（幂等，需先清缓存再强制重载）
	@return boolean - true 根目录存在并已扫描
]]
local function _scanCatalog(): boolean
	local sequenceFolder: Folder? = _getSequenceRoot()
	if not sequenceFolder then
		Log.warn("[SequenceManager] 未找到 Assets.Sequence（AssetPaths）")
		return false
	end

	for _, child: Instance in sequenceFolder:GetChildren() do
		if not child:IsA("Folder") then
			continue
		end

		-- 全量扫描不 settle，避免 Loading 启动卡太久；按名查询时再 settle
		_scanOneFolder(child :: Folder, child.Name, false)
	end
	return true
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	判断已排序帧序号是否从最小值起连续无空洞（公开供契约自检）
	@param indices { number } - 已按升序排列的帧序号
	@return boolean - true 表示连续
]]
function Catalog.AreFrameIndicesContiguous(indices: { number }): boolean
	return CatalogImages.AreFrameIndicesContiguous(indices)
end

--[[
	懒加载序列配置（根目录未就绪时不锁死，允许后续重试）
]]
function Catalog.EnsureLoaded(): ()
	if _initialized then
		return
	end
	if not _scanCatalog() then
		return
	end
	_initialized = true
end

--[[
	校验图集几何：columns/frameCount 合法，且可选 rows >= ceil(frameCount/columns)
	@param columns number - 列数
	@param frameCount number - 帧数
	@param rows number? - 可选行数上限
	@return boolean - true 合法
	@return string? - 失败时的简要说明
]]
function Catalog.ValidateSheetGeometry(columns: number, frameCount: number, rows: number?): (boolean, string?)
	return _validateSheetGeometry(columns, frameCount, rows)
end

--[[
	校验目录中某序列是否可安全播放（不修改缓存）
	@param sequenceName string - 序列名称
	@return boolean - true 无问题且可播放
	@return { Types.CatalogIssue } - 问题列表（深拷贝语义：新建表）
]]
function Catalog.ValidateSequence(sequenceName: string): (boolean, { Types.CatalogIssue })
	local issues: { Types.CatalogIssue } = {}
	if typeof(sequenceName) ~= "string" or sequenceName == "" then
		table.insert(issues, { code = Types.ErrorCode.INVALID_ARG, message = "sequenceName 无效" })
		return false, issues
	end

	local data = Catalog.GetSequenceData(sequenceName)
	if not data then
		table.insert(issues, { code = Types.ErrorCode.NOT_FOUND, message = "序列不存在" })
		return false, issues
	end
	if data.count <= 0 then
		local code = data.rejectCode or Types.ErrorCode.EMPTY_SEQUENCE
		local message = if code == Types.ErrorCode.FRAME_GAP
			then "帧序号不连续"
			elseif code == Types.ErrorCode.INVALID_SHEET then "图集配置无效或不全"
			elseif code == Types.ErrorCode.EMPTY_SEQUENCE then "序列无有效帧"
			else "序列帧数为 0"
		table.insert(issues, { code = code, message = message })
		return false, issues
	end

	if data.kind == Types.SequenceKind.Sheet then
		local sheet = data.sheet
		if not sheet then
			table.insert(issues, { code = Types.ErrorCode.INVALID_SHEET, message = "图集缺少 sheet 布局" })
			return false, issues
		end
		local okGeo, geoMsg = _validateSheetGeometry(sheet.columns, data.count, sheet.rows)
		if not okGeo then
			table.insert(issues, {
				code = Types.ErrorCode.INVALID_SHEET,
				message = geoMsg or "图集几何无效",
			})
			return false, issues
		end
		if sheet.imageId == "" then
			table.insert(issues, { code = Types.ErrorCode.INVALID_SHEET, message = "SheetImage 为空" })
			return false, issues
		end
	elseif data.kind == Types.SequenceKind.Images then
		if #data.frames ~= data.count then
			table.insert(issues, {
				code = Types.ErrorCode.INVALID_ARG,
				message = "frames 长度与 count 不一致",
			})
			return false, issues
		end
		-- 扫描期已拒绝空洞；此处兜底：空序列视为不可播放（含 FRAME_GAP 拒绝结果）
	end

	return true, issues
end

--[[
	读取已加载的序列数据（整表与 frames/sheet 均已 freeze，勿写入）
	返回缓存只读引用：禁止修改；勿跨 ReloadCatalog 长期持有（热更后仍指向旧 freeze 表）
	拒载或缺失时，若实例子树已多于上次扫描则自动重扫（缓解客户端复制未齐误报 FRAME_GAP）
	@param sequenceName string - 序列名称
	@return SequenceFrameData? - 只读帧数据，不存在时 nil
]]
function Catalog.GetSequenceData(sequenceName: string): SequenceFrameData?
	Catalog.EnsureLoaded()
	local data = loadedImageVt[sequenceName]
	return _refreshIfStale(sequenceName, data)
end

--[[
	序列是否存在且帧数 > 0
	@param sequenceName string - 序列名称
	@return boolean - true 表示可播放
]]
function Catalog.HasSequence(sequenceName: string): boolean
	local data = Catalog.GetSequenceData(sequenceName)
	return data ~= nil and data.count > 0
end

--[[
	目录中全部序列名（浅拷贝列表，按名称排序）
	@return { string } - 名称列表
]]
function Catalog.GetSequenceNames(): { string }
	Catalog.EnsureLoaded()
	-- 全量名列表：先按当前根目录补扫可能晚到的 Folder
	local sequenceFolder = _getSequenceRoot()
	if sequenceFolder then
		for _, child in sequenceFolder:GetChildren() do
			if child:IsA("Folder") then
				local name = child.Name
				if loadedImageVt[name] == nil or (_scannedChildCount[name] or 0) < #child:GetChildren() then
					_scanOneFolder(child :: Folder, name)
				end
			end
		end
	end
	local names: { string } = {}
	for name, data in pairs(loadedImageVt) do
		if data.count > 0 then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

--[[
	查询目录中序列的总帧数
	@param sequenceName string - 序列名称
	@return number? - 帧数；不存在或为空时 nil
]]
function Catalog.GetFrameCount(sequenceName: string): number?
	local sequenceData = Catalog.GetSequenceData(sequenceName)
	if not sequenceData or sequenceData.count == 0 then
		return nil
	end
	return sequenceData.count
end

--[[
	重新扫描 Sequence 目录
	@return boolean - true 目录存在并已重载
	@return string? - 失败时的 ErrorCode
]]
function Catalog.ReloadCatalog(): (boolean, string?)
	table.clear(loadedImageVt)
	table.clear(_scannedChildCount)
	table.clear(_didSettleRetry)
	_initialized = false
	Catalog.EnsureLoaded()
	if _getSequenceRoot() == nil then
		return false, Types.ErrorCode.NOT_FOUND
	end
	return true, nil
end

return Catalog
