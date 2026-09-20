--[[
	Module: UIMgr-Type
	Description: UIMgr 类型声明（完整使用说明见 ToolSystem/UIMgr/init.luau 文件头）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-17
]]

local UIMgr = {}

local BagSlotAwardStyle = {}
local BagSlot = {
	AwardStyle = BagSlotAwardStyle,
}
UIMgr.BagSlot = BagSlot

--[[
	按 hero cfg.Role 在 RoleIcon 容器内切换同名子 Gui 可见性
	@param RoleIcon Frame - 角色图标容器
	@param role any - 英雄配置 Role 字段（number/string）
	@return () - 无返回值
]]
function UIMgr.SetRoleIcon(RoleIcon: Frame, role: any): ()
end

--[[
	设置奖励显示
	@param _frame Frame - UI 框架
	@param _itemID number - 物品ID
	@param _count number - 数量
	@param _lv number? - 等级（可选，英雄/装备强化等级）
	@param _fakexyd number? - 假稀有度（可选，主要用于UI显示）
	@param _shardNum number? - 碎片数量（可选，只用于英雄）
	@param _isTips boolean? - 是否显示提示（可选，默认 true）
	@return () - 无返回值
]]
function UIMgr.SetAward(
	_frame: Frame,
	_itemID: number,
	_count: number,
	_lv: number?,
	_fakexyd: number?,
	_shardNum: number?,
	_isTips: boolean?
): ()
end

--[[
	AwardStyle：隐藏 SetAward 约定子节点
	@param frame Frame - 格子框架
	@return () - 无返回值
]]
function BagSlotAwardStyle.Clear(frame: Frame): ()
end

--[[
	AwardStyle：用 SetAward 填格
	@param frame Frame - 格子框架
	@param vm table - SlotVM，字段 id / count；缺 id 时视为 Clear
	@return () - 无返回值
]]
function BagSlotAwardStyle.Bind(frame: Frame, vm: any): ()
end

--[[
	填格；style 须含 Bind，默认 AwardStyle
	@param frame Frame - 格子框架
	@param vm table - GetData.BagView.ToSlotVM 结果
	@param style { Bind: (Frame, any) -> () }? - 皮肤；省略用 AwardStyle
	@return () - 无返回值
]]
function BagSlot.Bind(frame: Frame, vm: any, style: any?): ()
end

--[[
	清空格子；style 须含 Clear，默认 AwardStyle
	@param frame Frame - 格子框架
	@param style { Clear: (Frame) -> () }? - 皮肤；省略用 AwardStyle
	@return () - 无返回值
]]
function BagSlot.Clear(frame: Frame, style: any?): ()
end

--[[
	设置主界面可见性
	@param setVisible boolean? - 是否显示；nil 时根据弹窗「背景模糊/隐藏主界面」自动判断
	@return () - 无返回值
]]
function UIMgr.SetMainUIVisible(setVisible: boolean?): ()
end

--[[
	隐藏宠物相关 UI
	@return () - 无返回值
]]
function UIMgr.HideGui(): ()
end

--[[
	显示宠物相关 UI
	@return () - 无返回值
]]
function UIMgr.ShowGui(): ()
end

--[[
	禁用整个 ScreenGui
	@return () - 无返回值
]]
function UIMgr.HideScreenGui(): ()
end

--[[
	启用整个 ScreenGui
	@return () - 无返回值
]]
function UIMgr.ShowScreenGui(): ()
end

--[[
	根据 ScreenGui 状态与子 UI「背景模糊」标记更新 Lighting 模糊效果
	@return () - 无返回值
]]
function UIMgr.UpdateBlurVisible(): ()
end

--[[
	强制关闭 Lighting UI 模糊效果
	@return () - 无返回值
]]
function UIMgr.CloseBlur(): ()
end

--[[
	设置景深效果可见性
	@param visible boolean - 是否启用景深
	@return () - 无返回值
]]
function UIMgr.VisibleDepth(visible: boolean): ()
end

--[[
	关闭除忽略列表外的其他可见弹窗
	@param player Player - 目标玩家
	@return () - 无返回值
]]
function UIMgr.HideOtherUI(player: Player): ()
end

--[[
	动态设置 UI 列表大小
	@param _frame Frame - UI 框架（支持 Frame 和 ScrollingFrame）
	@return () - 无返回值
]]
function UIMgr.SetUIlistSize(_frame: Frame): ()
end

--[[
	动态设置 UI 网格布局大小
	@param _frame Frame - UI 框架（支持 Frame 和 ScrollingFrame）
	@return () - 无返回值
]]
function UIMgr.SetUIGridLayoutSize(_frame: Frame): ()
end

--[[
	设置标题
	@param _title number - 标题ID
	@param Title ImageLabel - 标题图片标签
	@return () - 无返回值
]]
function UIMgr.SetTitel(_title: number, Title: ImageLabel): ()
end

--[[
	添加文本长度调整脚本
	@param _text TextLabel - 文本标签
	@return () - 无返回值
]]
function UIMgr.AddTextLength(_text: TextLabel): ()
end

--[[
	设置 Robux 价格显示
	@param _text TextLabel - 文本标签
	@param _price number - 价格
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值
]]
function UIMgr.SetRbPrice(_text: TextLabel, _price: number, withSymbol: boolean?): ()
end

--[[
	按付费项 ID / 类型异步拉取 Roblox 真实售价并写入 TextLabel；同进程内每项成功价只请求一次
	@param _text TextLabel - 价格文本标签
	@param productId number - GamePass 或 Developer Product 资产 ID
	@param robuxType number - EnumMgr.RobuxType.GamePass | RobuxItem
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值（缓存命中同步写；否则异步完成后写）
]]
function UIMgr.SetRbPriceByProduct(_text: TextLabel, productId: number, robuxType: number, withSymbol: boolean?): ()
end

--[[
	按 itemshopdataConf.OnlyTag 查表后异步设置 Robux 价格（弹窗 UI 常用）
	@param _text TextLabel - 价格文本标签
	@param onlyTag string - 商城条目 OnlyTag
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值
]]
function UIMgr.SetRbPriceByOnlyTag(_text: TextLabel, onlyTag: string, withSymbol: boolean?): ()
end

--[[
	动态设置 UIListLayout 的大小（支持换行，正确处理 Title 和商品元素）
	@param _frame Frame | ScrollingFrame - 要设置大小的容器框架
	@return () - 无返回值
]]
function UIMgr.SetUIlistSize_New(_frame: Frame | ScrollingFrame)
end

--[[
	隐藏全部 ScreenGui 除了 _unHideUI
	@param _unHideUI string? - 保留显示的 ScreenGui 名称；nil 时隐藏全部
	@return () - 无返回值
]]
function UIMgr.HideAllBut(_unHideUI: string?): ()
end

--[[
	恢复 HideAllBut 之前隐藏的 ScreenGui
	@return () - 无返回值
]]
function UIMgr.RecoverHideUI(): ()
end

--[[
	获取稀有度名称（本地化 Key，不直接写 UI）
	@param xyd number - 稀有度档位
	@return string? - 普通/精良/稀有/史诗/传说/神话；越界 nil
]]
function UIMgr.getXydName(xyd: number): string?
end

--[[
	设置稀有度标签（文案走 TranslationHelper，Key 为字面量）
	@param text TextLabel - 文本标签
	@param xyd number - 稀有度档位
	@param isStroke boolean? - 是否按稀有度添加 UIStroke（默认 true）
	@param useColorTransition boolean? - 是否对 UIGradient 做旧色→新色过渡（默认 true）
	@return () - 无返回值
]]
function UIMgr.setXydLabel(text: TextLabel, xyd: number, isStroke: boolean?, useColorTransition: boolean?)
end

--[[
	设置物品稀有度背景/描边/名称
	@param frame Frame - 物品框架
	@param xyd number - 稀有度档位
	@return () - 无返回值
]]
function UIMgr.SetItemXyd(frame: Frame, xyd: number)
end

--[[
	设置英雄框稀有度背景/描边/特效
	@param frame Frame - 英雄框架
	@param xyd number - 稀有度档位
	@return () - 无返回值
]]
function UIMgr.SetHeroXyd(frame: Frame, xyd: number)
end

--[[
	按稀有度设置描边与背景渐变
	@param frame Frame - 框架（子级 Stroke / BG）
	@param xyd number - 稀有度档位
	@param stroke number? - 描边宽度；有值时按 2 倍缩小 BG
	@return () - 无返回值
]]
function UIMgr.SetStroke(frame: Frame, xyd: number, stroke: number?)
end

--[[
	获取稀有度主色 HEX
	@param xyd number? - 稀有度档位，越界夹取到 1～6
	@return string? - 形如 "#9F9F9F"
]]
function UIMgr.GetXydColorHex(xyd: number?): string?
end

--[[
	获取稀有度颜色文件夹（Assets 活引用，只读）
	@param xyd number? - 稀有度档位；nil 时取 "0"
	@return Folder? - 颜色文件夹
]]
function UIMgr.GetXydColor(xyd: number?): Folder?
end

--[[
	按逻辑名或稀有度别名克隆 Gridient 预设
	@param typeKey string | number - 渐变类型或 GradientCfg 别名
	@return UIGradient? - 克隆出的渐变；未找到时可能回退白色
]]
function UIMgr.GetGradientColor(typeKey: string | number): UIGradient?
end

--[[
	药水滚动条内圆按 xyd 取渐变 1～6
	@param xyd number? - 药水 cfg.xyd
	@return UIGradient? - 克隆的 UIGradient
]]
function UIMgr.GetPotionScrollInnerGradientByXyd(xyd: number?): UIGradient?
end

--[[
	挂载通用渐变（可过渡）
	@param typeKey string? - 渐变类型；nil 不处理
	@param parent Instance - 挂载父节点
	@param isText boolean? - true 时选用 type-Text 预设
	@param rot number? - 目标 Rotation
	@param useColorTransition boolean? - 已有渐变时是否过渡（默认 true）
	@return UIGradient? - 当前或新建的渐变
]]
function UIMgr.AddGradientColor(
	typeKey: string?,
	parent: Instance,
	isText: boolean?,
	rot: number?,
	useColorTransition: boolean?
): UIGradient?
end

--[[
	移除通用渐变并清 xyd Attribute
	@param parent Instance - 挂载父节点
	@return () - 无返回值
]]
function UIMgr.RemoveGradientColor(parent: Instance)
end

--[[
	读取父节点上的 UIGradient
	@param parent Instance - 挂载父节点
	@return UIGradient? - 已有渐变
]]
function UIMgr.GetUIGradient(parent: Instance): UIGradient?
end

--[[
	克隆出的 UIGradient 去掉子级脚本，避免预制体 LocalScript 与模块双跑
	@param gradient UIGradient - 克隆实例
	@return () - 无返回值
]]
function UIMgr.PrepareClonedGradient(gradient: UIGradient)
end

--[[
	注册或覆盖 ColorScroll 色板（色序从原脚本 -1 项起一圈）
	@param name string - 色板名
	@param colors { any } - hex 或 Color3 数组，至少 2 色；可含重复
	@return () - 无返回值
]]
function UIMgr.RegisterGradientAnimPalette(name: string, colors: { any })
end

--[[
	查询 ColorScroll 色板色序（拷贝）
	@param name string - 色板名（彩虹满 / 彩虹柔 / 彩虹柔金 / 彩虹艳 / 彩虹粉 / 红脉）
	@return { string }? - hex 列表；未注册 nil
]]
function UIMgr.GetGradientAnimPalette(name: string): { string }?
end

--[[
	注册或覆盖循环样式（新表现只注册，不改 Core）
	@param styleName string - 样式名（内置 ColorScroll / Rotation，或自定义）
	@param def { writes: { string }, onStart: ((UIGradient, table, table) -> ())?, onTick: (UIGradient, table, number, table) -> (), onStop: ((UIGradient, table, table) -> ())? } - writes 为 Color/Rotation/Offset/Transparency；onTick 每帧写对应属性
	@return () - 无返回值
]]
function UIMgr.RegisterGradientAnimStyle(styleName: string, def: {
	writes: { string },
	onStart: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
	onTick: (UIGradient, { [string]: any }, number, { [string]: any }) -> (),
	onStop: ((UIGradient, { [string]: any }, { [string]: any }) -> ())?,
})
end

--[[
	在 UIGradient 上播放命名循环样式（仅客户端；服务端 no-op）
	@param gradient UIGradient - 目标渐变
	@param styleName string - 已注册样式名（内置 ColorScroll / Rotation）
	@param opts { [string]: any }? - ColorScroll 可用 period、step、palette、colors；Rotation 可用 degPerSec
	@return () - 无返回值
]]
function UIMgr.PlayGradientAnim(gradient: UIGradient, styleName: string, opts: { [string]: any }?)
end

--[[
	停止目标上的循环表现
	@param target Instance - UIGradient 或其挂载父节点
	@param styleName string? - 指定样式；nil 则停全部
	@return () - 无返回值
]]
function UIMgr.StopGradientAnim(target: Instance, styleName: string?)
end

--[[
	按预设名 / 别名 / Attribute GradientAnim 自动播放（无配置则忽略）
	@param gradient UIGradient - 目标渐变
	@param typeKey string? - AddGradientColor 的类型键或解析后的预设名
	@return () - 无返回值
]]
function UIMgr.PlayGradientAnimForPreset(gradient: UIGradient, typeKey: string?)
end

--[[
	按稀有度文件夹为文本挂渐变/描边（不走 Gridient 别名）
	@param text TextLabel - 文本标签
	@param xyd number - 稀有度档位
	@param isStroke boolean? - 是否添加描边（默认 true）
	@return () - 无返回值
]]
function UIMgr.addGradients(text: TextLabel, xyd: number, isStroke: boolean?)
end

--[[
	按 ModelRes.Title 模板套用称号渐变/描边
	@param text TextLabel - 目标称号文本
	@param templateName string? - 与 Title 子级同名；空则卸下
	@param applyStroke boolean? - 是否同步 UIStroke（默认 true）
	@return () - 无返回值
]]
function UIMgr.ApplyTitleTextFromTemplate(text: TextLabel, templateName: string?, applyStroke: boolean?)
end

--[[
	按称号道具 id 解析 Model 并套用模板
	@param text TextLabel - 目标文本
	@param titleId number? - 称号道具配置 id；≤0 卸下
	@param applyStroke boolean? - 是否同步 UIStroke（默认 true）
	@return () - 无返回值
]]
function UIMgr.ApplyTitleTextByTitleId(text: TextLabel, titleId: number?, applyStroke: boolean?)
end

--[[
	按元素类型克隆 ElementGradients 预设
	@param elementType number - EnumMgr.ElementTp，非 None
	@return UIGradient? - 克隆出的渐变
]]
function UIMgr.GetElementGradient(elementType: number): UIGradient?
end

--[[
	为元素类型挂载渐变（可过渡）
	@param elementType number - 与 elementConf 一致
	@param parent Instance - 挂载父节点
	@param isText boolean? - 保留对齐；元素无 *-Text 变体
	@param rot number? - 目标 Rotation
	@return UIGradient? - 当前或新建的渐变
]]
function UIMgr.AddElementGradient(
	elementType: number,
	parent: Instance,
	isText: boolean?,
	rot: number?
): UIGradient?
end

--[[
	移除元素渐变并清 elementType Attribute
	@param parent Instance - 挂载父节点
	@return () - 无返回值
]]
function UIMgr.RemoveElementGradient(parent: Instance)
end

--[[
	对支持颜色的实例做 Color3 过渡
	@param instance Instance - ImageLabel/TextLabel/Frame/UIStroke 等
	@param targetColor Color3 - 目标颜色
	@param duration number? - 秒；缺省与渐变过渡相同
	@param useTransition boolean? - false 则立即设色
	@return () - 无返回值
]]
function UIMgr.TransitionColor3(
	instance: Instance,
	targetColor: Color3,
	duration: number?,
	useTransition: boolean?
)
end

--[[
	将 xyd 夹取到 1～6
	@param xyd number? - 原始稀有度
	@return number - 夹取后的整数
]]
function UIMgr.NormalizeXyd(xyd: number?): number
end

--[[
	背包/商店等 Bg亮底纹染色
	@param xyd number? - 稀有度档位
	@return Color3 - 深色底纹
]]
function UIMgr.GetRarityBgPatternColor(xyd: number?): Color3
end

--[[
	PassItem / SellTemp 稀有度 BG 样式深拷贝
	@param xyd number? - 稀有度档位
	@return table? - Enter/Normal/UIStroke/BGIcon/Effect；无档位 nil
]]
function UIMgr.GetXydPassBgStyle(xyd: number?): {
	Enter: { Color: ColorSequence },
	Normal: { Color: ColorSequence },
	UIStroke: { Color: Color3 },
	BGIcon: { ImageColor3: Color3 },
	Effect: { ImageColor3: Color3 },
}?
end

--[[
	稀有档位主色
	@param xyd number - 稀有度档位
	@return Color3? - 主色
]]
function UIMgr.GetColor3ByXYD(xyd: number): Color3?
end

--[[
	人种界面按主色挂 UIGradient
	@param target Instance? - GuiObject
	@param xyd number - 稀有度档位
	@return () - 无返回值
]]
function UIMgr.SetHumanRaceColor(target: Instance?, xyd: number)
end

--[[
	人种界面按 xyd 挂载 HumanRace「物品背景渐变N」（历史 Get 前缀，实际写入）
	@param frame Frame? - 目标框架
	@param xyd number? - 稀有度档位
	@return () - 无返回值
]]
function UIMgr.GetRaceByxyd(frame: Frame?, xyd: number?)
end

return UIMgr
