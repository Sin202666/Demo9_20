--[[
	Module: SoundModule
	Description: 音效播放网络接口（服务端向客户端下发 / 本地 Bindable 路由）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-01

	功能：
	- 服务端：向指定玩家下发播放/停止音效
	- 客户端：通过 Bindable 触发本地音效（由 SoundManager 监听并实例化）
	- 不直接创建 Sound 实例，实际播放在 SoundInstance 中完成

	子模块：
	- SoundInstance.luau  声音实例生命周期管理（创建、播放、停止、销毁、音效组）

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local SoundModule = Utils.SoundModule       -- 网络 / 本地路由（推荐大多数调用方使用）
	local SoundInstance = Utils.SoundInstance   -- 直接管理实例（BGM、音量设置等高级场景）

	【架构与调用链】
	服务端 PlaySound  → Remote(PLAY_SOUND) → SoundManager → SoundInstance:new → playSound
	客户端 PlaySoundLocal → Bindable(PLAY_SOUND) → 同上
	停止流程同理，经 STOP_SOUND 事件路由到 SoundInstance:stopSound

	客户端 SoundManager 位于 StarterPlayerScripts/Manager/SoundManager.client.luau，
	负责监听 Remote / Bindable，业务代码不应重复注册 PLAY_SOUND / STOP_SOUND。

	【运行环境】
	| API                              | 调用端           | 说明                                    |
	|----------------------------------|------------------|-----------------------------------------|
	| PlaySound / StopSound            | 仅服务端         | FireClient 下发至指定玩家               |
	| PlaySoundLocal / StopSoundLocal  | 客户端           | FireBindable，本机立即播放              |
	| SoundInstance                    | 仅客户端 require | 含 Instance 副作用，服务端 require 无效 |

	【API 选择】
	| 场景                              | 推荐 API                                         |
	|-----------------------------------|--------------------------------------------------|
	| UI 点击音、本地反馈               | SoundModule:PlaySoundLocal({ ... })              |
	| 服务端确认后播给单个玩家          | SoundModule:PlaySound(player, { ... })           |
	| 循环 BGM、需手动控制停止/复播     | SoundInstance:new + :playSound / :stopSound      |
	| 设置面板调节 BGM/音效组音量       | SoundInstance:SetSoundGroupVolume(...)           |
	| 按标签精确停止某个实例            | StopData 传 SoundTag                             |
	| 停止所有同名音效                  | StopData 传 SoundName                            |

	【SoundData 字段（播放）】
	- SoundName: string（必需）
	  SoundService 下 Sound 模板的 Name，找不到则 warn 且不播放。
	- SoundTag: string?（可选）
	  实例唯一标识；不传则自动生成（SoundName + 序号）。
	  同一 SoundTag 重复 new 会返回已有实例，不会重复创建。
	- Is2D: boolean?  默认 true
	  true  → 挂载 ReplicatedStorage/Sound2D（UI 音、BGM 等）
	  false → 挂载 workspace/Sound3D 下的透明 Part（空间音效）
	- Volume: number?  默认取模板 Volume，作为渐入目标音量。
	- AttachPart: BasePart?  3D 专用；指定后 Sound 跟随该 Part 移动（WeldConstraint）。
	- PlayPosition: Vector3?  3D 专用；无 AttachPart 时在固定世界坐标播放。

	【StopData 字段（停止）】
	- SoundTag: string?  优先匹配；精确停止单个实例。
	- SoundName: string?  无 SoundTag 时，停止所有同名活跃实例。
	- FadeTime: number?  渐出时间（秒），默认 0.1。
	- DestroyAfter: boolean?
	  nil   → 非循环音效 true（停止后销毁）；循环音效 false（保留实例可复播）
	  true  → 强制销毁（含 BGM）
	  false → 强制保留（仅 Stop，不 Destroy）

	【2D / 3D 播放模式】
	-- 2D UI 音效（默认）
	SoundModule:PlaySoundLocal({ SoundName = "音效-UI-通用中度点击" })

	-- 3D 固定位置
	SoundModule:PlaySoundLocal({
		SoundName = "受击-通用",
		Is2D = false,
		PlayPosition = hitPos,
	})

	-- 3D 跟随部件（如角色身上的音效）
	SoundModule:PlaySoundLocal({
		SoundName = "音效-脚步",
		Is2D = false,
		AttachPart = character.HumanoidRootPart,
	})

	【BGM 与一次性音效】
	- 一次性音效（Looped = false）：playSound 播完后自动 destroy；无需手动 Stop。
	- 循环 BGM（Looped = true）：stopSound 默认保留实例，可再次 playSound 复播。
	  BgmManager 即采用 SoundInstance:new 预创建 + playSound / stopSound 模式。
	- 需要指定 SoundTag 以便后续精确停止：
	  SoundInstance:new({ SoundName = "BGM1", SoundTag = "MainBGM", Is2D = true })

	【音效组音量（SettingManager 联动）】
	SettingManager 监听玩家 Setting 文件夹下 BGM / EFFECT NumberValue，
	调用 SoundInstance:SetSoundGroupVolume("BGM", volume, fadeTime) 调节 SoundService 音效组。
	模板 Sound 须正确归属到对应 SoundGroup（BGM / EFFECT）。

	【前置依赖】
	- SoundService 下存在 Name 匹配的 Sound 模板（可通过 SoundGroup 子级或任意层级放置）
	- 客户端 SoundManager 已启动（Manager 自动加载，一般无需手动 Init）
	- 3D 音效需设置 Is2D = false 并提供 PlayPosition 或 AttachPart 之一

	【副作用】
	- 客户端首次 require SoundInstance 时创建 ReplicatedStorage/Sound2D、workspace/Sound3D、SoundPool
	- 播放时优先从池取 Sound / 3D 宿主；非循环音效 Ended 后归还池（循环音仍 Destroy）
	- playSound / stopSound 含 Volume 渐入渐出（TweenService，默认 0.1s）

	【调用示例】
	-- 服务端：给玩家播放 UI 音效
	SoundModule:PlaySound(player, { SoundName = "音效-UI-通用中度点击", Is2D = true })

	-- 服务端：停止该玩家所有同名音效
	SoundModule:StopSound(player, { SoundName = "音效-UI-通用中度点击", FadeTime = 0.2 })

	-- 客户端：本地 3D 命中音
	SoundModule:PlaySoundLocal({
		SoundName = "受击-通用",
		Is2D = false,
		PlayPosition = hitPoint,
	})

	-- 客户端：按标签停止并保留 BGM 实例
	SoundModule:StopSoundLocal({
		SoundTag = "MainBGM",
		FadeTime = 1,
		DestroyAfter = false,
	})

	-- 客户端：BGM 直接管理（不经过 Bindable）
	local bgm = SoundInstance:new({ SoundName = "BGM1", Is2D = true, Volume = 1 })
	bgm:playSound(1)   -- 1 秒渐入
	bgm:stopSound(1)   -- 1 秒渐出，循环 BGM 默认保留实例
	bgm:playSound(1)   -- 可再次播放

	-- 客户端：调节音效组（设置面板）
	SoundInstance:SetSoundGroupVolume("EFFECT", 0.5, 0.5)

	【常见失败（warn 或不播放）】
	- SoundName 为空或未在 SoundService 中找到对应 Sound 模板
	- 服务端调用 PlaySoundLocal / StopSoundLocal（Bindable 仅客户端有效）
	- 服务端 require SoundInstance（返回 nil / warn，无法创建实例）
	- StopData 中 SoundTag 与 SoundName 均为空（无法定位实例）
	- 3D 音效未设 Is2D = false
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local SoundModule = {}

-- ============================================================================
-- 类型
-- ============================================================================

type SoundData = {
	SoundName: string,
	SoundTag: string?,
	Is2D: boolean?,
	Volume: number?,
	AttachPart: BasePart?,
	PlayPosition: Vector3?,
}

type StopData = {
	SoundName: string?,
	SoundTag: string?,
	FadeTime: number?,
	DestroyAfter: boolean?,
}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	校验 FireClient 目标是否为仍在游戏中的 Player
	@param player any - 调用方传入的玩家；非 Instance/Player 或已离场视为无效
	@return boolean - true 表示可下发 Remote
]]
local function _isValidPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil
end

--[[
	校验播放载荷是否含非空 SoundName
	@param soundData any - 调用方传入的播放表；须含 SoundName: string
	@return boolean - true 表示可下发 PLAY_SOUND
]]
local function _isValidSoundData(soundData: any): boolean
	return type(soundData) == "table" and type(soundData.SoundName) == "string" and soundData.SoundName ~= ""
end

--[[
	校验停止载荷能否定位实例（SoundTag 或 SoundName 至少一个非空）
	@param stopData any - 调用方传入的停止表
	@return boolean - true 表示可下发 STOP_SOUND
]]
local function _isValidStopData(stopData: any): boolean
	if type(stopData) ~= "table" then
		return false
	end
	local hasTag = type(stopData.SoundTag) == "string" and stopData.SoundTag ~= ""
	local hasName = type(stopData.SoundName) == "string" and stopData.SoundName ~= ""
	return hasTag or hasName
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	向指定玩家发送播放音效事件（仅服务端；经 PLAY_SOUND Remote 下发）
	@param player Player - 目标玩家；须仍在游戏中
	@param soundData SoundData - 播放载荷，须含非空 SoundName；其余字段见文件头
	@return nil
]]
function SoundModule:PlaySound(player: Player, soundData: SoundData)
	if not _isValidPlayer(player) then
		Log.warn("SoundModule.PlaySound: player 无效")
		return
	end
	if not _isValidSoundData(soundData) then
		Log.warn("SoundModule.PlaySound: SoundName 无效")
		return
	end
	NetWork.FireClient(player, NetMsg.PLAY_SOUND, soundData)
end

--[[
	向指定玩家发送停止音效事件（仅服务端；经 STOP_SOUND Remote 下发）
	@param player Player - 目标玩家；须仍在游戏中
	@param stopData StopData - 停止载荷，须含非空 SoundTag 或 SoundName
	@return nil
]]
function SoundModule:StopSound(player: Player, stopData: StopData)
	if not _isValidPlayer(player) then
		Log.warn("SoundModule.StopSound: player 无效")
		return
	end
	if not _isValidStopData(stopData) then
		Log.warn("SoundModule.StopSound: SoundTag/SoundName 无效")
		return
	end
	NetWork.FireClient(player, NetMsg.STOP_SOUND, stopData)
end

--[[
	播放本地音效（仅客户端；经 PLAY_SOUND Bindable 路由到 SoundManager）
	@param soundData SoundData - 播放载荷，须含非空 SoundName；其余字段见文件头
	@return nil
]]
function SoundModule:PlaySoundLocal(soundData: SoundData)
	if not _isValidSoundData(soundData) then
		Log.warn("SoundModule.PlaySoundLocal: SoundName 无效")
		return
	end
	NetWork.FireBindable(NetMsg.PLAY_SOUND, soundData)
end

--[[
	停止本地音效（仅客户端；经 STOP_SOUND Bindable 路由到 SoundManager）
	@param stopData StopData - 停止载荷，须含非空 SoundTag 或 SoundName
	@return nil
]]
function SoundModule:StopSoundLocal(stopData: StopData)
	if not _isValidStopData(stopData) then
		Log.warn("SoundModule.StopSoundLocal: SoundTag/SoundName 无效")
		return
	end
	NetWork.FireBindable(NetMsg.STOP_SOUND, stopData)
end

return SoundModule
