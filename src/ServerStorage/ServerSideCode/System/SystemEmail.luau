--[[
	Module: SystemEmail
	Description: 邮件系统（运营离线邮件 DS + 入服自动发奖进背包）
	Author: 林奥宇
	Created: 2026-05-11
	Last Modified: 2026-08-31

	功能：
	- Init(plr)：入服异步发放 DS 未同步邮件 + 老存档 Email 未领奖励，直接进背包
	- GivePlrEmail：运营侧写入离线邮件到 Email DataStore；目标在线则立即发放
	- PrintPlrEmail：调试打印 DS 邮件列表

	数据流：
	- Email DataStore 存放运营离线邮件；发放前先把待发邮件标为已同步并持久化，再入包
	- 标记后离线、标记后读 DS 失败、或入包失败：按本批次 SyncedAt / MailId 回滚为待发放
	- 玩家存档 Email 仅用于兼容老数据；Init 先从存档去掉待发条目再入包，发放失败再写回

	发奖语义：
	- GM / 常规邮件：RewardID + RewardCount 全部按物品入包（含 GamePass 配置 ID），无视背包容量
	- 药水 purity / mpTp 不生效，不写入背包扩展字段
	- Ex_Data.IsGift=1 + PassID：兼容老礼品邮件，走商城解锁（非入包）；配置缺失或解锁失败视为发放失败
	- 不发 AwardPop / 邮件红点 / 收件 UI

	GivePlrEmail 入参 emailData：
	- UserID: number - 目标玩家 UserId（正整数）
	- RewardID: {number} - 奖励配置 ID 列表（ipairs，须与 RewardCount 等长）
	- RewardCount: {number} - 对应数量（每项 1～MAX_ITEM_COUNT）
	- TagTitle / ContentTitle / UpdateText: string? - 展示文案，超长截断
	- Ex_Data: table? - 仅允许 { IsGift=1, PassID=number }；其它键（含药水参数）丢弃
	- 服务端写入 MailId（GUID），用于 UpdateAsync 幂等与发放失败回滚
	- 成功：true, nil
	- DS 已写入、在线入包未完成且标记已回滚（会补发）：true, EnumMgr.GmEmailErr.QueuedGrantFailed
	- DS 已写入、已同步但回滚失败（不会自动补发）：true, EnumMgr.GmEmailErr.SyncRevertFailed

	约束：
	- 通信：GM 发信走 DebugManager 的 DEBUG_EMAIL，本模块不绑定 Remote
	- 未同步邮件条数上限 MAX_UNSYNCED_MAILS；单封奖励条数上限 MAX_REWARD_ITEMS

	调用关系：
	- PlayerManager 入服时调用 Init(plr)
	- DebugManager 白名单玩家调用 GivePlrEmail

	示例：
	local SystemEmail = Utils.SystemEmail
	SystemEmail.Init(player)
	SystemEmail.GivePlrEmail({ UserID = 123, RewardID = {1}, RewardCount = {10} })
]]

-- ========================================
-- 服务引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local SystemBag = Utils.SystemBag
local SystemShop = Utils.SystemShop
local SystemBuyRoblox = Utils.SystemBuyRoblox
local SystemDataStore = Utils.SystemDataStore
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local HttpService = Utils.HttpService
local Struct = Utils.Struct

-- ========================================
-- 模块定义
-- ========================================
local SystemEmail = {}

-- ========================================
-- 常量定义
-- ========================================
local EMAIL_STORE = SystemDataStore.STORE.Email

local MAX_REWARD_ITEMS = 20
local MAX_ITEM_COUNT = 9999
local MAX_UNSYNCED_MAILS = 50
local MAX_TAG_TITLE_LEN = 64
local MAX_CONTENT_TITLE_LEN = 200
local MAX_UPDATE_TEXT_LEN = 2000

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家是否仍在线且有效

	@param plr Player - 待校验玩家
	@return boolean - true 表示玩家有效
]]
local function _validatePlayer(plr: Player): boolean
	return plr ~= nil and plr.Parent ~= nil
end

--[[
	将任意值截断为不超过 maxLen 字节的字符串，且落在 UTF-8 码点边界上

	@param value any - 原始值；非 string 时 tostring
	@param maxLen number - 最大字节长度
	@return string - 截断后的文本；value 为 nil 时为空串
]]
local function _truncateString(value: any, maxLen: number): string
	local text = if type(value) == "string" then value else tostring(value or "")
	if #text <= maxLen then
		return text
	end

	local resultEnd = 0
	local walkOk, walkErr = pcall(function()
		for startByte in utf8.codes(text) do
			local nextStart = utf8.offset(text, 2, startByte)
			local charEnd = if nextStart then nextStart - 1 else #text
			if charEnd > maxLen then
				break
			end
			resultEnd = charEnd
		end
	end)
	if walkOk then
		return string.sub(text, 1, resultEnd)
	end

	Log.warn("SystemEmail: UTF-8 截断回退为按字节", walkErr)
	return string.sub(text, 1, maxLen)
end

--[[
	解析并校验目标 UserId

	@param rawUserId any - 邮件入参 UserID
	@return number? - 正整数 UserId；非法为 nil
]]
local function _parseUserId(rawUserId: any): number?
	local userId = tonumber(rawUserId)
	if not userId or userId ~= userId or userId <= 0 or userId ~= math.floor(userId) then
		return nil
	end
	return userId
end

--[[
	获取玩家存档中的 Email 表

	@param plr Player - 玩家对象
	@return table? - Email 存档表；无数据时 nil
]]
local function _getEmailData(plr: Player)
	return PlayerData.GetPlrDataByKey(plr, "Email")
end

--[[
	判断 DS 邮件是否尚未发放

	@param mail any - DS 邮件条目；IsSynced 为 nil/0 表示待发放
	@return boolean - true 表示待发放
]]
local function _isMailPendingSync(mail: any): boolean
	if type(mail) ~= "table" then
		return false
	end
	local isSynced = mail.IsSynced
	return isSynced == nil or isSynced == 0
end

--[[
	统计 DS 列表中待发放邮件数量

	@param data any - Email DS 数组
	@return number - pending 条数
]]
local function _countPendingMails(data: any): number
	if type(data) ~= "table" then
		return 0
	end
	local pending = 0
	for _, mail in ipairs(data) do
		if _isMailPendingSync(mail) then
			pending += 1
		end
	end
	return pending
end

--[[
	校验奖励列表并拷贝为平行数组

	@param rewardID any - 奖励 ID 列表
	@param rewardCount any - 对应数量列表
	@return {number}?, {number}?, string? - 拷贝后的 ID、数量；失败时第三项为错误码
]]
local function _sanitizeRewardLists(rewardID: any, rewardCount: any): ({ number }?, { number }?, string?)
	if type(rewardID) ~= "table" or type(rewardCount) ~= "table" then
		return nil, nil, "INVALID_REWARD_LIST"
	end
	if #rewardID ~= #rewardCount then
		return nil, nil, "REWARD_LIST_MISMATCH"
	end
	if #rewardID == 0 then
		return nil, nil, "EMPTY_REWARD_LIST"
	end
	if #rewardID > MAX_REWARD_ITEMS then
		return nil, nil, "TOO_MANY_REWARDS"
	end

	local ids: { number } = {}
	local counts: { number } = {}
	for index, rawId in ipairs(rewardID) do
		local itemId = tonumber(rawId)
		local count = tonumber(rewardCount[index])
		if not itemId or itemId ~= math.floor(itemId) or itemId <= 0 then
			return nil, nil, "INVALID_REWARD_ID"
		end
		if not count or count ~= math.floor(count) or count < 1 or count > MAX_ITEM_COUNT then
			return nil, nil, "INVALID_REWARD_COUNT"
		end
		if not CfgFind.FindCfgByID(itemId) then
			return nil, nil, "UNKNOWN_REWARD_ID"
		end
		ids[index] = itemId
		counts[index] = count
	end
	return ids, counts, nil
end

--[[
	清洗 Ex_Data：丢弃药水等未知键；仅保留合法礼品解锁字段

	@param exData any - 客户端/运营传入的 Ex_Data
	@return table?, string? - 清洗后的表；失败时第二项为错误码
]]
local function _sanitizeExData(exData: any): ({ [string]: any }?, string?)
	if exData == nil then
		return {}, nil
	end
	if type(exData) ~= "table" then
		return nil, "INVALID_EX_DATA"
	end

	local isGift = tonumber(exData.IsGift)
	if isGift == 1 then
		local passID = tonumber(exData.PassID)
		if not passID or passID ~= math.floor(passID) or passID <= 0 then
			return nil, "INVALID_GIFT_PASS"
		end
		if not CfgFind.FindCfgByPassID(passID) then
			return nil, "INVALID_GIFT_PASS"
		end
		return { IsGift = 1, PassID = passID }, nil
	end

	return {}, nil
end

--[[
	邮件在 DS 回滚时用的键：优先 MailId，否则 Time 字符串

	@param mail any - DS 邮件条目
	@return string - 回滚查找键
]]
local function _mailIdentity(mail: any): string
	if type(mail) == "table" and type(mail.MailId) == "string" then
		return mail.MailId
	end
	if type(mail) == "table" and type(mail.Time) == "number" then
		return tostring(mail.Time)
	end
	return ""
end

--[[
	把本批次已标记同步的邮件回滚为待发放

	@param userIdStr string - UserId 字符串
	@param failedMailIds {[string]: boolean}? - 要回滚的键集合；nil 表示本批次 SyncedAt 全部回滚
	@param syncedAt number - 本批次标记时间
	@return boolean - DS Update 成功为 true
]]
local function _revertSyncMarks(userIdStr: string, failedMailIds: { [string]: boolean }?, syncedAt: number): boolean
	local revertOk, _, revertErr = SystemDataStore.Update(EMAIL_STORE, userIdStr, function(oldData)
		if type(oldData) ~= "table" then
			return oldData
		end
		for _, mail in ipairs(oldData) do
			if mail.IsSynced == 1 and mail.SyncedAt == syncedAt then
				local idKey = _mailIdentity(mail)
				if failedMailIds == nil or (idKey ~= "" and failedMailIds[idKey]) then
					mail.IsSynced = 0
					mail.SyncedAt = 0
				end
			end
		end
		return oldData
	end)
	if not revertOk then
		Log.warn("SystemEmail: DS 发放失败回滚标记失败", userIdStr, revertErr)
		return false
	end
	return true
end

--[[
	将 DS 邮件转为发奖用结构（剥离 DS 专用字段）

	@param dsMail Struct.DsEmail - DataStore 邮件条目
	@return Struct.Email - 发奖数据
]]
local function _dsMailToPlayerMail(dsMail: Struct.DsEmail): Struct.Email
	return {
		RewardID = dsMail.RewardID,
		RewardCount = dsMail.RewardCount,
		Ex_Data = dsMail.Ex_Data or {},
		TagTitle = dsMail.TagTitle or "",
		ContentTitle = dsMail.ContentTitle or "",
		UpdateText = dsMail.UpdateText or "",
		Time = dsMail.Time,
		IsRead = dsMail.IsRead or 0,
		IsClaim = dsMail.IsClaim or 0,
	}
end

--[[
	发放普通物品类邮件奖励（含 GamePass 配置 ID；不检查背包容量；药水参数不生效）
	同一封邮件一次 AddItems，避免逐件入包失败导致半包后回滚重复发奖

	@param plr Player - 玩家对象
	@param data Struct.Email - 邮件数据
	@return boolean - true 表示发奖成功
]]
local function _grantItemMailRewards(plr: Player, data: Struct.Email): boolean
	if not _validatePlayer(plr) then
		return false
	end

	local rewardID = data.RewardID or {}
	local rewardCount = data.RewardCount or {}
	local ids: { number } = {}
	local counts: { number } = {}

	for key, rawId in pairs(rewardID) do
		local itemId = tonumber(rawId)
		if not itemId then
			Log.warn("SystemEmail: 无效物品 ID", rawId)
			return false
		end
		local itemCfg = CfgFind.FindCfgByID(itemId)
		if not itemCfg then
			Log.warn("SystemEmail: 无效物品配置", itemId)
			return false
		end
		local count = math.floor(tonumber(rewardCount[key]) or 0)
		if count > 0 then
			table.insert(ids, itemId)
			table.insert(counts, count)
		end
	end

	if #ids == 0 then
		return true
	end

	local ok = SystemBag.AddItems(plr, ids, counts)
	if not ok then
		Log.warn("SystemEmail: 整封入包失败", plr.UserId)
		return false
	end

	return true
end

--[[
	发放单封邮件奖励（老礼品解锁或物品入包）

	@param plr Player - 玩家对象
	@param data Struct.Email - 邮件数据
	@return boolean - true 表示发奖成功
]]
local function _grantMailRewards(plr: Player, data: Struct.Email): boolean
	if not _validatePlayer(plr) or not data then
		return false
	end

	local exData = data.Ex_Data
	if exData and tonumber(exData.IsGift) == 1 and exData.PassID then
		local giftCfg = CfgFind.FindCfgByPassID(exData.PassID)
		if not giftCfg then
			Log.warn("SystemEmail: Gift Pass 配置缺失", exData.PassID)
			return false
		end
		if giftCfg.cost == EnumMgr.RobuxType.GamePass then
			local ok, err = SystemShop.BuyGamePassSuc(plr, giftCfg.passID)
			if not ok then
				Log.warn("SystemEmail: Gift GamePass 解锁失败", plr.UserId, giftCfg.passID, err)
				return false
			end
			return true
		end

		local buyOk = SystemBuyRoblox.BuyItemEnd(plr, giftCfg.OnlyTag)
		if not buyOk then
			Log.warn("SystemEmail: Gift 商品解锁失败", plr.UserId, giftCfg.OnlyTag)
			return false
		end
		return true
	end

	return _grantItemMailRewards(plr, data)
end

--[[
	发放并清理玩家存档中的老邮件。
	先把待发条目从存档去掉再入包，避免写回失败导致已入包项下次再发；发放失败的条目再写回。

	@param plr Player - 玩家对象
	@return nil
]]
local function _grantAndClearLegacySaveEmails(plr: Player)
	local email = _getEmailData(plr)
	if not email or not next(email) then
		return
	end

	local remaining: { [any]: any } = {}
	local pending: { { key: any, entry: any } } = {}
	local hasRemaining = false
	for key, entry in pairs(email) do
		if entry and entry.IsClaim ~= 1 then
			table.insert(pending, { key = key, entry = entry })
		else
			remaining[key] = entry
			hasRemaining = true
		end
	end
	if #pending == 0 then
		return
	end

	local writeOk, writeErr = PlayerData.ChangePlrData(plr, "Email", if hasRemaining then remaining else {})
	if not writeOk then
		Log.warn("SystemEmail: 老存档邮件写回失败，跳过发放", plr.UserId, writeErr)
		return
	end

	local needRestore = false
	for _, item in pending do
		local ok = _grantMailRewards(plr, item.entry)
		if not ok then
			Log.warn("SystemEmail: 老存档邮件发放失败", plr.UserId, item.key)
			remaining[item.key] = item.entry
			hasRemaining = true
			needRestore = true
		end
	end

	if not needRestore then
		return
	end

	local restoreOk, restoreErr = PlayerData.ChangePlrData(plr, "Email", remaining)
	if not restoreOk then
		Log.warn("SystemEmail: 老存档失败项写回失败", plr.UserId, restoreErr)
	end
end

--[[
	先把待同步邮件标为已同步并写入 DS，再入包；失败项按 MailId 回滚标记。
	标记后尚未入包就离线 / 读 DS 失败时，回滚本批次全部标记，避免已同步却未发奖。

	@param plr Player - 玩家对象
	@param userIdStr string - UserId 字符串
	@return boolean, string? - 无需发放或全部入包成功为 true；失败 false 与错误码
]]
local function _grantPendingDsEmails(plr: Player, userIdStr: string): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, "PLAYER_OFFLINE"
	end

	local peekOk, peekData, peekErr = SystemDataStore.Get(EMAIL_STORE, userIdStr)
	if not peekOk then
		Log.warn("SystemEmail: DS 读取失败", userIdStr, peekErr)
		return false, "DS_READ_FAILED"
	end
	if _countPendingMails(peekData) == 0 then
		return true, nil
	end

	local syncedAt = workspace:GetServerTimeNow()
	local updateOk, _, updateErr = SystemDataStore.Update(EMAIL_STORE, userIdStr, function(oldData)
		if type(oldData) ~= "table" then
			return oldData
		end
		for _, mail in ipairs(oldData) do
			if _isMailPendingSync(mail) then
				mail.IsSynced = 1
				mail.SyncedAt = syncedAt
			end
		end
		return oldData
	end)
	if not updateOk then
		Log.warn("SystemEmail: DS 同步标记失败", userIdStr, updateErr)
		return false, "DS_SYNC_FAILED"
	end

	local getOk, data, getErr = SystemDataStore.Get(EMAIL_STORE, userIdStr)
	if not getOk or type(data) ~= "table" then
		Log.warn("SystemEmail: DS 标记后读取失败，尝试回滚同步标记", userIdStr, getErr)
		if not _revertSyncMarks(userIdStr, nil, syncedAt) then
			return false, EnumMgr.GmEmailErr.SyncRevertFailed
		end
		return false, EnumMgr.GmEmailErr.QueuedGrantFailed
	end

	if not _validatePlayer(plr) then
		Log.warn("SystemEmail: 标记后玩家已离线，尝试回滚同步标记", userIdStr)
		if not _revertSyncMarks(userIdStr, nil, syncedAt) then
			return false, EnumMgr.GmEmailErr.SyncRevertFailed
		end
		return false, EnumMgr.GmEmailErr.QueuedGrantFailed
	end

	local failedMailIds: { [string]: boolean } = {}
	local needRevert = false
	for _, mail in ipairs(data) do
		if mail.IsSynced == 1 and mail.SyncedAt == syncedAt then
			if _grantMailRewards(plr, _dsMailToPlayerMail(mail)) then
				continue
			end
			Log.warn("SystemEmail: DS 邮件发放失败", userIdStr, mail.MailId)
			local idKey = _mailIdentity(mail)
			if idKey ~= "" then
				failedMailIds[idKey] = true
			end
			needRevert = true
		end
	end

	if not needRevert then
		return true, nil
	end

	if not _revertSyncMarks(userIdStr, failedMailIds, syncedAt) then
		return false, EnumMgr.GmEmailErr.SyncRevertFailed
	end
	return false, EnumMgr.GmEmailErr.QueuedGrantFailed
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	打印玩家 DS 邮件信息（调试用）

	@param userID number | string - 玩家 UserId
	@return nil
]]
function SystemEmail.PrintPlrEmail(userID: number | string)
	local userIdStr = tostring(userID)
	local ok, data, err = SystemDataStore.Get(EMAIL_STORE, userIdStr)
	if not ok then
		Log.warn("SystemEmail.PrintPlrEmail: 读取失败", userIdStr, err)
		return
	end
	if not data then
		Log.print("SystemEmail: 邮件空", userIdStr)
		return
	end

	Log.print("SystemEmail: 玩家 DS 邮件", userIdStr)
	for _, v in pairs(data) do
		local mailText = v.UpdateText or v.Des or ""
		Log.print("邮件内容:", mailText, "IsSynced:", v.IsSynced, "SyncedAt:", v.SyncedAt)
		local rewardID = v.RewardID
		local rewardCount = v.RewardCount
		if rewardID and rewardCount then
			for k1, id in pairs(rewardID) do
				Log.print(string.format("<%sx%s>", tostring(id), tostring(rewardCount[k1])))
			end
		end
	end
end

--[[
	运营侧向玩家 DS 写入离线邮件；目标在线时立即入包

	@param emailData table - 见文件头 GivePlrEmail 入参
	@return boolean, string? - 失败 false 与错误码；写入成功 true；在线入包未完成且会补发时为 QueuedGrantFailed；已同步但回滚失败为 SyncRevertFailed
]]
function SystemEmail.GivePlrEmail(emailData: any): (boolean, string?)
	if type(emailData) ~= "table" then
		return false, "INVALID_EMAIL_DATA"
	end

	local userID = _parseUserId(emailData.UserID)
	if not userID then
		return false, "MISSING_USER_ID"
	end

	local rewardIDs, rewardCounts, rewardErr = _sanitizeRewardLists(emailData.RewardID, emailData.RewardCount)
	if not rewardIDs or not rewardCounts then
		return false, rewardErr or "INVALID_REWARD_LIST"
	end

	local exData, exErr = _sanitizeExData(emailData.Ex_Data)
	if not exData then
		return false, exErr or "INVALID_EX_DATA"
	end

	local storedEmail: Struct.DsEmail = {
		RewardID = rewardIDs,
		RewardCount = rewardCounts,
		Ex_Data = exData,
		TagTitle = _truncateString(emailData.TagTitle, MAX_TAG_TITLE_LEN),
		ContentTitle = _truncateString(emailData.ContentTitle, MAX_CONTENT_TITLE_LEN),
		UpdateText = _truncateString(emailData.UpdateText, MAX_UPDATE_TEXT_LEN),
		Time = workspace:GetServerTimeNow(),
		IsRead = 0,
		IsClaim = 0,
		IsSynced = 0,
		SyncedAt = 0,
		MailId = HttpService:GenerateGUID(false),
	}

	local userIdStr = tostring(userID)
	local rejectReason: string? = nil
	local updateOk, _, updateErr = SystemDataStore.Update(EMAIL_STORE, userIdStr, function(oldData)
		rejectReason = nil
		local data = if type(oldData) == "table" then oldData else {}
		for _, mail in ipairs(data) do
			if mail.MailId == storedEmail.MailId then
				return data
			end
		end
		if _countPendingMails(data) >= MAX_UNSYNCED_MAILS then
			rejectReason = "MAIL_QUEUE_FULL"
			return oldData
		end
		table.insert(data, storedEmail)
		return data
	end)
	if not updateOk then
		Log.warn("SystemEmail.GivePlrEmail: 写入失败", userIdStr, updateErr)
		return false, "DS_WRITE_FAILED"
	end
	if rejectReason then
		return false, rejectReason
	end

	local targetPlr = Players:GetPlayerByUserId(userID)
	if targetPlr then
		local grantOk, grantErr = _grantPendingDsEmails(targetPlr, userIdStr)
		if not grantOk then
			Log.warn("SystemEmail.GivePlrEmail: 在线发放未完成", userIdStr, grantErr)
			if grantErr == EnumMgr.GmEmailErr.SyncRevertFailed then
				return true, EnumMgr.GmEmailErr.SyncRevertFailed
			end
			return true, EnumMgr.GmEmailErr.QueuedGrantFailed
		end
	end

	return true, nil
end

--[[
	玩家入服时异步发放老存档邮件与 DS 待同步邮件（由 PlayerManager 调用）

	@param plr Player - 刚完成数据加载的玩家
	@return nil
]]
function SystemEmail.Init(plr: Player)
	if not _validatePlayer(plr) then
		return
	end

	local userId = plr.UserId
	local userIdStr = tostring(userId)

	task.spawn(function()
		if not Players:GetPlayerByUserId(userId) then
			return
		end

		_grantAndClearLegacySaveEmails(plr)

		if not Players:GetPlayerByUserId(userId) then
			return
		end

		_grantPendingDsEmails(plr, userIdStr)
	end)
end

return SystemEmail
