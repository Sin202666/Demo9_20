local Config={
	["appid"]=  '3638c78d33f6469594810d1fb9cd7a73';
	['server']= 'https://global-receiver-ta.thinkingdata.cn';
	['enableLog']=false;---Enable console logging output.By default, it is disabled
	['strict'] = false;--- Validate the data format, By default, it is not validated.
}
local SendMethod = 'batch';--By default, it is in batch mode, and you can also set it to debug mode during testing.
local MaxRequest = 200;--The default setting is to allow a maximum of 200 network requests per minute, while Roblox allows a maximum of 500 network requests per minute to external systems. You can adjust the maximum number of network requests based on your specific business needs.
local ThinkingAnalyticsAPI = {}
local HttpService = game:GetService("HttpService")
function class(base, _ctor)
	local c = {}
	if not _ctor and type(base) == 'function' then
		_ctor = base
		base = nil
	elseif type(base) == 'table' then
		for i, v in pairs(base) do
			c[i] = v
		end
		c._base = base
	end
	c.__index = c
	local mt = {}
	mt.__call = function(_, ...)
		local obj = {}
		setmetatable(obj, c)
		if _ctor then
			_ctor(obj, ...) 
		end
		return obj
	end
	c._ctor = _ctor
	c.is_a = function(self, klass)
		local m = getmetatable(self)
		while m do
			if m == klass then
				return true
			end
			m = m._base
		end
		return false
	end
	setmetatable(c, mt)
	return c
end

TDSDK = class(function(self, consumer, strictMode, enableLog)
	if consumer == nil or type(consumer) ~= "table" then
		error("consumer params is invalidate.")
	end
	self.consumer = consumer
	self.checkKeyAndValue = strictMode or TDSDK.strictMode
	self.superProperties = {}
	self.dynamicSuperPropertiesTracker = nil
	Util.enableLog = enableLog
end)


--TADynamicSuperPropertiesTracker
TDSDK.TADynamicSuperPropertiesTracker = class()

function TDSDK.TADynamicSuperPropertiesTracker:getProperties()
end

--DebugConsumer
TDSDK.DebugConsumer = class(function(self, url, appid, debugOnly)
	if appid == nil or type(appid) ~= "string" or string.len(appid) == 0 then
		error("appid can't be empty")
	end
	if url == nil or type(url) ~= "string" or string.len(url) == 0 then
		error("server url can't be empty")
	end
	self.url = url .. "/data_debug"
	self.appid = appid
	self.debugOnly = debugOnly
	TDSDK.strictMode = true
end)
function TDSDK.DebugConsumer:add(msg)
	local code = Util.post(self.url, self.appid, msg, true, self.debugOnly)
	Util.log("Info: ", "send to: " .. self.url .. " return Code:[" .. code .. "]\nBody: " .. Util.toJson(msg))
	if (returnCode == 0) then
		return true
	end
	return false
end
function TDSDK.DebugConsumer:flush()
end
function TDSDK.DebugConsumer:close()
end
function TDSDK.DebugConsumer:toString()
	return "\n--Consumer: DebugConsumer" ..
		"\n--Consumer.Url: " .. self.url ..
		"\n--Consumer.Appid: " .. self.appid
end

--BatchConsumer
TDSDK.BatchConsumer = class(function(self, url, appid, batchNum, cacheCapacity)
	if appid == nil or type(appid) ~= "string" or string.len(appid) == 0 then
		error("appid can't be empty")
	end
	if url == nil or type(url) ~= "string" or string.len(url) == 0 then
		error("server url can't be empty")
	end
	if batchNum ~= nil and type(batchNum) ~= "number" then
		error("must be nummber type")
	end
	self.url = url .. "/sync_server"
	self.appid = appid
	self.batchNum = batchNum or TDSDK.batchNumber
	self.eventArrayJson = {}
	self.cacheCapacity = cacheCapacity or TDSDK.cacheCapacity
	self.cacheTable = {}
	self.requestNum = 0;
	self.currentMinute=Util.getCurrentMinute();
end)
function TDSDK.BatchConsumer:add(msg)
	local num = #self.eventArrayJson + 1
	self.eventArrayJson[num] = msg
	if (num >= self.batchNum or #self.cacheTable > 0) then
		return self:flush()
	end
	return true
end

function TDSDK.BatchConsumer:flush()
	local  minute = Util.getCurrentMinute()
	if minute ~= self.currentMinute then
		self.currentMinute = minute
		self.requestNum = 0;
	end
	if #self.eventArrayJson == 0 and #self.cacheTable == 0 then
		return true
	end
	if (#self.eventArrayJson >= self.batchNum or #self.cacheTable == 0) then
		local events = self.eventArrayJson
		self.eventArrayJson = {}
		table.insert(self.cacheTable, events)
	end
	while (#self.cacheTable > 0)
	do
		local events = self.cacheTable[1]
		local code = Util.post(self.url, self.appid, events)
		if self.requestNum >= MaxRequest then
			return false
		end
		self.requestNum += 1;
		Util.log("Info: ", "sent to: " .. self.url .. " return Code:[" .. code .. "]\nBody: " .. Util.toJson(events) )
		if (code == 0) then
			table.remove(self.cacheTable, 1)
		else
			if (#self.cacheTable > self.cacheCapacity) then
				table.remove(self.cacheTable, 1)
			end
			return false
		end
	end
	return true
end


function TDSDK.BatchConsumer:close()
	return self:flush(true)
end
function TDSDK.BatchConsumer:toString()
	return "\n--Consumer: BatchConsumer" ..
		"\n--Consumer.Url: " .. self.url ..
		"\n--Consumer.Appid: " .. self.appid ..
		"\n--Consumer.BatchNum: " .. self.batchNum
end

--[[
     * set dynamic common properties
     * @param params
--]]
function TDSDK:setDynamicSuperProperties(callback)
	if callback ~= nil then
		self.dynamicSuperPropertiesTracker = callback
	end
end


function TDSDK:userSet(accountId, distinctId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_set", nil, nil, properties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userSet: success")
		return ret
	else
		Util.log("Error: ", "userSet failed: ", ret)
	end
end
function TDSDK:userSetOnce(accountId, distinctId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_setOnce", nil, nil, properties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userSetOnce: success")
		return ret
	else
		Util.log("Error: ", "userSetOnce failed: ", ret)
	end
end

function TDSDK:userAdd(accountId, distinctId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_add", nil, nil, properties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userAdd: success")
		return ret
	else
		Util.log("Error: ", "userAdd failed: ", ret)
	end
end

function TDSDK:userAppend(accountId, distinctId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_append", nil, nil, properties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userUniqueAppend: success")
		return ret
	else
		Util.log("Error: ", "userUniqueAppend failed: ", ret)
	end
end

function TDSDK:userUniqueAppend(accountId, distinctId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_uniq_append", nil, nil, properties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userUniqueAppend: success")
		return ret
	else
		Util.log("Error: ", "userUniqueAppend failed: ", ret)
	end
end

function TDSDK:userUnset(accountId, distinctId, properties)
	local unSetProperties = {}
	for key, value in pairs(properties) do
		if Util.startWith(key, '#')then
			unSetProperties[key] = value
		else
			unSetProperties[key] = 0
		end
	end
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_unset", nil, nil, unSetProperties, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userUnSet: success")
		return ret
	else
		Util.log("Error: ", "userUnSet failed: ", ret)
	end
end
function TDSDK:userDel(accountId, distinctId)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "user_del", nil, nil, {}, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "userDelete: success")
		return ret
	else
		Util.log("Error: ", "userDelete failed: ", ret)
	end
end


function TDSDK:track(accountId, distinctId, eventName, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "track", eventName, "", properties, self.superProperties, self.dynamicSuperPropertiesTracker, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "track: success")
		return ret
	else
		Util.log("Error: ", "track failed: ", ret)
	end
end

function TDSDK:trackFirst(accountId, distinctId, eventName, firstCheckId, properties)
	local mProperties = {}
	for i,v in ipairs(properties) do
		mProperties[i] = v
	end
	Util.tablecopy(properties,mProperties)   
	if firstCheckId ~= nil and string.len(firstCheckId) ~= 0 then
		mProperties["#first_check_id"] = tostring(firstCheckId)
	else
		mProperties["#first_check_id"] = tostring(distinctId)
	end
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "track", eventName, nil, mProperties, self.superProperties, self.dynamicSuperPropertiesTracker, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "trackFirst: success")
		return ret
	else
		Util.log("Error: ", "trackFirst failed: ", ret)
	end
end

function TDSDK:trackUpdate(accountId, distinctId, eventName, eventId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "track_update", eventName, eventId, properties, self.superProperties, self.dynamicSuperPropertiesTracker, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "track_update: success")
		return ret
	else
		Util.log("Error: ", "track_update failed: ", ret)
	end
end
function TDSDK:trackOverwrite(accountId, distinctId, eventName, eventId, properties)
	local ok, ret = pcall(upload, self.consumer, distinctId, accountId, "track_overwrite", eventName, eventId, properties, self.superProperties, self.dynamicSuperPropertiesTracker, self.checkKeyAndValue)
	if ok then
		Util.log("Info: ", "track_overwrite: success")
		return ret
	else
		Util.log("Error: ", "track_overwrite failed: ", ret)
	end
end

--[[
     * uoload data.
     * @param consumer
     * @param distinctId distinct id
     * @param isLogin is login
     * @param eventName event name
     * @param eventId event id
     * @param properties properties
     * @param super common properties
--]]
function upload(consumer, distinctId, accountId, eventType, eventName, eventId, properties, superProperties, dynamicSuperPropertiesTracker, checkKeyAndValue)
	local finalProperties, presetProperties = divide(properties)
	local dynamicSuperProperties = {}
	if dynamicSuperPropertiesTracker ~= nil then
		dynamicSuperProperties = dynamicSuperPropertiesTracker:getProperties()
		check(distinctId, accountId, eventType, eventName, eventId, finalProperties, dynamicSuperProperties, checkKeyAndValue)
	else
		check(distinctId, accountId, eventType, eventName, eventId, finalProperties, checkKeyAndValue)
	end
	local eventJson = {}
	if accountId ~= nil and string.len(accountId) ~= 0 then
		eventJson["#account_id"] = tostring(accountId)
	end
	if distinctId ~= nil and string.len(distinctId) ~= 0 then
		eventJson["#distinct_id"] = tostring(distinctId)
	end
	eventJson["#type"] = eventType
	if eventName ~= nil and string.len(eventName) ~= 0 then
		eventJson["#event_name"] = tostring(eventName)
	end
	if eventId ~= nil and string.len(eventId) ~= 0 then
		eventJson["#event_id"] = tostring(eventId)
	end
	for key, value in pairs(presetProperties) do
		eventJson[key] = value
	end
	if presetProperties["#time"] == nil then
		eventJson["#time"] = os.date("%Y-%m-%d %H:%M:%S")
	end
	local mergeProperties = {}
	if eventType == "track" or eventType == "track_update" or eventType == "track_overwrite" then
		mergeProperties = Util.mergeTables(mergeProperties, superProperties)
		mergeProperties = Util.mergeTables(mergeProperties, dynamicSuperProperties)
		mergeProperties["#lib"] = TDSDK.LibName
		mergeProperties["#lib_version"] = TDSDK.LibVersion
	end
	mergeProperties = Util.mergeTables(mergeProperties, finalProperties)
	eventJson["properties"] = mergeProperties
	local ret = consumer:add(eventJson)
	presetProperties = nil
	finalProperties = nil
	mergeProperties = nil
	eventJson = nil
	return ret
end

function divide(properties)
	local presetProperties = {}
	local finalProperties = {}
	for key, value in pairs(properties) do
		if (key == "#ip" or key == "#uuid" or key == "#first_check_id" or key == "#time" or key == "#app_id") then
			presetProperties[key] = value
		else
			finalProperties[key] = value
		end
	end
	if (presetProperties["#uuid"] == nil) then
		presetProperties["#uuid"] = Util.create_uuid()
	end
	return finalProperties, presetProperties
end

function check(distinctId, accountId, eventType, eventName, eventId, properties, dynamicSuperProperties, checkKeyAndValue)
	if checkKeyAndValue == nil or checkKeyAndValue == false then
		return
	end
	assert(distinctId == nil or type(distinctId) == "string" or type(distinctId) == "number", "distinctId must be string or number type")
	assert(accountId == nil or type(accountId) == "string" or type(accountId) == "number", "accountId must be string or number type")
	assert(type(eventType) == "string", "type must be string type")
	assert(eventName == nil or type(eventName) == "string", "eventName must be string type")
	assert(type(properties) == "table", "properties must be Table type")
	if dynamicSuperProperties ~= nil then
		assert(type(dynamicSuperProperties) == "table", "dynamicSuperProperties must be Table type")
		checkKV(dynamicSuperProperties, eventName)
	end
	-- check name
	if ((distinctId == nil or string.len(distinctId) == 0) and (accountId == nil or string.len(accountId) == 0)) then
		error("distinctId, accountId can't both be empty")
	end
	if (Util.startWith(eventType, "track") and (eventName == nil or string.len(eventName) == 0)) then
		error("eventName can't be empty when the type is track or track_update or track_overwrite")
	end
	if (Util.startWith(eventType, "track_")  and (eventId == nil or string.len(eventId) == 0)) then
		error("eventId can't be empty when the type is track_update or track_overwrite")
	end
	checkKV(properties, eventName)
end

function checkKV(properties, eventName)
	-- check K/V
	local userAdd = "user_add"
	local userUnset = "user_unset"
	for key, value in pairs(properties) do
		if (string.len(key) == 0) then
			Util.log("Warn: ", "The property key is empty")
		end
		if (type(value) ~= "string" and
			type(value) ~= "number" and
			type(value) ~= "boolean" and
			type(value) ~= "table") then
			Util.log("Warn: ", "The property " .. key .. " is not number, string, boolean, table.")
		end
		if (type(value) == "table") then
			for k, v in pairs(value) do
				if (type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" and type(v) ~= "table") then
					Util.log("Warn: ", "The table property " .. k .. " is not number, string, boolean, table.")
				end
			end
		end
		if (type(value) == "string" and string.len(value) == 0 and not (userUnset == eventName)) then
			Util.log("Warn: ", "The property " .. key .. " string value is null or empty")
		end

		if (userAdd == eventName and type(value) ~= "number") then
			Util.log("Warn: ", "The property value of " .. key .. " should be a number ")
		end
	end
end

function TDSDK:flush()
	self.consumer:flush()
end

function TDSDK:close()
	self.consumer:close()
end

function TDSDK:toString()
	return self.consumer:toString()
end

TDSDK.LibName = "Roblox"
TDSDK.LibVersion = "1.0.0"
TDSDK.batchNumber = 50
TDSDK.strictMode = false
TDSDK.cacheCapacity = 50

Util = {}


function Util.post(url, appid, eventArrayJson, isDebug, debugOnly)

	--print("url:",url)
	--print("appid:",appid)
	--print("isDebug:",isDebug)
	--print("debugOnly:",debugOnly)
	--print("eventArrayJson:",HttpService:JSONEncode(eventArrayJson))


	local content = HttpService:JSONEncode(eventArrayJson)
	local contentType = Enum.HttpContentType.TextPlain
	local size = #eventArrayJson;
	local headers={
		["TA-Integration-Type"]= TDSDK.LibName ;
		['TA-Integration-Version']= TDSDK.LibVersion;
		['appid']= appid;
		['TA-Integration-Count'] = #eventArrayJson..'';
	}
	if isDebug then
		local dryRun = 0
		if debugOnly then
			dryRun = 1
		end
		local request_body =  HttpService:UrlEncode(content)
		content = "data=" .. request_body .. "&source=server&appid=" .. appid .. "&dryRun=" .. dryRun
		contentType = Enum.HttpContentType.ApplicationUrlEncoded
		local response = HttpService:PostAsync(url,content, contentType,false,headers)
		local result = HttpService:JSONDecode(response)
		return result['errorLevel']
	end
	--headers['compress'] = 'gzip'
	local response = HttpService:PostAsync(url,content, contentType,false,headers)
	local result = HttpService:JSONDecode(response)

	--print("result:",result)
	--print("response:",response)

	return result['code']
end

function urlEncode(s)
	s = string.gsub(s, "([^%w%.%- ])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return string.gsub(s, " ", "+")
end

function Util.mergeTables(...)
	local tabs = { ... }
	if not tabs then
		return {}
	end
	local origin = tabs[1]
	for i = 2, #tabs do
		if origin then
			if tabs[i] then
				for k, v in pairs(tabs[i]) do
					if (v ~= nil) then
						origin[k] = v
					end
				end
			end
		else
			origin = tabs[i]
		end
	end
	return origin
end

function Util.startWith(str, substr)
	if str == nil or substr == nil then
		return false
	end
	if string.find(str, substr) ~= 1 then
		return false
	else
		return true
	end
end
function Util.log(level, key, msg)
	if Util.enableLog then
		print(level .. (key or "") .. (msg or ""))
	end
end
function Util.tablecopy(src, dest)
	for k, v in pairs(src) do
		if type(v) == "table" then
			dest[k] = {}
			Util.tablecopy(v, dest[k])
		else
			dest[k] =  v
		end
	end

end

function Util.create_uuid()
	local seed = {'e','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}
	local sid = ""
	for i=1,32 do
		-- table.insert(tb,seed[math.random(1,16)])
		sid = sid .. seed[math.random(1,16)]
	end
	-- local sid=table.concat(tb)
	return string.format('%s-%s-%s-%s-%s',
		string.sub(sid,1,8),
		string.sub(sid,9,12),
		string.sub(sid,13,16),
		string.sub(sid,17,20),
		string.sub(sid,21,32)
	)
end
function Util.getHourFromDate(dateString)
	return string.sub(dateString, 12, 13)
end
function Util.getDateFromDateTime(dateTime)
	return string.sub(dateTime, 1, 10)
end
function Util.toJson(eventArrayJson)
	return  HttpService:JSONEncode(eventArrayJson)
end
function Util.getCurrentHour()
	local t = os.date("%Y-%m-%d %H:%M:%S")
	return string.sub(t, 12, 13)
end
function Util.getCurrentMinute()
	local t = os.date("%Y-%m-%d %H:%M:%S")
	return string.sub(t, 15, 16)
end
local consumer;
if SendMethod == 'debug' then
	consumer = TDSDK.DebugConsumer(Config.server,Config.appid)
else
	consumer = TDSDK.BatchConsumer(Config.server,Config.appid)
end
local SDKInstance = TDSDK(consumer,Config.strict,Config.enableLog)
--[[
     * report ordinary event
     * @param distinctId distinct id
     * @param accountId account id
     * @param eventName event name
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.track(accountId, distinctId, eventName, properties)
	SDKInstance:track(accountId,distinctId,eventName,properties)
end
--[[
     * report updatable event.
     * @param distinctId distinct id
     * @param accountId account id
     * @param eventName event name
     * @param eventId event id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.trackUpdate(accountId, distinctId, eventName, eventId, properties)
	SDKInstance:trackUpdate(accountId, distinctId, eventName, eventId, properties)
end
--[[
     * report first event.
     * @param distinctId distinct id
     * @param accountId account id
     * @param eventName event name
     * @param firstCheckId it is flag of the first event
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.trackFirst(accountId, distinctId, eventName, firstCheckId, properties)
	SDKInstance:trackFirst(accountId, distinctId, eventName, firstCheckId, properties)
end
--[[
     * report overridable event.
     * @param distinctId distinct id
     * @param accountId account id
     * @param eventName event name
     * @param eventId event id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.trackOverwrite(accountId, distinctId, eventName, eventId, properties)
	SDKInstance:trackOverwrite(accountId, distinctId, eventName, eventId, properties)
end

--[[
     * set user properties. would overwrite existing names
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userSet(accountId, distinctId, properties)
	SDKInstance:userSet(accountId, distinctId, properties)
end
--[[
     * set user properties, If such property had been set before, this message would be neglected.
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userSetOnce(accountId, distinctId, properties)
	SDKInstance:userSetOnce(accountId, distinctId, properties)
end
--[[
     * to accumulate operations against the property
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userAdd(accountId, distinctId, properties)
	SDKInstance:userAdd(accountId, distinctId, properties)
end
--[[
     * to add user properties of array type
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userAppend(accountId, distinctId, properties)
	SDKInstance:userAppend(accountId, distinctId, properties)
end
--[[
     * append user properties to array type by unique.
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userUniqueAppend(accountId, distinctId, properties)
	SDKInstance:userUniqueAppend(accountId, distinctId, properties)
end
--[[
     * clear the user properties of users
     * @param distinctId distinct id
     * @param accountId account id
     * @param properties properties
--]]
function ThinkingAnalyticsAPI.userUnset(accountId, distinctId, properties)
	SDKInstance:userUnset(accountId, distinctId, properties)
end
--[[
     * delete a user, This operation cannot be undone
     * @param distinctId distinct id
     * @param accountId account id
--]]
function ThinkingAnalyticsAPI.userDel(accountId, distinctId)
	SDKInstance:userDel(accountId, distinctId)
end

function ThinkingAnalyticsAPI.flush()
	SDKInstance:flush()
end

return ThinkingAnalyticsAPI

