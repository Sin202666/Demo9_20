--[[
	Module: PartIcles.TexturePin
	Description: 用 1×1 ImageLabel 钉住贴图，避免首次使用再解码
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- pin / unpin：按 owner 引用计数钉住 ContentId
	- pinSubtree / unpinSubtree：钉/放 root 及其后代全部贴图槽
	- releaseOwner / clear：按 owner 释放或全清
	- isPinned / count：查询

	1×1 ImageLabel、ImageTransparency=0.99 挂在隐藏 ScreenGui（全透明会被逐出）。
	owner 计数：最后一位 owner 释放才 Destroy pin。无 owner 时用匿名哨兵，仅 clear 能清。
	服务端 GuiHost 无容器时 pin 空操作。
	Ref: https://devforum.roblox.com/t/preloading-images-and-keeping-them-loaded/2998098

	加载：由 PartIcles 引擎内部 require，业务勿直接 require
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ContentProvider = Utils.ContentProvider
local GuiHost = require(script.Parent.GuiHost)

local TexturePin = {}

local _gui = nil            -- hidden ScreenGui hosting every pin ImageLabel
local _pinned = {}          -- assetId -> ImageLabel
local _ownersOf = {}        -- assetId -> {[owner]=true,...}
local _assetsByOwner = {}   -- owner   -> {[assetId]=true,...}  reverse index for O(pins held) release
local _ANON = newproxy()    -- sentinel for pin() without owner; only clear() releases anonymous pins

--[[
	取或创建隐藏 ScreenGui。服务端无 GuiHost 时返回 nil（pin 空操作）。
	@return ScreenGui? - 钉住用宿主；服务端 nil
]]
local function _ensureGui()
	if _gui and _gui.Parent then return _gui end
	local host = GuiHost.resolveContainer()
	if not host then return nil end  -- server context: pin no-ops
	_gui = Instance.new("ScreenGui")
	_gui.Name = "PartIclesTexturePin"
	_gui.Archivable = false
	_gui.DisplayOrder = -999
	_gui.IgnoreGuiInset = true
	_gui.ResetOnSpawn = false
	_gui.Parent = host
	return _gui
end

--[[
	把字符串或带贴图 Instance 解析为 ContentId；无法解析返回 nil。
	@param entry string | Instance - ContentId 或 Decal/Texture/PE/Beam/Trail/Image*/SpecialMesh/MeshPart
	@return string? - 非空 ContentId；否则 nil
]]
local function _resolveAssetId(entry)
	if typeof(entry) == "string" then return entry ~= "" and entry or nil end
	if typeof(entry) ~= "Instance" then return nil end
	if entry:IsA("Decal") or entry:IsA("Texture") or entry:IsA("ParticleEmitter") or entry:IsA("Beam") or entry:IsA("Trail") then
		local t = entry.Texture; return (t and t ~= "") and t or nil
	elseif entry:IsA("ImageLabel") or entry:IsA("ImageButton") then
		local t = entry.Image; return (t and t ~= "") and t or nil
	elseif entry:IsA("SpecialMesh") then
		-- SpecialMesh.TextureId (lowercase d).
		local t = entry.TextureId; return (t and t ~= "") and t or nil
	elseif entry:IsA("MeshPart") then
		-- MeshPart.TextureID (uppercase D); checked AFTER Beam etc.
		local t = entry.TextureID; return (t and t ~= "") and t or nil
	end
end

--[[
	收集 entry 的 ContentId 追加到 list。SurfaceAppearance 钉 4 个 PBR 槽。
	@param entry Instance - 待扫描实例
	@param list { string } - 输出数组（原地追加）
	@return () - 无返回值
]]
local function _appendAssetIds(entry, list)
	if entry:IsA("SurfaceAppearance") then
		for _, prop in ipairs({"ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap"}) do
			local ok, t = pcall(function() return entry[prop] end)
			if ok and t and t ~= "" then table.insert(list, t) end
		end
		return
	end
	local id = _resolveAssetId(entry)
	if id then table.insert(list, id) end
end

--[[
	为 owner 钉住一个或多个资源。`_pinned` 去重；owner 缺省为匿名哨兵。
	@param input string | Instance | { string | Instance } - 单个或数组
	@param owner any? - 引用持有者；nil 用匿名哨兵（仅 clear 能释放）
	@return () - 无返回值
]]
function TexturePin.pin(input, owner)
	if not input then return end
	owner = owner or _ANON
	local items = (type(input) == "table") and input or { input }
	local newPins = {}
	for _, entry in ipairs(items) do
		local assetId = _resolveAssetId(entry)
		if assetId then
			if not _pinned[assetId] then
				local gui = _ensureGui()
				if not gui then break end  -- server context: skip remaining pins entirely
				local img = Instance.new("ImageLabel")
				img.Name = "Pin"; img.Image = assetId
				img.Size = UDim2.fromOffset(1, 1); img.Position = UDim2.fromOffset(0, 0)
				img.BackgroundTransparency = 1; img.ImageTransparency = 0.99 -- 1.0 culls and evicts
				img.BorderSizePixel = 0; img.ZIndex = 1
				img.Parent = gui
				_pinned[assetId] = img
				table.insert(newPins, img)
			end
			local owners = _ownersOf[assetId]; if not owners then owners = {}; _ownersOf[assetId] = owners end
			owners[owner] = true
			local assets = _assetsByOwner[owner]; if not assets then assets = {}; _assetsByOwner[owner] = assets end
			assets[assetId] = true
		end
	end
	if #newPins > 0 then task.spawn(function() pcall(ContentProvider.PreloadAsync, ContentProvider, newPins) end) end
end

--[[
	钉住 root 及其后代全部贴图槽；owner = root。
	@param root Instance - 扫描根
	@return () - 无返回值
]]
function TexturePin.pinSubtree(root)
	if not root then return end
	local ids = {}
	_appendAssetIds(root, ids)
	local ok, descendants = pcall(root.GetDescendants, root)
	if ok then
		for _, d in ipairs(descendants) do _appendAssetIds(d, ids) end
	end
	if #ids > 0 then TexturePin.pin(ids, root) end
end

--[[
	查询某 ContentId 是否已钉。
	@param assetId string - ContentId
	@return boolean - 已钉为 true
]]
function TexturePin.isPinned(assetId) return _pinned[assetId] ~= nil end

--[[
	当前钉住的不同资源数。
	@return number - `_pinned` 条目数
]]
function TexturePin.count()
	local n = 0; for _ in pairs(_pinned) do n += 1 end; return n
end

--[[
	放下 owner 的声明；零 owner 时 Destroy pin。
	@param input string | Instance | { string | Instance } - 单个或数组
	@param owner any? - 引用持有者；nil 用匿名哨兵
	@return () - 无返回值
]]
function TexturePin.unpin(input, owner)
	if not input then return end
	owner = owner or _ANON
	local items = (type(input) == "table") and input or { input }
	for _, entry in ipairs(items) do
		local assetId = _resolveAssetId(entry)
		if assetId and _pinned[assetId] then
			local owners = _ownersOf[assetId]
			if owners then owners[owner] = nil end
			local assets = _assetsByOwner[owner]
			if assets then assets[assetId] = nil end
			local anyOwner = false; if owners then for _ in pairs(owners) do anyOwner = true; break end end
			if not anyOwner then
				pcall(_pinned[assetId].Destroy, _pinned[assetId])
				_pinned[assetId] = nil; _ownersOf[assetId] = nil
			end
		end
	end
end

--[[
	释放该 owner 持有的全部 pin；供 DescendantRemoving 自动清理。
	@param owner any - 引用持有者
	@return () - 无返回值
]]
function TexturePin.releaseOwner(owner)
	if not owner then return end
	local assets = _assetsByOwner[owner]; if not assets then return end
	for assetId in pairs(assets) do
		local owners = _ownersOf[assetId]
		if owners then owners[owner] = nil end
		local anyOwner = false; if owners then for _ in pairs(owners) do anyOwner = true; break end end
		if not anyOwner and _pinned[assetId] then
			pcall(_pinned[assetId].Destroy, _pinned[assetId])
			_pinned[assetId] = nil; _ownersOf[assetId] = nil
		end
	end
	_assetsByOwner[owner] = nil
end

--[[
	pinSubtree 的镜像；其他 owner 的份额保留。
	@param root Instance - 扫描根（同时作为 owner）
	@return () - 无返回值
]]
function TexturePin.unpinSubtree(root)
	if not root then return end
	local ids = {}
	_appendAssetIds(root, ids)
	local ok, descendants = pcall(root.GetDescendants, root)
	if ok then
		for _, d in ipairs(descendants) do _appendAssetIds(d, ids) end
	end
	if #ids > 0 then TexturePin.unpin(ids, root) end
end

--[[
	销毁全部 pin 与宿主 ScreenGui。插件关闭 / Deactivate 调用。
	@return () - 无返回值
]]
function TexturePin.clear()
	_pinned = {}; _ownersOf = {}; _assetsByOwner = {}
	if _gui then pcall(_gui.Destroy, _gui); _gui = nil end
end

return TexturePin
