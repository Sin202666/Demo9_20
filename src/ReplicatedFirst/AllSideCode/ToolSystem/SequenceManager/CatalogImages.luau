--[[
	Module: CatalogImages
	Description: SequenceManager 多图帧扫描（帧序号连续性、空洞诊断）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	从 Catalog 拆出以降有效代码行。图集扫描仍在 Catalog。
	AreFrameIndicesContiguous 由 Catalog 再导出，供 Contract 自检。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)

type Folder = typeof(workspace:FindFirstChildOfClass("Folder"))
type StringValue = typeof(workspace:FindFirstChildOfClass("StringValue"))
type SequenceFrameData = Types.SequenceFrameData
type FrameEntry = { index: number, imageId: string }

local CatalogImages = {}

--[[
	构造不可播放的多图占位（count=0 + rejectCode）
	@param rejectCode string - FRAME_GAP / EMPTY_SEQUENCE
	@return SequenceFrameData - 冻结占位
]]
local function _rejectedImages(rejectCode: string): SequenceFrameData
	return table.freeze({
		kind = Types.SequenceKind.Images,
		frames = table.freeze({} :: { string }),
		count = 0,
		sheet = nil,
		rejectCode = rejectCode,
	})
end

--[[
	判断已排序帧序号是否从最小值起连续无空洞
	@param indices { number } - 已按升序排列的帧序号
	@return boolean - true 表示连续
]]
function CatalogImages.AreFrameIndicesContiguous(indices: { number }): boolean
	if #indices == 0 then
		return true
	end
	local startIndex = indices[1]
	for i, index in ipairs(indices) do
		if index ~= startIndex + i - 1 then
			return false
		end
	end
	return true
end

--[[
	判断帧条目是否从最小值起连续无空洞
	@param entries { FrameEntry } - 已排序帧条目
	@return boolean - true 表示连续
]]
local function _isContiguous(entries: { FrameEntry }): boolean
	local indices: { number } = table.create(#entries)
	for i, entry in ipairs(entries) do
		indices[i] = entry.index
	end
	return CatalogImages.AreFrameIndicesContiguous(indices)
end

--[[
	将已排序帧序号拼成日志字符串
	@param entries { FrameEntry } - 已排序帧条目
	@return string - 如 "1,2,4"
]]
local function _formatFrameIndices(entries: { FrameEntry }): string
	if #entries == 0 then
		return "(无)"
	end
	local parts: { string } = table.create(#entries)
	for i, entry in ipairs(entries) do
		parts[i] = tostring(entry.index)
	end
	return table.concat(parts, ",")
end

--[[
	列出排序后序号中的空洞与重复（供 FRAME_GAP 诊断）
	@param entries { FrameEntry } - 已排序帧条目
	@return string - 缺失序号描述
	@return string - 重复序号描述；无重复时为空串
]]
local function _describeFrameGaps(entries: { FrameEntry }): (string, string)
	local missing: { string } = {}
	local duplicates: { string } = {}
	local seen: { [number]: boolean } = {}
	for _, entry in ipairs(entries) do
		if seen[entry.index] then
			table.insert(duplicates, tostring(entry.index))
		else
			seen[entry.index] = true
		end
	end
	if #entries >= 2 then
		local startIndex = entries[1].index
		local endIndex = entries[#entries].index
		for index = startIndex, endIndex do
			if not seen[index] then
				table.insert(missing, tostring(index))
			end
		end
	end
	local missingText = if #missing > 0 then table.concat(missing, ",") else "(无空洞，可能是重复序号)"
	local dupText = if #duplicates > 0 then table.concat(duplicates, ",") else ""
	return missingText, dupText
end

--[[
	扫描多图帧序列
	@param effectFolder Folder - 序列目录
	@param folderName string - 序列名
	@return SequenceFrameData - 多图数据（可能 count=0）
]]
function CatalogImages.Build(effectFolder: Folder, folderName: string): SequenceFrameData
	local frameEntries: { FrameEntry } = {}
	local emptyIdCount = 0
	local skippedNonString = 0

	for _, subChild: Instance in effectFolder:GetChildren() do
		if not subChild:IsA("StringValue") then
			skippedNonString += 1
			continue
		end
		if subChild.Name == Types.SHEET_IMAGE_VALUE_NAME then
			continue
		end

		local stringValue: StringValue = subChild :: StringValue
		local frameIndex: number? = tonumber(stringValue.Name)
		if not frameIndex then
			Log.warn("[SequenceManager] 跳过非数字帧名:", folderName, stringValue.Name)
			continue
		end
		-- 帧名须为整数序号；"1.5" / 带小数点的 Name 视为非法
		if frameIndex ~= math.floor(frameIndex) then
			Log.warn("[SequenceManager] 跳过非整数帧名:", folderName, stringValue.Name)
			continue
		end
		frameIndex = math.floor(frameIndex)

		local imageId = stringValue.Value
		if imageId == "" then
			emptyIdCount += 1
			Log.warn("[SequenceManager] 跳过空 ImageId:", folderName, stringValue.Name)
			continue
		end

		table.insert(frameEntries, {
			index = frameIndex,
			imageId = imageId,
		})
	end

	table.sort(frameEntries, function(a, b)
		return a.index < b.index
	end)

	-- 商业契约：逻辑帧 1..N 与目录帧名一一对应；不连续/重复则拒绝加载（count=0）
	if #frameEntries > 0 and not _isContiguous(frameEntries) then
		local missingText, dupText = _describeFrameGaps(frameEntries)
		Log.warn(
			"[SequenceManager] 帧序号不连续（已拒绝加载，须从最小序号起连续无空洞）:",
			folderName,
			"已解析=",
			_formatFrameIndices(frameEntries),
			"缺失=",
			missingText,
			if dupText ~= "" then "重复=" .. dupText else "",
			if emptyIdCount > 0 then "空ImageId跳过=" .. tostring(emptyIdCount) else "",
			if skippedNonString > 0 then "非StringValue子节点=" .. tostring(skippedNonString) else ""
		)
		return _rejectedImages(Types.ErrorCode.FRAME_GAP)
	end

	local frames: { string } = {}
	for _, entry in ipairs(frameEntries) do
		table.insert(frames, entry.imageId)
	end

	if #frames == 0 then
		Log.warn(
			"[SequenceManager] 序列无有效帧:",
			folderName,
			"子节点=",
			#effectFolder:GetChildren(),
			"空ImageId=",
			emptyIdCount,
			"非StringValue=",
			skippedNonString
		)
		return _rejectedImages(Types.ErrorCode.EMPTY_SEQUENCE)
	elseif emptyIdCount > 0 then
		Log.warn("[SequenceManager] 序列含空 ImageId 已跳过:", folderName, emptyIdCount)
	end

	return table.freeze({
		kind = Types.SequenceKind.Images,
		frames = table.freeze(frames),
		count = #frames,
		sheet = nil,
		rejectCode = nil,
	})
end

return CatalogImages
