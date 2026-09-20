local module = {}

-- 导出 Item 类型
export type Item = {
	id: number,      -- 物品的配置ID
	tp: number,      -- 物品类型
	onlyID: number,  -- 物品的OnlyID
	lock: number,    -- 物品锁定
	count: number,   -- 物品的数量
}

export type Email = {
	RewardID: { number }?,
	RewardCount: { number }?,
	Ex_Data: { [string]: any }?,
	TagTitle: string?,
	ContentTitle: string?,
	UpdateText: string?,
	Time: number?,
	IsRead: number?,
	IsClaim: number?,
	Des: { string }?,
}

export type DsEmail = Email & {
	IsSynced: number?,
	SyncedAt: number?,
	MailId: string?,
}

return module