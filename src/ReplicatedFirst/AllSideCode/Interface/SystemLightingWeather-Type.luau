--[[
	Module: SystemLightingWeather-Type
	Description: SystemLightingWeather 类型声明（完整说明见 SystemModule/SystemLightingWeather/init.luau）
	Author: 中台组 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-05

	业务仅经 LightingManager Bindable 调用；勿直接 Utils.SystemLightingWeather.new。
	createForOwner 失败时为降级单例（写 API 拒绝并写 LastError），不中断启动。
	getClockTime 为客户端视觉目标缓存；服端 ClockAuthority 为权威。
	reapplyEffective：绕过同名短路强制重放；生产全量/增量 apply 经 ApplyCoalesce 同帧合并。
	Acquire / setBaseline 返回 true = 请求已接受；落地：Pending==false 且
	LightingAppliedName==CurrentLightingName 且 LastError==nil。
	CurrentLightingName=意图；LightingAppliedName=天气 apply 成功落地（失败不推进）。
	lease TTL / StaleWarn / HardMax 见 LeaseLifecycle；副本退出仍须 FORCE_CLEAR / RELEASE。
	LightingBootReady=false：缺 Config 或降级，上线健康检查须阻断。
	releaseLease 降级态返回 false（与其它写 API 一致）。
]]

local SystemLightingWeather = {}

export type WeatherLeaseSnapshot = {
	writerId: string,
	name: string,
	priority: number,
	order: number,
	expiresAt: number?,
	acquiredAt: number,
}

export type SystemLightingWeatherInstance = {
	setClockTime: (self: SystemLightingWeatherInstance, clockTime: number, transitionTime: number?) -> (),
	getClockTime: (self: SystemLightingWeatherInstance) -> number,
	reportClientError: (self: SystemLightingWeatherInstance, message: string?) -> (),
	hasLease: (self: SystemLightingWeatherInstance, writerId: string) -> boolean,
	getActiveLeases: (self: SystemLightingWeatherInstance) -> { WeatherLeaseSnapshot },
	setBaseline: (self: SystemLightingWeatherInstance, lightingName: string, transitionTime: number) -> boolean,
	acquireLease: (
		self: SystemLightingWeatherInstance,
		writerId: string,
		lightingName: string,
		transitionTime: number,
		priority: number?,
		force: boolean?,
		ttl: number?
	) -> boolean,
	releaseLease: (self: SystemLightingWeatherInstance, writerId: string, transitionTime: number) -> boolean,
	forceClearLeases: (
		self: SystemLightingWeatherInstance,
		maxPriority: number?,
		transitionTime: number
	) -> boolean,
	reapplyEffective: (self: SystemLightingWeatherInstance, transitionTime: number) -> boolean,
	reconcileChannel: (self: SystemLightingWeatherInstance, className: string, transitionTime: number) -> (),
	onFxCcBusyReleased: (self: SystemLightingWeatherInstance) -> (),
	sweepExpiredLeases: (self: SystemLightingWeatherInstance) -> (),
	setCustomStateAndReconcile: (
		self: SystemLightingWeatherInstance,
		customName: string,
		nowState: boolean,
		transitionTime: number
	) -> boolean,
	destroy: (self: SystemLightingWeatherInstance) -> (),
}

function SystemLightingWeather.new(): SystemLightingWeatherInstance
end

function SystemLightingWeather.Init(): SystemLightingWeatherInstance
end

function SystemLightingWeather.setClockTime(
	self: SystemLightingWeatherInstance,
	clockTime: number,
	transitionTime: number?
)
end

function SystemLightingWeather.getClockTime(self: SystemLightingWeatherInstance): number
end

function SystemLightingWeather.reportClientError(self: SystemLightingWeatherInstance, message: string?)
end

function SystemLightingWeather.hasLease(self: SystemLightingWeatherInstance, writerId: string): boolean
end

function SystemLightingWeather.getActiveLeases(self: SystemLightingWeatherInstance): { WeatherLeaseSnapshot }
end

function SystemLightingWeather.setBaseline(self: SystemLightingWeatherInstance, lightingName: string, transitionTime: number): boolean
end

function SystemLightingWeather.acquireLease(
	self: SystemLightingWeatherInstance,
	writerId: string,
	lightingName: string,
	transitionTime: number,
	priority: number?,
	force: boolean?,
	ttl: number?
): boolean
end

function SystemLightingWeather.releaseLease(self: SystemLightingWeatherInstance, writerId: string, transitionTime: number): boolean
end

function SystemLightingWeather.forceClearLeases(
	self: SystemLightingWeatherInstance,
	maxPriority: number?,
	transitionTime: number
): boolean
end

function SystemLightingWeather.reapplyEffective(
	self: SystemLightingWeatherInstance,
	transitionTime: number
): boolean
end

function SystemLightingWeather.reconcileChannel(self: SystemLightingWeatherInstance, className: string, transitionTime: number)
end

function SystemLightingWeather.onFxCcBusyReleased(self: SystemLightingWeatherInstance)
end

function SystemLightingWeather.sweepExpiredLeases(self: SystemLightingWeatherInstance)
end

function SystemLightingWeather.setCustomStateAndReconcile(
	self: SystemLightingWeatherInstance,
	customName: string,
	nowState: boolean,
	transitionTime: number
): boolean
end

function SystemLightingWeather.destroy(self: SystemLightingWeatherInstance)
end

return SystemLightingWeather
