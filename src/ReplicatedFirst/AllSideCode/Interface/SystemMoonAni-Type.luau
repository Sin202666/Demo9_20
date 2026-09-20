--[[
	Module: SystemMoonAni-Type
	Description: SystemMoonAni 类型声明（完整使用说明见 SystemModule/SystemMoonAni/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-08-24
	Last Modified: 2026-08-25
]]

local SystemMoonAni = {}

export type PlayOptions = {
	map: Instance?,
	mapName: string?,
	mapCFrame: CFrame?,
	mapPosition: Vector3?,
	mapParent: Instance?,
	replace: { [number]: Instance }?,
	waitForObjects: boolean?,
	lockCharacter: boolean?,
	restart: boolean?,
	fps: number?,
	tasks: { [number]: (...any) -> () }?,
	onEnded: ((cutscene: any) -> ())?,
}

export type CutsceneHandle = string

SystemMoonAni.ERROR_CODE = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	MOON2CUTSCENE_MISSING = "MOON2CUTSCENE_MISSING",
	INVALID_ARGUMENT = "INVALID_ARGUMENT",
	FILE_NOT_FOUND = "FILE_NOT_FOUND",
	MAP_NOT_FOUND = "MAP_NOT_FOUND",
	HANDLE_NOT_FOUND = "HANDLE_NOT_FOUND",
	ALREADY_PLAYING = "ALREADY_PLAYING",
	CREATE_FAILED = "CREATE_FAILED",
})

--[[
	播放过场（单会话；已有会话时返回 ALREADY_PLAYING）

	@param file Instance | string - StringValue/Folder 实例或 MoonAnimator2Saves 下名称
	@param opts PlayOptions? - 播放选项
	@return boolean - 是否成功
	@return CutsceneHandle | string - 句柄或错误码
]]
function SystemMoonAni.Play(file: Instance | string, opts: PlayOptions?): (boolean, CutsceneHandle | string)
end

--[[
	从过场文件读取场景模型名（可省略 Play 的 mapName）

	@param file Instance | string - StringValue/Folder 或 Saves 下名称
	@return string? - mapName；解析失败时 nil
]]
function SystemMoonAni.GetMapName(file: Instance | string): string?
end

--[[
	停止指定或全部过场

	@param handle CutsceneHandle? - 会话句柄；nil 停止全部
	@return boolean - 是否至少停止一个
	@return string? - 失败错误码
]]
function SystemMoonAni.Stop(handle: CutsceneHandle?): (boolean, string?)
end

--[[
	等待过场结束（yield）

	@param handle CutsceneHandle? - 会话句柄；nil 时等待唯一会话
	@return boolean - 是否成功
	@return string? - 失败错误码
]]
function SystemMoonAni.Wait(handle: CutsceneHandle?): (boolean, string?)
end

--[[
	是否正在播放（以 cutscene:isPlaying 为准）

	@param handle CutsceneHandle? - 指定句柄；nil 表示任意仍在播的会话
	@return boolean - 是否在播
]]
function SystemMoonAni.IsPlaying(handle: CutsceneHandle?): boolean
end

--[[
	注册帧任务

	@param handle CutsceneHandle - 会话句柄
	@param frame number - 触发帧
	@param fn (...any) -> () - 回调
	@return boolean - 是否成功
	@return string? - 失败错误码
]]
function SystemMoonAni.RegisterTask(handle: CutsceneHandle, frame: number, fn: (...any) -> ()): (boolean, string?)
end

--[[
	替换动画对象

	@param handle CutsceneHandle - 会话句柄
	@param index number - Items 索引
	@param instance Instance - 替换目标
	@return boolean - 是否成功
	@return string? - 失败错误码
]]
function SystemMoonAni.ReplaceObject(handle: CutsceneHandle, index: number, instance: Instance): (boolean, string?)
end

--[[
	获取底层 Moon2Cutscene 库

	@return any? - 库表
]]
function SystemMoonAni.GetLibrary(): any?
end

--[[
	显示/清除字幕

	@param text string - 字幕文本；空串清除
	@param properties { [string]: any }? - 字体等属性（如 Font / TextSize / TextColor3，以库为准）
	@return nil
]]
function SystemMoonAni.Subtitle(text: string, properties: { [string]: any }?)
end

--[[
	创建淡入淡出（透传 Moon2Cutscene.fade）

	@param fadeInTime number? - 淡入秒
	@param stayTime number? - 停留秒
	@param fadeOutTime number? - 淡出秒
	@param color Color3? - 颜色
	@return ((() -> ())?, ScreenGui?) - 启动函数与 ScreenGui
]]
function SystemMoonAni.Fade(fadeInTime: number?, stayTime: number?, fadeOutTime: number?, color: Color3?): any
end

--[[
	创建暗角（透传 Moon2Cutscene.vignette）

	@param image string? - 可选贴图 asset id
	@return ((() -> ())?, ScreenGui?, ImageLabel?) - 销毁函数与 UI
]]
function SystemMoonAni.Vignette(image: string?): any
end

--[[
	销毁模块状态

	@return nil
]]
function SystemMoonAni.destroy()
end

return SystemMoonAni
