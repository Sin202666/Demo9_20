--[[
	Module: SettingManager
	Description: 客户端设置管理器，将玩家 Setting 中 BGM/EFFECT 同步到 SoundService 音效组音量
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-08-31

	功能：
	- 监听 player.Setting 下 BGM / EFFECT NumberValue（存盘 0~100，100 为满音量）
	- BGM 仅调节同名 SoundGroup；EFFECT 调节除 BGM 外所有已缓存 SoundGroup
	- 按存盘比例 × 启动时各组基准 Volume，经 SoundInstance 渐变写入
	- 启动后新加入的 SoundGroup 纳入缓存并立即套用当前 BGM/EFFECT 系数

	加载方式：
	- 本文件是 StarterPlayerScripts LocalScript，客户端自动运行
	- 不是 Utils 模块，禁止 require；不要写 Utils.SettingManager

	配置（GameConfig.Setting）：
	- 启用：false 时本 Manager 不运行，避免 WaitForChild 永久阻塞
	- 音量渐变秒：SetSoundGroupVolume 淡入淡出时长；非法值回落到 DEFAULT_FADE_SEC

	约定：
	- Setting 文件夹名走 EnumMgr.PlayerInst.SettingFolder
	- settingConf.ShowName 须与 SoundService 中 SoundGroup.Name 一致（BGM 为音乐组）
	- 服务端 SystemSet 创建 Setting 实例；Setting UI 经 Remote 写存档后同步 NumberValue
	- 旧档 BGM/EFFECT 0~1 → 0~100 只在 FixData.luau；本模块按 0~100 换算，不再二次兼容

	依赖：
	- Utils.SoundInstance：SetSoundGroupVolume
	- Utils.AddListen.NumValueAdd：注册时立即以当前值回调一次

	与 BgmManager 关系：
	- BgmManager 负责区域 BGM 切换；本模块仅调节 BGM 音效组总音量

	示例：
	- 滑条 80 → SystemSet.ChangeSet(player, "BGM", 80) → NumberValue=80 → 本模块写入 BGM 组 Volume=0.8×基准
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "Setting", "启用" }) == false then
	return
end

local SoundService = Utils.SoundService
local SoundInstance = Utils.SoundInstance
local AddListen = Utils.AddListen
local LocalPlayer = Utils.LocalPlayer
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log

-- ========================================
-- 常量
-- ========================================
local SETTING_FOLDER = EnumMgr.PlayerInst.SettingFolder
local SETTING_KEY_BGM = "BGM"
local SETTING_KEY_EFFECT = "EFFECT"
-- settingConf BGM/EFFECT range 上界；100 为满音量
local STORED_VOLUME_MAX = 100
local DEFAULT_BASE_VOLUME = 1
local DEFAULT_FADE_SEC = 0.5
local WAIT_TIMEOUT_SEC = 30

-- ========================================
-- 私有变量
-- ========================================
local _volumeFadeSec: number = DEFAULT_FADE_SEC
do
	local fadeSec = SystemGameConfig.GetValue({ "Setting", "音量渐变秒" })
	if typeof(fadeSec) == "number" and fadeSec >= 0 then
		_volumeFadeSec = fadeSec
	end
end

local _soundGroupBaseVolumes: { [string]: number } = {}
local _bgmGain01 = 1
local _effectGain01 = 1

-- ========================================
-- 私有函数
-- ========================================

--[[
	将 Setting 存盘值换算为 0~1 音量系数（100 等同满音量）
	旧档 0~1 缩放由 FixData 迁移，此处不再把 1 当成满音量。
	@param stored any - NumberValue.Value，期望 0~100 的 number
	@return number - 0~1 音量系数；非 number 时返回 0
]]
local function _settingStoredToGain01(stored: any): number
	if typeof(stored) ~= "number" then
		Log.warn("SettingManager: 音量存盘值非 number", stored)
		return 0
	end
	return math.clamp(stored, 0, STORED_VOLUME_MAX) / STORED_VOLUME_MAX
end

--[[
	读取 SoundService 音效组启动基准音量（满音量设置时恢复到此值）
	@param groupName string - SoundGroup.Name
	@return number - 基准 Volume；未缓存时返回 DEFAULT_BASE_VOLUME
]]
local function _getSoundGroupBaseVolume(groupName: string): number
	return _soundGroupBaseVolumes[groupName] or DEFAULT_BASE_VOLUME
end

--[[
	将 0~1 系数应用到指定音效组
	@param groupName string - SoundGroup.Name
	@param gain01 number - 0~1 音量系数
	@return nil - 无返回值
]]
local function _applySoundGroupGain(groupName: string, gain01: number)
	SoundInstance:SetSoundGroupVolume(groupName, gain01 * _getSoundGroupBaseVolume(groupName), _volumeFadeSec)
end

--[[
	将 EFFECT 设置应用到除 BGM 外所有已缓存音效组
	@param gain01 number - 0~1 音量系数
	@return nil - 无返回值
]]
local function _applyEffectGroupsGain(gain01: number)
	_effectGain01 = gain01
	for groupName, _ in _soundGroupBaseVolumes do
		if groupName ~= SETTING_KEY_BGM then
			_applySoundGroupGain(groupName, gain01)
		end
	end
end

--[[
	缓存启动时已存在的 SoundGroup 基准 Volume
	@return nil - 无返回值
]]
local function _cacheExistingSoundGroupBaseVolumes()
	for _, child in SoundService:GetChildren() do
		if child:IsA("SoundGroup") then
			_soundGroupBaseVolumes[child.Name] = child.Volume
		end
	end
end

--[[
	启动后新加入的 SoundGroup：写入基准并套用当前 BGM/EFFECT 系数
	@param child Instance - SoundService 新增子级
	@return nil - 无返回值
]]
local function _onSoundServiceChildAdded(child: Instance)
	if not child:IsA("SoundGroup") then
		return
	end
	if _soundGroupBaseVolumes[child.Name] == nil then
		_soundGroupBaseVolumes[child.Name] = child.Volume
	end
	if child.Name == SETTING_KEY_BGM then
		_applySoundGroupGain(child.Name, _bgmGain01)
	else
		_applySoundGroupGain(child.Name, _effectGain01)
	end
end

--[[
	BGM NumberValue 换算后的回调
	@param gain01 number - 0~1 音量系数
	@return nil - 无返回值
]]
local function _onBgmGainChanged(gain01: number)
	_bgmGain01 = gain01
	_applySoundGroupGain(SETTING_KEY_BGM, gain01)
end

--[[
	EFFECT NumberValue 换算后的回调
	@param gain01 number - 0~1 音量系数
	@return nil - 无返回值
]]
local function _onEffectGainChanged(gain01: number)
	_applyEffectGroupsGain(gain01)
end

--[[
	绑定 Setting NumberValue 到音效组音量
	@param volumeValue NumberValue - player.Setting 下的 BGM 或 EFFECT 实例
	@param onGainChanged (number) -> () - 收到 0~1 系数后的应用回调
	@return nil - 无返回值
]]
local function _bindVolumeSetting(volumeValue: NumberValue, onGainChanged: (number) -> ())
	AddListen.NumValueAdd(volumeValue, function(stored: number)
		onGainChanged(_settingStoredToGain01(stored))
	end)
end

--[[
	等待 player.Setting 下指定 NumberValue；超时或类型不符则打日志并返回 nil
	@param settingFolder Folder - player.Setting
	@param name string - NumberValue.Name（settingConf.ShowName）
	@return NumberValue? - 有效实例；失败为 nil
]]
local function _waitSettingNumberValue(settingFolder: Folder, name: string): NumberValue?
	local inst = settingFolder:WaitForChild(name, WAIT_TIMEOUT_SEC)
	if not inst or not inst:IsA("NumberValue") then
		Log.warn("SettingManager: 等待 Setting." .. name .. " 超时或类型不符", WAIT_TIMEOUT_SEC)
		return nil
	end
	return inst
end

-- ========================================
-- 初始化
-- ========================================
local settingFolderInst = LocalPlayer:WaitForChild(SETTING_FOLDER, WAIT_TIMEOUT_SEC)
if not settingFolderInst or not settingFolderInst:IsA("Folder") then
	Log.warn("SettingManager: 等待 Setting 文件夹超时或类型不符，音量联动降级关闭", WAIT_TIMEOUT_SEC)
	return
end

local settingFolder: Folder = settingFolderInst
local bgmVolume = _waitSettingNumberValue(settingFolder, SETTING_KEY_BGM)
local effectVolume = _waitSettingNumberValue(settingFolder, SETTING_KEY_EFFECT)
if not bgmVolume or not effectVolume then
	return
end

_cacheExistingSoundGroupBaseVolumes()
SoundService.ChildAdded:Connect(_onSoundServiceChildAdded)

_bindVolumeSetting(bgmVolume, _onBgmGainChanged)
_bindVolumeSetting(effectVolume, _onEffectGainChanged)
