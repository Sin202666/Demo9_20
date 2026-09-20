local module = {}

-- ============================================================================
-- 模块类型定义（用于 IDE 类型提示）
-- ============================================================================
-- 这个文件定义了 UtilsSystem 中所有模块的类型
-- 用于 IDE 代码补全和类型检查
--
-- 使用 typeof(require(...)) 从类型定义文件中提取类型
-- 这样 IDE 可以识别类型并提供完整的代码补全

-- ToolBasic 模块类型
type InsMgrType = typeof(require(script["InsMgr-Type"]))
type LogType = typeof(require(script["Log-Type"]))
type MathMgrType = typeof(require(script["MathMgr-Type"]))
type KeyframeEvalType = typeof(require(script["KeyframeEval-Type"]))
type AnchorRelativeType = typeof(require(script["AnchorRelative-Type"]))
type VisibleMgrType = typeof(require(script["VisibleMgr-Type"]))
type ObjectPoolUtilType = typeof(require(script["ObjectPoolUtil-Type"]))
type TimeTransferType = typeof(require(script["TimeTransfer-Type"]))
type RankConfigType = typeof(require(script["RankConfig-Type"]))
type CopyType = typeof(require(script["Copy-Type"]))
type ResRestoreType = typeof(require(script["ResRestore-Type"]))
type UISetMgrType = typeof(require(script["UISetMgr-Type"]))
type HumanModuleType = typeof(require(script["HumanModule-Type"]))
type TranslationHelperType = typeof(require(script["TranslationHelper-Type"]))
type ConfigInstanceType = typeof(require(script["ConfigInstance-Type"]))
type BezierCurveType = typeof(require(script["BezierCurve-Type"]))
type ViewportFrameModuleType = typeof(require(script["ViewportFrameModule-Type"]))
type AssetPathsType = typeof(require(script["AssetPaths-Type"]))
type AssetRegistryType = typeof(require(script["AssetRegistry-Type"]))
type NetMsgType = typeof(require(script["NetMsg-Type"]))
type LightingTweenUtilType = typeof(require(script["LightingTweenUtil-Type"]))
type ChannelResultUtilType = typeof(require(script["ChannelResultUtil-Type"]))

-- ToolSystem 模块类型（业务模块）
type CfgFindType = typeof(require(script["CfgFind-Type"]))
type GetDataType = typeof(require(script["GetData-Type"]))
type DeviceTypeType = typeof(require(script["DeviceType-Type"]))
type WorldUtilType = typeof(require(script["WorldUtil-Type"]))
type AssetAcquireType = typeof(require(script["AssetAcquire-Type"]))
type ResourceUtilType = typeof(require(script["ResourceUtil-Type"]))
type AddListenType = typeof(require(script["AddListen-Type"]))
type RequestRateLimitType = typeof(require(script["RequestRateLimit-Type"]))
type NetWorkType = typeof(require(script["NetWork-Type"]))
type TipsModuleType = typeof(require(script["TipsModule-Type"]))
type TipsRendererType = typeof(require(script["TipsRenderer-Type"]))
type TipsConfigType = typeof(require(script["TipsConfig-Type"]))
type AnimationModuleType = typeof(require(script["AnimationModule-Type"]))
type ActionArbiterType = typeof(require(script["ActionArbiter-Type"]))
type AnimationLayerType = typeof(require(script["AnimationLayer-Type"]))
type LocoStyleType = typeof(require(script["LocoStyle-Type"]))
type LocoStyleSetsType = typeof(require(script["LocoStyleSets-Type"]))
type CharacterControlType = typeof(require(script["CharacterControl-Type"]))
type SoundModuleType = typeof(require(script["SoundModule-Type"]))
type SoundInstanceType = typeof(require(script["SoundInstance-Type"]))
type EnumMgrType = typeof(require(script["EnumMgr-Type"]))
type UIMgrType = typeof(require(script["UIMgr-Type"]))
type UIanimaType = typeof(require(script["UIanima-Type"]))
type SequenceManagerType = typeof(require(script["SequenceManager-Type"]))
type SpeedLineFXType = typeof(require(script["SpeedLineFX-Type"]))
type BurstStoneType = typeof(require(script["BurstStone-Type"]))
type FXUtilType = typeof(require(script["FXUtil-Type"]))
type HatchEffectType = typeof(require(script["HatchEffect-Type"]))
type GhostShadowType = typeof(require(script["GhostShadow-Type"]))
type LightningType = typeof(require(script["Lightning-Type"]))
type PlayerDataType = typeof(require(script["PlayerData-Type"]))
type RayCastType = typeof(require(script["RayCast-Type"]))
type SystemGameConfigType = typeof(require(script["SystemGameConfig-Type"]))
type UpdateModuleType = typeof(require(script["UpdateModule-Type"]))
type SystemDataStoreType = typeof(require(script["SystemDataStore-Type"]))
type SystemGlobalDataType = typeof(require(script["SystemGlobalData-Type"]))
type SystemServerBuffType = typeof(require(script["SystemServerBuff-Type"]))
type SystemRankType = typeof(require(script["SystemRank-Type"]))

-- 服务器端系统模块类型
type SystemSaveType = typeof(require(script["SystemSave-Type"]))
type SystemBagType = typeof(require(script["SystemBag-Type"]))
type SystemBagToolbarType = typeof(require(script["SystemBagToolbar-Type"]))
type SystemBUFFType = typeof(require(script["SystemBUFF-Type"]))
type SystemEmailType = typeof(require(script["SystemEmail-Type"]))
type GmEmailWhitelistType = typeof(require(script["GmEmailWhitelist-Type"]))
type StructType = typeof(require(script["Struct-Type"]))
type SystemUpdateLogType = typeof(require(script["SystemUpdateLog-Type"]))
type SystemRecordType = typeof(require(script["SystemRecord-Type"]))
type SystemRedPointType = typeof(require(script["SystemRedPoint-Type"]))
type SystemSetType = typeof(require(script["SystemSet-Type"]))
type SystemCodeType = typeof(require(script["SystemCode-Type"]))
type SystemFeedbackType = typeof(require(script["SystemFeedback-Type"]))
type SystemShopType = typeof(require(script["SystemShop-Type"]))
type SystemRngType = typeof(require(script["SystemRng-Type"]))
type SystemDailyAwardType = typeof(require(script["SystemDailyAward-Type"]))
type SystemOnlineAwardType = typeof(require(script["SystemOnlineAward-Type"]))
type SystemBuyRobloxType = typeof(require(script["SystemBuyRoblox-Type"]))

-- 客户端系统模块类型
type CameraModuleType = typeof(require(script["CameraModule-Type"]))
type DataCacheType = typeof(require(script["DataCache-Type"]))
type SystemCDKType = typeof(require(script["SystemCDK-Type"]))
type SystemRankManagerType = typeof(require(script["SystemRankManager-Type"]))
type SystemLightingType = typeof(require(script["SystemLighting-Type"]))
type SystemLightingCustomStateType = typeof(require(script["SystemLightingCustomState-Type"]))
type SystemLightingWeatherType = typeof(require(script["SystemLightingWeather-Type"]))
type SystemMoonAniType = typeof(require(script["SystemMoonAni-Type"]))
type SystemInputType = typeof(require(script["SystemInput-Type"]))
type SystemInputBindType = typeof(require(script["SystemInputBind-Type"]))

-- Class 模块类型
-- Utils 系统完整类型定义
-- 注意：Services、通信对象、白名单模块（NetMsg/EnumMgr）为非可选；其余模块为延迟加载可选类型
export type Utils = {
	-- Services（所有环境）
	ReplicatedStorage: ReplicatedStorage?,
	ReplicatedFirst: ReplicatedFirst?,
	Debris: Debris?,
	Players: Players?,
	MarketplaceService: MarketplaceService?,
	RunService: RunService?,
	TeleportService: TeleportService?,
	UserInputService: UserInputService?,
	SoundService: SoundService?,
	GamepadService: GamepadService?,
	TextChatService: TextChatService?,
	TweenService: TweenService?,
	CollectionService: CollectionService?,
	ScriptContext: ScriptContext?,
	HttpService: HttpService?,
	ContentProvider: ContentProvider?,
	Lighting: Lighting?,
	
	-- 服务器专用服务
	ServerStorage: ServerStorage?,
	
	-- 客户端专用
	LocalPlayer: Player?,
	
	-- 通信对象（直接加载，初始化时已创建索引）
	Event: {[string]: BindableEvent?}?,
	RemoteEvent: {[string]: RemoteEvent?}?,
	RemoteFunction: {[string]: RemoteFunction?}?,
	Function: {[string]: BindableFunction?}?,
	
	-- ToolBasic 模块（延迟加载，白名单模块除外）
	InsMgr: InsMgrType?,
	Log: LogType?,
	MathMgr: MathMgrType?,
	KeyframeEval: KeyframeEvalType?,
	AnchorRelative: AnchorRelativeType?,
	VisibleMgr: VisibleMgrType?,
	ObjectPoolUtil: ObjectPoolUtilType?,
	TimeTransfer: TimeTransferType?,
	RankConfig: RankConfigType?,
	Copy: CopyType?,
	ResRestore: ResRestoreType?,
	UISetMgr: UISetMgrType?,
	HumanModule: HumanModuleType?,
	TranslationHelper: TranslationHelperType?,
	ConfigInstance: ConfigInstanceType?,
	BezierCurve: BezierCurveType?,
	ViewportFrameModule: ViewportFrameModuleType?,
	AssetPaths: AssetPathsType?,
	AssetRegistry: AssetRegistryType?,
	NetMsg: NetMsgType,
	LightingTweenUtil: LightingTweenUtilType?,
	ChannelResultUtil: ChannelResultUtilType?,

	-- 业务模块（延迟加载，白名单模块除外）
	EnumMgr: EnumMgrType,
	AnimationModule: AnimationModuleType?,
	ActionArbiter: ActionArbiterType?,
	AnimationLayer: AnimationLayerType?,
	LocoStyle: LocoStyleType?,
	LocoStyleSets: LocoStyleSetsType?,
	CharacterControl: CharacterControlType?,
	CfgFind: CfgFindType?,
	GetData: GetDataType?,
	DeviceType: DeviceTypeType?,
	UIMgr: UIMgrType?,
	ShowDetail: ShowDetailType?,
	TipsModule: TipsModuleType?,
	TipsRenderer: TipsRendererType?,
	TipsConfig: TipsConfigType?,
	SoundModule: SoundModuleType?,
	SoundInstance: SoundInstanceType?,
	FootstepSoundsConfig: any?,
	AssetAcquire: AssetAcquireType?,
	ResourceUtil: ResourceUtilType?,
	AddListen: AddListenType?,
	RequestRateLimit: RequestRateLimitType?,
	NetWork: NetWorkType?,
	UIanima: UIanimaType?,
	SequenceManager: SequenceManagerType?,
	UISequence: SequenceManagerType?,
	SpeedLineFX: SpeedLineFXType?,
	WorldUtil: WorldUtilType?,
	GmEmailWhitelist: GmEmailWhitelistType?,
	Struct: StructType?,
	BurstStone: BurstStoneType?,
	FXUtil: FXUtilType?,
	HatchEffect: HatchEffectType?,
	GhostShadow: GhostShadowType?,
	Lightning: LightningType?,
	PlayerData:PlayerDataType?,
	RayCast: RayCastType?,
	SystemGameConfig: SystemGameConfigType?,
	UpdateModule: UpdateModuleType?,
	SystemDataStore: SystemDataStoreType?,
	SystemGlobalData: SystemGlobalDataType?,
	SystemServerBuff: SystemServerBuffType?,
	SystemRank: SystemRankType?,

	-- 服务器端系统模块（延迟加载，仅服务器端）
	SystemSave: SystemSaveType?,
	SystemBag: SystemBagType?,
	SystemBagToolbar: SystemBagToolbarType?,
	SystemBUFF: SystemBUFFType?,
	SystemEmail: SystemEmailType?,
	SystemUpdateLog: SystemUpdateLogType?,
	SystemRecord: SystemRecordType?,
	SystemRedPoint: SystemRedPointType?,
	SystemSet: SystemSetType?,
	SystemCode: SystemCodeType?,
	SystemFeedback: SystemFeedbackType?,
	SystemShop: SystemShopType?,
	SystemRng: SystemRngType?,
	SystemDailyAward: SystemDailyAwardType?,
	SystemOnlineAward: SystemOnlineAwardType?,
	SystemBuyRoblox: SystemBuyRobloxType?,
	GameAnalytics: any?,

	-- 客户端系统模块（延迟加载，双端可用）
	CameraModule: CameraModuleType?,
	DataCache: DataCacheType?,
	SystemCDK: SystemCDKType?,
	SystemRankManager: SystemRankManagerType?,
	SystemLighting: SystemLightingType?,
	SystemLightingCustomState: SystemLightingCustomStateType?,
	SystemLightingWeather: SystemLightingWeatherType?,
	SystemMoonAni: SystemMoonAniType?,
	SystemInput: SystemInputType?,
	SystemInputBind: SystemInputBindType?,
}

return module
